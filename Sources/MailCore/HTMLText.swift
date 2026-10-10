import Foundation

/// Fast, dependency-free HTML helpers for search indexing, snippets and quoting.
public enum HTMLText {
    /// Text to edit for a description that may be HTML (Google Calendar writes HTML): tags go, link addresses stay
    /// ("the doc (https://…)"). Text that merely contains "<" ("budget < 5k", "Alex <alex@example.com>") stays as it is.
    public static func editableText(_ text: String) -> String {
        guard looksLikeHTML(text) else { return text }
        var html = text.replacingOccurrences(
            of: #"(?is)<a\s[^>]*href\s*=\s*(["'])(.*?)\1[^>]*>(.*?)</a>"#, with: "$3 ($2)", options: .regularExpression
        )
        // Addresses and links in angle brackets ("Alex <alex@example.com>") and a "<" that starts no tag are text.
        html = html.replacingOccurrences(of: #"<((?:[^<>\s]+@[^<>\s]+)|(?:https?://[^<>\s]+))>"#, with: "&lt;$1&gt;", options: .regularExpression)
        html = html.replacingOccurrences(of: #"<(?![a-zA-Z/!])"#, with: "&lt;", options: .regularExpression)
        return plainText(fromHTML: html)
    }

    /// The text has common HTML tags, as the descriptions Google Calendar writes do. Text that merely contains "<" does not.
    public static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: commonTag, options: .regularExpression) != nil
    }

    private static let commonTag =
        #"(?i)</?(a|b|i|u|p|br|div|span|ul|ol|li|strong|em|html|body|font|h[1-6]|table|tr|td|th|blockquote|pre|code|img|hr)(?=[\s/>])[^<>]*>"#

    /// Converts HTML to readable plain text: drops head, style and script blocks, turns block
    /// elements into line breaks, removes tags and decodes entities.
    public static func plainText(fromHTML html: String) -> String {
        var output = String.UnicodeScalarView()
        let scalars = Array(html.unicodeScalars)
        var index = 0
        let count = scalars.count

        func lowercasedTagName(at start: Int) -> (name: String, closing: Bool, end: Int) {
            var i = start + 1
            var closing = false
            if i < count, scalars[i] == "/" { closing = true; i += 1 }
            var name = ""
            while i < count, scalars[i].properties.isAlphabetic || (scalars[i].value >= 48 && scalars[i].value <= 57) {
                name.unicodeScalars.append(scalars[i])
                i += 1
            }
            while i < count, scalars[i] != ">" { i += 1 }
            return (name.lowercased(), closing, i)
        }

        func skipBlock(named name: String, from start: Int) -> Int {
            // Find the matching closing tag, case-insensitively.
            let needle = Array("</\(name)".unicodeScalars)
            var i = start
            while i < count {
                if scalars[i] == "<", i + needle.count <= count {
                    var matches = true
                    for (offset, scalar) in needle.enumerated() {
                        let candidate = scalars[i + offset]
                        if Character(candidate).lowercased() != Character(scalar).lowercased() {
                            matches = false
                            break
                        }
                    }
                    if matches {
                        while i < count, scalars[i] != ">" { i += 1 }
                        return i
                    }
                }
                i += 1
            }
            return count
        }

        let blockTags: Set<String> = ["p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "blockquote", "ul", "ol", "hr", "section", "article", "header", "footer"]

        while index < count {
            let scalar = scalars[index]
            if scalar == "<" {
                // Comments.
                if index + 3 < count, scalars[index + 1] == "!", scalars[index + 2] == "-", scalars[index + 3] == "-" {
                    var i = index + 4
                    while i + 2 < count, !(scalars[i] == "-" && scalars[i + 1] == "-" && scalars[i + 2] == ">") { i += 1 }
                    index = i + 3
                    continue
                }
                let tag = lowercasedTagName(at: index)
                if !tag.closing, ["style", "script", "head", "title"].contains(tag.name) {
                    index = skipBlock(named: tag.name, from: tag.end) + 1
                    continue
                }
                if blockTags.contains(tag.name) {
                    output.append("\n")
                } else if tag.name == "td" || tag.name == "th" {
                    output.append(" ")
                }
                index = tag.end + 1
                continue
            }
            output.append(scalar)
            index += 1
        }

        let decoded = decodeEntities(String(output))
        return collapseWhitespace(decoded)
    }

    /// Collapses runs of spaces and limits blank lines to one.
    public static func collapseWhitespace(_ text: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
            if line.isEmpty {
                blankRun += 1
                if blankRun == 1, !lines.isEmpty { lines.append("") }
            } else {
                blankRun = 0
                lines.append(line)
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
        "zwnj": "", "zwj": "", "shy": "", "euro": "€", "pound": "£", "times": "×", "rarr": "→",
        "larr": "←", "laquo": "«", "raquo": "»", "deg": "°",
    ]

    /// Decodes named and numeric character references (`&amp;`, `&#39;`, `&#x27;`).
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let entity = text[text.index(after: index)..<semicolon]
                var replacement: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    if let value = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) { replacement = String(Character(scalar)) }
                } else if entity.hasPrefix("#") {
                    if let value = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(value) { replacement = String(Character(scalar)) }
                } else {
                    replacement = namedEntities[String(entity).lowercased()]
                }
                if let replacement {
                    result += replacement
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(char)
            index = text.index(after: index)
        }
        return result
    }

    /// Escapes text for safe insertion into HTML.
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(char)
            }
        }
        return result
    }

    /// A single-line preview of up to `length` characters, without quoted replies, signatures,
    /// divider lines ("--------", "*****") or help-desk markers ("Reply above this line").
    public static func snippet(from text: String, length: Int = 200) -> String {
        var lines: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isQuoteHeader(line) || line == "--" || raw == "-- " { break }
            if line.isEmpty || line.hasPrefix(">") || !line.contains(where: { $0.isLetter || $0.isNumber }) { continue }
            let words = line.lowercased().filter { $0.isLetter || $0 == " " }
            if words.contains("reply above this line") || words.contains("type your reply above") { continue }
            lines.append(line)
        }
        let flat = lines.joined(separator: " ")
        if flat.count <= length { return flat }
        return String(flat.prefix(length)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "On Tue, Oct 7, 2026 at 10:42 AM, Alex <a@b.c> wrote:" and similar reply/forward headers.
    public static func isQuoteHeader(_ line: String) -> Bool {
        (line.hasPrefix("On ") && line.hasSuffix("wrote:"))
            || line.hasPrefix("---------- Forwarded message")
            || line.hasPrefix("-----Original Message-----")
    }
}
