import Testing
@testable import VimailKit

/// Plays the text view: text with "|" at the cursor, keys in vim notation. Typing in insert
/// mode goes into the buffer, as the text view would do it.
private struct Editor {
    var vim = InlineVim()
    var buffer: InlineVim.Buffer
    var lastOutcome: InlineVim.Outcome?

    init(_ marked: String, insert: Bool = false) {
        var chars = Array(marked)
        let cursor = chars.firstIndex(of: "|") ?? chars.count
        if cursor < chars.count { chars.remove(at: cursor) }
        buffer = InlineVim.Buffer(text: String(chars), cursor: cursor)
        guard !insert else { return }
        _ = vim.handle(KeyStroke(.escape), buffer: &buffer)
        buffer.cursor = cursor
    }

    var marked: String {
        var chars = Array(buffer.text)
        chars.insert("|", at: min(buffer.cursor, chars.count))
        return String(chars)
    }

    mutating func press(_ keys: String) {
        for token in Keymap.tokens(keys) { press(Self.stroke(token)) }
    }

    mutating func press(_ stroke: KeyStroke) {
        lastOutcome = vim.handle(stroke, buffer: &buffer)
        guard lastOutcome == .passThrough, vim.mode == .insert else { return }
        var chars = Array(buffer.text)
        switch stroke.key {
        case .char(let character): chars.insert(character, at: buffer.cursor); buffer.cursor += 1
        case .space: chars.insert(" ", at: buffer.cursor); buffer.cursor += 1
        case .enter: chars.insert("\n", at: buffer.cursor); buffer.cursor += 1
        case .backspace where buffer.cursor > 0: chars.remove(at: buffer.cursor - 1); buffer.cursor -= 1
        default: break
        }
        buffer.text = String(chars)
    }

    static func stroke(_ token: String) -> KeyStroke {
        switch token {
        case "<Esc>": return KeyStroke(.escape)
        case "<CR>": return KeyStroke(.enter)
        case "<Space>": return KeyStroke(.space)
        case "<BS>": return KeyStroke(.backspace)
        default:
            if token.hasPrefix("<C-") { return KeyStroke(.char(token.dropFirst(3).first!), control: true) }
            if token.hasPrefix("<D-") { return KeyStroke(.char(token.dropFirst(3).first!), command: true) }
            return .char(Character(token))
        }
    }
}

private func run(_ marked: String, _ keys: String) -> String {
    var editor = Editor(marked)
    editor.press(keys)
    return editor.marked
}

@Suite("Inline vim: motions")
struct InlineVimMotionTests {
    @Test func words() {
        #expect(run("|hello world foo", "w") == "hello |world foo")
        #expect(run("|hello world foo", "2w") == "hello world |foo")
        #expect(run("|hello world foo", "e") == "hell|o world foo")
        #expect(run("hello world |foo", "b") == "hello |world foo")
        #expect(run("|foo.bar baz", "w") == "foo|.bar baz")
        #expect(run("|foo.bar baz", "W") == "foo.bar |baz")
        #expect(run("foo.bar |baz", "B") == "|foo.bar baz")
        #expect(run("|one\n\ntwo", "w") == "one\n|\ntwo")
        #expect(run("one\n\n|two", "b") == "one\n|\ntwo")
    }

    @Test func line() {
        #expect(run("hello |world", "0") == "|hello world")
        #expect(run("|hello world", "$") == "hello worl|d")
        #expect(run("  |  hello", "^") == "    |hello")
        #expect(run("|hello world", "l") == "h|ello world")
        #expect(run("hell|o", "l") == "hell|o")
        #expect(run("|hello", "h") == "|hello")
    }

    @Test func linesKeepTheColumn() {
        #expect(run("abc|def\nab\nabcdef", "j") == "abcdef\na|b\nabcdef")
        #expect(run("abc|def\nab\nabcdef", "jj") == "abcdef\nab\nabc|def")
        #expect(run("abcdef\nab\nab|cdef", "kk") == "ab|cdef\nab\nabcdef")
        #expect(run("a|bc\nabcdef", "$j") == "abc\nabcde|f")
        #expect(run("a\nb\n|c", "j") == "a\nb\n|c")
        #expect(run("|a\nb\nc", "9j") == "a\nb\n|c")
    }

    @Test func fileAndParagraphs() {
        #expect(run("|a\nb\nc", "G") == "a\nb\n|c")
        #expect(run("a\nb\n|c", "gg") == "|a\nb\nc")
        #expect(run("|a\nb\nc", "2G") == "a\n|b\nc")
        #expect(run("|a\nb\n\nc", "}") == "a\nb\n|\nc")
        #expect(run("a\nb\n\n|c", "{") == "a\nb\n|\nc")
    }

