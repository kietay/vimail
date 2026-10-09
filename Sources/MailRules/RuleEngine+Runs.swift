import Foundation
import MailCore
import MailStore

/// Which stored mail a run of one rule covers.
public struct RunPlan: Sendable, Hashable {
    public enum Window: Sendable, Hashable {
        /// Back to the `n`th newest message that needs Claude ("Newest 100 for Claude").
        case newestNeedingClaude(Int)
        /// Mail from the last `n` days.
        case lastDays(Int)
        /// All stored mail.
        case allCached
        /// Mail dated in the interval, such as the time a rule was off.
        case dates(DateInterval)
        /// The messages where the rule still owns a label: a re-check of what it added.
        case labeled
    }

    public var ruleID: String
    /// `.backfill`; `.recheck`, which counts what would change and applies once you confirm; or `.gap`.
    public var kind: RunKind
    public var window: Window

    public init(ruleID: String, kind: RunKind = .backfill, window: Window) {
        self.ruleID = ruleID
        self.kind = kind
        self.window = window
    }
}

/// What a run would do and cost. The prices on the "how far back" sheet come only from here.
public struct RunEstimate: Sendable, Hashable {
    /// nil for `=` and for runs already made.
    public var plan: RunPlan?
    /// The store's exact counts, for a window of dates.
    public var counts: RuleEstimate?
    /// The dates covered; nil for all stored mail or a list of messages.
    public var window: ClosedRange<Date>?
    /// Messages the run goes through.
    public var messages: Int
    /// Of those, the ones that need a Claude call.
    public var needClaude: Int
    /// One call: the mean of the model's recent calls here, or the local estimate from its prices.
    public var perCallMicros: Int64
    public var fromHistory: Bool
    public var micros: Int64
    /// The run pauses when its cost reaches this: 1.5× the estimate.
    public var capMicros: Int64
    /// Within what runs may still spend today. True when the app reports no spend figures.
    public var fitsToday: Bool
}

/// `=` on a selection.
public struct ManualRun: Sendable, Hashable {
    /// nil when it would cost more than 5¢ and was not confirmed: ask, then call again confirmed.
    public var runID: Int64?
    public var estimate: RunEstimate
}

/// What `undo` reverts.
public enum UndoTarget: Sendable, Hashable {
    /// Every label the run added that is still its own.
    case run(Int64)
    /// These ledger rows, from "why these labels?".
    case ledger([Int64])
}

/// Runs over stored mail: estimates, starting, confirming, resuming, cancelling and undoing them.
extension RuleEngine {
    /// A run pauses at this multiple of its estimate.
    static let capFactor = 1.5
    /// `=` asks before spending more than 5¢.
    static let manualAskMicros: Int64 = 50_000
    /// The default backfill for a Claude rule is the last 14 days when that costs at most $1.
    static let defaultBackfillDays = 14
    static let defaultBackfillMicros: Int64 = 1_000_000
    static let defaultNewest = 100

    /// Before a model made any call here, one call is priced from its list prices:
    /// - the email, uncached: `typicalEmailCharacters` (about half the 4,000-character body limit,
    ///   plus headers and the previous message's start) at about 4 characters a token;
    /// - the cached prefix read back (instructions, rules, examples): `cachedPrefixTokens`;
    /// - the answer, a short reason and a verdict per rule: `answerTokens`.
    /// Once there are calls, the mean of the model's last 50 replaces it.
    static let typicalEmailCharacters = 2_400
    static let cachedPrefixTokens = 1_000
    static let answerTokens = 120

    static func localCallMicros(_ prices: TokenPrices) -> Int64 {
        let email = Double(typicalEmailCharacters) / 4 * prices.input
        let prefix = Double(cachedPrefixTokens) * prices.cacheRead
        let answer = Double(answerTokens) * prices.output
        return Int64((email + prefix + answer).rounded(.up))
    }

    /// What Claude would cost for live mail over `days` if it judged all of `messagesPerDay`, a call
    /// priced as before any call was made. Consent and Settings show it per model ("≈ $0.23/mo"); the
    /// spend guard reserves the daily figure for live mail until there is real live spend.
    public static func projectedLiveMicros(messagesPerDay: Double, days: Double = 1, prices: TokenPrices) -> Int64 {
        guard messagesPerDay.isFinite, messagesPerDay > 0, days > 0 else { return 0 }
        return Int64((messagesPerDay * days * Double(localCallMicros(prices))).rounded(.up))
    }

