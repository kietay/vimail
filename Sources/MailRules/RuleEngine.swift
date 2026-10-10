import Foundation
import MailCore
import MailStore
import VimailLog

/// Runs one account's rules over its mail: arriving mail as sync stores it, and runs over stored
/// mail that you approve.
///
/// Work lives in the store's queue, so nothing depends on the engine being up: sync queues arriving
/// mail in the transaction that stores it, and `wake()` asks for a pass. A pass claims due rows,
/// decides each message's rules in order, cheapest first (WHEN, your marks and examples, sender
/// overrides, an earlier match in the conversation, a cached verdict), asks Claude once per message
/// for every rule still open, and commits the labels (`MailStore.commitRuleOutcomes`).
///
/// Claude is reached only through a `RuleJudge` the app injects. When it is unavailable, rules that
/// need no verdict still apply and the message waits for Claude (`waiting_ai`).
///
/// `stop()` cancels the work in progress and returns once nothing writes to the store any more.
public actor RuleEngine: RuleWaking {
    /// Passes, calls, failures and runs: IDs, counts and timings only.
    static let log = Log("rules")

    /// What Claude's verdicts are cached under, and what estimates are priced with.
    public struct JudgeConfig: Sendable, Hashable {
        public var model: String
        public var effort: String
        /// The judge prompt's version: MailAI's `JudgePrompt.versionNumber`.
        public var promptVersion: Int
        /// The model's list prices, for estimates before it made any call here.
        public var prices: TokenPrices

        public init(model: String, effort: String, promptVersion: Int, prices: TokenPrices) {
            self.model = model
            self.effort = effort
            self.promptVersion = promptVersion
            self.prices = prices
        }

        /// The offline simulator: free.
        public static let simulated = JudgeConfig(model: SimulatedJudge.model, effort: "none", promptVersion: 1, prices: TokenPrices(input: 0, cacheRead: 0, output: 0))

        /// Another model, effort or prompt: cached verdicts no longer apply and runs are priced again.
        func judgesDifferently(from other: JudgeConfig) -> Bool {
            model != other.model || effort != other.effort || promptVersion != other.promptVersion
        }
    }

    /// Messages claimed per pass.
    static let batchSize = 20
    /// Claude calls in flight at once. The app's limiter decides how many really run.
    static let judgeConcurrency = 4
    /// Claude calls for live mail per hour; more mail waits.
    static let liveCallsPerHour = 300
    /// A row fails after this many transient failures (`r` queues it again), when Claude answers
    /// other calls meanwhile: the trouble is that email.
    static let maxAttempts = 8
    /// While every call fails (an outage), rows go on at the backoff's 30-minute pace: about 8 hours.
    static let maxAttemptsWhileDown = 24
    /// Offline: calls pause this long without counting an attempt.
    static let offlineCooldown: TimeInterval = 60
    /// A pause Anthropic reported (no credit, a bad key, the model unavailable) is tried again this
    /// often: one call finds out whether it ended.
    static let pauseProbeInterval: TimeInterval = 30 * 60
    /// Live mail waiting this long for Claude (by its date) moves to a backlog run.
    static let staleWaitingAge: TimeInterval = 3 * 86_400
    static let staleCheckInterval: TimeInterval = 3_600
    static let pruneInterval: TimeInterval = 86_400
    /// The status stream publishes at most this often.
    static let statusInterval: Duration = .milliseconds(250)
    /// Account meta: rules paused by you.
    static let pausedKey = "rules_paused"

    let store: MailStore
    var judge: (any RuleJudge)?
    var config: JudgeConfig
    let clock: any RuleClock
    /// Gmail is a dry run (debug builds): labels it would get are marked simulated.
    let simulatedSync: Bool
    /// Debug builds cap each run over stored mail.
    let runMessageLimit: Int?
    let spend: (@Sendable () async -> SpendFigures?)?
    let outboxChanged: @Sendable () -> Void

    public nonisolated let status: AsyncStream<RuleEngineStatus>
    let statusContinuation: AsyncStream<RuleEngineStatus>.Continuation

    /// Every stored rule, in order. Reloaded by `rulesChanged`.
    var records: [RuleRecord] = []
    var loaded = false
    /// `userPaused` was read from the account, or set since.
    var pausedKnown = false
    /// Goes up whenever the rules change: a pass that started before does not commit.
    var epoch = 0
    var userPaused = false
    var ai: AIState
    /// A budget pause ends by itself: at midnight, or when the month turns. A pause Anthropic
    /// reported is tried again then (`pauseProbeInterval`).
    var aiPausedUntil: Date?
    /// Mail an earlier launch left waiting for Claude, and runs it paused for Claude, are released
    /// once Claude is ready; again when a release failed.
    var releasePending = true
    /// A model change could not mark the unfinished runs out of date: upkeep tries again, and
    /// nothing is claimed until it did.
    var runsOutOfDate = false
    /// The local day upkeep last saw. When it turns, runs paused at a budget continue.
    var upkeepDay: Date?
    /// When live calls were made, for the hourly cap.
    var liveCalls: [Date] = []
    /// Cost so far and cap of the runs in the current pass.
    var runSpend: [Int64: (cost: Int64, cap: Int64?)] = [:]
    /// What a call is expected to cost, held against a run's cap while it is in flight.
    var callReserve: Int64 = 0
    var breaker = CircuitBreaker()
    /// Rows being worked on, so a second claim skips them.
    var claimed: Set<QueueKey> = []
    /// Runs you cancelled or undid: calls for them stop at once, also in the batch under way.
    var haltedRuns: Set<Int64> = []
    /// The last call Claude answered (or billed), rather than failed transiently: a row that keeps
    /// failing then fails for its own email, not an outage.
    var claudeAnswered = false
    var lastStaleCheck: Date?
    var lastPrune: Date?
    /// Passes that failed in a row on a store error: the loop backs off.
    var storeFailures = 0

    var started = false
    var stopped = false
    /// `stop()` returned for the first caller; a second waits for it.
    var stopFinished = false
    var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var loop: Task<Void, Never>?
    var draining: Task<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    var wakeRequested = false
    var sleepGeneration = 0
    var calls: [UUID: Task<Result<JudgeResponse, JudgeError>, Never>] = [:]
    var previews: [UUID: Task<Void, Never>] = [:]
    var activeWrites = 0
    var writesDone: [CheckedContinuation<Void, Never>] = []
    var statusTask: Task<Void, Never>?
    var statusDirty = false
    var lastStatus: ContinuousClock.Instant?
    /// Held while a run you started works, so App Nap does not slow it down.
    var activity: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - judge: decides Claude rules; nil until a key and consent exist.
    ///   - config: the model and prompt verdicts are cached under.
    ///   - simulatedSync: Gmail changes go to a dry-run provider.
    ///   - runMessageLimit: at most this many messages per run over stored mail (debug builds).
    ///   - spend: the app's spend and budgets, for the status and run estimates.
    ///   - outboxChanged: wakes sync after commits that queued Gmail changes.
    public init(
        store: MailStore, judge: (any RuleJudge)?, config: JudgeConfig, clock: any RuleClock = SystemRuleClock(), simulatedSync: Bool,
        runMessageLimit: Int? = nil, spend: (@Sendable () async -> SpendFigures?)? = nil, outboxChanged: @escaping @Sendable () -> Void
    ) {
        self.store = store
        self.judge = judge
        self.config = config
        self.clock = clock
        self.simulatedSync = simulatedSync
        self.runMessageLimit = runMessageLimit
        self.spend = spend
        self.outboxChanged = outboxChanged
        ai = judge == nil ? .notConfigured : .ready
        (status, statusContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started, !stopped else { return }
        started = true
        Self.log.info("Rules started (model \(config.model), \(judge == nil ? "no judge" : "judge ready"))")
        loop = Task { [weak self] in await self?.run() }
    }

    /// Stops for good (the account is closing): cancels the pass, previews and Claude calls in
    /// progress, and returns once no write is under way. Nothing writes to the store afterwards.
    /// Ends the status stream. Queued work stays for the next start.
    public func stop() async {
        guard !stopped else {
            // Another stop is under way: return when it does.
            if !stopFinished { await withCheckedContinuation { stopWaiters.append($0) } }
            return
        }
        stopped = true
        let running = [loop, draining].compactMap { $0 } + Array(previews.values)
        for task in running { task.cancel() }
        for call in calls.values { call.cancel() }
        waiter?.resume()
        waiter = nil
        for task in running { await task.value }
        while activeWrites > 0 {
            await withCheckedContinuation { writesDone.append($0) }
        }
        statusTask?.cancel()
        keepAwake(false)
        statusContinuation.finish()
        Self.log.info("Rules stopped")
        stopFinished = true
        for waiter in stopWaiters { waiter.resume() }
        stopWaiters = []
    }

    /// Asks for a pass soon. Sync calls it after storing arrived mail.
    public nonisolated func wake() {
        Task { await self.wakeNow() }
    }

    func wakeNow() {
        guard started, !stopped else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            wakeRequested = true
        }
    }

    private func run() async {
        try? await loadIfNeeded()
        refreshStatus()
        while !Task.isCancelled && !stopped {
            await drain()
            await sleep(until: await nextWake())
        }
    }

    /// When the loop has something to do next without a wake: a retry, the end of a cooldown or
    /// budget pause, upkeep, the next day (runs paused at a budget continue), or another try after a
    /// store error.
    private func nextWake() async -> Date? {
        let now = clock.now
        let calendar = Calendar.current
        var dates = [
            lastStaleCheck.map { $0.addingTimeInterval(Self.staleCheckInterval) },
            lastPrune.map { $0.addingTimeInterval(Self.pruneInterval) },
            aiPausedUntil,
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
        ]
        if case .cooling(let until) = ai { dates.append(until) }
        if storeFailures > 0 {
            dates.append(now.addingTimeInterval(min(60, pow(2, Double(storeFailures)))))
        } else if !userPaused {
            dates.append(try? await store.nextRuleQueueDueDate(after: now))
        }
        return dates.compactMap { $0 }.min()
    }

    private func sleep(until deadline: Date?) async {
        guard !Task.isCancelled, !stopped else { return }
        if wakeRequested {
            wakeRequested = false
            return
        }
        sleepGeneration += 1
        let generation = sleepGeneration
        let clock = clock
        let timer = deadline.map { deadline in
            Task { [weak self] in
                do { try await clock.sleep(until: deadline) } catch { return }
                await self?.timerFired(generation)
            }
        }
        await withCheckedContinuation { waiter = $0 }
        timer?.cancel()
    }

    private func timerFired(_ generation: Int) {
        guard generation == sleepGeneration, let waiter else { return }
        self.waiter = nil
        waiter.resume()
    }

    /// Reads your pause and the rules, each once. The pause is read even when `rulesChanged` loaded
    /// the rules first.
    func loadIfNeeded() async throws {
        if !pausedKnown {
            let paused = try await store.meta(Self.pausedKey) == "1"
            // `setPaused` may have answered during the read.
            if !pausedKnown {
                userPaused = paused
                pausedKnown = true
            }
        }
        guard !loaded else { return }
        records = try await store.rules()
        loaded = true
    }

    func reloadRules() async throws {
        records = try await store.rules()
        loaded = true
        epoch += 1
    }

    /// Picks up rules the store changed without `rulesChanged`: a label deleted here or in Gmail turns
    /// its rules off, and a label's new ID rewrites them. Before each batch, so a rule that is off
    /// never reaches Claude. Mail that waited for Claude may not need it any more.
    func refreshRules() async throws {
        let stored = try await store.rules()
        guard loaded, stored != records else { return }
        // Dates only (a run moved `covered_since` back): nothing a pass decides with.
        func meaning(_ records: [RuleRecord]) -> [[AnyHashable]] { records.map { [$0.rule, $0.position, $0.state] } }
        let changed = meaning(stored) != meaning(records)
        let asked = Set(enabledRules.filter(\.asksClaude).map(\.id))
        records = stored
        guard changed else { return }
        epoch += 1
        let asking = Set(enabledRules.filter(\.asksClaude).map(\.id))
        Self.log.info("Rules changed in the store: reloaded")
        if !asked.isSubset(of: asking) { _ = try await releaseWaiting() }
    }

    // MARK: - Writes and calls

    /// Runs a store write unless the engine is stopping. `stop()` waits for the writes under way.
    /// - Parameter evenWhenStopping: for verdicts Claude already billed, from a pass `stop()` waits for.
    @discardableResult
    func writing<T: Sendable>(evenWhenStopping: Bool = false, _ body: () async throws -> T) async throws -> T {
        guard !stopped || evenWhenStopping else { throw RuleEngineError.stopped }
        activeWrites += 1
        defer { writeEnded() }
        return try await body()
    }

    private func writeEnded() {
        activeWrites -= 1
        guard activeWrites == 0 else { return }
        for waiter in writesDone { waiter.resume() }
        writesDone = []
    }

    /// One judge call that `stop()` and the caller's cancellation can cancel. A failure comes without
    /// its `JudgeError.billed` wrapper: `billed` is what Claude charged before it failed.
    func callJudge(_ judge: any RuleJudge, _ request: JudgeRequest) async -> (result: Result<JudgeResponse, JudgeError>, billed: Int64) {
        let id = UUID()
        let task = Task { () async -> Result<JudgeResponse, JudgeError> in
            do throws(JudgeError) {
                return .success(try await judge.judge(request))
            } catch {
                return .failure(error)
            }
        }
        calls[id] = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        calls[id] = nil
        guard case .failure(let error) = result else { return (result, 0) }
        return (.failure(error.unbilled), error.billedMicros)
    }

    // MARK: - Settings

    /// Pauses or resumes all rules for this account; remembered across launches. While paused no
    /// mail is processed; it stays queued.
    public func setPaused(_ paused: Bool) async throws {
        try await writing { try await store.setMeta(Self.pausedKey, paused ? "1" : nil) }
        userPaused = paused
        pausedKnown = true
        Self.log.info(paused ? "Rules paused" : "Rules resumed")
        refreshStatus()
        if !paused { wakeNow() }
    }

    /// A new judge, model or Claude pause from the app. Another model marks unfinished runs out of
    /// date (`model_changed`), so they continue only after a new estimate. Claude becoming available
    /// releases the mail that waited for it.
    /// - Parameter aiPause: why Claude can't be used (no key, no consent…), or nil.
    public func configure(judge: (any RuleJudge)?, aiPause: PauseReason?, config: JudgeConfig) async {
        guard !stopped else { return }
        let changed = config.judgesDifferently(from: self.config)
        self.judge = judge
        self.config = config
        if changed {
            epoch += 1
            await markRunsOutOfDate()
        }
        if let aiPause {
            pauseLane(aiPause)
        } else if judge == nil {
            ai = .notConfigured
            aiPausedUntil = nil
        } else if ai != .ready {
            await laneReady()
        }
        refreshStatus()
    }

    /// The rules changed: reload them. Edits that change what a rule decides already paused its runs
    /// in the store; a pass that started before the change does not commit.
    ///
    /// For `.enabled`, pass the time the rule was off (what `MailStore.setRuleEnabled` returned): mail
    /// that arrived meanwhile becomes a `gap` run that waits for your confirmation. Returns its ID.
    @discardableResult
    public func rulesChanged(_ change: RuleChange, gap: DateInterval? = nil) async throws -> Int64? {
        guard !stopped else { throw RuleEngineError.stopped }
        try await reloadRules()
        var gapRun: Int64?
        switch change {
        case .revised(let id, _), .disabled(let id), .deleted(let id):
            breaker.forget(id)
            // Mail that waited for Claude may not need it any more.
            _ = try await releaseWaiting()
        case .enabled(let id):
            breaker.forget(id)
            if let gap { gapRun = try await makeGapRun(ruleID: id, gap: gap) }
        case .created, .updated, .reordered:
            break
        }
        refreshStatus()
        wakeNow()
        return gapRun
    }

    // MARK: - Rules

    /// Rules that run on new mail, in order.
    var enabledRules: [Rule] {
        records.filter { $0.rule.enabled && $0.rule.isSupported && $0.state == .ok }.map(\.rule)
    }

    func judgeHash(_ rule: Rule) -> String? {
        rule.judgeHash(model: config.model, effort: config.effort, promptVersion: config.promptVersion)
    }

    // MARK: - Claude lane

    /// Whether a Claude call may go out now.
    enum LaneCheck {
        case go
        /// Claude can't be used until something changes (key, consent, budget, model).
        case unavailable
        /// Cooling down after a rate limit or the network: try again then.
        case wait(until: Date)
    }

    func laneCheck() -> LaneCheck {
        guard judge != nil else { return .unavailable }
        switch ai {
        case .ready:
            return .go
        case .notConfigured, .paused:
            return .unavailable
        case .cooling(let until):
            guard clock.now < until else {
                ai = .ready
                return .go
            }
            return .wait(until: until)
        }
    }

    /// - Parameter fromClaude: Anthropic answered with it (no credit or a usage limit, a rejected key,
    ///   the model or the API unavailable). That can end without anything changing here, such as when
    ///   you add credit, so one call tries again after `pauseProbeInterval`. Pauses the app sets (no
    ///   key, no consent) end only through `configure`.
    func pauseLane(_ reason: PauseReason, fromClaude: Bool = false) {
        guard ai != .paused(reason) else { return }
        ai = .paused(reason)
        let calendar = Calendar.current
        let now = clock.now
        switch reason {
        case .budgetDay:
            aiPausedUntil = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .budgetMonth:
            let month = calendar.dateInterval(of: .month, for: now)
            aiPausedUntil = month?.end
        default:
            aiPausedUntil = fromClaude ? now.addingTimeInterval(Self.pauseProbeInterval) : nil
        }
        Self.log.notice("Claude rules paused: \(reason.rawValue)")
        refreshStatus()
    }

    /// Rate limited, overloaded or offline: calls wait until `until`. A pause stays a pause.
    func coolDown(until: Date) {
        switch ai {
        case .ready:
            ai = .cooling(until: until)
        case .cooling(let current) where current < until:
            ai = .cooling(until: until)
        default:
            break
        }
    }

    /// Claude is available again: mail that waited for it is due, and runs paused for it continue.
    func laneReady() async {
        ai = .ready
        aiPausedUntil = nil
        do {
            let released = try await releaseWaiting()
            let resumed = try await resumeRuns(pausedFor: .ai)
            releasePending = false
            Self.log.info("Claude rules ready: \(released) waiting message(s) released, \(resumed) run(s) resumed")
        } catch {
            releasePending = true
            Self.log.error("Could not release mail waiting for Claude: \(String(describing: type(of: error)))")
        }
        refreshStatus()
        wakeNow()
    }

    /// Mail waiting for Claude is due again, apart from what waited too long: that moves to a backlog
    /// run first, which waits for your confirmation (`holdStaleWaiting`), also after a relaunch or a
    /// pause that ended while the app was closed. Returns how many were released.
    func releaseWaiting() async throws -> Int {
        try await holdStaleWaiting()
        return try await writing { try await store.releaseWaitingAI() }
    }

    /// Arrived mail that waited 3 days for Claude (by its date) moves to a backlog run that waits for
    /// your confirmation, so labels never land weeks late in one burst.
    func holdStaleWaiting() async throws {
        let now = clock.now
        lastStaleCheck = now
        if let backlog = try await writing({ try await store.holdStaleWaiting(olderThan: Self.staleWaitingAge, now: now) }) {
            Self.log.notice("Mail waited 3 days for Claude: held in backlog run #\(backlog) for confirmation")
            refreshStatus()
        }
    }

    /// Continues the runs paused for `reason`. Returns how many.
    func resumeRuns(pausedFor reason: RunPauseReason) async throws -> Int {
        var resumed = 0
        for run in try await store.runs(unfinished: true) where run.state == .paused && run.pauseReason == reason {
            if try await writing({ try await store.resumeRun(run.id) }) { resumed += 1 }
        }
        return resumed
    }

    /// After a model change, unfinished runs wait for a new estimate (`model_changed`).
    func markRunsOutOfDate() async {
        do {
            let paused = try await writing { try await store.pauseRuns(reason: .modelChanged) }
            runsOutOfDate = false
            Self.log.info("Model changed: \(paused.count) run(s) out of date")
        } catch {
            runsOutOfDate = true
            Self.log.error("Could not mark runs out of date after a model change: \(String(describing: type(of: error)))")
        }
    }

    // MARK: - Upkeep

    /// Before each pass: lifts a budget pause that has run out (or tries Claude again after a pause
    /// Anthropic reported), releases what an earlier launch left waiting for Claude, retries marking
    /// runs out of date after a model change, continues runs paused at a budget once the day turns,
    /// moves mail that waited too long for Claude to a backlog run, and once a day deletes rule
    /// history past its use.
    func maintain() async {
        let now = clock.now
        if case .paused = ai, let until = aiPausedUntil, now >= until { await laneReady() }
        if releasePending, judge != nil, ai == .ready { await laneReady() }
        if runsOutOfDate { await markRunsOutOfDate() }
        // A new day, or a new launch, may have refilled what runs may spend. A run whose budget is
        // still spent pauses again at its first call, which the app's spend guard refuses unsent.
        let day = Calendar.current.startOfDay(for: now)
        if upkeepDay != day {
            do {
                let resumed = try await resumeRuns(pausedFor: .budget)
                upkeepDay = day
                if resumed > 0 {
                    Self.log.info("New day: \(resumed) run(s) paused at a budget continue")
                    refreshStatus()
                }
            } catch {
                Self.log.error("Could not continue runs paused at a budget: \(String(describing: type(of: error)))")
            }
        }
        if lastStaleCheck.map({ now.timeIntervalSince($0) >= Self.staleCheckInterval }) ?? true {
            do {
                try await holdStaleWaiting()
            } catch {
                Self.log.error("Could not check for stale waiting mail: \(String(describing: type(of: error)))")
            }
        }
        if lastPrune.map({ now.timeIntervalSince($0) >= Self.pruneInterval }) ?? true {
            lastPrune = now
            let hashes = Set(records.compactMap { judgeHash($0.rule) })
            do {
                try await writing { try await store.pruneRuleHistory(now: now, judgeHashesInUse: hashes) }
            } catch {
                Self.log.error("Could not prune rule history: \(String(describing: type(of: error)))")
            }
        }
    }

    // MARK: - Status

    /// Publishes a new status soon, at most every 250 ms.
    func refreshStatus() {
        guard !stopped else { return }
        statusDirty = true
        guard statusTask == nil else { return }
        statusTask = Task { await self.publishStatus() }
    }

    private func publishStatus() async {
        let pace = ContinuousClock()
        while statusDirty && !stopped && !Task.isCancelled {
            if let last = lastStatus {
                let wait = last.advanced(by: Self.statusInterval) - pace.now
                if wait > .zero { try? await Task.sleep(for: wait) }
            }
            statusDirty = false
            let status = await makeStatus()
            guard !stopped else { break }
            lastStatus = pace.now
            // Not while you paused all rules: nothing works then.
            keepAwake(!status.userPaused && status.runs.contains { $0.state == .running })
            statusContinuation.yield(status)
        }
        statusTask = nil
    }

    func makeStatus() async -> RuleEngineStatus {
        var status = RuleEngineStatus()
        status.ai = ai
        if case .cooling(let until) = ai, until <= clock.now { status.ai = .ready }
        status.userPaused = userPaused
        if let counts = try? await store.ruleQueueCounts() {
            status.liveQueued = counts.liveQueued
            status.waitingAI = counts.waitingAI
            status.held = counts.held
            status.failed = counts.failed
        }
        status.unsureToReview = (try? await store.unsureToReviewCount()) ?? 0
        if let runs = try? await store.runs(unfinished: true) {
            status.runs = runs.filter { $0.kind != .live }.map {
                // An estimate made for other rules or another model is out of date: `estimate(runID:)` prices it.
                let current = $0.pauseReason != .ruleChanged && $0.pauseReason != .modelChanged
                return RunProgress(
                    id: $0.id, kind: $0.kind, rules: $0.rules, done: $0.done, total: $0.total, costMicros: $0.costMicros, state: $0.state,
                    pauseReason: $0.pauseReason, estimateMicros: current ? $0.estimateMicros : nil
                )
            }
        }
        if let records = try? await store.rules() {
            status.tripped = records.filter { $0.state == .tripped }.map(\.id)
            status.labelMissing = records.filter { $0.state == .labelMissing }.map(\.id)
        }
        if let figures = await spend?() { status.apply(figures) }
        return status
    }

    /// App Nap is held off.
    var keepsAwake: Bool { activity != nil }

    /// Keeps App Nap away while a run over stored mail works.
    func keepAwake(_ active: Bool) {
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "applying rules to stored mail")
            Self.log.info("App Nap off: a rules run is working")
        } else if !active, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

/// Why the engine refused a request.
public enum RuleEngineError: Error, Equatable, Sendable {
    /// The engine stopped: the account closed.
    case stopped
    case ruleNotFound
    case runNotFound
}

/// List prices in dollars per million tokens, which is micro-dollars per token.
public struct TokenPrices: Sendable, Hashable {
    public var input: Double
    public var cacheRead: Double
    public var output: Double

    public init(input: Double, cacheRead: Double, output: Double) {
        self.input = input
        self.cacheRead = cacheRead
        self.output = output
    }
}

/// The time, and a way to wait for it. Tests move it by hand.
public protocol RuleClock: Sendable {
    var now: Date { get }
    /// Returns at `deadline`, or at once when it has passed. Throws when the task is cancelled.
    func sleep(until deadline: Date) async throws
}

/// The system clock.
public struct SystemRuleClock: RuleClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let seconds = deadline.timeIntervalSinceNow
        if seconds > 0 { try await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded(.up)))) }
    }
}