    @Test func find() {
        #expect(run("|a-b-c-d", "f-") == "a|-b-c-d")
        #expect(run("|a-b-c-d", "2f-") == "a-b|-c-d")
        #expect(run("|a-b-c-d", "f-;") == "a-b|-c-d")
        #expect(run("|a-b-c-d", "t-") == "|a-b-c-d")
        #expect(run("|a-b-c-d", "t-;") == "a-|b-c-d")
        #expect(run("a-b-c-|d", "F-") == "a-b-c|-d")
        #expect(run("a-b-c-|d", "T-") == "a-b-c-|d")
        #expect(run("a-b-c-|d", "F-,") == "a-b-c|-d")
        #expect(run("|abc", "fz") == "|abc")
    }
}

@Suite("Inline vim: editing")
struct InlineVimEditingTests {
    @Test func deleteWithMotions() {
        #expect(run("|foo bar baz", "dw") == "|bar baz")
        #expect(run("|foo bar baz", "d2w") == "|baz")
        #expect(run("|foo bar baz", "2dw") == "|baz")
        #expect(run("foo |bar\nbaz", "dw") == "foo| \nbaz")
        #expect(run("|foo bar", "de") == "| bar")
        #expect(run("foo |bar", "db") == "|bar")
        #expect(run("hello |world", "D") == "hello| ")
        #expect(run("hello |world", "d0") == "|world")
        #expect(run("foo(|abc)", "dt)") == "foo(|)")
        #expect(run("|abcdef", "3x") == "|def")
        #expect(run("ab|c", "x") == "a|b")
        #expect(run("ab|c", "X") == "a|c")
    }

    @Test func deleteLines() {
        #expect(run("a\n|b\nc", "dd") == "a\n|c")
        #expect(run("a\n|b", "dd") == "|a")
        #expect(run("|a\nb\nc", "2dd") == "|c")
        #expect(run("|a\nb\nc", "dj") == "|c")
        #expect(run("a\n|b\nc", "dG") == "|a")
        #expect(run("|only", "dd") == "|")
        #expect(run("|a\nb\n\nc", "d}") == "|\nc")
        #expect(run("|a\nb\n\nc", "dap") == "|c")
        #expect(run("x\n\n|a\nb\n\nc", "dip") == "x\n\n|\nc")
    }

    @Test func change() {
        #expect(run("|foo bar", "cwxyz<Esc>") == "xy|z bar")
        #expect(run("fo|o bar", "cwx<Esc>") == "fo|x bar")
        #expect(run("|foo bar", "c2wx<Esc>") == "|x")
        #expect(run("hello |world", "C!<Esc>") == "hello |!")
        #expect(run("  |foo\nbar", "ccx<Esc>") == "|x\nbar")
        #expect(run("|abc", "sX<Esc>") == "|Xbc")
        #expect(run("|", "Shi<Esc>") == "h|i")
    }

    @Test func textObjects() {
        #expect(run("foo b|ar baz", "diw") == "foo | baz")
        #expect(run("foo b|ar baz", "daw") == "foo |baz")
        #expect(run("foo b|az", "daw") == "fo|o")
        #expect(run("say \"h|i there\" now", "ci\"bye<Esc>") == "say \"by|e\" now")
        #expect(run("say \"h|i there\" now", "da\"") == "say |now")
        #expect(run("|say \"hi\" now", "di\"") == "say \"|\" now")
        #expect(run("foo(a, |b) bar", "di(") == "foo(|) bar")
        #expect(run("foo(a, |b) bar", "da(") == "foo| bar")
        #expect(run("f(a, (b|)) c", "dib") == "f(a, (|)) c")
        #expect(run("x [1, |2] y", "ci]0<Esc>") == "x [|0] y")
        #expect(run("x {a|} y", "da{") == "x | y")
    }

    @Test func yankAndPut() {
        #expect(run("|a\nb", "yyp") == "a\n|a\nb")
        #expect(run("a\n|b", "yyP") == "a\n|b\nb")
        #expect(run("a\n|b", "yyp") == "a\nb\n|b")
        #expect(run("|abc", "xp") == "b|ac")
        #expect(run("|foo bar", "ywP") == "foo| foo bar")
        #expect(run("|a\nb\nc", "ddp") == "b\n|a\nc")
        #expect(run("|ab", "yl3p") == "aaa|ab")
        #expect(run("|ab", "p") == "|ab")
    }

