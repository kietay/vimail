import Foundation
import Testing
@testable import MailAI
import MailCore

/// HTTP failures and what the engine sees (design §3.6 and the live API findings).
@Suite("Judge errors")
struct ErrorTests {
    func failure(_ answers: [FakeTransport.Answer], model: ClaudeModel = .haiku, limiter: AILimiter? = nil) async -> (JudgeError?, FakeTransport) {
        let transport = FakeTransport(answers)
        do {
            _ = try await makeJudge(transport, model: model, limiter: limiter).judge(Sample.request())
            return (nil, transport)
        } catch {
            return (error, transport)
        }
    }

    @Test func rateLimitWaitsForRetryAfterAndCoolsEveryCallDown() async {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock)
        let (error, _) = await failure([.error(429, type: "rate_limit_error", message: "Number of requests has exceeded your rate limit", headers: ["retry-after": "30"])], limiter: limiter)
        #expect(error == .transient(retryAfter: .seconds(30)))
        #expect(await limiter.cooldownEnd == clock.now.addingTimeInterval(30))
    }

    @Test func aRateLimitHoldsCallsAlreadyWaitingOnItsPrefix() async {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock)
        let transport = FakeTransport { _, index in
            index == 0 ? .error(429, type: "rate_limit_error", message: "Number of requests has exceeded your rate limit", headers: ["retry-after": "30"]) : .ok(Sample.bothMatch)
        }
        let judge = makeJudge(transport, limiter: limiter)
        let calls = (0..<3).map { _ in
            Task { () -> JudgeError? in
                do throws(JudgeError) {
                    _ = try await judge.judge(Sample.request())
                    return nil
                } catch {
                    return error
                }
            }
        }
        // The first call on the prefix gets the 429; the next waits out the cooldown instead of going.
        while clock.deadlines.isEmpty, transport.calls.count < 2 { await Task.yield() }
        #expect(transport.calls.count == 1)
        clock.advance(by: 30)
        let errors = await calls.asyncMap { await $0.value }
        #expect(errors.filter { $0 == .transient(retryAfter: .seconds(30)) }.count == 1)
        #expect(errors.filter { $0 == nil }.count == 2)
        #expect(transport.calls.count == 3)
    }

    @Test func overloadIsTransientAndCoolsDown() async {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock)
        let (error, _) = await failure([.error(529, type: "overloaded_error", message: "Overloaded", headers: ["retry-after": "12.5"])], limiter: limiter)
        #expect(error == .transient(retryAfter: .milliseconds(12_500)))
        #expect(await limiter.cooldownEnd == clock.now.addingTimeInterval(12.5))
    }

    @Test(arguments: [500, 504])
    func serverErrorsAreTransientWithoutACooldown(status: Int) async {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock)
        let (error, _) = await failure([.error(status, type: status == 504 ? "timeout_error" : "api_error", message: "Internal")], limiter: limiter)
        #expect(error == .transient(retryAfter: nil))
        #expect(await limiter.cooldownEnd == nil)
    }

    @Test func spendLimitPausesForBilling() async {
        let byCode = await failure([.error(429, type: "rate_limit_error", message: "Request rejected", details: "enforced_spend_limit_reached")])
        #expect(byCode.0 == .paused(.billing))
        let byMessage = await failure([.error(429, type: "rate_limit_error", message: "You have reached your specified workspace API spend limit")])
        #expect(byMessage.0 == .paused(.billing))
    }

    @Test func statusesThatNeedThePersonPauseClaude() async {
        #expect(await failure([.error(401, type: "authentication_error", message: "invalid x-api-key")]).0 == .paused(.badKey))
        #expect(await failure([.error(402, type: "billing_error", message: "Payment required")]).0 == .paused(.billing))
        #expect(await failure([.error(403, type: "permission_error", message: "Your API key does not have permission")]).0 == .paused(.modelUnavailable))
        #expect(await failure([.error(404, type: "not_found_error", message: "model: claude-haiku-5-5")]).0 == .paused(.modelUnavailable))
        #expect(await failure([.error(413, type: "request_too_large", message: "Request exceeds the maximum size")]).0 == .invalid(code: "http_413"))
    }

    @Test func lowCreditBalanceIsBillingAndNeverPausesAsIncompatible() async {
        let credit = FakeTransport.Answer.error(400, type: "invalid_request_error", message: "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits.")
        let transport = FakeTransport([credit])
        let judge = makeJudge(transport, model: .opus)
        for message in [Sample.receipt, Sample.newsletter, Sample.reply.message, Sample.receipt] {
            await #expect(throws: JudgeError.paused(.billing)) { try await judge.judge(Sample.request(message)) }
        }
        // Not retried without fallbacks either: it is not about the request's shape.
        #expect(transport.calls.count == 4)
    }

    @Test func usageLimitYouSetIsBillingAndNeverPausesAsIncompatible() async {
        let limit = FakeTransport.Answer.error(
            400, type: "invalid_request_error", message: "You have reached your specified API usage limits. You will regain access on 2026-11-01 at 00:00 UTC."
        )
        let transport = FakeTransport([limit])
        let judge = makeJudge(transport, model: .haiku)
        for message in [Sample.receipt, Sample.newsletter, Sample.reply.message, Sample.receipt] {
            await #expect(throws: JudgeError.paused(.billing)) { try await judge.judge(Sample.request(message)) }
        }
        #expect(await failure([.error(400, type: "invalid_request_error", message: "You have reached your specified workspace API usage limits")]).0 == .paused(.billing))
    }

    @Test func badRequestWithFallbacksRetriesWithoutThemAndRemembers() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-\(UUID().uuidString)/ai-usage.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let spend = SpendGuard(file: file, budget: .standard)
        let transport = FakeTransport { call, _ in
            call.json["fallbacks"] != nil ? .error(400, type: "invalid_request_error", message: "fallbacks: Extra inputs are not permitted") : .ok(Sample.bothMatch)
        }
        let judge = makeJudge(transport, model: .opus, spend: spend)
        let response = try await judge.judge(Sample.request())
        #expect(response.decisions.count == 2)
        #expect(transport.calls.count == 2)
        #expect(transport.calls[0].headers["anthropic-beta"] != nil && transport.calls[0].json["fallbacks"] != nil)
        #expect(transport.calls[1].headers["anthropic-beta"] == nil && transport.calls[1].json["fallbacks"] == nil)
        #expect(await spend.fallbacksUnavailable)

        // Later calls no longer send them, and a restart remembers.
        _ = try await judge.judge(Sample.request(Sample.newsletter))
        #expect(transport.calls.count == 3 && transport.calls[2].json["fallbacks"] == nil)
        #expect(await SpendGuard(file: file, budget: .standard).fallbacksUnavailable)
    }

    @Test func badRequestThatIsNotAboutFallbacksFailsTheEmail() async {
        let (error, transport) = await failure([.error(400, type: "invalid_request_error", message: "messages: text content blocks must be non-empty")], model: .sonnet)
        #expect(error == .invalid(code: "http_400"))
        #expect(transport.calls.count == 2)
    }

    @Test func sameBadRequestOnThreeEmailsPausesAsIncompatible() async {
        let transport = FakeTransport { call, _ in
            call.text.contains("The Browser")
                ? .error(400, type: "invalid_request_error", message: "something else")
                : .error(400, type: "invalid_request_error", message: "output_config.effort: unsupported value")
        }
        let judge = makeJudge(transport)
        func judged(_ message: MailMessage, id: String) async -> JudgeError? {
            var message = message
            message.id = id
            do {
                _ = try await judge.judge(Sample.request(message))
                return nil
            } catch {
                return error
            }
        }
        #expect(await judged(Sample.receipt, id: "a") == .invalid(code: "http_400"))
        // The same email again is not a second email.
        #expect(await judged(Sample.receipt, id: "a") == .invalid(code: "http_400"))
        // A different error message is a different problem.
        #expect(await judged(Sample.newsletter, id: "n") == .invalid(code: "http_400"))
        #expect(await judged(Sample.receipt, id: "b") == .invalid(code: "http_400"))
        #expect(await judged(Sample.receipt, id: "c") == .paused(.apiIncompatible))
    }

    @Test func aSuccessInBetweenResetsTheCount() async {
        let transport = FakeTransport { call, _ in
            call.text.contains("The Browser") ? .ok(Sample.bothMatch) : .error(400, type: "invalid_request_error", message: "same")
        }
        let judge = makeJudge(transport)
        var errors: [JudgeError?] = []
        for (index, message) in [Sample.receipt, Sample.receipt, Sample.newsletter, Sample.receipt, Sample.receipt].enumerated() {
            var message = message
            message.id = "m\(index)"
            do {
                _ = try await judge.judge(Sample.request(message))
                errors.append(nil)
            } catch {
                errors.append(error)
            }
        }
        let failed = JudgeError.invalid(code: "http_400")
        #expect(errors == [failed, failed, nil, failed, failed])
    }

    /// A stalled network times out too, so none of these is an attempt.
    @Test func offlineTimeoutsAndDroppedConnectionsAreOffline() async {
        for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .timedOut, .networkConnectionLost] {
            #expect(await failure([.failure(code)]).0 == .offline)
        }
    }

    @Test func noKeyOrConsentStopsBeforeTheNetwork() async {
        let transport = FakeTransport([.ok(Sample.bothMatch)])
        await #expect(throws: JudgeError.paused(.noKey)) { try await makeJudge(transport, key: nil).judge(Sample.request()) }
        await #expect(throws: JudgeError.paused(.noKey)) { try await makeJudge(transport, key: "  ").judge(Sample.request()) }
        await #expect(throws: JudgeError.paused(.noConsent)) { try await makeJudge(transport, consent: false).judge(Sample.request()) }
        #expect(transport.calls.isEmpty)
    }

    @Test func budgetStopsBeforeTheNetwork() async {
        let transport = FakeTransport([.ok(Sample.bothMatch)])
        let spend = SpendGuard(file: nil, budget: SpendGuard.Budget(day: 500, month: 10_000, previewDay: 100))
        await #expect(throws: JudgeError.paused(.budgetDay)) { try await makeJudge(transport, spend: spend).judge(Sample.request(lane: .live)) }
        await #expect(throws: JudgeError.budget(.day)) { try await makeJudge(transport, spend: spend).judge(Sample.request(lane: .run(1))) }
        #expect(transport.calls.isEmpty)
    }

    // MARK: - Spend

    /// What the input of `request` is estimated to cost on Haiku, at `tokensPerCharacter`.
    func inputEstimate(_ request: JudgeRequest, tokensPerCharacter: Double = 0.25) -> Int64 {
        let tokens = (Double(promptCharacters(request)) * tokensPerCharacter).rounded(.up)
        return Int64((tokens * ClaudeModel.haiku.prices.input).rounded(.up))
    }

    func promptCharacters(_ request: JudgeRequest) -> Int {
        JudgePrompt(request, timeZone: .gmt).body(model: .haiku, maxTokens: ClaudeModel.haiku.maxTokens, evaluate: request.evaluate, fallbacks: false).characterCount
    }

    @Test func judgedCallsSettleWhatTheyCost() async throws {
        let spend = SpendGuard(file: nil, budget: SpendGuard.Budget(day: 10_000, month: 1_000_000, previewDay: 0))
        let judge = makeJudge(FakeTransport([.ok(Sample.bothMatch)]), spend: spend)
        // Each call reserves about 1,500 (all of max_tokens at the output price is 1,024) and costs 162,
        // so 30 calls fit only when every reservation is given back.
        var spent: Int64 = 0
        for _ in 0..<30 { spent += try await judge.judge(Sample.request()).costMicros }
        #expect(spent == 30 * 162)
        let snapshot = await spend.snapshot()
        #expect(snapshot.spendToday == spent)
        #expect(snapshot.runRoomToday == 10_000 - spent)
    }

    @Test func failedCallsSettleOnlyWhatMayHaveBeenBilled() async {
        let spend = SpendGuard(file: nil, budget: SpendGuard.Budget(day: 10_000, month: 1_000_000, previewDay: 0))
        // Rejected or never sent: nothing spent, nothing held.
        for answer in [FakeTransport.Answer.error(401, type: "authentication_error", message: "invalid x-api-key"), .failure(.notConnectedToInternet)] {
            _ = try? await makeJudge(FakeTransport([answer]), spend: spend).judge(Sample.request())
            #expect(await spend.snapshot().spendToday == 0)
            #expect(await spend.snapshot().runRoomToday == 10_000)
        }
        // A timeout may have reached Anthropic: its input estimate counts.
        await #expect(throws: JudgeError.offline) { try await makeJudge(FakeTransport([.failure(.timedOut)]), spend: spend).judge(Sample.request()) }
        let estimate = inputEstimate(Sample.request())
        #expect(estimate > 0)
        #expect(await spend.snapshot().spendToday == estimate)
        #expect(await spend.snapshot().runRoomToday == 10_000 - estimate)
    }

    @Test func estimatesFollowTheTokensCallsReport() async throws {
        let spend = SpendGuard(file: nil, budget: SpendGuard.Budget(day: 10_000, month: 1_000_000, previewDay: 0))
        let larger = Sample.response([("r1", "match", "receipt"), ("r3", "no_match", "automated")], usage: #"{"input_tokens":3000,"output_tokens":120,"cache_creation_input_tokens":0,"cache_read_input_tokens":1200}"#)
        let judge = makeJudge(FakeTransport([.ok(Sample.bothMatch), .failure(.timedOut), .ok(larger)]), spend: spend)
        let request = Sample.request()
        let characters = Double(promptCharacters(request))
        #expect(await judge.history.tokensPerCharacter == 0.25)

        // The answer counted 900 input and 1,200 cached tokens for these characters.
        let cost = try await judge.judge(request).costMicros
        let calibrated = 2_100 / characters
        #expect(await judge.history.tokensPerCharacter == calibrated)
        // The next call reserves (and here, timing out, settles) the calibrated estimate.
        try #require(inputEstimate(request, tokensPerCharacter: calibrated) != inputEstimate(request))
        await #expect(throws: JudgeError.offline) { try await judge.judge(request) }
        #expect(await spend.snapshot().spendToday == cost + inputEstimate(request, tokensPerCharacter: calibrated))

        // Later answers move it a fifth of the way.
        _ = try await judge.judge(request)
        #expect(await judge.history.tokensPerCharacter == 0.8 * calibrated + 0.2 * (4_200 / characters))
    }

    @Test func errorDescriptionsNeverIncludeTheResponseBody() async {
        let secret = "SECRET-BODY Your receipt from bob@example.com"
        let client = AnthropicClient(transport: FakeTransport { _, index in
            let statuses = [400, 401, 402, 403, 404, 413, 429, 500, 504, 529, 418]
            return .error(statuses[index % statuses.count], type: "invalid_request_error", message: secret)
        }) { "sk-ant-test" }
        let body = JudgePrompt(Sample.request()).body(model: .haiku, maxTokens: 2048, evaluate: ["r1"], fallbacks: false)
        for _ in 0..<11 {
            do {
                _ = try await client.createMessage(body)
                Issue.record("expected a failure")
            } catch {
                for text in [error.description, error.localizedDescription, String(describing: error), "\(error)", String(describing: error.judgeError)] {
                    #expect(!text.contains("SECRET") && !text.contains("bob@"), "\(text)")
                }
            }
        }
        let unreadable = AnthropicClient(transport: FakeTransport([.ok(#"{"text": "SECRET-BODY"}"#)])) { "sk-ant-test" }
        do {
            _ = try await unreadable.createMessage(body)
        } catch {
            #expect(error == .malformedResponse && !error.description.contains("SECRET"))
        }
    }

    @Test func verifyKeyUsesTheFreeModelsEndpoint() async throws {
        let answers: [(FakeTransport.Answer, AnthropicClient.KeyCheck)] = [
            (.ok(#"{"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}"#), .valid),
            (.error(401, type: "authentication_error", message: "invalid x-api-key"), .badKey),
            (.error(404, type: "not_found_error", message: "model not found"), .modelUnavailable),
            (.error(403, type: "permission_error", message: "no access"), .modelUnavailable),
            (.error(529, type: "overloaded_error", message: "Overloaded"), .offline),
            (.failure(.notConnectedToInternet), .offline),
        ]
        for (answer, expected) in answers {
            let transport = FakeTransport([answer])
            let client = AnthropicClient(transport: transport) { "sk-ant-saved" }
            #expect(await client.verifyKey(model: .haiku) == expected)
            let call = try #require(transport.calls.first)
            #expect(call.method == "GET" && call.url.absoluteString == "https://api.anthropic.com/v1/models/claude-haiku-5-5")
            #expect(call.headers["x-api-key"] == "sk-ant-saved" && call.headers["anthropic-version"] == "2023-06-01")
        }
        // A key about to be saved is checked instead of the saved one.
        let transport = FakeTransport([.ok("{}")])
        #expect(await AnthropicClient(transport: transport) { nil }.verifyKey(" sk-ant-new\n", model: .opus) == .valid)
        #expect(transport.calls.first?.headers["x-api-key"] == "sk-ant-new")
        #expect(transport.calls.first?.path == "/v1/models/claude-opus-5-5")
        // A blank key about to be saved is bad: the saved one is not checked in its place.
        let blank = FakeTransport([.ok("{}")])
        #expect(await AnthropicClient(transport: blank) { "sk-ant-saved" }.verifyKey(" \n", model: .haiku) == .badKey)
        #expect(blank.calls.isEmpty)
        // No key at all: nothing to check.
        let none = FakeTransport([.ok("{}")])
        #expect(await AnthropicClient(transport: none) { nil }.verifyKey(model: .haiku) == .badKey)
        #expect(none.calls.isEmpty)
    }

    @Test func rateLimitHeadersAreRead() throws {
        let response = HTTPURLResponse(url: URL(string: "https://api.anthropic.com/v1/messages")!, statusCode: 200, httpVersion: nil, headerFields: [
            "anthropic-ratelimit-requests-limit": "1000", "anthropic-ratelimit-requests-remaining": "999",
            "anthropic-ratelimit-requests-reset": "2026-10-09T12:00:01Z",
            "anthropic-ratelimit-input-tokens-limit": "2000000", "anthropic-ratelimit-input-tokens-remaining": "1990000",
            "anthropic-ratelimit-input-tokens-reset": "2026-10-09T12:00:00.500Z",
            "anthropic-ratelimit-output-tokens-remaining": "400000", "anthropic-ratelimit-tokens-limit": "2400000",
        ])!
        let limits = RateLimits(response)
        #expect(limits.requests == RateLimits.Limit(limit: 1000, remaining: 999, reset: Date(timeIntervalSince1970: 1_791_547_201)))
        #expect(limits.inputTokens == RateLimits.Limit(limit: 2_000_000, remaining: 1_990_000, reset: Date(timeIntervalSince1970: 1_791_547_200.5)))
        #expect(limits.outputTokens == RateLimits.Limit(remaining: 400_000))
        #expect(limits.tokens == RateLimits.Limit(limit: 2_400_000))
    }
}
