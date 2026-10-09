import Foundation

/// Text from other people's mail, made safe to place inside a prompt between `<email>`-style delimiters.
extension HTMLText {
    /// The body text Claude reads, at most `maxCharacters` long.
    ///
    /// Prefers the HTML part (plain-text alternatives are often poor) and falls back to the text part.
    /// Keeps line breaks; cuts quoted replies and `-- ` signatures; drops text hidden by an inline style
    /// or the `hidden` attribute (`display:none`, `opacity:0` and `max-height:0` hide everything inside;
    /// `font-size:0` and `visibility:hidden` hide text until a child sets its own size or
    /// `visibility:visible`); drops zero-width, bidi and other invisible characters and URLs; and
    /// replaces `<` and `>` with `‹` and `›`.
    ///
    /// Not detected: text hidden by classes or `<style>` rules (there is no CSS engine), by colours,
    /// tiny sizes or positions, by values computed with `calc()` or `var()`, or by tag soup in foreign
    /// content or forms, which browsers repair differently.
    public static func promptText(html: String?, text: String?, maxCharacters: Int) -> String {
        var body = ""
        if let html, html.contains(where: { !$0.isWhitespace }) {
            body = promptReady(visibleText(fromHTML: html))
        }
        if body.isEmpty, let text {
            body = promptReady(text)
        }
        return truncated(body, to: maxCharacters)
    }

    /// One line of third-party text (a name, a subject, a file name) made safe for a prompt.
    public static func promptLine(_ text: String) -> String {
        neutralizingDelimiters(removingInvisibleCharacters(text))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func promptReady(_ text: String) -> String {
        // "\r\n" is one Character in Swift, so line handling below needs plain "\n".
        let unixLines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let visible = removingInvisibleCharacters(unixLines)
        let cut = cuttingQuotesAndSignature(visible)
        return collapseWhitespace(neutralizingDelimiters(removingURLs(cut)))
    }

    static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return String(text.prefix(max(limit, 0))) }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    // MARK: - Text cleanup

