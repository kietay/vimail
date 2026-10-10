import CryptoKit
import Foundation
import HTTPKit
import MailCore
import VimailLog

/// The Anthropic API over plain HTTP: the Messages endpoint for rules, and a free model lookup that
/// checks a key. Retries, pacing and spend belong to `ClaudeJudge`.
public struct AnthropicClient: Sendable {
    /// Every request: method, path, status, sizes, duration, request-id and error type. Never bodies,
    /// prompts, model output or the key.
    static let log = Log("anthropic")
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com/")!
    static let apiVersion = "2023-06-01"
    /// Pairs with `fallbacks: "default"`; the array form needs a different date.
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let timeout: TimeInterval = 120

    let transport: any HTTPTransport
    let baseURL: URL
    let apiKey: @Sendable () async -> String?

    /// - Parameter apiKey: the saved key, or nil when there is none. Read for every request, so a
    ///   replaced key takes effect at once.
    public init(transport: any HTTPTransport = URLSessionTransport(), baseURL: URL = AnthropicClient.defaultBaseURL, apiKey: @escaping @Sendable () async -> String?) {
        self.transport = transport
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public func hasKey() async -> Bool {
        await key() != nil
    }

    private func key() async -> String? {
        guard let key = await apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// A Messages API answer with what its headers said.
    struct Reply: Sendable {
        var message: MessagesResponse
        var requestID: String?
        var rateLimits: RateLimits
    }

    /// `POST /v1/messages`. The fallback beta header goes with the request exactly when it asks for fallbacks.
    func createMessage(_ request: MessagesRequest) async throws(AIError) -> Reply {
        guard let key = await key() else { throw .noKey }
        let (data, response) = try await perform("POST", "v1/messages", body: request.encoded(), beta: request.fallbacks == nil ? nil : Self.fallbackBeta, key: key)
        do {
            let message = try JSONDecoder().decode(MessagesResponse.self, from: data)
            return Reply(message: message, requestID: response.value(forHTTPHeaderField: "request-id"), rateLimits: RateLimits(response))
        } catch {
            Self.log.error("POST v1/messages: unreadable response (\(Self.bytes(data.count)), \(Self.decodingProblem(error)))")
            throw .malformedResponse
        }
    }

    /// Whether a key works for a model: `GET /v1/models/{id}`, which needs no credit.
    public enum KeyCheck: Sendable, Hashable {
        case valid
        /// No key, or Anthropic rejected it.
        case badKey
        /// The key works, but not with this model.
        case modelUnavailable
        /// Anthropic could not be reached, or could not answer right now. Try again later.
        case offline
    }

    /// Checks `candidate` (a key about to be saved), or the saved key when it is nil. A blank key is bad
    /// without asking.
    public func verifyKey(_ candidate: String? = nil, model: ClaudeModel) async -> KeyCheck {
        let key: String?
        if let candidate { key = candidate.trimmingCharacters(in: .whitespacesAndNewlines) } else { key = await self.key() }
        guard let key, !key.isEmpty else { return .badKey }
        do {
            _ = try await perform("GET", "v1/models/\(model.id)", body: nil, beta: nil, key: key)
            return .valid
        } catch {
            switch error {
            case .authentication: return .badKey
            case .permission, .notFound: return .modelUnavailable
            default: return .offline
            }
        }
    }

    private func perform(_ method: String, _ path: String, body: Data?, beta: String?, key: String) async throws(AIError) -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = body

        let label = "\(method) \(path)"
        let clock = Stopwatch()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            let mapped = Self.aiError(for: error)
            Self.log.notice("\(label) failed after \(clock.text): \(Self.describe(error))")
            throw mapped
        }

        let requestID = response.value(forHTTPHeaderField: "request-id").map { ", request \($0)" } ?? ""
        let sizes = Self.bytes(data.count) + (body.map { ", sent \(Self.bytes($0.count))" } ?? "")
        if (200..<300).contains(response.statusCode) {
            Self.log.debug("\(label) → \(response.statusCode), \(sizes), \(clock.text)\(requestID)")
            return (data, response)
        }
        let failure = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
        let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(Self.duration)
        let error = Self.aiError(status: response.statusCode, failure: failure, retryAfter: retryAfter)
        let type = failure?.type ?? "no error type"
        let line = "\(label) → \(response.statusCode) \(type) after \(clock.text)\(requestID)\(retryAfter.map { ", retry after \($0)" } ?? "")"
        if error.isTransient { Self.log.notice(line) } else { Self.log.error(line) }
        throw error
    }

