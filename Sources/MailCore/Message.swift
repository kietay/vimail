import Foundation

public struct MailAttachment: Identifiable, Hashable, Codable, Sendable {
    /// Provider attachment ID, used to fetch the bytes.
    public var id: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// Inline parts (for example images referenced by `cid:` URLs) are not listed as files.
    public var isInline: Bool
    public var contentID: String?

    public init(id: String, filename: String, mimeType: String, size: Int, isInline: Bool = false, contentID: String? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.isInline = isInline
        self.contentID = contentID
    }

    /// "PDF", "PNG", "TEXT", ... for compact display.
    public var kindLabel: String {
        let ext = (filename as NSString).pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        return mimeType.split(separator: "/").last.map { $0.uppercased() } ?? "FILE"
    }
}

/// One email message, in the shape the provider delivers it (Gmail-like).
public struct MailMessage: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var threadID: String
    public var labelIDs: Set<String>
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var subject: String
    /// Short plain-text preview (about 200 characters).
    public var snippet: String
    public var date: Date
    public var textBody: String?
    public var htmlBody: String?
    public var attachments: [MailAttachment]
    /// The RFC 5322 `Message-ID` header, used for threading replies.
    public var messageIDHeader: String?
    public var inReplyTo: String?
    public var references: [String]
    public var listUnsubscribe: String?
    /// RFC 8058 one-click unsubscribe: the sender accepts one POST to the HTTPS address in
    /// `listUnsubscribe`, and a DKIM signature the provider verified covers both headers.
    /// Nil for mail cached before vimail checked.
    public var oneClickUnsubscribe: Bool?
    public var sizeEstimate: Int

    public init(
        id: String,
        threadID: String,
        labelIDs: Set<String>,
        from: EmailAddress,
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        subject: String,
        snippet: String,
        date: Date,
        textBody: String? = nil,
        htmlBody: String? = nil,
        attachments: [MailAttachment] = [],
        messageIDHeader: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        listUnsubscribe: String? = nil,
        oneClickUnsubscribe: Bool? = nil,
        sizeEstimate: Int = 0
    ) {
        self.id = id
        self.threadID = threadID
        self.labelIDs = labelIDs
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.messageIDHeader = messageIDHeader
        self.inReplyTo = inReplyTo
        self.references = references
        self.listUnsubscribe = listUnsubscribe
        self.oneClickUnsubscribe = oneClickUnsubscribe
        self.sizeEstimate = sizeEstimate
    }

    public var isUnread: Bool { labelIDs.contains(SystemLabel.unread) }
    public var isStarred: Bool { labelIDs.contains(SystemLabel.starred) }
    public var isSent: Bool { labelIDs.contains(SystemLabel.sent) }
    public var fileAttachments: [MailAttachment] { attachments.filter { !$0.isInline } }

    /// Plain text for search, previews and quoting. Falls back to stripped HTML.
    public var plainText: String {
        if let textBody, !textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return textBody }
        if let htmlBody { return HTMLText.plainText(fromHTML: htmlBody) }
        return snippet
    }
}
