/// Rule work is grouped in runs: one live run per day for arriving mail, and runs you start
/// over stored mail. Each run applies its rules at the revisions it recorded.
public enum RunKind: String, Codable, Sendable {
    /// Mail as it arrives, one run per local day.
    case live
    /// "Apply to existing mail" after saving a rule.
    case backfill
    /// Judging a rule's earlier results again after an edit, applied only once you confirm.
    case recheck
    /// Rules run on the selection now (`=`).
    case manual
    /// Mail that arrived while a rule was off.
    case gap
    /// Mail that waited too long for Claude, or arrived during an offline resync.
    case backlog
}

public enum RunState: String, Codable, Sendable {
    case running, paused
    case awaitingConfirm = "awaiting_confirm"
    case done, cancelled, undone
}

/// Why a run stopped before finishing.
public enum RunPauseReason: String, Codable, Sendable {
    case budget
    /// It reached its cost cap (1.5× the estimate).
    case cap
    case user
    /// Claude is paused (`PauseReason`).
    case ai
    case ruleChanged = "rule_changed"
    case modelChanged = "model_changed"
}

/// A rule at the revision a run applies.
public struct RunRule: Codable, Sendable, Hashable {
    public var id: String
    public var revision: Int

    public init(id: String, revision: Int) {
        self.id = id
        self.revision = revision
    }

    /// The rule at its current revision.
    public init(_ rule: Rule) {
        self.init(id: rule.id, revision: rule.revision)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case revision = "rev"
    }
}
