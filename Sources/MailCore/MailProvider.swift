import Foundation

public struct AccountProfile: Hashable, Codable, Sendable {
    public var email: String
    public var displayName: String
    /// Opaque position in the provider's change history (Gmail `historyId`).
    public var historyCursor: String
    /// The account's own signature (Gmail settings), as HTML.
    public var signatureHTML: String?

    public init(email: String, displayName: String, historyCursor: String, signatureHTML: String? = nil) {
        self.email = email
        self.displayName = displayName
        self.historyCursor = historyCursor
        self.signatureHTML = signatureHTML
    }

    public var address: EmailAddress { EmailAddress(name: displayName, email: email) }
}

public struct ThreadIDPage: Sendable {
    public var ids: [String]
    public var nextPageToken: String?

    public init(ids: [String], nextPageToken: String?) {
        self.ids = ids
        self.nextPageToken = nextPageToken
    }
}

/// Everything that changed on the provider since a cursor.
public struct ChangeSet: Sendable {
    public var cursor: String
    /// New messages, or messages whose content changed. Contains the current label set.
    public var upserted: [MailMessage]
    /// Current provider label set for messages whose labels changed (content unchanged).
    public var labelUpdates: [String: Set<String>]
    public var deleted: [String]
    /// The label list itself changed (created, renamed or deleted labels).
    public var labelsChanged: Bool

    public init(cursor: String, upserted: [MailMessage] = [], labelUpdates: [String: Set<String>] = [:], deleted: [String] = [], labelsChanged: Bool = false) {
        self.cursor = cursor
        self.upserted = upserted
        self.labelUpdates = labelUpdates
        self.deleted = deleted
        self.labelsChanged = labelsChanged
    }

    public var isEmpty: Bool { upserted.isEmpty && labelUpdates.isEmpty && deleted.isEmpty && !labelsChanged }
}

public enum ProviderError: Error, Sendable, Equatable, LocalizedError {
    /// The network is unreachable. Retry later.
    case offline(String)
    /// Credentials are missing or expired.
    case unauthorized
    case notFound(String)
    /// The change cursor is too old. A full resync is required.
    case cursorExpired
    case rateLimited(retryAfter: TimeInterval?)
    /// The provider rejected the request. Retrying will not help.
    case rejected(String)
    /// A temporary server-side failure.
    case server(String)

    public var isTransient: Bool {
        switch self {
        case .offline, .rateLimited, .server: true
        case .unauthorized, .notFound, .cursorExpired, .rejected: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .offline(let reason): "Offline: \(reason)"
        case .unauthorized: "Not signed in"
        case .notFound(let what): "Not found: \(what)"
        case .cursorExpired: "Sync history expired"
        case .rateLimited: "Rate limited"
        case .rejected(let reason): "Rejected: \(reason)"
        case .server(let reason): "Server error: \(reason)"
        }
    }
}

/// The remote side of the mail client. The app never reads from a provider directly:
/// the sync engine copies provider state into the local store, and pushes local changes back.
///
/// The shape follows the Gmail API (labels on messages, threads, history cursors) so
/// `GmailProvider` implements it directly. `DummyMailProvider` implements it with fake data.
/// As in Gmail, a thread's ID is the ID of its first message.
public protocol MailProvider: Sendable {
    /// Short identifier for logs and storage paths, for example "dummy" or "gmail".
    var kind: String { get }
    /// False when the account cannot delete mail permanently (Gmail with the `gmail.modify` scope).
    var supportsPermanentDelete: Bool { get }

    func profile() async throws -> AccountProfile
    func labels() async throws -> [MailLabel]
    /// Thread IDs, newest first, for the initial sync. `labelID` limits the list to one label (for example the inbox).
    /// Spam and Trash are not listed.
    func listThreadIDs(labelID: String?, pageToken: String?, pageSize: Int) async throws -> ThreadIDPage
    /// Full messages for each thread, chronological. Unknown IDs are skipped.
    func threads(ids: [String]) async throws -> [[MailMessage]]
    /// Changes since `cursor`. Throws `ProviderError.cursorExpired` when a full resync is needed.
    func changes(since cursor: String) async throws -> ChangeSet

    func modifyLabels(messageIDs: [String], add: Set<String>, remove: Set<String>) async throws
    /// Permanent deletion.
    func deleteMessages(ids: [String]) async throws
    /// Sends a message. `fileData` holds the bytes of `.file` attachments, keyed by attachment ID.
    /// `isRetry` is true when an earlier attempt may have reached the provider (a timeout, or a crash
    /// mid-send). The provider should then check whether the message already went out.
    func send(_ message: OutgoingMessage, fileData: [String: Data], isRetry: Bool) async throws -> MailMessage
    func attachmentData(messageID: String, attachmentID: String) async throws -> Data

    func createLabel(name: String) async throws -> MailLabel
    func renameLabel(id: String, to name: String) async throws -> MailLabel
    func deleteLabel(id: String) async throws

    /// Optional push hints. Each element means "changes are available, sync soon".
    /// The sync engine also polls, so providers without push can return a stream that never yields.
    func changeSignals() -> AsyncStream<Void>
}

extension MailProvider {
    public var supportsPermanentDelete: Bool { true }

    public func changeSignals() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }
}
