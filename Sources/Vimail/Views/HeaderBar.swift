import MailCore
import SwiftUI

struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            // Room for the window's traffic lights.
            Color.clear.frame(width: 64)
            IconButton(icon: .panel, size: 18, help: model.session.sidebarCollapsed ? "Expand sidebar (^\\)" : "Collapse sidebar (^\\)") {
                withAnimation(.easeOut(duration: 0.2)) { model.session.sidebarCollapsed.toggle() }
            }
            .padding(.trailing, 16)

            Button { model.navigate(to: .mailbox(.inbox)) } label: { logo }
                .buttonStyle(.plain)
                .help("Inbox (gi)")

            HStack(spacing: 4) {
                tab(title: "Inbox", count: nil, active: model.destination == .mailbox(.inbox)) { model.navigate(to: .mailbox(.inbox)) }
                ForEach(model.views.filter(\.pinned)) { view in
                    tab(title: view.name, count: model.counts["view:\(view.id)"], active: model.destination == .view(view.id)) {
                        model.navigate(to: .view(view.id))
                    }
                }
            }
            .padding(.leading, 20)

            Spacer(minLength: 8)

            IconButton(icon: .views, size: 18, help: "Views · ⌘⇧[ / ⌘⇧]") { model.overlay = .views }
                .padding(.leading, 8)
            IconButton(icon: .command, size: 17, help: "Search commands and mail (⌘K)") { model.overlay = .omnibox }
        }
        .padding(.horizontal, 20)
        .frame(height: 70)
        .background(theme.reader.opacity(0.6))
        .background { WindowDragArea() }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border.opacity(0.6)).frame(height: 1) }
    }

    private var logo: some View {
        (Text("vi") + Text("/").foregroundColor(theme.primary) + Text("mail") + Text("_").foregroundColor(theme.primary))
            .font(AppFonts.mono(24, .medium))
            .tracking(-1.5)
            .foregroundStyle(theme.foreground)
    }

    private func tab(title: String, count: Int?, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(AppFonts.sans(11))
                if let count {
                    Text("\(count)").font(AppFonts.mono(9)).opacity(0.7)
                }
            }
            .foregroundStyle(active ? theme.foreground : theme.mutedForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 8, active: active)
        }
        .buttonStyle(.plain)
    }
}

/// Drags the window from the header background; double-click zooms, like a title bar.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
    }
}
