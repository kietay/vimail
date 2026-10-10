import Foundation
import MailCore
import MailStore

/// One choice on the "how far back" sheet after saving a rule (design §5.4), or on its re-check
/// after an edit.
public enum BackfillChoice: Hashable, Sendable {
    /// Nothing runs now: the rule judges arriving mail.
    case newMailOnly
    /// Back to the `n`th newest message that needs Claude.
    case newest(Int)
    case lastDays(Int)
    case allCached
    /// A re-check of the messages where the rule owns its label.
    case labeled

    /// The sheet after saving a new rule. Filter rules have no "newest for Claude".
    public static func backfill(asksClaude: Bool) -> [BackfillChoice] {
        [.newMailOnly] + (asksClaude ? [.newest(RuleEngine.defaultNewest)] : []) + [.lastDays(14), .lastDays(30), .lastDays(90), .allCached]
    }

    /// The re-check offered after an edit changed what a rule decides.
    public static let recheck: [BackfillChoice] = [.newMailOnly, .labeled, .lastDays(RuleEngine.defaultBackfillDays)]

    /// What the run covers, or nil for new mail only.
    public var window: RunPlan.Window? {
        switch self {
        case .newMailOnly: nil
        case .newest(let count): .newestNeedingClaude(count)
        case .lastDays(let days): .lastDays(days)
        case .allCached: .allCached
        case .labeled: .labeled
        }
    }

    /// The choice that starts a run over `window`.
    public init?(_ window: RunPlan.Window) {
        switch window {
        case .newestNeedingClaude(let count): self = .newest(count)
        case .lastDays(let days): self = .lastDays(days)
        case .allCached: self = .allCached
        case .labeled: self = .labeled
        case .dates: return nil
        }
    }
}

/// What runs may spend, from the app's spend guard, in millionths of a dollar.
public struct RunRoom: Sendable, Hashable {
    public var today: Int64
    public var month: Int64
    /// What today's budget keeps for live mail.
    public var reserve: Int64

    public init(today: Int64, month: Int64, reserve: Int64) {
        self.today = today
        self.month = month
        self.reserve = reserve
    }
}

/// The lines of the "how far back" sheet (design §5.4). Every figure comes from `RuleEngine.estimate`.
public enum BackfillText {
    /// A run judges about one message a second.
    public static let callsPerSecond = 1.0

    /// "New mail only", "Newest 100 for Claude (≈ 5 days)", "Last 14 days", "All cached (since 2 Jun)",
    /// "The 212 it labeled".
    /// - Parameter oldest: the oldest stored message in the rule's scope.
    public static func title(_ choice: BackfillChoice, estimate: RunEstimate?, oldest: Date?, now: Date = Date()) -> String {
        switch choice {
        case .newMailOnly:
            return "New mail only"
        case .newest(let count):
            guard let start = estimate?.counts?.claudeSpan?.lowerBound else { return "Newest \(count) for Claude" }
            return "Newest \(count) for Claude (\(span(from: start, to: now)))"
        case .lastDays(let days):
            return "Last \(days) days"
        case .allCached:
            return oldest.map { "All cached (since \(RuleText.day($0)))" } ?? "All cached"
        case .labeled:
            guard let estimate else { return "The messages it labeled" }
            return estimate.messages == 1 ? "The 1 message it labeled" : "The \(RuleText.count(estimate.messages)) it labeled"
        }
    }

    /// "≈ 5 days", "≈ 1 day", "< 1 day".
    static func span(from start: Date, to end: Date) -> String {
        let days = Int((end.timeIntervalSince(start) / 86_400).rounded())
        if days < 1 { return "< 1 day" }
        return days == 1 ? "≈ 1 day" : "≈ \(days) days"
    }

