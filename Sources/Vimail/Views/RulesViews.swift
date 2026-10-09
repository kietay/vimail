import MailAI
import MailCore
import MailRules
import SwiftUI

// MARK: - Why these labels?

/// `g?`: why the conversation carries each label, and which rules decided no. Text from mail and
/// Claude is shown verbatim, never as Markdown.
struct ExplainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let lines = model.explainLines
        let highlighted = model.explainHighlighted
        DialogShell(
            title: "Why these labels?", width: 720,
            footer: "x wrong: remove + teach · a should match: add + teach · s sender rule · d disable rule · u undo run · esc",
            onClose: { model.overlay = nil }
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            row(line, highlighted: index == highlighted)
                                .id(line.id)
                                .onHover { if $0 { model.explainHighlighted = index } }
                        }
                        if lines.isEmpty {
                            Text("No labels here, and no rule decided against this conversation.")
                                .font(AppFonts.sans(12))
                                .foregroundStyle(theme.mutedForeground)
                                .padding(.vertical, 24)
                                .padding(.horizontal, 12)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 440)
                .onChange(of: highlighted) { _, index in
                    if lines.indices.contains(index) { proxy.scrollTo(lines[index].id) }
                }
            }
        }
    }

    private func row(_ line: ExplainLine, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: line.isOnConversation ? "◆" : "·")
                .font(AppFonts.mono(11))
                .foregroundStyle(line.isOnConversation ? labelColor(line.labelID) : theme.mutedForeground)
            Text(verbatim: line.labelName)
                .font(AppFonts.mono(11))
                .foregroundStyle(line.isOnConversation ? theme.foreground : theme.mutedForeground)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: line.detail).font(AppFonts.sans(11)).foregroundStyle(theme.body)
                if let reason = line.reason, !reason.isEmpty {
                    Text(verbatim: "“\(reason)”").font(AppFonts.sans(11)).foregroundStyle(theme.mutedForeground)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(highlighted ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func labelColor(_ labelID: String?) -> Color {
        guard let label = model.labels.first(where: { $0.id == labelID }) else { return theme.mutedForeground }
        return theme.labelColor(label.paletteIndex(count: 7)).fg
    }
}

// MARK: - Consent

/// Before Claude judges an account's mail: what is sent and what never is, your volume, what each
/// model would cost, and the budget.
struct ConsentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var field: Field?

    enum Field { case month, day, preview }

    var body: some View {
        @Bindable var model = model
        let account = model.account.email.isEmpty ? "this account" : model.account.email
        let selected = model.consentDraft.claudeModel ?? .default
        DialogShell(title: "Send mail to Claude for \(account)?", width: 620, footer: "↵ allow for this account · j/k model · e edit budget · esc not now", onClose: { model.declineConsent() }) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("For each message a Claude rule judges, vimail sends:").foregroundStyle(theme.foreground)
                    bullet("sender name and address · subject · date · “me + N others”")
                    bullet("up to 4,000 characters of body text (quotes, signatures, links and inline-hidden text removed) · attachment names, never their contents")
                    bullet("for replies: the previous sender and its first 400 characters")
                    bullet("examples you mark: sender name, domain and subject only")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Never sent: your addresses, attachments, other threads.")
                    Text("Goes to Anthropic under your API key's terms. Logs never hold mail.")
                    Text("Filter-only rules send nothing and need no consent.")
                }
                .foregroundStyle(theme.body)
                Text(verbatim: volumeText).foregroundStyle(theme.foreground)
                VStack(spacing: 2) {
                    ForEach(ClaudeModel.allCases, id: \.self) { option in
                        modelRow(option, selected: option == selected)
                            .onTapGesture { model.consentDraft.model = option.rawValue }
                    }
                }
                HStack(spacing: 8) {
                    Text(verbatim: "Budget for \(selected.displayName):")
                    budgetField($model.consentDraft.monthlyBudgetUSD, .month)
                    Text("a month ·")
                    budgetField($model.consentDraft.dailyBudgetUSD, .day)
                    Text("a day · previews")
                    budgetField($model.consentDraft.previewDailyUSD, .preview)
                    Text("a day")
                }
                .foregroundStyle(theme.body)
                HStack {
                    Text("Prices as of \(ClaudeModel.pricesAsOf.formatted(date: .abbreviated, time: .omitted)). Revoke any time in Settings.")
                        .font(AppFonts.sans(10))
                        .foregroundStyle(theme.mutedForeground)
                    Spacer()
                    Button("Not now") { model.declineConsent() }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.mutedForeground)
                    Button { model.allowClaude() } label: {
                        Text("Allow for this account")
                            .font(AppFonts.sans(12, .medium))
                            .foregroundStyle(theme.buttonText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(theme.button, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(AppFonts.sans(12))
            .padding(24)
        }
        .onChange(of: model.focusTarget) { _, target in
            if target == .consentBudget, field == nil { field = .month } else if target == nil { field = nil }
        }
        .onChange(of: field) { _, value in
            if value != nil { model.focusTarget = .consentBudget } else if model.focusTarget == .consentBudget { model.focusTarget = nil }
        }
    }

    /// "You receive about 60 messages a day here; filters send fewer."
    private var volumeText: String {
        guard let volume = model.mailVolume else { return "Counting the mail you receive here…" }
        let perDay = volume < 1 ? "less than one message" : volume < 1.5 ? "about 1 message" : "about \(Int(volume.rounded())) messages"
        return "You receive \(perDay) a day here; filters send fewer."
    }

    private func bullet(_ text: String) -> some View {
        Text(verbatim: "  " + text).foregroundStyle(theme.body)
    }

    private func modelRow(_ option: ClaudeModel, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: selected ? "▸" : " ").font(AppFonts.mono(11)).foregroundStyle(theme.green).frame(width: 10)
            Text(verbatim: option.displayName).frame(width: 90, alignment: .leading)
            Text(verbatim: model.mailVolume.map { Formatting.monthly(AIServices.monthlyEstimate(option, messagesPerDay: $0)) } ?? "")
                .font(AppFonts.mono(11))
                .frame(width: 110, alignment: .leading)
            Text(verbatim: Self.note(option)).foregroundStyle(theme.mutedForeground)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? theme.foreground : theme.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    static func note(_ model: ClaudeModel) -> String {
        switch model {
        case .haiku: "cheapest · may miss subtle rules · refusals stay unlabeled"
        case .sonnet: "about half of Opus"
        case .opus: "best judgment"
        }
    }

    private func budgetField(_ value: Binding<Double>, _ which: Field) -> some View {
        HStack(spacing: 2) {
            Text("$")
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .fieldStyle()
                .frame(width: 70)
                .focused($field, equals: which)
        }
    }
}
