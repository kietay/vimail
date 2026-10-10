import Foundation
import MailAI
import MailCore
import MailRules
import MailStore

/// A ✔ or ✖ a rule gets with a label edit from "why these labels?" (`x`, `a`), under the edit's undo.
struct RuleTeaching {
    var ruleID: String
    var messageID: String
    var matches: Bool
}

/// Rules: their status, the manager, making and editing rules, `=`, "why these labels?", Claude's
/// key, consent and settings.
extension AppModel {
    // MARK: - Status

    func listenToRules() {
        let rules = services.rules
        let updates = rules.status
        Task { [weak self] in
            for await status in updates {
                guard let self, self.services.rules === rules else { return }
                self.rulesStatus = status
                // Activity follows the runs' progress.
                if self.overlay == .rules { self.rulesManager?.reload() }
            }
        }
    }

    /// The status bar's rules segment, or nil when there is nothing to show.
    var rulesStatusLine: RulesStatusLine? {
        rulesStatus.statusLine(gmailRejected: rulesGmailRejected)
    }

    /// Tapping the rules status: what it reported is seen, and the rules manager opens (`gr`).
    func openRulesStatus() {
        rulesGmailRejected = 0
        openRules(focus: rulesStatus.runs.isEmpty ? .rules : .activity)
    }

    func openSettings(at section: SettingsSection) {
        settingsSection = section
        overlay = .settings
    }

    /// Received mail a day over the last 30 days: what Claude estimates and the live reserve assume.
    func refreshMailVolume() async {
        let services = services
        let window = Date().addingTimeInterval(-30 * 86_400)...Date()
        do {
            let count = try await services.store.ruleMatchCount(try RuleFilter.parse(""), scope: .received, window: window)
            guard services === self.services else { return }
            let perDay = Double(count) / 30
            mailVolume = perDay
            ai.setVolume(messagesPerDay: perDay)
        } catch {
            Self.log.error("Could not count received mail: \(String(describing: type(of: error)))")
        }
    }

    // MARK: - Rules manager (gr)

    /// `gr`: back to the rule being written when one was left open (`L`, the omnibox), else the manager.
    func manageRules() {
        if ruleEditor != nil {
            resumeRuleEditor()
        } else {
            openRules()
        }
    }

    func openRules(focus: RulesManagerModel.Focus = .rules) {
        let manager = rulesManager ?? RulesManagerModel(app: self)
        manager.focus = focus
        manager.prompt = nil
        manager.pendingDelete = false
        rulesManager = manager
        overlay = .rules
        manager.reload()
    }

    /// Shows the rule editor that was left open.
    func resumeRuleEditor() {
        guard ruleEditor != nil else { return }
        if ruleMatches != nil { leaveRuleMatches() }
        overlay = .ruleEditor
    }

    // MARK: - Making and editing rules

    /// `T`: a rule from a conversation (the cursor's by default). The newest message you received in
    /// it becomes the rule's ✔ example; THEN takes the conversation's label when it has one, else
    /// proposes a new one; WHEN keeps your colleagues' mail out; Claude drafts the ASK when it may.
    /// - Parameter labelName: THEN, from the label picker's "Always label mail like this…".
    func newRuleFromThread(_ threadID: String? = nil, labelName: String? = nil) {
        guard let threadID = threadID ?? cursorID, !threadID.hasPrefix("draft:") else {
            showToast("Select a conversation first.")
            return
        }
        guard mayStartRule() else { return }
        let services = services
        let account = account.email
        Task {
            guard let thread = try? await services.store.thread(id: threadID) else { return }
            let me = services.store.selfAddresses
            guard let message = thread.messages.last(where: { !me.contains($0.from.normalized) }) else {
                showToast("This conversation has no mail you received.")
                return
            }
            let threadLabels = labels.filter { $0.kind != .system && thread.labelIDs.contains($0.id) }
            let label = labelName ?? (threadLabels.count == 1 ? threadLabels[0].name : RuleSuggestion.labelName(for: message.from))
            let seed = RuleEditorModel.Seed(
                sender: message.from, automated: RuleSuggestion.isAutomated(message.from, isList: !(message.listUnsubscribe ?? "").isEmpty),
                account: account
            )
            let rule = Rule(key: "", name: label, when: RuleSuggestion.when(account: account, sender: message.from, onlySender: false), then: [])
            do {
                try await services.store.setExample(ruleID: rule.id, messageID: message.id, matches: true, origin: .seed, draft: true)
            } catch {
                showToast("Could not start the rule: \(error.localizedDescription)", isError: true)
                return
            }
            let editor = RuleEditorModel(draft: rule, labelName: label, saved: nil, seed: seed, returnsToManager: false, field: canDraftRules ? .preview : .ask, app: self)
            open(editor)
            editor.startDrafting(
                description: "Mail like this email.", seed: EmailDigest(message: message, thread: thread.messages, selfAddresses: me),
                keepsLabel: labelName != nil || threadLabels.count == 1
            )
        }
    }