    /// "402 msgs · 64 filtered · 309 Claude"; a filter rule: "338 of 402 msgs".
    public static func counts(_ estimate: RunEstimate, asksClaude: Bool) -> String {
        guard let counts = estimate.counts else {
            return asksClaude ? "\(RuleText.count(estimate.messages)) msgs · \(RuleText.count(estimate.needClaude)) Claude" : "\(RuleText.count(estimate.messages)) msgs"
        }
        guard asksClaude else { return "\(RuleText.count(counts.passing)) of \(RuleText.count(counts.inScope)) msgs" }
        return "\(RuleText.count(counts.inScope)) msgs · \(RuleText.count(counts.inScope - counts.passing)) filtered · \(RuleText.count(estimate.needClaude)) Claude"
    }

    /// "≈ $3.91 · ≈ 6 min", "≈ $41.61 · over month room", "free".
    /// - Parameter room: what runs may spend; nil when the app reports no spend figures.
    public static func cost(_ estimate: RunEstimate, asksClaude: Bool, room: RunRoom?) -> String {
        guard asksClaude, estimate.needClaude > 0 else { return "free" }
        let price = Dollars.estimate(estimate.micros)
        if let room, estimate.micros > room.month { return "\(price) · over month room" }
        if let room, estimate.micros > room.today { return "\(price) · over today's room" }
        return duration(calls: estimate.needClaude).map { "\(price) · \($0)" } ?? price
    }

