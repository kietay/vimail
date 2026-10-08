import CryptoKit
import Foundation
import MailCore
import VimailLog

/// Gmail OAuth scopes.
public enum GmailScope {
    /// Read, label, archive, trash and send. No permanent deletion.
    public static let modify = "https://www.googleapis.com/auth/gmail.modify"
    /// Read only. Google rejects every change made with it.
    public static let readonly = "https://www.googleapis.com/auth/gmail.readonly"
    public static let full = "https://mail.google.com/"

    /// True when the granted scopes allow changes (labels, archive, send).
    public static func allowsChanges(_ scopes: [String]) -> Bool {
        scopes.contains(modify) || scopes.contains(full)
    }
}

/// An OAuth client from Google Cloud Console ("Desktop app" type), as in the downloaded
/// `client_secret_….json`. Google does not treat a desktop client's secret as confidential,
/// but vimail still keeps the file private (mode 600).
public struct GoogleOAuthClient: Codable, Hashable, Sendable {
    public var clientID: String
    public var clientSecret: String
    public var tokenURI: URL

    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let defaultTokenURI = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    public init(clientID: String, clientSecret: String, tokenURI: URL = GoogleOAuthClient.defaultTokenURI) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tokenURI = tokenURI
    }

    /// Parses the JSON that Google Cloud Console downloads: `{"installed": {...}}` (or `"web"`).
    public init(clientSecretJSON data: Data) throws {
        struct Entry: Decodable {
            var client_id: String
            var client_secret: String?
            var token_uri: String?
        }
        struct File: Decodable {
            var installed: Entry?
            var web: Entry?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data), let entry = file.installed ?? file.web else {
            throw GoogleOAuthError.invalidClientFile
        }
        guard let secret = entry.client_secret, !secret.isEmpty else { throw GoogleOAuthError.invalidClientFile }
        self.init(
            clientID: entry.client_id, clientSecret: secret,
            tokenURI: entry.token_uri.flatMap(URL.init(string:)) ?? Self.defaultTokenURI
        )
    }
}

public enum GoogleOAuthError: Error, Equatable, LocalizedError {
    case invalidClientFile
    case cancelled
    case timedOut
    case denied(String)
    case stateMismatch
    case missingRefreshToken
    case missingScope(String)
    case tokenEndpoint(String)

    public var errorDescription: String? {
        switch self {
        case .invalidClientFile: "This is not a Google OAuth client file. In Google Cloud Console, download the JSON of a “Desktop app” OAuth client."
        case .cancelled: "Sign-in cancelled."
        case .timedOut: "Sign-in timed out. Try again."
        case .denied(let reason): "Google sign-in failed: \(reason)."
        case .stateMismatch: "The sign-in response did not match the request. Try again."
        case .missingRefreshToken: "Google did not return a refresh token. Try again."
        case .missingScope: "Gmail access was not granted. Sign in again and allow access to Gmail."
        case .tokenEndpoint(let reason): "Google sign-in failed: \(reason)"
        }
    }
}

/// What vimail stores after sign-in. Access tokens are never stored; they are refreshed when needed.
public struct GoogleCredential: Codable, Hashable, Sendable {
    public var email: String
    public var refreshToken: String
    public var scopes: [String]
    public var client: GoogleOAuthClient

    public init(email: String, refreshToken: String, scopes: [String], client: GoogleOAuthClient) {
        self.email = email
        self.refreshToken = refreshToken
        self.scopes = scopes
        self.client = client
    }

    public var allowsChanges: Bool { GmailScope.allowsChanges(scopes) }

    /// Reads the "authorized user" JSON that Google's Python and Node libraries write (`token.json`).
    public init(authorizedUserJSON data: Data) throws {
        struct File: Decodable {
            var client_id: String
            var client_secret: String
            var refresh_token: String
            var token_uri: String?
            var scopes: [String]?
            var account: String?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { throw GoogleOAuthError.invalidClientFile }
        self.init(
            email: file.account ?? "",
            refreshToken: file.refresh_token,
            scopes: file.scopes ?? [],
            client: GoogleOAuthClient(
                clientID: file.client_id, clientSecret: file.client_secret,
                tokenURI: file.token_uri.flatMap(URL.init(string:)) ?? GoogleOAuthClient.defaultTokenURI
            )
        )
    }
}

/// One browser sign-in attempt: the authorization URL with PKCE (RFC 7636) and a state value.
public struct GoogleAuthorizationRequest: Sendable {
    public let client: GoogleOAuthClient
    public let scopes: [String]
    public let redirectURI: String
    public let state: String
    public let codeVerifier: String
    public let loginHint: String?

    public init(client: GoogleOAuthClient, scopes: [String], redirectURI: String, loginHint: String? = nil) {
        self.client = client
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.loginHint = loginHint
        state = Self.randomToken(bytes: 24)
        codeVerifier = Self.randomToken(bytes: 48)
    }