    /// Zero-width characters, bidi controls, soft hyphens, tag characters and variation selectors:
    /// invisible to a reader, so they can only hide or disguise text.
    static func removingInvisibleCharacters(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isInvisible(scalar) { scalars.append(scalar) }
        return String(scalars)
    }

    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x061C, 0x180E, 0xFEFF: true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069: true
        case 0xFE00...0xFE0F, 0xE0000...0xE007F, 0xE0100...0xE01EF: true
        default: false
        }
    }

    /// Ends the text at the first quoted-reply header or signature separator, and drops `>` lines.
    /// When nothing comes before the header (a plain forward), the forwarded text is kept.
    static func cuttingQuotesAndSignature(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var kept: [String] = []
        var hasContent = false
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            // Long attributions wrap: "On Tue, …, Alex Morgan <" / "alex@studio.co> wrote:".
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            let wrappedHeader = line.hasPrefix("On ") && !next.isEmpty && isQuoteHeader(line + " " + next)
            if isQuoteHeader(line) || wrappedHeader || line == "--" {
                if hasContent { break }
                index += wrappedHeader ? 2 : 1
                continue
            }
            if !line.hasPrefix(">") {
                kept.append(lines[index])
                if !line.isEmpty { hasContent = true }
            }
            index += 1
        }
        return kept.joined(separator: "\n")
    }

    /// Drops words that are links ("https://…", "www.…"), keeping line breaks.
    static func removingURLs(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .filter { word in
                    let lower = word.lowercased()
                    return !lower.contains("://") && !lower.drop(while: { "(<[\"'".contains($0) }).hasPrefix("www.")
                }
                .joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    /// `<` and `>` become `‹` and `›`, so third-party text can never open or close a prompt delimiter.
    static func neutralizingDelimiters(_ text: String) -> String {
        guard text.contains(where: { $0 == "<" || $0 == ">" }) else { return text }
        return text.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
    }


    // MARK: - Visible text

    /// Like `plainText(fromHTML:)`, but nests elements as a browser's parser does and reads their
    /// inline styles, so text shows only where a browser shows it. Source line breaks are spaces, as
    /// in a browser, except inside `<pre>`.
    static func visibleText(fromHTML html: String) -> String {
        let scalars = Array(html.unicodeScalars)
        let tokens = htmlTokens(scalars)
        var elements = OpenElements(tokens)
        var output = String.UnicodeScalarView()
        for token in tokens {
            switch token {
            case .text(let range):
                for scalar in scalars[range] {
                    elements.insertText(whitespace: scalar.properties.isWhitespace)
                    guard elements.showsText else { continue }
                    let lineBreak = scalar == "\n" || scalar == "\r" || scalar == "\t"
                    output.append(lineBreak && !elements.inPre ? " " : scalar)
                }
            case .start(let tag):
                elements.start(tag)
                // An element hidden with its content takes no space either.
                if let separator = separator(after: tag.name), !elements.dropsContent { output.append(separator) }
            case .end(let name):
                let dropped = elements.dropsContent
                elements.end(name)
                if let separator = separator(after: name), !dropped, !elements.dropsContent { output.append(separator) }
            case .literal(let tag, let range):
                elements.start(tag)
                if elements.showsText {
                    output.append("\n")
                    output.append(contentsOf: scalars[range])
                    output.append("\n")
                }
                elements.end(tag.name)
            }
        }
        return collapseWhitespace(decodeEntities(String(output)))
    }

    /// A line break around blocks, a space between table cells.
    static func separator(after name: String) -> Unicode.Scalar? {
        if promptBlockTags.contains(name) { return "\n" }
        return name == "td" || name == "th" ? " " : nil
    }

    /// A piece of HTML. Comments and elements whose content never shows are already left out.
    enum HTMLToken {
        case text(Range<Int>)
        case start(HTMLTag)
        case end(String)
        /// A `<textarea>`, `<xmp>` or `<plaintext>` and its content, which browsers show as typed.
        case literal(HTMLTag, Range<Int>)
    }

    static func htmlTokens(_ scalars: [Unicode.Scalar]) -> [HTMLToken] {
        let count = scalars.count
        var tokens: [HTMLToken] = []
        var textStart = 0
        var index = 0
        while index < count {
            guard scalars[index] == "<" else {
                index += 1
                continue
            }
            var token: HTMLToken?
            var next: Int
            if matches("<!--", in: scalars, at: index) {
                next = (find("-->", in: scalars, from: index + 4) ?? count) + 3
            } else if let tag = HTMLTag(scalars, at: index) {
                next = tag.end + 1
                if tag.closing {
                    token = .end(tag.name)
                } else if rawTextElements.contains(tag.name) {
                    next = findClosingTag(tag.name, in: scalars, from: next) ?? count
                    next = (find(">", in: scalars, from: next) ?? count) + 1
                } else if literalTextElements.contains(tag.name) {
                    // Nothing ends `<plaintext>`.
                    let end = tag.name == "plaintext" ? count : findClosingTag(tag.name, in: scalars, from: next) ?? count
                    token = .literal(tag, min(next, end)..<end)
                    next = end < count ? (find(">", in: scalars, from: end) ?? count) + 1 : count
                } else {
                    token = .start(tag)
                }
            } else if index + 1 < count, scalars[index + 1] == "!" || scalars[index + 1] == "?" || scalars[index + 1] == "/" {
                // <!DOCTYPE …>, <![CDATA[…]]>, <?xml …?>, and "</" without a tag name, which browsers read as a comment.
                next = (find(">", in: scalars, from: index) ?? count) + 1
            } else {
                // Text: "a < b", "<3".
                index += 1
                continue
            }
            if textStart < index { tokens.append(.text(textStart..<index)) }
            if let token { tokens.append(token) }
            index = min(next, count)
            textStart = index
        }
        if textStart < count { tokens.append(.text(textStart..<count)) }
        return tokens
    }

    static let promptBlockTags: Set<String> = [
        "p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "blockquote", "ul", "ol", "hr",
        "section", "article", "header", "footer", "pre", "dt", "dd",
    ]
    /// Left out with their content, which browsers never show as text. `<noscript>` is read like any
    /// other element: scripts never run in mail, so its content shows.
    static let rawTextElements: Set<String> = ["style", "script", "head", "title", "template", "iframe", "noembed", "noframes"]
    /// Shown as typed: tags inside them are text, so they open and close nothing.
    static let literalTextElements: Set<String> = ["textarea", "xmp", "plaintext"]
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    static func removingCSSComments(_ css: String) -> String {
        var result = ""
        var rest = css[...]
        while let start = rest.range(of: "/*") {
            result += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "*/") else { return result }
            rest = rest[end.upperBound...]
        }
        return result + rest
    }

    /// Resolves CSS escapes: `\6e one` and `n\one` both read "none".
    static func unescapingCSS(_ css: String) -> String {
        guard css.contains("\\") else { return css }
        let scalars = Array(css.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\\", index + 1 < scalars.count else {
                output.append(scalars[index])
                index += 1
                continue
            }
            index += 1
            var hex = ""
            while hex.count < 6, index < scalars.count, scalars[index].properties.isASCIIHexDigit {
                hex.unicodeScalars.append(scalars[index])
                index += 1
            }
            if hex.isEmpty {
                output.append(scalars[index])
                index += 1
            } else {
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { output.append(scalar) }
                if index < scalars.count, scalars[index] == " " || scalars[index] == "\n" || scalars[index] == "\t" { index += 1 }
            }
        }
        return String(output)
    }

    static func matches(_ needle: String, in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        matches(Array(needle.unicodeScalars), in: scalars, at: index)
    }

    static func matches(_ pattern: [Unicode.Scalar], in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index + pattern.count <= scalars.count else { return false }
        return pattern.indices.allSatisfy { scalars[index + $0] == pattern[$0] }
    }

    static func find(_ needle: String, in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        let pattern = Array(needle.unicodeScalars)
        var index = start
        while index < scalars.count {
            if scalars[index] == pattern[0], matches(pattern, in: scalars, at: index) { return index }
            index += 1
        }
        return nil
    }

    /// The index of `</name`, case-insensitively.
    static func findClosingTag(_ name: String, in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        let needle = Array("</\(name)".unicodeScalars)
        var index = start
        while index + needle.count <= scalars.count {
            if scalars[index] == "<", needle.indices.allSatisfy({ Character(scalars[index + $0]).lowercased() == Character(needle[$0]).lowercased() }) {
                return index
            }
            index += 1
        }
        return nil
    }
}

