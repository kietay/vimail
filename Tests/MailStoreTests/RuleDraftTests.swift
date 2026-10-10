import Foundation
import Testing
@testable import MailCore
@testable import MailStore

@Suite("Rules written in the editor")
struct RuleDraftTests {
    @Test func marksOnAnUnsavedRuleBecomeTheRulesWhenItIsSaved() async throws {
        let store = try await seededStore()
        let label = try await store.resolveLabel(name: "receipts")
        let draft = Rule(key: "", name: "Receipts", ask: "Receipts for things I bought", then: [.addLabel(LabelRef(id: label.id, lastKnownName: label.name))])
        // Only the editor teaches a rule that is not saved yet.
        await #expect(throws: RuleStoreError.notFound) {
            try await store.setExample(ruleID: draft.id, messageID: "m1", matches: true, origin: .seed)
        }
        try await store.setExample(ruleID: draft.id, messageID: "m1", matches: true, origin: .seed, draft: true)
        try await store.setExample(ruleID: draft.id, messageID: "m3", matches: false, origin: .preview, draft: true)
        try await store.setOverride(ruleID: draft.id, subject: "@parkhouse.me", matches: false, origin: .user, draft: true)

        // Saving keeps the draft's ID, so what it was taught is the rule's.
        let record = try await store.createRule(draft)
        #expect(record.id == draft.id && record.rule.key == "r1")
        #expect(Set(try await store.examples(ruleID: record.id).map(\.messageID)) == ["m1", "m3"])
        #expect(try await store.examples(ruleID: record.id).first { $0.messageID == "m1" }?.origin == .seed)
        #expect(try await store.overrides(ruleID: record.id).map(\.subject) == ["@parkhouse.me"])
        // A saved rule is never discarded as a draft.
        try await store.discardDraft(ruleID: record.id)
        #expect(try await store.examples(ruleID: record.id).count == 2)
        #expect(try await store.overrides(ruleID: record.id).count == 1)
    }

    @Test func aWhenRulesCantUseIsNeverSaved() async throws {
        let store = try await seededStore()
        let label = try await store.resolveLabel(name: "receipts")
        var rule = Rule(key: "", name: "Receipts", when: "in:inbox", then: [.addLabel(LabelRef(id: label.id, lastKnownName: label.name))])
        await #expect(throws: RuleFilter.Problem.self) { try await store.createRule(rule) }
        #expect(try await store.rules().isEmpty)

        rule.when = "from:stripe"
        let record = try await store.createRule(rule)
        var edited = record.rule
        edited.when = "from:stripe newer_than:7d"
        await #expect(throws: RuleFilter.Problem.self) { try await store.saveRule(edited) }
        let stored = try #require(try await store.rules().first)
        #expect(stored.rule.when == "from:stripe" && stored.rule.revision == 1)
    }

    @Test func discardingAnUnsavedRuleForgetsWhatItWasTaught() async throws {
        let store = try await seededStore()
        let saved = try await addRule(store)
        try await store.setExample(ruleID: saved.id, messageID: "m1", matches: true, origin: .preview)
        let draftID = Rule.makeID()
        try await store.setExample(ruleID: draftID, messageID: "m1", matches: true, origin: .seed, draft: true)
        try await store.setOverride(ruleID: draftID, subject: "nina@parkhouse.me", matches: true, origin: .user, draft: true)
        let box = ChangeBox()
        store.observe { box.append($0) }

        try await store.discardDraft(ruleID: draftID)
        #expect(try await store.examples(ruleID: draftID).isEmpty)
        #expect(try await store.overrides(ruleID: draftID).isEmpty)
        #expect(try await store.examples(messageID: "m1").map(\.ruleID) == [saved.id])
        #expect(box.changes.allSatisfy(\.rules) && box.changes.count == 1)
    }

    @Test func pruningForgetsDraftsLeftBehind() async throws {
        let store = try await seededStore()
        let saved = try await addRule(store)
        try await store.setExample(ruleID: saved.id, messageID: "m3", matches: true, origin: .preview)
        try await store.setOverride(ruleID: saved.id, subject: "@parkhouse.me", matches: true, origin: .user)
        let draftID = Rule.makeID()
        try await store.setExample(ruleID: draftID, messageID: "m1", matches: true, origin: .seed, draft: true)
        try await store.setOverride(ruleID: draftID, subject: "@studionorth.co", matches: false, origin: .user, draft: true)

        // A draft may still be open in the editor for a while.
        try await store.pruneRuleHistory(now: Date(), judgeHashesInUse: [])
        #expect(try await store.examples(ruleID: draftID).count == 1)
        // A day later the app must have quit without discarding it.
        try await store.pruneRuleHistory(now: Date().addingTimeInterval(86_400 + 60), judgeHashesInUse: [])
        #expect(try await store.examples(ruleID: draftID).isEmpty)
        #expect(try await store.overrides(ruleID: draftID).isEmpty)
        #expect(try await store.examples(ruleID: saved.id).count == 1)
        #expect(try await store.overrides(ruleID: saved.id).count == 1)
    }

    @Test func statsCountLabelsAndUnsureVerdicts() async throws {
        let store = try await seededStore()
        let receipts = try await addRule(store)
        let travel = try await addRule(store, name: "Travel")
        let run = try await manualRun(store, [receipts, travel], ["m1", "m3", "m4"])
        _ = try await store.commitRuleOutcomes([
            outcome("m1", matching: [receipts]),
            outcome("m4", matching: [receipts]),
            MessageOutcome(messageID: "m3", decisions: [
                RuleDecision(ruleID: receipts.id, revision: 1, verdict: .unsure, source: .claude),
                RuleDecision(ruleID: travel.id, revision: 1, verdict: .unsure, source: .claude),
            ], matches: []),
        ], runID: run, simulated: false)
        var stats = try await store.ruleStats()
        #expect(stats[receipts.id] == RuleStats(labeled: 2, unsure: 1))
        #expect(stats[travel.id] == RuleStats(labeled: 0, unsure: 1))

        // A reviewed verdict is no longer unsure; a label you removed is no longer the rule's.
        try await store.setExample(ruleID: travel.id, messageID: "m3", matches: false, origin: .preview)
        try await store.setLabelMarks(messageIDs: ["m4"], labelID: receipts.rule.labelTargets[0].id, present: false)
        stats = try await store.ruleStats()
        #expect(stats[receipts.id] == RuleStats(labeled: 1, unsure: 1))
        #expect(stats[travel.id] == nil)
    }

    @Test func everyConversationAWhenMatches() async throws {
        let store = try await seededStore()
        // Alex wrote m1 (t1, inbox) and m4 (t3, archived); Nina m3 (t2). m2 is yours: never in scope.
        #expect(Set(try await store.ruleMatchThreads(try RuleFilter.parse("from:alex"), scope: .received)) == ["t1", "t3"])
        #expect(Set(try await store.ruleMatchThreads(try RuleFilter.parse(""), scope: .received)) == ["t1", "t2", "t3"])
        #expect(try await store.ruleMatchThreads(try RuleFilter.parse("from:alex"), scope: .inbox) == ["t1"])
        #expect(try await store.ruleMatchThreads(try RuleFilter.parse("label:work"), scope: .received) == ["t3"])
    }

    @Test func oldestMessageInScope() async throws {
        let store = try await seededStore()
        // m4, ten hours ago; in the inbox, m1 half an hour ago.
        let oldest = try #require(try await store.oldestMessageDate(scope: .received))
        #expect(abs(oldest.timeIntervalSinceNow + 600 * 60) < 120)
        let inbox = try #require(try await store.oldestMessageDate(scope: .inbox))
        #expect(abs(inbox.timeIntervalSinceNow + 30 * 60) < 120)
        #expect(try await makeStore().oldestMessageDate(scope: .received) == nil)
    }

    @Test func aListMayHoldEveryConversationARuleMatches() async throws {
        let store = try await seededStore()
        var query = ThreadQuery(scope: .anywhere)
        // Far more IDs than SQLite takes as parameters.
        query.ids = (0..<40_000).map { "x\($0)" } + ["t2", "t3"]
        #expect(Set(try await store.threads(query).map(\.id)) == ["t2", "t3"])
        #expect(try await store.count(query) == 2)
        query.ids = []
        #expect(try await store.threads(query).isEmpty)
    }
}
