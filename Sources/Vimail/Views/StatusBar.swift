import MailRules
import SwiftUI

/// The vim-style status line.
struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let mode = model.mode
        HStack(spacing: 0) {
            Text(mode.rawValue)
                .font(AppFonts.mono(10, .semibold))
                .tracking(1)
                .foregroundStyle(modeColors(mode).fg)
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
                .background(modeColors(mode).bg)

            HStack(spacing: 0) {
                Text(model.destinationTitle.lowercased())
                Text("│").padding(.horizontal, 12)
                Text(position)
                if !model.searchText.isEmpty {
                    Text("│").padding(.horizontal, 12)
                    Text("/\(model.searchText)").foregroundStyle(theme.statusBright)
                }
                Text("│").padding(.horizontal, 12)
                syncText
                if let rules = model.rulesStatusLine {
                    Text("│").padding(.horizontal, 12)
                    rulesText(rules)
                }
                let pending = model.compose?.bodyPendingKeys ?? model.pendingKeys
                if !pending.isEmpty {
                    Text(pending)
                        .foregroundStyle(theme.statusBright)
                        .padding(.leading, 16)
                }
            }
            .padding(.leading, 16)
            .lineLimit(1)

            Spacer(minLength: 16)

            HStack(spacing: 20) {
                hint("j k", "navigate")
                hint("e", "archive")
                hint("r", "reply")
                Button { model.overlay = .omnibox } label: { hintLabel(":", "command") }.buttonStyle(.plain)
                Button { model.overlay = .help } label: { hintLabel("?", "help") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .font(AppFonts.mono(9))
        .foregroundStyle(theme.statusText)
        .frame(height: 32)
        .background(theme.status.opacity(0.85))
        .overlay(alignment: .top) { Rectangle().fill(theme.border.opacity(0.4)).frame(height: 1) }
        .onHover { hovering = $0 }
    }

    /// Local-first sync state: actions apply instantly; this shows what is still on its way.
    private var syncText: some View {
        let status = model.syncStatus
        let text: String
        var color = theme.statusText
        if model.signingIn {
            text = "signing in…"
            color = theme.yellow
        } else if let progress = status.initialSyncProgress, [.idle, .syncing].contains(status.phase) {
            text = "syncing inbox \(progress)"
            color = theme.yellow
        } else {
            switch status.phase {
            case .idle, .syncing:
                if status.pendingOperations > 0 {
                    text = "\(status.pendingOperations) queued"
                    color = theme.yellow
                } else if let cached = status.backfillProgress {
                    // Older mail being cached in the background.
                    text = "synced · caching \(cached)"
                } else {
                    text = "synced"
                }
            case .offline:
                text = status.pendingOperations > 0 ? "offline · \(status.pendingOperations) queued" : "offline"
                color = theme.orange
            case .rateLimited:
                text = "waiting for Gmail · rate limit"
                color = theme.yellow
            case .failed:
                text = "sync error"
                color = theme.red
            case .signedOut:
                text = status.pendingOperations > 0 ? "signed out · \(status.pendingOperations) queued · sign in" : "signed out · sign in"
                color = theme.red
            }
        }
        let account = model.services.isGmail ? model.account.email : "Dummy data"
        let detail = status.message ?? "Changes apply locally right away and sync in the background."
        return Text(text)
            .foregroundStyle(color)
            .help(account.isEmpty ? detail : "\(account) · \(detail)")
            .onTapGesture {
                if status.phase == .signedOut { model.connectGmail() } else { model.syncNow() }
            }
    }

    /// What rules are doing, after the sync state; hidden when there is nothing to say. Tapping it
    /// opens the rules manager (`gr`).
    private func rulesText(_ line: RulesStatusLine) -> some View {
        let color = switch line.tone {
        case .normal: theme.statusText
        case .busy: theme.yellow
        case .warning: theme.orange
        case .error: theme.red
        }
        return Text(verbatim: line.text)
            .foregroundStyle(color)
            .help("Rules and Claude · click for the rules manager (gr)")
            .onTapGesture { model.openRulesStatus() }
    }

    private var position: String {
        guard let index = model.cursorIndex else { return "0:\(model.totalCount)" }
        return "\(index + 1):\(model.totalCount)"
    }

    private var showHints: Bool { hovering || model.settings.alwaysShowKeyHints }

    private func hint(_ key: String, _ text: String) -> some View {
        hintLabel(key, text)
    }

    private func hintLabel(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(theme.statusBright).opacity(showHints ? 1 : 0)
            Text(text)
        }
        .opacity(showHints || key == ":" || key == "?" ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: showHints)
    }

    private func modeColors(_ mode: Mode) -> (bg: Color, fg: Color) {
        switch mode {
        case .insert, .compose: (theme.orangeSoft, theme.orange)
        case .visual: (theme.purpleSoft, theme.purple)
        case .command, .search: (theme.yellowSoft, theme.yellow)
        case .vim: (theme.greenSoft, theme.green)
        case .normal, .goto: (theme.mode, theme.modeText)
        }
    }
}