    /// How long a run of `calls` Claude calls takes at about one a second: "< 1 min", "≈ 6 min", "≈ 2 h".
    public static func duration(calls: Int) -> String? {
        guard calls > 0 else { return nil }
        let seconds = Double(calls) / callsPerSecond
        if seconds < 60 { return "< 1 min" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 120 { return "≈ \(minutes) min" }
        return "≈ \(Int((Double(minutes) / 60).rounded())) h"
    }

    /// "25 preview verdicts and 4 marks reused · stops at 1.5× ($1.90)".
    public static func reuse(_ estimate: RunEstimate) -> String {
        var parts: [String] = []
        if let counts = estimate.counts, counts.cachedVerdicts + counts.decidedByYou > 0 {
            let verdicts = counts.cachedVerdicts == 1 ? "1 verdict" : "\(RuleText.count(counts.cachedVerdicts)) verdicts"
            let marks = counts.decidedByYou == 1 ? "1 of your marks" : "\(RuleText.count(counts.decidedByYou)) of your marks"
            switch (counts.cachedVerdicts > 0, counts.decidedByYou > 0) {
            case (true, true): parts.append("\(verdicts) and \(marks) reused")
            case (true, false): parts.append("\(verdicts) reused")
            default: parts.append("\(marks) reused")
            }
        }
        if estimate.needClaude > 0 { parts.append("stops at 1.5× (\(Dollars.text(estimate.capMicros)))") }
        return parts.joined(separator: " · ")
    }

    /// "Runs may use $1.88 today, $13.18 this month; $1.70 stays for new mail".
    public static func room(_ room: RunRoom) -> String {
        "Runs may use \(Dollars.text(room.today)) today, \(Dollars.text(room.month)) this month; \(Dollars.text(room.reserve)) stays for new mail"
    }

    /// "Selected on Sonnet 5.5 ≈ $0.63 · Opus 5.5 ≈ $1.27 (change in Settings)".
    /// - Parameter others: the other models' names with what the run would cost on each.
    public static func otherModels(_ others: [(name: String, micros: Int64)]) -> String? {
        guard !others.isEmpty else { return nil }
        return "Selected on " + others.map { "\($0.name) \(Dollars.estimate($0.micros))" }.joined(separator: " · ") + " (change in Settings)"
    }

    /// The rules manager's offer when a rule comes back on: "off 9–14 Oct · 37 messages · ≈ $0.47".
    public static func gap(_ interval: DateInterval, estimate: RunEstimate, asksClaude: Bool) -> String {
        let messages = estimate.messages == 1 ? "1 message" : "\(RuleText.count(estimate.messages)) messages"
        let price = asksClaude && estimate.needClaude > 0 ? Dollars.estimate(estimate.micros) : "free"
        return "off \(RuleText.days(interval)) · \(messages) · \(price)"
    }
}

/// One line of the rules manager's Activity (design §5.5):
/// `#41  backfill from 4 Oct  Receipts v3  129 · 100 judged · 31 labeled · $1.24  u`.
public struct ActivityLine: Sendable, Hashable, Identifiable {
    public var id: Int64
    /// "backfill from 4 Oct", "live 9 Oct", "re-check", "gap 9–14 Oct".
    public var kind: String
    /// "Receipts v3", "all rules", "2 rules".
    public var rules: String
    /// "129 · 100 judged · 31 labeled · $1.24", "+5 −3 · ↵ apply", "paused: Receipts changed · ↵ continue with v4 ≈ $0.40".
    public var detail: String
    /// The key it offers: "↵" (confirm or continue), "c" (cancel), "u" (undo), or nil.
    public var key: String?
    /// Waits for you: paused or awaiting confirmation.
    public var needsYou: Bool
}

extension RunRecord {
    /// This run in Activity.
    /// - Parameters:
    ///   - rules: every rule now, for names and current revisions.
    ///   - estimate: what is left, priced now (`RuleEngine.estimate(runID:)`), for runs paused or
    ///     waiting for confirmation.
    public func activityLine(rules: [RuleRecord], estimate: RunEstimate?) -> ActivityLine {
        let byID = Dictionary(rules.map { ($0.id, $0.rule) }, uniquingKeysWith: { first, _ in first })
        let counts = "\(RuleText.count(total)) · \(RuleText.count(judged)) judged · \(RuleText.count(labeled)) labeled · \(Dollars.text(costMicros))"
        let undoKey = labeled > 0 ? "u" : nil
        var detail = counts
        var key = undoKey
        var needsYou = false
        switch state {
        case .running where kind == .live:
            break
        case .running:
            detail = isDryRun
                ? "counting \(RuleText.count(done))/\(RuleText.count(total)) · \(Dollars.text(costMicros))"
                : "\(RuleText.count(done))/\(RuleText.count(total)) · \(RuleText.count(labeled)) labeled · \(Dollars.text(costMicros)) · running"
            key = "c"
        case .paused:
            needsYou = true
            key = "↵"
            detail = "\(RuleText.count(done))/\(RuleText.count(total)) · \(Dollars.text(costMicros)) · paused: \(pauseText(byID))"
            detail += " · ↵ " + continueText(byID, estimate: estimate)
        case .awaitingConfirm:
            needsYou = true
            key = "↵"
            if kind == .recheck, let plus, let minus {
                detail = "+\(plus) −\(minus) · ↵ apply"
            } else {
                let micros = estimate?.micros ?? estimateMicros
                let price = micros.map { $0 > 0 ? Dollars.estimate($0) : "free" }
                let messages = total == 1 ? "1 message" : "\(RuleText.count(total)) messages"
                detail = ([messages] + (price.map { [$0] } ?? [])).joined(separator: " · ") + " · ↵ confirm"
            }
        case .done:
            break
        case .cancelled:
            detail += " · cancelled"
        case .undone:
            detail += " · undone"
            key = nil
        }
        return ActivityLine(id: id, kind: kindText, rules: rulesText(byID), detail: detail, key: key, needsYou: needsYou)
    }

    /// "live 9 Oct", "backfill from 4 Oct", "backfill, all", "re-check", "manual", "gap 9–14 Oct", "backlog".
    var kindText: String {
        switch kind {
        case .live: return "live " + RuleText.day(createdAt)
        case .backfill:
            guard let window else { return "backfill, all" }
            return "backfill from " + RuleText.day(window.lowerBound)
        case .recheck: return "re-check"
        case .manual: return "manual"
        case .gap: return window.map { "gap " + RuleText.days(DateInterval(start: $0.lowerBound, end: $0.upperBound)) } ?? "gap"
        case .backlog: return "backlog"
        }
    }

