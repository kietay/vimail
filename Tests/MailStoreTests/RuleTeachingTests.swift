import Foundation
import Testing
@testable import MailCore
@testable import MailStore

@Suite("What rules learn from you")
struct RuleTeachingTests {
    @Test func examplesDecideOneMessageForOneRule() async throws {
        let store = try await seededStore()
        let receipts = try await addRule(store)
        let travel = try await addRule(store, name: "Travel")
        let seed = try await store.setExample(ruleID: receipts.id, messageID: "m1", matches: true, origin: .seed)
        #expect(seed.digest == "Alex Morgan · @studionorth.co · Quarterly budget review")
        #expect(seed.matches && seed.origin == .seed && seed.undoKey == nil)

        // One example per rule and message: setting it again replaces it.
        try await store.setExample(ruleID: receipts.id, messageID: "m1", matches: false, origin: .preview, undoKey: "edit-1")
        try await store.setExample(ruleID: receipts.id, messageID: "m3", matches: true, origin: .explain)
        try await store.setExample(ruleID: travel.id, messageID: "m1", matches: true, origin: .edit)
        let examples = try await store.examples(ruleID: receipts.id)
        #expect(Set(examples.map(\.messageID)) == ["m1", "m3"])
        let replaced = try #require(examples.first { $0.messageID == "m1" })
        #expect(!replaced.matches && replaced.origin == .preview && replaced.undoKey == "edit-1" && replaced.digest == seed.digest)
        #expect(Set(try await store.examples(messageID: "m1").map(\.ruleID)) == [receipts.id, travel.id])

        try await store.removeExample(ruleID: receipts.id, messageID: "m3")
        #expect(try await store.examples(ruleID: receipts.id).map(\.messageID) == ["m1"])
        await #expect(throws: RuleStoreError.notFound) {
            try await store.setExample(ruleID: receipts.id, messageID: "gone", matches: true, origin: .preview)
        }
        await #expect(throws: RuleStoreError.notFound) {
            try await store.setExample(ruleID: "r_gone", messageID: "m1", matches: true, origin: .preview)
        }
        // A deleted rule's examples go with it.
        try await store.deleteRule(id: receipts.id)
        #expect(try await store.examples(messageID: "m1").map(\.ruleID) == [travel.id])
    }

    @Test func digestsNeverCarryYourAddresses() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        try await store.upsertMessages([
            message("f1", thread: "f1", from: EmailAddress(name: "sam@studionorth.co via Team", email: "team@lists.example"), subject: "Fwd: note for sam@studionorth.co", minutesAgo: 5),
        ])
        let example = try await store.setExample(ruleID: rule.id, messageID: "f1", matches: true, origin: .preview)
        #expect(example.digest == "me via Team · @lists.example · Fwd: note for me")
    }

    @Test func labelMarksRecordYourEdits() async throws {
        let store = try await seededStore()
        #expect(try await store.setLabelMarks(messageIDs: ["m1", "m3"], labelID: "Label_1", present: true, undoKey: "edit-1") == 0)
        try await store.setLabelMarks(messageIDs: ["m4"], labelID: "Label_1", present: false)
        try await store.setLabelMarks(messageIDs: ["m3"], labelID: "STARRED", present: true)
        let marks = try await store.labelMarks(labelID: "Label_1")
        #expect(Set(marks.map { "\($0.messageID) \($0.present)" }) == ["m1 true", "m3 true", "m4 false"])
        #expect(try await store.labelMarks(messageIDs: ["m3"]).count == 2)

        // A later edit replaces the mark.
        try await store.setLabelMarks(messageIDs: ["m1"], labelID: "Label_1", present: false, undoKey: "edit-2")
        let mark = try #require(try await store.labelMarks(messageIDs: ["m1"]).first)
        #expect(!mark.present && mark.undoKey == "edit-2" && mark.labelID == "Label_1")

        try await store.removeLabelMarks(messageIDs: ["m3", "m4"], labelID: "Label_1")
        #expect(try await store.labelMarks(labelID: "Label_1").map(\.messageID) == ["m1"])
        #expect(try await store.labelMarks(messageIDs: ["m3"]).map(\.labelID) == ["STARRED"])
    }

    @Test func undoingAnEditDeletesWhatItTaught() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        try await store.setLabelMarks(messageIDs: ["m1"], labelID: label, present: false, undoKey: "edit-1")
        try await store.setExample(ruleID: rule.id, messageID: "m1", matches: false, origin: .edit, undoKey: "edit-1")
        try await store.setLabelMarks(messageIDs: ["m3"], labelID: label, present: true, undoKey: "edit-2")
        try await store.setExample(ruleID: rule.id, messageID: "m3", matches: true, origin: .preview)

        try await store.deleteMarksAndExamples(undoKey: "edit-1")
        #expect(try await store.labelMarks(labelID: label).map(\.messageID) == ["m3"])
        #expect(try await store.examples(ruleID: rule.id).map(\.messageID) == ["m3"])

        // Every change to what rules know from you is heard, an edit that made marks only included.
        let box = ChangeBox()
        store.observe { box.append($0) }
        try await store.deleteMarksAndExamples(undoKey: "edit-2")
        #expect(try await store.labelMarks(labelID: label).isEmpty)
        try await store.setLabelMarks(messageIDs: ["m4"], labelID: label, present: false)
        try await store.removeLabelMarks(messageIDs: ["m4"], labelID: label)
        #expect(box.changes.count == 3 && box.changes.allSatisfy(\.rules))
    }

    @Test func senderOverridesNameAnAddressOrADomain() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let box = ChangeBox()
        store.observe { box.append($0) }
        try await store.setOverride(ruleID: rule.id, subject: " Receipts@Stripe.com ", matches: true, origin: .user)
        try await store.setOverride(ruleID: rule.id, subject: "@Allbirds.com", matches: false, origin: .learned, evidence: 5)
        let overrides = try await store.overrides(ruleID: rule.id)
        #expect(overrides.map(\.subject) == ["@allbirds.com", "receipts@stripe.com"])
        #expect(overrides.map(\.matches) == [false, true])
        #expect(overrides[0].origin == .learned && overrides[0].evidence == 5 && overrides[1].origin == .user && overrides[1].evidence == 0)
        #expect(box.changes.allSatisfy(\.rules) && box.changes.count == 2)

        // Setting it again replaces it.
        try await store.setOverride(ruleID: rule.id, subject: "@allbirds.com", matches: true, origin: .user)
        #expect(try await store.overrides(ruleID: rule.id).map(\.matches) == [true, true])
        try await store.removeOverride(ruleID: rule.id, subject: "@ALLBIRDS.com")
        #expect(try await store.overrides(ruleID: rule.id).map(\.subject) == ["receipts@stripe.com"])

        for subject in ["stripe.com", "@", " ", "x@", "a@b@c.com", "a b@c.com"] {
            await #expect(throws: RuleStoreError.invalidSender) {
                try await store.setOverride(ruleID: rule.id, subject: subject, matches: true, origin: .user)
            }
        }
        await #expect(throws: RuleStoreError.notFound) {
            try await store.setOverride(ruleID: "r_gone", subject: "@stripe.com", matches: true, origin: .user)
        }
        // A deleted rule's overrides go with it.
        try await store.deleteRule(id: rule.id)
        #expect(try await store.overrides(ruleID: rule.id).isEmpty)
    }
}
