import AppKit
import SwiftTerm
import VimailKit

/// Sends key presses in the main window to the vim keymap before AppKit sees them.
/// Text fields get their keys (insert mode) except Esc and a few control keys; the embedded
/// vim terminal gets every key.
@MainActor
final class KeyboardRouter {
    static let shared = KeyboardRouter()
    private var monitor: Any?
    private weak var model: AppModel?

    func install(_ model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { KeyboardRouter.shared.route(event) }
            return handled ? nil : event
        }
    }

    private func route(_ event: NSEvent) -> Bool {
        guard let model, let window = event.window, window === MainWindow.shared else { return false }
        let responder = window.firstResponder
        let terminalFocused = Self.isInsideTerminal(responder)
        let textFocused = !terminalFocused && Self.isTextInput(responder)

        // ⌘⇧[ and ⌘⇧] cycle views (matched by key code so it works on any layout).
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !terminalFocused, flags.contains(.command), flags.contains(.shift), model.compose == nil, model.overlay == nil {
            if event.keyCode == 30 { model.cycleViews(1); return true }
            if event.keyCode == 33 { model.cycleViews(-1); return true }
        }
        guard let stroke = Self.stroke(from: event) else { return false }
        // A multi-line text view (the compose body), not the field editor of a one-line text field.
        let textView = (responder as? NSTextView).flatMap { $0.isFieldEditor ? nil : $0 }
        return model.handleKey(stroke, context: .init(textFocused: textFocused, terminalFocused: terminalFocused, textView: textView))
    }

    private static func isInsideTerminal(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is TerminalView { return true }
            view = current.superview
        }
        return false
    }

    private static func isTextInput(_ responder: NSResponder?) -> Bool {
        if let textView = responder as? NSTextView { return textView.isEditable }
        return responder is NSTextField
    }

    static func stroke(from event: NSEvent) -> KeyStroke? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let special: KeyStroke.Key? = switch event.keyCode {
        case 53: .escape
        case 36, 76: .enter
        case 48: .tab
        case 49: .space
        case 51: .backspace
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 116: .pageUp
        case 121: .pageDown
        case 115: .home
        case 119: .end
        default: nil
        }
        if let special {
            return KeyStroke(special, control: control, command: command, option: option, shift: shift)
        }
        // Shift is already applied ("G", "#"); control and command use the base character.
        guard let character = event.charactersIgnoringModifiers?.first else { return nil }
        return KeyStroke(.char(character), control: control, command: command, option: option)
    }
}
