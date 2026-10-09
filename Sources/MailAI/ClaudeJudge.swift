import Foundation
import HTTPKit
import MailCore
import VimailLog

/// Decides Claude rules for one email per call: the `RuleJudge` the rules engine uses.
///
/// Each call checks the key and the account's consent, then for every HTTP attempt: estimates the
/// input tokens, waits for the limiter (previews first, live mail and runs in bulk), reserves the
/// worst case in the request's spend lane, calls, settles what it cost and releases the limiter.
///
/// Retries inside one call (design §3.6):
/// - A `max_tokens` stop: once more with twice the room. An empty or unreadable answer: once more.
/// - Rules missing from the answer: once more for those; then only the answered ones are returned and
///   the engine fails the rest. A retry that fails for this email (a 400, a 413, an unusable answer)
///   still returns what earlier attempts answered. One stopped by anything else (rate limits, the
///   network, a pause, the budget) throws, so the engine keeps the whole email for later or pauses.
/// - A 400 while sending `fallbacks` (Opus, Sonnet): once more without them and their beta header.
///   When that works the fallbacks are saved as unavailable and no longer sent.
/// - The same 400 on three different emails pauses Claude as `apiIncompatible`. A 400 about the credit
///   balance is billing, not this.
/// - A 429 or 529 also cools the limiter down for everyone.
public struct ClaudeJudge: RuleJudge {
    public let model: ClaudeModel
    let client: AnthropicClient
    let limiter: AILimiter
    let spend: SpendGuard
    let consent: @Sendable () async -> Bool
    let history = History()
    let timeZone: TimeZone

    /// - Parameters:
    ///   - limiter, spend: app-wide, shared by every account's judge.
    ///   - consent: whether this account's mail may go to Claude.
    ///   - timeZone: email dates are shown in it.
    public init(client: AnthropicClient, model: ClaudeModel, limiter: AILimiter, spend: SpendGuard, timeZone: TimeZone = .current, consent: @escaping @Sendable () async -> Bool) {
        self.client = client
        self.model = model
        self.limiter = limiter
        self.spend = spend
        self.timeZone = timeZone
        self.consent = consent
    }

    public func judge(_ request: JudgeRequest) async throws(JudgeError) -> JudgeResponse {
        var answer = JudgeResponse(decisions: [:], model: model.id, servedBy: model.id, costMicros: 0, usage: TokenUsage())
        guard !request.evaluate.isEmpty else { return answer }
        try await checkAccess()

        let prompt = JudgePrompt(request, timeZone: timeZone)
        let prefix = prompt.prefix(model: model)
        let priority: AILimiter.Priority = request.lane == .preview ? .interactive : .bulk
        var fallbacks = false
        if model.supportsFallbacks { fallbacks = await !spend.fallbacksUnavailable }
        var droppedFallbacks = false
        var maxTokens = model.maxTokens
        var pending = request.evaluate
        var retriedOutput = false
        var retriedMissing = false

        while true {
            let body = prompt.body(model: model, maxTokens: maxTokens, evaluate: pending, fallbacks: fallbacks)
            let attempt: Attempt
            switch try await call(body, lane: request.lane, priority: priority, prefix: prefix, cacheTTL: request.cacheTTL) {
            case .success(let value):
                attempt = value
            case .failure(.badRequest) where fallbacks:
                AnthropicClient.log.notice("Claude rejected a request with fallbacks: retrying without them")
                fallbacks = false
                droppedFallbacks = true
                continue
            case .failure(.badRequest(let fingerprint)):
                if await history.badRequest(fingerprint, messageID: request.email.messageID) {
                    AnthropicClient.log.error("The same 400 came back for 3 emails: pausing Claude rules")
                    throw .paused(.apiIncompatible)
                }
                if !answer.decisions.isEmpty { return answer }
                throw .invalid(code: "http_400")
            case .failure(let error):
                if case .invalid = error.judgeError, !answer.decisions.isEmpty { return answer }
                throw error.judgeError
            }

            await history.succeeded()
            if droppedFallbacks, await !spend.fallbacksUnavailable {
                AnthropicClient.log.notice("Claude answered without fallbacks: no longer sending them (refusals stay unlabeled)")
                await spend.setFallbacksUnavailable()
            }
            answer.costMicros += attempt.costMicros
            answer.usage.input += attempt.usage.input
            answer.usage.cacheWrite += attempt.usage.cacheWrite
            answer.usage.cacheRead += attempt.usage.cacheRead
            answer.usage.output += attempt.usage.output

            let verdicts: ResponseParser.Verdicts
            do {
                verdicts = try ResponseParser.verdicts(in: attempt.message, requested: pending)
            } catch {
                switch error {
                case .maxTokens where !retriedOutput:
                    maxTokens *= 2
                case .empty where !retriedOutput, .unreadable where !retriedOutput:
                    break
                default:
                    AnthropicClient.log.notice("Claude gave no usable answer for message \(request.email.messageID): \(error)")
                    if !answer.decisions.isEmpty { return answer }
                    throw error.judgeError
                }
                retriedOutput = true
                continue
            }
            answer.decisions.merge(verdicts.decisions) { earlier, _ in earlier }
            answer.servedBy = verdicts.servedBy
            pending = verdicts.missing
            if pending.isEmpty { return answer }
            if retriedMissing {
                AnthropicClient.log.notice("Claude left \(pending.count) of \(request.evaluate.count) rules undecided for message \(request.email.messageID)")
                if answer.decisions.isEmpty { throw .truncated }
                return answer
            }
            retriedMissing = true
        }
    }

