import Foundation

/// A mailbox address such as `Alex Morgan <alex@studionorth.co>`.
public struct EmailAddress: Hashable, Codable, Sendable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased address, used for identity comparisons.
    public var normalized: String { email.lowercased() }

    public var displayName: String { name ?? email }

    /// First name, or the local part of the address when there is no name.
    public var shortName: String {
        if let name {
            let words = name.split(separator: " ")
            if let first = words.first { return String(first) }
        }
        return String(email.split(separator: "@").first ?? Substring(email))
    }

    /// One or two letters for avatars: "Alex Morgan" -> "AM", "Linear" -> "L", "The Browser" -> "B".
    public var initials: String {
        let source = name ?? String(email.split(separator: "@").first ?? "")
        let words = source
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            .filter { $0.lowercased() != "the" }
        let letters = words.compactMap { $0.first(where: \.isLetter) }
        switch letters.count {
        case 0: return "?"
        case 1: return String(letters[0]).uppercased()
        default:
            // Single brand names ("Are.na") keep one letter; personal names use first + last.
            if name == nil || words.count == 1 { return String(letters[0]).uppercased() }
            return (String(letters[0]) + String(letters[letters.count - 1])).uppercased()
        }
    }

    /// RFC 5322 form, quoting the display name when it contains special characters.
    public var formatted: String {
        guard let name else { return email }
        let needsQuotes = name.contains { ",;:<>@\"()[]\\".contains($0) }
        let shown = needsQuotes ? "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\"" : name
        return "\(shown) <\(email)>"
    }

    public var isValid: Bool {
        let parts = email.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !email.contains(" ")
    }

    /// Parses one address: `Name <a@b.c>`, `"Last, First" <a@b.c>`, `<a@b.c>` or `a@b.c`.
    public static func parse(_ raw: String) -> EmailAddress? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let email = String(text[text.index(after: open)..<close])
            var name = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            let address = EmailAddress(name: name, email: email)
            return address.email.isEmpty ? nil : address
        }
        return EmailAddress(email: text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
    }

    /// Splits a header value on commas or semicolons that are outside quotes and angle brackets.
    public static func parseList(_ raw: String) -> [EmailAddress] {
        var results: [EmailAddress] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var previous: Character = " "
        for char in raw {
            switch char {
            case "\"" where previous != "\\": inQuotes.toggle()
            case "<" where !inQuotes: inAngle = true
            case ">" where !inQuotes: inAngle = false
            default: break
            }
            if (char == "," || char == ";") && !inQuotes && !inAngle {
                if let address = parse(current) { results.append(address) }
                current = ""
            } else {
                current.append(char)
            }
            previous = char
        }
        if let address = parse(current) { results.append(address) }
        return results
    }

    /// Splits text typed into a recipient field into finished addresses and the part still being
    /// typed. A comma or semicolon outside quotes and angle brackets finishes the addresses before
    /// it; a closing `>` finishes `Name <a@b.c>`.
    public static func splitTyped(_ raw: String) -> (finished: [EmailAddress], typing: String) {
        var lastSeparator: String.Index?
        var inQuotes = false
        var inAngle = false
        var previous: Character = " "
        for index in raw.indices {
            let char = raw[index]
            switch char {
            case "\"" where previous != "\\": inQuotes.toggle()
            case "<" where !inQuotes: inAngle = true
            case ">" where !inQuotes: inAngle = false
            default: break
            }
            if (char == "," || char == ";") && !inQuotes && !inAngle { lastSeparator = index }
            previous = char
        }
        var finished: [EmailAddress] = []
        var typing = raw
        if let lastSeparator {
            finished = parseList(String(raw[..<lastSeparator]))
            typing = String(raw[raw.index(after: lastSeparator)...])
        }
        typing = String(typing.drop(while: \.isWhitespace))
        if typing.hasSuffix(">"), let address = parse(typing), address.isValid {
            finished.append(address)
            typing = ""
        }
        return (finished, typing)
    }
}

extension Array where Element == EmailAddress {
    /// "Alex Morgan, jamie@x.com"
    public var displayList: String { map(\.displayName).joined(separator: ", ") }
    public var formattedList: String { map(\.formatted).joined(separator: ", ") }

    /// Removes duplicates (case-insensitive) and the given addresses, keeping order.
    public func deduplicated(excluding excluded: Set<String> = []) -> [EmailAddress] {
        var seen = excluded
        return filter { seen.insert($0.normalized).inserted }
    }
}
