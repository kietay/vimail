import Foundation
import MailCore
import MailRules
import MailStore
import Observation

/// The rules manager (`gr`, design §5.5): the account's rules in the order they run, what each has
/// done, and Activity, the runs over stored mail and live mail's daily runs.
@MainActor
@Observable
final class RulesManagerModel {
    enum Focus { case rules, activity }

    /// A question in the manager, answered with a key.
    enum Prompt: Equatable {
        /// `dd`: delete the rule, removing the labels it added (y) or keeping them (n).
        case delete(ruleID: String, name: String, labels: Int)
        /// `x` turned a rule back on: fill the time it was off (↵) or not (Esc). `needsClaude`: the
        /// run sends mail to Claude, so it asks for consent first.
        case gap(runID: Int64, text: String, needsClaude: Bool)
        /// `u` in Activity.
        case undo(runID: Int64, labeled: Int)
    }

    private(set) var records: [RuleRecord] = []
    private(set) var stats: [String: RuleStats] = [:]
    /// Unfinished runs first, then the most recent.
    private(set) var runs: [RunRecord] = []
    /// What is left of runs that wait for you, priced now.
    private(set) var estimates: [Int64: RunEstimate] = [:]
    private(set) var loaded = false
    var focus = Focus.rules
    var highlighted = 0
    var activityHighlighted = 0
    var prompt: Prompt?
    /// The first `d` of `dd`.
    var pendingDelete = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let services: AppServices
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadAgain = false
    /// The state each estimate was made in, so it is priced again only when the run moved on.
    @ObservationIgnored private var pricedAt: [Int64: String] = [:]

    init(app: AppModel) {
        self.app = app
        services = app.services
    }

    var highlightedRecord: RuleRecord? {
        records.indices.contains(highlighted) ? records[highlighted] : nil
    }

    var highlightedRun: RunRecord? {
        runs.indices.contains(activityHighlighted) ? runs[activityHighlighted] : nil
    }

    var activity: [ActivityLine] {
        runs.map { $0.activityLine(rules: records, estimate: estimates[$0.id]) }
    }

    /// "◆ receipts · Gmail" for a rule's row, or nil when its label is gone.
    func target(of record: RuleRecord) -> (label: MailLabel, kind: String)? {
        guard let id = record.rule.labelTargets.first?.id, let label = app?.labels.first(where: { $0.id == id }) else { return nil }
        return (label, label.kind == .local ? "local" : "Gmail")
    }

    // MARK: - Loading

    /// Reads the rules, their counts and the runs again. Calls made while a read is under way are
    /// folded into one more read after it.
    func reload() {
        guard reloadTask == nil else {
            reloadAgain = true
            return
        }
        reloadTask = Task {
            repeat {
                reloadAgain = false
                await load()
            } while reloadAgain && !Task.isCancelled
            reloadTask = nil
        }
    }

    private func load() async {
        let store = services.store
        do {
            async let records = store.rules()
            async let stats = store.ruleStats()
            async let unfinished = store.runs(limit: 50, unfinished: true)
            async let recent = store.runs(limit: 30)
            let (loadedRecords, loadedStats, open, latest) = try await (records, stats, unfinished, recent)
            let openIDs = Set(open.map(\.id))
            let highlightedRule = highlightedRecord?.id
            let highlightedRunID = highlightedRun?.id
            self.records = loadedRecords
            self.stats = loadedStats
            runs = open + latest.filter { !openIDs.contains($0.id) }
            highlighted = highlightedRule.flatMap { id in self.records.firstIndex { $0.id == id } } ?? min(highlighted, max(0, self.records.count - 1))
            activityHighlighted = highlightedRunID.flatMap { id in runs.firstIndex { $0.id == id } } ?? min(activityHighlighted, max(0, runs.count - 1))
            loaded = true
        } catch {
            AppModel.log.error("Could not load the rules manager: \(String(describing: type(of: error)))")
            return
        }
        await priceWaitingRuns()
    }

