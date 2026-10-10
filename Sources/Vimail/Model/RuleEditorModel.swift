import Foundation
import MailAI
import MailCore
import MailRules
import MailStore
import Observation
import VimailKit

/// The rule editor (design §5.3): the draft's fields, and a live preview of what it decides on your mail.
///
/// WHEN previews are free and follow each change after 150 ms. `⌃r` and `⌃R` send preview rows to
/// Claude: they are priced first and ask above 5¢. Marks (`y`, `n`) and sender rules (`s`) are stored
/// at once under the rule's ID, also before a new rule is saved: saving keeps the ID, and discarding
/// a new rule forgets them.
@MainActor
@Observable
final class RuleEditorModel {
    enum Field: CaseIterable {
        case name, when, onlySender, ask, then, scope, replies, stop, broad, edits, preview

        var focusTarget: FocusTarget? {
            switch self {
            case .name: .ruleName
            case .when: .ruleWhen
            case .ask: .ruleAsk
            case .then: .ruleLabel
            default: nil
            }
        }

        var isText: Bool { focusTarget != nil }

        init?(_ target: FocusTarget) {
            switch target {
            case .ruleName: self = .name
            case .ruleWhen: self = .when
            case .ruleAsk: self = .ask
            case .ruleLabel: self = .then
            default: return nil
            }
        }
    }

    /// A question at the foot of the preview, answered with a key.
    enum Prompt: Equatable {
        /// Esc on a draft with changes.
        case discard
        /// ⌘↵ with marks the last test did not use.
        case saveUntested(marks: Int)
        /// A test above 5¢.
        case test(PreviewTest, PreviewCost)
    }

    /// The email `T` made the rule from.
    struct Seed {
        var sender: EmailAddress
        /// List mail or a noreply-style address: WHEN may be limited to its domain.
        var automated: Bool
        /// Your address, for the WHEN suggestion.
        var account: String
    }

    /// WHEN's hint while it is empty, for this account.
    var whenPlaceholder: String {
        RuleSuggestion.whenPlaceholder(account: seed?.account ?? app?.account.email ?? "", asksClaude: draft.asksClaude)
    }

    /// Free counts over the last 90 days: how much of the mail in scope passes WHEN.
    struct FreeCount: Equatable {
        var passing: Int
        var inScope: Int
    }

    /// A test runs by itself below this; above it, it asks first.
    static let askAboveMicros: Int64 = 50_000
    /// `⌃r` tests at most this many rows at issue.
    static let atIssueLimit = 12
    static let countDays = 90

    var draft: Rule {
        didSet { draftChanged(from: oldValue) }
    }
    /// THEN: an existing label's name, or the name of a new local label made when the rule is saved.
    var labelName: String {
        didSet { if labelName != oldValue { labelChanged() } }
    }
    var field: Field {
        didSet { if field != oldValue { fieldChanged() } }
    }
    /// The rule as stored, or nil until a new rule is saved.
    private(set) var saved: RuleRecord?
    private(set) var rows: [PreviewRow] = []
    var highlighted = 0
    private(set) var whenProblem: String?
    private(set) var freeCount: FreeCount?
    private(set) var costs: (atIssue: PreviewCost, all: PreviewCost)?
    private(set) var spend: SpendGuard.Snapshot?
    private(set) var examples: [RuleExample] = []
    private(set) var loadingPreview = false
    private(set) var testing = false
    private(set) var drafting = false
    /// Why something could not be done: a stopped test, a failed save.
    var notice: String?
    /// Rows whose verdict flipped in the last test, highlighted for a moment.
    private(set) var flashed: Set<String> = []
    private(set) var sampleExtra = 0
    /// `o`: the highlighted message, read in place.
    private(set) var peek: MailMessage?
    var prompt: Prompt?
    var labelHighlighted = 0
    /// WHEN is limited to the seed's sender (`from:@domain`).
    private(set) var onlySender = false
    let seed: Seed?
    /// Esc leaves to the rules manager rather than the mailbox.
    let returnsToManager: Bool
    private(set) var saving = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let services: AppServices
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// Pricing a test before it runs.
    @ObservationIgnored private var priceTask: Task<Void, Never>?
    @ObservationIgnored private var figuresTask: Task<Void, Never>?
    @ObservationIgnored private var draftTask: Task<Void, Never>?

