import Foundation

/// One key press, normalized: shifted characters are folded into the character ("G", "#").
public struct KeyStroke: Hashable, Sendable, CustomStringConvertible {
    public enum Key: Hashable, Sendable {
        case char(Character)
        case escape, enter, tab, space, backspace
        case up, down, left, right, pageUp, pageDown, home, end
    }

    public var key: Key
    public var control = false
    public var command = false
    public var option = false
    /// Only meaningful for non-character keys (for example Shift+Space).
    public var shift = false

    public init(_ key: Key, control: Bool = false, command: Bool = false, option: Bool = false, shift: Bool = false) {
        self.key = key
        self.control = control
        self.command = command
        self.option = option
        self.shift = shift
    }

    public static func char(_ character: Character) -> KeyStroke { KeyStroke(.char(character)) }

    /// Vim notation: "j", "G", "<C-d>", "<Esc>", "<CR>", "<S-Space>", "<D-k>".
    public var description: String {
        let name: String
        var bracketed = control || command || option
        switch key {
        case .char(let character):
            name = String(character)
        case .escape: name = "Esc"; bracketed = true
        case .enter: name = "CR"; bracketed = true
        case .tab: name = "Tab"; bracketed = true
        case .space: name = "Space"; bracketed = true
        case .backspace: name = "BS"; bracketed = true
        case .up: name = "Up"; bracketed = true
        case .down: name = "Down"; bracketed = true
        case .left: name = "Left"; bracketed = true
        case .right: name = "Right"; bracketed = true
        case .pageUp: name = "PageUp"; bracketed = true
        case .pageDown: name = "PageDown"; bracketed = true
        case .home: name = "Home"; bracketed = true
        case .end: name = "End"; bracketed = true
        }
        guard bracketed else { return name }
        var prefix = ""
        if command { prefix += "D-" }
        if control { prefix += "C-" }
        if option { prefix += "A-" }
        if shift, case .char = key {} else if shift { prefix += "S-" }
        return "<\(prefix)\(name)>"
    }
}

public enum GoTarget: String, Hashable, Sendable, CaseIterable {
    case inbox, starred, sent, drafts, archive, snoozed, spam, trash, allMail
}

/// What a key sequence asks the app to do. The app decides what it means in the current
/// context (for example `.down` moves the list cursor or scrolls the reader).
public enum KeyCommand: Hashable, Sendable {
    case down, up, top, bottom, halfPageDown, halfPageUp, pageDown, pageUp
    case focusList, focusReader, open, back, escape
    case nextMessage, previousMessage, expandAll
    case nextThread, previousThread
    case readerPageDown, readerPageUp
    case visual, toggleSelection, selectAll, clearSelection
    case archive, trash, spam, toggleStar, markUnread, markRead
    case label, move, snooze, quickSnooze, undo, redo, repeatLast
    case compose, reply, replyAll, forward
    case go(GoTarget), goLabel, manageViews, nextView, previousView
    case search, omnibox, help, sync, toggleSidebar, openAttachments
    /// Why the conversation carries its labels, and rules that decided no.
    case explainLabels
    /// Every enabled rule on the selection now.
    case runRules
}

