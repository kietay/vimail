import Foundation

/// Built-in mailboxes. Most map to a Gmail label; `archive`, `allMail` and `snoozed` are derived.
public enum Mailbox: Hashable, Codable, Sendable {
    case inbox
    case starred
    case snoozed
    case sent
    case drafts
    /// Conversations not in Inbox, Trash or Spam that contain at least one received message.
    case archive
    /// Everything except Trash and Spam.
    case allMail
    case spam
    case trash
    case label(String)

    public static let navigation: [Mailbox] = [.inbox, .starred, .snoozed, .sent, .drafts, .archive, .trash]

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .snoozed: "Snoozed"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .archive: "Archive"
        case .allMail: "All mail"
        case .spam: "Spam"
        case .trash: "Trash"
        case .label(let id): id
        }
    }

    /// The Gmail label that defines membership, when there is one.
    public var labelID: String? {
        switch self {
        case .inbox: SystemLabel.inbox
        case .starred: SystemLabel.starred
        case .sent: SystemLabel.sent
        case .spam: SystemLabel.spam
        case .trash: SystemLabel.trash
        case .label(let id): id
        case .snoozed, .drafts, .archive, .allMail: nil
        }
    }

    /// Stable string form for persistence and command IDs.
    public var key: String {
        switch self {
        case .label(let id): "label:\(id)"
        default: title.lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }

    public init?(key: String) {
        if key.hasPrefix("label:") {
            self = .label(String(key.dropFirst(6)))
            return
        }
        let all: [Mailbox] = [.inbox, .starred, .snoozed, .sent, .drafts, .archive, .allMail, .spam, .trash]
        guard let match = all.first(where: { $0.key == key }) else { return nil }
        self = match
    }
}

public enum ReadFilter: String, Codable, Sendable, CaseIterable {
    case any, unread, read
}

/// The tabs above the message list.
public enum ListFilter: String, Codable, Sendable, CaseIterable {
    case all = "All mail"
    case unread = "Unread"
    case starred = "Starred"
}

/// A saved filter across mail ("view" in the design). Stored locally only.
public struct SavedView: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var pinned: Bool
    public var status: ReadFilter
    public var starredOnly: Bool
    /// Label ID, or nil for any label.
    public var labelID: String?
    /// Mailbox scope, or nil for "all mailboxes, except Trash".
    public var mailbox: Mailbox?
    /// Case-insensitive "sender contains".
    public var sender: String
    /// Case-insensitive "text contains" (subject, sender, body).
    public var text: String
    public var position: Int

    public init(
        id: String = "view-\(UUID().uuidString.prefix(8).lowercased())",
        name: String, pinned: Bool = true, status: ReadFilter = .any, starredOnly: Bool = false,
        labelID: String? = nil, mailbox: Mailbox? = nil, sender: String = "", text: String = "", position: Int = 0
    ) {
        self.id = id
        self.name = name
        self.pinned = pinned
        self.status = status
        self.starredOnly = starredOnly
        self.labelID = labelID
        self.mailbox = mailbox
        self.sender = sender
        self.text = text
        self.position = position
    }

    /// The query that lists this view's conversations.
    public var query: ThreadQuery {
        var query = ThreadQuery(scope: mailbox.map(ThreadQuery.Scope.mailbox) ?? .everywhereExceptTrash)
        query.read = status
        query.starredOnly = starredOnly
        if let labelID { query.labelIDs = [labelID] }
        if !sender.trimmingCharacters(in: .whitespaces).isEmpty { query.senders = [sender] }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { query.containsText = [text] }
        return query
    }
}

/// What the list pane shows: a mailbox or a saved view.
public enum Destination: Hashable, Codable, Sendable {
    case mailbox(Mailbox)
    case view(String)

    public var key: String {
        switch self {
        case .mailbox(let mailbox): "mailbox:\(mailbox.key)"
        case .view(let id): "view:\(id)"
        }
    }
}

/// A structured conversation query. The store turns it into SQL.
public struct ThreadQuery: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case mailbox(Mailbox)
        /// All mail except Trash and Spam.
        case everywhereExceptTrash
        /// Literally everything, including Trash and Spam.
        case anywhere
    }

    public var scope: Scope
    public var read: ReadFilter = .any
    public var starredOnly = false
    /// Every listed label must be present.
    public var labelIDs: [String] = []
    /// Labels matched by name (case-insensitive), from `label:` search terms.
    public var labelNames: [String] = []
    /// Substring match on sender name or address.
    public var senders: [String] = []
    /// Substring match on recipient name or address.
    public var recipients: [String] = []
    /// Substring match on the subject.
    public var subjects: [String] = []
    /// Substring match on subject, sender, snippet and body (used by saved views).
    public var containsText: [String] = []
    /// Full-text search terms (prefix match).
    public var terms: [String] = []
    /// Full-text exact phrases.
    public var phrases: [String] = []
    /// Full-text terms that must not appear.
    public var excludedTerms: [String] = []
    public var hasAttachment: Bool?
    public var before: Date?
    public var after: Date?
    /// Restricts results to these conversation IDs (used to keep "sticky" rows in filtered lists).
    public var ids: [String]?
    public var limit = 300
    public var offset = 0

    public init(scope: Scope) {
        self.scope = scope
    }

    public static func mailbox(_ mailbox: Mailbox) -> ThreadQuery { ThreadQuery(scope: .mailbox(mailbox)) }

    /// Adds the list-tab filter (All mail / Unread / Starred).
    public func applying(_ filter: ListFilter) -> ThreadQuery {
        var copy = self
        switch filter {
        case .all: break
        case .unread: copy.read = .unread
        case .starred: copy.starredOnly = true
        }
        return copy
    }

    /// Narrows this query with a parsed search. Search operators override the scope (for example `in:trash`).
    public func narrowed(by search: SearchQuery) -> ThreadQuery {
        var copy = self
        if let scope = search.scope { copy.scope = scope }
        if let read = search.read { copy.read = read }
        if search.starred == true { copy.starredOnly = true }
        copy.labelNames += search.labelNames
        copy.senders += search.from
        copy.recipients += search.to
        copy.subjects += search.subject
        copy.terms += search.terms
        copy.phrases += search.phrases
        copy.excludedTerms += search.excluded
        if let hasAttachment = search.hasAttachment { copy.hasAttachment = hasAttachment }
        if let before = search.before { copy.before = before }
        if let after = search.after { copy.after = after }
        return copy
    }
}
