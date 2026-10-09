import Foundation
import MailCore

/// A failed call to the Anthropic API. Separate from `ProviderError`, which is about mail providers.
///
/// Descriptions name the HTTP status and what it means, never the response body: error messages can
/// quote the request.
public enum AIError: Error, Sendable, Hashable {
    /// No API key is saved.
    case noKey
    /// No network: the request never reached Anthropic.
    case offline
    /// The connection timed out or dropped. Often the network, so not an attempt for the engine; but
    /// the request may have reached Anthropic, so its input estimate counts as spent.
    case interrupted
    case cancelled
    /// 401: the key is wrong or revoked.
    case authentication
    /// 402, a 429 for the spend limit, or a 400 for a credit balance that is too low.
    case billing
    /// 403: the key may not use this model.
    case permission
    /// 404: the model does not exist, or no longer does.
    case notFound
    /// 429.
    case rateLimited(retryAfter: Duration?)
    /// 529: Anthropic is overloaded.
    case overloaded(retryAfter: Duration?)
    /// 500, 504 and other 5xx.
    case server(status: Int, retryAfter: Duration?)
    /// 413.
    case tooLarge
    /// A 400 for this request. The fingerprint tells identical error messages apart without keeping their text.
    case badRequest(fingerprint: String)
    case unexpectedStatus(Int)
    /// A success whose body did not decode.
    case malformedResponse

    /// Retrying later can succeed without anyone acting.
    public var isTransient: Bool {
        switch self {
        case .offline, .interrupted, .rateLimited, .overloaded, .server: true
        default: false
        }
    }

    /// Anthropic may have processed (and billed) the request.
    var mayHaveBilled: Bool {
        switch self {
        case .interrupted, .cancelled, .malformedResponse: true
        default: false
        }
    }

    /// What the rules engine does about it (design §3.6). A 400 is only `invalid` here: `ClaudeJudge`
    /// first retries without fallbacks and watches for the same error on other emails.
    public var judgeError: JudgeError {
        switch self {
        case .noKey: .paused(.noKey)
        case .offline, .interrupted, .cancelled: .offline
        case .authentication: .paused(.badKey)
        case .billing: .paused(.billing)
        case .permission, .notFound: .paused(.modelUnavailable)
        case .rateLimited(let retryAfter), .overloaded(let retryAfter), .server(_, let retryAfter): .transient(retryAfter: retryAfter)
        case .tooLarge: .invalid(code: "http_413")
        case .badRequest: .invalid(code: "http_400")
        case .unexpectedStatus(let status): .invalid(code: "http_\(status)")
        case .malformedResponse: .invalid(code: "bad_response")
        }
    }
}

extension AIError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? {
        switch self {
        case .noKey: "No Anthropic API key"
        case .offline: "Offline"
        case .interrupted: "The connection to Anthropic timed out or dropped"
        case .cancelled: "Cancelled"
        case .authentication: "The Anthropic API key was rejected (HTTP 401)"
        case .billing: "Anthropic billing: no credit or spend limit reached"
        case .permission: "The API key may not use this model (HTTP 403)"
        case .notFound: "Model not found (HTTP 404)"
        case .rateLimited: "Rate limited by Anthropic (HTTP 429)"
        case .overloaded: "Anthropic is overloaded (HTTP 529)"
        case .server(let status, _): "Anthropic server error (HTTP \(status))"
        case .tooLarge: "Request too large (HTTP 413)"
        case .badRequest: "Anthropic rejected the request (HTTP 400)"
        case .unexpectedStatus(let status): "Unexpected response from Anthropic (HTTP \(status))"
        case .malformedResponse: "Unreadable response from Anthropic"
        }
    }

    // `String(describing:)` would otherwise print associated values.
    public var description: String { errorDescription ?? "Anthropic error" }
}