    /// One call's price, and whether it comes from this model's recent calls.
    func callPrice() async throws -> (micros: Int64, fromHistory: Bool) {
        if let mean = try await store.meanCallCostMicros(model: config.model) { return (mean, true) }
        return (Self.localCallMicros(config.prices), false)
    }

    // MARK: - Estimates

    /// Prices a run of one rule. Counts are exact: messages in scope passing WHEN, minus those your
    /// marks, examples, sender overrides, cached verdicts or earlier passes decide, times one call.
    public func estimate(_ plan: RunPlan) async throws -> RunEstimate {
        let rule = try await rule(plan.ruleID)
        let price = try await callPrice()
        if case .labeled = plan.window {
            let messages = limited(try await store.messagesLabeled(byRule: rule.id))
            let calls = try await claudeCalls(rules: [rule], messageIDs: messages)
            return await priced(plan: plan, counts: nil, window: nil, messages: messages.count, needClaude: calls, price: price, asks: rule.asksClaude)
        }
        let counts = try await store.estimate(rule, window: estimateWindow(plan.window), judgeHash: judgeHash(rule))
        let messages = runMessageLimit.map { min($0, counts.passing) } ?? counts.passing
        let calls = rule.asksClaude ? min(counts.needClaude, messages) : 0
        return await priced(plan: plan, counts: counts, window: counts.window, messages: messages, needClaude: calls, price: price, asks: rule.asksClaude)
    }

    /// The run the "how far back" sheet preselects after you save a rule (USER DECISIONS #5), or nil
    /// for "New mail only". A rule without an ASK: all stored mail, free. A Claude rule: the last 14
    /// days when that costs at most $1 and fits what runs may spend today; else the newest 100
    /// needing Claude when that fits; else nothing.
    public func defaultChoice(ruleID: String) async throws -> RunEstimate? {
        let rule = try await rule(ruleID)
        guard rule.asksClaude else { return try await estimate(RunPlan(ruleID: ruleID, window: .allCached)) }
        let recent = try await estimate(RunPlan(ruleID: ruleID, window: .lastDays(Self.defaultBackfillDays)))
        if recent.micros <= Self.defaultBackfillMicros && recent.fitsToday { return recent }
        let newest = try await estimate(RunPlan(ruleID: ruleID, window: .newestNeedingClaude(Self.defaultNewest)))
        return newest.fitsToday ? newest : nil
    }

    func estimateWindow(_ window: RunPlan.Window) -> EstimateWindow {
        switch window {
        case .newestNeedingClaude(let count): .newestNeedingClaude(count)
        case .lastDays(let days): .dates(clock.now.addingTimeInterval(-Double(days) * 86_400)...Date.distantFuture)
        case .allCached, .labeled: .allCached
        case .dates(let interval): .dates(interval.start...interval.end)
        }
    }

    func priced(
        plan: RunPlan?, counts: RuleEstimate?, window: ClosedRange<Date>?, messages: Int, needClaude: Int,
        price: (micros: Int64, fromHistory: Bool), asks: Bool
    ) async -> RunEstimate {
        let micros = Int64(needClaude) * price.micros
        var cap = Int64((Double(micros) * Self.capFactor).rounded(.up))
        // A Claude rule may always make one call: verdicts the estimate counted on can be gone.
        if asks { cap = max(cap, price.micros) }
        let room = await spend?()?.runRoomToday
        return RunEstimate(
            plan: plan, counts: counts, window: window, messages: messages, needClaude: needClaude, perCallMicros: price.micros,
            fromHistory: price.fromHistory, micros: micros, capMicros: cap, fitsToday: room.map { micros <= $0 } ?? true
        )
    }

    /// How many of these messages would need a Claude call for `rules`: the pass's pre-pass, without asking.
    func claudeCalls(rules: [Rule], messageIDs: [String]) async throws -> Int {
        guard rules.contains(where: \.asksClaude), !messageIDs.isEmpty else { return 0 }
        let labels = try await store.labels()
        var candidates = try await store.messageFacts(messageIDs).map { Candidate(facts: $0, rules: rules) }
        try await cascade(&candidates, labels: labels)
        return candidates.filter { !$0.plan.needsVerdict.isEmpty }.count
    }

    /// Prices what a run has left with its rules at their current revisions and the current model,
    /// as `confirmRun` and `resumeRun` would go on: for a backlog or gap run that waits for your
    /// confirmation, or one paused because its rules or the model changed ("continue with v4 · ≈ $x").
    public func estimate(runID: Int64) async throws -> RunEstimate {
        guard let run = try await store.run(id: runID) else { throw RuleEngineError.runNotFound }
        return try await remaining(run).estimate
    }

