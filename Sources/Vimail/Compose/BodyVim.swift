import AppKit
import VimailKit

/// Vim keys in the compose body's text view (not the embedded editor, that is `VimSession`).
/// Runs `InlineVim` against the focused NSTextView and draws a block cursor in normal mode.
@MainActor
final class BodyVim {
    private(set) var engine = InlineVim()
    private weak var textView: NSTextView?
    private var block: NSView?
    private var savedCaretColor: NSColor?
    private var observers: [NSObjectProtocol] = []

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var mode: InlineVim.Mode { engine.mode }
    var pendingDisplay: String { engine.pendingDisplay }

    func handle(_ stroke: KeyStroke, in textView: NSTextView) -> InlineVim.Outcome {
        attach(textView)
        let text = textView.string
        var buffer = InlineVim.Buffer(text: text, cursor: Self.characterOffset(utf16: textView.selectedRange().location, in: text))
        let outcome = engine.handle(stroke, buffer: &buffer)
        guard outcome == .handled else { return outcome }
        if buffer.text != text { replace(text, with: buffer.text, in: textView) }
        let location = NSRange(location: Self.utf16Offset(characters: buffer.cursor, in: buffer.text), length: 0)
        textView.setSelectedRange(location)
        textView.scrollRangeToVisible(location)
        updateBlock()
        return outcome
    }

    /// Insert mode again (the body lost focus). Text typed since the last Esc becomes one undo step.
    func reset() {
        let buffer = textView.map { view in
            InlineVim.Buffer(text: view.string, cursor: Self.characterOffset(utf16: view.selectedRange().location, in: view.string))
        }
        engine.reset(buffer: buffer)
        updateBlock()
    }

    // MARK: - Text view

    private func attach(_ view: NSTextView) {
        guard view !== textView else { return }
        detach()
        textView = view
        let center = NotificationCenter.default
        for name in [NSTextView.didChangeSelectionNotification, NSView.frameDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBlock() }
            })
        }
    }

    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        block?.removeFromSuperview()
        block = nil
        if let savedCaretColor { textView?.insertionPointColor = savedCaretColor }
        savedCaretColor = nil
        textView = nil
    }

    /// Replaces only the part that changed, through the text view, so SwiftUI's binding and ⌘Z see it.
    private func replace(_ old: String, with new: String, in view: NSTextView) {
        let before = Array(old), after = Array(new)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let start = String(before[..<prefix]).utf16.count
        let length = String(before[prefix..<before.count - suffix]).utf16.count
        let range = NSRange(location: start, length: length)
        let replacement = String(after[prefix..<after.count - suffix])
        guard view.shouldChangeText(in: range, replacementString: replacement) else { return }
        view.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: view.typingAttributes))
        view.didChangeText()
    }

    // MARK: - Block cursor

    /// Normal mode shows a block over the character under the cursor instead of the caret.
    private func updateBlock() {
        guard let view = textView else { return }
        guard engine.mode == .normal, view.window?.firstResponder === view, let window = view.window else {
            block?.isHidden = true
            if let savedCaretColor { view.insertionPointColor = savedCaretColor }
            savedCaretColor = nil
            return
        }
        if savedCaretColor == nil {
            savedCaretColor = view.insertionPointColor
            view.insertionPointColor = .clear
        }
        let block = self.block ?? makeBlock(in: view)
        let location = view.selectedRange().location
        let string = view.string as NSString
        let onCharacter = location < string.length && !CharacterSet.newlines.contains(Unicode.Scalar(string.character(at: location)) ?? " ")
        let range = onCharacter ? string.rangeOfComposedCharacterSequence(at: location) : NSRange(location: location, length: 0)
        var rect = view.convert(window.convertFromScreen(view.firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
        let font = view.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        if rect.width < 1 { rect.size.width = ("0" as NSString).size(withAttributes: [.font: font]).width }
        // The line height without the extra line spacing, at the top of the line.
        let height = min(rect.height, ceil(font.ascender - font.descender + font.leading))
        if !view.isFlipped { rect.origin.y += rect.height - height }
        rect.size.height = height
        block.frame = rect.integral
        block.layer?.backgroundColor = (savedCaretColor ?? .textColor).withAlphaComponent(0.45).cgColor
        block.isHidden = false
    }

    private func makeBlock(in view: NSTextView) -> NSView {
        let block = PassthroughView()
        block.wantsLayer = true
        block.layer?.cornerRadius = 1.5
        view.addSubview(block)
        self.block = block
        return block
    }
}

/// Never takes mouse clicks, so clicks reach the text under the block.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension BodyVim {
    static func characterOffset(utf16 offset: Int, in text: String) -> Int {
        var units = 0, characters = 0
        for character in text {
            if units >= offset { break }
            units += character.utf16.count
            characters += 1
        }
        return characters
    }

    static func utf16Offset(characters offset: Int, in text: String) -> Int {
        text.prefix(offset).utf16.count
    }
}
