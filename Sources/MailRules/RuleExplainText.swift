import Foundation
import MailCore
import MailStore

/// One line of "why these labels?" (design §5.5).
public struct ExplainLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A rule added the label, or co-owns it: the latest time it did on this conversation.
        case rule(LabelOwner)
        /// The label is on messages no rule owns there: you or Gmail added it.
        case other
        /// A rule matched a message that already had the label you or Gmail added: it agrees.
        case agrees(RuleAgreement)
        /// A rule decided no: for the newest message it judged.
        case miss(RuleMiss)
    }

    public var id: String
    public var kind: Kind
    /// The label on the conversation, or the one the rule that decided no would add.
    public var labelID: String?
    public var labelName: String
    /// `rule "Receipts" v3 · Claude (Haiku 5.5) · live, 9 Oct 14:02`, `added by you or Gmail`,
    /// `rule "Receipts" v3 agrees · Claude (Haiku 5.5)`, `rule "Travel" did not match`.
    public var detail: String
    /// Claude's reason, as plain text.
    public var reason: String?

    /// True for a label the conversation carries (◆), false for a rule that decided no (·).
    public var isOnConversation: Bool {
        if case .miss = kind { return false }
        return true
    }
}

extension ThreadExplanation {
    /// "Why these labels?" line by line: each label with the rules that added it (one line per rule)
    /// and, where no rule owns it, "added by you or Gmail" with the rules that matched it there
    /// ("agrees"); then the rules that decided no, except rules that added or agreed with a label here.
    /// - Parameters:
    ///   - rules: the account's rules, for the label a rule that decided no would add.
    ///   - labels: the account's labels, for their current names.
    ///   - modelName: how a model id reads ("Haiku 5.5").
    ///   - date: how a date reads.
    public func lines(rules: [RuleRecord], labels: [MailLabel], modelName: (String) -> String, date: (Date) -> String) -> [ExplainLine] {
        var lines: [ExplainLine] = []
        var owning = Set<String>()
        for explanation in self.labels {
            let label = explanation.label
            for owner in Self.latestOwners(explanation.owners) {
                owning.insert(owner.ruleID)
                lines.append(ExplainLine(
                    id: "label:\(label.id):\(owner.ruleID)", kind: .rule(owner), labelID: label.id, labelName: label.name,
                    detail: owner.detail(modelName: modelName, date: date), reason: owner.claudeDecided ? owner.reason : nil
                ))
            }
            if !explanation.unownedMessageIDs.isEmpty {
                lines.append(ExplainLine(id: "label:\(label.id):other", kind: .other, labelID: label.id, labelName: label.name, detail: "added by you or Gmail"))
            }
            let adding = Set(explanation.owners.map(\.ruleID))
            var agreeing: [String: RuleAgreement] = [:]
            var order: [String] = []
            // Oldest message first: the last one is the newest.
            for agreement in agreements where agreement.labelID == label.id && !adding.contains(agreement.ruleID) && explanation.messageIDs.contains(agreement.messageID) {
                if agreeing[agreement.ruleID] == nil { order.append(agreement.ruleID) }
                agreeing[agreement.ruleID] = agreement
            }
            for agreement in order.compactMap({ agreeing[$0] }) {
                owning.insert(agreement.ruleID)
                let claude = agreement.source == .claude || agreement.source == .cache
                lines.append(ExplainLine(
                    id: "agree:\(label.id):\(agreement.ruleID)", kind: .agrees(agreement), labelID: label.id, labelName: label.name,
                    detail: agreement.detail(modelName: modelName), reason: claude ? agreement.reason : nil
                ))
            }
        }
        var newest: [String: RuleMiss] = [:]
        var order: [String] = []
        for miss in misses where !owning.contains(miss.ruleID) {
            if newest[miss.ruleID] == nil { order.append(miss.ruleID) }
            // Misses come oldest message first: the last one is the newest.
            newest[miss.ruleID] = miss
        }
        for ruleID in order {
            guard let miss = newest[ruleID] else { continue }
            let target = rules.first { $0.id == ruleID }?.rule.labelTargets.first
            let name = target.map { ref in labels.first { $0.id == ref.id }?.name ?? ref.lastKnownName } ?? miss.ruleName ?? "deleted rule"
            let claude = miss.source == .claude || miss.source == .cache
            lines.append(ExplainLine(
                id: "miss:\(ruleID)", kind: .miss(miss), labelID: target?.id, labelName: name, detail: miss.detail,
                reason: claude && miss.verdict != .declined ? miss.reason : nil
            ))
        }
        return lines
    }

