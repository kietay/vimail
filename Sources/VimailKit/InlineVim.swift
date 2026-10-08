import Foundation

/// Vim keys for a plain text editor (the compose body), like Claude Code's vim mode. Esc goes to
/// normal mode: motions, operators with motions or text objects, one register, undo and `.`.
/// `i`, `a`, `o` and friends go back to insert mode, where typing is left to the text view.
///
/// UI-free: the caller passes the text and the cursor with every key and applies what comes back.
/// Positions are Character offsets. The full editor (Ctrl+G) is `VimSession`, not this.
public struct InlineVim: Sendable {
    public enum Mode: Equatable, Sendable { case insert, normal }

    public enum Outcome: Equatable, Sendable {
        /// The key was used. Apply the buffer.
        case handled
        /// The text view handles the key (typing in insert mode, ⌘ shortcuts).
        case passThrough
        /// Esc in normal mode with nothing pending. The caller can leave the editor.
        case escape
    }

    public struct Buffer: Equatable, Sendable {
        public var text: String
        public var cursor: Int

        public init(text: String, cursor: Int) {
            self.text = text
            self.cursor = cursor
        }
    }

    public private(set) var mode: Mode = .insert
    /// Spaces that `>>` adds and `<<` removes. Two nests a Markdown list item.
    public var shiftWidth: Int

    // The command being typed.
    private var count: Int?
    private var operatorCount: Int?
    private var pendingOperator: Operator?
    private var awaiting: Awaiting?
    /// Every key of the command, counts included (for the status bar).
    private var typed: [KeyStroke] = []
    /// The keys of the command without counts (for `.`).
    private var commandKeys: [KeyStroke] = []
    private var commandStart = Snapshot(chars: [], cursor: 0)

    private var register = Register(text: "", linewise: false)
    private var lastFind: Find?
    /// The column `j` and `k` keep (Int.max after `$`).
    private var column: Int?
    private var undoStack: [Buffer] = []
    private var redoStack: [Buffer] = []
    private var lastChange: Change?
    /// The buffer before the change that started insert mode, right after it, and the change itself.
    private var insertStart: Buffer?
    private var insertOrigin: Buffer?
    private var insertCommand: Change?

    private static let undoLimit = 500

    public init(shiftWidth: Int = 2) {
        self.shiftWidth = shiftWidth
    }

    /// The keys of an incomplete command, for example "2d" or "ci".
    public var pendingDisplay: String { typed.map(\.description).joined() }

    /// Back to insert mode with nothing pending, for example when the editor gets focus again.
    /// Pass the buffer so text typed since the last Esc becomes one undo step.
    public mutating func reset(buffer: Buffer? = nil) {
        if mode == .insert, let start = insertStart, let buffer, start.text != buffer.text {
            pushUndo(start)
        }
        clearPending()
        mode = .insert
        insertStart = nil
        insertOrigin = nil
        insertCommand = nil
        column = nil
    }

    public mutating func handle(_ stroke: KeyStroke, buffer: inout Buffer) -> Outcome {
        if mode == .insert {
            guard Self.isEscape(stroke) else {
                // Typing started without a command (the editor got focus): undo goes back to here.
                if insertStart == nil { insertStart = buffer }
                return .passThrough
            }
            var text = Text(buffer.text)
            var cursor = min(max(buffer.cursor, 0), text.count)
            leaveInsert(&text, &cursor)
            buffer.cursor = text.clampNormal(cursor)
            return .handled
        }
        if stroke.command { return .passThrough }
        var text = Text(buffer.text)
        var cursor = text.clampNormal(buffer.cursor)
        let outcome = normalKey(stroke, &text, &cursor)
        if text.modified { buffer.text = String(text.chars) }
        buffer.cursor = mode == .normal ? text.clampNormal(cursor) : min(max(cursor, 0), text.count)
        return outcome
    }

    // MARK: - Normal mode

    private var total: Int { (count ?? 1) * (operatorCount ?? 1) }
    private var hasCount: Bool { count != nil || operatorCount != nil }

