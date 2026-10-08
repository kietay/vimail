import Foundation
import MailCore

/// Markdown to email-safe HTML. Every element carries inline styles, because many mail clients
/// strip `<style>` blocks. Single newlines become line breaks, as people expect in email.
///
/// Supported: paragraphs, `#` headings, `**bold**`, `*italic*`, `~~strike~~`, `` `code` ``,
/// fenced code blocks, `> quotes`, `-`/`*`/`1.` lists (nested by indentation), `[links](url)`,
/// bare URLs, `<autolinks>`, and `---` rules.
public enum Markdown {
    enum Style {
        static let paragraph = "margin:0 0 12px 0;"
        static let heading = [
            1: "font-size:22px;font-weight:600;margin:18px 0 10px 0;line-height:1.3;",
            2: "font-size:18px;font-weight:600;margin:16px 0 8px 0;line-height:1.3;",
            3: "font-size:16px;font-weight:600;margin:14px 0 6px 0;line-height:1.3;",
        ]
        static let quote = "margin:0 0 12px 0;padding:0 0 0 12px;border-left:3px solid #d0d7de;color:#57606a;"
        static let code = "font-family:SFMono-Regular,Menlo,Consolas,monospace;font-size:0.92em;background:#f3f4f6;padding:1px 4px;border-radius:4px;"
        static let pre = "font-family:SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;line-height:1.45;background:#f6f8fa;padding:12px;border-radius:6px;margin:0 0 12px 0;white-space:pre-wrap;"
        static let list = "margin:0 0 12px 0;padding-left:24px;"
        static let item = "margin:2px 0;"
        static let link = "color:#0b57d0;"
        static let rule = "border:none;border-top:1px solid #d0d7de;margin:16px 0;"
    }

    public static func html(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return renderBlocks(lines[...])
    }

    // MARK: - Blocks

    private static func renderBlocks(_ lines: ArraySlice<String>) -> String {
        var output: [String] = []
        var index = lines.startIndex
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            output.append("<p style=\"\(Style.paragraph)\">\(paragraph.map(inline).joined(separator: "<br>"))</p>")
            paragraph = []
        }

        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.endIndex, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index = min(index + 1, lines.endIndex)
                output.append("<pre style=\"\(Style.pre)\"><code>\(HTMLText.escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                let level = min(heading, 3)
                output.append("<h\(level) style=\"\(Style.heading[level]!)\">\(inline(text))</h\(level)>")
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                output.append("<hr style=\"\(Style.rule)\">")
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.endIndex {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var content = current.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    quoted.append(String(content))
                    index += 1
                }
                output.append("<blockquote style=\"\(Style.quote)\">\(renderBlocks(quoted[...]))</blockquote>")
                continue
            }

            if let first = listMarker(line) {
                flushParagraph()
                let baseIndent = indentation(line)
                // Same list type at the same depth, so "- a" then "1. b" become two lists.
                func continues(_ candidate: String) -> Bool {
                    guard let marker = listMarker(candidate) else { return indentation(candidate) > baseIndent }
                    return indentation(candidate) > baseIndent + 1 || marker.ordered == first.ordered
                }
                var items: [String] = []
                while index < lines.endIndex {
                    let current = lines[index]
                    if current.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line ends the list unless the next line continues it.
                        let next = index + 1
                        if next < lines.endIndex, listMarker(lines[next]) != nil, continues(lines[next]) { index += 1; continue }
                        break
                    }
                    if !items.isEmpty, !continues(current) { break }
                    if listMarker(current) == nil, indentation(current) == 0 { break }
                    items.append(current)
                    index += 1
                }
                output.append(renderList(items[...]))
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return output.joined(separator: "\n")
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func indentation(_ line: String) -> Int {
        var width = 0
        for char in line {
            if char == " " { width += 1 } else if char == "\t" { width += 4 } else { break }
        }
        return width
    }

    /// Returns (ordered, content) when the line is a list item.
    private static func listMarker(_ line: String) -> (ordered: Bool, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            return (false, String(trimmed.dropFirst(2)))
        }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = trimmed.dropFirst(digits.count)
            if let marker = rest.first, ".)".contains(marker), rest.dropFirst().first == " " {
                return (true, String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    /// Renders list lines, nesting deeper-indented items.
    private static func renderList(_ lines: ArraySlice<String>) -> String {
        guard let first = lines.first, let firstMarker = listMarker(first) else { return "" }
        let baseIndent = indentation(first)
        let tag = firstMarker.ordered ? "ol" : "ul"
        var items: [String] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            guard let marker = listMarker(line), indentation(line) <= baseIndent + 1 else {
                index += 1
                continue
            }
            var content = inline(marker.content)
            var childStart = index + 1
            var childEnd = childStart
            while childEnd < lines.endIndex, indentation(lines[childEnd]) > baseIndent + 1 {
                childEnd += 1
            }
            if childEnd > childStart {
                let children = lines[childStart..<childEnd]
                if children.contains(where: { listMarker($0) != nil }) {
                    content += renderList(children)
                } else {
                    content += "<br>" + children.map { inline($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: "<br>")
                }
            }
            items.append("<li style=\"\(Style.item)\">\(content)</li>")
            childStart = childEnd
            index = childEnd
        }
        return "<\(tag) style=\"\(Style.list)\">\(items.joined())</\(tag)>"
    }

    // MARK: - Inline

    static func inline(_ text: String) -> String {
        var stash: [String] = []
        func protect(_ html: String) -> String {
            stash.append(html)
            return "\u{E000}\(stash.count - 1)\u{E001}"
        }

        // 1. Code spans keep their content literally.
        var working = replace(text, #"`([^`]+)`"#) { groups in
            protect("<code style=\"\(Style.code)\">\(HTMLText.escape(groups[1]))</code>")
        }
        // 2. Escape everything else.
        working = escapeKeepingPlaceholders(working)
        // 3. Links and URLs become protected anchors.
        working = replace(working, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { groups in
            protect("<a href=\"\(groups[2])\" style=\"\(Style.link)\">\(groups[1])</a>")
        }
        working = replace(working, #"&lt;((?:https?://|mailto:)[^\s&]+)&gt;"#) { groups in
            protect("<a href=\"\(groups[1])\" style=\"\(Style.link)\">\(groups[1])</a>")
        }
        working = replace(working, #"(?<![\w/=">])(https?://[^\s<\x{E000}]+[^\s<.,;:!?)\]\x{E000}])"#) { groups in
            protect("<a href=\"\(groups[1])\" style=\"\(Style.link)\">\(groups[1])</a>")
        }
        // 4. Emphasis.
        working = replace(working, #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#) { "<strong>\($0[1])</strong>" }
        working = replace(working, #"(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])"#) { "<strong>\($0[1])</strong>" }
        working = replace(working, #"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#) { "<em>\($0[1])</em>" }
        working = replace(working, #"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#) { "<em>\($0[1])</em>" }
        working = replace(working, #"~~(?=\S)(.+?)(?<=\S)~~"#) { "<del>\($0[1])</del>" }
        // 5. Restore protected HTML.
        return replace(working, "\u{E000}(\\d+)\u{E001}") { groups in stash[Int(groups[1]) ?? 0] }
    }

    private static func escapeKeepingPlaceholders(_ text: String) -> String {
        HTMLText.escape(text).replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            var groups: [String] = []
            for group in 0..<match.numberOfRanges {
                let range = match.range(at: group)
                groups.append(range.location == NSNotFound ? "" : source.substring(with: range))
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        return result
    }
}
