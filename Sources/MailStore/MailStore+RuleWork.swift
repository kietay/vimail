import Foundation
import MailCore

/// Which newly stored messages `applyRemoteChanges` queues for rules, in the same transaction.
public enum RuleIntake: Sendable, Hashable {
    /// Nothing: the first sync, the background download of older mail, refetches.
    case none
    /// Mail that just arrived through history, by ID. Conversations fetched only as context for a
    /// reply are not in it.
    case live(arrived: Set<String>)
    /// The full download after history expired: mail that arrived since rules last processed live mail.
    case resync
}

/// One message's row in one run's queue.
public struct QueueKey: Hashable, Sendable {
    public var messageID: String
    public var runID: Int64

    public init(messageID: String, runID: Int64) {
        self.messageID = messageID
        self.runID = runID
    }
}

/// A due queue row, for one pass.
public struct QueueClaim: Hashable, Sendable {
    public var key: QueueKey
    public var runKind: RunKind
    /// 0 live, 1 manual, 2 other runs.
    public var priority: Int
    /// Attempts that failed so far.
    public var attempts: Int
}

/// Queue rows by state, for the rules status.
public struct RuleQueueCounts: Hashable, Sendable {
    /// Arrived messages waiting for their pass.
    public var liveQueued = 0
    /// Waiting until Claude is available again.
    public var waitingAI = 0
    /// Held for a run that waits for your confirmation.
    public var held = 0
    public var failed = 0
}

/// A run, as Activity lists it.
public struct RunRecord: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var kind: RunKind
    /// Live runs: the local day, "2026-10-09".
    public var day: String?
    /// Its rules at their revisions. A live run lists the rules on when its day began; live mail
    /// always gets each rule's current revision.
    public var rules: [RunRule]
    /// The dates of mail it was made for, if it was made for a window.
    public var window: ClosedRange<Date>?
    public var state: RunState
    /// Why it is paused. For a run waiting for confirmation, why its rules or estimate are out of date
    /// (`rule_changed`, `model_changed`): confirm it with the current ones.
    public var pauseReason: RunPauseReason?
    public var model: String?
    /// Messages queued in it.
    public var total: Int
    /// Messages committed.
    public var done: Int
    /// Claude calls made.
    public var judged: Int
    /// Messages that got a label.
    public var labeled: Int
    /// Messages that failed (`r` re-queues them).
    public var failed: Int
    /// A re-check's first pass: labels applying it adds and removes.
    public var plus: Int?
    public var minus: Int?
    public var estimateMicros: Int64?
    /// It pauses (`cap`) when its cost reaches this.
    public var capMicros: Int64?
    public var costMicros: Int64
    public var createdAt: Date
    /// When you confirmed it. Backlog, gap and re-check runs wait for that.
    public var confirmedAt: Date?
    public var finishedAt: Date?

    /// A re-check before you confirmed it: its pass only counts what applying would change.
    public var isDryRun: Bool { kind == .recheck && confirmedAt == nil }
}

/// A rule's decision for a message as stored, with the run that made it.
public struct StoredDecision: Hashable, Sendable {
    public var decision: RuleDecision
    public var runID: Int64
    public var decidedAt: Date
}

/// Claude's verdict on one message for one ASK, cached by the rule's judge hash.
public struct StoredVerdict: Hashable, Sendable {
    public var messageID: String
    public var judgeHash: String
    public var verdict: Verdict
    /// A few words of evidence. Shown by "why these labels?", never logged.
    public var reason: String
    /// Identifies the examples the prompt carried, so a verdict made before newer marks can be told.
    public var examplesDigest: String
    /// The model asked, and the one that answered (another after a server-side fallback).
    public var model: String
    public var servedBy: String
    public var createdAt: Date

    public init(
        messageID: String, judgeHash: String, verdict: Verdict, reason: String, examplesDigest: String, model: String, servedBy: String,
        createdAt: Date = Date()
    ) {
        self.messageID = messageID
        self.judgeHash = judgeHash
        self.verdict = verdict
        self.reason = reason
        self.examplesDigest = examplesDigest
        self.model = model
        self.servedBy = servedBy
        self.createdAt = createdAt
    }
}

/// What rules know about a message before deciding it: headers, labels, your edits and earlier
/// decisions. No bodies: `judgeInputs(messageID:)` loads those when Claude is needed.
public struct MessageFacts: Hashable, Sendable {
    public var messageID: String
    public var threadID: String
    public var from: EmailAddress
    public var subject: String
    public var date: Date
    public var labelIDs: Set<String>
    /// Mailing-list mail (List-Unsubscribe present).
    public var isList: Bool
    /// Your label marks: label ID → you added (true) or removed (false) it.
    public var marks: [String: Bool] = [:]
    /// ✔ (true) and ✖ (false) examples, by rule ID.
    public var examples: [String: Bool] = [:]
    /// Sender overrides for this sender, by rule ID: an exact address wins over its domain.
    public var overrides: [String: Bool] = [:]
    /// Earlier decisions, by rule ID.
    public var decisions: [String: StoredDecision] = [:]
    /// Rules that matched an earlier message of the conversation, for opt-in inheritance.
    public var threadMatches: Set<String> = []
    /// Labels you removed from a message of the conversation: inheritance never brings them back.
    public var threadRemovals: Set<String> = []
}

/// A message with its conversation up to it, bodies included: what `EmailDigest` needs.
public struct JudgeInputs: Hashable, Sendable {
    public var message: MailMessage
    /// Oldest first, ending with `message`.
    public var thread: [MailMessage]
}

/// The stored mail a run would cover, for its estimate.
public enum EstimateWindow: Sendable, Hashable {
    /// Back to the `n`th newest message that needs Claude ("Newest 100 for Claude").
    case newestNeedingClaude(Int)
    /// Mail dated in the range: the last 14, 30 or 90 days, or the time a rule was off.
    case dates(ClosedRange<Date>)
    /// All stored mail.
    case allCached
}

/// Exact counts for running one rule over stored mail. The engine prices `needClaude`.
public struct RuleEstimate: Hashable, Sendable {
    /// The dates covered, nil for all stored mail. The run's messages come from the same window.
    public var window: ClosedRange<Date>?
    /// Messages in the rule's scope.
    public var inScope: Int
    /// Of those, the ones that pass WHEN, label terms included.
    public var passing: Int
    /// Of those, the ones decided without a call: your marks, examples, sender overrides, a cached
    /// verdict or a decision at the rule's revision. All of them for a rule without an ASK.
    public var decidedFree: Int
    /// Of those decided without a call, each counted once, in this order: by your marks, examples
    /// and sender overrides; by a cached verdict; by an earlier pass at the rule's revision.
    public var decidedByYou: Int
    public var cachedVerdicts: Int
    public var decidedEarlier: Int
    /// The rest: one Claude call each.
    public var needClaude: Int
    /// The oldest and newest messages needing Claude ("≈ 5 days").
    public var claudeSpan: ClosedRange<Date>?
}

/// Rules' work on stored mail: which messages pass a WHEN, and the queue that new mail enters.
extension MailStore {
    /// How many messages a resync queues for the live run. The rest wait in a backlog run for confirmation.
    static let resyncLiveLimit = 500

    // MARK: - Matching