    /// The page to open in the browser.
    public var url: URL {
        var components = URLComponents(url: GoogleOAuthClient.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // A refresh token every time, so a new sign-in always replaces an expired one.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    /// Validates the redirect's query and returns the authorization code.
    public func code(fromCallback query: [String: String]) throws -> String {
        if let error = query["error"] {
            throw error == "access_denied" ? GoogleOAuthError.cancelled : GoogleOAuthError.denied(error)
        }
        guard query["state"] == state else { throw GoogleOAuthError.stateMismatch }
        guard let code = query["code"], !code.isEmpty else { throw GoogleOAuthError.denied("no authorization code") }
        return code
    }

    static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    static func randomToken(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncodedString()
    }
}

/// The token endpoint's response.
public struct GoogleTokenResponse: Decodable, Sendable {
    public var accessToken: String
    public var expiresIn: Int?
    public var refreshToken: String?
    public var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }

    public var scopes: [String] { scope?.split(separator: " ").map(String.init) ?? [] }
}

/// Calls to Google's OAuth endpoints.
public enum GoogleOAuth {
    static let log = Log("auth")

    /// Exchanges the authorization code from the browser redirect for tokens.
    public static func exchange(code: String, for request: GoogleAuthorizationRequest, transport: any HTTPTransport) async throws -> GoogleTokenResponse {
        try await tokenRequest(client: request.client, transport: transport, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": request.redirectURI,
            "code_verifier": request.codeVerifier,
        ])
    }

    /// A fresh access token. Throws `ProviderError.unauthorized` when the refresh token was revoked or expired.
    public static func refresh(_ credential: GoogleCredential, transport: any HTTPTransport) async throws -> GoogleTokenResponse {
        try await tokenRequest(client: credential.client, transport: transport, form: [
            "grant_type": "refresh_token",
            "refresh_token": credential.refreshToken,
        ])
    }

    /// Revokes a token on Google's side (sign out). Best effort.
    public static func revoke(_ token: String, transport: any HTTPTransport) async {
        var request = URLRequest(url: GoogleOAuthClient.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["token": token])
        _ = try? await transport.data(for: request)
    }

    private static func tokenRequest(client: GoogleOAuthClient, transport: any HTTPTransport, form: [String: String]) async throws -> GoogleTokenResponse {
        var fields = form
        fields["client_id"] = client.clientID
        fields["client_secret"] = client.clientSecret
        var request = URLRequest(url: client.tokenURI, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields)

        let grant = form["grant_type"] ?? "?"
        let clock = Stopwatch()
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            log.error("Token request (\(grant)) failed after \(clock.text): \(GmailAPI.describe(error))")
            throw GmailAPI.providerError(for: error)
        }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { var error: String?; var error_description: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            log.error("Token request (\(grant)) → \(response.statusCode) after \(clock.text): \(failure?.error ?? "?") \(failure?.error_description ?? "")")
            // invalid_grant: the refresh token expired or was revoked. Sign in again.
            if failure?.error == "invalid_grant" { throw ProviderError.unauthorized }
            if response.statusCode >= 500 { throw ProviderError.server("Google sign-in returned \(response.statusCode)") }
            throw GoogleOAuthError.tokenEndpoint(failure?.error_description ?? failure?.error ?? "HTTP \(response.statusCode)")
        }
        do {
            let tokens = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
            log.info("Token request (\(grant)) succeeded in \(clock.text): access token valid \((tokens.expiresIn ?? 0) / 60) min, scopes \(tokens.scopes.map { $0.replacingOccurrences(of: "https://www.googleapis.com/auth/", with: "") }.joined(separator: " "))")
            return tokens
        } catch {
            log.error("Token request (\(grant)): unexpected response (\(data.count) bytes)")
            throw GoogleOAuthError.tokenEndpoint("unexpected response")
        }
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }
}

/// Hands out access tokens for one credential, refreshing them shortly before they expire.
/// Concurrent callers share one refresh.
public actor GoogleTokenSource {
    private let credential: GoogleCredential?
    private let transport: any HTTPTransport
    private var token: (value: String, expires: Date)?
    private var refreshing: Task<GoogleTokenResponse, Error>?

    public init(credential: GoogleCredential?, transport: any HTTPTransport) {
        self.credential = credential
        self.transport = transport
    }

    public func accessToken() async throws -> String {
        if let token, token.expires.timeIntervalSinceNow > 90 { return token.value }
        let task: Task<GoogleTokenResponse, Error>
        if let refreshing {
            task = refreshing
        } else {
            guard let credential else {
                GoogleOAuth.log.notice("No credential: signed out")
                throw ProviderError.unauthorized
            }
            let transport = transport
            task = Task { try await GoogleOAuth.refresh(credential, transport: transport) }
            refreshing = task
        }
        do {
            let response = try await task.value
            if refreshing == task { refreshing = nil }
            token = (response.accessToken, Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600)))
            return response.accessToken
        } catch {
            if refreshing == task { refreshing = nil }
            throw error
        }
    }

    /// Drops the cached token after the API rejected it (401).
    public func invalidate() {
        token = nil
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .filter { !$0.isWhitespace }
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }
}
