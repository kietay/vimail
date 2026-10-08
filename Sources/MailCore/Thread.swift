import Foundation

/// A row in the message list. Built from the denormalized `threads` table, so it is cheap to load.
public struct ThreadSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var subject: String
    public var snippet: String
    public var lastDate: Date
    /// Gmail-style participant line: "Alex Morgan", "Alex, me, Jamie" or "To: Nina Park".
    public var participants: String
    public var initials: String
    public var messageCount: Int
    public var isUnread: Bool
    public var isStarred: Bool
    public var hasAttachments: Bool
    public var labelIDs: [String]
    public var snoozedUntil: Date?
    /// Set when the row represents a local draft (Drafts mailbox).
    public var draftID: String?

    public init(
        id: String, subject: String, snippet: String, lastDate: Date, participants: String,
        initials: String, messageCount: Int, isUnread: Bool, isStarred: Bool, hasAttachments: Bool,
        labelIDs: [String], snoozedUntil: Date? = nil, draftID: String? = nil
    ) {
        self.id = id
        self.subject = subject
        self.snippet = snippet
        self.lastDate = lastDate
        self.participants = participants
        self.initials = initials
        self.messageCount = messageCount
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.hasAttachments = hasAttachments
        self.labelIDs = labelIDs
        self.snoozedUntil = snoozedUntil
        self.draftID = draftID
    }

    public func has(label id: String) -> Bool { labelIDs.contains(id) }
}

/// A full conversation for the reader.
public struct MailThread: Identifiable, Hashable, Sendable {
    public var id: String
    public var subject: String
    /// Chronological order (oldest first).
    public var messages: [MailMessage]
    public var labelIDs: Set<String>
    public var snoozedUntil: Date?
    /// Local annotations from message processors, keyed by message ID then annotation key.
    public var annotations: [String: [String: String]]

    public init(id: String, subject: String, messages: [MailMessage], labelIDs: Set<String>, snoozedUntil: Date? = nil, annotations: [String: [String: String]] = [:]) {
        self.id = id
        self.subject = subject
        self.messages = messages
        self.labelIDs = labelIDs
        self.snoozedUntil = snoozedUntil
        self.annotations = annotations
    }

    public var latest: MailMessage? { messages.last }
    public var isUnread: Bool { messages.contains(where: \.isUnread) }
    public var isStarred: Bool { messages.contains(where: \.isStarred) }

    /// The newest message that was not sent by one of `me`. Used as the reply target.
    public func latestReceived(excluding me: Set<String>) -> MailMessage? {
        messages.last(where: { !me.contains($0.from.normalized) }) ?? messages.last
    }
}