    private mutating func normalKey(_ stroke: KeyStroke, _ text: inout Text, _ cursor: inout Int) -> Outcome {
        if Self.isEscape(stroke) {
            if typed.isEmpty { return .escape }
            clearPending()
            return .handled
        }
        if typed.isEmpty { commandStart = Snapshot(chars: text.chars, cursor: cursor) }
        typed.append(stroke)

        if let awaiting {
            self.awaiting = nil
            commandKeys.append(stroke)
            return awaited(awaiting, stroke, &text, &cursor)
        }

        // Counts: 1-9 start one, 0 extends it ("2d3w" is d6w).
        if case .char(let character) = stroke.key, !stroke.control, !stroke.option, character.isASCII,
           let digit = character.wholeNumberValue, digit > 0 || (pendingOperator == nil ? count : operatorCount) != nil {
            if pendingOperator == nil {
                count = min((count ?? 0) * 10 + digit, 9_999)
            } else {
                operatorCount = min((operatorCount ?? 0) * 10 + digit, 9_999)
            }
            return .handled
        }

        commandKeys.append(stroke)
        let key = stroke.description
        let n = total

        if let op = pendingOperator {
            if key == String(op.rawValue) {
                let line = text.lineNumber(cursor)
                return operate(op, .lines(line...min(line + n - 1, text.lastLine)), &text, &cursor)
            }
            switch key {
            case "i", "a": awaiting = .object(inner: key == "i")
            case "f", "F", "t", "T": awaiting = .find(Self.findKind(key))
            case "g": awaiting = .g
            default:
                guard Self.motionKeys.contains(key) else { clearPending(); return .handled }
                let found = motion(key, text, cursor, count: n, for: op)
                return operate(op, motion: found, &text, &cursor)
            }
            return .handled
        }

        if Self.motionKeys.contains(key) {
            move(motion(key, text, cursor, count: n, for: nil), &cursor)
            clearPending()
            return .handled
        }
        if let (op, motionKey) = Self.shortcuts[key] {
            let found = motion(motionKey, text, cursor, count: n, for: op)
            return operate(op, motion: found, &text, &cursor)
        }

        switch key {
        case "f", "F", "t", "T": awaiting = .find(Self.findKind(key))
        case "g": awaiting = .g
        case "r": awaiting = .replace
        case "d", "c", "y", ">", "<": pendingOperator = Operator(rawValue: key.first!)
        case "S", "Y":
            let line = text.lineNumber(cursor)
            return operate(key == "S" ? .change : .yank, .lines(line...min(line + n - 1, text.lastLine)), &text, &cursor)
        case "i": beginInsert(at: cursor, text, &cursor)
        case "a": beginInsert(at: cursor < text.count && !text[cursor].isNewline ? cursor + 1 : cursor, text, &cursor)
        case "I": beginInsert(at: text.firstNonBlank(cursor), text, &cursor)
        case "A": beginInsert(at: text.lineEnd(cursor), text, &cursor)
        case "o", "O":
            let at = key == "o" ? text.lineEnd(cursor) : text.lineStart(cursor)
            text.replace(at..<at, with: ["\n"])
            beginInsert(at: key == "o" ? at + 1 : at, text, &cursor)
        case "p", "P": put(after: key == "p", count: n, &text, &cursor)
        case "J": join(count: n, &text, &cursor)
        case "~": toggleCase(count: n, &text, &cursor)
        case "u": undo(count: n, &text, &cursor)
        case "<C-r>": redo(count: n, &text, &cursor)
        case ".": repeatLastChange(&text, &cursor)
        default: clearPending()
        }
        if mode == .insert || awaiting != nil || pendingOperator != nil { return .handled }
        if ["p", "P", "J", "~"].contains(key) { finishChange(text) }
        clearPending()
        return .handled
    }

    /// The key after `f`, `t`, `r`, `g`, or an operator's `i`/`a`.
    private mutating func awaited(_ awaiting: Awaiting, _ stroke: KeyStroke, _ text: inout Text, _ cursor: inout Int) -> Outcome {
        let n = total
        switch awaiting {
        case .g:
            guard stroke.description == "g" else { clearPending(); return .handled }
            let gg = motion("gg", text, cursor, count: n, for: pendingOperator)
            if let op = pendingOperator { return operate(op, motion: gg, &text, &cursor) }
            move(gg, &cursor)
        case .find(let kind):
            guard let character = Self.literal(stroke), character != "\n" else { clearPending(); return .handled }
            let find = Find(kind: kind, character: character)
            lastFind = find
            let found = findMotion(find, text, cursor, count: n, repeating: false)
            if let op = pendingOperator { return operate(op, motion: found, &text, &cursor) }
            move(found, &cursor)
        case .replace:
            guard let character = Self.literal(stroke) else { clearPending(); return .handled }
            replace(with: character, count: n, &text, &cursor)
            if text.modified { finishChange(text) }
        case .object(let inner):
            guard let op = pendingOperator, let character = Self.literal(stroke),
                  let region = textObject(character, inner: inner, text, cursor) else { clearPending(); return .handled }
            return operate(op, region, &text, &cursor)
        }
        clearPending()
        return .handled
    }

