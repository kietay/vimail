import MailCore
import SwiftUI

/// Dimmed backdrop and placement for dialogs, as in the design.
struct OverlayHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        if let overlay = model.overlay {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(theme.status.opacity(0.45))
                        .background(.ultraThinMaterial.opacity(0.6))
                        .ignoresSafeArea()
                        .onTapGesture { dismiss(overlay) }
                    content(overlay)
                        .padding(.top, geometry.size.height * (overlay == .omnibox ? 0.12 : 0.1))
                        .padding(.horizontal, 16)
                }
            }
            .transition(.opacity)
        }
    }

    private func dismiss(_ overlay: Overlay) {
        switch overlay {
        case .viewEditor: model.overlay = .views
        case .aiConsent: model.declineConsent()
        case .ruleEditor: model.ruleEditor?.leaveByClick()
        case .backfill: model.backfill?.back()
        default: model.overlay = nil
        }
    }

    @ViewBuilder
    private func content(_ overlay: Overlay) -> some View {
        switch overlay {
        case .omnibox: OmniboxView()
        case .help: HelpView()
        case .settings: SettingsView()
        case .views: ViewsManagerView()
        case .viewEditor(let view): ViewEditorView(original: view)
        case .picker(let kind): PickerView(kind: kind)
        case .confirm(let confirmation): ConfirmView(confirmation: confirmation)
        case .explain: ExplainView()
        case .aiConsent: ConsentView()
        case .rules:
            if let manager = model.rulesManager { RulesManagerView(manager: manager) }
        case .ruleEditor:
            if let editor = model.ruleEditor { RuleEditorView(editor: editor) }
        case .backfill:
            if let sheet = model.backfill { BackfillView(sheet: sheet) }
        }
    }
}

// MARK: - Omnibox

struct OmniboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let results = model.omniResults
        let highlighted = model.omniHighlightedIndex
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Icon(name: .search, size: 20).foregroundStyle(theme.mutedForeground)
                TextField("Search commands, views, themes, or mail…", text: $model.omniQuery)
                    .textFieldStyle(.plain)
                    .font(AppFonts.sans(14))
                    .foregroundStyle(theme.foreground)
                    .focused($focused)
                Button { model.overlay = nil } label: { KeyChip("esc", alwaysVisible: true) }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            Rectangle().fill(theme.border).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || results[index - 1].group != item.group {
                                Text(item.group)
                                    .font(AppFonts.sans(10, .medium))
                                    .foregroundStyle(theme.mutedForeground)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 12)
                                    .padding(.bottom, 8)
                            }
                            OmniRow(item: item, highlighted: index == highlighted)
                                .id(item.id)
                                .onHover { if $0 { model.highlightOmni(item) } }
                                .onTapGesture { model.runOmni(item) }
                        }
                        if results.isEmpty {
                            VStack(spacing: 8) {
                                Text("No matches").font(AppFonts.sans(14)).foregroundStyle(theme.foreground)
                                Text("Try “dark”, “archive”, a view name, or a sender.").font(AppFonts.sans(12)).foregroundStyle(theme.mutedForeground)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 440)
                .onChange(of: highlighted) { _, index in
                    if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                }
            }

            Rectangle().fill(theme.border).frame(height: 1)
            HStack {
                HStack(spacing: 6) {
                    KeyChip("↑ ↓", alwaysVisible: true)
                    Text("navigate")
                    KeyChip("↵", alwaysVisible: true).padding(.leading, 12)
                    Text("run")
                }
                Spacer()
                Text("\(results.count) results").font(AppFonts.mono(10))
            }
            .font(AppFonts.sans(10))
            .foregroundStyle(theme.mutedForeground)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: 620)
        .background(theme.reader.opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border.opacity(0.8), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 50, y: 24)
        // Focus set in the same pass that inserts the overlay is dropped; defer it one turn.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: model.focusTarget) { _, target in focused = target == .omnibox }
    }
}

private struct OmniRow: View {
    @Environment(\.theme) private var theme
    let item: OmniItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Icon(name: item.icon, size: 16).foregroundStyle(theme.mutedForeground)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(AppFonts.sans(12)).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(AppFonts.sans(10)).foregroundStyle(theme.mutedForeground).lineLimit(1)
                }
            }
            Spacer()
            if item.active { Icon(name: .check, size: 14).foregroundStyle(theme.green) }
            if let shortcut = item.shortcut { KeyChip(shortcut, alwaysVisible: highlighted) }
        }
        .foregroundStyle(highlighted ? theme.foreground : theme.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(highlighted ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .opacity(item.disabled ? 0.35 : 1)
        .contentShape(Rectangle())
    }
}

// MARK: - Pickers (label, move, snooze, go to label)

