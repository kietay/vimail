import Foundation

/// Gmail's system label IDs. User labels have provider-assigned IDs such as `Label_12`.
public enum SystemLabel {
    public static let inbox = "INBOX"
    public static let unread = "UNREAD"
    public static let starred = "STARRED"
    public static let important = "IMPORTANT"
    public static let sent = "SENT"
    public static let draft = "DRAFT"
    public static let trash = "TRASH"
    public static let spam = "SPAM"
    public static let chat = "CHAT"
    public static let categoryPersonal = "CATEGORY_PERSONAL"
    public static let categorySocial = "CATEGORY_SOCIAL"
    public static let categoryPromotions = "CATEGORY_PROMOTIONS"
    public static let categoryUpdates = "CATEGORY_UPDATES"
    public static let categoryForums = "CATEGORY_FORUMS"

    public static let all: Set<String> = [
        inbox, unread, starred, important, sent, draft, trash, spam, chat,
        categoryPersonal, categorySocial, categoryPromotions, categoryUpdates, categoryForums,
    ]
}

public struct MailLabel: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Provider system labels (INBOX, STARRED, ...). Never shown as chips.
        case system
        /// Labels that exist on the provider and sync both ways.
        case user
        /// Labels that only exist in this app's local database (for example labels a rule creates).
        /// They are never sent to the provider.
        case local
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Index into the theme's label palette. `nil` lets the app pick one from the ID.
    public var colorIndex: Int?

    public init(id: String, name: String, kind: Kind, colorIndex: Int? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.colorIndex = colorIndex
    }

    public var isUserFacing: Bool { kind != .system }

    /// Stable palette slot derived from the label ID when no color is set.
    public func paletteIndex(count: Int) -> Int {
        if let colorIndex { return ((colorIndex % count) + count) % count }
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Int(hash % UInt64(count))
    }
}