    private mutating func move(_ motion: Motion?, _ cursor: inout Int) {
        guard let motion else { return }
        cursor = motion.target
        column = motion.column
    }

    // MARK: - Motions

    /// `x` is `dl`, `D` is `d$`, and so on.
    private static let shortcuts: [String: (Operator, String)] = [
        "x": (.delete, "l"), "X": (.delete, "h"), "D": (.delete, "$"), "C": (.change, "$"), "s": (.change, "l"),
    ]

    private static let motionKeys: Set<String> = [
        "h", "<Left>", "<BS>", "l", "<Right>", "<Space>", "j", "<Down>", "k", "<Up>", "+", "-", "<CR>",
        "0", "<Home>", "^", "$", "<End>", "w", "W", "b", "B", "e", "E", "G", "{", "}", ";", ",",
    ]

    private func motion(_ key: String, _ text: Text, _ cursor: Int, count n: Int, for op: Operator?) -> Motion? {
        switch key {
        case "h", "<Left>", "<BS>":
            return Motion(target: max(text.lineStart(cursor), cursor - n), kind: .exclusive)
        case "l", "<Right>", "<Space>":
            return Motion(target: min(cursor + n, text.lineEnd(cursor)), kind: .exclusive)
        case "j", "<Down>", "k", "<Up>", "+", "-", "<CR>":
            let down = ["j", "<Down>", "+", "<CR>"].contains(key)
            let line = text.lineNumber(cursor)
            guard (down ? line < text.lastLine : line > 0) else { return nil }
            let start = text.startOfLine(down ? min(line + n, text.lastLine) : max(line - n, 0))
            if ["+", "-", "<CR>"].contains(key) {
                return Motion(target: text.firstNonBlank(start), kind: .linewise)
            }
            let wanted = column ?? cursor - text.lineStart(cursor)
            let length = text.lineEnd(start) - start
            return Motion(target: wanted >= length ? text.lastColumn(start) : start + wanted, kind: .linewise, column: wanted)
        case "0", "<Home>":
            return Motion(target: text.lineStart(cursor), kind: .exclusive)
        case "^":
            return Motion(target: text.firstNonBlank(cursor), kind: .exclusive)
        case "$", "<End>":
            var position = cursor
            for _ in 1..<max(n, 1) {
                let end = text.lineEnd(position)
                guard end < text.count else { break }
                position = end + 1
            }
            return Motion(target: text.lastColumn(position), kind: .inclusive, column: .max)
        case "w", "W":
            let big = key == "W"
            if op == .change, cursor < text.count, text.kind(cursor, big: big) != 0 {
                // "cw" changes to the end of the word, like "ce", but never past the current word.
                var end = text.wordEndInPlace(cursor, big: big)
                for _ in 1..<max(n, 1) { end = text.wordEnd(after: end, big: big) }
                return Motion(target: end, kind: .inclusive)
            }
            var position = cursor
            for step in 0..<n {
                let next = text.wordStart(after: position, big: big)
                // With an operator, the last word moved over ends at its line end, not on the next line.
                if op != nil, step == n - 1 {
                    let end = text.lineEnd(position)
                    if end > position, end < next { position = end; break }
                }
                position = next
            }
            return Motion(target: position, kind: .exclusive)
        case "b", "B":
            var position = cursor
            for _ in 0..<n { position = text.wordStart(before: position, big: key == "B") }
            return Motion(target: position, kind: .exclusive)
        case "e", "E":
            var position = cursor
            for _ in 0..<n { position = text.wordEnd(after: position, big: key == "E") }
            return Motion(target: position, kind: .inclusive)
        case "G", "gg":
            let line = hasCount ? min(max(n - 1, 0), text.lastLine) : (key == "G" ? text.lastLine : 0)
            return Motion(target: text.firstNonBlank(text.startOfLine(line)), kind: .linewise)
        case "}":
            var line = text.lineNumber(cursor)
            for _ in 0..<n {
                while line < text.lastLine, text.isLineEmpty(line) { line += 1 }
                while line < text.lastLine, !text.isLineEmpty(line) { line += 1 }
            }
            return Motion(target: text.isLineEmpty(line) ? text.startOfLine(line) : text.count, kind: .exclusive)
        case "{":
            var line = text.lineNumber(cursor)
            for _ in 0..<n {
                while line > 0, text.isLineEmpty(line) { line -= 1 }
                while line > 0, !text.isLineEmpty(line) { line -= 1 }
            }
            return Motion(target: text.startOfLine(line), kind: .exclusive)
        case ";", ",":
            guard var find = lastFind else { return nil }
            if key == "," { find.kind.forward.toggle() }
            return findMotion(find, text, cursor, count: n, repeating: true)
        default:
            return nil
        }
    }