    /// What a run has left, priced with its rules at their current revisions and the current model.
    func remaining(_ run: RunRecord) async throws -> (rules: [Rule], estimate: RunEstimate) {
        try await loadIfNeeded()
        let ids = Set(run.rules.map(\.id))
        let rules = enabledRules.filter { ids.contains($0.id) }
        let messages = try await store.runMessageIDs(run.id)
        let calls = try await claudeCalls(rules: rules, messageIDs: messages)
        let estimate = await priced(
            plan: nil, counts: nil, window: run.window, messages: messages.count, needClaude: calls, price: try await callPrice(),
            asks: rules.contains(where: \.asksClaude)
        )
        return (rules, estimate)
    }

    func rule(_ id: String) async throws -> Rule {
        try await loadIfNeeded()
        if let record = records.first(where: { $0.id == id }) { return record.rule }
        try await reloadRules()
        guard let record = records.first(where: { $0.id == id }) else { throw RuleEngineError.ruleNotFound }
        return record.rule
    }

    func limited(_ messageIDs: [String]) -> [String] {
        runMessageLimit.map { Array(messageIDs.prefix($0)) } ?? messageIDs
    }

    /// The messages a run covers, newest first: in the rule's scope and passing its WHEN in the
    /// window (those already decided too: they cost nothing and get their labels), or the ones it
    /// labeled. A re-check over a window also takes what it labeled there, to find labels to remove.
    func runMessages(_ plan: RunPlan, rule: Rule, window: ClosedRange<Date>?) async throws -> [String] {
        if case .labeled = plan.window { return limited(try await store.messagesLabeled(byRule: rule.id)) }
        var ids = try await store.ruleMatches(try RuleFilter.parse(rule.when), scope: rule.scope.mailboxes, window: window)
        if plan.kind == .recheck {
            let passing = Set(ids)
            let labeled = try await store.messagesLabeled(byRule: rule.id).filter { !passing.contains($0) }
            ids += try await store.messageFacts(labeled)
                .filter { window?.contains($0.date) ?? true }
                .map(\.messageID)
        }
        return limited(ids)
    }

    // MARK: - Starting and steering runs

    /// Starts a run over stored mail and returns its ID. A re-check first counts what it would add
    /// and remove, then waits for `confirmRun`.
    /// - Parameter capMicros: where it pauses; 1.5× the estimate when nil.
    public func startRun(_ plan: RunPlan, capMicros: Int64? = nil) async throws -> Int64 {
        let cover = try await cover(plan)
        let id = try await createRun(plan, cover, capMicros: capMicros)
        Self.log.info("Run #\(id) (\(plan.kind.rawValue)) started: \(cover.messageIDs.count) message(s), \(cover.estimate.needClaude) for Claude")
        refreshStatus()
        wakeNow()
        return id
    }

    /// The mail that arrived while a rule was off, as a gap run that waits for your confirmation.
    func makeGapRun(ruleID: String, gap: DateInterval) async throws -> Int64? {
        let plan = RunPlan(ruleID: ruleID, kind: .gap, window: .dates(gap))
        let cover = try await cover(plan)
        guard !cover.messageIDs.isEmpty else { return nil }
        let id = try await createRun(plan, cover, capMicros: nil)
        Self.log.info("Rule \(ruleID) back on: gap run #\(id) holds \(cover.messageIDs.count) message(s) for confirmation")
        return id
    }

    /// A plan's rule, its estimate and the messages it covers, newest first.
    typealias Cover = (rule: Rule, estimate: RunEstimate, messageIDs: [String])

    private func cover(_ plan: RunPlan) async throws -> Cover {
        let rule = try await rule(plan.ruleID)
        let estimate = try await estimate(plan)
        return (rule, estimate, try await runMessages(plan, rule: rule, window: estimate.window))
    }

    /// Creates a run of one rule at its current revision, priced with the current model.
    /// - Parameter capMicros: where it pauses; 1.5× the estimate when nil.
    private func createRun(_ plan: RunPlan, _ cover: Cover, capMicros: Int64?) async throws -> Int64 {
        try await writing {
            try await store.createRun(
                plan.kind, rules: [RunRule(cover.rule)], messageIDs: cover.messageIDs, window: cover.estimate.window,
                estimateMicros: cover.estimate.micros, capMicros: capMicros ?? cover.estimate.capMicros, model: config.model
            )
        }
    }