/// One start or end tag with its attributes.
struct HTMLTag {
    var name: String
    var closing: Bool
    var attributes: [String: String]
    /// The index of the closing `>` (or the end of the input).
    var end: Int

    /// Parses the tag starting at `scalars[start]` ("<"). Nil when it is not a tag ("a < b", "<3").
    init?(_ scalars: [Unicode.Scalar], at start: Int) {
        let count = scalars.count
        var index = start + 1
        closing = index < count && scalars[index] == "/"
        if closing { index += 1 }
        guard index < count, scalars[index].isASCII, scalars[index].properties.isAlphabetic else { return nil }
        var name = String.UnicodeScalarView()
        while index < count, Self.isNameCharacter(scalars[index]) {
            name.append(scalars[index])
            index += 1
        }
        self.name = String(name).lowercased()
        attributes = [:]
        while index < count, scalars[index] != ">" {
            let scalar = scalars[index]
            if scalar.properties.isWhitespace || scalar == "/" {
                index += 1
                continue
            }
            var attribute = String.UnicodeScalarView()
            while index < count, !scalars[index].properties.isWhitespace, scalars[index] != "=", scalars[index] != ">", scalars[index] != "/" {
                attribute.append(scalars[index])
                index += 1
            }
            if attribute.isEmpty {
                // A stray "=": skip it.
                index += 1
                continue
            }
            while index < count, scalars[index].properties.isWhitespace { index += 1 }
            var value = String.UnicodeScalarView()
            if index < count, scalars[index] == "=" {
                index += 1
                while index < count, scalars[index].properties.isWhitespace { index += 1 }
                if index < count, scalars[index] == "\"" || scalars[index] == "'" {
                    let quote = scalars[index]
                    index += 1
                    while index < count, scalars[index] != quote {
                        value.append(scalars[index])
                        index += 1
                    }
                    index += 1
                } else {
                    while index < count, !scalars[index].properties.isWhitespace, scalars[index] != ">" {
                        value.append(scalars[index])
                        index += 1
                    }
                }
            }
            // As in browsers, the first of repeated attributes wins.
            let key = String(attribute).lowercased()
            if attributes[key] == nil { attributes[key] = HTMLText.decodeEntities(String(value)) }
        }
        end = min(index, count)
    }

    static func isNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-" || scalar == ":" || scalar == "_")
    }
}
