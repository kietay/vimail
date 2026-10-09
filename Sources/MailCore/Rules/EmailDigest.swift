import Foundation

/// What Claude learns about one email: the sender, a recipient count, a few facts and the visible body.
/// MailAI turns it into the `<email>` block of the prompt.
///
/// Third-party text is already prompt-safe (`HTMLText.promptLine`, `promptText`). The account's own
/// addresses never appear: recipients are only counted, the previous sender is nil when it was you,
/// and your addresses in the text read "me".
public struct EmailDigest: Sendable, Hashable {
    /// Gmail's inbox tab, from the CATEGORY_* labels.
    public enum Category: String, Sendable, Hashable {
        case primary = "Primary"
        case social = "Social"
        case promotions = "Promotions"
        case updates = "Updates"
        case forums = "Forums"
    }

    public struct Attachment: Sendable, Hashable {
        public var filename: String
        public var mimeType: String
    }

    /// The message before this one in its conversation.
    public struct Previous: Sendable, Hashable {
        /// nil when you sent it.
        public var from: EmailAddress?
        /// Its first characters (`previousLimit`).
        public var text: String
    }

    public static let bodyLimit = 4_000
    public static let previousLimit = 400

    public var messageID: String
    public var from: EmailAddress
    /// Recipients (To and Cc) other than you.
    public var otherRecipients: Int
    public var date: Date
    /// Mailing-list mail: the message has a List-Unsubscribe header.
    public var isList: Bool
    public var category: Category?
    public var subject: String
    /// Files only (no inline images), by name and type. Their contents are never sent.
    public var attachments: [Attachment]
    /// False for the first message of a conversation.
    public var isReply: Bool
    /// Visible body text, at most `bodyLimit` characters.
    public var body: String
    /// Set for replies whose earlier message is stored.
    public var previous: Previous?

    /// - Parameters:
    ///   - thread: the conversation, oldest first. It may include `message`.
    ///   - selfAddresses: the account's address and aliases, lowercased.
    public init(message: MailMessage, thread: [MailMessage], selfAddresses: Set<String>) {
        func redacted(_ text: String) -> String { Self.redacting(selfAddresses, in: text) }
        // Addresses are replaced before the text is cut, so none is cut in half.
        func bodyText(of message: MailMessage, limit: Int) -> String {
            HTMLText.truncated(redacted(HTMLText.promptText(html: message.htmlBody, text: message.textBody, maxCharacters: .max)), to: limit)
        }
        messageID = message.id
        from = EmailAddress(name: message.from.name.map { redacted(HTMLText.promptLine($0)) }, email: HTMLText.promptLine(message.from.email))
        otherRecipients = Set((message.to + message.cc).map(\.normalized)).subtracting(selfAddresses).count
        date = message.date
        isList = !(message.listUnsubscribe ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        category = Self.category(of: message.labelIDs)
        subject = redacted(HTMLText.promptLine(message.subject))
        attachments = message.fileAttachments.map {
            Attachment(filename: HTMLText.promptLine($0.filename), mimeType: HTMLText.promptLine($0.mimeType))
        }
        body = bodyText(of: message, limit: Self.bodyLimit)

        let earlier = thread.filter { $0.id != message.id && $0.date <= message.date && !$0.labelIDs.contains(SystemLabel.draft) }
        if let last = earlier.last {
            let fromMe = selfAddresses.contains(last.from.normalized)
            previous = Previous(
                from: fromMe ? nil : EmailAddress(name: last.from.name.map { redacted(HTMLText.promptLine($0)) }, email: HTMLText.promptLine(last.from.email)),
                text: bodyText(of: last, limit: Self.previousLimit)
            )
        }
        // A conversation's ID is its first message's ID, so a reply is known even when its parent is not stored.
        isReply = previous != nil || message.threadID != message.id
    }

    /// Replaces each of `addresses` with "me".
    static func redacting(_ addresses: Set<String>, in text: String) -> String {
        addresses.reduce(text) { replacingAddress($1, in: $0) }
    }

    /// Replaces whole occurrences of `address` (any case) with "me": "data@b.co" stays when the address is "a@b.co".
    static func replacingAddress(_ address: String, in text: String) -> String {
        guard !address.isEmpty else { return text }
        var result = ""
        var rest = text[...]
        while let range = rest.range(of: address, options: .caseInsensitive) {
            let before = range.lowerBound > rest.startIndex ? rest[rest.index(before: range.lowerBound)] : nil
            let after = range.upperBound < rest.endIndex ? rest[range.upperBound] : nil
            let whole = !(before.map { $0.isLetter || $0.isNumber || "._%+-".contains($0) } ?? false)
                && !(after.map { $0.isLetter || $0.isNumber || $0 == "-" } ?? false)
            result += rest[..<range.lowerBound]
            result += whole ? "me" : rest[range]
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    static func category(of labelIDs: Set<String>) -> Category? {
        let categories: [(String, Category)] = [
            (SystemLabel.categoryPersonal, .primary), (SystemLabel.categorySocial, .social),
            (SystemLabel.categoryPromotions, .promotions), (SystemLabel.categoryUpdates, .updates),
            (SystemLabel.categoryForums, .forums),
        ]
        return categories.first { labelIDs.contains($0.0) }?.1
    }
}
