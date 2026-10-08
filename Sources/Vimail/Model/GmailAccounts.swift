import AppKit
import GmailProvider
import MailCore
import UniformTypeIdentifiers
import VimailLog

/// Gmail sign-in and the credentials vimail keeps for it.
///
/// The OAuth client (downloaded from Google Cloud Console) is copied to `google-oauth-client.json`,
/// and each account's refresh token is kept in `accounts/gmail-<email>/google-credential.json`.
/// Both files are readable only by you (mode 600). Access tokens are never written to disk.
enum GmailAccounts {
    static let log = Log("sign-in")

    /// The installed app asks for read and write access (labels, archive, trash, send).
    /// Debug builds only ever ask for read-only access, so a test build cannot change or send mail.
    static var scopes: [String] {
        #if DEBUG
        [GmailScope.readonly]
        #else
        [GmailScope.modify]
        #endif
    }

    static func accountKey(email: String) -> String {
        "gmail-" + email.lowercased().filter { $0.isLetter || $0.isNumber || "@._+-".contains($0) }
    }

    // MARK: - OAuth client

    static func loadClient() -> GoogleOAuthClient? {
        guard let data = try? Data(contentsOf: AppPaths.googleClient) else { return nil }
        return try? GoogleOAuthClient(clientSecretJSON: data)
    }

    /// Asks for the client JSON downloaded from Google Cloud Console, then keeps a private copy.
    static func chooseClientFile() throws -> GoogleOAuthClient? {
        let panel = NSOpenPanel()
        panel.title = "Choose your Google OAuth client"
        panel.message = "Choose the client_secret_….json of a “Desktop app” OAuth client from Google Cloud Console."
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = try Data(contentsOf: url)
        let client = try GoogleOAuthClient(clientSecretJSON: data)
        try writePrivately(data, to: AppPaths.googleClient)
        log.info("Saved the OAuth client (\(client.clientID.prefix(12))…)")
        return client
    }

    // MARK: - Credentials

    static func credential(email: String) -> GoogleCredential? {
        guard !email.isEmpty, let data = try? Data(contentsOf: AppPaths.googleCredential(account: accountKey(email: email))) else { return nil }
        return try? JSONDecoder().decode(GoogleCredential.self, from: data)
    }

    static func save(_ credential: GoogleCredential) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivately(try encoder.encode(credential), to: AppPaths.googleCredential(account: accountKey(email: credential.email)))
    }

    /// Forgets the account's access. The mail cache and local drafts stay.
    static func signOut(email: String) async {
        guard let credential = credential(email: email) else { return }
        try? FileManager.default.removeItem(at: AppPaths.googleCredential(account: accountKey(email: email)))
        await GoogleOAuth.revoke(credential.refreshToken, transport: URLSessionTransport())
        log.info("Signed out of \(email): credential deleted, token revoked")
    }

    #if DEBUG
    /// Debug builds can use a token file from Google's own libraries (for example the read-only
    /// `token.json` of the first OAuth test): `VIMAIL_GMAIL_TOKEN_FILE=/path/to/token.json`.
    static func developmentCredential() -> GoogleCredential? {
        guard let path = ProcessInfo.processInfo.environment["VIMAIL_GMAIL_TOKEN_FILE"], !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else { return nil }
        return try? GoogleCredential(authorizedUserJSON: data)
    }
    #endif

    // MARK: - Sign-in

    /// Opens Google sign-in in the browser and waits for it. Saves and returns the new credential.
    static func signIn(client: GoogleOAuthClient, loginHint: String?) async throws -> GoogleCredential {
        let clock = Stopwatch()
        let receiver = try LoopbackReceiver()
        try await receiver.start()
        defer { receiver.stop() }
        let request = GoogleAuthorizationRequest(client: client, scopes: scopes, redirectURI: receiver.redirectURI, loginHint: loginHint)
        log.info("Step 1/4: waiting for Google on \(receiver.redirectURI), opening the browser (scopes: \(scopes.map { $0.components(separatedBy: "/").last ?? $0 }.joined(separator: " ")))")
        NSWorkspace.shared.open(request.url)

        let query: [String: String]
        do {
            query = try await receiver.callback(timeout: .seconds(600))
        } catch {
            log.notice("Sign-in stopped while waiting for the browser after \(clock.text): \(error.localizedDescription)")
            throw error
        }
        log.info("Step 2/4: browser returned after \(clock.text) (\(query["error"].map { "error \($0)" } ?? "authorization code received"))")
        let code = try request.code(fromCallback: query)
        let transport = URLSessionTransport()
        let tokens = try await GoogleOAuth.exchange(code: code, for: request, transport: transport)
        guard let refreshToken = tokens.refreshToken else {
            log.error("Google returned no refresh token")
            throw GoogleOAuthError.missingRefreshToken
        }
        // With granular consent people can untick Gmail access.
        if let missing = scopes.first(where: { !tokens.scopes.contains($0) }) {
            log.error("Gmail access was not granted (missing \(missing))")
            throw GoogleOAuthError.missingScope(missing)
        }
        log.info("Step 3/4: tokens received after \(clock.text). Reading the Gmail profile")

        var credential = GoogleCredential(email: "", refreshToken: refreshToken, scopes: tokens.scopes, client: client)
        credential.email = try await GmailProvider(credential: credential, transport: transport).profile().email
        try save(credential)
        log.info("Step 4/4: signed in as \(credential.email) in \(clock.text). Credential saved")
        NSApp.activate()
        return credential
    }

    /// Writes a secret file that only the current user can read.
    private static func writePrivately(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
    }
}
