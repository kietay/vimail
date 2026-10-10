import Foundation
import Testing
@testable import DummyProvider
@testable import MailCore
@testable import MailRules
@testable import MailStore
@testable import MailSync

let receiptsRule = RuleSpec(name: "Receipts", label: "receipts", ask: "Receipts and invoices for things I bought")
let travelRule = RuleSpec(name: "Travel", label: "travel", ask: "Trip bookings and itineraries")
let deploysRule = RuleSpec(name: "Deploys", label: "deploys", when: "subject:deploy")

@Suite("Rule engine: arriving mail", .serialized)
struct RuleEnginePumpTests {
    // MARK: - Intake

    @Test func initialSyncMakesNoJudgeCalls() async throws {
        let harness = try await Harness(rules: [receiptsRule, deploysRule], account: false)
        // The first sync stores the inbox: old mail, never queued.
        #expect(await harness.sync.cycle())
        await harness.engine.drain()
        #expect(harness.calls().isEmpty)
        #expect(try harness.queue().isEmpty)
    }

    @Test func backgroundDownloadMakesNoJudgeCalls() async throws {
        let harness = try await Harness(rules: [receiptsRule, deploysRule], account: false)
        repeat {
            #expect(await harness.sync.cycle())
        } while try await harness.store.meta("backfill_done") == nil
        await harness.engine.drain()
        #expect(harness.calls().isEmpty)
        #expect(try harness.queue().isEmpty)

        // Mail that arrives afterwards is judged.
        try await harness.provider.deliverIncomingMail(count: 2)
        #expect(await harness.sync.cycle())
        #expect(try harness.queue().count >= 1)
        await harness.engine.drain()
        #expect(!harness.calls().isEmpty)
        #expect(harness.calls().allSatisfy { $0.lane == .live })
        #expect(try harness.queue().isEmpty)
    }

    @Test func newMailOneCallCoversAllRules() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"], "r2": ["trip"]])
        let harness = try await Harness(rules: [receiptsRule, travelRule, deploysRule], judge: judge)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt for the deploy tool"))
        await harness.engine.drain()

