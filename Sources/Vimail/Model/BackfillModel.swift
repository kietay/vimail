import Foundation
import MailAI
import MailCore
import MailRules
import Observation

/// "Apply to mail already on this Mac?" after a rule is saved (design §5.4), `B` in the rules manager,
/// and the re-check offered after an edit. Every figure comes from `RuleEngine.estimate`; the
/// preselected choice from `RuleEngine.defaultChoice`.
@MainActor
@Observable
final class BackfillModel {
    enum Mode {
        /// A new rule, or `B`: how far back to apply it.
        case backfill
        /// An edit changed what the rule decides: judge its earlier results again, applied once you confirm.
        case recheck
    }

    let rule: Rule
    let mode: Mode
    let choices: [BackfillChoice]
    private(set) var estimates: [BackfillChoice: RunEstimate] = [:]
    var selected: BackfillChoice = .newMailOnly
    private(set) var loading = true
    private(set) var room: RunRoom?
    /// The oldest stored message in the rule's scope ("All cached (since 2 Jun)").
    private(set) var oldest: Date?
    private(set) var starting = false
    /// Esc goes back to it.
    let editor: RuleEditorModel?
    /// Without an editor, Esc goes back to the rules manager rather than the mailbox.
    let returnsToManager: Bool
    /// You picked a choice before the preselection arrived: it stays.
    @ObservationIgnored private var moved = false
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let services: AppServices

    init(rule: Rule, mode: Mode, editor: RuleEditorModel?, returnsToManager: Bool, app: AppModel) {
        self.rule = rule
        self.mode = mode
        self.editor = editor
        self.returnsToManager = returnsToManager
        self.app = app
        services = app.services
        choices = mode == .recheck ? BackfillChoice.recheck : BackfillChoice.backfill(asksClaude: rule.asksClaude)
    }

    var title: String {
        switch mode {
        case .backfill: "Apply “\(rule.name)” to mail already on this Mac?"
        case .recheck: "Re-check “\(rule.name)” after your edit?"
        }
    }

    var labelID: String? { rule.labelTargets.first?.id }

    /// A choice's line: "Newest 100 for Claude (≈ 5 days)"; for a re-check, doing nothing is "Not now".
    func title(of choice: BackfillChoice) -> String {
        if mode == .recheck, choice == .newMailOnly { return "Not now: earlier labels stay" }
        return BackfillText.title(choice, estimate: estimates[choice], oldest: oldest)
    }

    /// Prices every choice at once, then preselects one.
    func load() async {
        let rules = services.rules
        let ruleID = rule.id
        let kind: RunKind = mode == .recheck ? .recheck : .backfill
        let scope = rule.scope.mailboxes
        let store = services.store
        async let oldestDate = store.oldestMessageDate(scope: scope)
        await withTaskGroup(of: (BackfillChoice, RunEstimate?).self) { group in
            for choice in choices {
                guard let window = choice.window else { continue }
                group.addTask { (choice, try? await rules.estimate(RunPlan(ruleID: ruleID, kind: kind, window: window))) }
            }
            for await (choice, estimate) in group {
                if let estimate {
                    estimates[choice] = estimate
                } else {
                    AppModel.log.error("Could not price a run of rule \(ruleID)")
                }
            }
        }
        oldest = try? await oldestDate
        if let app {
            let snapshot = await app.ai.spend.snapshot()
            room = RunRoom(today: snapshot.runRoomToday, month: snapshot.runRoomMonth, reserve: snapshot.liveReserveToday)
        }
        let preselected = await defaultChoice()
        if !moved { selected = preselected }
        loading = false
    }

