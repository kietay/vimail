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
    /// Runs over stored mail that are not finished: running, paused or awaiting confirmation.
    /// Live mail shows as `liveQueued`.
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

    /// Takes spend and budgets from what the app's spend guard reports.
    mutating func apply(_ figures: SpendFigures) {
        spendToday = figures.spendToday
        spendMonth = figures.spendMonth
        budgetDay = figures.budgetDay
        budgetMonth = figures.budgetMonth
        runRoomToday = figures.runRoomToday
        previewLeft = figures.previewLeft
    }

    /// Nothing to show: no work, no problem to report, so the status bar hides its rules segment
    /// (`statusLine()` is nil). Runs waiting on a budget or your confirmation, and Claude waiting
    /// for a key or your consent while no mail waits, are no problem.
    public var isIdle: Bool { statusLine() == nil }
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
    /// What the run is expected to cost ("≈ $x"). nil when it has no current estimate: a backlog run,
    /// or one whose rules or model changed. `RuleEngine.estimate(runID:)` prices those.
    public var estimateMicros: Int64?

    public init(
        id: Int64, kind: RunKind, rules: [RunRule], done: Int, total: Int, costMicros: Int64, state: RunState, pauseReason: RunPauseReason? = nil,
        estimateMicros: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.rules = rules
        self.done = done
        self.total = total
        self.costMicros = costMicros
        self.state = state
        self.pauseReason = pauseReason
        self.estimateMicros = estimateMicros
    }
}

/// Claude spend and budgets for the whole app, in millionths of a dollar. The app reads them from
/// its spend guard; the engine shows them in its status and checks run estimates against them.
public struct SpendFigures: Sendable, Equatable {
    public var spendToday: Int64
    public var spendMonth: Int64
    public var budgetDay: Int64
    public var budgetMonth: Int64
    /// What runs may still spend today, after the reserve kept for live mail.
    public var runRoomToday: Int64
    /// What previews may still spend today.
    public var previewLeft: Int64

    public init(spendToday: Int64, spendMonth: Int64, budgetDay: Int64, budgetMonth: Int64, runRoomToday: Int64, previewLeft: Int64) {
        self.spendToday = spendToday
        self.spendMonth = spendMonth
        self.budgetDay = budgetDay
        self.budgetMonth = budgetMonth
        self.runRoomToday = runRoomToday
        self.previewLeft = previewLeft
    }
}