    /// `:rule <sentence>`: a rule drafted from your description. Without Claude, the sentence is the ASK.
    func draftRule(from sentence: String) {
        let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, mayStartRule() else { return }
        let rule = Rule(key: "", name: "", ask: sentence, then: [])
        let editor = RuleEditorModel(draft: rule, labelName: "", saved: nil, seed: nil, returnsToManager: false, field: canDraftRules ? .preview : .then, app: self)
        open(editor)
        editor.startDrafting(description: sentence, seed: nil)
    }

    /// `n` in the manager: an empty rule.
    func newRule(returnsToManager: Bool = true) {
        guard mayStartRule() else { return }
        let editor = RuleEditorModel(draft: Rule(key: "", name: "", then: []), labelName: "", saved: nil, seed: nil, returnsToManager: returnsToManager, field: .name, app: self)
        open(editor)
    }

    /// ↵ in the manager, `e` in "why these labels?".
    func editRule(_ record: RuleRecord, returnsToManager: Bool = true) {
        guard mayStartRule() else { return }
        let target = record.rule.labelTargets.first
        let label = target.map { ref in labels.first { $0.id == ref.id }?.name ?? ref.lastKnownName } ?? ""
        let editor = RuleEditorModel(draft: record.rule, labelName: label, saved: record, seed: nil, returnsToManager: returnsToManager, field: .preview, app: self)
        open(editor)
    }

    /// Claude may draft rules for this account now: a key, a model it knows, and consent.
    var canDraftRules: Bool {
        ai.drafter(forAccount: services.accountKey) != nil
    }

    /// A rule left open with changes comes back instead of a new one; one without changes is dropped.
    private func mayStartRule() -> Bool {
        guard let editor = ruleEditor else { return true }
        if editor.isDirty {
            resumeRuleEditor()
            showToast("Finish or discard this rule first (esc, then y).")
            return false
        }
        editor.abandon()
        ruleEditor = nil
        return true
    }

    private func open(_ editor: RuleEditorModel) {
        backfill = nil
        ruleEditor = editor
        overlay = .ruleEditor
        editor.start()
    }

    /// "How far back" for a saved rule, or its re-check after an edit.
    func openBackfill(for rule: Rule, mode: BackfillModel.Mode, editor: RuleEditorModel?, returnsToManager: Bool) {
        let sheet = BackfillModel(rule: rule, mode: mode, editor: editor, returnsToManager: returnsToManager, app: self)
        backfill = sheet
        overlay = .backfill
        Task { await sheet.load() }
    }

    // MARK: - Settings

    /// Claude settings changed: the spend guard gets the budgets; the rules get the judge, Claude's
    /// state and your pause.
    func aiSettingsChanged(from old: AISettings) {
        let new = settings.ai
        ai.update(new)
        let services = services
        let ai = ai
        let reconfigure = new.model != old.model || new.consents != old.consents || new.budget != old.budget
        let pause = new.pauseAll != old.pauseAll ? new.pauseAll : nil
        if new.model != old.model, let mailVolume { ai.setVolume(messagesPerDay: mailVolume) }
        Task {
            if reconfigure { await services.configureRules(ai) }
            if let pause { await services.setRulesPaused(pause) }
        }
    }

    func setRulesPaused(_ paused: Bool) {
        settings.ai.pauseAll = paused
        showToast(paused ? "Rules paused on every account. Arriving mail waits." : "Rules resumed.")
    }

    /// Checks the key in use. A key that works lets the rules try Claude again after a pause Anthropic
    /// reported, such as a rejected key or missing credit.
    func verifyAnthropicKey() async {
        await ai.verifyKey()
        if case .valid = ai.keyState { await services.configureRules(ai) }
    }

