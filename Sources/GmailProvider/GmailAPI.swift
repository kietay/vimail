import Foundation
import MailCore
import VimailLog

/// Sends HTTP requests. `URLSessionTransport` in the app; tests use a scripted fake.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.default
        // Slow networks (plane wifi) need patience; offline is detected by URLError, not by waiting.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.server("No HTTP response") }
        return (data, http)
    }
}

/// A small Gmail REST client: bearer token, gzip, quota pacing, retries and error mapping.
struct GmailAPI: Sendable {
    /// Every request: method, path, status, size, duration, attempt. Never bodies or tokens.
    static let log = Log("gmail")
    static let root = URL(string: "https://gmail.googleapis.com/")!
    /// Google only compresses responses when the user agent contains "gzip".
    static let userAgent = "vimail/0.1 (gzip)"

    enum Retry {
        /// Safe to repeat: reads and idempotent changes.
        case idempotent
        /// Never repeated here (sending). The sync engine decides, after checking what arrived.
        case never
    }

    let transport: any HTTPTransport
    let tokens: GoogleTokenSource
    let pacer: QuotaPacer
    var maxAttempts = 4
    /// Rate limits clear by themselves, so they get more attempts than other failures.
    var maxRateLimitedAttempts = 7

    func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = [], cost: Int, priority: QuotaPacer.Priority = .interactive) async throws -> T {
        let data = try await perform("GET", path, query: query, cost: cost, priority: priority)
        return try Self.decode(T.self, from: data, path: path)
    }

    func send<T: Decodable>(_ method: String, _ path: String, json: some Encodable, cost: Int, retry: Retry = .idempotent) async throws -> T {
        let data = try await perform(method, path, body: try JSONEncoder().encode(json), contentType: "application/json; charset=UTF-8", cost: cost, retry: retry)
        return try Self.decode(T.self, from: data, path: path)
    }

    func sendWithoutResult(_ method: String, _ path: String, json: (some Encodable)? = nil as String?, cost: Int) async throws {
        let body = try json.map { try JSONEncoder().encode($0) }
        _ = try await perform(method, path, body: body, contentType: body == nil ? nil : "application/json; charset=UTF-8", cost: cost)
    }

    @discardableResult
    func perform(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String? = nil,
        cost: Int, retry: Retry = .idempotent, timeout: TimeInterval = 60, priority: QuotaPacer.Priority = .interactive
    ) async throws -> Data {
        var components = URLComponents(url: Self.root.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ProviderError.rejected("Invalid request \(path)") }

        let label = Self.describe(method, path, query)
        var attempt = 0
        var renewedToken = false
        while true {
            attempt += 1
            try Task.checkCancellation()
            await pacer.acquire(cost, priority: priority)
            let token = try await tokens.accessToken()
            await pacer.enter(priority: priority)
            let clock = Stopwatch()
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            if let body {
                request.httpBody = body
                if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            }

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.data(for: request)
                await pacer.leave()
            } catch {
                await pacer.leave()
                let mapped = Self.providerError(for: error)
                if mapped.isTransient, retry == .idempotent, attempt < maxAttempts {
                    let delay = Self.backoffDelay(attempt: attempt, retryAfter: nil)
                    Self.log.notice("\(label) failed after \(clock.text) (attempt \(attempt)): \(Self.describe(error)). Retrying in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                    continue
                }
                Self.log.error("\(label) failed after \(clock.text) (attempt \(attempt)): \(Self.describe(error))")
                throw mapped
            }

            let sizes = Self.bytes(data.count) + (body.map { ", sent \(Self.bytes($0.count))" } ?? "")
            let attemptNote = attempt > 1 ? " (attempt \(attempt))" : ""
            if (200..<300).contains(response.statusCode) {
                Self.log.debug("\(label) → \(response.statusCode), \(sizes), \(clock.text)\(attemptNote)")
                return data
            }
            if response.statusCode == 401 {
                // The access token expired early or was revoked. Refresh once, then give up.
                guard !renewedToken else {
                    Self.log.error("\(label) → 401 again after a fresh token: signed out")
                    throw ProviderError.unauthorized
                }
                Self.log.notice("\(label) → 401 after \(clock.text): refreshing the access token")
                renewedToken = true
                await tokens.invalidate()
                continue
            }
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let error = Self.providerError(status: response.statusCode, body: data, retryAfter: retryAfter)
            let google = Self.googleReason(data)
            if case .rateLimited = error {
                // Slow every request down, not just this one: the limit is per user, across all requests.
                await pacer.rateLimited(retryAfter: retryAfter, reason: google)
                if attempt < maxRateLimitedAttempts {
                    Self.log.notice("\(label) → \(response.statusCode) rate limited\(attemptNote) (\(google)). Retrying after the pause")
                    continue
                }
            } else if error.isTransient, retry == .idempotent, attempt < maxAttempts {
                let delay = Self.backoffDelay(attempt: attempt, retryAfter: retryAfter)
                Self.log.notice("\(label) → \(response.statusCode) after \(clock.text)\(attemptNote) (\(google)). Retrying in \(String(format: "%.1f", delay))s")
                try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                continue
            }
            if response.statusCode == 404 {
                Self.log.debug("\(label) → 404, \(clock.text)")
            } else {
                Self.log.error("\(label) → \(response.statusCode) after \(clock.text)\(attemptNote): \(google)")
            }
            throw error
        }
    }

    /// "GET threads?labelIds=INBOX&maxResults=100": the path below users/me, long values shortened.
    static func describe(_ method: String, _ path: String, _ query: [URLQueryItem]) -> String {
        let short = path.replacingOccurrences(of: "gmail/v1/users/me/", with: "")
        guard !query.isEmpty else { return "\(method) \(short)" }
        let items = query.map { item -> String in
            let value = item.value ?? ""
            return "\(item.name)=\(value.count > 16 ? value.prefix(12) + "…" : Substring(value))"
        }
        return "\(method) \(short)?\(items.joined(separator: "&"))"
    }

    /// The transport error with its code, for example "URLError -1001 (timed out)".
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue) (\(urlError.localizedDescription))"
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Gmail's reason and message from an error body, for example
    /// "rateLimitExceeded: Too many concurrent requests for user".
    static func googleReason(_ body: Data) -> String {
        guard let failure = (try? JSONDecoder().decode(Failure.self, from: body))?.error else {
            return body.isEmpty ? "no details" : "\(body.count) bytes, not JSON"
        }
        let reasons = (failure.errors ?? []).compactMap(\.reason).joined(separator: ",")
        return [reasons.isEmpty ? failure.status : reasons, failure.message].compactMap { $0 }.joined(separator: ": ")
    }

    static func bytes(_ count: Int) -> String {
        count < 1024 ? "\(count) B" : count < 1_048_576 ? String(format: "%.1f KB", Double(count) / 1024) : String(format: "%.1f MB", Double(count) / 1_048_576)
    }

    /// A response that does not decode will not decode on a retry either, so it is "rejected".
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.error("Unexpected response from \(path) (\(bytes(data.count))): \(String(describing: error))")
            throw ProviderError.rejected("Unexpected response from Gmail (\(path))")
        }
    }

    /// Seconds to wait before attempt `attempt + 1`: 1, 2.5, 6.3 … (or Retry-After), at most 30, plus jitter.
    static func backoffDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        min(retryAfter ?? pow(2.5, Double(attempt - 1)), 30) + Double.random(in: 0...0.5)
    }

    // MARK: - Errors

    struct Failure: Decodable {
        struct Body: Decodable {
            struct Item: Decodable { var reason: String? }
            var code: Int?
            var message: String?
            var status: String?
            var errors: [Item]?
        }
        var error: Body?
    }

    static func providerError(for error: Error) -> ProviderError {
        if let error = error as? ProviderError { return error }
        if let urlError = error as? URLError {
            // Every transport failure (no route, DNS, timeouts, captive portals) is "offline": retry later.
            return .offline(urlError.code == .timedOut ? "The network is too slow right now" : urlError.localizedDescription)
        }
        if error is CancellationError { return .offline("Cancelled") }
        return .server(error.localizedDescription)
    }

    static func providerError(status: Int, body: Data, retryAfter: TimeInterval?) -> ProviderError {
        let failure = (try? JSONDecoder().decode(Failure.self, from: body))?.error
        let message = failure?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let reasons = Set((failure?.errors ?? []).compactMap(\.reason))
        switch status {
        case 403 where !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded", "concurrentLimitExceeded"]):
            return .rateLimited(retryAfter: retryAfter)
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 404:
            return .notFound(message)
        case 500, 502, 503, 504:
            return .server(message)
        default:
            return .rejected(message)
        }
    }
}