    /// Prices what is left of the runs that wait for you: paused, or awaiting confirmation.
    private func priceWaitingRuns() async {
        let rules = services.rules
        for run in runs where run.state == .paused || run.state == .awaitingConfirm {
            let key = "\(run.state.rawValue) \(run.pauseReason?.rawValue ?? "") \(run.done) \(run.rules.map { "\($0.id)@\($0.revision)" }.joined())"
            guard pricedAt[run.id] != key else { continue }
            pricedAt[run.id] = key
            do {
                estimates[run.id] = try await rules.estimate(runID: run.id)
            } catch {
                AppModel.log.error("Could not price run #\(run.id): \(String(describing: type(of: error)))")
            }
        }
    }

    // MARK: - Moving

    func move(_ delta: Int) {
        switch focus {
        case .rules:
            guard !records.isEmpty else { return }
            highlighted = min(max(highlighted + delta, 0), records.count - 1)
        case .activity:
            guard !runs.isEmpty else { return }
            activityHighlighted = min(max(activityHighlighted + delta, 0), runs.count - 1)
        }
    }

    /// `a` and Tab: between the rules and Activity.
    func switchFocus() {
        focus = focus == .rules ? .activity : .rules
    }

    // MARK: - Rules

    /// ↵: edits the highlighted rule.
    func edit() {
        guard let record = highlightedRecord, let app else { return }
        guard record.state != .needsUpgrade else {
            app.showToast("A newer vimail saved this rule. It stays as it is here.")
            return
        }
        app.editRule(record)
    }