        let calls = harness.calls()
        #expect(calls.count == 1)
        #expect(calls.first?.evaluate == ["r1", "r2"])
        #expect(calls.first?.lane == .live)
        // The prompt lists every Claude rule with its label's current name.
        #expect(calls.first?.catalog.map(\.key) == ["r1", "r2"])
        #expect(calls.first?.catalog.first?.labelName == "receipts")
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try await harness.hasLabel("m1", "deploys"))
        #expect(try await !harness.hasLabel("m1", "travel"))
        let receipts = try await harness.rule("Receipts")
        #expect(try await harness.decision("m1", receipts)?.source == .claude)
        #expect(try await harness.decision("m1", harness.rule("Travel"))?.verdict == .noMatch)
        #expect(try harness.queue().isEmpty)
        // The verdict is cached at the rule's judge hash, with the model that gave it.
        let hash = try #require(receipts.judgeHash(model: testConfig.model, effort: testConfig.effort, promptVersion: testConfig.promptVersion))
        #expect(try await harness.store.verdicts(messageIDs: ["m1"], judgeHashes: [hash]).first?.verdict == .match)
    }

    @Test func ownMailIsNeverJudged() async throws {
        let harness = try await Harness(rules: [receiptsRule])
        try await harness.deliver(mail("m1", from: me, subject: "Your receipt", labels: ["SENT"]))
        await harness.engine.drain()
        #expect(harness.calls().isEmpty)
        #expect(try harness.queue().isEmpty)
    }

    @Test func queueSurvivesStoppedEngine() async throws {
        let harness = try await Harness(rules: [receiptsRule], judge: FakeJudge(matching: ["r1": ["receipt"]]))
        await harness.engine.start()
        await harness.engine.stop()
        // Sync still stores and queues arriving mail; the stopped engine ignores the wake.
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        harness.engine.wake()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try harness.queue().map(\.state) == ["queued"])
        #expect(harness.calls().isEmpty)

        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let next = harness.restart(judge: judge)
        await next.drain()
        #expect(judge.calls.count == 1)
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try harness.queue().isEmpty)
    }

    @Test func resyncCapsAndHolds() async throws {
        let harness = try await Harness(rules: [deploysRule], account: false, initialSyncLimit: 2_000)
        // Rules last processed live mail long ago; then history expired and everything downloads
        // again into an empty cache.
        let longAgo = Int64(Date().addingTimeInterval(-365 * 86_400).timeIntervalSince1970 * 1000)
        try await harness.store.setMeta("rules_live_watermark", String(longAgo))
        try await harness.store.setMeta("resync", "1")
        repeat {
            #expect(await harness.sync.cycle())
        } while try await harness.store.meta("backfill_done") == nil

        let rows = try harness.queue()
        let live = rows.filter { $0.kind == "live" }
        let held = rows.filter { $0.state == "held" }
        #expect(live.count == 500)
        #expect(!held.isEmpty)
        #expect(held.allSatisfy { $0.kind == "backlog" })
        await harness.engine.drain()
        // Live mail went through; the backlog waits for your confirmation.
        #expect(try harness.queue().allSatisfy { $0.state == "held" })
        let status = await harness.engine.makeStatus()
        #expect(status.held == held.count)
        let backlog = try #require(status.runs.first { $0.kind == .backlog })
        #expect(backlog.state == .awaitingConfirm)

        try await harness.engine.confirmRun(backlog.id)
        await harness.engine.drain()
        #expect(try harness.queue().isEmpty)
        #expect(try await harness.store.run(id: backlog.id)?.state == .done)
    }

    // MARK: - Cascade

    @Test func filterRejectNeverCallsJudge() async throws {
        let harness = try await Harness(rules: [RuleSpec(name: "Receipts", label: "receipts", when: "from:stripe.com", ask: "Receipts")])
        try await harness.deliver(mail("m1", from: ana, subject: "Lunch receipt?"))
        await harness.engine.drain()
        #expect(harness.calls().isEmpty)
        let decision = try await harness.decision("m1", harness.rule("Receipts"))
        #expect(decision?.verdict == .noMatch && decision?.source == .gate)
    }

    @Test func foldSeesEarlierLabels() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule, RuleSpec(name: "Finance", label: "finance", when: "label:receipts")], judge: judge)
        try await harness.deliver(
            mail("m1", from: stripe, subject: "Your receipt"),
            mail("m2", from: stripe, subject: "Your weekly summary")
        )
        await harness.engine.drain()
        #expect(judge.calls.count == 2)
        #expect(judge.calls.allSatisfy { $0.evaluate == ["r1"] })
        // The filter rule saw the label the Claude rule added in the same pass.
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try await harness.hasLabel("m1", "finance"))
        #expect(try await !harness.hasLabel("m2", "finance"))
    }

    @Test func stopAfterMatchEndsThePass() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        var first = receiptsRule
        first.stopAfterMatch = true
        let harness = try await Harness(rules: [first, RuleSpec(name: "Everything", label: "all")], judge: judge)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"), mail("m2", from: ana, subject: "Lunch"))
        await harness.engine.drain()
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try await !harness.hasLabel("m1", "all"))
        #expect(try await harness.hasLabel("m2", "all"))
        #expect(try await harness.decision("m1", harness.rule("Everything")) == nil)
    }

    @Test func repliesInheritOnlyWhenTheRuleOptsIn() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        var inheriting = receiptsRule
        inheriting.inheritInThread = true
        let harness = try await Harness(rules: [inheriting], judge: judge)
        try await harness.deliver(mail("m1", thread: "t1", from: stripe, subject: "Your receipt", minutesAgo: 10))
        await harness.engine.drain()
        try await harness.deliver(mail("m2", thread: "t1", from: stripe, subject: "Re: Your order", minutesAgo: 5))
        await harness.engine.drain()
        #expect(judge.calls.count == 1)
        #expect(try await harness.decision("m2", harness.rule("Receipts"))?.source == .thread)
        #expect(try await harness.hasLabel("m2", "receipts"))
    }

    @Test func marksExamplesAndOverridesDecideWithoutClaude() async throws {
        let harness = try await Harness(rules: [receiptsRule])
        let rule = try await harness.rule("Receipts")
        let label = try await harness.labelID("receipts")
        try await harness.store.upsertMessages([
            mail("m1", from: stripe, subject: "Your receipt"), mail("m2", from: apple, subject: "Your receipt"),
            mail("m3", from: shop, subject: "Sale"),
        ])
        try await harness.store.setLabelMarks(messageIDs: ["m1"], labelID: label, present: false)
        try await harness.store.setExample(ruleID: rule.id, messageID: "m2", matches: true, origin: .preview)
        try await harness.store.setOverride(ruleID: rule.id, subject: "@allbirds.com", matches: true, origin: .user)

        let manual = try await harness.engine.runRules(on: ["m1", "m2", "m3"])
        #expect(manual.estimate.needClaude == 0)
        await harness.engine.drain()
        #expect(harness.calls().isEmpty)
        #expect(try await harness.decision("m1", rule)?.source == .mark)
        #expect(try await !harness.hasLabel("m1", "receipts"))
        #expect(try await harness.decision("m2", rule)?.source == .example)
        #expect(try await harness.decision("m3", rule)?.source == .override)
        #expect(try await harness.hasLabel("m3", "receipts"))
    }

    @Test func gmailLabelsWakeSync() async throws {
        let harness = try await Harness(rules: [RuleSpec(name: "Work", label: "work", when: "from:studio.co")])
        try await harness.deliver(mail("m1", from: ana, subject: "Plans"))
        await harness.engine.drain()
        #expect(try await harness.labels("m1").contains("Label_1"))
        #expect(harness.syncWakes.count == 1)
        #expect(try await harness.store.outboxCount() == 1)

        // A local label syncs nothing.
        let local = try await Harness(rules: [deploysRule])
        try await local.deliver(mail("m1", subject: "deploy finished"))
        await local.engine.drain()
        #expect(try await local.hasLabel("m1", "deploys"))
        #expect(local.syncWakes.count == 0)
    }

    // MARK: - Verdict cache

    @Test func editingR3RejudgesOnlyR3() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(
            rules: [receiptsRule, travelRule, RuleSpec(name: "Reply", label: "reply", ask: "A person waits for my answer")], judge: judge
        )
        try await harness.deliver(mail("m1", subject: "Can you send the invoice?"))
        await harness.engine.drain()
        #expect(judge.calls.map(\.evaluate) == [["r1", "r2", "r3"]])

        var edited = try await harness.rule("Reply")
        edited.ask = "Someone asks me a direct question"
        try await harness.store.saveRule(edited)
        try await harness.engine.rulesChanged(.revised(ruleID: edited.id, revision: 2))
        _ = try await harness.engine.runRules(on: ["m1"])
        await harness.engine.drain()
        #expect(judge.calls.map(\.evaluate) == [["r1", "r2", "r3"], ["r3"]])
        #expect(try await harness.decision("m1", harness.rule("Reply"))?.revision == 2)
    }

    @Test func newMarkRejudgesNothing() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"), mail("m2", from: shop, subject: "Sale ends"))
        await harness.engine.drain()
        #expect(judge.calls.count == 2)

        // A new ✖ on another message, tested into the prompt: older verdicts stand.
        var rule = try await harness.rule("Receipts")
        try await harness.store.setExample(ruleID: rule.id, messageID: "m2", matches: false, origin: .preview)
        rule.promptExampleIDs = ["m2"]
        try await harness.store.saveRule(rule)
        try await harness.engine.rulesChanged(.updated(ruleID: rule.id))
        _ = try await harness.engine.runRules(on: ["m1"])
        await harness.engine.drain()
        #expect(judge.calls.count == 2)
        #expect(try await harness.decision("m1", rule)?.source == .cache)
        #expect(try await harness.hasLabel("m1", "receipts"))

        // New mail carries the tested example in the prompt.
        try await harness.deliver(mail("m3", from: stripe, subject: "Another receipt"))
        await harness.engine.drain()
        #expect(judge.calls.last?.examples.map(\.verdict) == [.noMatch])
        #expect(judge.calls.last?.examples.first?.digest.contains("@allbirds.com") == true)
    }

    @Test func verdictsSurviveCrashBeforeCommit() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        // The commit fails, as if the app died between the call and the commit.
        try harness.store.writeNow { db, _ in
            try db.execute("CREATE TRIGGER fail BEFORE INSERT ON rule_decisions BEGIN SELECT RAISE(ABORT, 'injected'); END")
        }
        await harness.engine.drain()
        #expect(judge.calls.count == 1)
        #expect(try harness.queue().map(\.state) == ["queued"])
        #expect(try await !harness.hasLabel("m1", "receipts"))
        await harness.engine.stop()

        try harness.store.writeNow { db, _ in try db.execute("DROP TRIGGER fail") }
        let next = harness.restart(judge: judge)
        await next.drain()
        #expect(judge.calls.count == 1)
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try await harness.decision("m1", harness.rule("Receipts"))?.source == .cache)
    }

    @Test func unsureCountsAsNoAndIsReviewed() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        judge.set(.unsure, for: "m1", rule: "r1")
        try await harness.deliver(mail("m1", subject: "Invoice question"))
        await harness.engine.drain()
        #expect(try await !harness.hasLabel("m1", "receipts"))
        #expect(await harness.engine.makeStatus().unsureToReview == 1)
        let rule = try await harness.rule("Receipts")
        try await harness.store.setExample(ruleID: rule.id, messageID: "m1", matches: false, origin: .preview)
        #expect(await harness.engine.makeStatus().unsureToReview == 0)
    }

    // MARK: - Failures

    @Test func transientRetriesAfterBackoff() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        judge.fail("m1", with: .transient(retryAfter: nil))
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        await harness.engine.drain()
        let row = try #require(try harness.queue().first)
        #expect(row.state == "queued" && row.attempts == 1)
        let wait = row.notBefore.timeIntervalSince(harness.clock.now)
        #expect(wait >= 3.9 && wait <= 6.1)
        guard case .cooling = await harness.engine.ai else {
            Issue.record("Claude should cool down")
            return
        }

        await harness.engine.drain()
        #expect(judge.calls.count == 1)
        harness.clock.advance(by: 7)
        await harness.engine.drain()
        #expect(judge.calls.count == 2)
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(await harness.engine.ai == .ready)
    }

    @Test func retryAfterIsHonoured() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        judge.fail("m1", with: .transient(retryAfter: .seconds(120)))
        try await harness.deliver(mail("m1", subject: "Hello"))
        await harness.engine.drain()
        let wait = try #require(try harness.queue().first).notBefore.timeIntervalSince(harness.clock.now)
        #expect(wait >= 119 && wait <= 145)
    }

    @Test func attemptsRunOutAfterEight() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule, deploysRule], judge: judge)
        judge.fail("m1", with: .transient(retryAfter: nil), .transient(retryAfter: nil), .transient(retryAfter: nil), .transient(retryAfter: nil),
                   .transient(retryAfter: nil), .transient(retryAfter: nil), .transient(retryAfter: nil), .transient(retryAfter: nil))
        try await harness.deliver(mail("m1", subject: "deploy receipt"))
        for _ in 0..<7 {
            await harness.engine.drain()
            harness.clock.advance(by: 1_900)
        }
        // Claude answers another email meanwhile: the trouble is this one.
        try await harness.deliver(mail("m2", subject: "hello", minutesAgo: 0))
        try harness.store.writeNow { db, _ in try db.run("UPDATE rule_queue SET not_before = ? WHERE message_id = 'm1'", [harness.clock.now.addingTimeInterval(60)]) }
        await harness.engine.drain()
        harness.clock.advance(by: 1_900)
        await harness.engine.drain()
        #expect(judge.calls.filter { $0.messageID == "m1" }.count == 8)
        let row = try #require(try harness.queue().first { $0.messageID == "m1" })
        #expect(row.state == "failed")
        // The filter rule committed before the row failed.
        #expect(try await harness.hasLabel("m1", "deploys"))
        #expect(await harness.engine.makeStatus().failed == 1)
    }

    @Test func offlineDoesNotCountAttempts() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        judge.fail("m1", with: .offline)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"), mail("m2", from: stripe, subject: "Your receipt too", minutesAgo: 2))
        await harness.engine.drain()
        let rows = try harness.queue()
        #expect(rows.allSatisfy { $0.attempts == 0 && $0.state == "queued" })
        #expect(rows.allSatisfy { $0.notBefore > harness.clock.now.addingTimeInterval(50) })
        harness.clock.advance(by: 61)
        await harness.engine.drain()
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try await harness.hasLabel("m2", "receipts"))
    }

    @Test func badKeyPausesAIButFiltersRun() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule, deploysRule], judge: judge)
        judge.failLane("live", with: .paused(.badKey))
        try await harness.deliver(mail("m1", from: stripe, subject: "Deploy receipt"), mail("m2", subject: "deploy done", minutesAgo: 2))
        await harness.engine.drain()
        // Calls already on their way when the first came back paused.
        #expect(judge.calls.count <= 2)
        #expect(try await harness.hasLabel("m1", "deploys"))
        #expect(try await harness.hasLabel("m2", "deploys"))
        #expect(try await !harness.hasLabel("m1", "receipts"))
        #expect(try harness.queue().map(\.state) == ["waiting_ai", "waiting_ai"])
        #expect(try harness.queue().allSatisfy { $0.attempts == 0 })
        let status = await harness.engine.makeStatus()
        #expect(status.ai == .paused(.badKey) && status.waitingAI == 2)

        // A new key: the mail that waited goes through.
        judge.failLane("live", with: nil)
        await harness.engine.configure(judge: judge, aiPause: nil, config: testConfig)
        await harness.engine.drain()
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try await !harness.hasLabel("m2", "receipts"))
        #expect(try harness.queue().isEmpty)
    }

    @Test func modelUnavailablePausesLaneNotRows() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        judge.failLane("live", with: .paused(.modelUnavailable))
        try await harness.deliver(mail("m1", subject: "One"), mail("m2", subject: "Two", minutesAgo: 2), mail("m3", subject: "Three", minutesAgo: 3))
        await harness.engine.drain()
        // The first call paused the lane; the rest wait without calls or failures.
        #expect(judge.calls.count <= RuleEngine.judgeConcurrency)
        #expect(try harness.queue().allSatisfy { $0.state == "waiting_ai" && $0.attempts == 0 })
        #expect(await harness.engine.ai == .paused(.modelUnavailable))
        await harness.engine.drain()
        #expect(judge.calls.count <= RuleEngine.judgeConcurrency)
    }

    @Test func noJudgeWaitsForClaude() async throws {
        let harness = try await Harness(rules: [receiptsRule, deploysRule], judge: nil)
        try await harness.deliver(mail("m1", subject: "deploy receipt"))
        await harness.engine.drain()
        #expect(try await harness.hasLabel("m1", "deploys"))
        #expect(try harness.queue().map(\.state) == ["waiting_ai"])
        #expect(await harness.engine.makeStatus().ai == .notConfigured)
    }

    @Test func dailyBudgetPausesLiveUntilMidnight() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        judge.failLane("live", with: .paused(.budgetDay))
        try await harness.deliver(mail("m1", subject: "Hello"))
        await harness.engine.drain()
        #expect(await harness.engine.ai == .paused(.budgetDay))
        #expect(try harness.queue().map(\.state) == ["waiting_ai"])
        let until = try #require(await harness.engine.aiPausedUntil)
        #expect(until == Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: harness.clock.now)))

        judge.failLane("live", with: nil)
        harness.clock.advance(by: until.timeIntervalSince(harness.clock.now) + 1)
        await harness.engine.drain()
        #expect(await harness.engine.ai == .ready)
        #expect(try harness.queue().isEmpty)
    }

    @Test func refusalBecomesDeclined() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        judge.fail("m1", with: .refused(category: nil))
        try await harness.deliver(mail("m1", subject: "Verify your account now"))
        await harness.engine.drain()
        let rule = try await harness.rule("Receipts")
        #expect(try await harness.decision("m1", rule)?.verdict == .declined)
        #expect(try await !harness.hasLabel("m1", "receipts"))
        #expect(try harness.queue().isEmpty)
        // Declined is cached: not asked again.
        _ = try await harness.engine.runRules(on: ["m1"])
        await harness.engine.drain()
        #expect(judge.calls.count == 1)
        let explanation = try await harness.engine.explain(threadID: "m1")
        #expect(explanation.misses.first?.verdict == .declined)
        #expect(explanation.misses.first?.reason?.contains("declined") == true)
    }

    @Test func missingVerdictsFailOnlyTheirMessage() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"], "r2": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule, travelRule], judge: judge)
        judge.omit("r2")
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        await harness.engine.drain()
        // What Claude answered commits; the row fails for the rest.
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try harness.queue().map(\.state) == ["failed"])
        #expect(try await harness.decision("m1", harness.rule("Travel")) == nil)
    }

    @Test func invalidRequestFailsTheRow() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        judge.fail("m1", with: .invalid(code: "http_413"))
        try await harness.deliver(mail("m1", subject: "Huge"))
        await harness.engine.drain()
        #expect(try harness.queue().map(\.state) == ["failed"])
        #expect(try harness.store.readNow { db in try db.first("SELECT error_code FROM rule_queue") { $0.string(0) } } == "http_413")
    }

    @Test func liveCallCapPerHour() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let count = RuleEngine.liveCallsPerHour + 5
        try await harness.deliver((0..<count).map { mail("m\($0)", subject: "Message \($0)", minutesAgo: Double($0) / 10) })
        await harness.engine.drain()
        #expect(judge.calls.count == RuleEngine.liveCallsPerHour)
        let waiting = try harness.queue()
        #expect(waiting.count == 5)
        #expect(waiting.allSatisfy { $0.state == "queued" && $0.attempts == 0 && $0.notBefore > harness.clock.now.addingTimeInterval(3_000) })

        harness.clock.advance(by: 3_601)
        await harness.engine.drain()
        #expect(judge.calls.count == count)
        #expect(try harness.queue().isEmpty)
    }

    // MARK: - Stopping

    @Test func noWritesAfterStop() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.hold()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        let writes = Counter()
        harness.store.observe { _ in writes.increment() }
        await harness.engine.start()
        harness.engine.wake()
        try await eventually("a call in flight") { judge.waiting == 1 }

        await harness.engine.stop()
        let stopped = writes.count
        judge.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(writes.count == stopped)
        #expect(try harness.queue().map(\.state) == ["queued"])
        #expect(try await !harness.hasLabel("m1", "receipts"))
        // Asking a stopped engine to write is refused.
        await #expect(throws: RuleEngineError.stopped) { try await harness.engine.setPaused(true) }
        for await _ in harness.engine.status {}
    }

    @Test func restartResumesQueue() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        judge.fail("m1", with: .transient(retryAfter: nil))
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"), mail("m2", from: stripe, subject: "Your receipt 2", minutesAgo: 2))
        await harness.engine.start()
        try await eventually("m2 labeled") { try await harness.hasLabel("m2", "receipts") }
        try await eventually("m1 waiting for its retry") { try harness.queue().first?.attempts == 1 }
        await harness.engine.stop()

        let next = harness.restart(judge: judge)
        await next.start()
        harness.clock.advance(by: 10)
        try await eventually("m1 labeled after the restart") { try await harness.hasLabel("m1", "receipts") }
        #expect(try harness.queue().isEmpty)
        await next.stop()
    }

    @Test func pausedRulesClaimNothing() async throws {
        let harness = try await Harness(rules: [deploysRule])
        try await harness.engine.setPaused(true)
        try await harness.deliver(mail("m1", subject: "deploy"))
        await harness.engine.drain()
        #expect(try harness.queue().count == 1)
        #expect(await harness.engine.makeStatus().userPaused)
        #expect(try await harness.store.meta(RuleEngine.pausedKey) == "1")

        // Remembered across launches.
        let next = harness.restart(judge: nil)
        await next.drain()
        #expect(try harness.queue().count == 1)
        try await next.setPaused(false)
        await next.drain()
        #expect(try harness.queue().isEmpty)
    }

    @Test func pauseHoldsWhenRulesChangeBeforeTheFirstPass() async throws {
        let harness = try await Harness(rules: [deploysRule])
        try await harness.engine.setPaused(true)
        let next = harness.restart(judge: nil)
        try await next.rulesChanged(.updated(ruleID: harness.rule("Deploys").id))
        try await harness.deliver(mail("m1", subject: "deploy"))
        await next.drain()
        #expect(try harness.queue().map(\.state) == ["queued"])
        #expect(try await !harness.hasLabel("m1", "deploys"))
        #expect(await next.makeStatus().userPaused)
    }

    @Test func restartReleasesWaitingMail() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.failLane("live", with: .paused(.badKey))
        judge.failLane("run", with: .paused(.badKey))
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await storeMail(harness, count: 2)
        let run = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Receipts").id, window: .allCached))
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        await harness.engine.drain()
        #expect(try harness.queue().first { $0.messageID == "m1" }?.state == "waiting_ai")
        #expect(try await harness.store.run(id: run)?.pauseReason == .ai)
        await harness.engine.stop()

        // The key is fixed, and the app launches again with a judge that works.
        judge.failLane("live", with: nil)
        judge.failLane("run", with: nil)
        let next = harness.restart(judge: judge)
        await next.configure(judge: judge, aiPause: nil, config: testConfig)
        await next.drain()
        #expect(try harness.queue().isEmpty)
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try await harness.store.run(id: run)?.state == .done)
    }

    @Test func oneCallPerMessageAcrossRuns() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.engine.setPaused(true)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        // `=` on mail still queued: its live row and its manual row come due together.
        let manual = try await harness.engine.runRules(on: ["m1"], confirmed: true)
        try await harness.engine.setPaused(false)
        await harness.engine.drain()
        #expect(judge.calls.map(\.messageID) == ["m1"])
        #expect(try harness.queue().isEmpty)
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try await harness.store.run(id: try #require(manual.runID))?.state == .done)
    }

    @Test func unreadableRulesClaimNothing() async throws {
        let harness = try await Harness(rules: [deploysRule])
        try await harness.deliver(mail("m1", subject: "deploy"))
        try harness.store.writeNow { db, _ in try db.run("ALTER TABLE rules RENAME TO rules_away") }
        let next = harness.restart(judge: nil)
        await next.drain()
        // Without its rules the engine takes nothing: the mail stays queued and the loop backs off.
        #expect(try harness.queue().map(\.state) == ["queued"])
        #expect(await next.storeFailures == 1)

        try harness.store.writeNow { db, _ in try db.run("ALTER TABLE rules_away RENAME TO rules") }
        await next.drain()
        #expect(try harness.queue().isEmpty)
        #expect(try await harness.hasLabel("m1", "deploys"))
        #expect(await next.storeFailures == 0)
    }

    @Test func anOutageKeepsRowsWaitingPastEightAttempts() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.failLane("live", with: .transient(retryAfter: nil))
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        // Every call fails for 20 minutes and more: Claude is down, not this email.
        for _ in 0..<10 {
            await harness.engine.drain()
            harness.clock.advance(by: 1_900)
        }
        #expect(judge.calls.count == 10)
        #expect(try harness.queue().map(\.state) == ["queued"])
        // Claude is back: the mail is labeled without `r`.
        judge.failLane("live", with: nil)
        harness.clock.advance(by: 400)
        await harness.engine.drain()
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(try harness.queue().isEmpty)
    }

    @Test func pauseClaudeReportedIsTriedAgain() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.failLane("live", with: .paused(.billing))
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        await harness.engine.drain()
        #expect(await harness.engine.ai == .paused(.billing))
        #expect(judge.calls.count == 1)

        // Still no credit at the next try: one call, paused again.
        harness.clock.advance(by: RuleEngine.pauseProbeInterval + 1)
        await harness.engine.drain()
        #expect(judge.calls.count == 2)
        #expect(await harness.engine.ai == .paused(.billing))

        // Credit added at Anthropic, nothing changed here: the next try goes through.
        judge.failLane("live", with: nil)
        await harness.engine.drain()
        #expect(judge.calls.count == 2)
        harness.clock.advance(by: RuleEngine.pauseProbeInterval + 1)
        await harness.engine.drain()
        #expect(try await harness.hasLabel("m1", "receipts"))
        #expect(await harness.engine.ai == .ready)

        // A pause the app set (no consent) waits for the app.
        await harness.engine.configure(judge: judge, aiPause: .noConsent, config: testConfig)
        try await harness.deliver(mail("m2", from: stripe, subject: "Your receipt"))
        harness.clock.advance(by: RuleEngine.pauseProbeInterval + 1)
        await harness.engine.drain()
        #expect(judge.calls.count == 3)
        #expect(try harness.queue().map(\.state) == ["waiting_ai"])
    }

    @Test func relaunchHoldsMailThatWaitedTooLong() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.failLane("live", with: .paused(.billing))
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.deliver(mail("old", from: stripe, subject: "Your receipt"))
        await harness.engine.drain()
        #expect(try harness.queue().map(\.state) == ["waiting_ai"])
        await harness.engine.stop()

        // Credit is added while the app is closed; it opens 5 days later.
        judge.failLane("live", with: nil)
        harness.clock.advance(by: 5 * 86_400)
        try await harness.deliver(mail("new", from: stripe, subject: "Your receipt", date: harness.clock.now.addingTimeInterval(-60)))
        let next = harness.restart(judge: judge)
        await next.drain()
        // The new mail is labeled; the old waits in a backlog run for your confirmation.
        #expect(judge.calls.map(\.messageID) == ["old", "new"])
        #expect(try await harness.hasLabel("new", "receipts"))
        #expect(try await !harness.hasLabel("old", "receipts"))
        let rows = try harness.queue()
        #expect(rows.map(\.messageID) == ["old"] && rows.map(\.state) == ["held"] && rows.map(\.kind) == ["backlog"])
        await next.stop()
    }

    @Test func deletedLabelStopsItsRulesAtOnce() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let receipts = RuleSpec(name: "Receipts", label: "receipts", ask: "Receipts and invoices for things I bought", stopAfterMatch: true)
        let harness = try await Harness(rules: [receipts, deploysRule], judge: judge)
        try await harness.deliver(mail("m1", from: stripe, subject: "Deploy receipt"))
        await harness.engine.drain()
        #expect(judge.calls.count == 1)
        #expect(try await !harness.hasLabel("m1", "deploys"))

        // Deleted here or in Gmail: the store turns its rule off; nothing tells the engine.
        try await harness.store.deleteLabel(id: harness.labelID("receipts"))
        try await harness.deliver(mail("m2", from: stripe, subject: "Deploy receipt"), mail("m3", from: stripe, subject: "Your receipt", minutesAgo: 2))
        await harness.engine.drain()
        // Off: no call for it, and it no longer stops the rules after it.
        #expect(judge.calls.count == 1)
        #expect(try await harness.hasLabel("m2", "deploys"))
        #expect(try harness.queue().isEmpty)
    }

    @Test func modelSwitchStopsTheBatch() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.hold()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.deliver((0..<8).map { mail("m\($0)", from: stripe, subject: "Your receipt \($0)", minutesAgo: Double($0)) })
        let draining = Task { await harness.engine.drain() }
        try await eventually("calls in flight") { judge.waiting == RuleEngine.judgeConcurrency }
        let sonnet = RuleEngine.JudgeConfig(model: "claude-sonnet-5-5", effort: "low", promptVersion: 1, prices: testConfig.prices)
        await harness.engine.configure(judge: judge, aiPause: nil, config: sonnet)
        let haiku = try #require(try await harness.judgeHash("Receipts"))
        judge.release()
        await draining.value
        // No call of the old pass started after the switch: all 8 went again under the new model.
        #expect(judge.calls.count == RuleEngine.judgeConcurrency + 8)
        let ids = (0..<8).map { "m\($0)" }
        #expect(try await harness.store.verdicts(messageIDs: ids, judgeHashes: [haiku]).count == RuleEngine.judgeConcurrency)
        #expect(try harness.queue().isEmpty)
    }

    @Test func pausingAllRulesStopsTheBatch() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.hold()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.deliver((0..<8).map { mail("m\($0)", from: stripe, subject: "Your receipt \($0)", minutesAgo: Double($0)) })
        let draining = Task { await harness.engine.drain() }
        try await eventually("calls in flight") { judge.waiting == RuleEngine.judgeConcurrency }
        try await harness.engine.setPaused(true)
        judge.release()
        await draining.value
        #expect(judge.calls.count == RuleEngine.judgeConcurrency)
        #expect(try harness.queue().count == 8 - RuleEngine.judgeConcurrency)
    }

    @Test func appNapIsNotHeldOffWhileRulesArePaused() async throws {
        let harness = try await Harness(rules: [deploysRule])
        try await storeMail(harness, count: 3, subject: "deploy")
        let latest = Latest<RuleEngineStatus>()
        let listener = Task { for await status in harness.engine.status { latest.set(status) } }
        try await harness.engine.setPaused(true)
        _ = try await harness.engine.startRun(RunPlan(ruleID: harness.rule("Deploys").id, window: .allCached))
        try await eventually("the run in the status") { latest.value?.runs.contains { $0.state == .running } == true }
        #expect(await !harness.engine.keepsAwake)
        await harness.engine.stop()
        await listener.value
    }

    @Test func aPaidAnswerIsKeptWhenStopping() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.holdIgnoringCancellation()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        await harness.engine.start()
        harness.engine.wake()
        try await eventually("a call in flight") { judge.waiting == 1 }
        let stopping = Task { await harness.engine.stop() }
        try await eventually("stopping") { await harness.engine.stopped }
        // The answer comes back, paid for, after the account began to close.
        judge.release()
        await stopping.value
        let hash = try #require(try await harness.judgeHash("Receipts"))
        #expect(try await harness.store.verdicts(messageIDs: ["m1"], judgeHashes: [hash]).count == 1)
        #expect(try harness.queue().map(\.state) == ["queued"])

        // The next launch uses it: no second call.
        let next = harness.restart(judge: judge)
        await next.drain()
        #expect(judge.calls.count == 1)
        #expect(try await harness.hasLabel("m1", "receipts"))
    }

    @Test func aSecondStopWaitsForTheFirst() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        judge.holdIgnoringCancellation()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.deliver(mail("m1", from: stripe, subject: "Your receipt"))
        await harness.engine.start()
        harness.engine.wake()
        try await eventually("a call in flight") { judge.waiting == 1 }
        let first = Task { await harness.engine.stop() }
        try await eventually("stopping") { await harness.engine.stopped }
        let returned = Counter()
        let second = Task {
            await harness.engine.stop()
            returned.increment()
        }
        try await Task.sleep(for: .milliseconds(100))
        // Still writing: the second stop has not returned.
        #expect(returned.count == 0)
        judge.release()
        await first.value
        await second.value
        #expect(returned.count == 1)
        #expect(await harness.engine.activeWrites == 0)
    }
}
