import Foundation
import MailCore
import UniformTypeIdentifiers

/// Converts Gmail API resources into vimail's models.
enum GmailMapping {
    static func label(_ label: GmailLabel) -> MailLabel {
        let isUser = label.type == "user"
        return MailLabel(id: label.id, name: isUser ? label.name : label.id, kind: isUser ? .user : .system)
    }

    // MARK: - Messages

    /// Body parts Gmail did not include inline (it sends large parts by attachment ID).
    static func missingBodyAttachmentIDs(_ message: GmailMessage) -> [String] {
        guard let payload = message.payload else { return [] }
        var content = Content()
        walk(payload, into: &content, fetched: [:])
        return content.missing
    }

    /// The full message. `fetchedBodies` holds the bytes of parts listed by `missingBodyAttachmentIDs`.
    static func message(_ message: GmailMessage, fetchedBodies: [String: Data] = [:]) -> MailMessage {
        let payload = message.payload ?? GmailPart()
        var content = Content()
        walk(payload, into: &content, fetched: fetchedBodies)

        let html = content.html.isEmpty ? nil : content.html.joined(separator: "\n")
        let text = content.text.isEmpty ? nil : content.text.joined(separator: "\n\n")
        // An image with a Content-ID is inline only if the HTML shows it; otherwise it is a file.
        let attachments = content.attachments.map { attachment -> MailAttachment in
            var attachment = attachment
            if let contentID = attachment.contentID, attachment.isInline {
                attachment.isInline = html?.contains("cid:\(contentID)") ?? false
            }
            return attachment
        }

        func header(_ name: String) -> String? {
            payload.header(name).map { decodeHeader($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let from = header("From").flatMap(EmailAddress.parse) ?? EmailAddress(email: "")
        let date = message.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? header("Date").flatMap(parseDate) ?? Date()
        let plain = text ?? html.map(HTMLText.plainText(fromHTML:)) ?? ""
        var snippet = HTMLText.snippet(from: plain)
        if snippet.isEmpty { snippet = HTMLText.decodeEntities(message.snippet ?? "") }
        let references = (header("References") ?? "")
            .split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.hasPrefix("<") }
        let listUnsubscribe = header("List-Unsubscribe")

        return MailMessage(
            id: message.id,
            threadID: message.threadId,
            labelIDs: Set(message.labelIds ?? []),
            from: from,
            to: header("To").map(EmailAddress.parseList) ?? [],
            cc: header("Cc").map(EmailAddress.parseList) ?? [],
            bcc: header("Bcc").map(EmailAddress.parseList) ?? [],
            replyTo: header("Reply-To").map(EmailAddress.parseList) ?? [],
            subject: header("Subject") ?? "",
            snippet: snippet,
            date: date,
            textBody: text,
            htmlBody: html,
            attachments: attachments,
            messageIDHeader: header("Message-ID").flatMap(firstMessageID),
            inReplyTo: header("In-Reply-To").flatMap(firstMessageID),
            references: references,
            listUnsubscribe: listUnsubscribe,
            oneClickUnsubscribe: listUnsubscribe != nil && isOneClickUnsubscribe(payload.headers ?? []),
            sizeEstimate: message.sizeEstimate ?? 0
        )
    }

    // MARK: - One-click unsubscribe

    /// RFC 8058 one-click: the sender asks for it (`List-Unsubscribe-Post: List-Unsubscribe=One-Click`)
    /// and a DKIM signature Gmail verified covers both headers. Without that signature anyone on the
    /// way could have added them, so one-click is not offered (RFC 8058, section 4).
    static func isOneClickUnsubscribe(_ headers: [GmailHeader]) -> Bool {
        func values(_ name: String) -> [String] {
            headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        }
        // One of each: a copy added above a signed header would leave the signature valid.
        let post = values("List-Unsubscribe-Post")
        guard values("List-Unsubscribe").count == 1, post.count == 1,
              post[0].trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("List-Unsubscribe=One-Click") == .orderedSame else { return false }
        // Gmail puts its verdict above every other header. Copies further down can come from anyone.
        guard let verdict = values("Authentication-Results").first,
              verdict.split(separator: ";").first?.split(whereSeparator: \.isWhitespace).first?.lowercased() == "mx.google.com" else { return false }
        let signatures = values("DKIM-Signature").map(dkimTags)
        return passedDKIM(verdict).contains { result in
            // The signature Gmail verified: its domain, and its b= value starts the way Gmail quotes it.
            let verified = signatures.filter { tags in
                let domain = tags["d"]?.lowercased() ?? ""
                guard !domain.isEmpty, result.domain == domain || result.domain.hasSuffix(".\(domain)") else { return false }
                guard let prefix = result.signature else { return true }
                return !prefix.isEmpty && (tags["b"] ?? "").hasPrefix(prefix)
            }
            // A second one that looks the same may be a forged copy: then which one passed is unknown.
            guard verified.count == 1 else { return false }
            let signed = Set((verified[0]["h"] ?? "").lowercased().split(separator: ":"))
            return signed.contains("list-unsubscribe") && signed.contains("list-unsubscribe-post")
        }
    }

    /// The tags of a DKIM-Signature header (`d=example.com; h=from:to; b=…`), whitespace removed.
    static func dkimTags(_ value: String) -> [String: String] {
        var tags: [String: String] = [:]
        for pair in value.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            tags[pair[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)] = String(pair[pair.index(after: equals)...].filter { !$0.isWhitespace })
        }
        return tags
    }

    /// The DKIM signatures an Authentication-Results header says passed, for example
    /// `dkim=pass header.i=@example.com header.s=s1 header.b=AbCd1234`.
    static func passedDKIM(_ results: String) -> [(domain: String, signature: String?)] {
        // Comments in parentheses can hold anything, ";" included.
        let clean = results.replacingOccurrences(of: #"\([^()]*\)"#, with: " ", options: .regularExpression)
        return clean.split(separator: ";").compactMap { result in
            let words = result.split(whereSeparator: \.isWhitespace)
            guard words.first?.lowercased() == "dkim=pass" else { return nil }
            var properties: [String: String] = [:]
            for word in words.dropFirst() {
                guard let equals = word.firstIndex(of: "=") else { continue }
                properties[word[..<equals].lowercased()] = word[word.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            let domain = properties["header.d"] ?? properties["header.i"].flatMap { $0.split(separator: "@").last.map(String.init) } ?? ""
            return (domain.lowercased(), properties["header.b"])
        }
    }

    struct Content {
        var text: [String] = []
        var html: [String] = []
        var attachments: [MailAttachment] = []
        var missing: [String] = []
    }

    /// Collects the readable text, HTML and attachments of a MIME tree.
    static func walk(_ part: GmailPart, into content: inout Content, fetched: [String: Data]) {
        let mime = (part.mimeType ?? "text/plain").lowercased()
        let disposition = part.header("Content-Disposition").flatMap { $0.split(separator: ";").first }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let filename = part.filename ?? ""

        if mime.hasPrefix("multipart/") {
            let children = part.parts ?? []
            guard mime == "multipart/alternative" else {
                for child in children { walk(child, into: &content, fetched: fetched) }
                return
            }
            // Alternatives carry the same content: keep the last (richest) text and HTML versions.
            var text: [String] = []
            var html: [String] = []
            for child in children {
                var sub = Content()
                walk(child, into: &sub, fetched: fetched)
                if !sub.text.isEmpty { text = sub.text }
                if !sub.html.isEmpty { html = sub.html }
                content.attachments += sub.attachments
                content.missing += sub.missing
            }
            content.text += text
            content.html += html
            return
        }

        if (mime == "text/plain" || mime == "text/html"), disposition != "attachment", filename.isEmpty {
            let data: Data?
            if let inline = part.body?.data {
                data = Data(base64URLEncoded: inline)
            } else if let id = part.body?.attachmentId {
                data = fetched[id]
                if data == nil { content.missing.append(id) }
            } else {
                data = Data()
            }
            guard let data else { return }
            let decoded = decodeText(data, charset: parameters(of: part.header("Content-Type"))["charset"])
            if mime == "text/html" { content.html.append(decoded) } else { content.text.append(decoded) }
            return
        }

        // AMP and watch variants have an HTML twin. A calendar part stays, with or without a file name:
        // it is the invitation (Outlook sends it without one).
        if filename.isEmpty, ["text/x-amp-html", "text/watch-html"].contains(mime) { return }
        guard let body = part.body, body.attachmentId != nil || body.data != nil else { return }
        let contentID = part.header("Content-ID").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
        content.attachments.append(MailAttachment(
            id: body.attachmentId ?? "part:\(part.partId ?? "")",
            filename: filename.isEmpty ? defaultFilename(mimeType: mime) : filename,
            mimeType: mime,
            size: body.size ?? 0,
            isInline: contentID != nil && disposition != "attachment" && mime.hasPrefix("image/"),
            contentID: contentID
        ))
    }

    static func defaultFilename(mimeType: String) -> String {
        if mimeType == "message/rfc822" { return "message.eml" }
        if mimeType == "text/calendar" { return "invite.ics" }
        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension
        return ext.map { "attachment.\($0)" } ?? "attachment"
    }

    /// Finds a part by its Gmail part ID ("0", "1.2", ...).
    static func part(withID id: String, in part: GmailPart) -> GmailPart? {
        if part.partId == id { return part }
        for child in part.parts ?? [] {
            if let found = Self.part(withID: id, in: child) { return found }
        }
        return nil
    }

    // MARK: - Headers and charsets

    /// `<abc@host>` from a header that may hold several IDs or comments.
    static func firstMessageID(_ value: String) -> String? {
        if let open = value.firstIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
            return String(value[open...close])
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parameters of a structured header such as `text/html; charset="utf-8"`, keys lowercased.
    static func parameters(of header: String?) -> [String: String] {
        guard let header else { return [:] }
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        for character in header {
            if character == "\"" { inQuotes.toggle() }
            if character == ";", !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)
        var result: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            result[key] = value
        }
        return result
    }

    static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = stringEncoding(charset), let text = String(data: data, encoding: encoding) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    static func stringEncoding(_ charset: String) -> String.Encoding? {
        let name = charset.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))).lowercased()
        switch name {
        // ASCII is a subset of UTF-8, and mislabeled 8-bit mail is usually UTF-8.
        case "utf-8", "utf8", "us-ascii", "ascii": return .utf8
        // As in browsers: Latin-1 labels mean Windows-1252 (curly quotes, euro sign).
        case "iso-8859-1", "latin1", "iso8859-1": return .windowsCP1252
        default:
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard encoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        }
    }

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#)

    /// Decodes RFC 2047 encoded words (`=?UTF-8?B?…?=`). Gmail usually decodes headers already.
    static func decodeHeader(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let source = value as NSString
        let matches = encodedWord.matches(in: value, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return value }
        var output = ""
        var cursor = 0
        var previousWasEncoded = false
        for match in matches {
            let between = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Whitespace between two encoded words is not part of the text.
            if !(previousWasEncoded && between.allSatisfy(\.isWhitespace)) { output += between }
            let charset = source.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init) ?? "utf-8"
            let encoding = source.substring(with: match.range(at: 2)).uppercased()
            let payload = source.substring(with: match.range(at: 3))
            let bytes = encoding == "B" ? Data(base64Encoded: paddedBase64(payload)) : quotedPrintableWord(payload)
            if let bytes {
                output += decodeText(bytes, charset: charset)
            } else {
                output += source.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
            previousWasEncoded = true
        }
        output += source.substring(from: cursor)
        return output
    }

    private static func paddedBase64(_ text: String) -> String {
        let remainder = text.count % 4
        return remainder == 0 ? text : text + String(repeating: "=", count: 4 - remainder)
    }

    private static func quotedPrintableWord(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            switch byte {
            case UInt8(ascii: "_"): bytes.append(UInt8(ascii: " "))
            case UInt8(ascii: "="):
                guard let high = iterator.next(), let low = iterator.next(),
                      let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(value)
            default: bytes.append(byte)
            }
        }
        return Data(bytes)
    }

    private static let dateFormats = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"]

    static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Drop trailing comments such as "(UTC)".
        let cleaned = value.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}
