import Foundation
import Testing
@testable import MailCore
@testable import MailStore

/// Adds an enabled rule that adds an existing label.
@discardableResult
func addRule(_ store: MailStore, name: String, labelID: String, when: String = "", ask: String? = nil) async throws -> RuleRecord {
    try await store.createRule(Rule(key: "", name: name, when: when, ask: ask, then: [.addLabel(LabelRef(id: labelID, lastKnownName: name.lowercased()))]))
}

/// A pass over `messageID` where `matching` rules match, in order, and `notMatching` rules do not.
func outcome(_ messageID: String, matching: [RuleRecord] = [], notMatching: [RuleRecord] = [], source: DecisionSource = .gate) -> MessageOutcome {
    MessageOutcome(
        messageID: messageID,
        decisions: matching.map { RuleDecision(ruleID: $0.id, revision: $0.rule.revision, verdict: .match, source: source) }
            + notMatching.map { RuleDecision(ruleID: $0.id, revision: $0.rule.revision, verdict: .noMatch, source: source) },
        matches: matching.flatMap { record in
            record.rule.labelTargets.map { RuleMatch(ruleID: record.id, revision: record.rule.revision, labelID: $0.id) }
        }
    )
}

func manualRun(_ store: MailStore, _ rules: [RuleRecord], _ messageIDs: [String]) async throws -> Int64 {
    try await store.createRun(.manual, rules: rules.map { RunRule($0.rule) }, messageIDs: messageIDs)
}

struct LedgerEntry: Hashable {
    var id: Int64 = 0
    var ruleID: String
    var messageID: String
    var target: String
    var changed: Bool
    var outboxID: Int64?
    var simulated = false
    var revertedBy: String?
}

func ledger(_ store: MailStore) throws -> [LedgerEntry] {
    try store.readNow { db in
        try db.query("SELECT id, rule_id, message_id, target, changed, outbox_id, simulated, reverted_by FROM rule_ledger ORDER BY id") {
            LedgerEntry(
                id: $0.int64(0), ruleID: $0.string(1), messageID: $0.string(2), target: $0.string(3), changed: $0.bool(4),
                outboxID: $0.isNull(5) ? nil : $0.int64(5), simulated: $0.bool(6), revertedBy: $0.optionalString(7)
            )
        }
    }
}

func labels(_ store: MailStore, _ messageID: String) async throws -> Set<String> {
    try #require(try await store.message(id: messageID)).labelIDs
}

@Suite("Rule ledger")
struct RuleLedgerTests {
    // MARK: - Commit

    @Test func commitAddsLabelsTheRuleOwns() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        let run = try await manualRun(store, [rule], ["m1", "m3"])
        let box = ChangeBox()
        store.observe { box.append($0) }

