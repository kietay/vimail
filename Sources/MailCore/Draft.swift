import Foundation

public struct DraftAttachment: Identifiable, Hashable, Codable, Sendable {
    public enum Source: Hashable, Codable, Sendable {
        /// A file copied into the app's local draft folder.
        case file(path: String)
        /// An attachment of an existing message (forwarding). The provider resolves the bytes.
        case remote(messageID: String, attachmentID: String)
    }

    public var id: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var source: Source

    public init(id: String = UUID().uuidString, filename: String, mimeType: String, size: Int, source: Source) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.source = source
    }
}

/// Which signature goes below a message.
public enum SignatureChoice: Hashable, Codable, Sendable {
    case off
    /// The account's own signature (Gmail settings).
    case account
    /// One of your Markdown signatures (Settings), by id.
    case custom(String)
}

/// A message being written. Drafts are local-only state: they are never synced to the provider.
public struct Draft: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case new, reply, replyAll, forward

        public var title: String {
            switch self {
            case .new: "New message"
            case .reply: "Reply"
            case .replyAll: "Reply all"
            case .forward: "Forward"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var threadID: String?
    /// The message this draft replies to or forwards.
    public var sourceMessageID: String?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    /// Markdown source of the new text (without the quoted original).
    public var body: String
    public var attachments: [DraftAttachment]
    /// Append the quoted original message (replies) or the forwarded message (forwards) when sending.
    public var includeQuote: Bool
    /// Nil until compose opens the draft; then the default signature from Settings.
    public var signature: SignatureChoice?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: Kind = .new,
        threadID: String? = nil,
        sourceMessageID: String? = nil,
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String = "",
        body: String = "",
        attachments: [DraftAttachment] = [],
        includeQuote: Bool = true,
        signature: SignatureChoice? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.threadID = threadID
        self.sourceMessageID = sourceMessageID
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.includeQuote = includeQuote
        self.signature = signature
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var recipients: [EmailAddress] { to + cc + bcc }

    /// True when there is nothing worth keeping.
    public var isBlank: Bool {
        recipients.isEmpty && subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

/// A fully rendered message handed to the provider for sending.
public struct OutgoingMessage: Hashable, Codable, Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var textBody: String
    public var htmlBody: String?
    public var threadID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var attachments: [DraftAttachment]
    /// The RFC 5322 Message-ID, fixed when the message is queued so retries can detect a send
    /// that already arrived. Nil for messages queued before this field existed.
    public var messageID: String?

    public init(
        from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
        subject: String, textBody: String, htmlBody: String? = nil, threadID: String? = nil,
        inReplyTo: String? = nil, references: [String] = [], attachments: [DraftAttachment] = [],
        messageID: String? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.threadID = threadID
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
        self.messageID = messageID
    }
}