    /// A new rule's run (USER DECISIONS #5) from `RuleEngine.defaultChoice`. A re-check: what the
    /// rule labeled, when it labeled anything and that fits today; else nothing.
    private func defaultChoice() async -> BackfillChoice {
        switch mode {
        case .backfill:
            do {
                guard let window = try await services.rules.defaultChoice(ruleID: rule.id)?.plan?.window else { return .newMailOnly }
                return BackfillChoice(window) ?? .newMailOnly
            } catch {
                AppModel.log.error("Could not pick the default run for rule \(rule.id): \(String(describing: type(of: error)))")
                return .newMailOnly
            }
        case .recheck:
            guard let labeled = estimates[.labeled], labeled.messages > 0, labeled.fitsToday else { return .newMailOnly }
            return .labeled
        }
    }

    func move(_ delta: Int) {
        guard let index = choices.firstIndex(of: selected) else { return }
        moved = true
        selected = choices[min(max(index + delta, 0), choices.count - 1)]
    }

    func select(_ choice: BackfillChoice) {
        moved = true
        selected = choice
    }

    /// The selected run on the other models, at their list prices.
    var otherModels: String? {
        guard rule.asksClaude, let app, let estimate = estimates[selected], estimate.needClaude > 0 else { return nil }
        let current = app.ai.usesSimulator ? nil : app.settings.ai.model
        let others = ClaudeModel.allCases.filter { $0.rawValue != current }.map { model in
            (name: model.displayName, micros: RuleEngine.listPriceMicros(calls: estimate.needClaude, prices: AIServices.tokenPrices(model)))
        }
        return BackfillText.otherModels(others)
    }

    // MARK: - Choosing

    /// ↵: starts the selected run, then shows the label's mailbox, where conversations appear as they
    /// are labeled. A re-check counts first and waits for you in Activity.
    func apply() {
        guard !starting, let app else { return }
        guard let window = selected.window else {
            finish()
            app.showToast(mode == .recheck ? "Rule \(rule.name) saved. Earlier labels stay as they are." : "Rule \(rule.name) judges new mail from now on.")
            return
        }
        let plan = RunPlan(ruleID: rule.id, kind: mode == .recheck ? .recheck : .backfill, window: window)
        let cap = estimates[selected]?.capMicros
        let needsClaude = rule.asksClaude && (estimates[selected]?.needClaude ?? 1) > 0
        let start = { [weak self] in
            guard let self else { return }
            starting = true
            Task {
                defer { self.starting = false }
                do {
                    let runID = try await self.services.rules.startRun(plan, capMicros: cap)
                    self.started(runID)
                } catch {
                    app.showToast("Could not start the run: \(error.localizedDescription)", isError: true)
                }
            }
        }
        if needsClaude { app.requireClaudeConsent(then: start) } else { start() }
    }

    private func started(_ runID: Int64) {
        guard let app else { return }
        let messages = estimates[selected].map { $0.messages == 1 ? "1 message" : "\(RuleText.count($0.messages)) messages" } ?? "stored mail"
        finish(leaving: true)
        switch mode {
        case .backfill:
            app.overlay = nil
            if let labelID { app.navigate(to: .mailbox(.label(labelID))) }
            app.showToast("Applying \(rule.name) to \(messages). Labels appear as they land · gr a shows run #\(runID), u there undoes it.")
        case .recheck:
            app.openRules(focus: .activity)
            app.showToast("Re-checking \(rule.name): nothing changes until you apply it here (↵).")
        }
    }

    /// Closes the sheet. The rule is saved, so the editor goes too.
    private func finish(leaving: Bool = false) {
        guard let app else { return }
        editor?.abandon()
        if app.ruleEditor === editor { app.ruleEditor = nil }
        app.backfill = nil
        guard !leaving else { return }
        if returnsToManager { app.openRules() } else { app.overlay = nil }
    }

    /// Esc: back to editing the rule, or to the rules manager.
    func back() {
        guard let app else { return }
        app.backfill = nil
        if let editor {
            app.ruleEditor = editor
            app.overlay = .ruleEditor
        } else if returnsToManager {
            app.openRules()
        } else {
            app.overlay = nil
        }
    }
}
