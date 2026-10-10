import MailCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var collapsed: Bool { model.session.sidebarCollapsed }

    private let navigation: [(Mailbox, IconName, String)] = [
        (.inbox, .inbox, "gi"), (.starred, .star, "gs"), (.snoozed, .clock, "gz"), (.sent, .send, "gt"),
        (.drafts, .file, "gd"), (.archive, .archive, "ga"), (.trash, .trash, "g#"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            composeButton.padding(.bottom, 28)

            if !collapsed { sectionTitle("MAILBOX").padding(.bottom, 12) }
            VStack(spacing: 4) {
                ForEach(navigation, id: \.0) { mailbox, icon, key in
                    navItem(mailbox, icon: icon, key: key)
                }
                calendarItem
            }

            if collapsed {
                Spacer(minLength: 12)
            } else {
                // Labels take the remaining height and scroll when there are many.
                LabelsSection()
                    .padding(.top, 36)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            settingsButton.padding(.bottom, 20)
            if !collapsed { accountRow }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, collapsed ? 8 : 16)
        .frame(width: collapsed ? 64 : 210)
        .background(theme.sidebar.opacity(0.7))
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border.opacity(0.5)).frame(width: 1) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppFonts.mono(9))
            .tracking(1.5)
            .foregroundStyle(theme.mutedForeground)
            .cssLine(9)
            .padding(.horizontal, 12)
    }

    private var composeButton: some View {
        Button { model.openCompose(nil) } label: {
            HStack(spacing: 8) {
                Icon(name: .plus, size: 16)
                if !collapsed {
                    Text("Compose").font(AppFonts.sans(12, .medium))
                    Spacer()
                    KeyChip("c", dark: true)
                }
            }
            .foregroundStyle(theme.buttonText)
            .padding(.horizontal, collapsed ? 0 : 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(theme.button, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.foreground.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 5, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hintScope()
        .help("Compose (c)")
    }

    private func navItem(_ mailbox: Mailbox, icon: IconName, key: String) -> some View {
        let active = model.destination == .mailbox(mailbox)
        return Button { model.navigate(to: .mailbox(mailbox)) } label: {
            HStack(spacing: 12) {
                Icon(name: icon, size: 16)
                if !collapsed {
                    Text(mailbox.title).font(AppFonts.sans(12, active ? .semibold : .regular))
                    Spacer()
                    trailing(for: mailbox, key: key)
                }
            }
            .foregroundStyle(active ? theme.green : theme.mutedForeground)
            .padding(.horizontal, collapsed ? 4 : 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: collapsed ? .center : .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 6, active: active)
        }
        .buttonStyle(.plain)
        .hintScope()
        .help("\(mailbox.title) (\(key))")
    }

    private var calendarItem: some View {
        let active = model.destination == .calendar
        let waiting = model.waitingInvitationCount
        return Button { model.openCalendar() } label: {
            HStack(spacing: 12) {
                Icon(name: .calendar, size: 16)
                if !collapsed {
                    Text("Calendar").font(AppFonts.sans(12, active ? .semibold : .regular))
                    Spacer()
                    if waiting > 0 { Text("\(waiting)").font(AppFonts.mono(10)) } else { HintText("gc") }
                }
            }
            .foregroundStyle(active ? theme.green : theme.mutedForeground)
            .padding(.horizontal, collapsed ? 4 : 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: collapsed ? .center : .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 6, active: active)
        }
        .buttonStyle(.plain)
        .hintScope()
        .help("Calendar (gc)")
    }

    @ViewBuilder
    private func trailing(for mailbox: Mailbox, key: String) -> some View {
        let count: Int? = switch mailbox {
        case .inbox: model.unreadCounts[SystemLabel.inbox]
        case .drafts: model.counts["drafts"]
        case .snoozed: model.counts["snoozed"]
        default: nil
        }
        if let count, count > 0 {
            Text("\(count)").font(AppFonts.mono(10))
        } else {
            HintText(key)
        }
    }

    private var settingsButton: some View {
        Button { model.overlay = .settings } label: {
            HStack(spacing: 12) {
                Icon(name: .settings, size: 15)
                if !collapsed { Text("Settings").font(AppFonts.sans(12)) }
            }
            .foregroundStyle(theme.mutedForeground)
            .padding(.horizontal, collapsed ? 4 : 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: collapsed ? .center : .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .help("Settings (⌘,)")
    }

    private var accountRow: some View {
        HStack(spacing: 10) {
            Text(model.account.email.isEmpty ? "··" : model.account.initials)
                .font(AppFonts.mono(10))
                .foregroundStyle(theme.green)
                .frame(width: 32, height: 32)
                .background(theme.muted, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(model.account.name ?? "Signing in…").font(AppFonts.sans(12, .medium)).foregroundStyle(theme.foreground).lineLimit(1)
                    .cssLine(12, 16 / 12)
                Text(model.account.email).font(AppFonts.sans(10)).foregroundStyle(theme.mutedForeground).lineLimit(1)
                    .cssLine(10)
            }
            Spacer(minLength: 0)
            Icon(name: .down, size: 13).foregroundStyle(theme.mutedForeground)
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
        .help(model.services.dummy != nil ? "Dummy data mode. Your real mail is not touched." : model.account.email)
    }
}

/// Shortcut text that appears on hover.
struct HintText: View {
    @Environment(\.hintsVisible) private var visible
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(AppFonts.mono(10))
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: visible)
    }
}

private struct LabelsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var editing: MailLabel?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LABELS").font(AppFonts.mono(9)).tracking(1.5).foregroundStyle(theme.mutedForeground).cssLine(9)
                Spacer()
                Button {
                    model.pickerTargets = []
                    model.overlay = .picker(.label)
                } label: {
                    Icon(name: .plus, size: 12).foregroundStyle(theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Create a label (t, then type a new name)")
            }
            .padding(.horizontal, 12)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(model.userLabels) { label in
                        labelRow(label)
                    }
                }
            }
        }
        .onHover { hovering = $0 }
    }

    private func labelRow(_ label: MailLabel) -> some View {
        let active = model.destination == .mailbox(.label(label.id))
        let color = theme.labelColor(label.paletteIndex(count: 7)).fg
        return Button { model.navigate(to: .mailbox(.label(label.id))) } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                Text(label.name).font(AppFonts.sans(12)).lineLimit(1)
                Spacer()
            }
            .foregroundStyle(theme.mutedForeground)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 4, active: active)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { rename(label) }
            Button("Delete label") { model.deleteLabel(label) }
            if label.kind == .local { Text("Local only — never synced") }
        }
    }

    private func rename(_ label: MailLabel) {
        let alert = NSAlert()
        alert.messageText = "Rename label"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: label.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { model.renameLabel(label, to: name) }
        }
    }
}
