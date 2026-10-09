import Foundation
import Testing
@testable import DummyProvider
@testable import MailCore
@testable import MailStore
@testable import MailSync

@Suite("Gmail refusing rule labels", .serialized)
struct RuleRejectionSyncTests {
    /// Stops the engine, which ends its event stream, and returns what it sent.
    func events(_ harness: Harness) async -> [SyncEngine.Event] {
        await harness.engine.stop()
        var events: [SyncEngine.Event] = []
        for await event in harness.engine.events { events.append(event) }
        return events
    }

    @Test func refusedRuleLabelsComeOffWithoutAToast() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let store = harness.store
        // A Gmail label this Mac knows that Gmail does not: Gmail refuses to add it.
        try await store.upsertLabel(MailLabel(id: "Label_gone", name: "receipts", kind: .user))
        let rule = try await store.createRule(Rule(key: "", name: "Receipts", then: [.addLabel(LabelRef(id: "Label_gone", lastKnownName: "receipts"))]))
        let other = try await store.createRule(Rule(key: "", name: "Bills", then: [.addLabel(LabelRef(id: "Label_gone", lastKnownName: "receipts"))]))
        let thread = try #require(try await store.threads(.mailbox(.inbox)).first)
        let messageID = try #require(try await store.thread(id: thread.id)?.messages.last?.id)
        let run = try await store.createRun(.manual, rules: [RunRule(rule.rule), RunRule(other.rule)], messageIDs: [messageID])
        let summary = try await store.commitRuleOutcomes(
            [MessageOutcome(
                messageID: messageID,
                decisions: [RuleDecision(ruleID: rule.id, revision: 1, verdict: .match, source: .gate), RuleDecision(ruleID: other.id, revision: 1, verdict: .match, source: .gate)],
                matches: [RuleMatch(ruleID: rule.id, revision: 1, labelID: "Label_gone"), RuleMatch(ruleID: other.id, revision: 1, labelID: "Label_gone")]
            )],
            runID: run, simulated: false
        )
        #expect(summary.syncedChanges == 1 && summary.coOwned == 1)
        #expect(try await store.message(id: messageID)?.labelIDs.contains("Label_gone") == true)

        #expect(await harness.engine.cycle())
        #expect(try await store.outboxCount() == 0)
        #expect(try await store.message(id: messageID)?.labelIDs.contains("Label_gone") == false)
        let revertedBy = try store.readNow { db in try db.query("SELECT reverted_by FROM rule_ledger ORDER BY id") { $0.optionalString(0) } }
        #expect(revertedBy == ["gmail_rejected", "gmail_rejected"])

        let sent = await events(harness)
        #expect(sent.count == 1)
        guard case .rulesGmailRejected(let count) = sent.first else {
            Issue.record("expected .rulesGmailRejected, got \(sent)")
            return
        }
        #expect(count == 1)
    }

    @Test func refusedChangesOfYoursStillShowAToast() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        try await harness.store.upsertLabel(MailLabel(id: "Label_gone", name: "receipts", kind: .user))
        let thread = try #require(try await harness.store.threads(.mailbox(.inbox)).first)
        try await harness.actions.perform(.addLabel("Label_gone"), threads: [thread.id])

        #expect(await harness.engine.cycle())
        let sent = await events(harness)
        guard case .operationFailed(let reason) = sent.first else {
            Issue.record("expected .operationFailed, got \(sent)")
            return
        }
        #expect(reason.hasPrefix("Could not update mail"))
        #expect(!sent.contains { if case .rulesGmailRejected = $0 { true } else { false } })
    }
}
