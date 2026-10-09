import Foundation

/// A way to leave a mailing list: from a message's `List-Unsubscribe` header (RFC 2369) and
/// `List-Unsubscribe-Post` (RFC 8058), or from an "unsubscribe" link in its text.
public enum UnsubscribeMethod: Hashable, Sendable {
    /// One HTTPS POST unsubscribes (RFC 8058). Nothing opens.
    case oneClick(URL)
    /// An email to the list's address unsubscribes (a `mailto:` in the header).
    case email(to: EmailAddress, subject: String, body: String)
    /// A page where you unsubscribe yourself, in the browser.
    case website(URL)
}

/// An unsubscribe waiting in the outbox.
public struct UnsubscribeRequest: Hashable, Codable, Sendable {
    public enum Method: Hashable, Codable, Sendable {
        /// POST `List-Unsubscribe=One-Click` to this HTTPS address (RFC 8058).
        case oneClick(URL)
        /// An email from the account to the list's unsubscribe address.
        case email(OutgoingMessage)
    }

    public var method: Method
    /// The list's name for messages, for example "The Browser".
    public var list: String

    public init(method: Method, list: String) {
        self.method = method
        self.list = list
    }

    /// The queued form of a method. Nil for a web page: only the browser can do that one.
    public init?(_ method: UnsubscribeMethod, list: String, from: EmailAddress) {
        switch method {
        case .oneClick(let url):
            self.init(method: .oneClick(url), list: list)
        case .email(let to, let subject, let body):
            let domain = from.email.split(separator: "@").last.map(String.init) ?? "vimail.local"
            // Fixed now, so a retry after a timeout can find the copy that already went out.
            let messageID = "<vimail.\(UUID().uuidString.lowercased())@\(domain)>"
            self.init(method: .email(OutgoingMessage(from: from, to: [to], subject: subject, textBody: body, messageID: messageID)), list: list)
        case .website:
            return nil
        }
    }
}

extension MailMessage {
    /// The best way to leave this message's list that its headers offer: one-click (nothing opens,
    /// nothing in Sent), then an email, then a web page. Nil without a usable `List-Unsubscribe`.
    public var listUnsubscribeMethod: UnsubscribeMethod? {
        guard let listUnsubscribe else { return nil }
        let uris = Unsubscribe.uris(in: listUnsubscribe)
        let https = uris.filter { $0.scheme?.lowercased() == "https" }
        if oneClickUnsubscribe == true, let url = https.first { return .oneClick(url) }
        if let email = uris.lazy.compactMap(Unsubscribe.email).first { return email }
        let page = https.first ?? uris.first { $0.scheme?.lowercased() == "http" }
        return page.map(UnsubscribeMethod.website)
    }

    /// True when the message was cached before vimail checked for one-click unsubscribe and its
    /// header has an HTTPS address: downloading it again may find one-click.
    public var needsOneClickCheck: Bool {
        guard oneClickUnsubscribe == nil, let listUnsubscribe else { return false }
        return Unsubscribe.uris(in: listUnsubscribe).contains { $0.scheme?.lowercased() == "https" }
    }

    /// An "unsubscribe" link in the message text, for senders without the header.
    public var unsubscribeLink: URL? {
        htmlBody.flatMap(Unsubscribe.link(inHTML:)) ?? textBody.flatMap(Unsubscribe.link(inText:))
    }
}

extension MailThread {
    /// What unsubscribing acts on: the newest message from someone else whose headers say how,
    /// else the newest with an "unsubscribe" link in its text.
    public func unsubscribeTarget(excluding me: Set<String>) -> (message: MailMessage, method: UnsubscribeMethod)? {
        let received = messages.reversed().filter { !me.contains($0.from.normalized) }
        for message in received {
            if let method = message.listUnsubscribeMethod { return (message, method) }
        }
        for message in received {
            if let link = message.unsubscribeLink { return (message, .website(link)) }
        }
        return nil
    }
}

/// Reads `List-Unsubscribe` headers and finds unsubscribe links in message text.
public enum Unsubscribe {
    /// The https, http and mailto addresses in a `List-Unsubscribe` header, in the sender's order.
    /// Tolerates folded lines and missing angle brackets.
    public static func uris(in header: String) -> [URL] {
        var candidates: [String] = []
        var rest = Substring(header)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            // Whitespace inside the brackets is line folding, not part of the address (RFC 2369).
            candidates.append(String(rest[rest.index(after: open)..<close].filter { !$0.isWhitespace }))
            rest = rest[rest.index(after: close)...]
        }
        if candidates.isEmpty {
            candidates = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return candidates.compactMap { candidate in
            guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { return nil }
            if scheme == "mailto" { return url }
            return (scheme == "https" || scheme == "http") && url.host?.isEmpty == false ? url : nil
        }
    }

    /// A `mailto:` address as an email: the first address, with the subject and body the list asks
    /// for (list servers read commands there). Other fields, such as cc and bcc, are ignored.
    public static func email(_ url: URL) -> UnsubscribeMethod? {
        guard url.scheme?.lowercased() == "mailto", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func field(_ name: String) -> String? {
            guard let value = items.first(where: { $0.name.lowercased() == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        let addresses = components.path.isEmpty ? field("to") ?? "" : components.path
        let address = EmailAddress(email: String(addresses.split(separator: ",").first ?? ""))
        guard address.isValid else { return nil }
        // Short and on one line: the email is sent from your account.
        let subject = field("subject").map { String($0.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200)) } ?? "Unsubscribe"
        let body = field("body").map { String($0.prefix(1_000)) } ?? "Unsubscribe"
        return .email(to: address, subject: subject, body: body)
    }

    private static let anchors = try! NSRegularExpression(
        pattern: #"<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let words = try! NSRegularExpression(pattern: #"unsubscribe|opt[\s_-]?out"#, options: .caseInsensitive)
    private static let webAddresses = try! NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#, options: .caseInsensitive)

    static func mentionsUnsubscribe(_ text: String) -> Bool {
        words.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The last link whose text says "unsubscribe" or "opt out", else the last whose address does.
    /// Footers come last, so the last match is the footer's.
    public static func link(inHTML html: String) -> URL? {
        // Most mail never says it: one quick scan before looking at every link (the reader asks on each render).
        guard mentionsUnsubscribe(html) else { return nil }
        var byText: URL?
        var byAddress: URL?
        let source = html as NSString
        for match in anchors.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            guard let href = (1...3).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }),
                  let url = webURL(HTMLText.decodeEntities(source.substring(with: href))) else { continue }
            if mentionsUnsubscribe(HTMLText.plainText(fromHTML: source.substring(with: match.range(at: 4)))) {
                byText = url
            } else if mentionsUnsubscribe(url.absoluteString) {
                byAddress = url
            }
        }
        return byText ?? byAddress
    }

    /// The last web address that says "unsubscribe", is on a line that does, or follows such a line.
    public static func link(inText text: String) -> URL? {
        guard mentionsUnsubscribe(text) else { return nil }
        var result: URL?
        var previousLineAsks = false
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let mentions = mentionsUnsubscribe(line)
            let source = line as NSString
            let found = webAddresses.matches(in: line, range: NSRange(location: 0, length: source.length))
            for match in found {
                let address = source.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                if let url = webURL(address), mentions || previousLineAsks || mentionsUnsubscribe(address) { result = url }
            }
            // "To unsubscribe, visit:" with the address on the next line.
            previousLineAsks = mentions && found.isEmpty
        }
        return result
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