    init(draft: Rule, labelName: String, saved: RuleRecord?, seed: Seed?, returnsToManager: Bool, field: Field, app: AppModel) {
        self.draft = draft
        self.labelName = labelName
        self.saved = saved
        self.seed = seed
        self.returnsToManager = returnsToManager
        self.field = field
        self.app = app
        services = app.services
        self.draft.then = [.addLabel(targetRef)]
    }

    var isNew: Bool { saved == nil }

    /// The fields Tab moves through.
    var fields: [Field] {
        Field.allCases.filter { $0 != .onlySender || seed?.automated == true }
    }

    var title: String {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if isNew { return name.isEmpty ? "New rule" : "New rule · \(name)" }
        return "Rule · \(name.isEmpty ? labelName : name)"
    }

    // MARK: - Starting and closing

    /// The first preview, and what was marked for the rule.
    func start() {
        schedulePreview(delay: false)
    }

    /// Drafts the ASK, and a name, label and WHEN, with Claude (design §4.5). Needs the key and consent;
    /// without them nothing is sent. Fields you changed meanwhile are kept.
    /// - Parameters:
    ///   - description: your sentence, or for `T` a stand-in for one.
    ///   - seed: the email `T` was pressed on.
    ///   - keepsLabel: THEN was chosen (the conversation's label, or the label picker's): it and the
    ///     name stay.
    func startDrafting(description: String, seed: EmailDigest?, keepsLabel: Bool = false) {
        guard let app, let drafter = app.ai.drafter(forAccount: services.accountKey) else { return }
        let before = (name: draft.name, label: labelName, ask: draft.ask, when: draft.when)
        let labelNames = app.userLabels.map(\.name)
        drafting = true
        draftTask = Task {
            defer { drafting = false }
            let result: RuleDraft
            do throws(JudgeError) {
                result = try await drafter.draft(description, seed: seed, labelNames: labelNames)
            } catch {
                guard !Task.isCancelled else { return }
                AppModel.log.error("Drafting a rule failed: \(String(describing: error))")
                notice = Self.draftingFailed(error)
                return
            }
            guard !Task.isCancelled else { return }
            if draft.ask == before.ask, !result.ask.isEmpty {
                draft.ask = result.ask
                draft.askDrafted = result.askDrafted
            }
            if draft.name == before.name, !keepsLabel, !result.name.isEmpty { draft.name = result.name }
            if labelName == before.label, !keepsLabel, !result.label.isEmpty { labelName = result.label }
            // `T` keeps its own WHEN suggestion; a sentence takes Claude's.
            if self.seed == nil, draft.when == before.when, let when = result.when { draft.when = when }
        }
    }

    static func draftingFailed(_ error: JudgeError) -> String {
        switch error {
        case .budget: "Not drafted: today's preview allowance is spent. Describe the mail yourself under ASK."
        case .paused(let reason): "Not drafted: \(RuleEditorText.pauseText(reason)). Describe the mail yourself under ASK."
        case .offline: "Not drafted: Anthropic could not be reached. Describe the mail yourself under ASK."
        default: "Claude could not draft the rule. Describe the mail yourself under ASK."
        }
    }

    /// True when leaving would lose something: a new rule with anything in it, or unsaved changes.
    var isDirty: Bool {
        guard let saved else {
            let rule = draft
            return !rule.name.trimmingCharacters(in: .whitespaces).isEmpty || !rule.when.trimmingCharacters(in: .whitespaces).isEmpty
                || rule.asksClaude || !labelName.trimmingCharacters(in: .whitespaces).isEmpty || !examples.isEmpty
        }
        var current = draft
        var stored = saved.rule
        current.askDrafted = false
        stored.askDrafted = false
        return current != stored || labelName.trimmingCharacters(in: .whitespaces) != label(of: saved.rule)
    }

    /// Esc: closes a prompt or the peek, leaves a field for the preview, then leaves the editor,
    /// asking first when that would lose something.
    func escape() {
        if prompt != nil {
            prompt = nil
        } else if peek != nil {
            peek = nil
        } else if field != .preview {
            field = .preview
        } else if isDirty {
            prompt = .discard
        } else {
            close()
        }
    }

    /// A click outside the editor or on its close button: leaves, asking first when that would lose something.
    func leaveByClick() {
        field = .preview
        peek = nil
        if isDirty { prompt = .discard } else { close() }
    }