    // MARK: - Errors

    static func aiError(for error: any Error) -> AIError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .offline }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut, .networkConnectionLost: return .interrupted
        default: return .offline
        }
    }

    /// Billing is checked before the generic 400: an account without credit answers every request
    /// with a 400 `invalid_request_error` about its "credit balance", and a workspace or organization
    /// past the usage limit you set with one saying "You have reached your specified API usage limits".
    static func aiError(status: Int, failure: ErrorResponse.Detail?, retryAfter: Duration?) -> AIError {
        let message = failure?.message ?? ""
        let spendLimit = failure?.details?.errorCode == "enforced_spend_limit_reached" || message.localizedCaseInsensitiveContains("spend limit")
        let billing400 = ["credit balance", "usage limit"].contains { message.localizedCaseInsensitiveContains($0) }
        if failure?.type == "billing_error" || (status == 400 && billing400) {
            return .billing
        }
        switch status {
        case 400: return .badRequest(fingerprint: fingerprint(message))
        case 401: return .authentication
        case 402: return .billing
        case 403: return .permission
        case 404: return .notFound
        case 413: return .tooLarge
        case 429 where spendLimit: return .billing
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 529: return .overloaded(retryAfter: retryAfter)
        case 500...599: return .server(status: status, retryAfter: retryAfter)
        default: return .unexpectedStatus(status)
        }
    }

    /// A short hash of an error message: equal messages, equal fingerprints.
    static func fingerprint(_ message: String) -> String {
        SHA256.hash(data: Data(message.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `retry-after` in seconds.
    static func duration(_ header: String) -> Duration? {
        guard let seconds = Double(header.trimmingCharacters(in: .whitespaces)), seconds >= 0, seconds.isFinite else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    /// The transport error with its code, for example "URLError -1001 (timed out)".
    static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue) (\(urlError.localizedDescription))"
        }
        return String(describing: type(of: error))
    }

    /// Where decoding failed, without the values.
    static func decodingProblem(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: type(of: error)) }
        let path: [any CodingKey]
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context), .dataCorrupted(let context):
            path = context.codingPath
        @unknown default:
            path = []
        }
        let location = path.map(\.stringValue).joined(separator: ".")
        return location.isEmpty ? "at the top level" : "at \(location)"
    }

    static func bytes(_ count: Int) -> String {
        count < 1024 ? "\(count) B" : count < 1_048_576 ? String(format: "%.1f KB", Double(count) / 1024) : String(format: "%.1f MB", Double(count) / 1_048_576)
    }
}

/// What the `anthropic-ratelimit-*` headers say about the key's limits right now.
public struct RateLimits: Sendable, Hashable {
    public struct Limit: Sendable, Hashable {
        public var limit: Int?
        public var remaining: Int?
        /// When the limit is fully replenished.
        public var reset: Date?

        public init(limit: Int? = nil, remaining: Int? = nil, reset: Date? = nil) {
            self.limit = limit
            self.remaining = remaining
            self.reset = reset
        }
    }

    public var requests = Limit()
    public var inputTokens = Limit()
    public var outputTokens = Limit()
    public var tokens = Limit()

    public init(requests: Limit = Limit(), inputTokens: Limit = Limit(), outputTokens: Limit = Limit(), tokens: Limit = Limit()) {
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.tokens = tokens
    }

    init(_ response: HTTPURLResponse) {
        func limit(_ name: String) -> Limit {
            let header = { (suffix: String) in response.value(forHTTPHeaderField: "anthropic-ratelimit-\(name)-\(suffix)") }
            return Limit(
                limit: header("limit").flatMap { Int($0) },
                remaining: header("remaining").flatMap { Int($0) },
                reset: header("reset").flatMap(Self.date)
            )
        }
        requests = limit("requests")
        inputTokens = limit("input-tokens")
        outputTokens = limit("output-tokens")
        tokens = limit("tokens")
    }

    /// RFC 3339, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}
