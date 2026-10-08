import Foundation

/// Builds reply and forward drafts with Gmail's addressing rules.
public enum ReplyComposer {
    /// Adds "Re:" or "Fwd:" unless the subject already starts with an equivalent prefix.
    public static func prefixed(_ subject: String, with prefix: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        let equivalents = prefix.lowercased() == "re" ? ["re:", "aw:", "sv:"] : ["fwd:", "fw:"]
        if equivalents.contains(where: { lower.hasPrefix($0) }) { return trimmed }
        return trimmed.isEmpty ? "\(prefix):" : "\(prefix): \(trimmed)"
    }

    /// Reply (or reply all) to `message`. `me` holds the account's own addresses (lowercased).
    public static func reply(to message: MailMessage, all: Bool, me: Set<String>) -> Draft {
        let fromMe = me.contains(message.from.normalized)
        var to: [EmailAddress]
        var cc: [EmailAddress] = []

        if fromMe {
            // Replying to your own message continues the conversation with its recipients.
            to = message.to.isEmpty ? [message.from] : message.to
            if all { cc = message.cc }
        } else {
            to = message.replyTo.isEmpty ? [message.from] : message.replyTo
            if all {
                to += message.to
                cc = message.cc
            }
        }

        let excluded = fromMe && !all ? Set<String>() : me
        to = to.deduplicated(excluding: excluded)
        if to.isEmpty { to = [message.from] }
        cc = cc.deduplicated(excluding: excluded.union(to.map(\.normalized)))

        return Draft(
            kind: all ? .replyAll : .reply,
            threadID: message.threadID,
            sourceMessageID: message.id,
            to: to,
            cc: cc,
            subject: prefixed(message.subject, with: "Re")
        )
    }

    public static func forward(_ message: MailMessage) -> Draft {
        Draft(
            kind: .forward,
            threadID: nil,
            sourceMessageID: message.id,
            subject: prefixed(message.subject, with: "Fwd"),
            attachments: message.fileAttachments.map {
                DraftAttachment(
                    filename: $0.filename, mimeType: $0.mimeType, size: $0.size,
                    source: .remote(messageID: message.id, attachmentID: $0.id)
                )
            }
        )
    }

    /// "On Tue, Oct 7, 2026 at 10:42 AM, Alex Morgan <alex@studionorth.co> wrote:"
    public static func attribution(for message: MailMessage, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return "On \(formatter.string(from: message.date)), \(message.from.formatted) wrote:"
    }

    /// The original text with "> " quoting, for the plain-text part of a reply.
    public static func quotedText(of message: MailMessage) -> String {
        message.plainText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }

    /// The "Forwarded message" header block, as plain text.
    public static func forwardHeader(for message: MailMessage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        var lines = [
            "---------- Forwarded message ---------",
            "From: \(message.from.formatted)",
            "Date: \(formatter.string(from: message.date))",
            "Subject: \(message.subject)",
            "To: \(message.to.formattedList)",
        ]
        if !message.cc.isEmpty { lines.append("Cc: \(message.cc.formattedList)") }
        return lines.joined(separator: "\n")
    }
}