        let summary = try await store.commitRuleOutcomes([outcome("m1", matching: [rule]), outcome("m3", notMatching: [rule])], runID: run, simulated: false)
        #expect(summary.messages == 2 && summary.labelsAdded == 1 && summary.coOwned == 0 && summary.syncedChanges == 0)
        #expect(try await labels(store, "m1").contains(label))
        #expect(!(try await labels(store, "m3").contains(label)))
        #expect(try ledger(store).map { LedgerEntry(ruleID: $0.ruleID, messageID: $0.messageID, target: $0.target, changed: $0.changed) }
            == [LedgerEntry(ruleID: rule.id, messageID: "m1", target: label, changed: true)])
        let decisions = try await store.decisions(for: ["m1", "m3"])
        #expect(decisions["m1"]?[rule.id]?.decision == RuleDecision(ruleID: rule.id, revision: 1, verdict: .match, source: .gate))
        #expect(decisions["m3"]?[rule.id]?.decision.verdict == .noMatch)
        #expect(decisions["m1"]?[rule.id]?.runID == run)
        #expect(try queueRows(store).isEmpty)
        let record = try #require(try await store.run(id: run))
        #expect(record.state == .done && record.total == 2 && record.done == 2 && record.labeled == 1 && record.finishedAt != nil)
        #expect(try await store.outboxCount() == 0)
        // The list shows the label, and observers heard once.
        #expect(try await store.threadSummary(id: "t1")?.labelIDs.contains(label) == true)
        #expect(box.changes.count == 1 && box.changes.first?.threadIDs == ["t1"])
    }

    @Test func liveCommitsMoveTheWatermarkForward() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        _ = try await store.applyRemoteChanges(
            ChangeSet(cursor: "2", upserted: [message("n1", thread: "n1", from: nina, minutesAgo: 1), message("n2", thread: "n2", from: nina, minutesAgo: 3)]),
            cursor: "2", intake: .live(arrived: ["n1", "n2"])
        )
        let live = try #require(try runRows(store).first).id
        func millis(_ id: String) async throws -> String {
            String(Int64((try #require(try await store.message(id: id)).date.timeIntervalSince1970 * 1000).rounded()))
        }

        try await store.commitRuleOutcomes([outcome("n1", matching: [rule])], runID: live, simulated: false)
        #expect(try await store.meta("rules_live_watermark") == (try await millis("n1")))
        // An older message does not move it back.
        try await store.commitRuleOutcomes([outcome("n2", matching: [rule])], runID: live, simulated: false)
        #expect(try await store.meta("rules_live_watermark") == (try await millis("n1")))
        // Today's live run stays open for later arrivals.
        #expect(try await store.run(id: live)?.state == .running)
        // Other runs leave it alone.
        try await store.setMeta("rules_live_watermark", "5")
        let run = try await manualRun(store, [rule], ["m3"])
        try await store.commitRuleOutcomes([outcome("m3", matching: [rule])], runID: run, simulated: false)
        #expect(try await store.meta("rules_live_watermark") == "5")
    }

    @Test func aLabelYouAlreadyHadStaysYours() async throws {
        let store = try await seededStore()
        let work = try await addRule(store, name: "Work", labelID: "Label_1")
        let run = try await manualRun(store, [work], ["m4", "m3"])
        let summary = try await store.commitRuleOutcomes([outcome("m4", matching: [work]), outcome("m3", matching: [work])], runID: run, simulated: false)
        // m4 had the label: the decision is recorded, no ledger row. m3 gets it from the rule.
        #expect(summary.labelsAdded == 1 && summary.coOwned == 0)
        #expect(try ledger(store).map(\.messageID) == ["m3"])
        #expect(try await store.decisions(for: ["m4"])["m4"]?[work.id]?.decision.verdict == .match)

        // Undo removes only what the rule added.
        let undone = try await store.undoRun(run)
        #expect(undone.rows == 1 && undone.labelsRemoved == 1)
        #expect(try await labels(store, "m4").contains("Label_1"))
        #expect(!(try await labels(store, "m3").contains("Label_1")))
    }

    @Test func rulesWithTheSameLabelCoOwnIt() async throws {
        let store = try await seededStore()
        let receipts = try await addRule(store)
        let label = receipts.rule.labelTargets[0].id
        let bills = try await addRule(store, name: "Bills", labelID: label)
        let run = try await manualRun(store, [receipts, bills], ["m1"])
        let summary = try await store.commitRuleOutcomes([outcome("m1", matching: [receipts, bills])], runID: run, simulated: false)
        #expect(summary.labelsAdded == 1 && summary.coOwned == 1)
        #expect(try ledger(store).map { [$0.ruleID, String($0.changed)] } == [[receipts.id, "true"], [bills.id, "false"]])

        // A later run's match co-owns it too, and the label goes only with its last owner.
        let travel = try await addRule(store, name: "Travel", labelID: label)
        let later = try await manualRun(store, [travel], ["m1"])
        #expect(try await store.commitRuleOutcomes([outcome("m1", matching: [travel])], runID: later, simulated: false).coOwned == 1)
        #expect(try await store.revertLedger(.rule(receipts.id), reason: .undo).labelsRemoved == 0)
        #expect(try await store.undoRun(run).labelsRemoved == 0)
        #expect(try await labels(store, "m1").contains(label))
        let last = try await store.undoRun(later)
        #expect(last.rows == 1 && last.labelsRemoved == 1)
        #expect(!(try await labels(store, "m1").contains(label)))
    }

    @Test func committingTwiceChangesNothing() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let run = try await manualRun(store, [rule], ["m1", "m3"])
        let outcomes = [outcome("m1", matching: [rule]), outcome("m3", notMatching: [rule])]
        try await store.commitRuleOutcomes(outcomes, runID: run, simulated: false)
        let before = (try ledger(store), try await store.decisions(for: ["m1", "m3"]), try await store.run(id: run))

        #expect(try await store.commitRuleOutcomes(outcomes, runID: run, simulated: false) == RuleCommitSummary())
        #expect(try ledger(store) == before.0)
        #expect(try await store.decisions(for: ["m1", "m3"]) == before.1)
        #expect(try await store.run(id: run) == before.2)

        // Another run deciding the same again adds no second row; its decision replaces the first.
        let again = try await manualRun(store, [rule], ["m1"])
        let summary = try await store.commitRuleOutcomes([outcome("m1", matching: [rule])], runID: again, simulated: false)
        #expect(summary.messages == 1 && summary.labelsAdded == 0 && summary.coOwned == 0)
        #expect(try ledger(store) == before.0)
        #expect(try await store.decisions(for: ["m1"])["m1"]?[rule.id]?.runID == again)
    }

    @Test func aPassWaitingForClaudeCommitsWhatItDecided() async throws {
        let store = try await seededStore()
        let work = try await addRule(store, name: "Work", labelID: "Label_1")
        let receiptsLabel = try await store.resolveLabel(name: "receipts")
        let receipts = try await addRule(store, name: "Receipts", labelID: receiptsLabel.id, ask: "Receipts for things I bought")
        let live = try await arrive(store, [message("n1", thread: "n1", from: nina, minutesAgo: 2), message("n2", thread: "n2", from: nina, minutesAgo: 1)])
        let workOnly = { (id: String) in
            MessageOutcome(
                messageID: id, decisions: [RuleDecision(ruleID: work.id, revision: 1, verdict: .match, source: .gate)],
                matches: [RuleMatch(ruleID: work.id, revision: 1, labelID: "Label_1")], waitsForAI: true
            )
        }
        // Claude is unavailable: n1 was set waiting first, n2 is still queued. The filter rule applies to both.
        try await store.waitForAI([QueueKey(messageID: "n1", runID: live)])
        let partial = try await store.commitRuleOutcomes([workOnly("n1"), workOnly("n2")], runID: live, simulated: false)
        #expect(partial.messages == 0 && partial.waitingAI == 2 && partial.labelsAdded == 2 && partial.syncedChanges == 1)
        #expect(try await labels(store, "n1").contains("Label_1"))
        #expect(try await labels(store, "n2").contains("Label_1"))
        #expect(try queueRows(store).map(\.state) == ["waiting_ai", "waiting_ai"])
        #expect(try await store.decisions(for: ["n1"])["n1"]?.keys.sorted() == [work.id])
        var record = try #require(try await store.run(id: live))
        #expect(record.done == 0 && record.labeled == 2)
        #expect(try await store.claimDueRules().isEmpty)
        #expect(try await store.meta("rules_live_watermark") == nil)

        // Claude is back: the rest is decided, and the message counts once.
        #expect(try await store.releaseWaitingAI() == 2)
        let whole = MessageOutcome(
            messageID: "n1",
            decisions: [
                RuleDecision(ruleID: work.id, revision: 1, verdict: .match, source: .gate),
                RuleDecision(ruleID: receipts.id, revision: 1, verdict: .match, source: .claude, judgeHash: "h1"),
            ],
            matches: [RuleMatch(ruleID: work.id, revision: 1, labelID: "Label_1"), RuleMatch(ruleID: receipts.id, revision: 1, labelID: receiptsLabel.id)]
        )
        let rest = try await store.commitRuleOutcomes([whole], runID: live, simulated: false)
        #expect(rest.messages == 1 && rest.waitingAI == 0 && rest.labelsAdded == 1 && rest.coOwned == 0)
        #expect(try await labels(store, "n1").isSuperset(of: ["Label_1", receiptsLabel.id]))
        #expect(try ledger(store).filter { $0.messageID == "n1" }.map(\.ruleID) == [work.id, receipts.id])
        #expect(try queueRows(store).map(\.messageID) == ["n2"])
        record = try #require(try await store.run(id: live))
        #expect(record.done == 1 && record.labeled == 2)
        #expect(try await store.meta("rules_live_watermark") != nil)

        // A re-check's first pass counts a message only once every rule is decided.
        let recheck = try await store.createRun(.recheck, rules: [RunRule(work.rule)], messageIDs: ["m1"])
        let counted = try await store.commitRuleOutcomes([workOnly("m1")], runID: recheck, simulated: false)
        #expect(counted.waitingAI == 1 && counted.messages == 0)
        let waiting = try #require(try await store.run(id: recheck))
        #expect(waiting.state == .running && waiting.plus == 0 && waiting.minus == 0 && waiting.done == 0)
        #expect(try queueRows(store).first { $0.runID == recheck }?.state == "waiting_ai")
    }

    @Test func rulesDeletedOrTurnedOffDuringAPassApplyNothing() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        let live = try await arrive(store, [message("n1", thread: "n1", from: nina, minutesAgo: 1)])
        #expect(try await store.claimDueRules().map(\.key.messageID) == ["n1"])
        // Deleted while its pass is in flight.
        try await store.deleteRuleEffects(ruleID: rule.id, removeLabels: true)
        try await store.deleteRule(id: rule.id)
        let summary = try await store.commitRuleOutcomes([outcome("n1", matching: [rule])], runID: live, simulated: false)
        #expect(summary.messages == 1 && summary.labelsAdded == 0)
        #expect(!(try await labels(store, "n1").contains(label)))
        #expect(try ledger(store).isEmpty)
        #expect(try await store.decisions(for: ["n1"]).isEmpty)
        #expect(try await store.removableLabelCount(ruleID: rule.id) == 0)

        // Turned off, and so taken out of the run: the rules left still apply.
        let work = try await addRule(store, name: "Work", labelID: "Label_1")
        let bills = try await addRule(store, name: "Bills")
        let run = try await manualRun(store, [work, bills], ["m1"])
        try await store.setRuleEnabled(id: bills.id, false)
        let applied = try await store.commitRuleOutcomes([outcome("m1", matching: [work, bills])], runID: run, simulated: false)
        #expect(applied.labelsAdded == 1)
        #expect(try ledger(store).map(\.ruleID) == [work.id])
        #expect(try await store.decisions(for: ["m1"])["m1"]?.keys.sorted() == [work.id])
    }

    @Test(arguments: ["rule_ledger", "rule_decisions", "outbox", "rule_runs", "message_labels"])
    func commitIsAllOrNothing(_ failingTable: String) async throws {
        let store = try await seededStore()
        let work = try await addRule(store, name: "Work", labelID: "Label_1")
        let receipts = try await addRule(store)
        let label = receipts.rule.labelTargets[0].id
        let run = try await manualRun(store, [work, receipts], ["m1", "m3"])
        try store.writeNow { db, _ in
            let event = failingTable == "rule_runs" ? "UPDATE" : "INSERT"
            try db.execute("CREATE TRIGGER fail BEFORE \(event) ON \(failingTable) BEGIN SELECT RAISE(ABORT, 'injected'); END")
        }
        let outcomes = [outcome("m1", matching: [work, receipts]), outcome("m3", matching: [work, receipts])]
        await #expect(throws: SQLiteError.self) {
            try await store.commitRuleOutcomes(outcomes, runID: run, simulated: false)
        }
        try store.writeNow { db, _ in try db.execute("DROP TRIGGER fail") }

        for id in ["m1", "m3"] {
            #expect(try await labels(store, id).isDisjoint(with: ["Label_1", label]), "\(id)")
        }
        #expect(try ledger(store).isEmpty)
        #expect(try await store.decisions(for: ["m1", "m3"]).isEmpty)
        #expect(try queueRows(store).map(\.state) == ["queued", "queued"])
        #expect(try await store.outboxCount() == 0)
        #expect(try await store.run(id: run)?.done == 0)

        // Once the fault is gone, the same outcomes commit.
        #expect(try await store.commitRuleOutcomes(outcomes, runID: run, simulated: false).messages == 2)
    }

    @Test func largeCommitsTakeSeveralTransactionsAndNotifyOnce() async throws {
        let store = try await seededStore()
        let work = try await addRule(store, name: "Work", labelID: "Label_1")
        let ids = (0..<30).map { "b\($0)" }
        try await store.upsertMessages(ids.map { message($0, thread: $0, from: nina, minutesAgo: 60) })
        let run = try await manualRun(store, [work], ids)
        let box = ChangeBox()
        store.observe { box.append($0) }

        let summary = try await store.commitRuleOutcomes(ids.map { outcome($0, matching: [work]) }, runID: run, simulated: false)
        #expect(summary.messages == 30 && summary.labelsAdded == 30)
        // One Gmail change per label and transaction of at most 25 messages.
        #expect(summary.syncedChanges == 2)
        let sizes = try await store.outboxItems().map { item -> Int in
            guard case .modifyLabels(let delta) = item.operation else { return 0 }
            return delta.messageIDs.count
        }
        #expect(sizes == [25, 5])
        #expect(box.changes.count == 1 && box.changes.first?.threadIDs.count == 30)
        #expect(try await store.run(id: run)?.state == .done)
    }

    // MARK: - Gmail labels

    @Test func gmailLabelsGoThroughTheOutboxAndUndoCancelsThem() async throws {
        let store = try await seededStore()
        let work = try await addRule(store, name: "Work", labelID: "Label_1")
        let run = try await manualRun(store, [work], ["m1", "m3"])
        let summary = try await store.commitRuleOutcomes([outcome("m1", matching: [work]), outcome("m3", matching: [work])], runID: run, simulated: false)
        #expect(summary.syncedChanges == 1)
        let items = try await store.outboxItems()
        #expect(items.map(\.operation) == [.modifyLabels(LabelDelta(messageIDs: ["m1", "m3"], add: ["Label_1"]))])
        let rows = try ledger(store)
        #expect(rows.map(\.outboxID) == [items[0].id, items[0].id])
        #expect(rows.allSatisfy { !$0.simulated })

        // Undoing one label while the change waits takes its message out of it.
        let one = try await store.revertLedger(.rows([rows[0].id]), reason: .undo)
        #expect(one.labelsRemoved == 1 && one.syncedChanges == 1)
        #expect(try await store.outboxItems().map(\.operation) == [.modifyLabels(LabelDelta(messageIDs: ["m3"], add: ["Label_1"]))])
        // Undoing the rest cancels it.
        #expect(try await store.undoRun(run).syncedChanges == 1)
        #expect(try await store.outboxCount() == 0)
        #expect(try await labels(store, "m1").union(try await labels(store, "m3")).isDisjoint(with: ["Label_1"]))
    }

    @Test(arguments: [false, true])
    func undoAfterGmailHasTheLabelQueuesTheInverse(_ inFlight: Bool) async throws {
        let store = try await seededStore()
        let work = try await addRule(store, name: "Work", labelID: "Label_1")
        let run = try await manualRun(store, [work], ["m1", "m3"])
        try await store.commitRuleOutcomes([outcome("m1", matching: [work]), outcome("m3", matching: [work])], runID: run, simulated: false)
        let item = try #require(try await store.claimNextOutboxItem())
        if !inFlight { try await store.completeOutboxItem(item.id) }

        let undone = try await store.undoRun(run)
        #expect(undone.labelsRemoved == 2 && undone.syncedChanges == 1)
        let operations = try await store.outboxItems().map(\.operation)
        let inverse = OutboxOperation.modifyLabels(LabelDelta(messageIDs: ["m1", "m3"], remove: ["Label_1"]))
        #expect(operations == (inFlight ? [item.operation, inverse] : [inverse]))
    }

    @Test func gmailRefusingAChangeSparesMessagesUndoTookOutOfIt() async throws {
        let store = try await seededStore()
        let work = try await addRule(store, name: "Work", labelID: "Label_1")
        let other = try await addRule(store, name: "Other", labelID: "Label_1")
        let run = try await manualRun(store, [work], ["m1", "m3"])
        try await store.commitRuleOutcomes([outcome("m1", matching: [work]), outcome("m3", matching: [work])], runID: run, simulated: false)
        let first = try #require(try await store.outboxItems().first).id
        // Undone on m1 while the change waits; then another rule adds the label to m1 again.
        try await store.revertLedger(.rows([try ledger(store)[0].id]), reason: .undo)
        let later = try await manualRun(store, [other], ["m1"])
        try await store.commitRuleOutcomes([outcome("m1", matching: [other])], runID: later, simulated: false)
        #expect(try await store.outboxItems().count == 2)

        // Gmail refuses the first change, which by then carries m3 only.
        #expect(try await store.ruleOutboxRejected(first) == 1)
        #expect(try await labels(store, "m1").contains("Label_1"))
        #expect(!(try await labels(store, "m3").contains("Label_1")))
        #expect(try ledger(store).map { [$0.ruleID, $0.messageID, $0.revertedBy ?? "active"] } == [
            [work.id, "m1", "undo"], [work.id, "m3", "gmail_rejected"], [other.id, "m1", "active"],
        ])
    }

    @Test func dryRunProvidersMarkSyncedEffectsSimulated() async throws {
        let store = try await seededStore()
        let work = try await addRule(store, name: "Work", labelID: "Label_1")
        let receipts = try await addRule(store)
        let run = try await manualRun(store, [work, receipts], ["m1"])
        try await store.commitRuleOutcomes([outcome("m1", matching: [work, receipts])], runID: run, simulated: true)
        let rows = try ledger(store)
        #expect(rows.map(\.simulated) == [true, false])
        #expect(rows[0].outboxID != nil && rows[1].outboxID == nil)
    }

    // MARK: - Labels that are gone, your marks

    @Test func aVanishedLabelTurnsItsRulesOffAndIsNeverCreated() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        let other = try await addRule(store, name: "Bills", labelID: label)
        let run = try await manualRun(store, [rule], ["m1"])
        // Gone between the pass and its commit.
        try store.writeNow { db, _ in try db.run("DELETE FROM labels WHERE id = ?", [label]) }

        let summary = try await store.commitRuleOutcomes([outcome("m1", matching: [rule])], runID: run, simulated: false)
        #expect(summary.messages == 1 && summary.labelsAdded == 0)
        #expect(summary.labelMissing == [rule.id, other.id])
        #expect(!(try await labels(store, "m1").contains(label)))
        #expect(!(try await store.labels().contains { $0.id == label }))
        #expect(try await store.rules().allSatisfy { $0.state == .labelMissing && !$0.rule.enabled })
        #expect(try ledger(store).isEmpty)
        #expect(try await store.decisions(for: ["m1"])["m1"]?[rule.id]?.decision.verdict == .match)
    }

    @Test func yourMarksBindEveryRule() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        // You removed it from m1: no rule adds it back there.
        try await store.setLabelMarks(messageIDs: ["m1"], labelID: label, present: false)
        let run = try await manualRun(store, [rule], ["m1", "m3"])
        let summary = try await store.commitRuleOutcomes([outcome("m1", matching: [rule]), outcome("m3", matching: [rule])], runID: run, simulated: false)
        #expect(summary.labelsAdded == 1)
        #expect(!(try await labels(store, "m1").contains(label)))
        #expect(try await labels(store, "m3").contains(label))

        // You added it to m3 as well: undo leaves it.
        try await store.setLabelMarks(messageIDs: ["m3"], labelID: label, present: true)
        let undone = try await store.undoRun(run)
        #expect(undone.rows == 1 && undone.labelsRemoved == 0)
        #expect(try await labels(store, "m3").contains(label))
        #expect(try ledger(store).map(\.revertedBy) == ["undo"])
    }

    @Test func removingARuleLabelYourselfEndsItsOwnershipUntilYouUndo() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        let run = try await manualRun(store, [rule], ["m1"])
        try await store.commitRuleOutcomes([outcome("m1", matching: [rule])], runID: run, simulated: false)

        // You remove it; then rules hear about it. Nothing more is removed.
        let removal = try await store.apply(LocalMutation(deltas: [PlannedDelta(LabelDelta(messageIDs: ["m1"], remove: [label]), syncs: false)]))
        #expect(try await store.setLabelMarks(messageIDs: ["m1"], labelID: label, present: false, undoKey: "edit-1") == 1)
        #expect(try ledger(store).map(\.revertedBy) == ["user"])
        let mark = try #require(try await store.labelMarks(messageIDs: ["m1"]).first)
        #expect(!mark.present && mark.undoKey == "edit-1" && mark.labelID == label)

        // Undoing your removal brings the label back, and the rule owns it again.
        try await store.revert(removal)
        try await store.deleteMarksAndExamples(undoKey: "edit-1")
        #expect(try ledger(store).map(\.revertedBy) == [nil])
        #expect(try await store.labelMarks(messageIDs: ["m1"]).isEmpty)
        try await store.undoRun(run)
        #expect(!(try await labels(store, "m1").contains(label)))
    }

    // MARK: - Undo and delete

    @Test func undoKeepsDecisionsAndStopsTheRun() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let run = try await manualRun(store, [rule], ["m1", "m3"])
        try await store.commitRuleOutcomes([outcome("m1", matching: [rule])], runID: run, simulated: false)

        let undone = try await store.undoRun(run)
        #expect(undone.rows == 1 && undone.labelsRemoved == 1)
        let record = try #require(try await store.run(id: run))
        #expect(record.state == .undone && record.finishedAt != nil)
        // Decisions stay, so live processing does not add the label again.
        #expect(try await store.decisions(for: ["m1"])["m1"]?[rule.id]?.decision.verdict == .match)
        // Work it had left is gone: a late commit applies nothing.
        #expect(try queueRows(store).isEmpty)
        #expect(try await store.commitRuleOutcomes([outcome("m3", matching: [rule])], runID: run, simulated: false).messages == 0)
        #expect(try await store.undoRun(run) == RevertSummary())
    }

    @Test func deletingARuleRemovesOnlyTheLabelsItAloneAdded() async throws {
        let store = try await seededStore()
        let receipts = try await addRule(store)
        let label = receipts.rule.labelTargets[0].id
        let bills = try await addRule(store, name: "Bills", labelID: label)
        let run = try await manualRun(store, [receipts, bills], ["m1", "m3", "m4"])
        try await store.commitRuleOutcomes(
            [outcome("m1", matching: [receipts]), outcome("m3", matching: [receipts, bills]), outcome("m4", matching: [receipts])], runID: run, simulated: false
        )
        // You added it to m4 as well.
        try await store.setLabelMarks(messageIDs: ["m4"], labelID: label, present: true)
        #expect(try await store.removableLabelCount(ruleID: receipts.id) == 1)

        let removed = try await store.deleteRuleEffects(ruleID: receipts.id, removeLabels: true)
        #expect(removed.rows == 3 && removed.labelsRemoved == 1)
        try await store.deleteRule(id: receipts.id)
        #expect(!(try await labels(store, "m1").contains(label)))
        #expect(try await labels(store, "m3").intersection(try await labels(store, "m4")).contains(label))
        let decisions = try await store.decisions(for: ["m1", "m3", "m4"])
        #expect(decisions.values.allSatisfy { $0[receipts.id] == nil })
        #expect(decisions["m3"]?[bills.id] != nil)

        // Deleting without removing: the labels stay, as yours.
        #expect(try await store.removableLabelCount(ruleID: bills.id) == 1)
        try await store.deleteRule(id: bills.id)
        #expect(try await labels(store, "m3").contains(label))
        #expect(try ledger(store).allSatisfy { $0.revertedBy != nil })
        #expect(try ledger(store).filter { $0.ruleID == bills.id }.map(\.revertedBy) == ["rule_deleted"])
    }

    @Test func deleteRuleEffectsCanKeepTheLabels() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        let run = try await manualRun(store, [rule], ["m1"])
        try await store.commitRuleOutcomes([outcome("m1", matching: [rule])], runID: run, simulated: false)
        let kept = try await store.deleteRuleEffects(ruleID: rule.id, removeLabels: false)
        #expect(kept.rows == 1 && kept.labelsRemoved == 0)
        #expect(try await labels(store, "m1").contains(label))
        #expect(try ledger(store).map(\.revertedBy) == ["rule_deleted"])
    }

    // MARK: - Re-check

    @Test func aRecheckCountsFirstAndAppliesOnceConfirmed() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        let first = try await manualRun(store, [rule], ["m1", "m3"])
        try await store.commitRuleOutcomes([outcome("m1", matching: [rule]), outcome("m3", matching: [rule])], runID: first, simulated: false)

        let recheck = try await store.createRun(.recheck, rules: [RunRule(rule.rule)], messageIDs: ["m1", "m3", "m4"])
        let outcomes = [outcome("m1", notMatching: [rule], source: .claude), outcome("m3", matching: [rule]), outcome("m4", matching: [rule])]
        let preview = try await store.commitRuleOutcomes(outcomes, runID: recheck, simulated: false)
        #expect(preview.plus == 1 && preview.minus == 1 && preview.messages == 3)
        #expect(preview.labelsAdded == 0 && preview.labelsRemoved == 0)
        // Nothing changed yet.
        #expect(try await labels(store, "m1").contains(label))
        #expect(!(try await labels(store, "m4").contains(label)))
        #expect(try await store.decisions(for: ["m1"])["m1"]?[rule.id]?.runID == first)
        let waiting = try #require(try await store.run(id: recheck))
        #expect(waiting.state == .awaitingConfirm && waiting.plus == 1 && waiting.minus == 1 && waiting.isDryRun)
        #expect(try queueRows(store).allSatisfy { $0.state == "held" })
        #expect(try await store.claimDueRules().isEmpty)

        #expect(try await store.confirmRun(recheck))
        #expect(try await store.claimDueRules().count == 3)
        let applied = try await store.commitRuleOutcomes(outcomes, runID: recheck, simulated: false)
        #expect(applied.labelsAdded == 1 && applied.labelsRemoved == 1)
        #expect(!(try await labels(store, "m1").contains(label)))
        #expect(try await labels(store, "m3").intersection(try await labels(store, "m4")).contains(label))
        #expect(try ledger(store).filter { $0.messageID == "m1" }.map(\.revertedBy) == ["recheck"])
        let done = try #require(try await store.run(id: recheck))
        #expect(done.state == .done && done.done == 3 && done.labeled == 1 && done.plus == 1 && done.minus == 1 && done.confirmedAt != nil)
    }

    // MARK: - Explain

    @Test func explainSaysWhoAddedEachLabelAndWhy() async throws {
        let store = try await seededStore()
        let receipts = try await addRule(store, name: "Receipts")
        let travel = try await addRule(store, name: "Travel")
        let deploys = try await addRule(store, name: "Deploys")
        let label = receipts.rule.labelTargets[0].id
        let run = try await manualRun(store, [receipts, travel, deploys], ["m1"])
        try await store.putVerdicts(
            [
                StoredVerdict(messageID: "m1", judgeHash: "h-receipts", verdict: .match, reason: "spreadsheet of purchases", examplesDigest: "e", model: "claude-opus-5-5", servedBy: "claude-sonnet-5-5"),
                StoredVerdict(messageID: "m1", judgeHash: "h-travel", verdict: .noMatch, reason: "not a trip booking", examplesDigest: "e", model: "claude-opus-5-5", servedBy: "claude-opus-5-5"),
            ],
            model: "claude-opus-5-5", costMicros: 1_200, runID: run
        )
        let decided = MessageOutcome(
            messageID: "m1",
            decisions: [
                RuleDecision(ruleID: receipts.id, revision: 1, verdict: .match, source: .claude, judgeHash: "h-receipts"),
                RuleDecision(ruleID: travel.id, revision: 1, verdict: .noMatch, source: .claude, judgeHash: "h-travel"),
                RuleDecision(ruleID: deploys.id, revision: 1, verdict: .noMatch, source: .gate),
            ],
            matches: [RuleMatch(ruleID: receipts.id, revision: 1, labelID: label)]
        )
        try await store.commitRuleOutcomes([decided], runID: run, simulated: true)
        // You labeled your reply "work".
        _ = try await store.apply(LocalMutation(deltas: [PlannedDelta(LabelDelta(messageIDs: ["m2"], add: ["Label_1"]), syncs: true)]))

        let explanation = try await store.explain(threadID: "t1")
        #expect(explanation.labels.map(\.label.name) == ["receipts", "work"])
        let owners = explanation.labels[0].owners
        #expect(owners.count == 1 && explanation.labels[0].messageIDs == ["m1"] && explanation.labels[0].unownedMessageIDs.isEmpty)
        let owner = try #require(owners.first)
        #expect(owner.ruleID == receipts.id && owner.ruleName == "Receipts" && owner.revision == 1 && owner.messageID == "m1")
        #expect(owner.runID == run && owner.runKind == .manual && owner.added && !owner.simulated)
        #expect(owner.source == .claude && owner.reason == "spreadsheet of purchases")
        #expect(owner.model == "claude-opus-5-5" && owner.servedBy == "claude-sonnet-5-5")
        // Added by you or Gmail.
        #expect(explanation.labels[1].owners.isEmpty && explanation.labels[1].unownedMessageIDs == ["m2"])
        // Travel judged it and said no; Deploys' filter never let it through.
        let miss = try #require(explanation.misses.first)
        #expect(explanation.misses.count == 1)
        #expect(miss.ruleID == travel.id && miss.ruleName == "Travel" && miss.verdict == .noMatch && miss.source == .claude)
        #expect(miss.reason == "not a trip booking" && miss.model == "claude-opus-5-5" && miss.messageID == "m1")

        // Once the rule is gone, the label is yours.
        try await store.deleteRule(id: receipts.id)
        let after = try await store.explain(threadID: "t1")
        #expect(after.labels[0].owners.isEmpty && after.labels[0].unownedMessageIDs == ["m1"])
    }
}
