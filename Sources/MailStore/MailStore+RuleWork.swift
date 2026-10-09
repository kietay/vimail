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
            let backlog = try waiting ?? createRun(.backlog, rules: rules, state: .awaitingConfirm, db)
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

    /// Today's live run, created with the rules that can run now.
    static func liveRun(_ rules: [Rule], _ db: SQLiteDatabase) throws -> Int64 {
        let day = liveDay(Date())
        if let id = try db.first("SELECT id FROM rule_runs WHERE kind = 'live' AND day = ?", [day], { $0.int64(0) }) { return id }
        return try createRun(.live, day: day, rules: rules, state: .running, db)
    }

    static func createRun(_ kind: RunKind, day: String? = nil, rules: [Rule], state: RunState, _ db: SQLiteDatabase) throws -> Int64 {
        try db.run(
            "INSERT INTO rule_runs(kind, day, rules, state, created_at) VALUES (?, ?, ?, ?, ?)",
            [kind.rawValue, day, try json(rules.map { RunRule(id: $0.id, revision: $0.revision) }), state.rawValue, Date()]
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