    /// `x`: turns the highlighted rule off or on. Back on, the mail that arrived while it was off
    /// is offered as a priced run.
    func toggle() {
        guard let record = highlightedRecord, let app else { return }
        let services = services
        let on = !record.rule.enabled
        let name = record.rule.name
        Task {
            do {
                let gap = try await services.store.setRuleEnabled(id: record.id, on)
                guard on else {
                    try await services.rules.rulesChanged(.disabled(ruleID: record.id))
                    app.showToast("\(name) is off. Its labels stay.")
                    reload()
                    return
                }
                let runID = try await services.rules.rulesChanged(.enabled(ruleID: record.id), gap: gap)
                reload()
                guard let runID, let gap else {
                    app.showToast("\(name) is on. It judges new mail from now on.")
                    return
                }
                let estimate = try await services.rules.estimate(runID: runID)
                prompt = .gap(
                    runID: runID, text: "\(name) was " + BackfillText.gap(gap, estimate: estimate, asksClaude: record.rule.asksClaude),
                    needsClaude: record.rule.asksClaude && estimate.needClaude > 0
                )
            } catch RuleStoreError.labelMissing {
                app.showToast("\(name)'s label is gone. ↵ to pick another, then turn it on.", isError: true)
            } catch RuleStoreError.needsUpgrade {
                app.showToast("A newer vimail saved this rule. It stays off here.", isError: true)
            } catch {
                app.showToast("Could not turn \(name) \(on ? "on" : "off"): \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// ↵ on the gap offer: the run fills the time the rule was off. Only a run that sends mail to
    /// Claude asks for consent.
    func fillGap(_ runID: Int64, needsClaude: Bool) {
        prompt = nil
        guard let app else { return }
        let rules = services.rules
        let go: () -> Void = {
            Task {
                do {
                    try await rules.confirmRun(runID)
                    app.showToast("Filling the gap: run #\(runID) started.")
                } catch {
                    app.showToast("Could not start the run: \(error.localizedDescription)", isError: true)
                }
            }
        }
        if needsClaude { app.requireClaudeConsent(then: go) } else { go() }
    }

    /// Esc on the gap offer: the time stays uncovered.
    func skipGap(_ runID: Int64) {
        prompt = nil
        let rules = services.rules
        Task { try? await rules.cancelRun(runID) }
    }

    /// `J` and `K`: runs the highlighted rule later or earlier.
    func reorder(_ delta: Int) {
        guard let record = highlightedRecord else { return }
        let target = highlighted + delta
        guard records.indices.contains(target) else { return }
        let services = services
        records.swapAt(highlighted, target)
        highlighted = target
        Task {
            do {
                try await services.store.moveRule(id: record.id, to: target)
                try await services.rules.rulesChanged(.reordered)
            } catch {
                app?.showToast("Could not move the rule: \(error.localizedDescription)", isError: true)
            }
            reload()
        }
    }

    /// `B`: applies the highlighted rule to stored mail.
    func applyToExisting() {
        guard let record = highlightedRecord, let app else { return }
        guard record.rule.enabled, record.state == .ok else {
            app.showToast("Turn \(record.rule.name) on first (x).")
            return
        }
        app.openBackfill(for: record.rule, mode: .backfill, editor: nil, returnsToManager: true)
    }

    /// `dd`: asks how to delete the highlighted rule.
    func askDelete() {
        guard let record = highlightedRecord else { return }
        let store = services.store
        Task {
            let count = (try? await store.removableLabelCount(ruleID: record.id)) ?? 0
            prompt = .delete(ruleID: record.id, name: record.rule.name, labels: count)
        }
    }

    /// Deletes the rule; with `removingLabels`, the labels only it added go too.
    func delete(_ ruleID: String, name: String, removingLabels: Bool) {
        prompt = nil
        guard let app else { return }
        let services = services
        Task {
            do {
                let summary = try await services.store.deleteRuleEffects(ruleID: ruleID, removeLabels: removingLabels)
                try await services.store.deleteRule(id: ruleID)
                try await services.rules.rulesChanged(.deleted(ruleID: ruleID))
                if summary.syncedChanges > 0 { services.engine.wake() }
                let removed = summary.labelsRemoved == 1 ? "1 label" : "\(summary.labelsRemoved) labels"
                app.showToast(removingLabels ? "Rule \(name) deleted with \(removed) it added." : "Rule \(name) deleted. Its labels stay.")
            } catch {
                app.showToast("Could not delete \(name): \(error.localizedDescription)", isError: true)
            }
            reload()
        }
    }

    /// `r`: messages that failed go back in the queue.
    func retryFailed() {
        guard let app else { return }
        let services = services
        Task {
            do {
                let count = try await services.store.requeueFailed()
                services.rules.wake()
                app.showToast(count == 0 ? "Nothing failed." : count == 1 ? "1 message queued again." : "\(count) messages queued again.")
            } catch {
                app.showToast("Could not retry: \(error.localizedDescription)", isError: true)
            }
            reload()
        }
    }

    // MARK: - Activity

    /// ↵: confirms a run that waits for it (a counted re-check, a gap or backlog), or continues a
    /// paused one, with what is left priced again.
    func confirmOrContinue() {
        guard let run = highlightedRun, let app else { return }
        let rules = services.rules
        let estimate = estimates[run.id]
        let go: () -> Void = {
            Task {
                do {
                    switch run.state {
                    case .awaitingConfirm:
                        try await rules.confirmRun(run.id)
                        app.showToast(run.kind == .recheck && run.plus != nil ? "Applying the re-check of run #\(run.id)." : "Run #\(run.id) started.")
                    case .paused:
                        // A run paused at its cap goes on with a cap for what is left.
                        let cap = run.pauseReason == .cap ? run.costMicros + (estimate?.capMicros ?? 0) : nil
                        try await rules.resumeRun(run.id, capMicros: cap)
                        app.showToast("Run #\(run.id) continues.")
                    default:
                        return
                    }
                } catch {
                    app.showToast("Could not continue run #\(run.id): \(error.localizedDescription)", isError: true)
                }
                self.reload()
            }
        }
        guard run.state == .awaitingConfirm || run.state == .paused else { return }
        if (estimate?.needClaude ?? 0) > 0 { app.requireClaudeConsent(then: go) } else { go() }
    }

    /// `c`: stops the highlighted run for good. What it did stays (`u` undoes it).
    func cancelRun() {
        guard let run = highlightedRun, [.running, .paused, .awaitingConfirm].contains(run.state), run.kind != .live, let app else { return }
        let rules = services.rules
        Task {
            if (try? await rules.cancelRun(run.id)) == true { app.showToast("Run #\(run.id) cancelled. What it did stays: u undoes it.") }
            reload()
        }
    }

    /// `u`: asks before undoing the highlighted run.
    func askUndo() {
        guard let run = highlightedRun, run.state != .undone else { return }
        guard run.labeled > 0 else {
            app?.showToast("Run #\(run.id) added no labels.")
            return
        }
        prompt = .undo(runID: run.id, labeled: run.labeled)
    }

    func undo(_ runID: Int64) {
        prompt = nil
        app?.undoRuleRun(runID)
    }
}