/// Paces requests to stay under Gmail's per-user quota ("units per minute per user") with a cap on
/// concurrent requests.
///
/// The real limit depends on the Google Cloud project: an unverified project in testing measured about
/// 900 units a minute, far below the documented 15,000. So the pacer learns it, like TCP: it starts at
/// 12 units/s, speeds up by a quarter every 20 s until Gmail first says "rate limited", then halves once
/// per minute of rejections, waits for the window to drain, and afterwards creeps up by 1 unit/s every 30 s.
///
/// Bulk downloads yield to everything else: an archive or a send never waits behind the background download.
actor QuotaPacer {
    enum Priority { case bulk, interactive }

    private let maxRate: Double
    private let minRate: Double = 3
    private var unitsPerSecond: Double
    private var slowStart = true
    private let burst: Double
    private var available: Double
    private var updated = ContinuousClock.now
    private var pausedUntil: ContinuousClock.Instant?
    private var lastHalving: ContinuousClock.Instant?
    private var lastChange = ContinuousClock.now
    private let maxConcurrent: Int
    private var concurrent: Int
    private var inFlight = 0
    private var interactiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var bulkWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - unitsPerSecond: the starting rate (12 units/s is 720 a minute).
    ///   - maxRate: Gmail's documented ceiling (250 units/s).
    init(unitsPerSecond: Double = 12, maxRate: Double = 250, burst: Double = 40, maxConcurrent: Int = 4) {
        self.maxRate = maxRate
        self.unitsPerSecond = min(unitsPerSecond, maxRate)
        self.burst = burst
        available = burst
        self.maxConcurrent = maxConcurrent
        concurrent = maxConcurrent
    }

    var currentLimits: (unitsPerSecond: Double, concurrent: Int) { (unitsPerSecond, concurrent) }

    /// Waits until a request of `cost` units may start. Interactive requests do not wait for the
    /// rate (their cost delays bulk requests instead); every request waits out a rate-limit pause.
    func acquire(_ cost: Int, priority: Priority = .interactive) async {
        if let pausedUntil, pausedUntil > .now {
            try? await Task.sleep(until: pausedUntil, clock: .continuous)
        }
        let now = ContinuousClock.now
        probe(now)
        let elapsed = now - updated
        updated = now
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        available = min(burst, available + seconds * unitsPerSecond) - Double(cost)
        // Negative means reserved ahead: bulk requests wait until the bucket refills to zero.
        if available < 0, priority == .bulk {
            let wait = Int(-available / unitsPerSecond * 1000)
            if wait >= 5_000 { GmailAPI.log.debug("Pacing: next download in \(wait)ms (\(Int(unitsPerSecond * 60)) units/min)") }
            try? await Task.sleep(for: .milliseconds(wait))
        }
    }

    /// Probes for more room while Gmail has not complained for a while.
    private func probe(_ now: ContinuousClock.Instant) {
        let interval: Duration = slowStart ? .seconds(20) : .seconds(30)
        guard now - lastChange > interval, unitsPerSecond < maxRate || concurrent < maxConcurrent else { return }
        unitsPerSecond = min(maxRate, slowStart ? unitsPerSecond * 1.25 : unitsPerSecond + 1)
        concurrent = min(maxConcurrent, concurrent + 1)
        lastChange = now
        GmailAPI.log.debug("Pacing: \(Int(unitsPerSecond * 60)) units/min, \(concurrent) request(s) at a time")
    }

    /// Gmail answered "rate limited": pause everything until the minute window drains.
    func rateLimited(retryAfter: TimeInterval?, reason: String) {
        let now = ContinuousClock.now
        // Requests already in flight report the same limit: one pause covers them.
        if let pausedUntil, pausedUntil > now { return }
        // Rejections continue until the window drains, so slow down once per minute, not per rejection.
        let halve = lastHalving.map { now - $0 > .seconds(60) } ?? true
        if halve {
            slowStart = false
            unitsPerSecond = max(minRate, unitsPerSecond / 2)
            concurrent = max(1, concurrent - 1)
            lastHalving = now
        }
        let pause = min(max(retryAfter ?? 20, 1), 60)
        pausedUntil = now + .milliseconds(Int(pause * 1000))
        lastChange = now
        available = min(available, 0)
        GmailAPI.log.notice("Gmail rate limit (\(reason)): pausing \(Int(pause))s\(halve ? ", then \(Int(unitsPerSecond * 60)) units/min and \(concurrent) request(s) at a time" : "")")
    }

    /// Waits for a request slot. Interactive requests get the next free slot before bulk ones.
    func enter(priority: Priority = .interactive) async {
        if inFlight < concurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            if priority == .interactive { interactiveWaiters.append(continuation) } else { bulkWaiters.append(continuation) }
        }
    }

    func leave() {
        inFlight -= 1
        // Fill free slots (more than one when the limit was just raised), interactive first.
        while inFlight < concurrent, !(interactiveWaiters.isEmpty && bulkWaiters.isEmpty) {
            inFlight += 1
            (interactiveWaiters.isEmpty ? bulkWaiters.removeFirst() : interactiveWaiters.removeFirst()).resume()
        }
    }
}
