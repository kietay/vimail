import Foundation
import MailCore
import VimailLog

/// Calendar OAuth scopes. Calendar is optional: mail works when they are not granted.
public enum CalendarScope {
    /// View and edit events on all your calendars.
    public static let events = "https://www.googleapis.com/auth/calendar.events"
    /// View events on all your calendars. Debug builds ask only for this, so they cannot change a calendar.
    public static let eventsReadonly = "https://www.googleapis.com/auth/calendar.events.readonly"
    /// See the list of calendars you're subscribed to.
    public static let calendarListReadonly = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    /// See the availability on Google calendars you have access to. `freeBusy.query` does not accept `calendar.events`.
    public static let freeBusy = "https://www.googleapis.com/auth/calendar.events.freebusy"
    static let full = "https://www.googleapis.com/auth/calendar"
    static let readonly = "https://www.googleapis.com/auth/calendar.readonly"

    /// True when the granted scopes can read events and the calendar list.
    public static func allowsReading(_ scopes: [String]) -> Bool {
        let events = scopes.contains(self.events) || scopes.contains(eventsReadonly) || scopes.contains(full) || scopes.contains(readonly)
        let list = scopes.contains(calendarListReadonly) || scopes.contains(full) || scopes.contains(readonly)
        return events && list
    }

    /// True when the granted scopes can change events (answers, creates, edits).
    public static func allowsChanges(_ scopes: [String]) -> Bool {
        scopes.contains(events) || scopes.contains(full)
    }
}

/// A small Calendar v3 REST client: bearer token, gzip, pacing, retries and error mapping.
/// The same request loop as `GmailAPI`, with Calendar's errors: 409 duplicate, 410 gone, 412 changed.
struct GoogleCalendarAPI: Sendable {
    /// Every request: method, path, status, size, duration. Never bodies, titles or addresses.
    static let log = Log("calendar")
    static let root = URL(string: "https://www.googleapis.com/calendar/v3/")!

    let transport: any HTTPTransport
    let tokens: GoogleTokenSource
    let pacer: QuotaPacer
    var maxAttempts = 4
    var maxRateLimitedAttempts = 7

    func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = [], priority: QuotaPacer.Priority = .interactive) async throws -> T {
        let data = try await perform("GET", path, query: query, priority: priority)
        return try Self.decode(T.self, from: data, path: path)
    }

    func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], json: some Encodable, ifMatch: String? = nil) async throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try await perform(method, path, query: query, body: try encoder.encode(json), ifMatch: ifMatch)
        return try Self.decode(T.self, from: data, path: path)
    }

    @discardableResult
    func perform(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, ifMatch: String? = nil,
        priority: QuotaPacer.Priority = .interactive
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
            await pacer.acquire(1, priority: priority)
            let token = try await tokens.accessToken()
            await pacer.enter(priority: priority)
            let clock = Stopwatch()
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(GmailAPI.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
            if let body {
                request.httpBody = body
                request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            }

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.data(for: request)
                await pacer.leave()
            } catch {
                await pacer.leave()
                let mapped = GmailAPI.providerError(for: error)
                if mapped.isTransient, attempt < maxAttempts {
                    let delay = GmailAPI.backoffDelay(attempt: attempt, retryAfter: nil)
                    Self.log.notice("\(label) failed after \(clock.text) (attempt \(attempt)): \(GmailAPI.describe(error)). Retrying in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                    continue
                }
                Self.log.error("\(label) failed after \(clock.text) (attempt \(attempt)): \(GmailAPI.describe(error))")
                throw mapped
            }

            let attemptNote = attempt > 1 ? " (attempt \(attempt))" : ""
            if (200..<300).contains(response.statusCode) {
                Self.log.debug("\(label) → \(response.statusCode), \(GmailAPI.bytes(data.count)), \(clock.text)\(attemptNote)")
                return data
            }
            if response.statusCode == 401 {
                guard !renewedToken else {
                    Self.log.error("\(label) → 401 again after a fresh token: signed out")
                    throw ProviderError.unauthorized
                }
                renewedToken = true
                await tokens.invalidate()
                continue
            }
            let google = GmailAPI.googleReason(data)
            let reasons = Self.reasons(data)
            switch response.statusCode {
            case 409 where reasons.contains("duplicate"):
                Self.log.notice("\(label) → 409 duplicate after \(clock.text)")
                throw CalendarProviderError.duplicate
            case 410:
                Self.log.notice("\(label) → 410 after \(clock.text): \(google)")
                throw ProviderError.cursorExpired
            case 412:
                Self.log.notice("\(label) → 412 after \(clock.text): the event changed")
                throw CalendarProviderError.changedElsewhere
            case 403 where !reasons.isDisjoint(with: ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]):
                Self.log.error("\(label) → 403 after \(clock.text): calendar access not granted (\(google))")
                throw CalendarProviderError.notConnected
            case 403 where !reasons.isDisjoint(with: ["accessNotConfigured", "SERVICE_DISABLED"]):
                Self.log.error("\(label) → 403 after \(clock.text): \(google)")
                throw ProviderError.rejected("The Google Calendar API is not enabled for your Google Cloud project. Enable it in Google Cloud Console → APIs & Services, next to the Gmail API.")
            default:
                break
            }
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let error = GmailAPI.providerError(status: response.statusCode, body: data, retryAfter: retryAfter)
            if case .rateLimited = error {
                await pacer.rateLimited(retryAfter: retryAfter, reason: google)
                if attempt < maxRateLimitedAttempts { continue }
            } else if error.isTransient, attempt < maxAttempts {
                let delay = GmailAPI.backoffDelay(attempt: attempt, retryAfter: retryAfter)
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

    /// "GET calendars/…/events?syncToken=…": calendar IDs shortened, since shared calendars are other people's addresses.
    static func describe(_ method: String, _ path: String, _ query: [URLQueryItem]) -> String {
        let short = path.split(separator: "/").map { part in part.contains("@") ? "…" : String(part.prefix(28)) }.joined(separator: "/")
        return GmailAPI.describe(method, short, query)
    }

    static func reasons(_ body: Data) -> Set<String> {
        guard let failure = (try? JSONDecoder().decode(GmailAPI.Failure.self, from: body))?.error else { return [] }
        var reasons = Set((failure.errors ?? []).compactMap(\.reason))
        if let status = failure.status { reasons.insert(status) }
        return reasons
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.error("Unexpected response from \(describe("GET", path, [])) (\(GmailAPI.bytes(data.count))): \(String(describing: error))")
            throw ProviderError.rejected("Unexpected response from Google Calendar")
        }
    }
}
