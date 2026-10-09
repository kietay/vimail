import Foundation
import Testing
@testable import MailCore
@testable import MailRules
@testable import MailStore

@Suite("Rule engine: your edits and the breaker", .serialized)
struct RuleFeedbackTests {
    /// The receipts rule labels m1 in conversation t1 as it arrives.
    func labeledReceipt(_ spec: RuleSpec = receiptsRule) async throws -> (Harness, FakeJudge, String) {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [spec], judge: judge)
        try await harness.deliver(mail("m1", thread: "t1", from: stripe, subject: "Your receipt", minutesAgo: 30))
        await harness.engine.drain()
        let label = try await harness.labelID("receipts")
        #expect(try await harness.hasLabel("m1", "receipts"))
        return (harness, judge, label)
    }

    func marks(_ harness: Harness) async throws -> [LabelMark] {
        try await harness.store.labelMarks(messageIDs: ["m1", "m2", "m3"])
    }

    // MARK: - Removing a rule's label

    @Test func removalTeachesByDefault() async throws {
        let (harness, judge, label) = try await labeledReceipt()
        try await harness.actions.perform(.removeLabel(label), threads: ["t1"])
        let note = try await harness.engine.noteUserChange(.applied(LabelEdit(undoKey: "u1", labelID: label, added: false, messageIDs: ["m1"])))
        #expect(note == LabelEditNote(stoppedRules: ["Receipts"], taughtRules: ["Receipts"]))

        #expect(try await marks(harness).map { "\($0.messageID) \($0.present)" } == ["m1 false"])
        let rule = try await harness.rule("Receipts")
        let examples = try await harness.store.examples(ruleID: rule.id)
        #expect(examples.map(\.messageID) == ["m1"])
        #expect(examples.first?.matches == false && examples.first?.origin == .edit && examples.first?.undoKey == "u1")
        // The rule no longer owns it, and does not add it back.
        #expect(try await harness.engine.explain(threadID: "t1").labels.isEmpty)
        _ = try await harness.engine.runRules(on: ["m1"])
        await harness.engine.drain()
        #expect(try await !harness.hasLabel("m1", "receipts"))
        #expect(try await harness.decision("m1", rule)?.source == .mark)
        #expect(judge.calls.count == 1)

        // A new reply is still judged.
        try await harness.deliver(mail("m2", thread: "t1", from: stripe, subject: "Re: Your receipt", minutesAgo: 1))
        await harness.engine.drain()
        #expect(judge.calls.count == 2)
        #expect(try await harness.hasLabel("m2", "receipts"))
    }

    @Test func removalWithEditsTeachOffBlocksWithoutTeaching() async throws {
        var workflow = receiptsRule
        workflow.editsTeach = false
        let (harness, judge, label) = try await labeledReceipt(workflow)
        try await harness.actions.perform(.removeLabel(label), threads: ["t1"])
        let note = try await harness.engine.noteUserChange(.applied(LabelEdit(undoKey: "u1", labelID: label, added: false, messageIDs: ["m1"])))
        #expect(note == LabelEditNote(stoppedRules: ["Receipts"], taughtRules: []))

        #expect(try await marks(harness).map(\.present) == [false])
        #expect(try await harness.store.examples(ruleID: harness.rule("Receipts").id).isEmpty)
        _ = try await harness.engine.runRules(on: ["m1"])
        await harness.engine.drain()
        #expect(try await !harness.hasLabel("m1", "receipts"))
        #expect(judge.calls.count == 1)
    }

    @Test func undoOfRemovalDeletesMark() async throws {
        let (harness, _, label) = try await labeledReceipt()
        let record = try #require(try await harness.actions.perform(.removeLabel(label), threads: ["t1"]))
        let edit = LabelEdit(undoKey: "u1", labelID: label, added: false, messageIDs: ["m1"])
        try await harness.engine.noteUserChange(.applied(edit))

        try await harness.actions.undo(record)
        try await harness.engine.noteUserChange(.undone(edit))
        #expect(try await marks(harness).isEmpty)
        #expect(try await harness.store.examples(ruleID: harness.rule("Receipts").id).isEmpty)
        #expect(try await harness.hasLabel("m1", "receipts"))
        // The rule owns the label again.
        #expect(try await harness.engine.explain(threadID: "t1").labels.first?.owners.map(\.ruleName) == ["Receipts"])
    }

    @Test func addingByHandMarksReceivedMessagesOnly() async throws {
        let harness = try await Harness(rules: [receiptsRule])
        let label = try await harness.labelID("receipts")
        try await harness.store.upsertMessages([
            mail("m1", thread: "t1", from: stripe, subject: "Your order", minutesAgo: 30),
            mail("m2", thread: "t1", from: me, to: [stripe], subject: "Re: Your order", minutesAgo: 20, labels: ["SENT"]),
            mail("m3", thread: "t1", from: stripe, subject: "Re: Your order", minutesAgo: 10),
        ])
        try await harness.actions.perform(.addLabel(label), threads: ["t1"])
        let note = try await harness.engine.noteUserChange(.applied(LabelEdit(undoKey: "u2", labelID: label, added: true, messageIDs: ["m1", "m2", "m3"])))
        #expect(note == LabelEditNote(stoppedRules: [], taughtRules: ["Receipts"]))

        #expect(try await marks(harness).filter(\.present).map(\.messageID).sorted() == ["m1", "m3"])
        // ✔ on the latest received message.
        let examples = try await harness.store.examples(ruleID: harness.rule("Receipts").id)
        #expect(examples.map(\.messageID) == ["m3"] && examples.first?.matches == true)
    }

    @Test func editsOfLabelsNoRuleAddsAreNotRecorded() async throws {
        let harness = try await Harness(rules: [receiptsRule])
        try await harness.store.upsertMessages([mail("m1", subject: "Hello")])
        try await harness.actions.perform(.addLabel("Label_1"), threads: ["m1"])
        let note = try await harness.engine.noteUserChange(.applied(LabelEdit(undoKey: "u3", labelID: "Label_1", added: true, messageIDs: ["m1"])))
        #expect(try await marks(harness).isEmpty)
        #expect(note == LabelEditNote())
    }

    // MARK: - Teaching from "why these labels?"

    @Test func shouldMatchTeachesWhenTheLabelWasAlreadyThere() async throws {
        let (harness, _, label) = try await labeledReceipt()
        let rule = try await harness.rule("Receipts")
        // `a` with the label on every message: the edit changes no label, the rule still learns.
        let edit = LabelEdit(undoKey: "u1", labelID: label, added: true, messageIDs: [])
        #expect(try await harness.engine.noteUserChange(.applied(edit)) == LabelEditNote())
        #expect(try await harness.engine.teach(ruleID: rule.id, messageID: "m1", matches: true, undoKey: "u1") == "Receipts")
        let examples = try await harness.store.examples(ruleID: rule.id)
        #expect(examples.map(\.messageID) == ["m1"] && examples.first?.matches == true && examples.first?.origin == .explain)
        // u
        try await harness.engine.noteUserChange(.undone(edit))
        #expect(try await harness.store.examples(ruleID: rule.id).isEmpty)
    }

    @Test func wrongTeachesARuleWhoseEditsDoNot() async throws {
        var workflow = receiptsRule
        workflow.editsTeach = false
        let (harness, _, label) = try await labeledReceipt(workflow)
        let rule = try await harness.rule("Receipts")
        try await harness.actions.perform(.removeLabel(label), threads: ["t1"])
        var note = try await harness.engine.noteUserChange(.applied(LabelEdit(undoKey: "u1", labelID: label, added: false, messageIDs: ["m1"])))
        #expect(note.taughtRules.isEmpty)
        // `x` gives the ✖ anyway, so the toast says it learns.
        let taught = try #require(try await harness.engine.teach(ruleID: rule.id, messageID: "m1", matches: false, undoKey: "u1"))
        note.taughtRules.append(taught)
        #expect(note.removalToast(labelName: "receipts") == "receipts removed · rule Receipts won't re-add it and will learn from this")
        #expect(try await harness.store.examples(ruleID: rule.id).map(\.matches) == [false])
    }

    @Test func filterRulesDoNotLearnFromExamples() async throws {
        let harness = try await Harness(rules: [deploysRule])
        try await harness.deliver(mail("m1", thread: "t1", subject: "deploy"))
        await harness.engine.drain()
        #expect(try await harness.engine.teach(ruleID: harness.rule("Deploys").id, messageID: "m1", matches: false, undoKey: "u1") == nil)
    }

    @Test func explainLinesForALabeledReceipt() async throws {
        let judge = FakeJudge(matching: ["r1": ["receipt"]])
        let harness = try await Harness(rules: [receiptsRule, travelRule], judge: judge)
        try await harness.deliver(mail("m1", thread: "t1", from: stripe, subject: "Your receipt", minutesAgo: 30))
        await harness.engine.drain()
        let explanation = try await harness.engine.explain(threadID: "t1")
        let lines = explanation.lines(rules: try await harness.store.rules(), labels: try await harness.store.labels(), modelName: { _ in "Haiku 5.5" }, date: { _ in "today" })
        #expect(lines.map(\.labelName) == ["receipts", "travel"])
        #expect(lines.map(\.detail) == [#"rule "Receipts" v1 · Claude (Haiku 5.5) · live, today"#, #"rule "Travel" did not match"#])
        #expect(lines.map(\.reason) == ["fake: match", "fake: no_match"])
        let label = try await harness.labelID("receipts")
        #expect(explanation.provenance(ofLabel: label) == ["rule Receipts · Claude: fake: match"])
    }

    // MARK: - Breaker

    @Test func breakerTrips() async throws {
        var everything = RuleSpec(name: "Everything", label: "all")
        everything.acknowledgedBroad = true
        let harness = try await Harness(rules: [everything])
        // 150 messages dated within the last hour. It trips once a pass takes it past 100.
        try await harness.deliver((0..<150).map { mail("m\($0)", subject: "Note \($0)", minutesAgo: Double($0) * 0.3) })
        await harness.engine.drain()
        let rule = try await harness.store.rules().first
        #expect(rule?.state == .tripped && rule?.rule.enabled == false)
        let labeled = try await harness.store.ruleMatchCount(RuleFilter.parse("label:all"), scope: .received)
        #expect(labeled > 100 && labeled < 150)
        #expect(await harness.engine.makeStatus().tripped == [rule?.id])

        // Turning it back on clears the trip, and its counts start over: more mail from the same
        // hour gets the label without tripping it.
        let id = try #require(rule?.id)
        let gap = try await harness.store.setRuleEnabled(id: id, true)
        #expect(try await harness.store.rules().first?.state == .ok)
        // Nothing arrived while it was off: no gap run.
        #expect(try await harness.engine.rulesChanged(.enabled(ruleID: id), gap: gap) == nil)
        try await harness.deliver((150..<200).map { mail("m\($0)", subject: "Note \($0)", minutesAgo: Double($0 - 150) * 0.3) })
        await harness.engine.drain()
        #expect(try await harness.store.rules().first?.state == .ok)
        #expect(try await harness.hasLabel("m199", "all"))
    }

    @Test func breakerTripsOnBroadMatches() async throws {
        let harness = try await Harness(rules: [RuleSpec(name: "Deals", label: "deals", when: "subject:deal")])
        let messages = (0..<40).map { index in
            mail("m\(index)", subject: index < 35 ? "A deal for you \(index)" : "Lunch \(index)", minutesAgo: Double(index) * 5)
        }
        try await harness.deliver(messages)
        await harness.engine.drain()
        #expect(try await harness.store.rules().first?.state == .tripped)
    }

    @Test func breakerIgnoresCatchUp() async throws {
        let harness = try await Harness(rules: [RuleSpec(name: "Deals", label: "deals", when: "subject:deal")])
        // 300 messages from ten hours offline, half of them deals: 15 an hour.
        let messages = (0..<300).map { index in
            mail("m\(index)", subject: index.isMultiple(of: 2) ? "A deal \(index)" : "Note \(index)", minutesAgo: Double(index) * 2)
        }
        try await harness.deliver(messages)
        await harness.engine.drain()
        #expect(try await harness.store.rules().first?.state == .ok)
        #expect(try await harness.store.ruleMatchCount(RuleFilter.parse("label:deals"), scope: .received) == 150)
    }

    @Test func breakerUnit() {
        var breaker = CircuitBreaker()
        let now = Date()
        // Catch-up: many labels, but spread over many hours of message dates.
        for index in 0..<500 {
            #expect(breaker.record(ruleID: "r", messageID: "c\(index)", date: now.addingTimeInterval(-Double(index) * 60), matched: true, added: true, broadAllowed: true) == nil)
        }
        var burst = CircuitBreaker()
        var trip: CircuitBreaker.Trip?
        for index in 0..<101 {
            trip = burst.record(ruleID: "r", messageID: "b\(index)", date: now.addingTimeInterval(-Double(index) * 30), matched: true, added: true, broadAllowed: true)
        }
        #expect(trip == .burst)
        // Older mail does not push the newest out of the ratio sample.
        var ratio = CircuitBreaker()
        for index in 0..<40 {
            _ = ratio.record(ruleID: "r", messageID: "n\(index)", date: now.addingTimeInterval(-Double(index)), matched: index < 10, added: false, broadAllowed: false)
        }
        for index in 0..<40 {
            #expect(ratio.record(ruleID: "r", messageID: "o\(index)", date: now.addingTimeInterval(-86_400 - Double(index)), matched: true, added: false, broadAllowed: false) == nil)
        }
        // A message counts once, however often it is decided.
        var again = CircuitBreaker()
        for index in 0..<40 {
            _ = again.record(ruleID: "r", messageID: "m\(index)", date: now.addingTimeInterval(-Double(index)), matched: index < 20, added: false, broadAllowed: false)
        }
        for index in 0..<20 {
            #expect(again.record(ruleID: "r", messageID: "m\(index)", date: now.addingTimeInterval(-Double(index)), matched: true, added: false, broadAllowed: false) == nil)
        }
        var once = CircuitBreaker()
        for _ in 0..<150 { trip = once.record(ruleID: "r", messageID: "m1", date: now, matched: true, added: true, broadAllowed: true) }
        #expect(trip == nil)
    }

    @Test func breakerCountsMailThatWaitedForClaudeOnce() async throws {
        let harness = try await Harness(rules: [receiptsRule, deploysRule], judge: nil)
        // Deploys matches half the mail: the 20 newest.
        try await harness.deliver((0..<40).map { index in
            mail("m\(index)", subject: index < 20 ? "deploy \(index)" : "Lunch \(index)", minutesAgo: Double(index) * 5)
        })
        await harness.engine.drain()
        #expect(try harness.queue().allSatisfy { $0.state == "waiting_ai" })

        // A key: every message comes back for Receipts, and Deploys decides it again.
        await harness.engine.configure(judge: FakeJudge(), aiPause: nil, config: testConfig)
        await harness.engine.drain()
        #expect(try harness.queue().isEmpty)
        #expect(try await harness.store.rules().map(\.state) == [.ok, .ok])
    }

    // MARK: - Status

    @Test func statusReportsWorkProblemsAndSpend() async throws {
        let spend = SpendFigures(spendToday: 420_000, spendMonth: 3_120_000, budgetDay: 3_000_000, budgetMonth: 20_000_000, runRoomToday: 1_880_000, previewLeft: 530_000)
        let harness = try await Harness(rules: [receiptsRule, deploysRule], judge: nil, spend: spend)
        try await harness.deliver(mail("m1", subject: "deploy"))
        var status = await harness.engine.makeStatus()
        #expect(status.liveQueued == 1 && status.ai == .notConfigured)
        #expect(status.spendToday == 420_000 && status.runRoomToday == 1_880_000 && status.previewLeft == 530_000)

        await harness.engine.drain()
        status = await harness.engine.makeStatus()
        #expect(status.liveQueued == 0 && status.waitingAI == 1 && !status.isIdle)

        try await harness.store.deleteLabel(id: try await harness.labelID("deploys"))
        status = await harness.engine.makeStatus()
        #expect(status.labelMissing == [try await harness.store.rules().first { $0.rule.name == "Deploys" }?.id])
    }

    @Test func statusStreamPublishes() async throws {
        let harness = try await Harness(rules: [deploysRule])
        await harness.engine.start()
        try await harness.engine.setPaused(true)
        var iterator = harness.engine.status.makeAsyncIterator()
        var paused = false
        while let status = await iterator.next() {
            if status.userPaused {
                paused = true
                break
            }
        }
        #expect(paused)
        await harness.engine.stop()
    }
}