public enum Keymap {
    /// The vim-first hybrid keymap. Multi-key sequences use vim notation.
    public static let defaults: [(String, KeyCommand)] = [
        // Motion
        ("j", .down), ("<Down>", .down), ("k", .up), ("<Up>", .up),
        ("gg", .top), ("G", .bottom), ("<Home>", .top), ("<End>", .bottom),
        ("<C-d>", .halfPageDown), ("<C-u>", .halfPageUp),
        ("<C-f>", .pageDown), ("<C-b>", .pageUp), ("<PageDown>", .pageDown), ("<PageUp>", .pageUp),
        // Panes
        ("h", .focusList), ("<Left>", .focusList), ("l", .focusReader), ("<Right>", .focusReader),
        ("<CR>", .open), ("o", .open), ("q", .back), ("<Esc>", .escape),
        // Reader
        ("n", .nextMessage), ("p", .previousMessage), ("O", .expandAll),
        ("J", .nextThread), ("K", .previousThread),
        ("<Space>", .readerPageDown), ("<S-Space>", .readerPageUp),
        ("ga", .go(.archive)),
        // Selection
        ("v", .visual), ("V", .visual), ("x", .toggleSelection), ("*a", .selectAll), ("*n", .clearSelection),
        // Actions
        ("e", .archive), ("#", .trash), ("dd", .trash), ("!", .spam), ("s", .toggleStar),
        ("U", .markUnread), ("I", .markRead), ("t", .label), ("m", .move), ("z", .snooze), ("b", .quickSnooze),
        ("u", .undo), ("<C-r>", .redo), (".", .repeatLast),
        // Writing
        ("c", .compose), ("r", .reply), ("a", .replyAll), ("f", .forward),
        // Go to
        ("gi", .go(.inbox)), ("gs", .go(.starred)), ("gt", .go(.sent)), ("gd", .go(.drafts)),
        ("gz", .go(.snoozed)), ("g!", .go(.spam)), ("g#", .go(.trash)), ("gA", .go(.allMail)),
        ("gl", .goLabel), ("gv", .manageViews), ("L", .nextView), ("H", .previousView),
        ("go", .openAttachments),
        // Rules
        ("g?", .explainLabels), ("=", .runRules),
        // Modes and app
        ("/", .search), (":", .omnibox), ("<D-k>", .omnibox), ("?", .help), ("<C-l>", .sync),
        ("<C-\\>", .toggleSidebar),
    ]

    /// Splits "gg" or "<C-d>x" into tokens.
    public static func tokens(_ sequence: String) -> [String] {
        var tokens: [String] = []
        var index = sequence.startIndex
        while index < sequence.endIndex {
            if sequence[index] == "<", let close = sequence[index...].firstIndex(of: ">"), sequence.distance(from: index, to: close) > 1 {
                tokens.append(String(sequence[index...close]))
                index = sequence.index(after: close)
            } else {
                tokens.append(String(sequence[index]))
                index = sequence.index(after: index)
            }
        }
        return tokens
    }
}

/// Turns key presses into commands: counts ("5j"), multi-key sequences ("gg", "dd", "gi"),
/// and pending-state display for the status bar.
public struct KeySequenceParser: Sendable {
    public enum Result: Equatable, Sendable {
        case command(KeyCommand, count: Int)
        /// Waiting for more keys.
        case pending
        /// Not a binding. The pending sequence was cleared.
        case unbound
    }

    private var bindings: [String: KeyCommand] = [:]
    private var prefixes: Set<String> = []
    public private(set) var pending: [String] = []
    public private(set) var count: Int?

    public init(bindings: [(String, KeyCommand)] = Keymap.defaults) {
        for (sequence, command) in bindings {
            let tokens = Keymap.tokens(sequence)
            self.bindings[tokens.joined(separator: " ")] = command
            for length in 1..<max(tokens.count, 1) where tokens.count > 1 {
                prefixes.insert(tokens.prefix(length).joined(separator: " "))
            }
        }
    }

    /// What the status bar shows while a sequence is incomplete (for example "3d").
    public var display: String {
        (count.map(String.init) ?? "") + pending.joined()
    }

    public var isPending: Bool { !pending.isEmpty || count != nil }

    public mutating func reset() {
        pending = []
        count = nil
    }

    public mutating func feed(_ stroke: KeyStroke) -> Result {
        if case .escape = stroke.key, isPending {
            reset()
            return .unbound
        }
        // Counts: 1-9 start a count, 0 extends it.
        if pending.isEmpty, case .char(let character) = stroke.key, !stroke.control, !stroke.command, !stroke.option,
           let digit = character.wholeNumberValue, character.isASCII, digit > 0 || count != nil {
            count = min((count ?? 0) * 10 + digit, 9_999)
            return .pending
        }

        let token = stroke.description
        let candidate = (pending + [token]).joined(separator: " ")
        if let command = bindings[candidate] {
            let times = count ?? 1
            reset()
            return .command(command, count: times)
        }
        if prefixes.contains(candidate) {
            pending.append(token)
            return .pending
        }
        reset()
        return .unbound
    }
}
