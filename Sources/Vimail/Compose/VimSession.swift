import AppKit
import Foundation
import SwiftTerm
import SwiftUI

/// Runs your editor ($VISUAL, $EDITOR or nvim, resolved by your login shell) on the draft body,
/// inside a terminal view in the compose panel. Every `:w` updates the draft; `:q` returns.
///
/// Your normal config loads (`~/.config/nvim`, `~/.vimrc`). For mail-only settings, create
/// `~/.config/vimail/vimrc`; it is sourced after your config.
@MainActor
final class VimSession: NSObject, LocalProcessTerminalViewDelegate {
    let file: URL
    private let command: String
    private var lastModified: Date?
    private var pollTask: Task<Void, Never>?
    private(set) var terminal: LocalProcessTerminalView?
    var onChange: ((String) -> Void)?
    var onExit: ((String?) -> Void)?

    static var mailVimrc: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/vimail/vimrc")
    }

    init(file: URL, command: String) {
        self.file = file
        self.command = command.trimmingCharacters(in: .whitespaces)
        super.init()
        lastModified = modificationDate()
    }

    /// The shell command line that starts the editor on `$VIMAIL_FILE`.
    var shellCommand: String {
        let editor = command.isEmpty ? "${VISUAL:-${EDITOR:-nvim}}" : command
        var extra = ""
        if FileManager.default.fileExists(atPath: Self.mailVimrc.path) {
            extra = " -c 'source \(Self.mailVimrc.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return "exec \(editor)\(extra) \"$VIMAIL_FILE\""
    }

    func makeTerminal(palette: Palette) -> LocalProcessTerminalView {
        if let terminal { return terminal }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.processDelegate = self
        view.font = AppFonts.monoNSFont(13)
        view.optionAsMetaKey = true
        apply(palette, to: view)

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["VIMAIL_FILE"] = file.path
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        // Background hint for vim's light/dark detection; explicit settings in your config still win.
        environment["COLORFGBG"] = palette.isDark ? "15;0" : "0;15"
        let shell = environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        view.startProcess(
            executable: shell,
            args: ["-l", "-c", shellCommand],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: file.deletingLastPathComponent().path
        )
        terminal = view
        startPolling()
        return view
    }

    func apply(_ palette: Palette, to view: TerminalView) {
        view.nativeBackgroundColor = NSColor(hex: palette.reader)
        view.nativeForegroundColor = NSColor(hex: palette.foreground)
        view.caretColor = NSColor(hex: palette.primary)
        let ansi: [String] = palette.isDark
            ? ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
               "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]
            : ["#eeeeee", "#af0000", "#008700", "#5f8700", "#0087af", "#878787", "#005f87", "#444444",
               "#bcbcbc", "#d70000", "#d70087", "#8700af", "#d75f00", "#d75f00", "#005faf", "#005f87"]
        view.installColors(ansi.map { hex in
            let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
            return SwiftTerm.Color(red8: UInt16((value >> 16) & 0xFF), green8: UInt16((value >> 8) & 0xFF), blue8: UInt16(value & 0xFF))
        })
    }

    func focusTerminal() {
        guard let terminal else { return }
        terminal.window?.makeFirstResponder(terminal)
    }

    /// Ends the editor (when compose closes). Text saved with :w is already in the draft.
    func stop() {
        pollTask?.cancel()
        if let terminal, terminal.process?.running == true { terminal.terminate() }
        terminal = nil
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
    }

    private func readFile() -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                let modified = self.modificationDate()
                if modified != self.lastModified {
                    self.lastModified = modified
                    if let text = self.readFile() { self.onChange?(text) }
                }
            }
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.pollTask?.cancel()
            let text = self.readFile()
            self.terminal = nil
            self.onExit?(text)
        }
    }
}

/// Hosts the session's terminal view in SwiftUI and gives it keyboard focus.
struct VimTerminalView: NSViewRepresentable {
    let session: VimSession
    let palette: Palette

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let terminal = session.makeTerminal(palette: palette)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let terminal = session.terminal { session.apply(palette, to: terminal) }
    }
}