    /// Leaves the editor. A new rule that was never saved forgets its marks.
    func close() {
        abandon()
        guard let app else { return }
        app.ruleEditor = nil
        if returnsToManager { app.openRules() } else { app.overlay = nil }
    }

    /// Stops what the editor has running and, for a rule never saved, deletes its marks and sender rules.
    func abandon() {
        priceTask?.cancel()
        previewTask?.cancel()
        figuresTask?.cancel()
        draftTask?.cancel()
        guard isNew else { return }
        let store = services.store
        let id = draft.id
        Task { try? await store.discardDraft(ruleID: id) }
    }

    // MARK: - Fields

    private func fieldChanged() {
        guard let app else { return }
        if field != .then { labelHighlighted = 0 }
        app.focusTarget = field.focusTarget
        if !field.isText { app.blurTextInput() }
    }

    /// The view's text focus moved (a click into a field).
    func viewFocused(_ target: FocusTarget?) {
        guard let target, let field = Field(target) else { return }
        self.field = field
    }

    /// Tab and ⇧Tab.
    func moveField(_ delta: Int) {
        let fields = fields
        let index = fields.firstIndex(of: field) ?? 0
        field = fields[(index + delta + fields.count) % fields.count]
    }

    /// The ASK as typed. Typing clears the "drafted from an email" tag.
    var askText: String {
        get { draft.ask ?? "" }
        set {
            guard newValue != (draft.ask ?? "") else { return }
            draft.ask = newValue.isEmpty ? nil : newValue
            draft.askDrafted = false
        }
    }

    /// Space or ↵ on a switch.
    func toggle(_ field: Field) {
        switch field {
        case .onlySender: setOnlySender(!onlySender)
        case .scope: draft.scope.mailboxes = draft.scope.mailboxes == .inbox ? .received : .inbox
        case .replies: draft.scope.inheritInThread.toggle()
        case .stop: draft.stopAfterMatch.toggle()
        case .broad: draft.acknowledgedBroad.toggle()
        case .edits: draft.editsTeach.toggle()
        default: break
        }
    }

    /// Limits WHEN to the seed's sender, or goes back to the suggestion without it. A WHEN you
    /// typed yourself is left alone.
    func setOnlySender(_ on: Bool) {
        guard let seed, seed.automated else { return }
        let current = RuleSuggestion.when(account: seed.account, sender: seed.sender, onlySender: onlySender)
        onlySender = on
        guard draft.when.trimmingCharacters(in: .whitespaces) == current else { return }
        draft.when = RuleSuggestion.when(account: seed.account, sender: seed.sender, onlySender: on)
    }

    private func draftChanged(from old: Rule) {
        guard draft != old else { return }
        if draft.when != old.when || draft.ask != old.ask || draft.scope != old.scope || draft.then != old.then {
            // An ASK edit cancels tests in flight; going back to an earlier wording is free (cached).
            schedulePreview()
        }
    }

    // MARK: - THEN

    /// The label a name picks, as saving resolves it: Gmail's before a local one.
    private var resolvedLabel: MailLabel? {
        let name = labelName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, let app else { return nil }
        let named = app.userLabels.filter { $0.name.lowercased() == name }
        return named.first { $0.kind == .user } ?? named.first
    }

    /// The label THEN shows: the saved rule's while THEN names it, else the one saving would pick.
    var targetLabel: MailLabel? {
        if let keptTarget, let live = app?.labels.first(where: { $0.id == keptTarget.id }) { return live }
        return resolvedLabel
    }

    /// Existing labels that match what is typed, for picking with ↑ ↓ and ↵.
    var labelSuggestions: [MailLabel] {
        guard let app else { return [] }
        let query = labelName.trimmingCharacters(in: .whitespaces).lowercased()
        let labels = query.isEmpty ? app.userLabels : app.userLabels.filter { FuzzyMatcher.score(query: query, in: $0.name.lowercased()) != nil }
        return Array(labels.prefix(6))
    }

    func moveLabelSuggestion(_ delta: Int) {
        let count = labelSuggestions.count
        guard count > 0 else { return }
        labelHighlighted = (min(labelHighlighted, count - 1) + delta + count) % count
    }