    /// Messages in `scope` that pass `filter`, newest first. Reads on the background connection.
    /// - Parameters:
    ///   - labelTerms: also test the filter's `label:` terms against stored labels (previews and
    ///     estimates). The engine tests them in memory instead, where earlier rules' labels count too.
    ///   - messageIDs: only these messages.
    ///   - window: only messages dated inside it.
    ///   - limit: at most this many, the newest.
    public func ruleMatches(
        _ filter: RuleFilter, scope: RuleScope.Mailboxes, labelTerms: Bool = true, among messageIDs: [String]? = nil,
        window: ClosedRange<Date>? = nil, newestFirst limit: Int? = nil
    ) async throws -> [String] {
        let query = MessageQuery(search: Self.search(filter, labelTerms: labelTerms), mailboxes: scope, ids: messageIDs, window: window, limit: limit)
        let me = selfAddresses
        return try await readBackground { db in
            let (sql, args) = try Self.messageQuerySQL(query, me: me, selecting: "m.id", ordered: true)
            return try db.query(sql, args) { $0.string(0) }
        }
    }

    /// How many messages `ruleMatches` would list without a limit.
    public func ruleMatchCount(
        _ filter: RuleFilter, scope: RuleScope.Mailboxes, labelTerms: Bool = true, among messageIDs: [String]? = nil,
        window: ClosedRange<Date>? = nil
    ) async throws -> Int {
        let query = MessageQuery(search: Self.search(filter, labelTerms: labelTerms), mailboxes: scope, ids: messageIDs, window: window)
        let me = selfAddresses
        return try await readBackground { db in
            let (sql, args) = try Self.messageQuerySQL(query, me: me, selecting: "COUNT(*)", ordered: false)
            return try db.scalar(sql, args)
        }
    }

    /// The conversations of the messages in `scope` that pass `filter`: the rule editor lists every
    /// match. Reads on the background connection.
    public func ruleMatchThreads(_ filter: RuleFilter, scope: RuleScope.Mailboxes) async throws -> [String] {
        let query = MessageQuery(search: Self.search(filter, labelTerms: true), mailboxes: scope)
        let me = selfAddresses
        return try await readBackground { db in
            let (sql, args) = try Self.messageQuerySQL(query, me: me, selecting: "DISTINCT m.thread_id", ordered: false)
            return try db.query(sql, args) { $0.string(0) }
        }
    }

    /// The date of the oldest stored message in `scope`, or nil when there is none: how far back
    /// "all cached" mail goes. Reads on the background connection.
    public func oldestMessageDate(scope: RuleScope.Mailboxes) async throws -> Date? {
        let me = selfAddresses
        return try await readBackground { db in
            let (sql, args) = try Self.messageQuerySQL(MessageQuery(search: SearchQuery(), mailboxes: scope), me: me, selecting: "MIN(m.date)", ordered: false)
            return try db.first(sql, args) { $0.isNull(0) ? nil : $0.date(0) } ?? nil
        }
    }

    /// Messages in `scope` that carry `labelID`, newest first: a rule's preview checks it finds them.
    /// Reads on the background connection.
    public func scopeMessages(carrying labelID: String, scope: RuleScope.Mailboxes, newestFirst limit: Int) async throws -> [String] {
        let me = selfAddresses
        return try await readBackground { db in
            let (inScope, args) = Self.scopeCondition(scope, me: me)
            return try db.query(
                """
                SELECT m.id FROM messages m
                WHERE \(inScope) AND EXISTS (SELECT 1 FROM message_labels x WHERE x.message_id = m.id AND x.label_id = ?)
                ORDER BY m.date DESC LIMIT ?
                """,
                args + [labelID as SQLBindable, limit]
            ) { $0.string(0) }
        }
    }

    /// A rule's WHEN as a search, with or without its label terms.
    static func search(_ filter: RuleFilter, labelTerms: Bool) -> SearchQuery {
        var search = filter.query
        if labelTerms {
            search.labelNames = filter.labelTerms.filter { !$0.negated }.map(\.name)
            search.excludedLabelNames = filter.labelTerms.filter(\.negated).map(\.name)
        }
        return search
    }

    // MARK: - Intake

    /// A resync in progress (meta `rules_resync`): the live watermark when it started, how many
    /// messages it queued live, and the backlog run holding the rest.
    struct ResyncIntake: Codable {
        /// nil when rules had not processed live mail yet: nothing is queued.
        var since: Date?
        var live = 0
        var backlog: Int64?
    }

    /// Queues newly stored messages for rules, inside the transaction that stored them. Only
    /// received mail (`RuleScope.Mailboxes.received`) is queued, and only while a rule can run.
    static func queueForRules(_ inserted: [String], intake: RuleIntake, me: Set<String>, _ db: SQLiteDatabase) throws {
        switch intake {
        case .none:
            return
        case .live(let arrived):
            let arriving = inserted.filter(arrived.contains)
            guard !arriving.isEmpty else { return }
            let rules = try runnableRules(db)
            guard !rules.isEmpty else { return }
            let received = try receivedMessages(arriving, since: nil, me: me, db)
            guard !received.isEmpty else { return }
            try queue(received, run: try liveRun(rules, db), priority: 0, held: false, db)
        case .resync:
            // Fixed when the resync starts: live processing moves the watermark meanwhile.
            var resync = try resyncIntake(db) ?? ResyncIntake(since: try liveWatermark(db))
            try queueResync(inserted, me: me, &resync, db)
            try setMeta("rules_resync", try json(resync), db)
        }
    }

    /// Queues one resync batch: the newest go to today's live run until `resyncLiveLimit` is reached
    /// (downloads go newest first), the rest are held in the backlog run.
    static func queueResync(_ inserted: [String], me: Set<String>, _ resync: inout ResyncIntake, _ db: SQLiteDatabase) throws {
        guard let since = resync.since, !inserted.isEmpty else { return }
        let rules = try runnableRules(db)
        guard !rules.isEmpty else { return }
        let received = try receivedMessages(inserted, since: since, me: me, db)
        let room = max(0, resyncLiveLimit - resync.live)
        let live = Array(received.prefix(room))
        let held = Array(received.dropFirst(room))
        if !live.isEmpty {
            try queue(live, run: try liveRun(rules, db), priority: 0, held: false, db)
            resync.live += live.count
        }
        if !held.isEmpty {
            // A new backlog run once the earlier one was confirmed or cancelled.
            let waiting = try resync.backlog.flatMap { id in
                try db.first("SELECT id FROM rule_runs WHERE id = ? AND state = 'awaiting_confirm'", [id]) { $0.int64(0) }
            }
            let backlog = try waiting ?? createRun(.backlog, rules: rules.map(RunRule.init), state: .awaitingConfirm, db)
            resync.backlog = backlog
            try queue(held, run: backlog, priority: 2, held: true, db)
        }
    }

    /// Ends a full resync: clears its flag and what intake kept about it.
    public func endResync() async throws {
        try await write { db, _ in
            try Self.setMeta("resync", nil, db)
            try Self.setMeta("rules_resync", nil, db)
        }
    }

    static func resyncIntake(_ db: SQLiteDatabase) throws -> ResyncIntake? {
        try db.first("SELECT value FROM meta WHERE key = 'rules_resync'") { row in
            try? decoder.decode(ResyncIntake.self, from: Data(row.string(0).utf8))
        } ?? nil
    }

