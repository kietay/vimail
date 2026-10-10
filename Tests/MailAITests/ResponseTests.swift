import Foundation
import Testing
@testable import MailAI
import MailCore

/// Reading answers: stop reasons, block types, fallbacks and their billing, and the retries the
/// judge makes for incomplete answers. Bodies come from `Fixtures/responses.json`.
@Suite("Judge responses")
struct ResponseTests {
    static func body(_ name: String) throws -> String {
        let all = try #require(JSONSerialization.jsonObject(with: fixture("responses.json")) as? [String: Any])
        let entry = try #require(all[name], "no fixture \(name)")
        return String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self)
    }

    func judge(_ names: [String], model: ClaudeModel = .haiku, request: JudgeRequest = Sample.request()) async throws -> (Result<JudgeResponse, JudgeError>, FakeTransport) {
        let transport = FakeTransport(try names.map { .ok(try Self.body($0)) })
        do {
            return (.success(try await makeJudge(transport, model: model).judge(request)), transport)
        } catch {
            return (.failure(error), transport)
        }
    }

    @Test func readsVerdictsWithoutThinking() async throws {
        let (result, transport) = try await judge(["plain"])
        let response = try result.get()
        #expect(response.decisions["r1"] == JudgeResponse.Decision(verdict: .match, reason: "Stripe receipt for a Figma subscription"))
        #expect(response.decisions["r3"] == JudgeResponse.Decision(verdict: .noMatch, reason: "automated receipt, nobody waiting"))
        #expect(response.model == "claude-haiku-5-5" && response.servedBy == "claude-haiku-5-5")
        // 900 input × $0.10 + 120 output × $0.50 + 1,200 cache reads × $0.01, per million.
        #expect(response.costMicros == 162)
        #expect(response.usage == TokenUsage(input: 900, cacheWrite: 0, cacheRead: 1200, output: 120))
        #expect(transport.calls.count == 1)
    }

    @Test func skipsThinkingBlocksAndPricesCacheWritesByTheirTTL() async throws {
        let (result, _) = try await judge(["thinking"], request: Sample.request(lane: .preview))
        let response = try result.get()
        #expect(response.decisions["r1"]?.verdict == .match && response.decisions["r3"]?.verdict == .unsure)
        // The API reports the 1,200 written tokens as 1-hour writes ($0.20), though the request asked for 5 minutes.
        #expect(response.costMicros == 90 + 170 + 240)
    }

    @Test func fallbackBillsEveryAttemptAtItsModelsPrices() async throws {
        let (result, _) = try await judge(["fallback"], model: .sonnet)
        let response = try result.get()
        #expect(response.model == "claude-sonnet-5-5")
        #expect(response.servedBy == "claude-opus-5-5")
        #expect(response.decisions["r1"]?.verdict == .match)
        // Sonnet declined (1,000 input × $2), then Opus answered (1,000 × $4 + 200 output × $20).
        #expect(response.costMicros == 2_000 + 4_000 + 4_000)
        #expect(response.usage == TokenUsage(input: 2_000, cacheWrite: 0, cacheRead: 0, output: 200))
    }

    @Test func fallbackModelsOutsideTheCatalogArePricedAsTheDearest() async throws {
        let (result, _) = try await judge(["fallback-outside-catalog"])
        let response = try result.get()
        #expect(response.servedBy == "claude-opus-4-8")
        #expect(response.costMicros == 100 + 4_000 + 2_000)
    }

    @Test(arguments: ["cyber", "bio", "frontier_llm", "reasoning_extraction", "general_harms", nil] as [String?])
    func refusalsAreDeclinedWithTheirCategory(category: String?) async throws {
        var body = try Self.body("refusal")
        body = body.replacingOccurrences(of: #""category":"cyber""#, with: category.map { #""category":"\#($0)""# } ?? #""category":null"#)
        for model in ClaudeModel.allCases {
            let transport = FakeTransport([.ok(body)])
            let error = await #expect(throws: JudgeError.self) {
                try await makeJudge(transport, model: model).judge(Sample.request())
            }
            // A refusal is billed: the engine counts its cost toward the run.
            #expect(error?.unbilled == .refused(category: category))
            #expect((error?.billedMicros ?? 0) > 0)
            // Never retried: the same email would be declined again.
            #expect(transport.calls.count == 1)
        }
    }

    @Test func maxTokensRetriesOnceWithTwiceTheRoom() async throws {
        let (result, transport) = try await judge(["max_tokens", "plain"])
        #expect(try result.get().decisions.count == 2)
        #expect(transport.calls.map { $0.json["max_tokens"] as? Int } == [2048, 4096])

        let (again, twice) = try await judge(["max_tokens", "max_tokens", "plain"], model: .opus)
        #expect(again.failure?.unbilled == .truncated && (again.failure?.billedMicros ?? 0) > 0)
        #expect(twice.calls.map { $0.json["max_tokens"] as? Int } == [4096, 8192])
    }

    @Test func contextWindowIsNotRetried() async throws {
        let (result, transport) = try await judge(["context", "plain"])
        #expect(result.failure?.unbilled == .truncated)
        #expect(transport.calls.count == 1)
    }

    @Test func emptyOrUnreadableTextIsRetriedOnce() async throws {
        let (recovered, first) = try await judge(["empty", "plain"])
        #expect(try recovered.get().decisions.count == 2)
        #expect(first.calls.count == 2)

        let (empty, second) = try await judge(["empty", "empty", "plain"])
        #expect(empty.failure?.unbilled == .truncated)
        #expect(second.calls.count == 2)

        let (unreadable, _) = try await judge(["unreadable", "unreadable"])
        #expect(unreadable.failure?.unbilled == .invalid(code: "bad_output"))
    }

    @Test func missingRulesAreAskedForOnceThenLeftOut() async throws {
        let (result, transport) = try await judge(["missing", "missing"])
        let response = try result.get()
        // The engine fails r3; r1 stands. Both attempts are billed.
        #expect(response.decisions.keys.sorted() == ["r1"])
        #expect(transport.calls.count == 2)
        #expect(response.costMicros == 2 * (90 + 30 + 12))

        // Nothing answered at all: an incomplete answer.
        let (none, _) = try await judge(["missing", "missing"], request: Sample.request(evaluate: ["r3"]))
        #expect(none.failure == .billed(.truncated, costMicros: 2 * (90 + 30 + 12)))
    }

    @Test func extraDuplicateAndUnrequestedVerdictsAreDropped() async throws {
        let (result, _) = try await judge(["extra"])
        let response = try result.get()
        #expect(response.decisions == [
            "r1": JudgeResponse.Decision(verdict: .match, reason: "receipt"),
            "r3": JudgeResponse.Decision(verdict: .noMatch, reason: "automated"),
        ])
    }

    @Test func aRetryThatFailsForTheEmailKeepsEarlierAnswers() async throws {
        let failures: [FakeTransport.Answer] = [.error(413, type: "request_too_large", message: "Request exceeds the maximum size"), .ok(#"{"text": "not a message"}"#)]
        for failure in failures {
            let transport = FakeTransport([.ok(try Self.body("missing")), failure])
            let response = try await makeJudge(transport).judge(Sample.request())
            #expect(response.decisions.keys.sorted() == ["r1"])
            #expect(transport.calls.count == 2)
        }
    }

    /// Returning r1 alone would make the engine fail r3, which Claude never got to answer.
    @Test func aRetryStoppedByRateLimitsTheNetworkOrAPauseLeavesTheEmailForLater() async throws {
        let stops: [(FakeTransport.Answer, JudgeError)] = [
            (.error(529, type: "overloaded_error", message: "Overloaded"), .transient(retryAfter: nil)),
            (.error(401, type: "authentication_error", message: "invalid x-api-key"), .paused(.badKey)),
            (.error(400, type: "invalid_request_error", message: "Your credit balance is too low to access the Anthropic API."), .paused(.billing)),
            (.failure(.notConnectedToInternet), .offline),
        ]
        for (stop, expected) in stops {
            let transport = FakeTransport([.ok(try Self.body("missing")), stop])
            // The first attempt was billed: its cost comes with the error.
            await #expect(throws: JudgeError.billed(expected, costMicros: 90 + 30 + 12)) { try await makeJudge(transport).judge(Sample.request()) }
            #expect(transport.calls.count == 2)
        }
    }

    @Test func aRetryTheBudgetStopsLeavesTheEmailForLater() async throws {
        let request = Sample.request(lane: .run(1))
        // Room for the first call's worst case (its estimate at the 5-minute write price, plus all of
        // max_tokens), so none for the retry once the first has cost something.
        let body = JudgePrompt(request, timeZone: .gmt).body(model: .haiku, maxTokens: ClaudeModel.haiku.maxTokens, evaluate: request.evaluate, fallbacks: false)
        let prices = ClaudeModel.haiku.prices
        let worstCase = Int64(((Double(body.characterCount) / 4).rounded(.up) * prices.cacheWrite5m + Double(body.maxTokens) * prices.output).rounded(.up))
        let spend = SpendGuard(file: nil, budget: SpendGuard.Budget(day: worstCase, month: 1_000_000, previewDay: 0))
        let transport = FakeTransport([.ok(try Self.body("missing")), .ok(Sample.bothMatch)])
        await #expect(throws: JudgeError.billed(.budget(.day), costMicros: 90 + 30 + 12)) { try await makeJudge(transport, spend: spend).judge(request) }
        #expect(transport.calls.count == 1)
        // What the first call cost still counts.
        #expect(await spend.snapshot().spendToday == 90 + 30 + 12)
    }

    @Test func reasonsArePlainTextWithoutLinksOrAddresses() {
        let raw = "Receipt\nfrom <b>Stripe</b> https://stripe.com/x see www.figma.com, stripe.com/receipts or (bob@example.com) via @stripe.com\u{200B}"
        #expect(ResponseParser.plainText(raw, limit: 160) == "Receipt from ‹b›Stripe‹/b› see or via @stripe.com")
        let long = ResponseParser.plainText(String(repeating: "word ", count: 100), limit: ResponseParser.reasonLimit)
        #expect(long.count == ResponseParser.reasonLimit && long.hasSuffix("…"))
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
