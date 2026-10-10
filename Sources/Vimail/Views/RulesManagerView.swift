import MailCore
import MailRules
import MailStore
import SwiftUI

// MARK: - Rules manager

/// `gr`: the rules in the order they run, what each has done, the month's spend, and Activity.
struct RulesManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let manager: RulesManagerModel

    var body: some View {
        DialogShell(title: "Rules", width: 920, footer: footer, onClose: { model.overlay = nil }) {
            VStack(alignment: .leading, spacing: 0) {
                rules
                Text(verbatim: summary)
                    .font(AppFonts.mono(10))
                    .foregroundStyle(theme.mutedForeground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                Rectangle().fill(theme.border).frame(height: 1)
                Text("ACTIVITY")
                    .font(AppFonts.mono(9))
                    .tracking(1.5)
                    .foregroundStyle(manager.focus == .activity ? theme.foreground : theme.mutedForeground)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                activity
                if let prompt = manager.prompt {
                    Rectangle().fill(theme.border).frame(height: 1)
                    promptBar(prompt)
                }
            }
        }
    }

    private var footer: String {
        switch manager.focus {
        case .rules: "j/k move · ↵ edit · n new · x on/off · J/K reorder · B apply to existing · dd delete · a activity · r retry · p pause all · esc"
        case .activity: "j/k move · ↵ confirm or continue · u undo run · c cancel · a rules · r retry · esc"
        }
    }

    private var summary: String {
        let month = Date().formatted(.dateTime.month(.wide).locale(Locale(identifier: "en_US")))
        return model.rulesStatus.managerSummary(month: month, model: model.judgeModelName)
    }

    // MARK: Rules

    private var rules: some View {
        ScrollViewReader { proxy in
            FittingScroll(maxHeight: 300) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(manager.records.enumerated()), id: \.element.id) { index, record in
                        ruleRow(record, position: index + 1, highlighted: manager.focus == .rules && index == manager.highlighted)
                            .id(record.id)
                            .onTapGesture {
                                manager.focus = .rules
                                manager.highlighted = index
                            }
                    }
                    if manager.loaded, manager.records.isEmpty { emptyState }
                }
                .padding(8)
            }
            .onChange(of: manager.highlighted) { _, index in
                if manager.records.indices.contains(index) { proxy.scrollTo(manager.records[index].id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No rules yet.").font(AppFonts.sans(13)).foregroundStyle(theme.foreground)
            Text("A rule labels mail as it arrives: a search filter, and optionally a question Claude decides.")
            Text("T on a message makes one from it · n starts from scratch · :rule and a sentence drafts one (“rule receipts for things I buy”).")
        }
        .font(AppFonts.sans(12))
        .foregroundStyle(theme.mutedForeground)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
    }

    private func ruleRow(_ record: RuleRecord, position: Int, highlighted: Bool) -> some View {
        let rule = record.rule
        let warning = record.warning
        let on = rule.enabled && record.state == .ok
        return HStack(spacing: 12) {
            Text(verbatim: warning != nil ? "⚠" : on ? "●" : "○")
                .foregroundStyle(warning != nil ? theme.orange : on ? theme.green : theme.mutedForeground)
                .frame(width: 14)
            Text(verbatim: "\(position)").foregroundStyle(theme.mutedForeground).frame(width: 20, alignment: .trailing)
            Text(verbatim: rule.name)
                .foregroundStyle(on ? theme.foreground : theme.mutedForeground)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            targetChip(record).frame(width: 190, alignment: .leading)
            Text(verbatim: record.kindText).foregroundStyle(theme.mutedForeground).frame(width: 96, alignment: .leading)
            Text(verbatim: warning ?? record.countsText(manager.stats[record.id]))
                .foregroundStyle(warning != nil ? theme.orange : theme.body)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(AppFonts.mono(11))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(highlighted ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func targetChip(_ record: RuleRecord) -> some View {
        if let target = manager.target(of: record) {
            HStack(spacing: 6) {
                LabelChip(name: "◆ \(target.label.name)", colorIndex: target.label.paletteIndex(count: 7))
                Text(verbatim: "· \(target.kind)").foregroundStyle(theme.mutedForeground)
            }
        } else {
            Text(verbatim: "◆ \(record.rule.labelTargets.first?.lastKnownName ?? "no label")").foregroundStyle(theme.mutedForeground)
        }
    }

    // MARK: Activity

    private var activity: some View {
        let lines = manager.activity
        return ScrollViewReader { proxy in
            FittingScroll(maxHeight: 240) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        activityRow(line, highlighted: manager.focus == .activity && index == manager.activityHighlighted)
                            .id(line.id)
                            .onTapGesture {
                                manager.focus = .activity
                                manager.activityHighlighted = index
                            }
                    }
                    if manager.loaded, lines.isEmpty {
                        Text("No runs yet. Saving a rule offers to apply it to mail already here.")
                            .font(AppFonts.sans(12))
                            .foregroundStyle(theme.mutedForeground)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                    }
                }
                .padding(8)
            }
            .onChange(of: manager.activityHighlighted) { _, index in
                if lines.indices.contains(index) { proxy.scrollTo(lines[index].id) }
            }
        }
    }

    private func activityRow(_ line: ActivityLine, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: "#\(line.id)").foregroundStyle(theme.mutedForeground).frame(width: 44, alignment: .leading)
            Text(verbatim: line.kind).lineLimit(1).frame(width: 150, alignment: .leading)
            Text(verbatim: line.rules).lineLimit(1).frame(width: 150, alignment: .leading)
            Text(verbatim: line.detail)
                .foregroundStyle(line.needsYou ? theme.yellow : theme.body)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let key = line.key { KeyChip(key, alwaysVisible: highlighted) }
        }
        .font(AppFonts.mono(11))
        .foregroundStyle(theme.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(highlighted ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    // MARK: Questions

    private func promptBar(_ prompt: RulesManagerModel.Prompt) -> some View {
        let (text, keys): (String, String) = switch prompt {
        case .delete(_, let name, 0):
            ("Delete \(name)? It added no labels that would come off.", "y delete · n or esc cancel")
        case .delete(_, let name, let count):
            ("Delete \(name)? Remove the \(RuleText.count(count)) \(count == 1 ? "label" : "labels") it added? Labels you or another rule added stay.",
             "y remove · n keep · esc cancel")
        case .gap(_, let text, _):
            (text, "↵ fill · esc skip")
        case .undo(let runID, let labeled):
            ("Undo run #\(runID)? Its \(RuleText.count(labeled)) \(labeled == 1 ? "label comes" : "labels come") off, except where you or another rule added them.",
             "y undo · esc keep")
        }
        return HStack(spacing: 16) {
            Text(verbatim: text).foregroundStyle(theme.foreground)
            Spacer(minLength: 8)
            Text(verbatim: keys).font(AppFonts.mono(10)).foregroundStyle(theme.yellow)
        }
        .font(AppFonts.sans(12))
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(theme.yellowSoft.opacity(0.5))
    }
}

// MARK: - How far back

/// After saving a rule (and `B`, and the re-check after an edit): how much of the mail already here
/// it applies to, with the price of each choice.
struct BackfillView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let sheet: BackfillModel

    var body: some View {
        DialogShell(title: sheet.title, width: 780, footer: footer, onClose: { sheet.back() }) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sheet.choices, id: \.self) { choice in
                    row(choice, selected: choice == sheet.selected)
                        .onTapGesture { sheet.select(choice) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes, id: \.self) { note in
                        Text(verbatim: note)
                    }
                }
                .font(AppFonts.mono(10))
                .foregroundStyle(theme.mutedForeground)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            .padding(16)
        }
    }

    private var footer: String {
        let back = sheet.editor != nil ? "esc back to editing" : "esc back"
        return "↵ apply · j/k choose · \(back) · undo any run: gr a u"
    }

    /// Under the choices: the other models, what is reused and where it stops, and the room runs have.
    private var notes: [String] {
        var notes: [String] = []
        if let others = sheet.otherModels { notes.append(others) }
        if let estimate = sheet.estimates[sheet.selected] {
            let reuse = BackfillText.reuse(estimate)
            if !reuse.isEmpty { notes.append(reuse) }
        }
        if sheet.rule.asksClaude, let room = sheet.room { notes.append(BackfillText.room(room)) }
        if sheet.mode == .recheck { notes.append("A re-check counts what would change (+ added, − removed) and applies only when you confirm it in Activity.") }
        return notes
    }

    private func row(_ choice: BackfillChoice, selected: Bool) -> some View {
        let estimate = sheet.estimates[choice]
        let asks = sheet.rule.asksClaude
        let counts: String
        let cost: String
        if choice == .newMailOnly {
            counts = ""
            cost = "free"
        } else if let estimate {
            counts = BackfillText.counts(estimate, asksClaude: asks)
            cost = BackfillText.cost(estimate, asksClaude: asks, room: sheet.room)
        } else {
            counts = sheet.loading ? "counting…" : "could not count"
            cost = ""
        }
        return HStack(spacing: 12) {
            Text(verbatim: selected ? "▸" : " ").foregroundStyle(theme.green).frame(width: 10)
            Text(verbatim: selected ? "●" : "○").foregroundStyle(selected ? theme.green : theme.mutedForeground)
            Text(verbatim: sheet.title(of: choice))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .frame(width: 250, alignment: .leading)
            Text(verbatim: counts).foregroundStyle(theme.body).lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: cost)
                .foregroundStyle(cost.contains("over") ? theme.orange : theme.foreground)
                .lineLimit(1)
        }
        .font(AppFonts.mono(11))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