    /// Confirms a run that waits for it: a backlog, a gap or a counted re-check. With `reestimate`,
    /// and always for a run whose rules or model changed, it moves to the rules' current revisions
    /// and the current model with a new estimate and cap. A run without an estimate gets one.
    @discardableResult
    public func confirmRun(_ runID: Int64, reestimate: Bool = false) async throws -> Bool {
        guard let run = try await store.run(id: runID) else { throw RuleEngineError.runNotFound }
        let current = reestimate || run.pauseReason == .ruleChanged || run.pauseReason == .modelChanged
        let confirmed: Bool
        if current || run.estimateMicros == nil {
            let (rules, estimate) = try await remaining(run)
            confirmed = try await writing {
                try await store.confirmRun(
                    runID, rules: current ? rules.map(RunRule.init) : nil, estimateMicros: estimate.micros, capMicros: estimate.capMicros,
                    model: current || run.model == nil ? config.model : nil
                )
            }
        } else {
            confirmed = try await writing { try await store.confirmRun(runID) }
        }
        if confirmed { Self.log.info("Run #\(runID) confirmed") }
        refreshStatus()
        wakeNow()
        return confirmed
    }

    /// Continues a paused run. One paused because its rules or the model changed goes on with the
    /// current revisions and model ("continue with v4"), priced again. One paused at its cap needs a
    /// higher `capMicros`, or it pauses again at once.
    @discardableResult
    public func resumeRun(_ runID: Int64, capMicros: Int64? = nil) async throws -> Bool {
        guard let run = try await store.run(id: runID) else { throw RuleEngineError.runNotFound }
        let resumed: Bool
        if run.pauseReason == .ruleChanged || run.pauseReason == .modelChanged {
            let (rules, estimate) = try await remaining(run)
            resumed = try await writing {
                try await store.resumeRun(
                    runID, rules: rules.map(RunRule.init), estimateMicros: run.costMicros + estimate.micros,
                    capMicros: capMicros ?? run.costMicros + estimate.capMicros, model: config.model
                )
            }
        } else {
            resumed = try await writing { try await store.resumeRun(runID, capMicros: capMicros) }
        }
        if resumed { Self.log.info("Run #\(runID) resumed") }
        refreshStatus()
        wakeNow()
        return resumed
    }

    @discardableResult
    public func cancelRun(_ runID: Int64) async throws -> Bool {
        let cancelled = try await writing { try await store.cancelRun(runID) }
        if cancelled { Self.log.info("Run #\(runID) cancelled") }
        refreshStatus()
        return cancelled
    }

    /// `=`: every enabled rule on these messages now, ahead of other runs and behind live mail.
    /// Cached verdicts are reused. Above 5¢ nothing starts until you confirm: the result has no run
    /// ID; ask, then call again with `confirmed`.
    public func runRules(on messageIDs: [String], confirmed: Bool = false) async throws -> ManualRun {
        try await loadIfNeeded()
        let rules = enabledRules
        let calls = try await claudeCalls(rules: rules, messageIDs: messageIDs)
        let estimate = await priced(
            plan: nil, counts: nil, window: nil, messages: messageIDs.count, needClaude: calls, price: try await callPrice(),
            asks: rules.contains(where: \.asksClaude)
        )
        guard confirmed || estimate.micros <= Self.manualAskMicros else { return ManualRun(runID: nil, estimate: estimate) }
        let id = try await writing {
            try await store.createRun(
                .manual, rules: rules.map(RunRule.init), messageIDs: messageIDs, estimateMicros: estimate.micros, capMicros: estimate.capMicros,
                model: config.model
            )
        }
        Self.log.info("Run #\(id) (manual) started: \(messageIDs.count) message(s), \(calls) for Claude")
        refreshStatus()
        wakeNow()
        return ManualRun(runID: id, estimate: estimate)
    }

    // MARK: - Undo

    /// Undoes a run, or single labels from "why these labels?". Labels come off under the removal
    /// rule: one you or another rule added stays. Decisions stay, so live mail does not add them back.
    @discardableResult
    public func undo(_ target: UndoTarget) async throws -> RevertSummary {
        let summary = try await writing {
            switch target {
            case .run(let id): try await store.undoRun(id)
            case .ledger(let ids): try await store.revertLedger(.rows(ids), reason: .undo)
            }
        }
        Self.log.info("Rules undo: \(summary.rows) label(s) released, \(summary.labelsRemoved) removed")
        if summary.syncedChanges > 0 { outboxChanged() }
        refreshStatus()
        return summary
    }
}