    /// Checks a new API key and saves it when Anthropic accepts it. Returns true when it was saved.
    func saveAnthropicKey(_ key: String) async -> Bool {
        let check: AnthropicClient.KeyCheck
        do {
            check = try await ai.replaceKey(key)
        } catch {
            showToast("Could not save the key: \(error.localizedDescription)", isError: true)
            return false
        }
        switch check {
        case .valid:
            showToast("API key saved and verified.")
        case .modelUnavailable:
            showToast("API key saved, but it can't use \(Self.modelName(settings.ai.model)). Pick another model.", isError: true)
        case .badKey:
            showToast("Anthropic rejected that key. Nothing was saved.", isError: true)
            return false
        case .offline:
            showToast("Could not reach Anthropic to check the key. Nothing was saved.", isError: true)
            return false
        }
        await services.configureRules(ai)
        return true
    }

    func removeAnthropicKey() {
        do {
            try ai.removeKey()
        } catch {
            showToast("Could not remove the key: \(error.localizedDescription)", isError: true)
            return
        }
        let services = services
        let ai = ai
        Task { await services.configureRules(ai) }
        showToast(ai.hasKey ? "Saved key removed. The key from the environment is still used." : "API key removed. Claude rules wait; filter rules keep running.")
    }

    func confirmDeleteClaudeResults() {
        overlay = .confirm(Confirmation(
            title: "Delete Claude results?",
            message: "Deletes Claude's verdicts and reasons for this account. Labels already added stay. Mail is judged again, and billed, when a rule needs it.",
            confirmTitle: "Delete",
            action: .deleteClaudeResults
        ))
    }

