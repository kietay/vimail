import MailCore
import SwiftUI
import WebKit

/// The reader column: the persistent web view, a pinned action bar, and a focus indicator
/// for vim-style pane focus.
struct ReaderPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ReaderWebViewHost(webView: model.reader.webView)
            if model.cursorID != nil {
                ReaderActionBar()
            }
        }
        .background(theme.reader.opacity(0.95))
        .overlay(alignment: .leading) {
            if model.focus == .reader {
                Rectangle().fill(theme.green).frame(width: 2)
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reply / Reply all / Forward, always at the same place at the bottom of the reader.
private struct ReaderActionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                if model.cursorID?.hasPrefix("draft:") == true {
                    ActionButton(title: "Edit draft", icon: .edit, key: "↵", primary: true) { model.openCurrent() }
                    ActionButton(title: "Discard", icon: .trash, key: "#", primary: false) { model.trash() }
                } else {
                    ActionButton(title: "Reply", icon: .reply, key: "r", primary: true) { model.reply(all: false) }
                    if model.canReplyAll {
                        ActionButton(title: "Reply all", icon: .reply, key: "a", primary: false) { model.reply(all: true) }
                    }
                    ActionButton(title: "Forward", icon: .arrow, key: "f", primary: false) { model.forward() }
                }
                Spacer()
            }
            // Matches the reader's text inset (px-6, xl:px-9).
            .padding(.horizontal, geometry.size.width >= 1000 ? 36 : 24)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 72)
        .background(theme.reader)
        .overlay(alignment: .top) { Rectangle().fill(theme.border.opacity(0.5)).frame(height: 1) }
    }
}

private struct ActionButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: IconName
    let key: String
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: primary ? 10 : 8) {
                Icon(name: icon, size: primary ? 15 : 14)
                Text(title).font(AppFonts.sans(11, primary ? .medium : .regular)).cssLine(11)
                KeyChip(key)
            }
            .foregroundStyle(primary ? theme.green : (hovering ? theme.foreground : theme.mutedForeground))
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(primary ? theme.greenSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? .clear : theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hintScope()
        .help("\(title) (\(key))")
    }
}

struct ReaderWebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