    /// `f`, `F`, `t`, `T` within the current line.
    private func findMotion(_ find: Find, _ text: Text, _ cursor: Int, count n: Int, repeating: Bool) -> Motion? {
        // Repeating "t" starts one further, so ";" does not stop on the same spot.
        let skip = find.kind.till && repeating ? 1 : 0
        var remaining = n
        if find.kind.forward {
            var index = cursor + 1 + skip
            while index < text.lineEnd(cursor) {
                if text[index] == find.character { remaining -= 1; if remaining == 0 { break } }
                index += 1
            }
            guard remaining == 0 else { return nil }
            return Motion(target: find.kind.till ? index - 1 : index, kind: .inclusive)
        }
        var index = cursor - 1 - skip
        while index >= text.lineStart(cursor) {
            if text[index] == find.character { remaining -= 1; if remaining == 0 { break } }
            index -= 1
        }
        guard remaining == 0 else { return nil }
        return Motion(target: find.kind.till ? index + 1 : index, kind: .exclusive)
    }

    // MARK: - Text objects

    private func textObject(_ character: Character, inner: Bool, _ text: Text, _ cursor: Int) -> Region? {
        switch character {
        case "w", "W": return wordObject(big: character == "W", inner: inner, text, cursor)
        case "\"", "'", "`": return quoteObject(character, inner: inner, text, cursor)
        case "(", ")", "b": return bracketObject("(", ")", inner: inner, text, cursor)
        case "[", "]": return bracketObject("[", "]", inner: inner, text, cursor)
        case "{", "}", "B": return bracketObject("{", "}", inner: inner, text, cursor)
        case "<", ">": return bracketObject("<", ">", inner: inner, text, cursor)
        case "p": return paragraphObject(inner: inner, text, cursor)
        default: return nil
        }
    }

    private func wordObject(big: Bool, inner: Bool, _ text: Text, _ cursor: Int) -> Region? {
        guard cursor < text.count, !text[cursor].isNewline else { return nil }
        let lineStart = text.lineStart(cursor), lineEnd = text.lineEnd(cursor)
        let kind = text.kind(cursor, big: big)
        var start = cursor, end = cursor + 1
        while start > lineStart, text.kind(start - 1, big: big) == kind { start -= 1 }
        while end < lineEnd, text.kind(end, big: big) == kind { end += 1 }
        guard !inner else { return .chars(start..<end) }
        if kind == 0 {
            // On blanks: the blanks and the word after them.
            guard end < lineEnd else { return .chars(start..<end) }
            let next = text.kind(end, big: big)
            while end < lineEnd, text.kind(end, big: big) == next { end += 1 }
            return .chars(start..<end)
        }
        // On a word: the word and the blanks after it, or before it at the end of the line.
        var trailing = end
        while trailing < lineEnd, text[trailing].isBlank { trailing += 1 }
        if trailing > end { return .chars(start..<trailing) }
        while start > lineStart, text[start - 1].isBlank { start -= 1 }
        return .chars(start..<end)
    }

    private func quoteObject(_ quote: Character, inner: Bool, _ text: Text, _ cursor: Int) -> Region? {
        let lineStart = text.lineStart(cursor), lineEnd = text.lineEnd(cursor)
        let quotes = (lineStart..<lineEnd).filter { text[$0] == quote && ($0 == lineStart || text[$0 - 1] != "\\") }
        let open: Int, close: Int
        if let index = quotes.firstIndex(of: cursor) {
            if index % 2 == 0 {
                guard index + 1 < quotes.count else { return nil }
                (open, close) = (quotes[index], quotes[index + 1])
            } else {
                (open, close) = (quotes[index - 1], quotes[index])
            }
        } else {
            let before = quotes.filter { $0 < cursor }.count
            // Inside a pair, or else the first pair after the cursor.
            let first = before % 2 == 1 ? before - 1 : before
            guard first + 1 < quotes.count else { return nil }
            (open, close) = (quotes[first], quotes[first + 1])
        }
        if inner { return .chars(open + 1..<close) }
        var end = close + 1
        while end < lineEnd, text[end].isBlank { end += 1 }
        var start = open
        if end == close + 1 { while start > lineStart, text[start - 1].isBlank { start -= 1 } }
        return .chars(start..<end)
    }