    /// ↵ in THEN: takes the highlighted suggestion.
    func pickLabelSuggestion() {
        let suggestions = labelSuggestions
        guard suggestions.indices.contains(labelHighlighted) else { return }
        labelName = suggestions[labelHighlighted].name
    }

    /// The label the draft adds. A saved rule keeps its reference while THEN names its label.
    private var targetRef: LabelRef {
        if let keptTarget { return keptTarget }
        let resolved = resolvedLabel
        return LabelRef(id: resolved?.id ?? "", lastKnownName: resolved?.name ?? labelName.trimmingCharacters(in: .whitespaces))
    }

    /// The saved rule's label while THEN still names it, also when another label shares its name.
    private var keptTarget: LabelRef? {
        guard let current = saved?.rule.labelTargets.first else { return nil }
        let name = labelName.trimmingCharacters(in: .whitespaces).lowercased()
        guard let live = app?.labels.first(where: { $0.id == current.id }) else {
            // A label saving just made may not be listed yet: its name still picks it.
            return resolvedLabel == nil && current.lastKnownName.lowercased() == name ? current : nil
        }
        return live.name.lowercased() == name ? current : nil
    }

    private func labelChanged() {
        labelHighlighted = 0
        draft.then = [.addLabel(targetRef)]
    }

    /// The live name of the label a stored rule adds.
    private func label(of rule: Rule) -> String {
        guard let target = rule.labelTargets.first else { return "" }
        return app?.labels.first { $0.id == target.id }?.name ?? target.lastKnownName
    }

    // MARK: - Preview

    var highlightedRow: PreviewRow? {
        rows.indices.contains(highlighted) ? rows[highlighted] : nil
    }

