import Foundation
import MailCore

/// Builds the RFC 5322 / MIME message that Gmail sends: a plain-text and an HTML alternative
/// (UTF-8, quoted-printable), plus attachments (base64). Lines end with CRLF.
public enum MIMEBuilder {
    public struct File: Sendable {
        public var filename: String
        public var mimeType: String
        public var data: Data

        public init(filename: String, mimeType: String, data: Data) {
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
        }
    }

    public static func build(_ message: OutgoingMessage, messageID: String, files: [File], date: Date = Date()) -> Data {
        var headers: [String] = []
        headers.append("From: \(address(message.from))")
        if !message.to.isEmpty { headers.append(addressHeader("To", message.to)) }
        if !message.cc.isEmpty { headers.append(addressHeader("Cc", message.cc)) }
        // Gmail delivers to Bcc recipients and removes the header from the copies others receive.
        if !message.bcc.isEmpty { headers.append(addressHeader("Bcc", message.bcc)) }
        headers.append(unstructuredHeader("Subject", message.subject))
        headers.append("Date: \(rfc5322Date(date))")
        headers.append("Message-ID: \(messageID)")
        if let inReplyTo = message.inReplyTo { headers.append("In-Reply-To: \(inReplyTo)") }
        if !message.references.isEmpty { headers.append(fold("References: " + message.references.joined(separator: " "))) }
        headers.append("MIME-Version: 1.0")

        var body = textBody(message)
        if !files.isEmpty {
            let boundary = makeBoundary("mixed")
            var mixed = "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            mixed += "--\(boundary)\r\n\(body)\r\n"
            for file in files {
                mixed += "--\(boundary)\r\n\(attachmentPart(file))\r\n"
            }
            mixed += "--\(boundary)--\r\n"
            body = mixed
        }
        return Data((headers.joined(separator: "\r\n") + "\r\n" + body).utf8)
    }

    /// A new globally unique Message-ID in the sender's domain.
    public static func makeMessageID(from address: EmailAddress) -> String {
        let domain = address.email.split(separator: "@").last.map(String.init) ?? "vimail.local"
        return "<vimail.\(UUID().uuidString.lowercased())@\(domain)>"
    }

    // MARK: - Parts

    /// The text part, or text + HTML alternatives, including their Content-Type headers.
    static func textBody(_ message: OutgoingMessage) -> String {
        let plain = "Content-Type: text/plain; charset=\"UTF-8\"\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            + quotedPrintable(message.textBody)
        guard let html = message.htmlBody else { return plain }
        let boundary = makeBoundary("alt")
        let htmlPart = "Content-Type: text/html; charset=\"UTF-8\"\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            + quotedPrintable(html)
        return "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
            + "--\(boundary)\r\n\(plain)\r\n--\(boundary)\r\n\(htmlPart)\r\n--\(boundary)--"
    }

    static func attachmentPart(_ file: File) -> String {
        let name = parameter("name", file.filename)
        let filename = parameter("filename", file.filename)
        let mimeType = file.mimeType.isEmpty ? "application/octet-stream" : file.mimeType
        return "Content-Type: \(mimeType); \(name)\r\nContent-Disposition: attachment; \(filename)\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            + file.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    static func makeBoundary(_ kind: String) -> String {
        "vimail-\(kind)-\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    }

    // MARK: - Headers

    static func address(_ address: EmailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        if !name.allSatisfy(\.isASCII) { return "\(encodedWords(name)) <\(address.email)>" }
        let needsQuotes = name.contains { "()<>[]:;@\\,.\"".contains($0) }
        let shown = needsQuotes ? "\"\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" : name
        return "\(shown) <\(address.email)>"
    }

    static func addressHeader(_ name: String, _ addresses: [EmailAddress]) -> String {
        "\(name): " + addresses.map(address).joined(separator: ",\r\n ")
    }

    static func unstructuredHeader(_ name: String, _ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if clean.allSatisfy(\.isASCII) { return fold("\(name): \(clean)") }
        return "\(name): \(encodedWords(clean))"
    }

    /// RFC 2047 B-encoded words of at most 75 characters, split on character boundaries,
    /// joined by folding whitespace.
    static func encodedWords(_ text: String) -> String {
        var words: [String] = []
        var chunk = ""
        for character in text {
            let candidate = chunk + String(character)
            // "=?UTF-8?B?" + base64 + "?=" must stay within 75 characters: 45 bytes encode to 60.
            if candidate.utf8.count > 45, !chunk.isEmpty {
                words.append(chunk)
                chunk = String(character)
            } else {
                chunk = candidate
            }
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    /// Folds an ASCII header line at spaces so lines stay under 78 characters where possible.
    static func fold(_ line: String) -> String {
        guard line.count > 78 else { return line }
        var lines: [String] = []
        var current = ""
        for word in line.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count > 78 {
                lines.append(current)
                current = String(word)
            } else {
                current += " " + word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\r\n ")
    }

    /// `name="file.pdf"`, or the RFC 2231 form for names outside ASCII.
    static func parameter(_ key: String, _ value: String) -> String {
        let sanitized = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        if sanitized.allSatisfy({ $0.isASCII && $0 != "\"" && $0 != "\\" }) {
            return "\(key)=\"\(sanitized)\""
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "!#$&+-.^_`|~")
        let encoded = sanitized.addingPercentEncoding(withAllowedCharacters: allowed) ?? sanitized
        return "\(key)*=UTF-8''\(encoded)"
    }

    static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: - Quoted-printable

    /// RFC 2045 quoted-printable for UTF-8 text. Line breaks become CRLF; lines wrap at 76 characters.
    static func quotedPrintable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var output: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let bytes = Array(line.utf8)
            var encoded: [String] = []
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                switch byte {
                case 0x20, 0x09:
                    // Trailing whitespace would be stripped in transit, so it is encoded.
                    encoded.append(isLast ? String(format: "=%02X", byte) : String(UnicodeScalar(byte)))
                case 0x21...0x3C, 0x3E...0x7E:
                    encoded.append(String(UnicodeScalar(byte)))
                default:
                    encoded.append(String(format: "=%02X", byte))
                }
            }
            // Soft line breaks: at most 75 characters plus "=" per physical line, never inside "=XX".
            var physical = ""
            for token in encoded {
                if physical.count + token.count > 75 {
                    output.append(physical + "=")
                    physical = ""
                }
                physical += token
            }
            output.append(physical)
        }
        return output.joined(separator: "\r\n")
    }
}