    @Test func smallChanges() {
        #expect(run("|foo\n  bar", "J") == "foo| bar")
        #expect(run("|a\nb\nc", "3J") == "a b| c")
        #expect(run("a|bc", "rx") == "a|xc")
        #expect(run("|abc", "3rx") == "xx|x")
        #expect(run("|abc", "~~") == "AB|c")
        #expect(run("- a\n|- b", ">>") == "- a\n  |- b")
        #expect(run("- a\n    |- b", "<<") == "- a\n  |- b")
        #expect(run("|a\nb\nc", ">j") == "  |a\n  b\nc")
    }

    @Test func insertCommands() {
        #expect(run("f|oo", "ix<Esc>") == "f|xoo")
        #expect(run("f|oo", "ax<Esc>") == "fo|xo")
        #expect(run("  f|oo", "Ix<Esc>") == "  |xfoo")
        #expect(run("f|oo", "A!<Esc>") == "foo|!")
        #expect(run("f|oo\nbaz", "obar<Esc>") == "foo\nba|r\nbaz")
        #expect(run("foo\n|baz", "Obar<Esc>") == "foo\nba|r\nbaz")
        #expect(run("|", "ahi<Esc>") == "h|i")
    }
}

@Suite("Inline vim: undo, repeat and modes")
struct InlineVimStateTests {
    @Test func undoAndRedo() {
        #expect(run("|foo bar", "dwu") == "|foo bar")
        #expect(run("|foo bar", "dwu<C-r>") == "|bar")
        #expect(run("|a b c", "dwdwuu") == "|a b c")
        #expect(run("|foo bar", "cwxyz<Esc>u") == "|foo bar")
        #expect(run("|foo", "u") == "|foo")
        #expect(run("|foo", "yyu") == "|foo")
    }

    @Test func typingBeforeTheFirstEscIsOneUndoStep() {
        var editor = Editor("|", insert: true)
        editor.press("hello<Esc>u")
        #expect(editor.marked == "|")
    }

    @Test func dotRepeats() {
        #expect(run("|a b c d", "dw..") == "|d")
        #expect(run("|abcd", "x.") == "|cd")
        #expect(run("|foo\nfoo", "ciwbar<Esc>j0.") == "bar\nba|r")
        #expect(run("|a\nb\nc\nd", "dd2.") == "|d")
        #expect(run("|x\ny", "A;<Esc>j.") == "x;\ny|;")
        #expect(run("|abc", "rz.") == "|zbc")
        #expect(run("|a b c d", "dw.u") == "|b c d")
        // Motions between changes are not part of them.
        #expect(run("|abc\ndef", "xj.") == "bc\n|ef")
        #expect(run("|ab cd ef", "2wx") == "ab cd |f")
        #expect(run("|ab cd ef", "wxwu") == "ab |cd ef")
    }

    @Test func escapeAndPending() {
        var editor = Editor("|foo")
        editor.press("<Esc>")
        #expect(editor.lastOutcome == .escape)
        editor.press("2d")
        #expect(editor.vim.pendingDisplay == "2d")
        editor.press("<Esc>")
        #expect(editor.lastOutcome == .handled)
        #expect(editor.vim.pendingDisplay == "")
        editor.press("w")
        #expect(editor.marked == "fo|o")
        editor.press("2h")
        #expect(editor.vim.pendingDisplay == "")
    }

    @Test func modes() {
        var editor = Editor("foo|", insert: true)
        #expect(editor.vim.mode == .insert)
        editor.press("<Esc>")
        #expect(editor.vim.mode == .normal)
        #expect(editor.marked == "fo|o")
        editor.press("<C-[>")
        #expect(editor.lastOutcome == .escape)
        editor.press("<D-v>")
        #expect(editor.lastOutcome == .passThrough)
        editor.press("a")
        #expect(editor.vim.mode == .insert)
        editor.vim.reset()
        #expect(editor.vim.mode == .insert)
    }

    @Test func unicode() {
        #expect(run("héllo |👋 wörld", "x") == "héllo | wörld")
        #expect(run("|héllo wörld", "w") == "héllo |wörld")
        #expect(run("|é👋é", "$") == "é👋|é")
    }

    @Test func emptyBuffer() {
        #expect(run("|", "x") == "|")
        #expect(run("|", "dd") == "|")
        #expect(run("|", "jkwbe$0G") == "|")
        #expect(run("|", "p") == "|")
    }
}