    func moveHighlight(_ delta: Int) {
        guard !rows.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), rows.count - 1)
        if peek != nil { openPeek() }
    }

    /// Previews the draft as it stands, WHEN only (free), after a short pause for typing.
    /// - Parameter keepOrder: rows already shown stay where they are (after a mark), new ones follow.
    func schedulePreview(delay: Bool = true, keepOrder: Bool = false) {
        previewTask?.cancel()
        testing = false
        let draft = draft
        let sample = PreviewSample(extra: sampleExtra)
        previewTask = Task {
            if delay {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            await loadPreview(draft, sample: sample, keepOrder: keepOrder)
        }
    }

    private func loadPreview(_ draft: Rule, sample: PreviewSample, keepOrder: Bool) async {
        whenProblem = Self.problem(with: draft.when)
        guard whenProblem == nil else { return }
        loadingPreview = true
        defer { loadingPreview = false }
        var incoming: [PreviewRow] = []
        do {
            for try await row in await services.rules.preview(draft, sample: sample, test: .none) {
                incoming.append(row)
            }
        } catch let problem as RuleFilter.Problem {
            whenProblem = problem.message
            return
        } catch {
            guard !Task.isCancelled else { return }
            AppModel.log.error("Rule preview failed: \(String(describing: type(of: error)))")
            return
        }
        guard !Task.isCancelled else { return }
        show(incoming, keepOrder: keepOrder)
        await refreshFigures(draft, sample: sample)
    }

    /// Why a WHEN can't be used, or nil.
    static func problem(with when: String) -> String? {
        do throws(RuleFilter.Problem) {
            _ = try RuleFilter.parse(when)
            return nil
        } catch {
            return error.message
        }
    }

    /// Shows a fresh sample, keeping the highlighted message under the cursor.
    private func show(_ incoming: [PreviewRow], keepOrder: Bool) {
        let current = highlightedRow?.messageID
        if keepOrder {
            let fresh = Dictionary(incoming.map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first })
            let known = Set(rows.map(\.messageID))
            rows = rows.compactMap { fresh[$0.messageID] } + incoming.filter { !known.contains($0.messageID) }
        } else {
            rows = incoming
        }
        highlighted = current.flatMap { id in rows.firstIndex { $0.messageID == id } } ?? min(highlighted, max(0, rows.count - 1))
    }

    /// What testing would cost, the free WHEN counts, your marks, and preview spend.
    private func refreshFigures(_ draft: Rule, sample: PreviewSample) async {
        let rules = services.rules
        let store = services.store
        let scope = draft.scope.mailboxes
        let window = Date().addingTimeInterval(-Double(Self.countDays) * 86_400)...Date()
        do {
            let filter = try RuleFilter.parse(draft.when)
            let everything = try RuleFilter.parse("")
            async let atIssue = rules.previewCost(draft, sample: sample, test: .atIssue(limit: Self.atIssueLimit))
            async let all = rules.previewCost(draft, sample: sample, test: .all)
            async let passing = store.ruleMatchCount(filter, scope: scope, window: window)
            async let inScope = store.ruleMatchCount(everything, scope: scope, window: window)
            async let examples = store.examples(ruleID: draft.id)
            let figures = try await (atIssue, all, passing, inScope, examples)
            guard !Task.isCancelled else { return }
            costs = (figures.0, figures.1)
            freeCount = FreeCount(passing: figures.2, inScope: figures.3)
            self.examples = figures.4
        } catch {
            guard !Task.isCancelled else { return }
            AppModel.log.error("Could not price the rule preview: \(String(describing: type(of: error)))")
        }
        if let app { spend = await app.ai.spend.snapshot() }
    }

    /// Marks, sender rules or spend changed outside a preview: their figures again.
    private func refreshFiguresSoon() {
        figuresTask?.cancel()
        let draft = draft
        let sample = PreviewSample(extra: sampleExtra)
        figuresTask = Task { await refreshFigures(draft, sample: sample) }
    }

    /// "Too broad?": the rule would label more than half the mail in scope.
    var isTooBroad: Bool {
        guard let freeCount, let breadth = RuleEditorText.breadth(passing: freeCount.passing, inScope: freeCount.inScope, rows: rows, asksClaude: draft.asksClaude)
        else { return false }
        return breadth > RuleEditorText.broadShare
    }

    /// `+`: 20 more of the newest messages passing WHEN.
    func showMore() {
        sampleExtra += 1
        schedulePreview(delay: false, keepOrder: true)
    }

    /// `y`, `n`: your ✔ or ✖ for the highlighted message. It decides that message for the rule and
    /// joins Claude's examples at the next test. The cursor moves on.
    func mark(_ matches: Bool) {
        guard let row = highlightedRow else { return }
        let store = services.store
        let ruleID = draft.id
        let unsaved = isNew
        if let index = rows.firstIndex(where: { $0.messageID == row.messageID }) {
            rows[index].markedByYou = true
            rows[index].disagrees = false
            rows[index].judgedBeforeNewestMarks = false
            if rows[index].outcome != .filteredOut {
                rows[index].outcome = matches ? .match : .noMatch
                rows[index].source = .example
                rows[index].reason = nil
            }
        }
        if row.outcome == .filteredOut { app?.showToast("Marked. WHEN keeps this message out, so the mark only teaches Claude.") }
        moveHighlight(1)
        Task {
            do {
                try await store.setExample(ruleID: ruleID, messageID: row.messageID, matches: matches, origin: .preview, draft: unsaved)
                refreshFiguresSoon()
            } catch {
                app?.showToast("Could not save the mark: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// `u`: forgets your mark on the highlighted message.
    func clearMark() {
        guard let row = highlightedRow, examples.contains(where: { $0.messageID == row.messageID }) || row.source == .example else { return }
        let store = services.store
        let ruleID = draft.id
        Task {
            do {
                try await store.removeExample(ruleID: ruleID, messageID: row.messageID)
                if !testing { schedulePreview(delay: false, keepOrder: true) } else { refreshFiguresSoon() }
            } catch {
                app?.showToast("Could not clear the mark: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// `s`: a sender rule for the highlighted message's sender. Cycles: always matches, never
    /// matches, decided as before.
    func cycleSender() {
        guard let row = highlightedRow, let app else { return }
        let sender = row.sender.normalized
        guard !sender.isEmpty else { return }
        let ruleID = draft.id
        let unsaved = isNew
        Task {
            do {
                try await app.cycleSenderRule(ruleID: ruleID, sender: sender, ruleName: nil, draft: unsaved)
                if !testing { schedulePreview(delay: false, keepOrder: true) } else { refreshFiguresSoon() }
            } catch {
                app.showToast("Could not change the sender rule: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// `o`: reads the highlighted message in place; `o` or Esc again closes it.
    func togglePeek() {
        if peek != nil { peek = nil } else { openPeek() }
    }

    private func openPeek() {
        guard let row = highlightedRow else { return }
        let store = services.store
        Task {
            guard let message = try? await store.message(id: row.messageID), highlightedRow?.messageID == row.messageID else { return }
            peek = message
        }
    }

    /// `L`: the main list shows every conversation with a message passing WHEN. Esc or `gr` there
    /// comes back here.
    func listMatches() {
        guard whenProblem == nil, let filter = try? RuleFilter.parse(draft.when), let app else { return }
        let store = services.store
        let scope = draft.scope.mailboxes
        let name = draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? labelName : draft.name
        Task {
            do {
                let threads = try await store.ruleMatchThreads(filter, scope: scope)
                app.showRuleMatches(RuleMatches(title: name.isEmpty ? "Rule" : name, threadIDs: threads))
            } catch {
                app.showToast("Could not list the matches: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Testing with Claude

    /// `⌃r` (rows at issue) and `⌃R` (every row you have not decided): asks for consent first, then
    /// shows the price and runs by itself only below 5¢.
    func test(_ test: PreviewTest, confirmed: Bool = false) {
        // One test at a time: another press (or the key repeating) would cancel the calls in flight,
        // which may be billed, and send the same rows again.
        guard !testing, priceTask == nil else { return }
        prompt = nil
        guard draft.asksClaude else {
            notice = "Filter rules need no test: the preview already shows exactly what they match."
            return
        }
        guard whenProblem == nil, let app else { return }
        app.requireClaudeConsent { [weak self] in self?.priceTest(test, confirmed: confirmed) }
    }

    private func priceTest(_ test: PreviewTest, confirmed: Bool) {
        var tested = draft
        let sample = PreviewSample(extra: sampleExtra)
        let rules = services.rules
        let store = services.store
        priceTask = Task {
            defer { priceTask = nil }
            do {
                // Your marks as they are now, also one made a moment ago.
                let marks = try await store.examples(ruleID: tested.id).map(\.messageID)
                tested.promptExampleIDs = marks
                let cost = try await rules.previewCost(tested, sample: sample, test: test)
                guard cost.calls > 0 else {
                    notice = "Nothing to test: your marks, sender rules and Claude's verdicts decide every row."
                    return
                }
                if !confirmed, cost.micros >= Self.askAboveMicros {
                    prompt = .test(test, cost)
                    return
                }
                guard !Task.isCancelled else { return }
                runTest(test, marks: marks, sample: sample)
            } catch {
                notice = "Could not price the test: \(error.localizedDescription)"
            }
        }
    }

    /// Snapshots your marks as the example set the test uses, sends the rows, and flashes those
    /// whose verdict flipped.
    private func runTest(_ test: PreviewTest, marks: [String], sample: PreviewSample) {
        // Not a semantic change: no new WHEN preview.
        draft.promptExampleIDs = marks
        let draft = draft
        previewTask?.cancel()
        testing = true
        notice = nil
        let before = Dictionary(rows.map { ($0.messageID, $0.outcome) }, uniquingKeysWith: { first, _ in first })
        previewTask = Task {
            do {
                for try await row in await services.rules.preview(draft, sample: sample, test: test) {
                    guard !Task.isCancelled else { return }
                    if let index = rows.firstIndex(where: { $0.messageID == row.messageID }) {
                        // A mark you made while the test ran decides the row, whatever Claude says.
                        if rows[index].markedByYou, !row.markedByYou { continue }
                        rows[index] = row
                    } else {
                        rows.append(row)
                    }
                    if !row.testing, row.source == .claude, let old = before[row.messageID], old.isVerdict, old != row.outcome {
                        flash(row.messageID)
                    }
                }
            } catch let error as PreviewError {
                notice = RuleEditorText.stopped(error)
            } catch {
                guard !Task.isCancelled else { return }
                AppModel.log.error("Rule test failed: \(String(describing: type(of: error)))")
                notice = "The test stopped: \(error.localizedDescription)"
            }
            guard !Task.isCancelled else { return }
            testing = false
            await refreshFigures(draft, sample: sample)
        }
    }

    private func flash(_ messageID: String) {
        flashed.insert(messageID)
        Task {
            try? await Task.sleep(for: .milliseconds(1_600))
            flashed.remove(messageID)
        }
    }

    // MARK: - Saving

    /// ⌘↵. With marks the last test did not use it asks first; `asTested` saves anyway, keeping the
    /// tested example set, so the preview's verdicts carry over to runs. A Claude rule asks for
    /// consent first; `consented` is the save that follows it.
    func save(asTested: Bool = false, consented: Bool = false) {
        guard !saving, let app else { return }
        prompt = nil
        let label = labelName.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else {
            notice = "Choose a label under THEN."
            field = .then
            return
        }
        // WHEN as typed: the preview checks it only after a pause.
        if let problem = Self.problem(with: draft.when) {
            whenProblem = problem
            notice = "Fix WHEN first: \(problem)"
            field = .when
            return
        }
        // With neither a filter nor a question, the rule would label every message you receive.
        if draft.when.trimmingCharacters(in: .whitespaces).isEmpty, !draft.asksClaude {
            notice = "Describe which emails match under ASK, or filter them under WHEN: this rule would label all your mail."
            field = .ask
            return
        }
        if draft.asksClaude, !asTested, RuleEditorText.untested(examples, tested: draft.promptExampleIDs) > 0 {
            prompt = .saveUntested(marks: RuleEditorText.untested(examples, tested: draft.promptExampleIDs))
            return
        }
        if draft.asksClaude, !consented {
            app.requireClaudeConsent { [weak self] in self?.save(asTested: asTested, consented: true) }
            return
        }
        saving = true
        let services = services
        // The saved rule's label, unless THEN names another; else the label the name picks, or a new local one.
        let kept = keptTarget.flatMap { ref in app.labels.first { $0.id == ref.id }.map { (ref: ref, name: $0.name) } }
        Task {
            defer { saving = false }
            do {
                var rule = draft
                let target: (ref: LabelRef, name: String)
                if let kept {
                    target = kept
                } else {
                    let resolved = try await services.store.resolveLabel(name: label)
                    target = (LabelRef(id: resolved.id, lastKnownName: resolved.name), resolved.name)
                }
                let name = rule.name.trimmingCharacters(in: .whitespaces)
                rule.name = name.isEmpty ? target.name : name
                rule.when = rule.when.trimmingCharacters(in: .whitespaces)
                let ask = rule.ask?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                rule.ask = ask.isEmpty ? nil : ask
                rule.askDrafted = false
                rule.then = [.addLabel(target.ref)]
                if let saved {
                    // On or off is the manager's and the breaker's: it stays as it is now, not as when editing began.
                    if let current = try await services.store.rules().first(where: { $0.id == saved.id }) { rule.enabled = current.rule.enabled }
                    let stored = try await services.store.saveRule(rule)
                    let revised = stored.revision != saved.rule.revision
                    try await services.rules.rulesChanged(revised ? .revised(ruleID: stored.id, revision: stored.revision) : .updated(ruleID: stored.id))
                    guard let record = try await services.store.rules().first(where: { $0.id == stored.id }) else { return }
                    adopt(record)
                    if revised, record.rule.enabled {
                        app.openBackfill(for: record.rule, mode: .recheck, editor: self, returnsToManager: returnsToManager)
                    } else {
                        close()
                        app.showToast(record.rule.enabled ? "Rule \(record.rule.name) saved." : "Rule \(record.rule.name) saved. It is off: x in the rules manager turns it on.")
                    }
                } else {
                    let record = try await services.store.createRule(rule)
                    try await services.rules.rulesChanged(.created(ruleID: record.id))
                    adopt(record)
                    app.openBackfill(for: record.rule, mode: .backfill, editor: self, returnsToManager: returnsToManager)
                }
            } catch let problem as RuleFilter.Problem {
                whenProblem = problem.message
                notice = "Fix WHEN first: \(problem.message)"
                field = .when
            } catch {
                AppModel.log.error("Could not save rule \(draft.id): \(String(describing: type(of: error)))")
                notice = "Could not save the rule: \(error.localizedDescription)"
            }
        }
    }

    /// The rule as stored becomes what the editor edits.
    private func adopt(_ record: RuleRecord) {
        saved = record
        draft = record.rule
        labelName = label(of: record.rule)
    }
}

/// The main list showing every conversation a rule's WHEN matches (`L` in the rule editor).
struct RuleMatches: Equatable {
    var title: String
    var threadIDs: [String]
    /// Listed from the calendar view, which has no conversation list: leaving goes back to the calendar.
    var fromCalendar = false
}