struct PickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    let kind: PickerKind

    var body: some View {
        @Bindable var model = model
        let items = model.pickerItems
        let highlighted = min(model.pickerHighlighted, max(items.count - 1, 0))
        DialogShell(title: model.pickerTitle(kind), width: 440, footer: footer, onClose: { model.overlay = nil }) {
            VStack(spacing: 0) {
                TextField(model.pickerPlaceholder(kind), text: $model.pickerQuery)
                    .textFieldStyle(.plain)
                    .font(AppFonts.sans(13))
                    .foregroundStyle(theme.foreground)
                    .focused($focused)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                Rectangle().fill(theme.border).frame(height: 1)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            pickerRow(item, highlighted: index == highlighted)
                                .onHover { if $0 { model.pickerHighlighted = index } }
                                .onTapGesture { item.run(kind == .label) }
                        }
                        if items.isEmpty {
                            Text(kind == .snooze ? "Type a time like 2h, 3d, tomorrow 9am or mon." : "No matches.")
                                .font(AppFonts.sans(12))
                                .foregroundStyle(theme.mutedForeground)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 340)
            }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var footer: String {
        switch kind {
        case .label: "↵ toggle and close · tab toggle and stay · esc close"
        case .snooze: "press a letter for a preset · ↵ choose · esc close"
        default: "↵ choose · esc close"
        }
    }

    private func pickerRow(_ item: PickerItem, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            if let checked = item.checked {
                checkbox(checked)
            }
            if let colorIndex = item.colorIndex {
                RoundedRectangle(cornerRadius: 2).fill(theme.labelColor(colorIndex).fg).frame(width: 8, height: 8)
            } else if let icon = item.icon {
                Icon(name: icon, size: 15).foregroundStyle(theme.mutedForeground)
            }
            Text(item.title).font(AppFonts.sans(12)).lineLimit(1)
            Spacer()
            if let subtitle = item.subtitle {
                Text(subtitle).font(AppFonts.mono(10)).foregroundStyle(theme.mutedForeground)
            }
            if let key = item.key { KeyChip(key, alwaysVisible: true) }
        }
        .foregroundStyle(highlighted ? theme.foreground : theme.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(highlighted ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func checkbox(_ state: Bool?) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(theme.mutedForeground, lineWidth: 1)
            .frame(width: 14, height: 14)
            .overlay {
                if state == true {
                    Icon(name: .check, size: 12).foregroundStyle(theme.green)
                } else if state == nil {
                    Rectangle().fill(theme.mutedForeground).frame(width: 7, height: 1.5)
                }
            }
    }
}

// MARK: - Help

struct HelpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        DialogShell(title: "Keyboard shortcuts", width: 760, onClose: { model.overlay = nil }) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 32), GridItem(.flexible(), spacing: 32)], alignment: .leading, spacing: 24) {
                    ForEach(AppModel.shortcutSections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.0.uppercased()).font(AppFonts.mono(9)).tracking(1.5).foregroundStyle(theme.mutedForeground)
                            ForEach(section.1, id: \.0) { key, text in
                                HStack(spacing: 8) {
                                    Text(text).font(AppFonts.sans(11)).foregroundStyle(theme.mutedForeground)
                                    Spacer()
                                    KeyChip(key, alwaysVisible: true)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .frame(maxHeight: 560)
        }
    }
}

// MARK: - Confirm

struct ConfirmView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let confirmation: Confirmation

    var body: some View {
        DialogShell(title: confirmation.title, width: 440, footer: "y confirm · n cancel", onClose: { model.overlay = nil }) {
            VStack(alignment: .leading, spacing: 20) {
                Text(confirmation.message).font(AppFonts.sans(12)).foregroundStyle(theme.body)
                HStack {
                    Spacer()
                    Button("Cancel") { model.overlay = nil }
                        .buttonStyle(.plain)
                        .font(AppFonts.sans(12))
                        .foregroundStyle(theme.mutedForeground)
                    Button { model.confirm(confirmation) } label: {
                        Text(confirmation.confirmTitle)
                            .font(AppFonts.sans(12, .medium))
                            .foregroundStyle(theme.buttonText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(theme.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        if let toast = model.toast {
            let detail = toast.detail.map { " \($0)" } ?? ""
            HStack(spacing: 14) {
                if let deadline = toast.countdownTo {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let seconds = max(1, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                        Text("\(toast.text) in \(seconds)s.\(detail)")
                    }
                } else {
                    Text(toast.text + detail)
                }
                if toast.undoable {
                    Button { model.toast = nil; model.undo() } label: {
                        HStack(spacing: 6) {
                            Text("Undo").foregroundStyle(theme.primary)
                            KeyChip("u", dark: true, alwaysVisible: true)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(AppFonts.sans(12))
            .foregroundStyle(toast.isError ? theme.orange : theme.buttonText)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(theme.status, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            .padding(.bottom, 48)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