    /// For the reader: how rules added the label, one line per rule
    /// ("rule Receipts · Claude: payment receipt for Figma").
    public func provenance(ofLabel labelID: String) -> [String] {
        guard let explanation = labels.first(where: { $0.label.id == labelID }) else { return [] }
        return Self.latestOwners(explanation.owners).map(\.provenance)
    }

    /// Each rule's most recent ownership, in the order the rules first added the label.
    static func latestOwners(_ owners: [LabelOwner]) -> [LabelOwner] {
        var latest: [String: LabelOwner] = [:]
        var order: [String] = []
        for owner in owners {
            if let current = latest[owner.ruleID] {
                if owner.appliedAt >= current.appliedAt { latest[owner.ruleID] = owner }
            } else {
                order.append(owner.ruleID)
                latest[owner.ruleID] = owner
            }
        }
        return order.compactMap { latest[$0] }
    }
}

extension LabelOwner {
    /// Claude decided, by a call or from its cache.
    var claudeDecided: Bool { source == .claude || source == .cache }

    /// "rule Receipts · Claude: payment receipt for Figma", "rule Deploys · filter".
    public var provenance: String {
        let rule = ruleName.map { "rule \($0)" } ?? "a deleted rule"
        if claudeDecided, let reason, !reason.isEmpty { return "\(rule) · Claude: \(reason)" }
        return "\(rule) · \(how(model: nil))"
    }

    /// `rule "Receipts" v3 · Claude (Haiku 5.5) · live, 9 Oct 14:02`, with `simulated (debug)` for a
    /// label a dry-run provider never sent to Gmail.
    func detail(modelName: (String) -> String, date: (Date) -> String) -> String {
        var parts = [ruleName.map { "rule \"\($0)\" v\(revision)" } ?? "a deleted rule", how(model: (servedBy ?? model).map(modelName))]
        let when = date(appliedAt)
        parts.append(runKind.map { "\(Self.runText($0)), \(when)" } ?? when)
        if simulated { parts.append("simulated (debug)") }
        return parts.joined(separator: " · ")
    }

    /// How the rule decided: "Claude (Haiku 5.5)", "filter", "your ✔ example"…
    /// - Parameter model: the model's name, when it should show.
    func how(model: String?) -> String {
        switch source {
        case .claude, .cache:
            return model.map { "Claude (\($0))" } ?? "Claude"
        case .gate, nil: return "filter"
        case .mark: return "your label"
        case .example: return "your ✔ example"
        case .override: return "sender rule"
        case .thread: return "matched earlier in the conversation"
        }
    }

    static func runText(_ kind: RunKind) -> String {
        switch kind {
        case .live: "live"
        case .backfill: "run"
        case .recheck: "re-check"
        case .manual: "manual run"
        case .gap: "gap run"
        case .backlog: "backlog run"
        }
    }
}

extension RuleAgreement {
    /// `rule "Receipts" v3 agrees · Claude (Haiku 5.5)`, `rule "Deploys" v1 agrees · filter`.
    func detail(modelName: (String) -> String) -> String {
        let rule = ruleName.map { "rule \"\($0)\" v\(revision)" } ?? "a deleted rule"
        let how: String
        switch source {
        case .claude, .cache: how = model.map { "Claude (\(modelName($0)))" } ?? "Claude"
        case .gate, .mark: how = "filter"
        case .example: how = "your ✔ example"
        case .override: how = "sender rule"
        case .thread: how = "matched earlier in the conversation"
        }
        return "\(rule) agrees · \(how)"
    }
}

extension RuleMiss {
    /// `rule "Travel" did not match`, `rule "Travel": Claude was unsure`, `rule "Travel": Claude
    /// declined to classify this email (often phishing)`.
    var detail: String {
        let rule = ruleName.map { "rule \"\($0)\"" } ?? "a deleted rule"
        switch (source, verdict) {
        case (.mark, _): return "\(rule) won't add it: you removed the label"
        case (.example, _): return "\(rule) did not match: your ✖ example"
        case (.override, _): return "\(rule) did not match: your sender rule says never"
        case (_, .unsure): return "\(rule): Claude was unsure"
        case (_, .declined): return "\(rule): Claude declined to classify this email (often phishing)"
        default: return "\(rule) did not match"
        }
    }
}