    /// Throws before any network use when there is no key or no consent.
    func checkAccess() async throws(JudgeError) {
        guard await client.hasKey() else { throw .paused(.noKey) }
        guard await consent() else { throw .paused(.noConsent) }
    }

    // MARK: - One attempt

    /// An answered HTTP attempt and what it cost.
    struct Attempt: Sendable {
        var message: MessagesResponse
        var usage: TokenUsage
        var costMicros: Int64
    }

    /// One HTTP attempt: limiter, reservation, call, settlement. Throws only when the call could not be
    /// made (a budget, or cancelled while waiting); a failed call is a `.failure`.
    func call(_ body: MessagesRequest, lane: SpendLane, priority: AILimiter.Priority, prefix: AILimiter.Prefix?, cacheTTL: PromptCacheTTL) async throws(JudgeError) -> Result<Attempt, AIError> {
        let characters = body.characterCount
        let tokens = await history.estimatedTokens(characters: characters)
        let prices = model.prices
        let inputPrice = max(prices.input, cacheTTL == .oneHour ? prices.cacheWrite1h : prices.cacheWrite5m)
        let inputEstimate = Int64((Double(tokens) * prices.input).rounded(.up))
        let worstCase = Int64((Double(tokens) * inputPrice + Double(body.maxTokens) * prices.output).rounded(.up))

        let permit: AILimiter.Permit
        do {
            permit = try await limiter.acquire(priority, prefix: prefix, inputTokens: tokens)
        } catch {
            throw .offline
        }
        let reservation: SpendGuard.Reservation
        do {
            reservation = try await spend.reserve(lane: lane, worstCase: worstCase, inputEstimate: inputEstimate)
        } catch {
            await limiter.release(permit, succeeded: false)
            AnthropicClient.log.info("Claude call not made: \(error) (\(SpendGuard.laneKey(lane)) lane)")
            throw error
        }

        let clock = Stopwatch()
        do {
            let reply = try await client.createMessage(body)
            let bill = reply.message.bill(requested: model, cacheTTL: cacheTTL)
            await spend.settle(reservation, actualMicros: bill.micros)
            await history.calibrate(characters: characters, tokens: reply.message.usage.counts.allInput)
            await limiter.update(reply.rateLimits)
            await limiter.release(permit, succeeded: true)
            let usage = bill.usage
            AnthropicClient.log.info(
                "Claude \(model.id) → \(reply.message.stopReason ?? "no stop reason") in \(clock.text): input \(usage.input), cache read \(usage.cacheRead), cache write \(usage.cacheWrite), output \(usage.output), \(Self.dollars(bill.micros))"
                    + (reply.message.model == model.id ? "" : ", served by \(reply.message.model)")
                    + (reply.requestID.map { ", request \($0)" } ?? "")
            )
            return .success(Attempt(message: reply.message, usage: usage, costMicros: bill.micros))
        } catch {
            if error.mayHaveBilled { await spend.cancel(reservation) } else { await spend.settle(reservation, actualMicros: 0) }
            switch error {
            case .rateLimited(let retryAfter), .overloaded(let retryAfter): await limiter.coolDown(retryAfter: retryAfter)
            default: break
            }
            await limiter.release(permit, succeeded: false)
            return .failure(error)
        }
    }

    /// "$0.000312".
    static func dollars(_ micros: Int64) -> String {
        String(format: "$%.6f", Double(micros) / 1_000_000)
    }

    /// What earlier calls taught this judge: tokens per character, and recent 400s.
    actor History {
        /// Starts at the usual 4 characters per token; then follows what calls report.
        private(set) var tokensPerCharacter = 0.25
        private var calibrated = false
        /// 400 fingerprints → the emails that got them, since the last success.
        private var badRequests: [String: Set<String>] = [:]

        func estimatedTokens(characters: Int) -> Int {
            Int((Double(characters) * tokensPerCharacter).rounded(.up))
        }

        /// An exponential average of input tokens (cached or not) per character sent.
        func calibrate(characters: Int, tokens: Int) {
            guard characters > 0, tokens > 0 else { return }
            let observed = Double(tokens) / Double(characters)
            tokensPerCharacter = calibrated ? 0.8 * tokensPerCharacter + 0.2 * observed : observed
            calibrated = true
        }

        /// Records a 400 for an email. True once the same error has come back for three different emails.
        func badRequest(_ fingerprint: String, messageID: String) -> Bool {
            badRequests[fingerprint, default: []].insert(messageID)
            return badRequests[fingerprint, default: []].count >= 3
        }

        /// A call went through: earlier 400s were about their emails, not the request shape.
        func succeeded() {
            badRequests.removeAll()
        }
    }
}
