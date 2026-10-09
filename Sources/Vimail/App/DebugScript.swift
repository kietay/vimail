#if DEBUG
import AppKit
import WebKit

/// Debug builds only: replays a key script through the real event path (key router, text
/// fields, vim parser) so flows can be exercised without synthetic input permissions.
///
///     VIMAIL_SCRIPT='wait:1500 j j / type:coffee <CR> wait:500 e' build/app.noindex/vimail.app/Contents/MacOS/vimail
///
/// Tokens: single characters, vim notation (`<Esc> <CR> <Tab> <Space> <BS> <Up> <Down> <C-d> <D-k> <S-Space>`),
/// `type:text` (types characters), `wait:ms`, `activate` (bring the window to the front), `hide` (hide the app),
/// `snapshot:name` (saves the reader as `snapshots/name.png` in the data folder, and as `name.json`: which
/// messages are collapsed, focused and on screen).
@MainActor
enum DebugScript {
    static func runIfRequested() {
        guard let script = ProcessInfo.processInfo.environment["VIMAIL_SCRIPT"], !script.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(1_000))
            for token in script.split(separator: " ").map(String.init) {
                if token.hasPrefix("wait:"), let ms = Int(token.dropFirst(5)) {
                    try? await Task.sleep(for: .milliseconds(ms))
                    continue
                }
                if token == "activate" {
                    NSApp.activate(ignoringOtherApps: true)
                    MainWindow.shared?.makeKeyAndOrderFront(nil)
                    continue
                }
                if token == "hide" {
                    NSApp.hide(nil)
                    continue
                }
                if token.hasPrefix("snapshot:") {
                    await snapshot(named: String(token.dropFirst(9)))
                    continue
                }
                if token.hasPrefix("type:") {
                    // Characters, with vim notation (<Space>, <CR>, <Esc>, ...) for special keys.
                    var text = Substring(token.dropFirst(5))
                    while let first = text.first {
                        if first == "<", let close = text.firstIndex(of: ">"), text.distance(from: text.startIndex, to: close) > 1 {
                            post(token: String(text[...close]))
                            text = text[text.index(after: close)...]
                        } else {
                            post(character: String(first), keyCode: 0, flags: [])
                            text = text.dropFirst()
                        }
                        try? await Task.sleep(for: .milliseconds(15))
                    }
                } else {
                    post(token: token)
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private static func snapshot(named name: String) async {
        guard case .success(let model) = AppContainer.shared else { return }
        let directory = AppPaths.root.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let webView = model.reader.webView
        if let json = try? await webView.evaluateJavaScript(readerLayoutScript) as? String {
            try? Data(json.utf8).write(to: directory.appendingPathComponent("\(name).json"))
        }
        if let image = try? await webView.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private static let readerLayoutScript = """
    (() => {
      const top = window.scrollY;
      return JSON.stringify({
        subject: document.querySelector('h1.subject')?.textContent ?? null,
        header: document.querySelector('.message.multi') ? document.querySelector('header.thread .time').textContent : null,
        readToggle: document.querySelector('.menu [data-action="toggleRead"] .label')?.textContent ?? null,
        scrollY: Math.round(top), viewport: window.innerHeight, height: document.documentElement.scrollHeight,
        messages: Array.from(document.querySelectorAll('.message')).map((node) => {
          const box = node.getBoundingClientRect();
          return {
            index: Number(node.dataset.index), from: node.querySelector('.name')?.textContent ?? null,
            isNew: node.querySelector('.message-head .unread-dot') !== null,
            classes: node.className.trim().split(/\\s+/), onScreen: box.bottom > 0 && box.top < window.innerHeight,
            top: Math.round(box.top + top), height: Math.round(box.height),
          };
        }),
      });
    })()
    """

    private static let specialKeys: [String: UInt16] = [
        "Esc": 53, "CR": 36, "Tab": 48, "Space": 49, "BS": 51, "Up": 126, "Down": 125, "Left": 123, "Right": 124,
    ]

    private static func post(token: String) {
        guard token.hasPrefix("<"), token.hasSuffix(">"), token.count > 2 else {
            for character in token { post(character: String(character), keyCode: 0, flags: []) }
            return
        }
        var body = String(token.dropFirst().dropLast())
        var flags: NSEvent.ModifierFlags = []
        while body.count > 2, body.dropFirst().first == "-" {
            switch body.first {
            case "C": flags.insert(.control)
            case "D": flags.insert(.command)
            case "S": flags.insert(.shift)
            case "A": flags.insert(.option)
            default: break
            }
            body = String(body.dropFirst(2))
        }
        if let code = specialKeys[body] {
            let characters = body == "Space" ? " " : body == "CR" ? "\r" : body == "Tab" ? "\t" : body == "Esc" ? "\u{1b}" : ""
            post(character: characters, keyCode: code, flags: flags)
        } else {
            post(character: body, keyCode: 0, flags: flags)
        }
    }

    private static func post(character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let window = MainWindow.shared,
              let event = NSEvent.keyEvent(
                  with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber, context: nil, characters: character,
                  charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode
              ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
#endif