    /// The newest arrival rules have processed live (meta `rules_live_watermark`, in milliseconds).
    static func liveWatermark(_ db: SQLiteDatabase) throws -> Date? {
        let value = try db.first("SELECT value FROM meta WHERE key = 'rules_live_watermark'") { Double($0.string(0)) } ?? nil
        return value.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// The given messages that rules may see, newest first, optionally only those dated `since` or later.
    static func receivedMessages(_ ids: [String], since: Date?, me: Set<String>, _ db: SQLiteDatabase) throws -> [String] {
        var search = SearchQuery()
        search.after = since
        let (sql, args) = try messageQuerySQL(MessageQuery(search: search, mailboxes: .received, ids: ids), me: me, selecting: "m.id", ordered: true)
        return try db.query(sql, args) { $0.string(0) }
    }

    /// Today's live run, created with the rules that can run now. There is one per day, apart from
    /// runs you undid: later arrivals go to a new one.
    static func liveRun(_ rules: [Rule], _ db: SQLiteDatabase) throws -> Int64 {
        let day = liveDay(Date())
        if let id = try db.first("SELECT id FROM rule_runs WHERE kind = 'live' AND day = ? AND state != 'undone'", [day], { $0.int64(0) }) {
            try db.run("UPDATE rule_runs SET state = 'running', finished_at = NULL WHERE id = ? AND state = 'done'", [id])
            return id
        }
        return try createRun(.live, day: day, rules: rules.map(RunRule.init), state: .running, db)
    }

    static func createRun(
        _ kind: RunKind, day: String? = nil, rules: [RunRule], state: RunState, window: ClosedRange<Date>? = nil,
        estimateMicros: Int64? = nil, capMicros: Int64? = nil, model: String? = nil, _ db: SQLiteDatabase
    ) throws -> Int64 {
        try db.run(
            """
            INSERT INTO rule_runs(kind, day, rules, window_start, window_end, state, model, est_micros, cap_micros, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                kind.rawValue, day, try json(rules), window?.lowerBound, window?.upperBound, state.rawValue, model,
                estimateMicros, capMicros, Date(),
            ]
        )
        return db.lastInsertRowID
    }

    /// The local day a live run covers, such as "2026-10-09".
    static func liveDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Adds messages to a run's queue (`held` ones wait for the run to be confirmed) and counts them in its total.
    static func queue(_ messageIDs: [String], run: Int64, priority: Int, held: Bool, _ db: SQLiteDatabase) throws {
        var added = 0
        for id in messageIDs {
            try db.run(
                "INSERT OR IGNORE INTO rule_queue(message_id, run_id, priority, state) VALUES (?, ?, ?, ?)",
                [id, run, priority, held ? "held" : "queued"]
            )
            added += db.changes
        }
        try db.run("UPDATE rule_runs SET total = total + ? WHERE id = ?", [added, run])
    }
}

/// The queue, runs, decisions and Claude's verdicts.
extension MailStore {
    /// Calls averaged for a model's cost per call.
    static let callCostSample = 50

    // MARK: - Queue

    /// Due queue rows, best first: by priority, then the newest message. Only rows of running runs:
    /// never those of paused, cancelled, undone runs or runs waiting for confirmation.
    ///
    /// Claiming writes nothing. A row stays queued until its pass commits it (`commitRuleOutcomes`),
    /// retries it, fails it or sets it waiting. The engine is the only claimer: it passes the rows it
    /// is working on as `claimed`, so a second claim never returns them, and rows it held when it
    /// stopped or crashed are simply due again. Reads on the background connection.
    public func claimDueRules(limit: Int = 20, now: Date = Date(), excluding claimed: Set<QueueKey> = []) async throws -> [QueueClaim] {
        try await readBackground { db in
            let rows = try db.query(
                """
                SELECT q.message_id, q.run_id, r.kind, q.priority, q.attempts
                FROM rule_queue q
                JOIN rule_runs r ON r.id = q.run_id AND r.state = 'running'
                JOIN messages m ON m.id = q.message_id
                WHERE q.state = 'queued' AND q.not_before <= ?
                ORDER BY q.priority, m.date DESC
                LIMIT ?
                """,
                [now, limit + claimed.count]
            ) { row in
                QueueClaim(
                    key: QueueKey(messageID: row.string(0), runID: row.int64(1)), runKind: RunKind(rawValue: row.string(2)) ?? .live,
                    priority: row.int(3), attempts: row.int(4)
                )
            }
            return Array(rows.filter { !claimed.contains($0.key) }.prefix(limit))
        }
    }

    /// When the next row waiting for its retry is due, if any is not due yet.
    public func nextRuleQueueDueDate(after now: Date = Date()) async throws -> Date? {
        try await readBackground { db in
            try db.first(
                "SELECT MIN(q.not_before) FROM rule_queue q JOIN rule_runs r ON r.id = q.run_id AND r.state = 'running' WHERE q.state = 'queued' AND q.not_before > ?",
                [now]
            ) { $0.optionalDate(0) } ?? nil
        }
    }

    /// After a transient failure: the row is due again at `notBefore`.
    /// - Parameter errorCode: what failed, such as "http_529". Never message content.
    public func retryRow(_ key: QueueKey, attempts: Int, notBefore: Date, errorCode: String?) async throws {
        try await write { db, _ in
            try db.run(
                "UPDATE rule_queue SET state = 'queued', attempts = ?, not_before = ?, error_code = ? WHERE message_id = ? AND run_id = ?",
                [attempts, notBefore, errorCode, key.messageID, key.runID]
            )
        }
    }

    /// After a permanent failure, or too many attempts: the row waits for `r` (`requeueFailed`).
    /// - Parameter errorCode: such as "http_4xx" or "attempts_exhausted".
    public func failRow(_ key: QueueKey, errorCode: String) async throws {
        try await write { db, _ in
            try db.run(
                "UPDATE rule_queue SET state = 'failed', error_code = ? WHERE message_id = ? AND run_id = ? AND state != 'failed'",
                [errorCode, key.messageID, key.runID]
            )
            guard db.changes > 0 else { return }
            try db.run("UPDATE rule_runs SET failed = failed + 1 WHERE id = ?", [key.runID])
            try Self.finishRuns([key.runID], db)
        }
    }

    /// Claude is unavailable (no key, consent or budget; a bad key or model): the rows wait for it.
    /// A pass that decided some rules commits them instead, with `MessageOutcome.waitsForAI`.
    public func waitForAI(_ keys: [QueueKey]) async throws {
        try await write { db, _ in
            for key in keys {
                try db.run("UPDATE rule_queue SET state = 'waiting_ai' WHERE message_id = ? AND run_id = ? AND state = 'queued'", [key.messageID, key.runID])
            }
        }
    }

    /// Claude is available again: waiting rows are due now. Returns how many.
    @discardableResult
    public func releaseWaitingAI() async throws -> Int {
        try await write { db, _ in
            try db.run("UPDATE rule_queue SET state = 'queued', not_before = 0 WHERE state = 'waiting_ai'")
            return db.changes
        }
    }

    /// `r`: failed rows are queued again with fresh attempts, and their finished runs reopen. Returns how many.
    @discardableResult
    public func requeueFailed() async throws -> Int {
        try await write { db, change in
            let runs = try db.query("SELECT run_id, COUNT(*) FROM rule_queue WHERE state = 'failed' GROUP BY run_id") { ($0.int64(0), $0.int(1)) }
            try db.run("UPDATE rule_queue SET state = 'queued', attempts = 0, not_before = 0, error_code = NULL WHERE state = 'failed'")
            let count = db.changes
            for (id, failed) in runs {
                try db.run(
                    """
                    UPDATE rule_runs SET failed = MAX(failed - ?, 0),
                        state = CASE WHEN state = 'done' THEN 'running' ELSE state END,
                        finished_at = CASE WHEN state = 'done' THEN NULL ELSE finished_at END
                    WHERE id = ?
                    """,
                    [failed, id]
                )
            }
            if count > 0 { change.rules = true }
            return count
        }
    }

    /// Arrived mail that waited for Claude too long (by its date) moves to a backlog run that waits
    /// for your confirmation, so labels never land weeks late in one burst. Returns the backlog run,
    /// or nil when nothing was that old.
    @discardableResult
    public func holdStaleWaiting(olderThan age: TimeInterval = 3 * 86_400, now: Date = Date()) async throws -> Int64? {
        try await write { db, change in
            let stale = try db.query(
                """
                SELECT q.message_id, q.run_id FROM rule_queue q
                JOIN rule_runs r ON r.id = q.run_id AND r.kind = 'live'
                JOIN messages m ON m.id = q.message_id
                WHERE q.state = 'waiting_ai' AND m.date < ?
                """,
                [now.addingTimeInterval(-age)]
            ) { QueueKey(messageID: $0.string(0), runID: $0.int64(1)) }
            guard !stale.isEmpty else { return nil }
            let waiting = try db.first("SELECT id FROM rule_runs WHERE kind = 'backlog' AND state = 'awaiting_confirm' ORDER BY id DESC LIMIT 1") { $0.int64(0) }
            let backlog = try waiting ?? Self.createRun(.backlog, rules: try Self.runnableRules(db).map(RunRule.init), state: .awaitingConfirm, db)
            for key in stale {
                try db.run("DELETE FROM rule_queue WHERE message_id = ? AND run_id = ?", [key.messageID, key.runID])
                try db.run("UPDATE rule_runs SET total = MAX(total - 1, 0) WHERE id = ?", [key.runID])
            }
            try Self.queue(stale.map(\.messageID), run: backlog, priority: 2, held: true, db)
            try Self.finishRuns(Set(stale.map(\.runID)), now: now, db)
            change.rules = true
            return backlog
        }
    }

    /// Reads on the background connection.
    public func ruleQueueCounts() async throws -> RuleQueueCounts {
        try await readBackground { db in
            try db.first(
                """
                SELECT TOTAL(q.state = 'queued' AND r.kind = 'live'), TOTAL(q.state = 'waiting_ai'), TOTAL(q.state = 'held'), TOTAL(q.state = 'failed')
                FROM rule_queue q JOIN rule_runs r ON r.id = q.run_id
                """
            ) { RuleQueueCounts(liveQueued: $0.int(0), waitingAI: $0.int(1), held: $0.int(2), failed: $0.int(3)) } ?? RuleQueueCounts()
        }
    }

    // MARK: - Runs

    /// Starts a run over stored mail: the run and its queue rows in one transaction. Backlog and gap
    /// runs hold their rows until you confirm them (`confirmRun`); the others start at once, manual
    /// runs (`=`) ahead of other runs and behind live mail. Live runs are made by intake: asking for
    /// one throws `RuleStoreError.liveRun`.
    @discardableResult
    public func createRun(
        _ kind: RunKind, rules: [RunRule], messageIDs: [String], window: ClosedRange<Date>? = nil,
        estimateMicros: Int64? = nil, capMicros: Int64? = nil, model: String? = nil
    ) async throws -> Int64 {
        guard kind != .live else { throw RuleStoreError.liveRun }
        return try await write { db, change in
            let confirmFirst = kind == .backlog || kind == .gap
            let id = try Self.createRun(
                kind, rules: rules, state: confirmFirst ? .awaitingConfirm : .running, window: window,
                estimateMicros: estimateMicros, capMicros: capMicros, model: model, db
            )
            try Self.queue(messageIDs, run: id, priority: kind == .manual ? 1 : 2, held: confirmFirst, db)
            try Self.finishRuns([id], db)
            change.rules = true
            return id
        }
    }

    /// Runs, newest first.
    /// - Parameter unfinished: only runs still running, paused or waiting for confirmation.
    public func runs(limit: Int = 50, unfinished: Bool = false) async throws -> [RunRecord] {
        try await read { db in
            let filter = unfinished ? "WHERE state IN ('running', 'paused', 'awaiting_confirm')" : ""
            return try db.query("SELECT \(Self.runColumns) FROM rule_runs \(filter) ORDER BY id DESC LIMIT ?", [limit], Self.runRecord)
        }
    }

    public func run(id: Int64) async throws -> RunRecord? {
        try await read { db in try Self.runRecord(id: id, db) }
    }

    /// The messages a run still has to do (queued, held or waiting for Claude), newest first, so
    /// what is left can be priced again. Reads on the background connection.
    public func runMessageIDs(_ id: Int64) async throws -> [String] {
        try await readBackground { db in
            try db.query(
                "SELECT q.message_id FROM rule_queue q JOIN messages m ON m.id = q.message_id WHERE q.run_id = ? AND q.state != 'failed' ORDER BY m.date DESC",
                [id]
            ) { $0.string(0) }
        }
    }

    /// Pauses a running run. Returns false when it was not running.
    @discardableResult
    public func pauseRun(_ id: Int64, reason: RunPauseReason) async throws -> Bool {
        try await write { db, change in
            try db.run("UPDATE rule_runs SET state = 'paused', pause_reason = ? WHERE id = ? AND state = 'running'", [reason.rawValue, id])
            change.rules = db.changes > 0
            return change.rules
        }
    }

    /// Pauses the running runs that apply `ruleID`, or all of them: after a model switch, or a new
    /// revision (`saveRule` does that itself). Live runs go on, with each rule's current revision.
    /// A new revision or model also makes runs that are already paused or waiting for confirmation
    /// out of date: their reason becomes `rule_changed` or `model_changed`, so they continue only once
    /// you have seen the new estimate. Returns the runs paused or marked.
    @discardableResult
    public func pauseRuns(containing ruleID: String? = nil, reason: RunPauseReason) async throws -> [Int64] {
        try await write { db, change in
            let paused = try Self.pauseRuns(containing: ruleID, reason: reason, db)
            change.rules = !paused.isEmpty
            return paused
        }
    }

    static func pauseRuns(containing ruleID: String?, reason: RunPauseReason, _ db: SQLiteDatabase) throws -> [Int64] {
        let states = reason == .ruleChanged || reason == .modelChanged ? "'running', 'paused', 'awaiting_confirm'" : "'running'"
        var paused: [Int64] = []
        for run in try db.query("SELECT \(runColumns) FROM rule_runs WHERE state IN (\(states)) AND kind != 'live'", [], runRecord) {
            guard ruleID.map({ id in run.rules.contains { $0.id == id } }) ?? true else { continue }
            try db.run(
                "UPDATE rule_runs SET state = CASE WHEN state = 'running' THEN 'paused' ELSE state END, pause_reason = ? WHERE id = ?",
                [reason.rawValue, run.id]
            )
            paused.append(run.id)
        }
        return paused
    }

    /// Continues a paused run, optionally with its rules at newer revisions ("continue with v4"),
    /// another model and a new estimate and cap. A re-check still counting starts its count over when
    /// its rules or model change. Returns false when it was not paused.
    @discardableResult
    public func resumeRun(
        _ id: Int64, rules: [RunRule]? = nil, estimateMicros: Int64? = nil, capMicros: Int64? = nil, model: String? = nil
    ) async throws -> Bool {
        try await write { db, change in
            guard let run = try Self.runRecord(id: id, db), run.state == .paused else { return false }
            try Self.revise(run: id, rules: rules, estimateMicros: estimateMicros, capMicros: capMicros, model: model, db)
            try db.run("UPDATE rule_runs SET state = 'running', pause_reason = NULL WHERE id = ?", [id])
            _ = try Self.countAgainIfStale(run, rules: rules, model: model, db)
            try Self.finishRuns([id], db)
            change.rules = true
            return true
        }
    }

    /// Starts a run that waited for your confirmation, optionally with its rules at newer revisions,
    /// another model and a new estimate and cap: its held rows are queued. A re-check then makes its
    /// second pass, which applies what the first one counted. A re-check confirmed with other rules or
    /// another model than it counted with counts again first, and waits for your confirmation again.
    @discardableResult
    public func confirmRun(
        _ id: Int64, rules: [RunRule]? = nil, estimateMicros: Int64? = nil, capMicros: Int64? = nil, model: String? = nil
    ) async throws -> Bool {
        try await write { db, change in
            guard let run = try Self.runRecord(id: id, db), run.state == .awaitingConfirm else { return false }
            try Self.revise(run: id, rules: rules, estimateMicros: estimateMicros, capMicros: capMicros, model: model, db)
            if try !Self.countAgainIfStale(run, rules: rules, model: model, db) {
                try db.run(
                    """
                    UPDATE rule_runs SET state = 'running', pause_reason = NULL, confirmed_at = ?,
                        done = CASE WHEN kind = 'recheck' THEN 0 ELSE done END
                    WHERE id = ?
                    """,
                    [Date(), id]
                )
                try db.run("UPDATE rule_queue SET state = 'queued', not_before = 0 WHERE run_id = ? AND state = 'held'", [id])
            }
            try Self.finishRuns([id], db)
            change.rules = true
            return true
        }
    }

    /// Replaces what is given of a run's rules, estimate, cap and model.
    static func revise(run id: Int64, rules: [RunRule]?, estimateMicros: Int64?, capMicros: Int64?, model: String?, _ db: SQLiteDatabase) throws {
        try db.run(
            """
            UPDATE rule_runs SET rules = COALESCE(?, rules), est_micros = COALESCE(?, est_micros),
                cap_micros = COALESCE(?, cap_micros), model = COALESCE(?, model)
            WHERE id = ?
            """,
            [try rules.map { try json($0) }, estimateMicros, capMicros, model, id]
        )
    }

    /// A re-check's first pass counts what applying its rules with its model would change. When the
    /// rules or the model change before you confirm, the counts are out of date: the pass starts over.
    /// Returns whether it did.
    static func countAgainIfStale(_ run: RunRecord, rules: [RunRule]?, model: String?, _ db: SQLiteDatabase) throws -> Bool {
        guard run.isDryRun, (rules.map { $0 != run.rules } ?? false) || (model.map { $0 != run.model } ?? false) else { return false }
        try db.run("UPDATE rule_runs SET state = 'running', pause_reason = NULL, done = 0, plus = NULL, minus = NULL WHERE id = ?", [run.id])
        try db.run("UPDATE rule_queue SET state = 'queued', not_before = 0 WHERE run_id = ? AND state = 'held'", [run.id])
        return true
    }

    /// Stops a run for good: its remaining queue rows go. What it did stays (`undoRun` reverts it).
    /// Live runs are not cancelled: arrived mail is never dropped, and pausing rules stops it.
    @discardableResult
    public func cancelRun(_ id: Int64) async throws -> Bool {
        try await write { db, change in
            change.rules = try Self.cancel(run: id, db)
            return change.rules
        }
    }

    static func cancel(run id: Int64, _ db: SQLiteDatabase) throws -> Bool {
        try db.run(
            """
            UPDATE rule_runs SET state = 'cancelled', pause_reason = NULL, finished_at = ?
            WHERE id = ? AND kind != 'live' AND state IN ('running', 'paused', 'awaiting_confirm')
            """,
            [Date(), id]
        )
        guard db.changes > 0 else { return false }
        try db.run("DELETE FROM rule_queue WHERE run_id = ?", [id])
        return true
    }

    /// Takes a rule that was turned off or deleted out of the runs not finished yet. A run left with
    /// no rule has nothing to do and is cancelled. Live runs keep the list of rules their day began with.
    static func removeFromRuns(ruleID: String, _ db: SQLiteDatabase) throws {
        let runs = try db.query("SELECT \(runColumns) FROM rule_runs WHERE state IN ('running', 'paused', 'awaiting_confirm') AND kind != 'live'", [], runRecord)
        for run in runs where run.rules.contains(where: { $0.id == ruleID }) {
            let rules = run.rules.filter { $0.id != ruleID }
            try db.run("UPDATE rule_runs SET rules = ? WHERE id = ?", [try json(rules), run.id])
            if rules.isEmpty { _ = try cancel(run: run.id, db) }
        }
    }

    /// Moves runs on once their queue has nothing left to do: a re-check's first pass waits for your
    /// confirmation (still marked out of date if its rules or model changed), any other run is done.
    /// Failed rows do not keep a run open, and a run waiting for confirmation whose messages are all
    /// gone is done too. Today's live run stays open for later arrivals; earlier days' live runs are
    /// closed here too, since nothing else would.
    static func finishRuns(_ ids: Set<Int64>, now: Date = Date(), _ db: SQLiteDatabase) throws {
        let list = try json(Array(ids))
        try db.run(
            """
            UPDATE rule_runs SET state = 'awaiting_confirm',
                pause_reason = CASE WHEN pause_reason IN ('rule_changed', 'model_changed') THEN pause_reason END
            WHERE id IN (SELECT value FROM json_each(?)) AND kind = 'recheck' AND confirmed_at IS NULL AND state IN ('running', 'paused')
              AND NOT EXISTS (SELECT 1 FROM rule_queue q WHERE q.run_id = rule_runs.id AND q.state IN ('queued', 'waiting_ai'))
            """,
            [list]
        )
        try db.run(
            """
            UPDATE rule_runs SET state = 'done', pause_reason = NULL, finished_at = ?
            WHERE (id IN (SELECT value FROM json_each(?)) OR kind = 'live')
              AND NOT (kind = 'live' AND day = ?) AND NOT (kind = 'recheck' AND confirmed_at IS NULL)
              AND (state IN ('running', 'paused') AND NOT EXISTS (SELECT 1 FROM rule_queue q WHERE q.run_id = rule_runs.id AND q.state != 'failed')
                OR state = 'awaiting_confirm' AND NOT EXISTS (SELECT 1 FROM rule_queue q WHERE q.run_id = rule_runs.id))
            """,
            [now, list, liveDay(now)]
        )
    }

    static let runColumns = """
        id, kind, day, rules, window_start, window_end, state, pause_reason, model, total, done, judged, labeled, failed,
        plus, minus, est_micros, cap_micros, cost_micros, created_at, confirmed_at, finished_at
        """

    static func runRecord(id: Int64, _ db: SQLiteDatabase) throws -> RunRecord? {
        try db.first("SELECT \(runColumns) FROM rule_runs WHERE id = ?", [id], runRecord)
    }

    static func runRecord(_ row: SQLRow) -> RunRecord {
        let window = row.isNull(4) || row.isNull(5) ? nil : row.date(4)...max(row.date(4), row.date(5))
        return RunRecord(
            id: row.int64(0), kind: RunKind(rawValue: row.string(1)) ?? .manual, day: row.optionalString(2),
            rules: (try? decoder.decode([RunRule].self, from: Data(row.string(3).utf8))) ?? [], window: window,
            state: RunState(rawValue: row.string(6)) ?? .done, pauseReason: row.optionalString(7).flatMap(RunPauseReason.init(rawValue:)),
            model: row.optionalString(8), total: row.int(9), done: row.int(10), judged: row.int(11), labeled: row.int(12), failed: row.int(13),
            plus: row.isNull(14) ? nil : row.int(14), minus: row.isNull(15) ? nil : row.int(15),
            estimateMicros: row.isNull(16) ? nil : row.int64(16), capMicros: row.isNull(17) ? nil : row.int64(17), costMicros: row.int64(18),
            createdAt: row.date(19), confirmedAt: row.optionalDate(20), finishedAt: row.optionalDate(21)
        )
    }

    // MARK: - Decisions

    /// Decisions recorded for these messages: message ID → rule ID → decision. Reads on the background connection.
    public func decisions(for messageIDs: [String]) async throws -> [String: [String: StoredDecision]] {
        try await readBackground { db in
            var decisions: [String: [String: StoredDecision]] = [:]
            for (messageID, decision) in try db.query(
                "SELECT message_id, \(Self.decisionColumns) FROM rule_decisions WHERE message_id IN (SELECT value FROM json_each(?))",
                [try Self.json(messageIDs)], { ($0.string(0), Self.decision($0, from: 1)) }
            ) {
                decisions[messageID, default: [:]][decision.decision.ruleID] = decision
            }
            return decisions
        }
    }

    /// Messages Claude was unsure about for the rule and you have not marked ✔ or ✖ yet, newest
    /// first: the rule editor reviews them. Reads on the background connection.
    public func unsureMessageIDs(ruleID: String, limit: Int) async throws -> [String] {
        try await readBackground { db in
            try db.query(
                """
                SELECT d.message_id FROM rule_decisions d JOIN messages m ON m.id = d.message_id
                WHERE d.rule_id = ? AND d.outcome = ? \(Self.notReviewed)
                ORDER BY m.date DESC LIMIT ?
                """,
                [ruleID, Verdict.unsure.rawValue, limit]
            ) { $0.string(0) }
        }
    }

    /// How many `unsure` decisions of existing rules wait for review, for the rules status.
    /// Reads on the background connection.
    public func unsureToReviewCount() async throws -> Int {
        try await readBackground { db in
            try db.scalar(
                "SELECT COUNT(*) FROM rule_decisions d JOIN rules r ON r.id = d.rule_id WHERE d.outcome = ? \(Self.notReviewed)",
                [Verdict.unsure.rawValue]
            )
        }
    }

    /// The decision `d` has no ✔ or ✖ for its rule and message.
    static let notReviewed = "AND NOT EXISTS (SELECT 1 FROM rule_examples e WHERE e.rule_id = d.rule_id AND e.message_id = d.message_id)"

    static let decisionColumns = "rule_id, revision, outcome, source, judge_hash, run_id, decided_at"

    /// A decision read from `decisionColumns`, starting at column `first`.
    static func decision(_ row: SQLRow, from first: Int32) -> StoredDecision {
        StoredDecision(
            decision: RuleDecision(
                ruleID: row.string(first), revision: row.int(first + 1), verdict: Verdict(rawValue: row.string(first + 2)) ?? .noMatch,
                source: DecisionSource(rawValue: row.string(first + 3)) ?? .gate, judgeHash: row.optionalString(first + 4)
            ),
            runID: row.int64(first + 5), decidedAt: row.date(first + 6)
        )
    }

    static func upsertDecision(_ decision: RuleDecision, messageID: String, runID: Int64, now: Date, _ db: SQLiteDatabase) throws {
        try db.run(
            """
            INSERT INTO rule_decisions(message_id, rule_id, revision, outcome, source, judge_hash, run_id, decided_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_id, rule_id) DO UPDATE SET revision = excluded.revision, outcome = excluded.outcome,
                source = excluded.source, judge_hash = excluded.judge_hash, run_id = excluded.run_id, decided_at = excluded.decided_at
            """,
            [messageID, decision.ruleID, decision.revision, decision.verdict.rawValue, decision.source.rawValue, decision.judgeHash, runID, now]
        )
    }

    // MARK: - Verdicts

    /// Stores Claude's answer for one call as soon as it returns, in its own transaction, so a crash
    /// before the commit never pays for it twice. The call's cost counts toward its run at once (the
    /// run's cap needs it before the commit) and toward the model's recent costs, which estimates average.
    /// - Parameters:
    ///   - verdicts: possibly none, for a call that was billed but answered nothing usable.
    ///   - model: the model asked.
    ///   - runID: the run whose message was judged; nil for the editor's previews.
    public func putVerdicts(_ verdicts: [StoredVerdict], model: String, costMicros: Int64, runID: Int64? = nil) async throws {
        try await write { db, _ in
            for verdict in verdicts {
                try db.run(
                    """
                    INSERT OR REPLACE INTO verdicts(message_id, judge_hash, verdict, reason, examples_digest, model, served_by, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        verdict.messageID, verdict.judgeHash, verdict.verdict.rawValue, verdict.reason, verdict.examplesDigest,
                        verdict.model, verdict.servedBy, verdict.createdAt,
                    ]
                )
            }
            try db.run("INSERT INTO rule_call_costs(model, cost_micros, created_at) VALUES (?, ?, ?)", [model, costMicros, Date()])
            try db.run(
                "DELETE FROM rule_call_costs WHERE model = ? AND rowid NOT IN (SELECT rowid FROM rule_call_costs WHERE model = ? ORDER BY rowid DESC LIMIT ?)",
                [model, model, Self.callCostSample]
            )
            if let runID {
                try db.run("UPDATE rule_runs SET judged = judged + 1, cost_micros = cost_micros + ? WHERE id = ?", [costMicros, runID])
            }
        }
    }

    /// Cached verdicts for these messages at these judge hashes. Reads on the background connection.
    public func verdicts(messageIDs: [String], judgeHashes: Set<String>) async throws -> [StoredVerdict] {
        guard !messageIDs.isEmpty, !judgeHashes.isEmpty else { return [] }
        return try await readBackground { db in
            try db.query(
                """
                SELECT message_id, judge_hash, verdict, reason, examples_digest, model, served_by, created_at FROM verdicts
                WHERE message_id IN (SELECT value FROM json_each(?)) AND judge_hash IN (SELECT value FROM json_each(?))
                """,
                [try Self.json(messageIDs), try Self.json(judgeHashes.sorted())]
            ) { row in
                StoredVerdict(
                    messageID: row.string(0), judgeHash: row.string(1), verdict: Verdict(rawValue: row.string(2)) ?? .unsure, reason: row.string(3),
                    examplesDigest: row.string(4), model: row.string(5), servedBy: row.string(6), createdAt: row.date(7)
                )
            }
        }
    }

    /// What the model's last 50 calls in this account cost on average, or nil before its first.
    public func meanCallCostMicros(model: String) async throws -> Int64? {
        try await readBackground { db in
            try db.first("SELECT AVG(cost_micros) FROM rule_call_costs WHERE model = ?", [model]) { $0.isNull(0) ? nil : Int64($0.double(0).rounded()) } ?? nil
        }
    }
}

