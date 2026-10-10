import Foundation
import Testing
@testable import MailAI
import MailCore

/// The limiter on a hand-moved clock: priorities, cooldowns, the rate-limit bucket and new prefixes.
@Suite("AI limiter")
struct AILimiterTests {
    let prefix = AILimiter.Prefix(key: "rules-v1", ttl: .fiveMinutes)

    /// Permits of the calls that got through, in order.
    final class Started: @unchecked Sendable {
        private let lock = NSLock()
        private var permits: [AILimiter.Permit] = []

        var count: Int { lock.withLock { permits.count } }
        var first: AILimiter.Permit? { lock.withLock { permits.first } }

        func append(_ permit: AILimiter.Permit) {
            lock.withLock { permits.append(permit) }
        }
    }

    /// Starts `acquire` in a task and records when it got through.
    func start(_ limiter: AILimiter, _ priority: AILimiter.Priority, prefix: AILimiter.Prefix? = nil, tokens: Int = 1_000, started: Started) -> Task<AILimiter.Permit?, Never> {
        Task {
            guard let permit = try? await limiter.acquire(priority, prefix: prefix, inputTokens: tokens) else { return nil }
            started.append(permit)
            return permit
        }
    }

    /// Lets other tasks run so a blocked one would have had its chance.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func bulkCallsLeaveASlotForPreviews() async throws {
        let limiter = AILimiter(clock: TestClock())
        var permits: [AILimiter.Permit] = []
        for _ in 0..<3 { permits.append(try await limiter.acquire(.bulk, prefix: nil, inputTokens: 100)) }
        let bulk = Started()
        let fourth = start(limiter, .bulk, started: bulk)
        await settle()
        #expect(bulk.count == 0)
        // The fourth slot is free for interactive work at once.
        let preview = try await limiter.acquire(.interactive, prefix: nil, inputTokens: 100)
        await limiter.release(permits.removeFirst(), succeeded: true)
        _ = await fourth.value
        #expect(bulk.count == 1)
        await limiter.release(preview, succeeded: true)
    }

    @Test func aCallCancelledWhileWaitingForASlotGivesItBack() async throws {
        let limiter = AILimiter(clock: TestClock())
        var permits: [AILimiter.Permit] = []
        for priority in [AILimiter.Priority.bulk, .bulk, .bulk, .interactive] {
            permits.append(try await limiter.acquire(priority, prefix: nil, inputTokens: 100))
        }
        let started = Started()
        let waiting = start(limiter, .interactive, started: started)
        await settle()
        // The editor closes while its call waits: it never starts, so it is never charged.
        waiting.cancel()
        await limiter.release(permits.removeLast(), succeeded: true)
        let permit = await waiting.value
        #expect(permit == nil)
        #expect(started.count == 0)
        if let permit { await limiter.release(permit, succeeded: false) }
        // Its slot is free for the next call at once.
        permits.append(try await limiter.acquire(.interactive, prefix: nil, inputTokens: 100))
        for permit in permits { await limiter.release(permit, succeeded: true) }
    }

    @Test func waitingPreviewsGoBeforeWaitingBulkCalls() async throws {
        let limiter = AILimiter(clock: TestClock())
        var permits: [AILimiter.Permit] = []
        for priority in [AILimiter.Priority.bulk, .bulk, .interactive, .interactive] {
            permits.append(try await limiter.acquire(priority, prefix: nil, inputTokens: 100))
        }
        let bulk = Started()
        let preview = Started()
        let waitingBulk = start(limiter, .bulk, started: bulk)
        await settle()
        let waitingPreview = start(limiter, .interactive, started: preview)
        await settle()
        #expect(bulk.count == 0 && preview.count == 0)
        // One slot frees up: the preview takes it although the bulk call asked first.
        await limiter.release(permits.removeLast(), succeeded: true)
        _ = await waitingPreview.value
        await settle()
        #expect(preview.count == 1 && bulk.count == 0)
        await limiter.release(permits.removeLast(), succeeded: true)
        _ = await waitingBulk.value
        #expect(bulk.count == 1)
    }

    @Test func cooldownHoldsEveryCallUntilRetryAfter() async throws {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock)
        await limiter.coolDown(retryAfter: .seconds(30))
        // A shorter one never cuts it short.
        await limiter.coolDown(retryAfter: .seconds(5))
        #expect(await limiter.cooldownEnd == clock.now.addingTimeInterval(30))
        let started = Started()
        let waiting = start(limiter, .interactive, started: started)
        await clock.waitForSleepers()
        #expect(clock.deadlines == [clock.now.addingTimeInterval(30)])
        clock.advance(by: 29)
        await settle()
        #expect(started.count == 0)
        clock.advance(by: 1)
        #expect(await waiting.value != nil)
        #expect(await limiter.cooldownEnd == nil)
    }

    @Test func cooldownHoldsCallsAlreadyWaitingForASlotOrAPrefix() async throws {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock)
        var bulk: [AILimiter.Permit] = []
        for _ in 0..<3 { bulk.append(try await limiter.acquire(.bulk, prefix: nil, inputTokens: 100)) }
        let writer = try await limiter.acquire(.interactive, prefix: prefix, inputTokens: 100)
        let started = Started()
        let forSlot = start(limiter, .bulk, started: started)
        let forPrefix = start(limiter, .interactive, prefix: prefix, started: started)
        await settle()
        // A 429 comes back, then its call ends, as `ClaudeJudge` does it: neither waiting call may start.
        await limiter.coolDown(retryAfter: .seconds(30))
        let end = try #require(await limiter.cooldownEnd)
        await limiter.release(bulk.removeFirst(), succeeded: false)
        await limiter.release(writer, succeeded: false)
        await settle()
        try #require(started.count == 0)
        await clock.waitForSleepers(2)
        #expect(clock.deadlines == [end, end])
        clock.advance(by: 29)
        await settle()
        #expect(started.count == 0)
        clock.advance(by: 1)
        #expect(await forSlot.value != nil)
        #expect(await forPrefix.value != nil)
    }

    @Test func cooldownWithoutRetryAfterBacksOff() async {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock, backoff: .init(first: .seconds(5), maximum: .seconds(1800), jitter: 0))
        await limiter.coolDown(retryAfter: nil)
        #expect(await limiter.cooldownEnd == clock.now.addingTimeInterval(5))
        await limiter.coolDown(retryAfter: nil)
        #expect(await limiter.cooldownEnd == clock.now.addingTimeInterval(10))
    }

    @Test func theFirstCallOnANewPrefixRunsAlone() async throws {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock)
        let first = try await limiter.acquire(.bulk, prefix: prefix, inputTokens: 100)
        let others = Started()
        let waiting = (0..<2).map { _ in start(limiter, .bulk, prefix: prefix, started: others) }
        await settle()
        #expect(others.count == 0)
        // Another prefix is not held up.
        let elsewhere = try await limiter.acquire(.bulk, prefix: AILimiter.Prefix(key: "other", ttl: .fiveMinutes), inputTokens: 100)
        await limiter.release(elsewhere, succeeded: true)
        // Once the first has written the cache, the rest fan out together.
        await limiter.release(first, succeeded: true)
        let permits = await waiting.asyncMap { await $0.value }
        #expect(others.count == 2)
        for permit in permits { await limiter.release(try #require(permit), succeeded: true) }
    }

    @Test func aFailedFirstCallHandsTheTurnOn() async throws {
        let limiter = AILimiter(clock: TestClock())
        let first = try await limiter.acquire(.bulk, prefix: prefix, inputTokens: 100)
        let others = Started()
        let waiting = (0..<2).map { _ in start(limiter, .bulk, prefix: prefix, started: others) }
        await settle()
        await limiter.release(first, succeeded: false)
        await settle()
        // One of them is now the first; the other waits for it.
        #expect(others.count == 1)
        await limiter.release(try #require(others.first), succeeded: true)
        _ = await waiting.asyncMap { await $0.value }
        #expect(others.count == 2)
    }

    @Test func anExpiredPrefixRunsAloneAgain() async throws {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock)
        await limiter.release(try await limiter.acquire(.bulk, prefix: prefix, inputTokens: 100), succeeded: true)
        // Warm: no waiting.
        let warm = try await limiter.acquire(.bulk, prefix: prefix, inputTokens: 100)
        let second = try await limiter.acquire(.bulk, prefix: prefix, inputTokens: 100)
        await limiter.release(warm, succeeded: true)
        await limiter.release(second, succeeded: true)
        clock.advance(by: 301)
        let cold = try await limiter.acquire(.bulk, prefix: prefix, inputTokens: 100)
        let others = Started()
        let waiting = start(limiter, .bulk, prefix: prefix, started: others)
        await settle()
        #expect(others.count == 0)
        await limiter.release(cold, succeeded: true)
        _ = await waiting.value
        #expect(others.count == 1)
    }

    @Test func callsWaitForTheBucketToRefill() async throws {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock)
        // No input tokens left; full again in 60 s, so 100,000 tokens come back in 3 s.
        await limiter.update(RateLimits(
            requests: .init(limit: 1_000, remaining: 900, reset: clock.now.addingTimeInterval(60)),
            inputTokens: .init(limit: 2_000_000, remaining: 0, reset: clock.now.addingTimeInterval(60))
        ))
        let started = Started()
        let waiting = start(limiter, .bulk, tokens: 100_000, started: started)
        await clock.waitForSleepers()
        let deadline = try #require(clock.deadlines.first)
        #expect(abs(deadline.timeIntervalSince(clock.now) - 3) < 0.01)
        clock.advance(by: 3)
        #expect(await waiting.value != nil)
    }

    @Test func nearlyUsedUpLimitsLeaveOneBulkSlot() async throws {
        let clock = TestClock()
        let limiter = AILimiter(clock: clock)
        await limiter.update(RateLimits(requests: .init(limit: 1_000, remaining: 50, reset: clock.now.addingTimeInterval(60))))
        let first = try await limiter.acquire(.bulk, prefix: nil, inputTokens: 100)
        let started = Started()
        let second = start(limiter, .bulk, started: started)
        await settle()
        #expect(started.count == 0)
        // Previews still get the other slots.
        let preview = try await limiter.acquire(.interactive, prefix: nil, inputTokens: 100)
        // Recovered limits give bulk its three slots back.
        await limiter.update(RateLimits(requests: .init(limit: 1_000, remaining: 990, reset: clock.now.addingTimeInterval(60))))
        _ = await second.value
        #expect(started.count == 1)
        await limiter.release(first, succeeded: true)
        await limiter.release(preview, succeeded: true)
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
