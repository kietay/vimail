import AppKit
import SwiftUI

/// Configures the main window: content under a transparent title bar, frame autosave,
/// and the traffic lights centered vertically in the app's header.
struct WindowConfigurator: NSViewRepresentable {
    let headerHeight: CGFloat
    let background: Color

    final class Coordinator {
        nonisolated(unsafe) var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.backgroundColor = NSColor(background)
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window, coordinator.observers.isEmpty else { return }
        MainWindow.shared = window
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = NSColor(background)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("vimail.main")
        let height = headerHeight
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didEndLiveResizeNotification] {
            coordinator.observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    WindowConfigurator.layoutTrafficLights(window, headerHeight: height)
                }
            })
        }
        WindowConfigurator.layoutTrafficLights(window, headerHeight: height)
    }

    @MainActor
    static func layoutTrafficLights(_ window: NSWindow, headerHeight: CGFloat) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        var frame = container.frame
        frame.size.height = headerHeight
        frame.origin.y = window.frame.height - headerHeight
        container.frame = frame
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 20 + CGFloat(index) * 20, y: (headerHeight - button.frame.height) / 2))
        }
    }
}

@MainActor
enum MainWindow {
    static weak var shared: NSWindow?

    /// Focuses the multi-line text view that is back after the embedded editor quits (:wq): the compose body, or the
    /// event editor's Notes. SwiftUI drops focus requests made before the new text view is in the window, so this
    /// waits for it and asks AppKit, like a click does. SwiftUI's focus state follows.
    static func focusTextView() async {
        for _ in 0..<40 {
            if let textView = shared?.contentView?.firstDescendant(of: NSTextView.self, where: { !$0.isFieldEditor && $0.isEditable }) {
                textView.window?.makeFirstResponder(textView)
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}
