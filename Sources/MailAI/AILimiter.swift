import Foundation
import HTTPKit
import MailCore
import VimailLog

/// Paces Claude calls for the whole app: rate limits belong to the API key, not to an account.
///
/// - **Slots:** at most 4 calls at once, at most 3 of them bulk (live mail and runs), so a preview in
///   the editor always finds one free. Bulk drops to 1 slot while less than 10% of the requests or
///   input tokens limit remains.
/// - **Token bucket:** follows the `anthropic-ratelimit-*` headers, refilling evenly until their reset
///   time. A call waits while the requests or input tokens it needs are not there yet.
/// - **Cooldown:** a 429 or 529 holds every call until its retry-after (else 5 s, doubling), also the
///   calls already waiting for a slot or a prefix.
/// - **New prefixes:** the first call on a prompt prefix nobody has cached runs alone. Concurrent
///   calls can't read a cache entry that is still being written, so the others wait and then read it.
public actor AILimiter {
    public typealias Priority = PrioritySlots.Priority

    /// A cacheable prompt prefix: the same key means the same model, bytes and TTL.
    public struct Prefix: Sendable, Hashable {
        public var key: String
        public var ttl: PromptCacheTTL

        public init(key: String, ttl: PromptCacheTTL) {
            self.key = key
            self.ttl = ttl
        }
    }

    /// A started call. Hand it back to `release(_:succeeded:)`.
    public struct Permit: Sendable {
        let priority: Priority
        let prefix: Prefix?
        /// The first call on its prefix: others wait for it.
        let writesPrefix: Bool
    }

    public static let slotCount = 4
    public static let bulkSlotCount = 3

    private let clock: any AIClock
    private let backoff: Backoff
    private let slots = PrioritySlots(limit: AILimiter.slotCount, bulkLimit: AILimiter.bulkSlotCount)
    private var bulkLimit = AILimiter.bulkSlotCount
    private var requests = Bucket()
    private var inputTokens = Bucket()
    private var coolingUntil: Date?
    private var cooldowns = 0
    /// Prefixes Claude has cached, until their TTL runs out.
    private var cached: [String: Date] = [:]
    /// Prefixes whose first call is in flight.
    private var writing: Set<String> = []
    private var prefixWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(clock: any AIClock = WallClock(), backoff: Backoff = Backoff(first: .seconds(5), maximum: .seconds(1800))) {
        self.clock = clock
        self.backoff = backoff
    }

    /// When calls may start again after a 429 or 529, if that is still ahead.
    public var cooldownEnd: Date? {
        coolingUntil.flatMap { $0 > clock.now ? $0 : nil }
    }

    /// Waits until a call may start.
    /// - Parameters:
    ///   - prefix: the cached part of the prompt, or nil when the call caches nothing.
    ///   - inputTokens: the estimated input, taken from the bucket.
    public func acquire(_ priority: Priority, prefix: Prefix?, inputTokens tokens: Int) async throws(CancellationError) -> Permit {
        let writesPrefix = try await waitForPrefix(prefix)
        await slots.enter(priority: priority)
        // Last, with the slot held: a 429 can come back while this call waits for its prefix or slot.
        do throws(CancellationError) {
            // Cancelled while it waited for a slot: it gives the slot back unsent, so nothing is
            // reserved or charged for it.
            if Task.isCancelled { throw CancellationError() }
            try await waitForTurn(tokens)
        } catch {
            if writesPrefix, let prefix { finishWriting(prefix) }
            await slots.leave(priority: priority)
            throw error
        }
        let now = clock.now
        requests.take(1, now: now)
        inputTokens.take(Double(tokens), now: now)
        return Permit(priority: priority, prefix: prefix, writesPrefix: writesPrefix)
    }

    /// Ends a call. `succeeded` means Claude answered, so its prefix is now cached.
    public func release(_ permit: Permit, succeeded: Bool) async {
        if succeeded {
            cooldowns = 0
            if let prefix = permit.prefix { cached[prefix.key] = clock.now.addingTimeInterval(Self.seconds(prefix.ttl)) }
        }
        if permit.writesPrefix, let prefix = permit.prefix { finishWriting(prefix) }
        await slots.leave(priority: permit.priority)
    }

    /// Takes in the limits a response reported.
    public func update(_ limits: RateLimits) async {
        let now = clock.now
        requests.update(limits.requests, now: now)
        inputTokens.update(limits.inputTokens, now: now)
        let low = [requests.fraction(at: now), inputTokens.fraction(at: now)].contains { ($0 ?? 1) < 0.1 }
        let wanted = low ? 1 : Self.bulkSlotCount
        if wanted != bulkLimit {
            bulkLimit = wanted
            AnthropicClient.log.notice("Claude rate limits \(low ? "nearly used up: 1 background call at a time" : "recovered: \(wanted) background calls at a time")")
            await slots.setLimit(Self.slotCount, bulkLimit: wanted)
        }
    }

    /// Holds every call after a 429 or 529, for the server's retry-after when it gave one.
    public func coolDown(retryAfter: Duration?) {
        cooldowns += 1
        let delay = retryAfter ?? backoff.delay(afterAttempt: cooldowns)
        let until = clock.now.addingTimeInterval(Self.interval(delay))
        guard until > coolingUntil ?? .distantPast else { return }
        coolingUntil = until
        AnthropicClient.log.notice("Claude calls paused for \(Int(Self.interval(delay).rounded(.up)))s")
    }

    // MARK: - Waiting

    /// Returns true when this call is the first on its prefix and must run alone.
    private func waitForPrefix(_ prefix: Prefix?) async throws(CancellationError) -> Bool {
        guard let prefix else { return false }
        while true {
            if Task.isCancelled { throw CancellationError() }
            let now = clock.now
            cached = cached.filter { $0.value > now }
            if cached[prefix.key] != nil { return false }
            if !writing.contains(prefix.key) {
                writing.insert(prefix.key)
                return true
            }
            await withCheckedContinuation { prefixWaiters[prefix.key, default: []].append($0) }
        }
    }

    /// Wakes the calls waiting on `prefix`. If the first call failed, the next becomes the first.
    private func finishWriting(_ prefix: Prefix) {
        writing.remove(prefix.key)
        for waiter in prefixWaiters.removeValue(forKey: prefix.key) ?? [] { waiter.resume() }
    }

    /// Waits out a cooldown, and for the bucket to hold one request and `tokens`.
    private func waitForTurn(_ tokens: Int) async throws(CancellationError) {
        while true {
            let now = clock.now
            let cooldown = coolingUntil.flatMap { $0 > now ? $0 : nil }
            let ready = [cooldown, requests.readyAt(1, now: now), inputTokens.readyAt(Double(tokens), now: now)].compactMap { $0 }.max()
            guard let ready else { return }
            try await sleep(until: ready)
        }
    }

    private func sleep(until deadline: Date) async throws(CancellationError) {
        do {
            try await clock.sleep(until: deadline)
        } catch {
            throw CancellationError()
        }
        if Task.isCancelled { throw CancellationError() }
    }

    static func seconds(_ ttl: PromptCacheTTL) -> TimeInterval {
        ttl == .oneHour ? 3600 : 300
    }

    static func interval(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// One rate limit as a bucket that refills evenly from what remained to full at the reset time.
    struct Bucket {
        var limit: Double?
        var remaining: Double?
        var updated = Date.distantPast
        var reset: Date?

        mutating func update(_ reported: RateLimits.Limit, now: Date) {
            guard let remaining = reported.remaining else { return }
            limit = reported.limit.map(Double.init)
            self.remaining = Double(remaining)
            updated = now
            reset = reported.reset
        }

        func available(at now: Date) -> Double? {
            guard let remaining else { return nil }
            guard let limit else { return reset.map { now >= $0 } == true ? nil : remaining }
            guard let reset, now < reset else { return limit }
            let span = reset.timeIntervalSince(updated)
            guard span > 0 else { return limit }
            return min(limit, remaining + (limit - remaining) * max(0, now.timeIntervalSince(updated)) / span)
        }

        func fraction(at now: Date) -> Double? {
            guard let limit, limit > 0, let available = available(at: now) else { return nil }
            return available / limit
        }

        /// When `amount` will be there, or nil when it is now.
        func readyAt(_ amount: Double, now: Date) -> Date? {
            guard let available = available(at: now), let remaining else { return nil }
            let needed = min(amount, limit ?? amount)
            // Within half a token or request: counts are whole numbers.
            guard available + 0.5 < needed else { return nil }
            guard let reset, reset > now else { return nil }
            guard let limit, limit > remaining else { return reset }
            let perSecond = (limit - remaining) / reset.timeIntervalSince(updated)
            let ready = updated.addingTimeInterval((needed - remaining) / perSecond)
            return min(max(ready, now.addingTimeInterval(0.001)), reset)
        }

        /// Spends `amount` now. The bucket refills from what is left, still full at the reset time.
        mutating func take(_ amount: Double, now: Date) {
            guard let available = available(at: now) else { return }
            if let reset, now >= reset {
                // Past the reset: the limit is unknown until the next response reports it.
                remaining = nil
                return
            }
            remaining = available - amount
            updated = now
        }
    }
}
