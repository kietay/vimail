import Foundation
import Testing
@testable import MailCore
@testable import MailStore

/// A verdict by Haiku with a fixed date.
func verdict(_ messageID: String, _ judgeHash: String, _ verdict: Verdict = .match, reason: String = "receipt for a purchase") -> StoredVerdict {
    StoredVerdict(
        messageID: messageID, judgeHash: judgeHash, verdict: verdict, reason: reason, examplesDigest: "ex-1", model: "claude-haiku-5-5",
        servedBy: "claude-haiku-5-5", createdAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
}

/// Arrival of new mail through history, queued in today's live run. Returns the run.
func arrive(_ store: MailStore, _ messages: [MailMessage]) async throws -> Int64 {
    _ = try await store.applyRemoteChanges(ChangeSet(cursor: "2", upserted: messages), cursor: "2", intake: .live(arrived: Set(messages.map(\.id))))
    return try #require(try runRows(store).last { $0.kind == "live" }).id
}

@Suite("Rule work")
struct RuleWorkTests {
    // MARK: - Queue

    @Test func claimsDueRowsOfRunningRunsBestFirst() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let rules = [RunRule(rule.rule)]
        let live = try await arrive(store, [message("n1", thread: "n1", from: nina, minutesAgo: 1)])
        let manual = try await store.createRun(.manual, rules: rules, messageIDs: ["m4", "m3"])
        let backfill = try await store.createRun(.backfill, rules: rules, messageIDs: ["m1"])
        // None of these is claimed: paused, cancelled, undone, waiting for confirmation.
        let paused = try await store.createRun(.backfill, rules: rules, messageIDs: ["m1"])
        #expect(try await store.pauseRun(paused, reason: .user))
        let cancelled = try await store.createRun(.backfill, rules: rules, messageIDs: ["m3"])
        #expect(try await store.cancelRun(cancelled))
        let undone = try await store.createRun(.backfill, rules: rules, messageIDs: ["m4"])
        try await store.undoRun(undone)
        _ = try await store.createRun(.gap, rules: rules, messageIDs: ["m1"])

        let claims = try await store.claimDueRules()
        #expect(claims.map(\.key) == [
            QueueKey(messageID: "n1", runID: live), QueueKey(messageID: "m3", runID: manual),
            QueueKey(messageID: "m4", runID: manual), QueueKey(messageID: "m1", runID: backfill),
        ])
        #expect(claims.map(\.runKind) == [.live, .manual, .manual, .backfill])
        #expect(claims.map(\.priority) == [0, 1, 1, 2])
        #expect(claims.allSatisfy { $0.attempts == 0 })
        // Claiming writes nothing: the engine passes the rows it holds, and they are not claimed again.
        let held = Set(claims.prefix(2).map(\.key))
        #expect(try await store.claimDueRules(limit: 5, excluding: held).map(\.key) == claims.dropFirst(2).map(\.key))
        #expect(try await store.claimDueRules(limit: 1).map(\.key) == [claims[0].key])
        #expect(try queueRows(store).filter { $0.state == "queued" }.count == 5)
    }

    @Test func rowsRetryWaitFailAndComeBack() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let run = try await store.createRun(.backfill, rules: [RunRule(rule.rule)], messageIDs: ["m1", "m3", "m4"])
        let (m1, m3, m4) = (QueueKey(messageID: "m1", runID: run), QueueKey(messageID: "m3", runID: run), QueueKey(messageID: "m4", runID: run))
        let now = Date()

        // A transient failure: due again later.
        try await store.retryRow(m1, attempts: 1, notBefore: now.addingTimeInterval(60), errorCode: "http_529")
        #expect(try await store.claimDueRules(now: now).map(\.key) == [m3, m4])
        let retried = try #require(try await store.claimDueRules(now: now.addingTimeInterval(61)).first { $0.key == m1 })
        #expect(retried.attempts == 1)
        let due = try #require(try await store.nextRuleQueueDueDate(after: now))
        #expect(abs(due.timeIntervalSince(now.addingTimeInterval(60))) < 0.01)
        #expect(try await store.nextRuleQueueDueDate(after: now.addingTimeInterval(61)) == nil)

        // Claude is unavailable: the row waits, and is not due.
        try await store.waitForAI([m3])
        #expect(try await store.ruleQueueCounts() == RuleQueueCounts(liveQueued: 0, waitingAI: 1, held: 0, failed: 0))
        #expect(try await store.claimDueRules(now: now).map(\.key) == [m4])
        #expect(try await store.releaseWaitingAI() == 1)
        #expect(try await store.claimDueRules(now: now).map(\.key) == [m3, m4])

        // A permanent failure waits for `r`.
        try await store.failRow(m4, errorCode: "http_4xx")
        #expect(try await store.ruleQueueCounts().failed == 1)
        #expect(try await store.run(id: run)?.failed == 1)
        #expect(try await store.claimDueRules(now: now).map(\.key) == [m3])
        let code = try store.readNow { db in try db.first("SELECT error_code FROM rule_queue WHERE message_id = 'm4'") { $0.string(0) } }
        #expect(code == "http_4xx")
        #expect(try await store.requeueFailed() == 1)
        #expect(try await store.run(id: run)?.failed == 0)
        let requeued = try #require(try await store.claimDueRules(now: now).first { $0.key == m4 })
        #expect(requeued.attempts == 0)
    }

    @Test func failedRowsDoNotKeepARunOpen() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let run = try await store.createRun(.backfill, rules: [RunRule(rule.rule)], messageIDs: ["m1"])
        try await store.failRow(QueueKey(messageID: "m1", runID: run), errorCode: "attempts_exhausted")
        var record = try #require(try await store.run(id: run))
        #expect(record.state == .done && record.failed == 1 && record.finishedAt != nil)

        // `r` reopens it.
        try await store.requeueFailed()
        record = try #require(try await store.run(id: run))
        #expect(record.state == .running && record.failed == 0 && record.finishedAt == nil)
        try await store.commitRuleOutcomes([outcome("m1", matching: [rule])], runID: run, simulated: false)
        #expect(try await store.run(id: run)?.state == .done)
    }

    @Test func mailWaitingTooLongForClaudeIsHeldForConfirmation() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let live = try await arrive(store, [
            message("o1", thread: "o1", from: nina, minutesAgo: 5 * 1440), message("n1", thread: "n1", from: nina, minutesAgo: 1),
        ])
        try await store.waitForAI([QueueKey(messageID: "o1", runID: live), QueueKey(messageID: "n1", runID: live)])

        let backlog = try #require(try await store.holdStaleWaiting())
        #expect(try queueRows(store) == [
            QueueRow(messageID: "o1", runID: backlog, priority: 2, state: "held"),
            QueueRow(messageID: "n1", runID: live, priority: 0, state: "waiting_ai"),
        ])
        let record = try #require(try await store.run(id: backlog))
        #expect(record.kind == .backlog && record.state == .awaitingConfirm && record.total == 1 && record.rules == [RunRule(rule.rule)])
        #expect(try await store.run(id: live)?.total == 1)
        #expect(try await store.ruleQueueCounts() == RuleQueueCounts(liveQueued: 0, waitingAI: 1, held: 1, failed: 0))
        // Nothing else is that old.
        #expect(try await store.holdStaleWaiting() == nil)

        #expect(try await store.confirmRun(backlog))
        #expect(try await store.claimDueRules().map(\.key) == [QueueKey(messageID: "o1", runID: backlog)])
        #expect(try await store.run(id: backlog)?.confirmedAt != nil)
        #expect(!(try await store.confirmRun(backlog)))
    }

    @Test func liveMailCountsAsQueuedLive() async throws {
        let store = try await seededStore()
        try await addRule(store)
        _ = try await arrive(store, [message("n1", thread: "n1", from: nina, minutesAgo: 1), message("n2", thread: "n2", from: nina, minutesAgo: 2)])
        #expect(try await store.ruleQueueCounts() == RuleQueueCounts(liveQueued: 2, waitingAI: 0, held: 0, failed: 0))
    }

    // MARK: - Runs

    @Test func runLifecycleAndCounters() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let rules = [RunRule(rule.rule)]
        let window = Date(timeIntervalSince1970: 1_790_000_000)...Date(timeIntervalSince1970: 1_791_000_000)
        let run = try await store.createRun(
            .backfill, rules: rules, messageIDs: ["m1", "m3"], window: window, estimateMicros: 2_000, capMicros: 3_000, model: "claude-haiku-5-5"
        )
        var record = try #require(try await store.run(id: run))
        #expect(record.kind == .backfill && record.state == .running && record.total == 2 && record.rules == rules && record.window == window)
        #expect(record.model == "claude-haiku-5-5" && record.estimateMicros == 2_000 && record.capMicros == 3_000 && record.costMicros == 0)
        #expect(record.plus == nil && record.minus == nil && record.confirmedAt == nil && record.day == nil)

        // Paused at its cap: nothing is claimed.
        #expect(try await store.pauseRun(run, reason: .cap))
        #expect(try await store.run(id: run)?.pauseReason == .cap)
        #expect(try await store.claimDueRules().isEmpty)
        #expect(!(try await store.pauseRun(run, reason: .user)))
        // Continued with a new estimate and cap.
        #expect(try await store.resumeRun(run, estimateMicros: 2_500, capMicros: 3_750))
        record = try #require(try await store.run(id: run))
        #expect(record.state == .running && record.pauseReason == nil && record.estimateMicros == 2_500 && record.capMicros == 3_750)
        #expect(record.model == "claude-haiku-5-5" && record.rules == rules)
        #expect(!(try await store.resumeRun(run)))

        // A call counts as soon as its verdicts are stored; the commit counts the rest.
        try await store.putVerdicts([verdict("m1", "h1")], model: "claude-haiku-5-5", costMicros: 420, runID: run)
        record = try #require(try await store.run(id: run))
        #expect(record.judged == 1 && record.costMicros == 420)
        try await store.commitRuleOutcomes([outcome("m1", matching: [rule]), outcome("m3", notMatching: [rule])], runID: run, simulated: false)
        record = try #require(try await store.run(id: run))
        #expect(record.state == .done && record.done == 2 && record.labeled == 1 && record.finishedAt != nil)
        #expect(!(try await store.cancelRun(run)))

        let later = try await store.createRun(.manual, rules: rules, messageIDs: ["m4"])
        #expect(try await store.runs().map(\.id) == [later, run])
        #expect(try await store.runs(limit: 1).map(\.id) == [later])
        #expect(try await store.runs(unfinished: true).map(\.id) == [later])
    }

    @Test func gapAndBacklogRunsWaitForConfirmation() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let gap = try await store.createRun(.gap, rules: [RunRule(rule.rule)], messageIDs: ["m1", "m3"])
        #expect(try await store.run(id: gap)?.state == .awaitingConfirm)
        #expect(try queueRows(store).map(\.state) == ["held", "held"])
        #expect(try await store.ruleQueueCounts().held == 2)

        // Declined: its rows go.
        #expect(try await store.cancelRun(gap))
        let record = try #require(try await store.run(id: gap))
        #expect(record.state == .cancelled && record.finishedAt != nil)
        #expect(try queueRows(store).isEmpty)
        #expect(!(try await store.confirmRun(gap)))

        // A run with nothing to do is done at once.
        let empty = try await store.createRun(.backfill, rules: [RunRule(rule.rule)], messageIDs: [])
        #expect(try await store.run(id: empty)?.state == .done)
    }

    @Test func ruleEditsPauseRunsAndRemovalsCancelThem() async throws {
        let store = try await seededStore()
        let a = try await addRule(store, name: "A")
        let b = try await addRule(store, name: "B")
        let live = try await arrive(store, [message("n1", thread: "n1", from: nina, minutesAgo: 1)])
        let both = try await store.createRun(.backfill, rules: [RunRule(a.rule), RunRule(b.rule)], messageIDs: ["m1"])
        let onlyA = try await store.createRun(.manual, rules: [RunRule(a.rule)], messageIDs: ["m3"])

        // A new revision pauses the runs that apply the old one. Live mail goes on.
        var edited = a.rule
        edited.when = "from:nina"
        try await store.saveRule(edited)
        #expect(try await store.run(id: both)?.pauseReason == .ruleChanged)
        #expect(try await store.run(id: onlyA)?.state == .paused)
        #expect(try await store.run(id: live)?.state == .running)
        #expect(try await store.rules(at: [RunRule(id: a.id, revision: 1), RunRule(id: a.id, revision: 2), RunRule(id: a.id, revision: 9)]).map(\.when) == ["", "from:nina"])
        // Renaming keeps the revision, and the runs as they are.
        try await store.resumeRun(both)
        var renamed = try #require(try await store.rules().first { $0.id == a.id }).rule
        renamed.name = "Apples"
        try await store.saveRule(renamed)
        #expect(try await store.run(id: both)?.state == .running)

        // Turning a rule off takes it out of its runs; a run left with none is cancelled.
        try await store.setRuleEnabled(id: a.id, false)
        #expect(try await store.run(id: onlyA)?.state == .cancelled)
        #expect(try await store.run(id: both)?.rules == [RunRule(b.rule)])
        #expect(try await store.run(id: live)?.rules.count == 2)
        #expect(Set(try queueRows(store).map(\.runID)) == [live, both])
        // So does deleting one.
        try await store.deleteRule(id: b.id)
        #expect(try await store.run(id: both)?.state == .cancelled)
        #expect(Set(try queueRows(store).map(\.runID)) == [live])

        // A model switch pauses every run but live mail.
        let c = try await addRule(store, name: "C")
        let run = try await store.createRun(.backfill, rules: [RunRule(c.rule)], messageIDs: ["m4"])
        #expect(try await store.pauseRuns(reason: .modelChanged) == [run])
        #expect(try await store.run(id: live)?.state == .running)
        #expect(try await store.pauseRuns(containing: c.id, reason: .user).isEmpty)
    }

    @Test func liveRunsAreNeverCancelled() async throws {
        let store = try await seededStore()
        try await addRule(store)
        let live = try await arrive(store, [message("n1", thread: "n1", from: nina, minutesAgo: 2)])
        #expect(!(try await store.cancelRun(live)))
        #expect(try await store.run(id: live)?.state == .running)
        #expect(try await store.claimDueRules().map(\.key.messageID) == ["n1"])
        await #expect(throws: RuleStoreError.liveRun) {
            try await store.createRun(.live, rules: [], messageIDs: ["m1"])
        }
    }

    @Test func undoingALiveRunKeepsTheMailItHadLeft() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        let live = try await arrive(store, [message("n1", thread: "n1", from: nina, minutesAgo: 3), message("n2", thread: "n2", from: nina, minutesAgo: 2)])
        try await store.commitRuleOutcomes([outcome("n1", matching: [rule])], runID: live, simulated: false)
        try await store.waitForAI([QueueKey(messageID: "n2", runID: live)])

        let undone = try await store.undoRun(live)
        #expect(undone.labelsRemoved == 1)
        #expect(!(try await labels(store, "n1").contains(label)))
        let record = try #require(try await store.run(id: live))
        #expect(record.state == .undone && record.total == 1 && record.done == 1)
        // n2 goes on in a new live run for the day, and so does later mail.
        let next = try #require(try queueRows(store).first).runID
        #expect(next != live)
        #expect(try queueRows(store) == [QueueRow(messageID: "n2", runID: next, priority: 0, state: "waiting_ai")])
        let fresh = try #require(try await store.run(id: next))
        #expect(fresh.kind == .live && fresh.day == record.day && fresh.state == .running && fresh.total == 1)
        #expect(try await store.releaseWaitingAI() == 1)
        #expect(try await arrive(store, [message("n3", thread: "n3", from: nina, minutesAgo: 1)]) == next)
        #expect(Set(try await store.claimDueRules().map(\.key)) == [QueueKey(messageID: "n2", runID: next), QueueKey(messageID: "n3", runID: next)])
        #expect(try await store.run(id: live)?.state == .undone)
        #expect(try await store.undoRun(live) == RevertSummary())
    }

    @Test func editsMakePausedAndWaitingRunsOutOfDate() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let budget = try await store.createRun(.backfill, rules: [RunRule(rule.rule)], messageIDs: ["m1"])
        try await store.pauseRun(budget, reason: .budget)
        let gap = try await store.createRun(.gap, rules: [RunRule(rule.rule)], messageIDs: ["m3"])
        let recheck = try await store.createRun(.recheck, rules: [RunRule(rule.rule)], messageIDs: ["m4"])
        try await store.commitRuleOutcomes([outcome("m4", matching: [rule])], runID: recheck, simulated: false)
        #expect(try await store.run(id: recheck)?.state == .awaitingConfirm)

        var edited = rule.rule
        edited.when = "from:nina"
        let saved = try await store.saveRule(edited)
        let current = [RunRule(saved)]
        for id in [budget, gap, recheck] {
            #expect(try await store.run(id: id)?.pauseReason == .ruleChanged, "\(id)")
        }
        #expect(try await store.run(id: budget)?.state == .paused)
        #expect(try await store.run(id: gap)?.state == .awaitingConfirm)
        // Other reasons leave paused runs as they are.
        #expect(try await store.pauseRuns(reason: .user).isEmpty)
        #expect(try await store.run(id: budget)?.pauseReason == .ruleChanged)

        // Confirmed with the current revision, a new estimate and cap.
        #expect(try await store.confirmRun(gap, rules: current, estimateMicros: 900, capMicros: 1_350, model: "claude-haiku-5-5"))
        let confirmed = try #require(try await store.run(id: gap))
        #expect(confirmed.state == .running && confirmed.pauseReason == nil && confirmed.rules == current)
        #expect(confirmed.estimateMicros == 900 && confirmed.capMicros == 1_350 && confirmed.model == "claude-haiku-5-5" && confirmed.confirmedAt != nil)

        // A re-check confirmed with the new revision counts again before it applies anything.
        #expect(try await store.confirmRun(recheck, rules: current))
        var counting = try #require(try await store.run(id: recheck))
        #expect(counting.state == .running && counting.isDryRun && counting.plus == nil && counting.done == 0 && counting.rules == current)
        #expect(try queueRows(store).first { $0.messageID == "m4" }?.state == "queued")
        try await store.commitRuleOutcomes([outcome("m4", notMatching: [rule])], runID: recheck, simulated: false)
        counting = try #require(try await store.run(id: recheck))
        #expect(counting.state == .awaitingConfirm && counting.pauseReason == nil && counting.plus == 0 && counting.minus == 0)

        // A model switch marks them too; resuming with the new model clears it.
        #expect(Set(try await store.pauseRuns(reason: .modelChanged)) == [budget, gap, recheck])
        #expect(try await store.run(id: recheck)?.pauseReason == .modelChanged)
        #expect(try await store.resumeRun(budget, rules: current, model: "claude-haiku-5-5"))
        #expect(try await store.run(id: budget)?.rules == current)
    }

    @Test func aRunWhoseLastMessageIsDeletedFinishes() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let run = try await store.createRun(.backfill, rules: [RunRule(rule.rule)], messageIDs: ["m1", "m3", "m4"])
        try await store.failRow(QueueKey(messageID: "m4", runID: run), errorCode: "http_4xx")
        try await store.commitRuleOutcomes([outcome("m1", matching: [rule])], runID: run, simulated: false)
        try await store.deleteMessages(["m3", "m4"])
        let record = try #require(try await store.run(id: run))
        #expect(record.state == .done && record.total == 1 && record.done == 1 && record.failed == 0 && record.finishedAt != nil)
        #expect(try await store.runs(unfinished: true).isEmpty)

        // A held run whose messages are all gone is done too.
        let gap = try await store.createRun(.gap, rules: [RunRule(rule.rule)], messageIDs: ["m1"])
        try await store.deleteMessages(["m1"])
        #expect(try await store.run(id: gap)?.state == .done)
    }

    // MARK: - Decisions and verdicts

    @Test func verdictsAreCachedByJudgeHashWithCallCosts() async throws {
        let store = try await seededStore()
        try await store.putVerdicts([verdict("m1", "h1"), verdict("m1", "h2", .noMatch), verdict("m3", "h1", .unsure)], model: "claude-haiku-5-5", costMicros: 100)
        let cached = try await store.verdicts(messageIDs: ["m1", "m3", "m4"], judgeHashes: ["h1"])
        #expect(Set(cached) == [verdict("m1", "h1"), verdict("m3", "h1", .unsure)])
        #expect(try await store.verdicts(messageIDs: ["m1"], judgeHashes: []).isEmpty)
        // Asking again replaces the verdict.
        try await store.putVerdicts([verdict("m1", "h1", .noMatch, reason: "a newsletter")], model: "claude-haiku-5-5", costMicros: 100)
        #expect(try await store.verdicts(messageIDs: ["m1"], judgeHashes: ["h1"]).map(\.reason) == ["a newsletter"])

        // Estimates average the model's last 50 calls.
        for cost in 1...60 {
            try await store.putVerdicts([], model: "claude-opus-5-5", costMicros: Int64(cost * 10))
        }
        #expect(try await store.meanCallCostMicros(model: "claude-opus-5-5") == 355)
        #expect(try await store.meanCallCostMicros(model: "claude-haiku-5-5") == 100)
        #expect(try await store.meanCallCostMicros(model: "claude-sonnet-5-5") == nil)
        #expect(try store.readNow { try $0.scalar("SELECT COUNT(*) FROM rule_call_costs WHERE model = 'claude-opus-5-5'") } == 50)
    }

    @Test func verdictsSurviveACommitThatFails() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let run = try await manualRun(store, [rule], ["m1"])
        try await store.putVerdicts([verdict("m1", "h1")], model: "claude-haiku-5-5", costMicros: 420, runID: run)
        try store.writeNow { db, _ in try db.execute("CREATE TRIGGER fail BEFORE INSERT ON rule_decisions BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        await #expect(throws: SQLiteError.self) {
            try await store.commitRuleOutcomes([outcome("m1", matching: [rule], source: .claude)], runID: run, simulated: false)
        }
        try store.writeNow { db, _ in try db.execute("DROP TRIGGER fail") }

        // The call was paid once: its verdict and cost stay, so the next pass finds it cached.
        #expect(try await store.verdicts(messageIDs: ["m1"], judgeHashes: ["h1"]) == [verdict("m1", "h1")])
        let record = try #require(try await store.run(id: run))
        #expect(record.judged == 1 && record.costMicros == 420 && record.done == 0)
        #expect(try await store.meanCallCostMicros(model: "claude-haiku-5-5") == 420)
        #expect(try queueRows(store).map(\.state) == ["queued"])
    }

    @Test func deletingClaudeResultsKeepsEverythingElse() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        let run = try await manualRun(store, [rule], ["m1", "m3", "m4"])
        try await store.putVerdicts([verdict("m1", "h1")], model: "claude-haiku-5-5", costMicros: 100, runID: run)
        try await store.commitRuleOutcomes(
            [outcome("m1", matching: [rule], source: .claude), outcome("m3", matching: [rule], source: .cache), outcome("m4", notMatching: [rule])],
            runID: run, simulated: false
        )
        try await store.deleteClaudeResults()
        #expect(try await store.verdicts(messageIDs: ["m1"], judgeHashes: ["h1"]).isEmpty)
        let decisions = try await store.decisions(for: ["m1", "m3", "m4"])
        #expect(decisions.keys.sorted() == ["m4"])
        #expect(try ledger(store).count == 2)
        #expect(try await labels(store, "m1").contains(label))
    }

    // MARK: - Facts

    @Test func factsForABatchHaveNoBodies() async throws {
        let store = try await seededStore()
        let receipts = try await addRule(store)
        let label = receipts.rule.labelTargets[0].id
        let travel = try await addRule(store, name: "Travel")
        var newsletter = message("l1", thread: "l1", from: EmailAddress(name: "The Browser", email: "hello@thebrowser.com"), minutesAgo: 50)
        newsletter.listUnsubscribe = "<mailto:leave@thebrowser.com>"
        try await store.upsertMessages([message("m5", thread: "t1", from: alex, subject: "Re: Quarterly budget review", minutesAgo: 10), newsletter])
        let run = try await manualRun(store, [receipts], ["m1"])
        try await store.commitRuleOutcomes([outcome("m1", matching: [receipts])], runID: run, simulated: false)
        try await store.setLabelMarks(messageIDs: ["m1"], labelID: label, present: false)
        try await store.setLabelMarks(messageIDs: ["m5"], labelID: "Label_1", present: true)
        try await store.setExample(ruleID: travel.id, messageID: "m5", matches: false, origin: .preview)
        try await store.setOverride(ruleID: receipts.id, subject: "@studionorth.co", matches: false, origin: .user)
        try await store.setOverride(ruleID: receipts.id, subject: "alex@studionorth.co", matches: true, origin: .user)
        try await store.setOverride(ruleID: travel.id, subject: "@studionorth.co", matches: false, origin: .learned)

        let facts = try await store.messageFacts(["m5", "gone", "m1", "l1"])
        #expect(facts.map(\.messageID) == ["m5", "m1", "l1"])
        let reply = facts[0]
        #expect(reply.threadID == "t1" && reply.from == alex && reply.labelIDs == ["INBOX", "UNREAD"] && !reply.isList)
        #expect(reply.marks == ["Label_1": true])
        #expect(reply.examples == [travel.id: false])
        // The exact address wins over its domain.
        #expect(reply.overrides == [receipts.id: true, travel.id: false])
        #expect(reply.decisions.isEmpty)
        // Receipts matched earlier in the conversation, where you then removed its label.
        #expect(reply.threadMatches == [receipts.id])
        #expect(reply.threadRemovals == [label])

        let first = facts[1]
        #expect(first.decisions[receipts.id]?.decision.verdict == .match && first.decisions[receipts.id]?.runID == run)
        #expect(first.threadMatches.isEmpty)
        #expect(first.marks == [label: false])
        #expect(facts[2].isList && facts[2].overrides.isEmpty && facts[2].threadMatches.isEmpty)
        #expect(try await store.messageFacts([]).isEmpty)
    }

    @Test func judgeInputsLoadTheConversationUpToTheMessage() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([
            message("m5", thread: "t1", from: alex, subject: "Re: Quarterly budget review", body: "One more thing", minutesAgo: 10),
            message("m6", thread: "t1", from: alex, subject: "Re: Quarterly budget review", body: "Later", minutesAgo: 1),
        ])
        let inputs = try #require(try await store.judgeInputs(messageID: "m5"))
        #expect(inputs.message.id == "m5" && inputs.message.textBody == "One more thing")
        #expect(inputs.thread.map(\.id) == ["m1", "m2", "m5"])
        #expect(inputs.thread[1].textBody == "Looks good to me" && inputs.thread[1].labelIDs == ["SENT"])
        let digest = EmailDigest(message: inputs.message, thread: inputs.thread, selfAddresses: store.selfAddresses)
        #expect(digest.isReply && digest.previous?.from == nil && digest.previous?.text == "Looks good to me")
        #expect(try await store.judgeInputs(messageID: "gone") == nil)
    }

    // MARK: - Estimates

    @Test func estimatesCountWhatNeedsClaude() async throws {
        let store = try await seededStore()
        let label = try await store.resolveLabel(name: "receipts")
        let rule = try await store.createRule(Rule(key: "", name: "Receipts", ask: "Receipts for things I bought", then: [.addLabel(LabelRef(id: label.id, lastKnownName: "receipts"))])).rule
        let shop = EmailAddress(name: "Shop", email: "orders@shop.example")
        try await store.upsertMessages([
            message("e1", thread: "e1", from: shop, minutesAgo: 1 * 1440),
            message("e2", thread: "e2", from: shop, minutesAgo: 3 * 1440),
            message("e3", thread: "e3", from: EmailAddress(email: "Billing@Vendor.example"), minutesAgo: 5 * 1440),
            message("e4", thread: "e4", from: nina, minutesAgo: 20 * 1440),
            message("e5", thread: "e5", from: nina, minutesAgo: 40 * 1440),
            message("e6", thread: "e6", from: nina, minutesAgo: 60 * 1440),
            message("s1", thread: "s1", from: me, to: [nina], labels: ["SENT"], minutesAgo: 2 * 1440),
        ])
        // Decided without a call: your mark, an example, a sender override, a cached verdict, a decision at this revision.
        try await store.setLabelMarks(messageIDs: ["e1"], labelID: label.id, present: false)
        try await store.setExample(ruleID: rule.id, messageID: "e2", matches: true, origin: .preview)
        try await store.setOverride(ruleID: rule.id, subject: "@vendor.example", matches: true, origin: .user)
        let hash = try #require(rule.judgeHash(model: "claude-haiku-5-5", effort: "low", promptVersion: 1))
        try await store.putVerdicts([verdict("e4", hash, .noMatch), verdict("e6", "another-ask")], model: "claude-haiku-5-5", costMicros: 0)
        let run = try await store.createRun(.backfill, rules: [RunRule(rule)], messageIDs: ["e5"])
        try await store.commitRuleOutcomes(
            [MessageOutcome(messageID: "e5", decisions: [RuleDecision(ruleID: rule.id, revision: 1, verdict: .noMatch, source: .claude)], matches: [])],
            runID: run, simulated: false
        )
        func date(_ id: String) async throws -> Date { try #require(try await store.message(id: id)).date }

        // Received mail: m1, m3, m4 and e1–e6. m2 and s1 are yours.
        let all = try await store.estimate(rule, window: .allCached, judgeHash: hash)
        #expect(all == RuleEstimate(
            window: nil, inScope: 9, passing: 9, decidedFree: 5, decidedByYou: 3, cachedVerdicts: 1, decidedEarlier: 1, needClaude: 4,
            claudeSpan: try await date("e6")...(try await date("m3"))
        ))
        // Without a judge hash, cached verdicts do not count; nor does a decision at an older revision.
        let uncached = try await store.estimate(rule, window: .allCached, judgeHash: nil)
        #expect(uncached.needClaude == 5 && uncached.cachedVerdicts == 0 && uncached.decidedByYou == 3 && uncached.decidedEarlier == 1)
        var revised = rule
        revised.revision = 2
        #expect(try await store.estimate(revised, window: .allCached, judgeHash: hash).needClaude == 5)

        // The last 14 days.
        let now = Date()
        let recent = try await store.estimate(rule, window: .dates(now.addingTimeInterval(-14 * 86_400)...now), judgeHash: hash)
        #expect(recent.inScope == 6 && recent.passing == 6 && recent.decidedFree == 3 && recent.decidedByYou == 3 && recent.needClaude == 3)
        #expect(recent.window == now.addingTimeInterval(-14 * 86_400)...now)

        // The newest 2 needing Claude reach back to m1; the window covers everything newer.
        let newest = try await store.estimate(rule, window: .newestNeedingClaude(2), judgeHash: hash)
        let m1 = try await date("m1")
        #expect(newest == RuleEstimate(
            window: m1...Date.distantFuture, inScope: 2, passing: 2, decidedFree: 0, decidedByYou: 0, cachedVerdicts: 0, decidedEarlier: 0, needClaude: 2,
            claudeSpan: m1...(try await date("m3"))
        ))
        #expect(try await store.ruleMatches(try RuleFilter.parse(rule.when), scope: .received, window: newest.window) == ["m3", "m1"])
        // Fewer need Claude than asked: all stored mail.
        #expect(try await store.estimate(rule, window: .newestNeedingClaude(100), judgeHash: hash) == all)

        // WHEN counts, label terms included.
        var work = rule
        work.when = "label:work"
        let labelled = try await store.estimate(work, window: .allCached, judgeHash: hash)
        #expect(labelled.inScope == 9 && labelled.passing == 1 && labelled.needClaude == 1)
        var notNina = rule
        notNina.when = "-from:nina"
        let others = try await store.estimate(notNina, window: .allCached, judgeHash: hash)
        #expect(others.passing == 5 && others.decidedFree == 3 && others.needClaude == 2)

        // A rule without an ASK needs no call.
        var filter = rule
        filter.ask = nil
        filter.when = "from:shop"
        #expect(try await store.estimate(filter, window: .newestNeedingClaude(100), judgeHash: nil)
            == RuleEstimate(window: nil, inScope: 9, passing: 2, decidedFree: 2, decidedByYou: 0, cachedVerdicts: 0, decidedEarlier: 0, needClaude: 0, claudeSpan: nil))

        // A WHEN rules cannot use is an error.
        var invalid = rule
        invalid.when = "is:unread"
        await #expect(throws: RuleFilter.Problem.self) { try await store.estimate(invalid, window: .allCached, judgeHash: nil) }
    }

    // MARK: - Retention

    @Test func pruningKeepsWhatUndoAndLabelsStillNeed() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        let old = try await manualRun(store, [rule], ["m1", "m3"])
        try await store.commitRuleOutcomes([outcome("m1", matching: [rule]), outcome("m3", matching: [rule])], runID: old, simulated: false)
        try await store.revertLedger(.rows([try ledger(store)[1].id]), reason: .undo)
        let recent = try await manualRun(store, [rule], ["m4"])
        try await store.commitRuleOutcomes([outcome("m4", matching: [rule])], runID: recent, simulated: false)
        try await store.undoRun(recent)
        let fresh = try await manualRun(store, [rule], ["m3"])
        try await store.commitRuleOutcomes([outcome("m3", matching: [rule])], runID: fresh, simulated: false)
        try await store.revertLedger(.run(fresh), reason: .undo)

        let now = Date()
        let longAgo = now.addingTimeInterval(-100 * 86_400)
        try store.writeNow { db, _ in
            try db.run("UPDATE rule_runs SET created_at = ?, finished_at = ? WHERE id = ?", [longAgo, longAgo, old])
            try db.run("UPDATE rule_ledger SET reverted_at = ? WHERE run_id IN (?, ?) AND reverted_at IS NOT NULL", [longAgo, old, recent])
        }
        try await store.pruneRuleHistory(now: now, judgeHashesInUse: [])
        #expect(Set(try await store.runs().map(\.id)) == [recent, fresh])
        // m1's label is still the rule's: its row stays though its run is gone. Old reverted rows go.
        let rows = try ledger(store)
        #expect(rows.map(\.messageID) == ["m1", "m3"])
        #expect(rows.map(\.revertedBy) == [nil, "undo"])
        #expect(try await labels(store, "m1").contains(label))
        #expect(try await store.explain(threadID: "t1").labels.first?.owners.first?.runKind == nil)
    }

    @Test func verdictsAtUnusedJudgeHashesGoAfterThirtyDays() async throws {
        let store = try await seededStore()
        try await store.putVerdicts([verdict("m1", "current"), verdict("m1", "old"), verdict("m3", "old"), verdict("m3", "restored")], model: "claude-haiku-5-5", costMicros: 0)
        func hashes() async throws -> Set<String> {
            Set(try await store.verdicts(messageIDs: ["m1", "m3"], judgeHashes: ["current", "old", "restored"]).map(\.judgeHash))
        }
        let day: TimeInterval = 86_400
        let now = Date()
        // Noticed unused now: kept for 30 days.
        try await store.pruneRuleHistory(now: now, judgeHashesInUse: ["current"])
        #expect(try await hashes() == ["current", "old", "restored"])
        // Restoring an earlier ASK uses its hash again.
        try await store.pruneRuleHistory(now: now.addingTimeInterval(20 * day), judgeHashesInUse: ["current", "restored"])
        try await store.pruneRuleHistory(now: now.addingTimeInterval(29 * day), judgeHashesInUse: ["current"])
        #expect(try await hashes() == ["current", "old", "restored"])
        try await store.pruneRuleHistory(now: now.addingTimeInterval(31 * day), judgeHashesInUse: ["current"])
        #expect(try await hashes() == ["current", "restored"])
        try await store.pruneRuleHistory(now: now.addingTimeInterval(51 * day), judgeHashesInUse: ["current"])
        #expect(try await hashes() == ["current"])
    }
}
