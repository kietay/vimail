import Foundation
import Testing
@testable import MailCore
@testable import MailRules
@testable import MailStore

/// Stored mail, never queued: what runs cover.
@discardableResult
func storeMail(_ harness: Harness, count: Int, subject: String = "Your receipt", from: EmailAddress = stripe, daysAgo: Double = 0) async throws -> [String] {
    let messages = (0..<count).map { mail("s\($0)", from: from, subject: "\(subject) \($0)", minutesAgo: daysAgo * 1_440 + Double($0)) }
    try await harness.store.upsertMessages(messages)
    return messages.map(\.id)
}

/// Makes the model's recent calls cost `micros` each, so estimates use that mean.
func setCallCost(_ harness: Harness, _ micros: Int64) async throws {
    try await harness.store.putVerdicts([], model: testConfig.model, costMicros: micros)
}

@Suite("Rule engine: runs over stored mail", .serialized)
struct RuleEngineRunTests {
    // MARK: - Estimates

    @Test func estimatesUseLocalPricesBeforeAnyCall() async throws {
        let harness = try await Harness(rules: [receiptsRule])
        try await storeMail(harness, count: 5)
        let estimate = try await harness.engine.estimate(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        // 2,400 characters / 4 × $0.10 + 1,000 cached × $0.01 + 120 out × $0.50 per million tokens.
        #expect(RuleEngine.localCallMicros(testConfig.prices) == 130)
        #expect(estimate.messages == 5 && estimate.needClaude == 5)
        #expect(estimate.perCallMicros == 130 && !estimate.fromHistory)
        #expect(estimate.micros == 650 && estimate.capMicros == 975)
        #expect(estimate.fitsToday)
    }

    @Test func estimatesUseTheModelsRecentCalls() async throws {
        let harness = try await Harness(rules: [receiptsRule, deploysRule])
        try await storeMail(harness, count: 4)
        try await setCallCost(harness, 2_000)
        let receipts = try await harness.engine.estimate(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        #expect(receipts.perCallMicros == 2_000 && receipts.fromHistory)
        #expect(receipts.micros == 8_000 && receipts.capMicros == 12_000)
        // A filter rule needs no call.
        let deploys = try await harness.engine.estimate(RunPlan(ruleID: harness.rule("Deploys").id, window: .allCached))
        #expect(deploys.needClaude == 0 && deploys.micros == 0)
    }

    @Test func liveProjection() {
        // 130 micro-dollars a call.
        #expect(RuleEngine.projectedLiveMicros(messagesPerDay: 60, days: 30, prices: testConfig.prices) == 234_000)
        #expect(RuleEngine.projectedLiveMicros(messagesPerDay: 60, prices: testConfig.prices) == 7_800)
        #expect(RuleEngine.projectedLiveMicros(messagesPerDay: 0, days: 30, prices: testConfig.prices) == 0)
    }

    @Test func estimatesSubtractWhatIsDecidedAlready() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let ids = try await storeMail(harness, count: 4)
        let rule = try await harness.rule("Receipts")
        try await harness.store.setExample(ruleID: rule.id, messageID: ids[0], matches: true, origin: .preview)
        _ = try await harness.engine.runRules(on: [ids[1]])
        await harness.engine.drain()
        let estimate = try await harness.engine.estimate(RunPlan(ruleID: rule.id, window: .allCached))
        #expect(estimate.needClaude == 2)
        #expect(estimate.counts?.decidedByYou == 1 && estimate.counts?.cachedVerdicts == 1)
    }

    @Test func defaultChoiceFollowsUserDecisions() async throws {
        // Filter-only rules: all stored mail, free.
        let filters = try await Harness(rules: [deploysRule])
        let all = try #require(try await filters.engine.defaultChoice(ruleID: filters.rule("Deploys").id))
        #expect(all.plan?.window == .allCached && all.micros == 0)

        // A Claude rule: the last 14 days when that costs at most $1 and fits today's room.
        let cheap = try await Harness(rules: [receiptsRule], spend: figures(runRoom: 2_000_000))
        try await storeMail(cheap, count: 3, daysAgo: 2)
        let recent = try #require(try await cheap.engine.defaultChoice(ruleID: cheap.rule("Receipts").id))
        #expect(recent.plan?.window == .lastDays(14) && recent.needClaude == 3)

        // Over $1: the newest 100 needing Claude, when they fit.
        let dear = try await Harness(rules: [receiptsRule], spend: figures(runRoom: 5_000_000))
        try await storeMail(dear, count: 3, daysAgo: 2)
        try await setCallCost(dear, 400_000)
        let newest = try #require(try await dear.engine.defaultChoice(ruleID: dear.rule("Receipts").id))
        #expect(newest.plan?.window == .newestNeedingClaude(100) && newest.micros == 1_200_000)

        // Nothing fits: new mail only.
        let broke = try await Harness(rules: [receiptsRule], spend: figures(runRoom: 1_000_000))
        try await storeMail(broke, count: 3, daysAgo: 2)
        try await setCallCost(broke, 400_000)
        #expect(try await broke.engine.defaultChoice(ruleID: broke.rule("Receipts").id) == nil)
    }

    func figures(runRoom: Int64) -> SpendFigures {
        SpendFigures(spendToday: 0, spendMonth: 0, budgetDay: 3_000_000, budgetMonth: 20_000_000, runRoomToday: runRoom, previewLeft: 750_000)
    }

    // MARK: - Running

    @Test func backfillLabelsStoredMail() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let ids = try await storeMail(harness, count: 3)
        try await harness.store.upsertMessages([mail("other", from: shop, subject: "Sale")])
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        await harness.engine.drain()
        #expect(judge.calls.count == 4)
        #expect(judge.calls.allSatisfy { $0.lane == .run(id) })
        for id in ids { #expect(try await harness.hasLabel(id, "receipts")) }
        #expect(try await !harness.hasLabel("other", "receipts"))
        let run = try #require(try await harness.store.run(id: id))
        #expect(run.state == .done && run.judged == 4 && run.labeled == 3 && run.costMicros == 4_000 && run.model == testConfig.model)
    }

    @Test func debugBuildsCapRunSize() async throws {
        let harness = try await Harness(rules: [deploysRule], runMessageLimit: 2)
        try await storeMail(harness, count: 5, subject: "deploy")
        let plan = RunPlan(ruleID: try await harness.rule("Deploys").id, window: .allCached)
        #expect(try await harness.engine.estimate(plan).messages == 2)
        let id = try await harness.engine.startRun(plan)
        #expect(try await harness.store.run(id: id)?.total == 2)
    }

    @Test func runStopsAtCap() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 12)
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached), capMicros: 2_500)
        await harness.engine.drain()
        var run = try #require(try await harness.store.run(id: id))
        #expect(run.state == .paused && run.pauseReason == .cap)
        #expect(run.judged >= 3 && run.judged < 12)
        #expect(await harness.engine.makeStatus().runs.first?.pauseReason == .cap)

        // A higher cap lets it finish.
        #expect(try await harness.engine.resumeRun(id, capMicros: 100_000))
        await harness.engine.drain()
        run = try #require(try await harness.store.run(id: id))
        #expect(run.state == .done && run.judged == 12)
    }

    @Test func liveReserveStopsBackfill() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.failLane("run", with: .budget(.runRoom))
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 3)
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        await harness.engine.drain()
        let run = try #require(try await harness.store.run(id: id))
        #expect(run.state == .paused && run.pauseReason == .budget)
        #expect(try harness.queue().filter { $0.kind == "backfill" }.allSatisfy { $0.state == "queued" && $0.attempts == 0 })
        #expect(await harness.engine.ai == .ready)

        // Live mail still goes through.
        try await harness.deliver(mail("live", from: stripe, subject: "Your receipt"))
        await harness.engine.drain()
        #expect(try await harness.hasLabel("live", "receipts"))
    }

    @Test func budgetPausedRunContinuesNextDay() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.failLane("run", with: .budget(.runRoom))
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 3)
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        await harness.engine.drain()
        #expect(try await harness.store.run(id: id)?.pauseReason == .budget)

        // The same day it stays paused.
        judge.failLane("run", with: nil)
        await harness.engine.drain()
        #expect(try await harness.store.run(id: id)?.pauseReason == .budget)

        // The room refills overnight: it continues.
        let calendar = Calendar.current
        let midnight = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: harness.clock.now)))
        harness.clock.advance(by: midnight.timeIntervalSince(harness.clock.now) + 1)
        await harness.engine.drain()
        let run = try #require(try await harness.store.run(id: id))
        #expect(run.state == .done && run.judged == 3)
        #expect(try await harness.hasLabel("s0", "receipts"))
    }

    @Test func pausedClaudePausesRunsAndResumesThem() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 2)
        await harness.engine.configure(judge: judge, aiPause: .noConsent, config: testConfig)
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        await harness.engine.drain()
        #expect(judge.calls.isEmpty)
        #expect(try await harness.store.run(id: id)?.pauseReason == .ai)

        await harness.engine.configure(judge: judge, aiPause: nil, config: testConfig)
        await harness.engine.drain()
        #expect(try await harness.store.run(id: id)?.state == .done)
        #expect(judge.calls.count == 2)
    }

    @Test func ruleEditPausesRun() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 3)
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        var rule = try await harness.rule("Receipts")
        rule.ask = "Invoices only"
        try await harness.store.saveRule(rule)
        try await harness.engine.rulesChanged(.revised(ruleID: rule.id, revision: 2))
        await harness.engine.drain()
        #expect(judge.calls.isEmpty)
        #expect(try await harness.store.run(id: id)?.pauseReason == .ruleChanged)

        // "Continue with v2": the current revision, priced again.
        #expect(try await harness.engine.resumeRun(id))
        let resumed = try #require(try await harness.store.run(id: id))
        #expect(resumed.rules == [RunRule(id: rule.id, revision: 2)] && resumed.state == .running && resumed.estimateMicros == 3 * 130)
        await harness.engine.drain()
        #expect(judge.calls.count == 3)
        #expect(judge.calls.allSatisfy { $0.catalog.first?.ask == "Invoices only" })
        #expect(try await harness.store.run(id: id)?.state == .done)
    }

    @Test func modelSwitchPausesRuns() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 2)
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        var opus = testConfig
        opus.model = "claude-opus-5-5"
        opus.prices = TokenPrices(input: 4, cacheRead: 0.2, output: 20)
        await harness.engine.configure(judge: judge, aiPause: nil, config: opus)
        await harness.engine.drain()
        #expect(judge.calls.isEmpty)
        #expect(try await harness.store.run(id: id)?.pauseReason == .modelChanged)

        #expect(try await harness.engine.resumeRun(id))
        let resumed = try #require(try await harness.store.run(id: id))
        #expect(resumed.model == "claude-opus-5-5" && resumed.estimateMicros == 2 * RuleEngine.localCallMicros(opus.prices))
        await harness.engine.drain()
        #expect(judge.calls.count == 2)
    }

    @Test func recheckCountsThenApplies() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let ids = try await storeMail(harness, count: 3)
        var rule = try await harness.rule("Receipts")
        _ = try await harness.engine.startRun(RunPlan(ruleID: rule.id, window: .allCached))
        await harness.engine.drain()
        for id in ids { #expect(try await harness.hasLabel(id, "receipts")) }

        rule.ask = "Receipts over $50"
        try await harness.store.saveRule(rule)
        try await harness.engine.rulesChanged(.revised(ruleID: rule.id, revision: 2))
        judge.set(.noMatch, for: ids[0], rule: "r1")
        let id = try await harness.engine.startRun(RunPlan(ruleID: rule.id, kind: .recheck, window: .labeled))
        await harness.engine.drain()
        var recheck = try #require(try await harness.store.run(id: id))
        #expect(recheck.state == .awaitingConfirm && recheck.plus == 0 && recheck.minus == 1)
        // Counting changed nothing.
        #expect(try await harness.hasLabel(ids[0], "receipts"))
        let calls = judge.calls.count

        #expect(try await harness.engine.confirmRun(id))
        await harness.engine.drain()
        recheck = try #require(try await harness.store.run(id: id))
        #expect(recheck.state == .done)
        #expect(judge.calls.count == calls)
        #expect(try await !harness.hasLabel(ids[0], "receipts"))
        #expect(try await harness.hasLabel(ids[1], "receipts"))
    }

    @Test func manualRunAsksAboveFiveCents() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let ids = try await storeMail(harness, count: 2)
        try await setCallCost(harness, 30_000)
        let asked = try await harness.engine.runRules(on: ids)
        #expect(asked.runID == nil && asked.estimate.micros == 60_000)
        #expect(try harness.queue().isEmpty)

        let started = try await harness.engine.runRules(on: ids, confirmed: true)
        let id = try #require(started.runID)
        #expect(try harness.queue().allSatisfy { $0.kind == "manual" })
        await harness.engine.drain()
        #expect(try await harness.store.run(id: id)?.state == .done)
    }

    @Test func appNapIsHeldWhileARunWorks() async throws {
        let judge = FakeJudge()
        judge.hold()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 2)
        await harness.engine.start()
        _ = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        try await eventually("App Nap held") { await harness.engine.keepsAwake }
        judge.release()
        try await eventually("App Nap released") { await !harness.engine.keepsAwake }
        await harness.engine.stop()
    }

    // MARK: - Undo

    @Test func undoKeepsManualLabels() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let ids = try await storeMail(harness, count: 2)
        let label = try await harness.labelID("receipts")
        // You label the first one yourself.
        let record = try #require(try await harness.actions.perform(.addLabel(label), threads: [ids[0]]))
        try await harness.engine.noteUserChange(.applied(LabelEdit(undoKey: "u1", labelID: label, added: true, messageIDs: [ids[0]])))
        #expect(record.threadIDs == [ids[0]])

        let run = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        await harness.engine.drain()
        let summary = try await harness.engine.undo(.run(run))
        #expect(summary.labelsRemoved == 1)
        #expect(try await harness.hasLabel(ids[0], "receipts"))
        #expect(try await !harness.hasLabel(ids[1], "receipts"))
        // Decisions stay, so live mail does not get the label back.
        #expect(try await harness.decision(ids[1], harness.rule("Receipts"))?.verdict == .match)
    }

    @Test func undoKeepsCoOwnedLabel() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule, RuleSpec(name: "Stripe", label: "receipts", when: "from:stripe.com")], judge: judge)
        let ids = try await storeMail(harness, count: 1)
        let first = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        await harness.engine.drain()
        _ = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Stripe").id, window: .allCached))
        await harness.engine.drain()

        try await harness.engine.undo(.run(first))
        #expect(try await harness.hasLabel(ids[0], "receipts"))
        let owners = try await harness.engine.explain(threadID: ids[0]).labels.first { $0.label.name == "receipts" }?.owners
        #expect(owners?.map(\.ruleName) == ["Stripe"])
    }

    @Test func undoOfSingleLabels() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let ids = try await storeMail(harness, count: 2)
        _ = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        await harness.engine.drain()
        let owner = try #require(try await harness.engine.explain(threadID: ids[0]).labels.first?.owners.first)
        #expect(owner.source == .claude && owner.reason == "fake: match")
        try await harness.engine.undo(.ledger([owner.ledgerID]))
        #expect(try await !harness.hasLabel(ids[0], "receipts"))
        #expect(try await harness.hasLabel(ids[1], "receipts"))
    }

    // MARK: - Waiting, gaps, upkeep

    @Test func staleWaitingBecomesBacklog() async throws {
        let harness = try await Harness(rules: [receiptsRule], judge: nil)
        try await harness.deliver(mail("old", subject: "Hello", minutesAgo: 4 * 1_440), mail("new", subject: "Hi"))
        await harness.engine.drain()
        #expect(try harness.queue().map(\.state) == ["waiting_ai", "waiting_ai"])

        harness.clock.advance(by: 3_601)
        await harness.engine.drain()
        let rows = try harness.queue()
        #expect(rows.first { $0.messageID == "old" }?.state == "held")
        #expect(rows.first { $0.messageID == "old" }?.kind == "backlog")
        #expect(rows.first { $0.messageID == "new" }?.state == "waiting_ai")
        let backlog = try #require(await harness.engine.makeStatus().runs.first { $0.kind == .backlog })
        #expect(backlog.state == .awaitingConfirm && backlog.total == 1)
    }

    @Test func runsArePricedBeforeTheyGoOn() async throws {
        let harness = try await Harness(rules: [receiptsRule], judge: nil)
        // A backlog: three messages that waited four days for Claude.
        try await harness.deliver((0..<3).map { mail("old\($0)", subject: "Hello \($0)", minutesAgo: 4 * 1_440 + Double($0)) })
        await harness.engine.drain()
        harness.clock.advance(by: 3_601)
        await harness.engine.drain()
        let backlog = try #require(await harness.engine.makeStatus().runs.first { $0.kind == .backlog })
        #expect(backlog.state == .awaitingConfirm && backlog.estimateMicros == nil)
        let held = try await harness.engine.estimate(runID: backlog.id)
        #expect(held.messages == 3 && held.needClaude == 3 && held.micros == 3 * 130)

        // A run whose rule changed: priced with the new revision before it continues.
        try await storeMail(harness, count: 2)
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        #expect(await harness.engine.makeStatus().runs.first { $0.id == id }?.estimateMicros == 5 * 130)
        var rule = try await harness.rule("Receipts")
        rule.ask = "Invoices only"
        try await harness.store.saveRule(rule)
        try await harness.engine.rulesChanged(.revised(ruleID: rule.id, revision: 2))
        #expect(try await harness.store.run(id: id)?.pauseReason == .ruleChanged)
        #expect(await harness.engine.makeStatus().runs.first { $0.id == id }?.estimateMicros == nil)
        let changed = try await harness.engine.estimate(runID: id)
        #expect(changed.messages == 5 && changed.needClaude == 5 && changed.micros == 5 * 130)
        #expect(try await harness.engine.resumeRun(id))
        #expect(await harness.engine.makeStatus().runs.first { $0.id == id }?.estimateMicros == 5 * 130)
        await #expect(throws: RuleEngineError.runNotFound) { try await harness.engine.estimate(runID: 999) }
    }

    @Test func modelSwitchMarksRunsOnceTheStoreWorks() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 2)
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        try harness.store.writeNow { db, _ in try db.run("ALTER TABLE rule_runs RENAME TO rule_runs_away") }
        var opus = testConfig
        opus.model = "claude-opus-5-5"
        await harness.engine.configure(judge: judge, aiPause: nil, config: opus)
        #expect(await harness.engine.runsOutOfDate)
        // The store works again: the next pass marks the runs before it claims anything.
        try harness.store.writeNow { db, _ in try db.run("ALTER TABLE rule_runs_away RENAME TO rule_runs") }
        await harness.engine.drain()
        #expect(await !harness.engine.runsOutOfDate)
        #expect(judge.calls.isEmpty)
        #expect(try await harness.store.run(id: id)?.pauseReason == .modelChanged)
    }

    @Test func reenableOffersGap() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule, deploysRule], judge: judge)
        let rule = try await harness.rule("Receipts")
        try await harness.store.setRuleEnabled(id: rule.id, false)
        try await harness.engine.rulesChanged(.disabled(ruleID: rule.id))
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt", minutesAgo: 0), mail("m2", subject: "deploy", minutesAgo: 0))
        await harness.engine.drain()
        #expect(judge.calls.isEmpty)

        let gap = try #require(try await harness.store.setRuleEnabled(id: rule.id, true))
        let id = try #require(try await harness.engine.rulesChanged(.enabled(ruleID: rule.id), gap: gap))
        let run = try #require(try await harness.store.run(id: id))
        #expect(run.kind == .gap && run.state == .awaitingConfirm && run.total == 2)
        #expect(run.estimateMicros == Int64(2 * 130))
        await harness.engine.drain()
        #expect(judge.calls.isEmpty)

        try await harness.engine.confirmRun(id)
        await harness.engine.drain()
        #expect(judge.calls.count == 2)
        #expect(try await harness.store.run(id: id)?.state == .done)
    }

    @Test func retentionKeepsHashesInUse() async throws {
        let harness = try await Harness(rules: [receiptsRule])
        await harness.engine.drain()
        let rule = try await harness.rule("Receipts")
        let hash = try #require(rule.judgeHash(model: testConfig.model, effort: testConfig.effort, promptVersion: testConfig.promptVersion))
        let stored = try #require(try await harness.store.meta("rules_judge_hashes"))
        #expect(stored.contains(hash))
    }

    // MARK: - Progress, examples, caps and coverage

    @Test func statusFollowsARunBatchByBatch() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 30)
        try await setCallCost(harness, 1_000)
        judge.hold(after: RuleEngine.batchSize)
        let latest = Latest<RuleEngineStatus>()
        let listener = Task { for await status in harness.engine.status { latest.set(status) } }
        // Upkeep done and published first: what is published next comes from the run.
        await harness.engine.drain()
        try await Task.sleep(for: .milliseconds(300))
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        try await eventually("the run in the status") { latest.value?.runs.first { $0.id == id }?.done == 0 }
        let draining = Task { await harness.engine.drain() }
        try await eventually("the second batch at work") { judge.waiting > 0 }
        // The first batch committed: the status bar and Activity show it while the run goes on.
        try await eventually("progress in the status") {
            latest.value?.runs.first { $0.id == id }.map { $0.done == RuleEngine.batchSize && $0.costMicros == 20_000 } ?? false
        }
        judge.release()
        await draining.value
        await harness.engine.stop()
        await listener.value
    }

    @Test func runsJudgeWithTheExamplesYouTested() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let ids = try await storeMail(harness, count: 4)
        // ⌃r with two marks, then ⌘↵: only the tested example set changed, so the revision stays.
        var rule = try await harness.rule("Receipts")
        try await harness.store.setExample(ruleID: rule.id, messageID: ids[0], matches: true, origin: .preview)
        try await harness.store.setExample(ruleID: rule.id, messageID: ids[1], matches: false, origin: .preview)
        rule.promptExampleIDs = [ids[0], ids[1]]
        #expect(try await harness.store.saveRule(rule).revision == 1)
        try await harness.engine.rulesChanged(.updated(ruleID: rule.id))

        let id = try await harness.engine.startRun(RunPlan(ruleID: rule.id, window: .allCached))
        await harness.engine.drain()
        // The marked two decide themselves; the others go to Claude with the examples you tested.
        #expect(judge.calls.count == 2)
        #expect(judge.calls.allSatisfy { $0.lane == .run(id) && $0.examples.count == 2 })
    }

    @Test func cancellingARunStopsItsBatch() async throws {
        let judge = FakeJudge()
        judge.hold()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 20)
        try await setCallCost(harness, 1_000)
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        let draining = Task { await harness.engine.drain() }
        try await eventually("calls in flight") { judge.waiting == RuleEngine.judgeConcurrency }
        #expect(try await harness.engine.cancelRun(id))
        judge.release()
        await draining.value
        // Only the calls already on their way were made.
        #expect(judge.calls.count == RuleEngine.judgeConcurrency)
        #expect(try await harness.store.run(id: id)?.state == .cancelled)
    }

    @Test func debugCapIsShownAndRunsGoOnWhereTheLastStopped() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge, runMessageLimit: 3)
        try await storeMail(harness, count: 7)
        let plan = RunPlan(ruleID: try await harness.rule("Receipts").id, window: .allCached)
        let first = try await harness.engine.estimate(plan)
        #expect(first.cappedAt == 3 && first.messages == 3 && first.needClaude == 3 && first.counts?.passing == 7)
        _ = try await harness.engine.startRun(plan)
        await harness.engine.drain()
        #expect(judge.calls.count == 3)

        // The next run takes three it has not decided, at the price it shows.
        let second = try await harness.engine.estimate(plan)
        #expect(second.cappedAt == 3 && second.needClaude == 3)
        _ = try await harness.engine.startRun(plan)
        await harness.engine.drain()
        #expect(judge.calls.count == 6 && Set(judge.calls.map(\.messageID)).count == 6)

        // The last one fits: nothing held back.
        let third = try await harness.engine.estimate(plan)
        #expect(third.cappedAt == nil && third.needClaude == 1)
        _ = try await harness.engine.startRun(plan)
        await harness.engine.drain()
        #expect(Set(judge.calls.map(\.messageID)).count == 7)
    }

    @Test func estimatesCountOnlyClaudesDecisionsAsEarlier() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let ids = try await storeMail(harness, count: 2)
        let rule = try await harness.rule("Receipts")
        try await harness.store.setOverride(ruleID: rule.id, subject: "@stripe.com", matches: true, origin: .user)
        _ = try await harness.engine.runRules(on: ids, confirmed: true)
        await harness.engine.drain()
        #expect(judge.calls.isEmpty)
        // The sender rule goes: those messages need Claude again, as the run will find.
        try await harness.store.removeOverride(ruleID: rule.id, subject: "@stripe.com")
        let estimate = try await harness.engine.estimate(RunPlan(ruleID: rule.id, window: .allCached))
        #expect(estimate.needClaude == 2 && estimate.counts?.decidedEarlier == 0)
        #expect(try await harness.engine.claudeCalls(rules: [rule], messageIDs: ids) == 2)
    }

    @Test func runsOverStoredMailMoveCoveredSinceBack() async throws {
        let harness = try await Harness(rules: [deploysRule])
        try await storeMail(harness, count: 3, subject: "deploy", daysAgo: 10)
        let rule = try await harness.rule("Deploys")
        func coveredSince() async throws -> Date? { try await harness.store.rules().first { $0.id == rule.id }?.coveredSince }
        let created = try #require(try await coveredSince())

        // `=` covers chosen messages, not a stretch of mail.
        _ = try await harness.engine.runRules(on: ["s0"], confirmed: true)
        await harness.engine.drain()
        #expect(try await coveredSince() == created)

        _ = try await harness.engine.startRun(RunPlan(ruleID: rule.id, window: .lastDays(30)))
        await harness.engine.drain()
        let covered = try #require(try await coveredSince())
        #expect(abs(covered.timeIntervalSince(harness.clock.now.addingTimeInterval(-30 * 86_400))) < 5)
    }

    @Test func billedFailuresCountTowardTheRunsCap() async throws {
        let judge = FakeJudge()
        // Claude billed each call, then the answer was cut off twice.
        judge.failLane("run", with: .billed(.truncated, costMicros: 1_000))
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 12)
        try await setCallCost(harness, 1_000)
        let id = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached), capMicros: 2_500)
        await harness.engine.drain()
        let run = try #require(try await harness.store.run(id: id))
        #expect(run.state == .paused && run.pauseReason == .cap)
        #expect(run.costMicros == 2_000 && judge.calls.count == 2)
        #expect(try await harness.store.meanCallCostMicros(model: testConfig.model) == 1_000)
    }
}
