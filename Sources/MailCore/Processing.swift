import Foundation

/// Input to a message processor.
public struct ProcessorInput: Sendable {
    /// The message to process.
    public let message: MailMessage
    /// All messages in its conversation, oldest first (includes `message`).
    public let thread: [MailMessage]
    /// All labels the account knows about, for name lookups.
    public let labels: [MailLabel]
    /// The account's own address.
    public let accountEmail: String

    public init(message: MailMessage, thread: [MailMessage], labels: [MailLabel], accountEmail: String) {
        self.message = message
        self.thread = thread
        self.labels = labels
        self.accountEmail = accountEmail
    }
}

/// Where a processor-created label lives.
public enum LabelScope: String, Codable, Sendable {
    /// Only in this app's local database. The provider never sees it. This is the default.
    case local
    /// A real provider label (visible in Gmail too).
    case synced
}

/// What a processor wants to happen. Effects are applied through the same action layer
/// as keyboard actions, so they are undoable, stored locally, and synced when needed.
public enum ProcessorEffect: Hashable, Sendable {
    /// Adds a label by name. The label is created when it does not exist.
    case addLabel(String, scope: LabelScope = .local)
    case removeLabel(String)
    /// Stores a key/value pair on the message (for example "category", "summary", "priority").
    /// Annotations stay local.
    case annotate(key: String, value: String)
    case markRead
    case archive
    case star
}

/// A step in the incoming-mail pipeline, for example an AI classifier.
///
/// Processors run in the background after sync stores new messages. Each (message, processor id,
/// version) pair runs once; bump `version` to reprocess existing mail after a change.
public protocol MessageProcessor: Sendable {
    /// Stable identifier, for example "classifier".
    var id: String { get }
    var version: Int { get }
    /// Cheap pre-filter. The default skips sent mail and drafts.
    func accepts(_ message: MailMessage) -> Bool
    func process(_ input: ProcessorInput) async throws -> [ProcessorEffect]
}

extension MessageProcessor {
    public var version: Int { 1 }

    public func accepts(_ message: MailMessage) -> Bool {
        !message.labelIDs.contains(SystemLabel.sent) && !message.labelIDs.contains(SystemLabel.draft)
    }
}

/// The ordered list of processors. Empty in the first, non-AI version of the app.
public struct ProcessingPipeline: Sendable {
    public var processors: [any MessageProcessor]

    public init(_ processors: [any MessageProcessor] = []) {
        self.processors = processors
    }

    public var isEmpty: Bool { processors.isEmpty }
}

/// Example processor: adds a local label when the subject or sender matches a keyword.
/// Shows the shape a classifier takes; not registered by default.
public struct KeywordLabeler: MessageProcessor {
    public let id: String
    public let version: Int
    public let rules: [(keyword: String, label: String)]

    public init(id: String = "keyword-labeler", version: Int = 1, rules: [(keyword: String, label: String)]) {
        self.id = id
        self.version = version
        self.rules = rules
    }

    public func process(_ input: ProcessorInput) async throws -> [ProcessorEffect] {
        let haystack = "\(input.message.subject) \(input.message.from.displayName) \(input.message.from.email)".lowercased()
        return rules
            .filter { haystack.contains($0.keyword.lowercased()) }
            .map { .addLabel($0.label, scope: .local) }
    }
}
