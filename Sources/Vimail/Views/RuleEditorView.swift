import MailCore
import MailRules
import MailStore
import SwiftUI

/// Writing a rule (design §5.3): the fields on the left, and on the right the preview of what the
/// rule decides on your mail, live as you type. Text from mail and Claude is shown verbatim.
struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Bindable var editor: RuleEditorModel
    @FocusState private var focus: FocusTarget?

    var body: some View {
        DialogShell(title: editor.title, width: 1000, footer: footer, onClose: { editor.leaveByClick() }) {
            HStack(alignment: .top, spacing: 0) {
                form
                    .frame(width: 430)
                Rectangle().fill(theme.border).frame(width: 1)
                preview
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 580)
        }
        // Focus set in the same pass that inserts the overlay is dropped; defer it one turn.
        .onAppear { DispatchQueue.main.async { focus = model.focusTarget } }
        .onChange(of: model.focusTarget) { _, target in focus = target }
        .onChange(of: focus) { _, value in editor.viewFocused(value) }
    }

    private var footer: String {
        "⌘↵ save · ⌃r test at issue · ⌃R test all · tab fields ↔ preview · esc leave field, then editor"
    }

    // MARK: - Fields

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                row("NAME", .name) {
                    TextField("Receipts", text: $editor.draft.name).fieldStyle().focused($focus, equals: .ruleName)
                }
                row("WHEN", .when) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("-from:@studio.co · empty: all mail", text: $editor.draft.when)
                                .fieldStyle()
                                .font(AppFonts.mono(12))
                                .focused($focus, equals: .ruleWhen)
                            tag("per message")
                        }
                        if let problem = editor.whenProblem {
                            note(problem, color: theme.red)
                        } else if let count = editor.freeCount {
                            note(RuleEditorText.freeCount(passing: count.passing, inScope: count.inScope, days: RuleEditorModel.countDays))
                        }
                    }
                }
                if let seed = editor.seed, seed.automated {
                    row("", .onlySender) {
                        check(editor.onlySender, "only this sender (from:@\(RuleSuggestion.domain(of: seed.sender.email)))") { editor.toggle(.onlySender) }
                    }
                }
                row(editor.drafting ? "ASK…" : "ASK", .ask) { ask }
                row("THEN", .then) { then }
                row("SCOPE", .scope) {
                    choice(editor.draft.scope.mailboxes == .inbox ? "inbox only" : "received (archived included)") { editor.toggle(.scope) }
                }
                row("", .replies) {
                    check(editor.draft.scope.inheritInThread, "replies inherit a match in their conversation (no call)") { editor.toggle(.replies) }
                }
                row("", .stop) {
                    check(editor.draft.stopAfterMatch, "stop later rules on a match") { editor.toggle(.stop) }
                }
                row("", .broad) {
                    check(editor.draft.acknowledgedBroad, "broad on purpose: matching most new mail doesn't turn it off") { editor.toggle(.broad) }
                }
                row("EDITS", .edits) {
                    choice(editor.draft.editsTeach ? "removing = wrong (teach)" : "removing = done (no teaching)") { editor.toggle(.edits) }
                }
                row("TEACH", nil) {
                    note(RuleEditorText.teach(editor.examples, tested: editor.draft.promptExampleIDs, asksClaude: editor.draft.asksClaude), color: theme.body)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if editor.draft.asksClaude, let costs = editor.costs {
                        note(RuleEditorText.testPrices(atIssue: costs.atIssue, all: costs.all), color: theme.body)
                    } else if !editor.draft.asksClaude {
                        note("filter rule: nothing goes to Claude", color: theme.body)
                    }
                    if let spend = editor.spend, editor.draft.asksClaude {
                        note(RuleEditorText.previewSpend(today: spend.previewToday, allowance: model.settings.ai.budget.previewDay))
                    }
                    if let notice = editor.notice {
                        note(notice, color: theme.orange)
                    }
                }
                .padding(.leading, 76)
                HStack {
                    Spacer()
                    Button { editor.save() } label: {
                        HStack(spacing: 10) {
                            Text(editor.saving ? "Saving…" : editor.isNew ? "Save rule" : "Save changes").font(AppFonts.sans(12, .medium))
                            KeyChip("⌘↵", dark: true, alwaysVisible: true)
                        }
                        .foregroundStyle(theme.buttonText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(theme.button, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { editor.askText }, set: { editor.askText = $0 }))
                    .font(AppFonts.sans(12))
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .ruleAsk)
                    .padding(6)
                if editor.askText.isEmpty {
                    Text(editor.drafting ? "drafting…" : "describe which emails match · empty: a filter rule, no Claude")
                        .font(AppFonts.sans(12))
                        .foregroundStyle(theme.mutedForeground)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(theme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
            HStack(spacing: 8) {
                if editor.draft.asksClaude { tag("Claude decides") }
                if editor.draft.askDrafted { tag("drafted from an email · read it", color: theme.yellow) }
                if editor.drafting { tag("drafting…", color: theme.yellow) }
            }
        }
    }

    private var then: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("add label").font(AppFonts.sans(11)).foregroundStyle(theme.mutedForeground)
                TextField("receipts", text: $editor.labelName).fieldStyle().focused($focus, equals: .ruleLabel)
            }
            if let label = editor.targetLabel {
                HStack(spacing: 6) {
                    LabelChip(name: "◆ \(label.name)", colorIndex: label.paletteIndex(count: 7))
                    note(label.kind == .local ? "· local" : "· Gmail (syncs)")
                }
            } else if !editor.labelName.trimmingCharacters(in: .whitespaces).isEmpty {
                note("new local label: \(editor.labelName.trimmingCharacters(in: .whitespaces))")
            }
            if editor.field == .then {
                let suggestions = editor.labelSuggestions
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, label in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(theme.labelColor(label.paletteIndex(count: 7)).fg).frame(width: 8, height: 8)
                            Text(verbatim: label.name).font(AppFonts.sans(11))
                            Spacer()
                            Text(label.kind == .local ? "local" : "Gmail").font(AppFonts.mono(9)).foregroundStyle(theme.mutedForeground)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(index == editor.labelHighlighted ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { editor.labelName = label.name }
                    }
                }
                if !suggestions.isEmpty { note("↑ ↓ choose · ↵ take it") }
            }
        }
    }

    /// One field: its name in the margin, highlighted while it has the keyboard.
    private func row<Content: View>(_ title: String, _ field: RuleEditorModel.Field?, @ViewBuilder content: () -> Content) -> some View {
        let active = field != nil && editor.field == field && !(field?.isText ?? false)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(AppFonts.mono(9))
                .tracking(1.2)
                .foregroundStyle(field != nil && editor.field == field ? theme.foreground : theme.mutedForeground)
                .frame(width: 64, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, active ? 4 : 0)
        .padding(.horizontal, active ? 4 : 0)
        .background(active ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func note(_ text: String, color: Color? = nil) -> some View {
        Text(verbatim: text).font(AppFonts.mono(10)).foregroundStyle(color ?? theme.mutedForeground).fixedSize(horizontal: false, vertical: true)
    }

    private func tag(_ text: String, color: Color? = nil) -> some View {
        Text(verbatim: text)
            .font(AppFonts.mono(9))
            .foregroundStyle(color ?? theme.mutedForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.muted, in: RoundedRectangle(cornerRadius: 4))
    }

    private func check(_ on: Bool, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(verbatim: on ? "☑" : "☐").foregroundStyle(on ? theme.green : theme.mutedForeground)
                Text(verbatim: text).foregroundStyle(theme.body)
            }
            .font(AppFonts.sans(12))
        }
        .buttonStyle(.plain)
    }

    private func choice(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(verbatim: text).foregroundStyle(theme.body)
                Text(verbatim: "▾").foregroundStyle(theme.mutedForeground)
            }
            .font(AppFonts.sans(12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: header)
                    .font(AppFonts.mono(10))
                    .foregroundStyle(editor.field == .preview ? theme.foreground : theme.mutedForeground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if editor.isTooBroad {
                    if editor.draft.acknowledgedBroad {
                        Text("broad on purpose").font(AppFonts.mono(10)).foregroundStyle(theme.mutedForeground)
                    } else {
                        Text("Too broad? It would label most of your mail.").font(AppFonts.mono(10)).foregroundStyle(theme.orange)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(theme.border).frame(height: 1)
            if let message = editor.peek {
                peek(message)
            } else {
                rows
            }
            Rectangle().fill(theme.border).frame(height: 1)
            if let prompt = editor.prompt {
                promptBar(prompt)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("y ✔   n ✖   u clear   s sender always/never   o open   + 20 more   L all matches in the list")
                    Text("✔ match  ✖ no  ~ unsure  ≠ not as you labeled  ◐ before your newest mark  ! declined  ◌ not judged  ● yours")
                }
                .font(AppFonts.mono(9))
                .foregroundStyle(theme.mutedForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private var header: String {
        let decidedBy = editor.draft.asksClaude ? model.judgeModelName : "filter · free"
        var text = RuleEditorText.header(editor.rows, decidedBy: decidedBy)
        if editor.testing { text += " · testing…" } else if editor.loadingPreview { text += " · …" }
        return text
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(editor.rows.enumerated()), id: \.element.id) { index, row in
                        previewRow(row, highlighted: index == editor.highlighted && editor.field == .preview)
                            .id(row.id)
                            .onTapGesture {
                                editor.highlighted = index
                                editor.field = .preview
                            }
                    }
                    if editor.rows.isEmpty {
                        Text(editor.whenProblem == nil ? "No mail here passes WHEN." : "Fix WHEN to see the preview.")
                            .font(AppFonts.sans(12))
                            .foregroundStyle(theme.mutedForeground)
                            .padding(24)
                    }
                }
                .padding(8)
            }
            .onChange(of: editor.highlighted) { _, index in
                if editor.rows.indices.contains(index) { proxy.scrollTo(editor.rows[index].id) }
            }
        }
    }

    private func previewRow(_ row: PreviewRow, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: row.markedByYou ? "●" : " ").foregroundStyle(theme.primary).frame(width: 10)
                Text(verbatim: row.glyph).foregroundStyle(color(of: row)).frame(width: 14)
                Text(verbatim: row.sender.displayName).foregroundStyle(theme.foreground).lineLimit(1).frame(width: 150, alignment: .leading)
                Text(verbatim: row.subject.isEmpty ? "(no subject)" : row.subject).foregroundStyle(theme.body).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(AppFonts.mono(11))
            Text(verbatim: row.detail)
                .font(AppFonts.sans(11))
                .foregroundStyle(theme.mutedForeground)
                .lineLimit(1)
                .padding(.leading, 36)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(background(of: row, highlighted: highlighted), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func background(of row: PreviewRow, highlighted: Bool) -> Color {
        if editor.flashed.contains(row.messageID) { return theme.yellowSoft }
        return highlighted ? theme.selected : .clear
    }

    private func color(of row: PreviewRow) -> Color {
        switch row.glyph {
        case "✔": theme.green
        case "~": theme.yellow
        case "≠": theme.orange
        case "!": theme.red
        default: theme.mutedForeground
        }
    }

    private func peek(_ message: MailMessage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message.subject.isEmpty ? "(no subject)" : message.subject).font(AppFonts.sans(13, .medium)).foregroundStyle(theme.foreground)
                Text(verbatim: "\(message.from.formatted) · \(Formatting.longDate(message.date))").font(AppFonts.mono(10)).foregroundStyle(theme.mutedForeground)
                Text(verbatim: String(message.plainText.prefix(4_000)))
                    .font(AppFonts.sans(12))
                    .foregroundStyle(theme.body)
                    .textSelection(.enabled)
                Text("o or esc closes").font(AppFonts.mono(9)).foregroundStyle(theme.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func promptBar(_ prompt: RuleEditorModel.Prompt) -> some View {
        let (text, keys): (String, String) = switch prompt {
        case .discard:
            (editor.isNew ? "Discard this rule? Its marks go too." : "Discard your changes to this rule?", "y discard · n keep editing")
        case .saveUntested(let marks):
            ("\(marks == 1 ? "1 mark" : "\(marks) marks") not tested" + (editor.costs.map { " · ⌃r test ≈ \(Dollars.text($0.atIssue.micros))" } ?? ""),
             "↵ save as tested · ⌃r test · esc")
        case .test(let test, let cost):
            ("Test \(cost.calls) \(cost.calls == 1 ? "row" : "rows")\(test == .all ? "" : " at issue") with Claude ≈ \(Dollars.text(cost.micros))?", "↵ test · esc cancel")
        }
        return HStack(spacing: 12) {
            Text(verbatim: text).foregroundStyle(theme.foreground)
            Spacer(minLength: 8)
            Text(verbatim: keys).font(AppFonts.mono(10)).foregroundStyle(theme.yellow)
        }
        .font(AppFonts.sans(12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.yellowSoft.opacity(0.5))
    }
}
