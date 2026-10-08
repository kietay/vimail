import Foundation
import MailCore

/// The signature added below the text: your Markdown one, or the account's own (Gmail settings) HTML.
public enum EmailSignature: Hashable, Sendable {
    case markdown(String)
    case html(String)

    var isEmpty: Bool {
        switch self {
        case .markdown(let text), .html(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Turns a draft into the exact message that is sent: an HTML part (rendered Markdown,
/// signature, quoted original) and a plain-text part. The compose preview shows the same HTML,
/// so what you see is what recipients get.
public enum EmailComposer {
    static let wrapperStyle = "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;font-size:14px;line-height:1.55;color:#1f2328;"

    public static func outgoing(draft: Draft, source: MailMessage?, signature: EmailSignature, from: EmailAddress) -> OutgoingMessage {
        var references = source?.references ?? []
        if let header = source?.messageIDHeader, !references.contains(header) { references.append(header) }
        let isReply = draft.kind == .reply || draft.kind == .replyAll
        return OutgoingMessage(
            from: from, to: draft.to, cc: draft.cc, bcc: draft.bcc,
            subject: draft.subject,
            textBody: text(draft: draft, source: source, signature: signature),
            htmlBody: html(draft: draft, source: source, signature: signature),
            threadID: isReply ? draft.threadID : nil,
            inReplyTo: isReply ? source?.messageIDHeader : nil,
            references: isReply ? references : [],
            attachments: draft.attachments,
            messageID: "<vimail.\(UUID().uuidString.lowercased())@\(from.email.split(separator: "@").last.map(String.init) ?? "vimail.local")>"
        )
    }

    public static func html(draft: Draft, source: MailMessage?, signature: EmailSignature) -> String {
        var parts = [Markdown.html(draft.body)]
        switch signature {
        case .markdown(let markdown) where !signature.isEmpty:
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append("<div class=\"vimail-signature\" style=\"margin:16px 0 0 0;color:#57606a;\">\(Markdown.html(trimmed))</div>")
        case .html(let html) where !signature.isEmpty:
            // The account's own signature, exactly as Gmail would add it.
            parts.append("<div class=\"vimail-signature\" style=\"margin:16px 0 0 0;\">\(html)</div>")
        default:
            break
        }
        if draft.includeQuote, let source {
            parts.append(quoteHTML(for: source, forward: draft.kind == .forward))
        }
        return "<div style=\"\(wrapperStyle)\">\(parts.joined(separator: "\n"))</div>"
    }

    public static func text(draft: Draft, source: MailMessage?, signature: EmailSignature) -> String {
        var text = draft.body.trimmingCharacters(in: .newlines)
        if !signature.isEmpty {
            switch signature {
            case .markdown(let markdown): text += "\n\n-- \n\(markdown.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .html(let html):
                // Signature HTML is usually nested <div>s: keep its lines, drop the blank ones between them.
                let lines = HTMLText.plainText(fromHTML: html).split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                text += "\n\n-- \n" + lines.joined(separator: "\n")
            }
        }
        if draft.includeQuote, let source {
            if draft.kind == .forward {
                text += "\n\n\(ReplyComposer.forwardHeader(for: source))\n\n\(source.plainText)"
            } else {
                text += "\n\n\(ReplyComposer.attribution(for: source))\n\(ReplyComposer.quotedText(of: source))"
            }
        }
        return text
    }

    static func quoteHTML(for source: MailMessage, forward: Bool) -> String {
        let original: String
        if let html = source.htmlBody, !html.isEmpty {
            original = bodyContent(of: html)
        } else {
            original = "<div style=\"white-space:pre-wrap;\">\(HTMLText.escape(source.plainText))</div>"
        }
        if forward {
            let header = HTMLText.escape(ReplyComposer.forwardHeader(for: source)).replacingOccurrences(of: "\n", with: "<br>")
            return "<div class=\"vimail-forward\" style=\"margin:20px 0 0 0;\"><div style=\"color:#57606a;\">\(header)</div><br>\(original)</div>"
        }
        return """
        <div class="vimail-quote" style="margin:20px 0 0 0;">
        <div style="color:#57606a;">\(HTMLText.escape(ReplyComposer.attribution(for: source)))</div>
        <blockquote style="margin:6px 0 0 0.8ex;border-left:1px solid #ccc;padding-left:1ex;">\(original)</blockquote>
        </div>
        """
    }

    /// The inner HTML of `<body>`, without `<html>`/`<head>`, so it can be nested.
    static func bodyContent(of html: String) -> String {
        guard let open = html.range(of: "<body", options: .caseInsensitive),
              let openEnd = html[open.upperBound...].firstIndex(of: ">") else { return html }
        let start = html.index(after: openEnd)
        let end = html.range(of: "</body>", options: [.caseInsensitive, .backwards])?.lowerBound ?? html.endIndex
        return start <= end ? String(html[start..<end]) : html
    }
}

/// Token-based fuzzy matching for the omnibox: every query word must appear; prefix and
/// word-start matches rank higher.
public enum FuzzyMatcher {
    public static func score(query: String, in haystack: String) -> Int? {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return 0 }
        let text = haystack.lowercased()
        var total = 0
        for token in tokens {
            guard let range = text.range(of: token) else { return nil }
            if range.lowerBound == text.startIndex {
                total += 30
            } else if let before = text[..<range.lowerBound].last, !before.isLetter && !before.isNumber {
                total += 15
            } else {
                total += 5
            }
        }
        return total - min(text.count / 20, 10)
    }
}
