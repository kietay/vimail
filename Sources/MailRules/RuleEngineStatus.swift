import Foundation
import MailCore

/// What the rules engine is doing, for the status bar and the rules manager.
public struct RuleEngineStatus: Sendable, Equatable {
    public var ai: AIState = .notConfigured
    /// The person paused all rules.
    public var userPaused = false
    /// Arrived messages waiting for their pass.
    public var liveQueued = 0
    /// Messages waiting until Claude is available again.
    public var waitingAI = 0
    /// Messages held for a run that waits for your confirmation.
    public var held = 0
    public var failed = 0
    /// `unsure` verdicts to review in the rule editor.
    public var unsureToReview = 0
    /// Runs that are not finished: running, paused or awaiting confirmation.
    public var runs: [RunProgress] = []
    /// IDs of rules the breaker turned off.
    public var tripped: [String] = []
    /// IDs of rules whose label was deleted.
    public var labelMissing: [String] = []
    /// Spend and budgets in millionths of a dollar.
    public var spendToday: Int64 = 0
    public var spendMonth: Int64 = 0
    public var budgetDay: Int64 = 0
    public var budgetMonth: Int64 = 0
    /// What runs may still spend today, after the reserve kept for live mail.
    public var runRoomToday: Int64 = 0
    /// What previews may still spend today.
    public var previewLeft: Int64 = 0

    public init() {}

    /// Nothing to show: no work, no problem to report. The status bar hides its rules segment.
    public var isIdle: Bool {
        if case .paused = ai { return false }
        return !userPaused && liveQueued == 0 && waitingAI == 0 && held == 0 && failed == 0 && unsureToReview == 0
            && runs.isEmpty && tripped.isEmpty && labelMissing.isEmpty
    }
}

/// Whether Claude rules can run.
public enum AIState: Sendable, Equatable {
    /// No key or no consent yet, and no Claude rule waiting for one.
    case notConfigured
    case ready
    /// Rate limited, overloaded or offline: calls resume by themselves.
    case cooling(until: Date)
    /// Calls wait until the person acts.
    case paused(PauseReason)
}

/// One unfinished run.
public struct RunProgress: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var kind: RunKind
    public var rules: [RunRule]
    public var done: Int
    public var total: Int
    public var costMicros: Int64
    public var state: RunState
    public var pauseReason: RunPauseReason?

    public init(id: Int64, kind: RunKind, rules: [RunRule], done: Int, total: Int, costMicros: Int64, state: RunState, pauseReason: RunPauseReason? = nil) {
        self.id = id
        self.kind = kind
        self.rules = rules
        self.done = done
        self.total = total
        self.costMicros = costMicros
        self.state = state
        self.pauseReason = pauseReason
    }
}