    func deleteClaudeResults() {
        let store = services.store
        Task {
            do {
                try await store.deleteClaudeResults()
                showToast("Claude results deleted. Labels stay.")
            } catch {
                showToast("Could not delete Claude results: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// The model that judges now: "Haiku 5.5", or the offline simulator.
    var judgeModelName: String {
        ai.usesSimulator ? "Offline simulator" : Self.modelName(settings.ai.model)
    }

    /// "Haiku 5.5" for "claude-haiku-5-5".
    static func modelName(_ id: String) -> String {
        if let model = ClaudeModel(rawValue: id) { return model.displayName }
        return id == AIServices.simulatorModel ? "Offline simulator" : id
    }

    // MARK: - Consent

    /// Runs `then` once this account's mail may go to Claude: at once when it may (or the offline
    /// simulator judges), else after you allow it in the consent panel. "Not now" drops it. Either
    /// way the dialog that asked (the rule editor, the rules manager) comes back.
    func requireClaudeConsent(then: (() -> Void)? = nil) {
        if ai.usesSimulator || ai.hasConsent(services.accountKey) {
            then?()
            return
        }
        let asking = overlay
        openConsent()
        afterConsent = then
        consentReturn = asking
    }

    func openConsent() {
        consentDraft = settings.ai
        if consentDraft.claudeModel == nil { consentDraft.model = ClaudeModel.default.rawValue }
        afterConsent = nil
        consentReturn = nil
        overlay = .aiConsent
        Task { await refreshMailVolume() }
    }

    /// ↵ in the consent panel: this account's mail may go to Claude, with the model and budgets shown.
    func allowClaude() {
        let then = afterConsent
        afterConsent = nil
        var ai = settings.ai
        ai.model = consentDraft.model
        ai.monthlyBudgetUSD = max(0, consentDraft.monthlyBudgetUSD)
        ai.dailyBudgetUSD = max(0, consentDraft.dailyBudgetUSD)
        ai.previewDailyUSD = max(0, consentDraft.previewDailyUSD)
        ai.consents[services.accountKey] = Date()
        settings.ai = ai
        let returnTo = consentReturn
        consentReturn = nil
        overlay = returnTo
        showToast(self.ai.hasKey ? "Claude may judge this account's mail." : "Claude may judge this account's mail once you add an API key in Settings.")
        then?()
    }

    func declineConsent() {
        let returnTo = consentReturn
        afterConsent = nil
        consentReturn = nil
        overlay = returnTo
    }

    func revokeConsent() {
        settings.ai.consents[services.accountKey] = nil
        showToast("Claude no longer judges this account's mail. Filter rules keep running.")
    }

    /// j/k in the consent panel.
    func moveConsentModel(_ delta: Int) {
        let models = ClaudeModel.allCases
        let index = models.firstIndex { $0.rawValue == consentDraft.model } ?? 0
        consentDraft.model = models[(index + delta + models.count) % models.count].rawValue
    }

    // MARK: - Run rules (=)

    /// `=`: every rule that is on, on the selection or the conversation under the cursor.
    func runRulesOnSelection() {
        let targets = actionTargets.filter { !$0.hasPrefix("draft:") }
        guard !targets.isEmpty else {
            showToast("Select a conversation first.")
            return
        }
        let store = services.store
        Task {
            do {
                guard try await store.rules().contains(where: { $0.rule.enabled && $0.state == .ok }) else {
                    showToast("No rules are on.")
                    return
                }
                let messageIDs = try await store.messageLabels(inThreads: targets).filter { !$0.isLocal }.map(\.messageID)
                guard !messageIDs.isEmpty else { return }
                runRules(on: messageIDs, confirmed: false)
            } catch {
                showToast("Could not run rules: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Runs the rules on these messages. Above 5¢ it asks first; `u` undoes the run.
    func runRules(on messageIDs: [String], confirmed: Bool) {
        let services = services
        Task {
            do {
                let run = try await services.rules.runRules(on: messageIDs, confirmed: confirmed)
                guard services === self.services else { return }
                let count = messageIDs.count == 1 ? "1 message" : "\(messageIDs.count) messages"
                guard let runID = run.runID else {
                    overlay = .confirm(Confirmation(
                        title: "Run rules on \(count)?",
                        message: "Claude would judge \(run.estimate.needClaude) of them, about \(Formatting.dollars(run.estimate.micros)).",
                        confirmTitle: "Run rules",
                        action: .runRules(messageIDs)
                    ))
                    return
                }
                pushUndo(.ruleRun(runID))
                let ran = "Rules ran on \(count)."
                guard run.estimate.needClaude > 0, let pause = ai.aiPause(forAccount: services.accountKey) else {
                    showToast(ran, undoable: true)
                    return
                }
                switch pause {
                case .noConsent: requireClaudeConsent { self.showToast(ran, undoable: true) }
                case .noKey: showToast("\(ran) Claude rules wait for an API key in Settings.", undoable: true)
                default: showToast(ran, undoable: true)
                }
            } catch {
                showToast("Could not run rules: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Asks before undoing a run, with how many labels it added.
    func confirmUndoRun(_ runID: Int64) {
        let store = services.store
        Task {
            let labeled = (try? await store.run(id: runID))?.labeled ?? 0
            overlay = .confirm(Confirmation(
                title: "Undo run #\(runID)?",
                message: "It labeled \(labeled == 1 ? "1 message" : "\(labeled) messages"). Those labels come off, except where you or another rule added them.",
                confirmTitle: "Undo run",
                action: .undoRuleRun(runID)
            ))
        }
    }

    func undoRuleRun(_ runID: Int64) {
        let rules = services.rules
        Task {
            do {
                let summary = try await rules.undo(.run(runID))
                let removed = summary.labelsRemoved == 1 ? "1 label" : "\(summary.labelsRemoved) labels"
                showToast(summary.labelsRemoved == 0 ? "Undone: rules run. No labels came off." : "Undone: rules run. \(removed) came off.")
            } catch {
                showToast("Could not undo the rules run: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Why these labels? (g?)

    func openExplain() {
        guard let id = cursorID, !id.hasPrefix("draft:") else {
            showToast("Select a conversation first.")
            return
        }
        explainLines = []
        explainHighlighted = 0
        overlay = .explain(threadID: id)
        Task { await loadExplanation(threadID: id) }
    }

    func loadExplanation(threadID: String) async {
        let store = services.store
        do {
            let explanation = try await store.explain(threadID: threadID)
            let rules = try await store.rules()
            let lines = explanation.lines(rules: rules, labels: labels, modelName: { Self.modelName($0) }, date: { Formatting.readerTime($0) })
            guard overlay == .explain(threadID: threadID) else { return }
            explainLines = lines
            explainHighlighted = min(explainHighlighted, max(0, lines.count - 1))
        } catch {
            Self.log.error("Could not explain thread \(threadID): \(String(describing: type(of: error)))")
        }
    }

    var highlightedExplainLine: ExplainLine? {
        explainLines.indices.contains(explainHighlighted) ? explainLines[explainHighlighted] : nil
    }

    func moveExplain(_ delta: Int) {
        guard !explainLines.isEmpty else { return }
        explainHighlighted = min(max(explainHighlighted + delta, 0), explainLines.count - 1)
    }

    /// x: the rule was wrong. Removes its label like `t` does (`u` undoes it) and gives the rule a ✖
    /// for the message; also for a rule that agreed with a label you or Gmail added.
    func explainWrong() {
        guard case .explain(let threadID) = overlay, let line = highlightedExplainLine, let labelID = line.labelID else { return }
        let rule: (ruleID: String, messageID: String)
        switch line.kind {
        case .rule(let owner): rule = (owner.ruleID, owner.messageID)
        case .agrees(let agreement): rule = (agreement.ruleID, agreement.messageID)
        case .other, .miss:
            showToast("x is for a label a rule added or agreed with.")
            return
        }
        perform(.removeLabel(labelID), on: [threadID], labelName: line.labelName, teaching: RuleTeaching(ruleID: rule.ruleID, messageID: rule.messageID, matches: false))
    }

    /// a: the rule should have matched. Adds its label (`u` undoes it) and gives the rule a ✔ for the message.
    func explainShouldMatch() {
        guard case .explain(let threadID) = overlay, let line = highlightedExplainLine else { return }
        guard case .miss(let miss) = line.kind, let labelID = line.labelID, labels.contains(where: { $0.id == labelID }) else {
            showToast("a is for a rule that did not match.")
            return
        }
        perform(.addLabel(labelID), on: [threadID], labelName: line.labelName, teaching: RuleTeaching(ruleID: miss.ruleID, messageID: miss.messageID, matches: true))
    }

    /// The rule and message of the highlighted line, when it is about a rule.
    private var explainedRule: (ruleID: String, name: String, messageID: String)? {
        switch highlightedExplainLine?.kind {
        case .rule(let owner): (owner.ruleID, owner.ruleName ?? "the deleted rule", owner.messageID)
        case .agrees(let agreement): (agreement.ruleID, agreement.ruleName ?? "the deleted rule", agreement.messageID)
        case .miss(let miss): (miss.ruleID, miss.ruleName ?? "the deleted rule", miss.messageID)
        case .other, nil: nil
        }
    }

    /// s: a sender rule for the highlighted rule. Cycles: mail from this sender always matches, never
    /// matches, or is decided as before.
    func cycleSenderRule() {
        guard let rule = explainedRule else {
            showToast("s is for a rule's line.")
            return
        }
        let store = services.store
        Task {
            do {
                guard let sender = try await store.message(id: rule.messageID)?.from.normalized, !sender.isEmpty else { return }
                try await cycleSenderRule(ruleID: rule.ruleID, sender: sender, ruleName: rule.name)
            } catch {
                showToast("Could not change the sender rule: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Moves a rule's sender rule for `sender` on: always matches, never matches, decided as before.
    /// "Why these labels?" and the rule editor (`s`) both use it.
    /// - Parameters:
    ///   - ruleName: nil for the rule being written ("this rule").
    ///   - draft: the rule is not saved yet (`MailStore.setOverride`).
    func cycleSenderRule(ruleID: String, sender: String, ruleName: String?, draft: Bool = false) async throws {
        let store = services.store
        let rule = ruleName ?? "this rule"
        switch try await store.overrides(ruleID: ruleID).first(where: { $0.subject == sender })?.matches {
        case nil:
            try await store.setOverride(ruleID: ruleID, subject: sender, matches: true, origin: .user, draft: draft)
            showToast("From now on, mail from \(sender) always matches \(rule).")
        case true?:
            try await store.setOverride(ruleID: ruleID, subject: sender, matches: false, origin: .user, draft: draft)
            showToast("From now on, mail from \(sender) never matches \(rule).")
        case false?:
            try await store.removeOverride(ruleID: ruleID, subject: sender)
            showToast("Sender rule removed: \(rule) decides mail from \(sender) as before.")
        }
    }

    /// e: edits the highlighted line's rule.
    func editExplainedRule() {
        guard let rule = explainedRule else {
            showToast("e is for a rule's line.")
            return
        }
        let store = services.store
        Task {
            guard let record = try? await store.rules().first(where: { $0.id == rule.ruleID }), record.state != .needsUpgrade else {
                showToast("That rule can't be edited here.")
                return
            }
            editRule(record, returnsToManager: false)
        }
    }

    /// d: turns the highlighted rule off. The labels it added stay.
    func disableExplainedRule() {
        guard let rule = explainedRule else {
            showToast("d is for a rule's line.")
            return
        }
        let services = services
        Task {
            do {
                let gap = try await services.store.setRuleEnabled(id: rule.ruleID, false)
                try await services.rules.rulesChanged(.disabled(ruleID: rule.ruleID), gap: gap)
                showToast("Rule \(rule.name) turned off. Its labels stay.")
            } catch {
                showToast("Could not turn the rule off: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// u: undoes the run that added the highlighted label, after asking.
    func undoExplainedRun() {
        guard case .rule(let owner) = highlightedExplainLine?.kind else {
            showToast("u is for a label a rule added.")
            return
        }
        confirmUndoRun(owner.runID)
    }
}