/// What the engine reads to decide messages, what runs would cost, and retention.
extension MailStore {
    // MARK: - Facts

    /// Facts for a batch of messages, in the order given. Messages that are gone are left out.
    /// Reads on the background connection.
    public func messageFacts(_ messageIDs: [String]) async throws -> [MessageFacts] {
        guard !messageIDs.isEmpty else { return [] }
        return try await readBackground { db in
            let ids = try Self.json(messageIDs)
            var facts: [String: MessageFacts] = [:]
            for fact in try db.query(
                """
                SELECT m.id, m.thread_id, m.from_name, m.from_email, m.date, \(Self.isListMessage),
                       (SELECT group_concat(label_id, ' ') FROM message_labels WHERE message_id = m.id), m.subject
                FROM messages m WHERE m.id IN (SELECT value FROM json_each(?))
                """,
                [ids], { row in
                    MessageFacts(
                        messageID: row.string(0), threadID: row.string(1), from: EmailAddress(name: row.optionalString(2), email: row.string(3)),
                        subject: row.string(7), date: row.date(4), labelIDs: Set(row.string(6).split(separator: " ").map(String.init)), isList: row.bool(5)
                    )
                }
            ) {
                facts[fact.messageID] = fact
            }
            for (messageID, labelID, present) in try db.query(
                "SELECT message_id, label_id, present FROM label_marks WHERE message_id IN (SELECT value FROM json_each(?))", [ids],
                { ($0.string(0), $0.string(1), $0.bool(2)) }
            ) {
                facts[messageID]?.marks[labelID] = present
            }
            for (messageID, ruleID, matches) in try db.query(
                "SELECT message_id, rule_id, verdict FROM rule_examples WHERE message_id IN (SELECT value FROM json_each(?))", [ids],
                { ($0.string(0), $0.string(1), $0.bool(2)) }
            ) {
                facts[messageID]?.examples[ruleID] = matches
            }
            for (messageID, decision) in try db.query(
                "SELECT message_id, \(Self.decisionColumns) FROM rule_decisions WHERE message_id IN (SELECT value FROM json_each(?))", [ids],
                { ($0.string(0), Self.decision($0, from: 1)) }
            ) {
                facts[messageID]?.decisions[decision.decision.ruleID] = decision
            }

            // Sender overrides: an exact address wins over its domain.
            let senders = Set(facts.values.flatMap { Self.overrideSubjects(of: $0.from) })
            var overrides: [String: [(rule: String, matches: Bool)]] = [:]
            for (subject, ruleID, matches) in try db.query(
                "SELECT subject, rule_id, verdict FROM rule_overrides WHERE subject IN (SELECT value FROM json_each(?))", [try Self.json(senders.sorted())],
                { ($0.string(0), $0.string(1), $0.bool(2)) }
            ) {
                overrides[subject, default: []].append((ruleID, matches))
            }

            // Conversations: earlier matches (for inheritance) and your removals.
            let threads = try Self.json(Set(facts.values.map(\.threadID)).sorted())
            let matches = try db.query(
                """
                SELECT m.thread_id, m.date, d.rule_id FROM rule_decisions d JOIN messages m ON m.id = d.message_id
                WHERE m.thread_id IN (SELECT value FROM json_each(?)) AND d.outcome = ?
                """,
                [threads, Verdict.match.rawValue], { (thread: $0.string(0), date: $0.date(1), rule: $0.string(2)) }
            )
            let removals = try db.query(
                """
                SELECT m.thread_id, k.label_id FROM label_marks k JOIN messages m ON m.id = k.message_id
                WHERE m.thread_id IN (SELECT value FROM json_each(?)) AND k.present = 0
                """,
                [threads], { (thread: $0.string(0), label: $0.string(1)) }
            )
            for id in facts.keys {
                guard var fact = facts[id] else { continue }
                for subject in Self.overrideSubjects(of: fact.from) {
                    for override in overrides[subject] ?? [] { fact.overrides[override.rule] = override.matches }
                }
                fact.threadMatches = Set(matches.filter { $0.thread == fact.threadID && $0.date < fact.date }.map(\.rule))
                fact.threadRemovals = Set(removals.filter { $0.thread == fact.threadID }.map(\.label))
                facts[id] = fact
            }
            return messageIDs.compactMap { facts[$0] }
        }
    }