    /// "Receipts v3" for a run of one rule; "all rules" for live mail; "2 rules".
    func rulesText(_ rules: [String: Rule]) -> String {
        if kind == .live { return "all rules" }
        switch self.rules.count {
        case 0: return "no rules"
        case 1: return "\(rules[self.rules[0].id]?.name ?? "deleted rule") v\(self.rules[0].revision)"
        default: return "\(self.rules.count) rules"
        }
    }

    /// Why it paused: "run budget spent today", "reached its cap ($1.90)", "Receipts changed".
    func pauseText(_ rules: [String: Rule]) -> String {
        switch pauseReason {
        case .budget?: return "run budget spent; continues tomorrow"
        case .cap?: return "reached its cap (\(Dollars.text(capMicros ?? 0)))"
        case .user?, nil: return "by you"
        case .ai?: return "Claude unavailable"
        case .modelChanged?: return "the model changed"
        case .ruleChanged?:
            let changed = self.rules.filter { ref in rules[ref.id].map { $0.revision != ref.revision } ?? false }
            let names = changed.compactMap { rules[$0.id]?.name }
            return names.isEmpty ? "its rule changed" : LabelEditNote.names(names) + " changed"
        }
    }

    /// "continue ≈ $0.40", "continue with v4 ≈ $0.40".
    func continueText(_ rules: [String: Rule], estimate: RunEstimate?) -> String {
        var text = "continue"
        if pauseReason == .ruleChanged, self.rules.count == 1, let rule = rules[self.rules[0].id] { text += " with v\(rule.revision)" }
        if let estimate, estimate.needClaude > 0 { text += " \(Dollars.estimate(estimate.micros))" }
        return text
    }
}

extension RuleRecord {
    /// "filter", "filter+Claude" or "Claude".
    public var kindText: String {
        guard rule.asksClaude else { return "filter" }
        return rule.when.trimmingCharacters(in: .whitespaces).isEmpty ? "Claude" : "filter+Claude"
    }

    /// "212 labeled · 3 unsure · since 9 Jul".
    public func countsText(_ stats: RuleStats?) -> String {
        var parts = ["\(RuleText.count(stats?.labeled ?? 0)) labeled"]
        if let unsure = stats?.unsure, unsure > 0 { parts.append("\(RuleText.count(unsure)) unsure") }
        if let since = coveredSince { parts.append("since \(RuleText.day(since))") }
        return parts.joined(separator: " · ")
    }

    /// Why it does not run, or nil: "tripped: matched most new mail · x turns it back on",
    /// "label missing", "needs a newer vimail".
    public var warning: String? {
        switch state {
        case .ok: nil
        case .tripped: "tripped: it matched most new mail · x turns it back on"
        case .labelMissing: "label missing · ↵ pick another"
        case .needsUpgrade: "needs a newer vimail"
        }
    }
}

extension RuleEngineStatus {
    /// The rules manager's summary: "October $3.12/$20 · today $0.42/$3 · Haiku 5.5 · 2 waiting · 1 failed".
    /// - Parameters:
    ///   - month: the month's name.
    ///   - model: the model's name.
    public func managerSummary(month: String, model: String) -> String {
        var parts = [
            "\(month) \(Dollars.text(spendMonth))/\(Dollars.text(budgetMonth))",
            "today \(Dollars.text(spendToday))/\(Dollars.text(budgetDay))",
            model,
        ]
        if userPaused { parts.append("paused") }
        if waitingAI > 0 { parts.append("\(RuleText.count(waitingAI)) waiting") }
        if held > 0 { parts.append("\(RuleText.count(held)) held") }
        if failed > 0 { parts.append("\(RuleText.count(failed)) failed") }
        if unsureToReview > 0 { parts.append("\(RuleText.count(unsureToReview)) unsure") }
        return parts.joined(separator: " · ")
    }
}