    private func bracketObject(_ open: Character, _ close: Character, inner: Bool, _ text: Text, _ cursor: Int) -> Region? {
        var openIndex: Int?
        if cursor < text.count, text[cursor] == open {
            openIndex = cursor
        } else {
            // On a closing bracket this finds its own opening one.
            var depth = 0
            var index = cursor - 1
            while index >= 0 {
                if text[index] == close { depth += 1 } else if text[index] == open {
                    if depth == 0 { openIndex = index; break }
                    depth -= 1
                }
                index -= 1
            }
        }
        guard let openIndex else { return nil }
        var depth = 0
        var index = openIndex + 1
        while index < text.count {
            if text[index] == open { depth += 1 } else if text[index] == close {
                if depth == 0 { return .chars(inner ? openIndex + 1..<index : openIndex..<index + 1) }
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    private func paragraphObject(inner: Bool, _ text: Text, _ cursor: Int) -> Region {
        let line = text.lineNumber(cursor)
        let blank = text.isLineBlank(line)
        var first = line, last = line
        while first > 0, text.isLineBlank(first - 1) == blank { first -= 1 }
        while last < text.lastLine, text.isLineBlank(last + 1) == blank { last += 1 }
        guard !inner else { return .lines(first...last) }
        // "ap": the paragraph and the blank lines after it (or before it, at the end).
        var extended = last
        while extended < text.lastLine, text.isLineBlank(extended + 1) != blank { extended += 1 }
        if extended > last || blank { return .lines(first...extended) }
        while first > 0, text.isLineBlank(first - 1) { first -= 1 }
        return .lines(first...last)
    }

    // MARK: - Operators

    private mutating func operate(_ op: Operator, motion: Motion?, _ text: inout Text, _ cursor: inout Int) -> Outcome {
        guard let motion, let region = self.region(from: cursor, to: motion, text) else {
            // A change whose motion goes nowhere ("cw" at the end) still starts insert mode.
            if op == .change, motion != nil {
                beginInsert(at: cursor, text, &cursor)
            } else {
                clearPending()
            }
            return .handled
        }
        return operate(op, region, &text, &cursor)
    }

    private func region(from cursor: Int, to motion: Motion, _ text: Text) -> Region? {
        let low = min(cursor, motion.target), high = max(cursor, motion.target)
        switch motion.kind {
        case .linewise:
            return .lines(text.lineNumber(low)...text.lineNumber(high))
        case .inclusive:
            // Never takes the line break under the cursor (for example "d$" on an empty line).
            let end = high < text.count && text[high].isNewline ? high : min(high + 1, text.count)
            return low < end ? .chars(low..<end) : nil
        case .exclusive:
            guard low < high else { return nil }
            // Vim's rule for exclusive motions that end at the start of a later line.
            if text.lineStart(high) == high, text.lineNumber(high) > text.lineNumber(low) {
                if low <= text.firstNonBlank(low) {
                    return .lines(text.lineNumber(low)...text.lineNumber(high) - 1)
                }
                return .chars(low..<high - 1)
            }
            return .chars(low..<high)
        }
    }

    private mutating func operate(_ op: Operator, _ region: Region, _ text: inout Text, _ cursor: inout Int) -> Outcome {
        switch (op, region) {
        case (.indent, _), (.outdent, _):
            let lines = region.lineRange(in: text)
            let starts = text.lineStarts()
            for line in lines.reversed() {
                let start = starts[line], end = text.lineEnd(start)
                if op == .indent {
                    if end > start { text.replace(start..<start, with: Array(repeating: " ", count: shiftWidth)) }
                } else {
                    var index = start
                    while index < end, index - start < shiftWidth, text[index].isBlank {
                        index += 1
                        if text[index - 1] == "\t" { break }
                    }
                    text.replace(start..<index, with: [])
                }
            }
            cursor = text.firstNonBlank(text.startOfLine(lines.lowerBound))
        case (_, .lines(let lines)):
            let start = text.startOfLine(lines.lowerBound)
            let end = text.lineEnd(text.startOfLine(lines.upperBound))
            register = Register(text: String(text.chars[start..<end]), linewise: true)
            switch op {
            case .yank:
                if text.lineNumber(cursor) != lines.lowerBound { cursor = text.firstNonBlank(start) }
            case .change:
                text.replace(start..<end, with: [])
                beginInsert(at: start, text, &cursor)
                return .handled
            default:
                if end < text.count {
                    text.replace(start..<end + 1, with: [])
                } else {
                    text.replace(max(start - 1, 0)..<end, with: [])
                }
                cursor = text.firstNonBlank(text.startOfLine(min(lines.lowerBound, text.lastLine)))
            }
        case (_, .chars(let range)):
            register = Register(text: String(text.chars[range]), linewise: false)
            cursor = range.lowerBound
            if op == .yank { break }
            text.replace(range, with: [])
            if op == .change {
                beginInsert(at: range.lowerBound, text, &cursor)
                return .handled
            }
        }
        if op != .yank { finishChange(text) }
        clearPending()
        return .handled
    }

    // MARK: - Simple changes

    private mutating func put(after: Bool, count n: Int, _ text: inout Text, _ cursor: inout Int) {
        guard register.linewise || !register.text.isEmpty else { return }
        let content = Array(register.text)
        if register.linewise {
            let block = Array(Array(repeating: content + ["\n"], count: n).joined())
            if !after {
                let at = text.lineStart(cursor)
                text.replace(at..<at, with: block)
                cursor = text.firstNonBlank(at)
            } else if text.lineEnd(cursor) < text.count {
                let at = text.lineEnd(cursor) + 1
                text.replace(at..<at, with: block)
                cursor = text.firstNonBlank(at)
            } else {
                // After the last line: the line break goes first.
                let at = text.count
                text.replace(at..<at, with: ["\n"] + block.dropLast())
                cursor = text.firstNonBlank(at + 1)
            }
            return
        }
        let block = Array(Array(repeating: content, count: n).joined())
        let onCharacter = cursor < text.count && !text[cursor].isNewline
        let at = after && onCharacter ? cursor + 1 : cursor
        text.replace(at..<at, with: block)
        cursor = at + block.count - 1
    }

    private mutating func join(count n: Int, _ text: inout Text, _ cursor: inout Int) {
        for _ in 0..<max(n - 1, 1) {
            let end = text.lineEnd(cursor)
            guard end < text.count else { break }
            var next = end + 1
            while next < text.count, text[next].isBlank { next += 1 }
            let lineIsEmpty = end == text.lineStart(end)
            let nextIsEmpty = next >= text.count || text[next].isNewline
            let space = !lineIsEmpty && !nextIsEmpty && !text[end - 1].isBlank && text[next] != ")"
            text.replace(end..<next, with: space ? [" "] : [])
            cursor = end
        }
    }

    private mutating func replace(with character: Character, count n: Int, _ text: inout Text, _ cursor: inout Int) {
        guard cursor + n <= text.lineEnd(cursor) else { return }
        if character.isNewline {
            text.replace(cursor..<cursor + n, with: ["\n"])
            cursor += 1
        } else {
            text.replace(cursor..<cursor + n, with: Array(repeating: character, count: n))
            cursor += n - 1
        }
    }

    private mutating func toggleCase(count n: Int, _ text: inout Text, _ cursor: inout Int) {
        let end = min(cursor + n, text.lineEnd(cursor))
        guard end > cursor else { return }
        let toggled = text.chars[cursor..<end].map { character -> Character in
            let swapped = character.isUppercase ? character.lowercased() : character.uppercased()
            return swapped.count == 1 ? Character(swapped) : character
        }
        text.replace(cursor..<end, with: toggled)
        cursor = end
    }

    // MARK: - Insert mode

    private mutating func beginInsert(at position: Int, _ text: Text, _ cursor: inout Int) {
        insertStart = commandStart.buffer
        insertOrigin = Buffer(text: String(text.chars), cursor: position)
        insertCommand = Change(keys: commandKeys, count: hasCount ? total : nil, inserted: nil)
        cursor = position
        mode = .insert
        clearPending()
    }

    private mutating func leaveInsert(_ text: inout Text, _ cursor: inout Int) {
        mode = .normal
        if let start = insertStart, Array(start.text) != text.chars { pushUndo(start) }
        if var change = insertCommand {
            if let origin = insertOrigin { change.inserted = Self.inserted(origin: origin, final: text.chars) }
            lastChange = change
        }
        insertStart = nil
        insertOrigin = nil
        insertCommand = nil
        column = nil
        if cursor > text.lineStart(cursor) { cursor -= 1 }
    }

    /// The text typed in insert mode, when it went in at one spot.
    private static func inserted(origin: Buffer, final: [Character]) -> String? {
        let before = Array(origin.text), at = origin.cursor
        let added = final.count - before.count
        guard added >= 0, at <= before.count,
              final[..<at].elementsEqual(before[..<at]),
              final[(at + added)...].elementsEqual(before[at...]) else { return nil }
        return String(final[at..<at + added])
    }

    // MARK: - Undo and repeat

    private mutating func finishChange(_ text: Text) {
        if text.modified { pushUndo(commandStart.buffer) }
        lastChange = Change(keys: commandKeys, count: hasCount ? total : nil, inserted: nil)
        column = nil
    }

    private mutating func pushUndo(_ buffer: Buffer) {
        undoStack.append(buffer)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private mutating func undo(count n: Int, _ text: inout Text, _ cursor: inout Int) {
        for _ in 0..<n {
            guard let previous = undoStack.popLast() else { break }
            redoStack.append(Buffer(text: String(text.chars), cursor: cursor))
            text.replaceAll(with: previous.text)
            cursor = previous.cursor
        }
    }

    private mutating func redo(count n: Int, _ text: inout Text, _ cursor: inout Int) {
        for _ in 0..<n {
            guard let next = redoStack.popLast() else { break }
            undoStack.append(Buffer(text: String(text.chars), cursor: cursor))
            text.replaceAll(with: next.text)
            cursor = next.cursor
        }
    }

    private mutating func repeatLastChange(_ text: inout Text, _ cursor: inout Int) {
        guard let change = lastChange else { return }
        // A count on "." replaces the change's own count.
        let times = hasCount ? total : change.count
        clearPending()
        let keys = (times.map { String($0).map(KeyStroke.char) } ?? []) + change.keys
        for key in keys { _ = normalKey(key, &text, &cursor) }
        if mode == .insert {
            if let inserted = change.inserted {
                text.replace(cursor..<cursor, with: Array(inserted))
                cursor += inserted.count
            }
            leaveInsert(&text, &cursor)
        }
    }

    private mutating func clearPending() {
        count = nil
        operatorCount = nil
        pendingOperator = nil
        awaiting = nil
        typed = []
        commandKeys = []
    }

    // MARK: - Keys

    private static func isEscape(_ stroke: KeyStroke) -> Bool {
        if case .escape = stroke.key { return true }
        if case .char("[") = stroke.key, stroke.control { return true }
        return false
    }

    /// The character a key types, for `f`, `r` and text objects.
    private static func literal(_ stroke: KeyStroke) -> Character? {
        guard !stroke.control, !stroke.command else { return nil }
        switch stroke.key {
        case .char(let character): return character
        case .space: return " "
        case .tab: return "\t"
        case .enter: return "\n"
        default: return nil
        }
    }

    private static func findKind(_ key: String) -> Find.Kind {
        Find.Kind(forward: key == "f" || key == "t", till: key == "t" || key == "T")
    }
}

// MARK: - Supporting types

extension InlineVim {
    private enum Operator: Character {
        case delete = "d", change = "c", yank = "y", indent = ">", outdent = "<"
    }

    private enum Awaiting {
        case g, find(Find.Kind), replace, object(inner: Bool)
    }

    private struct Find {
        struct Kind {
            var forward: Bool
            var till: Bool
        }

        var kind: Kind
        var character: Character
    }

    private struct Motion {
        enum Kind { case exclusive, inclusive, linewise }
        var target: Int
        var kind: Kind
        /// The column for later `j`/`k`; nil forgets it.
        var column: Int?
    }

    private enum Region {
        case chars(Range<Int>)
        /// Line numbers.
        case lines(ClosedRange<Int>)

        func lineRange(in text: Text) -> ClosedRange<Int> {
            switch self {
            case .lines(let lines): lines
            case .chars(let range): text.lineNumber(range.lowerBound)...text.lineNumber(max(range.lowerBound, range.upperBound - 1))
            }
        }
    }

    private struct Register {
        var text: String
        var linewise: Bool
    }

    private struct Change {
        var keys: [KeyStroke]
        var count: Int?
        /// What was typed after the change started insert mode.
        var inserted: String?
    }

    private struct Snapshot {
        var chars: [Character]
        var cursor: Int
        var buffer: Buffer { Buffer(text: String(chars), cursor: cursor) }
    }
}

/// The buffer as Characters, with line and word helpers. A line break belongs to the line it ends.
private struct Text {
    private(set) var chars: [Character]
    private(set) var modified = false

    init(_ string: String) { chars = Array(string) }

    var count: Int { chars.count }
    subscript(index: Int) -> Character { chars[index] }

    mutating func replace(_ range: Range<Int>, with new: [Character]) {
        guard !range.isEmpty || !new.isEmpty else { return }
        chars.replaceSubrange(range, with: new)
        modified = true
    }

    mutating func replaceAll(with string: String) {
        chars = Array(string)
        modified = true
    }

    // Lines

    func lineStart(_ index: Int) -> Int {
        var start = min(index, count)
        while start > 0, !chars[start - 1].isNewline { start -= 1 }
        return start
    }

    /// The index of the line break, or the end of the text.
    func lineEnd(_ index: Int) -> Int {
        var end = max(index, 0)
        while end < count, !chars[end].isNewline { end += 1 }
        return end
    }

    /// The last place the cursor can be on the line in normal mode.
    func lastColumn(_ index: Int) -> Int {
        let start = lineStart(index), end = lineEnd(index)
        return end > start ? end - 1 : start
    }

    func firstNonBlank(_ index: Int) -> Int {
        let start = lineStart(index), end = lineEnd(index)
        var position = start
        while position < end, chars[position].isBlank { position += 1 }
        return position < end ? position : lastColumn(index)
    }

    func clampNormal(_ index: Int) -> Int {
        let index = min(max(index, 0), count)
        let start = lineStart(index), end = lineEnd(index)
        return end > start ? min(index, end - 1) : start
    }

    func lineNumber(_ index: Int) -> Int {
        chars[..<min(max(index, 0), count)].reduce(0) { $1.isNewline ? $0 + 1 : $0 }
    }

    var lastLine: Int { lineNumber(count) }

    func lineStarts() -> [Int] {
        [0] + chars.indices.filter { chars[$0].isNewline }.map { $0 + 1 }
    }

    func startOfLine(_ line: Int) -> Int {
        guard line > 0 else { return 0 }
        var seen = 0
        for index in chars.indices where chars[index].isNewline {
            seen += 1
            if seen == line { return index + 1 }
        }
        return count
    }

    func isLineEmpty(_ line: Int) -> Bool {
        let start = startOfLine(line)
        return lineEnd(start) == start
    }

    func isLineBlank(_ line: Int) -> Bool {
        let start = startOfLine(line)
        return chars[start..<lineEnd(start)].allSatisfy(\.isBlank)
    }

    // Words

    /// 0 blank or line break, 1 punctuation (any non-blank for WORDs), 2 letters, digits and "_".
    func kind(_ index: Int, big: Bool) -> Int {
        let character = chars[index]
        if character.isWhitespace { return 0 }
        if big { return 1 }
        return character.isLetter || character.isNumber || character == "_" ? 2 : 1
    }

    /// An empty line is a word of its own for `w` and `b`.
    private func isEmptyLine(at index: Int) -> Bool {
        index < count && chars[index].isNewline && lineStart(index) == index
    }

    func wordStart(after index: Int, big: Bool) -> Int {
        guard index < count else { return count }
        var position = index
        let start = kind(position, big: big)
        if start != 0 { while position < count, kind(position, big: big) == start { position += 1 } }
        while position < count, kind(position, big: big) == 0 {
            if position != index, isEmptyLine(at: position) { return position }
            position += 1
        }
        return position
    }

    func wordStart(before index: Int, big: Bool) -> Int {
        guard index > 0 else { return 0 }
        var position = min(index, count) - 1
        while position > 0, kind(position, big: big) == 0 {
            if isEmptyLine(at: position) { return position }
            position -= 1
        }
        let word = kind(position, big: big)
        guard word != 0 else { return position }
        while position > 0, kind(position - 1, big: big) == word { position -= 1 }
        return position
    }

    func wordEnd(after index: Int, big: Bool) -> Int {
        var position = index + 1
        while position < count, kind(position, big: big) == 0 { position += 1 }
        guard position < count else { return max(count - 1, 0) }
        let word = kind(position, big: big)
        while position + 1 < count, kind(position + 1, big: big) == word { position += 1 }
        return position
    }

    /// The end of the word under the cursor.
    func wordEndInPlace(_ index: Int, big: Bool) -> Int {
        let word = kind(index, big: big)
        var position = index
        while position + 1 < count, kind(position + 1, big: big) == word { position += 1 }
        return position
    }
}

private extension Character {
    /// Space or tab, not a line break.
    var isBlank: Bool { isWhitespace && !isNewline }
}