    /// The override subjects that apply to a sender, weakest first: its domain, then its address.
    static func overrideSubjects(of sender: EmailAddress) -> [String] {
        let address = sender.normalized
        guard let domain = address.split(separator: "@").last, address.contains("@") else { return [address] }
        return ["@\(domain)", address]
    }

    /// The message and its conversation up to it, with bodies, when Claude has to judge it.
    /// Reads on the background connection.
    public func judgeInputs(messageID: String) async throws -> JudgeInputs? {
        try await readBackground { db in
            func decode(_ row: SQLRow) throws -> MailMessage {
                try Self.decodeMessage(row, labels: Set(row.string(19).split(separator: " ").map(String.init)))
            }
            guard let message = try db.first("SELECT \(Self.messageColumns) FROM messages m WHERE m.id = ?", [messageID], decode) else { return nil }
            let thread = try db.query(
                "SELECT \(Self.messageColumns) FROM messages m WHERE m.thread_id = ? AND m.date <= ? AND m.id != ? ORDER BY m.date",
                [message.threadID, message.date, message.id], decode
            )
            return JudgeInputs(message: message, thread: thread + [message])
        }
    }

    // MARK: - Estimates

    /// Exact counts for running `rule` over the stored mail in `window`. Filter-only rules need no
    /// call. Reads on the background connection.
    /// - Parameter judgeHash: the rule's judge hash at the current model, so cached verdicts count
    ///   as decided; nil when there is none yet.
    public func estimate(_ rule: Rule, window: EstimateWindow, judgeHash: String?) async throws -> RuleEstimate {
        let filter = try RuleFilter.parse(rule.when)
        let me = selfAddresses
        return try await readBackground { db in
            let search = Self.search(filter, labelTerms: true)
            let scope = rule.scope.mailboxes
            let (decided, decidedArgs): (String, [SQLBindable]) = rule.asksClaude ? try Self.decidedWithoutCall(rule, judgeHash: judgeHash) : ("'filter'", [])
            func passing(_ range: ClosedRange<Date>?) throws -> (String, [SQLBindable]) {
                let (sql, args) = try Self.messageQuerySQL(
                    MessageQuery(search: search, mailboxes: scope, window: range), me: me, selecting: "m.date AS date, \(decided) AS decided", ordered: false
                )
                return (sql, decidedArgs + args)
            }

            var range: ClosedRange<Date>?
            switch window {
            case .dates(let dates):
                range = dates
            case .allCached:
                range = nil
            case .newestNeedingClaude(let count):
                // Back to the count-th message needing Claude; all stored mail when fewer need it.
                let (sql, args) = try passing(nil)
                let dates = try db.query("SELECT date FROM (\(sql)) WHERE decided IS NULL ORDER BY date DESC LIMIT ?", args + [count as SQLBindable]) { $0.date(0) }
                if dates.count == count, let oldest = dates.last { range = oldest...Date.distantFuture }
            }

            let (scoped, scopedArgs) = try Self.messageQuerySQL(MessageQuery(search: SearchQuery(), mailboxes: scope, window: range), me: me, selecting: "COUNT(*)", ordered: false)
            let inScope = try db.scalar(scoped, scopedArgs)
            let (sql, args) = try passing(range)
            return try db.first(
                """
                SELECT COUNT(*), COUNT(decided), TOTAL(decided = 'you'), TOTAL(decided = 'verdict'), TOTAL(decided = 'earlier'),
                       MIN(CASE WHEN decided IS NULL THEN date END), MAX(CASE WHEN decided IS NULL THEN date END)
                FROM (\(sql))
                """,
                args
            ) { row in
                RuleEstimate(
                    window: range, inScope: inScope, passing: row.int(0), decidedFree: row.int(1), decidedByYou: row.int(2),
                    cachedVerdicts: row.int(3), decidedEarlier: row.int(4), needClaude: row.int(0) - row.int(1),
                    claudeSpan: row.isNull(5) ? nil : row.date(5)...row.date(6)
                )
            } ?? RuleEstimate(window: range, inScope: inScope, passing: 0, decidedFree: 0, decidedByYou: 0, cachedVerdicts: 0, decidedEarlier: 0, needClaude: 0)
        }
    }

