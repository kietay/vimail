import CryptoKit
import Foundation

/// How a rule's decision for one message was reached, cheapest first.
public enum DecisionSource: String, Codable, Sendable {
    /// Out of scope, or WHEN did not pass.
    case gate
    /// Your edit of the rule's label on the message: a removal decides no, an addition yes.
    case mark
    /// A ✔ or ✖ you gave this rule for the message.
    case example
    /// A sender override: the exact address, else its domain.
    case override
    /// Inherited from the rule's match earlier in the conversation (opt-in).
    case thread
    /// A verdict Claude gave earlier at the rule's judge hash.
    case cache
    case claude
}

/// What one rule decided for one message, at one revision.
public struct RuleDecision: Hashable, Sendable {
    public var ruleID: String
    public var revision: Int
    /// Only `.match` applies the rule.
    public var verdict: Verdict
    public var source: DecisionSource
    /// Where Claude's verdict is cached (`cache` and `claude` decisions), so its reason can be shown.
    public var judgeHash: String?

    public init(ruleID: String, revision: Int, verdict: Verdict, source: DecisionSource, judgeHash: String? = nil) {
        self.ruleID = ruleID
        self.revision = revision
        self.verdict = verdict
        self.source = source
        self.judgeHash = judgeHash
    }
}

/// Why a label a rule added stopped being the rule's.
public enum LedgerRevertReason: String, Codable, Sendable {
    /// You undid the run.
    case undo
    /// You removed the label yourself.
    case user
    /// A re-check found the rule no longer matches.
    case recheck
    case ruleDeleted = "rule_deleted"
    case labelDeleted = "label_deleted"
    /// Gmail refused to add it.
    case gmailRejected = "gmail_rejected"
}

extension Rule {
    /// The key Claude's verdicts for this rule are cached under, or nil for a rule without an ASK.
    /// Examples and the label's name are not part of it: a new example or a renamed label re-bills nothing.
    public func judgeHash(model: String, effort: String, promptVersion: Int) -> String? {
        guard asksClaude, let ask else { return nil }
        return Self.judgeHash(ask: ask, model: model, effort: effort, promptVersion: promptVersion)
    }

    /// sha256(prompt version ‖ model ‖ effort ‖ ASK) in hex. The ASK comes last, so the newline
    /// separators are unambiguous; whitespace around it does not count.
    public static func judgeHash(ask: String, model: String, effort: String, promptVersion: Int) -> String {
        let input = [String(promptVersion), model, effort, ask.trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: "\n")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
