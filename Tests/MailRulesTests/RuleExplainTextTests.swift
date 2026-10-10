import Foundation
import Testing
@testable import MailCore
@testable import MailRules
@testable import MailStore

@Suite("Why these labels, as text")
struct RuleExplainTextTests {
    let applied = Date(timeIntervalSince1970: 1_790_942_400)

    func owner(_ rule: String, name: String?, message: String = "m1", source: DecisionSource?, reason: String? = nil, runKind: RunKind? = .live, at offset: TimeInterval = 0, simulated: Bool = false) -> LabelOwner {
        LabelOwner(
            ledgerID: 1, messageID: message, ruleID: rule, ruleName: name, revision: 3, runID: 40, runKind: runKind, appliedAt: applied.addingTimeInterval(offset),
            added: true, source: source, reason: reason, model: "claude-haiku-5-5", servedBy: "claude-haiku-5-5", simulated: simulated
        )
    }

    func lines(_ explanation: ThreadExplanation, rules: [RuleRecord] = [], labels: [MailLabel] = []) -> [ExplainLine] {
        explanation.lines(rules: rules, labels: labels, modelName: { $0 == "claude-haiku-5-5" ? "Haiku 5.5" : $0 }, date: { _ in "9 Oct 14:02" })
    }

    @Test func ruleLabelsAndLabelsYouAdded() {
        let receipts = MailLabel(id: "Label_5", name: "receipts", kind: .user)
        let work = MailLabel(id: "Label_1", name: "work", kind: .user)
        let explanation = ThreadExplanation(labels: [
            LabelExplanation(label: receipts, messageIDs: ["m1", "m2"], owners: [
                owner("r_1", name: "Receipts", source: .claude, reason: "payment receipt for Figma"),
                owner("r_1", name: "Receipts", message: "m2", source: .cache, reason: "another receipt", at: 60),
                owner("r_2", name: "Deploys", source: .gate, runKind: .manual, simulated: true),
            ]),
            LabelExplanation(label: work, messageIDs: ["m1"], owners: []),
        ], misses: [])
        let result = lines(explanation)
        #expect(result.map(\.detail) == [
            #"rule "Receipts" v3 · Claude (Haiku 5.5) · live, 9 Oct 14:02"#,
            #"rule "Deploys" v3 · filter · manual run, 9 Oct 14:02 · simulated (debug)"#,
            "added by you or Gmail",
        ])
        // The latest time the rule added it here.
        #expect(result.first?.reason == "another receipt")
        #expect(result[1].reason == nil)
        #expect(result.map(\.labelName) == ["receipts", "receipts", "work"])
        #expect(result.allSatisfy { $0.isOnConversation })
        #expect(explanation.provenance(ofLabel: "Label_5") == ["rule Receipts · Claude: another receipt", "rule Deploys · filter"])
        #expect(explanation.provenance(ofLabel: "Label_1").isEmpty)
    }

    @Test func rulesThatDecidedNo() {
        let travel = MailLabel(id: "Label_6", name: "travel", kind: .user)
        let rule = Rule(id: "r_3", key: "r3", name: "Travel", ask: "Trips", then: [.addLabel(LabelRef(id: "Label_6", lastKnownName: "trips"))])
        let record = RuleRecord(rule: rule, position: 1, state: .ok, createdAt: applied, updatedAt: applied)
        func miss(_ rule: String, _ message: String, _ verdict: Verdict, _ source: DecisionSource, _ reason: String?) -> RuleMiss {
            RuleMiss(messageID: message, ruleID: rule, ruleName: rule == "r_3" ? "Travel" : "Other", revision: 1, verdict: verdict, source: source, reason: reason, model: "claude-haiku-5-5")
        }
        let explanation = ThreadExplanation(labels: [], misses: [
            miss("r_3", "m1", .noMatch, .claude, "an older reason"),
            miss("r_3", "m2", .noMatch, .cache, "a software receipt, not a trip booking"),
            miss("r_4", "m2", .unsure, .claude, "asks about an invoice"),
            miss("r_5", "m2", .declined, .claude, nil),
            miss("r_6", "m2", .noMatch, .mark, nil),
            miss("r_7", "m2", .noMatch, .override, nil),
        ])
        let result = lines(explanation, rules: [record], labels: [travel])
        #expect(result.map(\.detail) == [
            #"rule "Travel" did not match"#, #"rule "Other": Claude was unsure"#,
            #"rule "Other": Claude declined to classify this email (often phishing)"#,
            #"rule "Other" won't add it: you removed the label"#, #"rule "Other" did not match: your sender rule says never"#,
        ])
        #expect(result.map(\.reason) == ["a software receipt, not a trip booking", "asks about an invoice", nil, nil, nil])
        // The label's current name; rules without a record fall back to their own name.
        #expect(result.first?.labelName == "travel" && result.first?.labelID == "Label_6")
        #expect(result.allSatisfy { !$0.isOnConversation })
    }

    @Test func aRuleThatAddedALabelHereIsNotAlsoAMiss() {
        let receipts = MailLabel(id: "Label_5", name: "receipts", kind: .user)
        let explanation = ThreadExplanation(
            labels: [LabelExplanation(label: receipts, messageIDs: ["m1"], owners: [owner("r_1", name: "Receipts", source: .claude, reason: "receipt")])],
            misses: [RuleMiss(messageID: "m2", ruleID: "r_1", ruleName: "Receipts", revision: 3, verdict: .noMatch, source: .claude, reason: "a reply", model: nil)]
        )
        #expect(lines(explanation).count == 1)
    }

    @Test func rulesThatAgreeWithALabelYouAdded() {
        let receipts = MailLabel(id: "Label_5", name: "receipts", kind: .user)
        func agreement(_ message: String, _ source: DecisionSource, _ reason: String?) -> RuleAgreement {
            RuleAgreement(messageID: message, ruleID: "r_1", ruleName: "Receipts", revision: 3, labelID: "Label_5", source: source, reason: reason, model: "claude-haiku-5-5")
        }
        let explanation = ThreadExplanation(
            labels: [LabelExplanation(label: receipts, messageIDs: ["m1", "m2"], owners: [])],
            misses: [RuleMiss(messageID: "m3", ruleID: "r_1", ruleName: "Receipts", revision: 3, verdict: .noMatch, source: .claude, reason: "a reply", model: nil)],
            agreements: [agreement("m1", .claude, "an older receipt"), agreement("m2", .cache, "receipt for Figma")]
        )
        let result = lines(explanation)
        // One line for the rule, its newest agreement; and no "did not match" for it.
        #expect(result.map(\.detail) == ["added by you or Gmail", #"rule "Receipts" v3 agrees · Claude (Haiku 5.5)"#])
        #expect(result.last?.reason == "receipt for Figma")
        #expect(result.allSatisfy { $0.isOnConversation })
    }

    @Test func deletedRules() {
        let receipts = MailLabel(id: "Label_5", name: "receipts", kind: .user)
        let explanation = ThreadExplanation(labels: [LabelExplanation(label: receipts, messageIDs: ["m1"], owners: [owner("r_9", name: nil, source: .gate, runKind: nil)])], misses: [])
        #expect(lines(explanation).first?.detail == "a deleted rule · filter · 9 Oct 14:02")
        #expect(explanation.provenance(ofLabel: "Label_5") == ["a deleted rule · filter"])
    }
}