    /// How the message `m` is decided for a Claude rule without a call, or NULL when it needs one:
    /// 'you' by your mark on its label, an example or a sender override; 'verdict' by a verdict cached
    /// at `judgeHash`; 'earlier' by a decision at the rule's revision.
    static func decidedWithoutCall(_ rule: Rule, judgeHash: String?) throws -> (String, [SQLBindable]) {
        let sender = "unicode_lower(m.from_email)"
        let yours = [
            "EXISTS (SELECT 1 FROM label_marks k WHERE k.message_id = m.id AND k.label_id IN (SELECT value FROM json_each(?)))",
            "EXISTS (SELECT 1 FROM rule_examples e WHERE e.rule_id = ? AND e.message_id = m.id)",
            "EXISTS (SELECT 1 FROM rule_overrides o WHERE o.rule_id = ? AND o.subject IN (\(sender), '@' || substr(\(sender), instr(\(sender), '@') + 1)))",
        ]
        var sql = "CASE WHEN " + yours.joined(separator: " OR ") + " THEN 'you'"
        var args: [SQLBindable] = [try json(rule.labelTargets.map(\.id)), rule.id, rule.id]
        if let judgeHash {
            sql += " WHEN EXISTS (SELECT 1 FROM verdicts v WHERE v.message_id = m.id AND v.judge_hash = ?) THEN 'verdict'"
            args.append(judgeHash)
        }
        sql += " WHEN EXISTS (SELECT 1 FROM rule_decisions d WHERE d.message_id = m.id AND d.rule_id = ? AND d.revision = ?) THEN 'earlier' END"
        args += [rule.id, rule.revision]
        return (sql, args)
    }

    // MARK: - Retention

    /// Finished runs and reverted ledger rows stay for the undo window.
    static let runRetention: TimeInterval = 90 * 86_400
    /// Verdicts stay this long after no rule revision uses their judge hash, so restoring an earlier ASK is free.
    static let unusedVerdictRetention: TimeInterval = 30 * 86_400

    /// Examples and sender rules of a rule written in the editor and never saved stay this long, in case
    /// the app quit before the editor discarded them.
    static let draftRetention: TimeInterval = 86_400

    /// Deletes rule history past its use: finished runs older than 90 days (the undo window) with
    /// their reverted ledger rows, ledger rows reverted more than 90 days ago, verdicts at judge
    /// hashes no current rule revision has used for 30 days, and what unsaved drafts were taught a
    /// day ago or earlier. Labels rules still own keep their rows.
    /// - Parameter judgeHashesInUse: every rule's current judge hash, at the current model.
    public func pruneRuleHistory(now: Date = Date(), judgeHashesInUse: Set<String>) async throws {
        try await write { db, _ in
            let cutoff = now.addingTimeInterval(-Self.runRetention)
            let old = try Self.json(try db.query(
                "SELECT id FROM rule_runs WHERE state IN ('done', 'cancelled', 'undone') AND COALESCE(finished_at, created_at) < ?", [cutoff]
            ) { $0.int64(0) })
            try db.run("DELETE FROM rule_ledger WHERE reverted_at IS NOT NULL AND (reverted_at < ? OR run_id IN (SELECT value FROM json_each(?)))", [cutoff, old])
            try db.run("DELETE FROM rule_queue WHERE run_id IN (SELECT value FROM json_each(?))", [old])
            try db.run("DELETE FROM rule_runs WHERE id IN (SELECT value FROM json_each(?))", [old])
            let drafts = now.addingTimeInterval(-Self.draftRetention)
            try db.run("DELETE FROM rule_examples WHERE created_at < ? AND rule_id NOT IN (SELECT id FROM rules)", [drafts])
            try db.run("DELETE FROM rule_overrides WHERE created_at < ? AND rule_id NOT IN (SELECT id FROM rules)", [drafts])

            // When each judge hash was last in use (meta `rules_judge_hashes`, milliseconds).
            let nowMillis = Int64((now.timeIntervalSince1970 * 1000).rounded())
            let stored = try db.first("SELECT value FROM meta WHERE key = 'rules_judge_hashes'") { row in
                try? Self.decoder.decode([String: Int64].self, from: Data(row.string(0).utf8))
            }
            var lastUsed = (stored ?? nil) ?? [:]
            for hash in judgeHashesInUse { lastUsed[hash] = nowMillis }
            for hash in try db.query("SELECT DISTINCT judge_hash FROM verdicts", [], { $0.string(0) }) where lastUsed[hash] == nil {
                lastUsed[hash] = nowMillis
            }
            let expiry = nowMillis - Int64(Self.unusedVerdictRetention * 1000)
            let expired = lastUsed.filter { $0.value < expiry }.map(\.key)
            try db.run("DELETE FROM verdicts WHERE judge_hash IN (SELECT value FROM json_each(?))", [try Self.json(expired)])
            for hash in expired { lastUsed[hash] = nil }
            try Self.setMeta("rules_judge_hashes", lastUsed.isEmpty ? nil : try Self.json(lastUsed), db)
        }
    }

    /// Settings → "Delete Claude results": every cached verdict and every decision Claude made, by a
    /// call or from the cache. Labels already applied stay.
    public func deleteClaudeResults() async throws {
        try await write { db, change in
            try db.run("DELETE FROM verdicts")
            try db.run("DELETE FROM rule_decisions WHERE source IN (?, ?)", [DecisionSource.claude.rawValue, DecisionSource.cache.rawValue])
            try Self.setMeta("rules_judge_hashes", nil, db)
            change.rules = true
        }
    }
}
