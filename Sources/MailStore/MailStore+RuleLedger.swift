import Foundation
import MailCore

/// A matching rule's label, as the fold applies it.
public struct RuleMatch: Hashable, Sendable {
    public var ruleID: String
    public var revision: Int
    public var labelID: String

    public init(ruleID: String, revision: Int, labelID: String) {
        self.ruleID = ruleID
        self.revision = revision
        self.labelID = labelID
    }
}

/// What one pass decided for one message, to commit.
public struct MessageOutcome: Hashable, Sendable {
    public var messageID: String
    /// Decisions to record, replacing earlier ones for the same rules.
    public var decisions: [RuleDecision]
    /// The matching rules' labels in fold order: when two rules add one label, the first adds it
    /// and the second co-owns it.
    public var matches: [RuleMatch]
    /// Claude is unavailable and some rules wait for a verdict. What was decided commits, and the
    /// message waits (`waiting_ai`) for a later pass that decides the rest.
    public var waitsForAI: Bool

    public init(messageID: String, decisions: [RuleDecision], matches: [RuleMatch], waitsForAI: Bool = false) {
        self.messageID = messageID
        self.decisions = decisions
        self.matches = matches
        self.waitsForAI = waitsForAI
    }
}

/// What `commitRuleOutcomes` did.
public struct RuleCommitSummary: Hashable, Sendable {
    /// Messages committed. Their queue rows are gone (held, in a re-check's first pass).
    public var messages = 0
    /// Messages committed in part: they wait for Claude to decide the rest.
    public var waitingAI = 0
    /// Labels added.
    public var labelsAdded = 0
    /// Matches on a label another rule had added: the rules now co-own it.
    public var coOwned = 0
    /// Labels a confirmed re-check removed.
    public var labelsRemoved = 0
    /// Gmail changes queued in the outbox. Wake sync only when there are some.
    public var syncedChanges = 0
    /// Rules turned off because their label is gone.
    public var labelMissing: Set<String> = []
    /// A re-check's first pass: labels applying it would add and remove. Nothing changed yet.
    public var plus = 0
    public var minus = 0

    public init() {}

    mutating func formUnion(_ other: RuleCommitSummary) {
        messages += other.messages
        waitingAI += other.waitingAI
        labelsAdded += other.labelsAdded
        coOwned += other.coOwned
        labelsRemoved += other.labelsRemoved
        syncedChanges += other.syncedChanges
        labelMissing.formUnion(other.labelMissing)
        plus += other.plus
        minus += other.minus
    }
}

/// Which ledger rows to revert.
public enum LedgerSelector: Sendable, Hashable {
    case rows([Int64])
    /// Every label a run added that is still its own.
    case run(Int64)
    /// Every label a rule added that is still its own.
    case rule(String)
}

/// What a revert did.
public struct RevertSummary: Hashable, Sendable {
    /// Ledger rows that stopped being active.
    public var rows = 0
    /// Labels removed from messages. The others stay: another rule owns them, or you added them.
    public var labelsRemoved = 0
    /// Gmail changes queued or cancelled in the outbox. Wake sync only when there are some.
    public var syncedChanges = 0

    public init() {}
}

/// Why a conversation carries its labels ("why these labels?").
public struct ThreadExplanation: Hashable, Sendable {
    /// Each label on the conversation's messages, by name. System labels are left out.
    public var labels: [LabelExplanation]
    /// Rules that judged a message and decided no (`no_match`, `unsure` or `declined`), with
    /// Claude's reason when Claude decided. Rules whose WHEN filtered the message out are left out.
    public var misses: [RuleMiss]
    /// Rules that matched a message already carrying their label, which you or Gmail added: the
    /// label stays yours and no rule owns it, but the rule agrees.
    public var agreements: [RuleAgreement] = []
}

public struct LabelExplanation: Hashable, Sendable {
    public var label: MailLabel
    /// The messages carrying it, oldest first.
    public var messageIDs: [String]
    /// The rules that own it on those messages.
    public var owners: [LabelOwner]

    /// Messages carrying it that no rule owns there: you or Gmail added it.
    public var unownedMessageIDs: [String] {
        messageIDs.filter { id in !owners.contains { $0.messageID == id } }
    }
}

/// A rule's ownership of a label on one message.
public struct LabelOwner: Hashable, Sendable {
    public var ledgerID: Int64
    public var messageID: String
    public var ruleID: String
    /// The rule's current name; nil once it is deleted.
    public var ruleName: String?
    public var revision: Int
    public var runID: Int64
    /// nil once the run is past retention.
    public var runKind: RunKind?
    public var appliedAt: Date
    /// False when another rule had added the label: this one co-owns it.
    public var added: Bool
    /// How the rule decided, from its decision for the message.
    public var source: DecisionSource?
    /// Claude's reason, when Claude decided.
    public var reason: String?
    public var model: String?
    public var servedBy: String?
    /// Added under a dry-run provider: Gmail never saw it.
    public var simulated: Bool
}

/// A rule that matched a message whose label was already there, added by you or Gmail.
public struct RuleAgreement: Hashable, Sendable {
    public var messageID: String
    public var ruleID: String
    public var ruleName: String?
    public var revision: Int
    public var labelID: String
    public var source: DecisionSource
    public var reason: String?
    /// The model that answered, when Claude decided.
    public var model: String?
}

/// A rule that decided a message does not match.
public struct RuleMiss: Hashable, Sendable {
    public var messageID: String
    public var ruleID: String
    public var ruleName: String?
    public var revision: Int
    public var verdict: Verdict
    public var source: DecisionSource
    public var reason: String?
    public var model: String?
}

/// The ledger of labels rules added: commits, the removal rule, undo and explanations.
extension MailStore {
    /// Messages per commit transaction.
    static let commitBatch = 25

    /// An active ledger row: a rule owns a label on a message.
    struct LedgerRow {
        var id: Int64
        var ruleID: String
        var messageID: String
        var threadID: String
        var target: String
    }

    static let ledgerRowColumns = "id, rule_id, message_id, thread_id, target"

    static func ledgerRow(_ row: SQLRow) -> LedgerRow {
        LedgerRow(id: row.int64(0), ruleID: row.string(1), messageID: row.string(2), threadID: row.string(3), target: row.string(4))
    }

    // MARK: - Commit

    /// Commits passes over messages of one run, one transaction per 25 messages.
    ///
    /// Every matching rule leaves a ledger row: one that adds its label (`changed`), or one that
    /// co-owns a label another rule added. A label you already had stays yours: the decision is
    /// recorded, nothing else. A label you removed from the message is never added back. Commits never
    /// create labels: a match on a label that is gone turns its rules off (`label_missing`). Gmail
    /// labels also queue one outbox change per label and transaction, `simulated` when the provider is
    /// a dry run. Decisions replace earlier ones, queue rows go, the run's counters move and live runs
    /// advance `rules_live_watermark`. Observers hear once.
    ///
    /// An outcome commits only while its row is queued or waiting for Claude, so committing twice
    /// changes nothing and a cancelled or undone run applies nothing more. Rules deleted or turned off
    /// since the pass, or taken out of the run, apply nothing. An outcome that waits for Claude commits
    /// what was decided and keeps its row, waiting. A re-check's first pass changes nothing: it counts
    /// what applying would add and remove and holds its rows for your confirmation. Its confirmed pass
    /// applies, and removes labels the rule no longer matches under the removal rule (`recheck`).
    @discardableResult
    public func commitRuleOutcomes(_ outcomes: [MessageOutcome], runID: Int64, simulated: Bool) async throws -> RuleCommitSummary {
        let me = selfAddresses
        let summaries = try await writeChunks(outcomes, size: Self.commitBatch) { chunk, db, change in
            try Self.commit(chunk, runID: runID, simulated: simulated, me: me, db, &change)
        }
        return summaries.reduce(into: RuleCommitSummary()) { $0.formUnion($1) }
    }

    static func commit(
        _ outcomes: ArraySlice<MessageOutcome>, runID: Int64, simulated: Bool, me: Set<String>, _ db: SQLiteDatabase, _ change: inout StoreChange
    ) throws -> RuleCommitSummary {
        var summary = RuleCommitSummary()
        guard let run = try runRecord(id: runID, db) else { return summary }
        let now = Date()
        let dry = run.isDryRun
        // Live mail goes through every enabled rule, other runs through the rules they still list.
        var applying = Set(try db.query("SELECT id FROM rules WHERE enabled = 1") { $0.string(0) })
        if run.kind != .live { applying.formIntersection(run.rules.map(\.id)) }
        var kinds: [String: MailLabel.Kind?] = [:]
        func kind(of labelID: String) throws -> MailLabel.Kind? {
            if let known = kinds[labelID] { return known }
            let kind = try db.first("SELECT kind FROM labels WHERE id = ?", [labelID]) { MailLabel.Kind(rawValue: $0.string(0)) ?? .user }
            kinds[labelID] = kind
            return kind
        }
        var missing = Set<String>()
        var gmailAdds: [String: [(messageID: String, ledgerID: Int64)]] = [:]
        var labeled = 0
        var newest: Date?

        for outcome in outcomes {
            let key: [SQLBindable] = [outcome.messageID, runID]
            guard try db.scalar("SELECT COUNT(*) FROM rule_queue WHERE message_id = ? AND run_id = ? AND state IN ('queued', 'waiting_ai')", key) > 0,
                  let (threadID, date) = try db.first("SELECT thread_id, date FROM messages WHERE id = ?", [outcome.messageID], { ($0.string(0), $0.date(1)) })
            else { continue }
            if dry && outcome.waitsForAI {
                // A re-check counts a message once every rule is decided.
                try db.run("UPDATE rule_queue SET state = 'waiting_ai' WHERE message_id = ? AND run_id = ?", key)
                summary.waitingAI += 1
                continue
            }
            let decisions = outcome.decisions.filter { applying.contains($0.ruleID) }
            var labels = Set(try db.query("SELECT label_id FROM message_labels WHERE message_id = ?", [outcome.messageID]) { $0.string(0) })
            var owners = try db.query("SELECT \(ledgerRowColumns) FROM rule_ledger WHERE message_id = ? AND reverted_at IS NULL", [outcome.messageID], ledgerRow)
            let removedByYou = Set(try db.query("SELECT label_id FROM label_marks WHERE message_id = ? AND present = 0", [outcome.messageID]) { $0.string(0) })
            // A message counts as labeled once per run, though its labels may come in two commits.
            let labeledBefore = try db.scalar("SELECT COUNT(*) FROM rule_ledger WHERE message_id = ? AND run_id = ? AND changed = 1", key) > 0
            var added = false

            for match in outcome.matches where applying.contains(match.ruleID) {
                guard let labelKind = try kind(of: match.labelID) else {
                    if missing.insert(match.labelID).inserted { summary.labelMissing.formUnion(try labelRemoved(match.labelID, db, &change)) }
                    continue
                }
                guard !owners.contains(where: { $0.ruleID == match.ruleID && $0.target == match.labelID }), !removedByYou.contains(match.labelID) else { continue }
                if labels.contains(match.labelID) {
                    // Another rule's label is co-owned; one nobody's rule added is yours.
                    guard owners.contains(where: { $0.target == match.labelID }) else { continue }
                    var id: Int64 = 0
                    if !dry {
                        id = try insertLedger(match, messageID: outcome.messageID, threadID: threadID, runID: runID, changed: false, now: now, db)
                        summary.coOwned += 1
                    }
                    owners.append(LedgerRow(id: id, ruleID: match.ruleID, messageID: outcome.messageID, threadID: threadID, target: match.labelID))
                } else {
                    labels.insert(match.labelID)
                    if dry {
                        summary.plus += 1
                        owners.append(LedgerRow(id: 0, ruleID: match.ruleID, messageID: outcome.messageID, threadID: threadID, target: match.labelID))
                        continue
                    }
                    try db.run("INSERT OR IGNORE INTO message_labels(message_id, label_id) VALUES (?, ?)", [outcome.messageID, match.labelID])
                    let id = try insertLedger(match, messageID: outcome.messageID, threadID: threadID, runID: runID, changed: true, now: now, db)
                    owners.append(LedgerRow(id: id, ruleID: match.ruleID, messageID: outcome.messageID, threadID: threadID, target: match.labelID))
                    if labelKind == .user { gmailAdds[match.labelID, default: []].append((outcome.messageID, id)) }
                    change.threadIDs.insert(threadID)
                    summary.labelsAdded += 1
                    added = true
                }
            }

            if run.kind == .recheck {
                let noLonger = Set(decisions.filter { !$0.verdict.isMatch }.map(\.ruleID))
                let stale = owners.filter { noLonger.contains($0.ruleID) && $0.id != 0 }
                if dry {
                    summary.minus += try stale.filter { row in
                        try wouldRemove(row, keptBy: owners.filter { !noLonger.contains($0.ruleID) }, labels: labels, db)
                    }.count
                } else {
                    let reverted = try revert(stale, reason: .recheck, now: now, db, &change)
                    summary.labelsRemoved += reverted.labelsRemoved
                    summary.syncedChanges += reverted.syncedChanges
                }
            }

            if dry {
                try db.run("UPDATE rule_queue SET state = 'held' WHERE message_id = ? AND run_id = ?", key)
                summary.messages += 1
                continue
            }
            for decision in decisions {
                try upsertDecision(decision, messageID: outcome.messageID, runID: runID, now: now, db)
            }
            if added && !labeledBefore { labeled += 1 }
            if outcome.waitsForAI {
                try db.run("UPDATE rule_queue SET state = 'waiting_ai' WHERE message_id = ? AND run_id = ?", key)
                summary.waitingAI += 1
            } else {
                try db.run("DELETE FROM rule_queue WHERE message_id = ? AND run_id = ?", key)
                summary.messages += 1
                newest = max(newest ?? date, date)
            }
        }

        for (labelID, rows) in gmailAdds.sorted(by: { $0.key < $1.key }) {
            let outboxID = try enqueue(.modifyLabels(LabelDelta(messageIDs: rows.map { $0.messageID }, add: [labelID])), db)
            for row in rows {
                try db.run("UPDATE rule_ledger SET outbox_id = ?, simulated = ? WHERE id = ?", [outboxID, simulated, row.ledgerID])
            }
            summary.syncedChanges += 1
        }
        if summary.syncedChanges > 0 { change.outbox = true }

        try db.run(
            """
            UPDATE rule_runs SET done = done + ?, labeled = labeled + ?,
                plus = CASE WHEN ? THEN COALESCE(plus, 0) + ? ELSE plus END, minus = CASE WHEN ? THEN COALESCE(minus, 0) + ? ELSE minus END
            WHERE id = ?
            """,
            [summary.messages, labeled, dry, summary.plus, dry, summary.minus, runID]
        )
        if run.kind == .live, let newest { try advanceLiveWatermark(to: newest, db) }
        try finishRuns([runID], now: now, db)
        try refreshThreads(change.threadIDs, db, selfAddresses: me)
        return summary
    }

    static func insertLedger(_ match: RuleMatch, messageID: String, threadID: String, runID: Int64, changed: Bool, now: Date, _ db: SQLiteDatabase) throws -> Int64 {
        try db.run(
            """
            INSERT INTO rule_ledger(run_id, rule_id, revision, message_id, thread_id, effect, target, changed, applied_at)
            VALUES (?, ?, ?, ?, ?, 'add_label', ?, ?, ?)
            """,
            [runID, match.ruleID, match.revision, messageID, threadID, match.labelID, changed, now]
        )
        return db.lastInsertRowID
    }

    /// Moves `rules_live_watermark` (milliseconds) forward to `date`, never back.
    static func advanceLiveWatermark(to date: Date, _ db: SQLiteDatabase) throws {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let current = try liveWatermark(db).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        guard current.map({ millis > $0 }) ?? true else { return }
        try setMeta("rules_live_watermark", String(millis), db)
    }

    // MARK: - Removal rule

    /// The removal rule: stamps `rows` reverted, then takes each label off its message only when no
    /// rule owns it there any more and you did not add it yourself (a present mark). Gmail labels
    /// follow through the outbox, as `revert(_:)` does for your actions: the change that added the
    /// label is cancelled for the message while still pending, else the inverse is queued.
    /// - Parameter syncs: false leaves the outbox alone, for a change Gmail refused.
    static func revert(
        _ rows: [LedgerRow], reason: LedgerRevertReason, now: Date, syncs: Bool = true, _ db: SQLiteDatabase, _ change: inout StoreChange
    ) throws -> RevertSummary {
        var summary = RevertSummary()
        var pairs: [LedgerRow] = []
        var seen = Set<[String]>()
        for row in rows {
            try db.run("UPDATE rule_ledger SET reverted_at = ?, reverted_by = ? WHERE id = ? AND reverted_at IS NULL", [now, reason.rawValue, row.id])
            guard db.changes > 0 else { continue }
            summary.rows += 1
            if seen.insert([row.messageID, row.target]).inserted { pairs.append(row) }
        }

        var cancels: [Int64: Set<String>] = [:]
        var inverses: [String: [String]] = [:]
        for row in pairs {
            guard try db.scalar("SELECT COUNT(*) FROM rule_ledger WHERE message_id = ? AND target = ? AND reverted_at IS NULL", [row.messageID, row.target]) == 0,
                  try db.scalar("SELECT COUNT(*) FROM label_marks WHERE message_id = ? AND label_id = ? AND present = 1", [row.messageID, row.target]) == 0
            else { continue }
            try db.run("DELETE FROM message_labels WHERE message_id = ? AND label_id = ?", [row.messageID, row.target])
            guard db.changes > 0 else { continue }
            summary.labelsRemoved += 1
            change.threadIDs.insert(row.threadID)
            guard syncs, try db.first("SELECT kind FROM labels WHERE id = ?", [row.target], { $0.string(0) }) == MailLabel.Kind.user.rawValue else { continue }
            let addedBy = try db.first(
                "SELECT outbox_id FROM rule_ledger WHERE message_id = ? AND target = ? AND outbox_id IS NOT NULL ORDER BY id DESC LIMIT 1",
                [row.messageID, row.target]
            ) { $0.int64(0) }
            if let addedBy, try pendingLabelChange(addedBy, db)?.messageIDs.contains(row.messageID) == true {
                cancels[addedBy, default: []].insert(row.messageID)
            } else {
                inverses[row.target, default: []].append(row.messageID)
            }
        }

        for (outboxID, messageIDs) in cancels {
            guard var delta = try pendingLabelChange(outboxID, db) else { continue }
            delta.messageIDs.removeAll { messageIDs.contains($0) }
            if delta.messageIDs.isEmpty {
                try db.run("DELETE FROM outbox WHERE id = ?", [outboxID])
            } else {
                try db.run("UPDATE outbox SET payload = ? WHERE id = ?", [try json(OutboxOperation.modifyLabels(delta)), outboxID])
            }
            // The change no longer carries these messages: if Gmail refuses it, they are not affected.
            try db.run(
                "UPDATE rule_ledger SET outbox_id = NULL WHERE outbox_id = ? AND message_id IN (SELECT value FROM json_each(?))",
                [outboxID, try json(messageIDs.sorted())]
            )
            summary.syncedChanges += 1
        }
        for (labelID, messageIDs) in inverses.sorted(by: { $0.key < $1.key }) {
            _ = try enqueue(.modifyLabels(LabelDelta(messageIDs: messageIDs, remove: [labelID])), db)
            summary.syncedChanges += 1
        }
        if summary.syncedChanges > 0 { change.outbox = true }
        return summary
    }

    /// The label change an outbox entry still waiting to be sent carries.
    static func pendingLabelChange(_ outboxID: Int64, _ db: SQLiteDatabase) throws -> LabelDelta? {
        let operation = try db.first("SELECT payload FROM outbox WHERE id = ? AND state = 'pending'", [outboxID]) { row in
            try decoder.decode(OutboxOperation.self, from: Data(row.string(0).utf8))
        }
        if case .modifyLabels(let delta) = operation { return delta }
        return nil
    }

    /// Whether reverting `row` would take its label off: it is on the message, no rule in `keptBy`
    /// owns it there, and you did not add it.
    static func wouldRemove(_ row: LedgerRow, keptBy owners: [LedgerRow], labels: Set<String>, _ db: SQLiteDatabase) throws -> Bool {
        guard labels.contains(row.target), !owners.contains(where: { $0.target == row.target }) else { return false }
        return try db.scalar("SELECT COUNT(*) FROM label_marks WHERE message_id = ? AND label_id = ? AND present = 1", [row.messageID, row.target]) == 0
    }

    static func activeLedgerRows(_ selector: LedgerSelector, _ db: SQLiteDatabase) throws -> [LedgerRow] {
        let select = "SELECT \(ledgerRowColumns) FROM rule_ledger WHERE reverted_at IS NULL"
        switch selector {
        case .rows(let ids): return try db.query("\(select) AND id IN (SELECT value FROM json_each(?)) ORDER BY id", [try json(ids)], ledgerRow)
        case .run(let id): return try db.query("\(select) AND run_id = ? ORDER BY id", [id], ledgerRow)
        case .rule(let id): return try db.query("\(select) AND rule_id = ? ORDER BY id", [id], ledgerRow)
        }
    }

    /// Ends rules' ownership of the selected labels under the removal rule: a label goes only where
    /// no other rule owns it and you did not add it. Gmail labels follow through the outbox.
    @discardableResult
    public func revertLedger(_ selector: LedgerSelector, reason: LedgerRevertReason) async throws -> RevertSummary {
        try await write { db, change in
            let rows = try Self.activeLedgerRows(selector, db)
            let summary = try Self.revert(rows, reason: reason, now: Date(), syncs: reason != .gmailRejected, db, &change)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            return summary
        }
    }

    /// Undoes a run: the labels it added go under the removal rule, and work it had left is dropped.
    /// Its decisions stay, so live processing does not add the labels again. A live run's mail still
    /// to process is not dropped: it goes on in a new live run for the same day.
    @discardableResult
    public func undoRun(_ runID: Int64) async throws -> RevertSummary {
        try await write { db, change in
            guard let run = try Self.runRecord(id: runID, db), run.state != .undone else { return RevertSummary() }
            let now = Date()
            try db.run("UPDATE rule_runs SET state = 'undone', pause_reason = NULL, finished_at = COALESCE(finished_at, ?) WHERE id = ?", [now, runID])
            if run.kind == .live {
                try Self.handOver(run, db)
            } else {
                try db.run("DELETE FROM rule_queue WHERE run_id = ?", [runID])
            }
            let summary = try Self.revert(try Self.activeLedgerRows(.run(runID), db), reason: .undo, now: now, db, &change)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            change.rules = true
            return summary
        }
    }

    /// Moves the queue rows of an undone live run to a new live run for its day.
    static func handOver(_ run: RunRecord, _ db: SQLiteDatabase) throws {
        let (rows, failed) = try db.first("SELECT COUNT(*), TOTAL(state = 'failed') FROM rule_queue WHERE run_id = ?", [run.id]) { ($0.int(0), $0.int(1)) } ?? (0, 0)
        guard rows > 0 else { return }
        let next = try createRun(.live, day: run.day, rules: try runnableRules(db).map(RunRule.init), state: .running, db)
        try db.run("UPDATE rule_queue SET run_id = ? WHERE run_id = ?", [next, run.id])
        try db.run("UPDATE rule_runs SET total = ?, failed = ? WHERE id = ?", [rows, failed, next])
        try db.run("UPDATE rule_runs SET total = MAX(total - ?, 0), failed = MAX(failed - ?, 0) WHERE id = ?", [rows, failed, run.id])
    }

    /// Messages where the rule still owns a label, newest first: what a re-check of "the labels it
    /// added" covers. Reads on the background connection.
    public func messagesLabeled(byRule ruleID: String) async throws -> [String] {
        try await readBackground { db in
            try db.query(
                """
                SELECT l.message_id FROM rule_ledger l JOIN messages m ON m.id = l.message_id
                WHERE l.rule_id = ? AND l.reverted_at IS NULL GROUP BY l.message_id ORDER BY MAX(m.date) DESC
                """,
                [ruleID]
            ) { $0.string(0) }
        }
    }

    /// Which rules own `labelID` on messages of these conversations: rule ID → its messages, newest
    /// first. Your label edits teach the rules that own the label.
    public func ruleOwners(ofLabel labelID: String, inThreads threadIDs: [String]) async throws -> [String: [String]] {
        try await read { db in
            var owners: [String: [String]] = [:]
            for (ruleID, messageID) in try db.query(
                """
                SELECT l.rule_id, l.message_id FROM rule_ledger l JOIN messages m ON m.id = l.message_id
                WHERE l.target = ? AND l.reverted_at IS NULL AND m.thread_id IN (SELECT value FROM json_each(?))
                ORDER BY m.date DESC
                """,
                [labelID, try Self.json(threadIDs)], { ($0.string(0), $0.string(1)) }
            ) {
                owners[ruleID, default: []].append(messageID)
            }
            return owners
        }
    }

    /// How many labels deleting the rule could remove: those it added that are still on their
    /// message, that no other rule co-owns and that you did not add yourself. For "Remove the 212
    /// labels it added? Labels you or another rule added stay."
    public func removableLabelCount(ruleID: String) async throws -> Int {
        try await read { db in
            try db.scalar(
                """
                SELECT COUNT(*) FROM rule_ledger l
                WHERE l.rule_id = ? AND l.reverted_at IS NULL
                  AND EXISTS (SELECT 1 FROM message_labels x WHERE x.message_id = l.message_id AND x.label_id = l.target)
                  AND NOT EXISTS (SELECT 1 FROM rule_ledger o WHERE o.message_id = l.message_id AND o.target = l.target
                      AND o.reverted_at IS NULL AND o.rule_id != l.rule_id)
                  AND NOT EXISTS (SELECT 1 FROM label_marks k WHERE k.message_id = l.message_id AND k.label_id = l.target AND k.present = 1)
                """,
                [ruleID]
            )
        }
    }

    /// Before deleting a rule: ends its ownership of the labels it added (`rule_deleted`). With
    /// `removeLabels` they go under the removal rule; without, they stay, as yours, which is what
    /// `deleteRule` alone does.
    @discardableResult
    public func deleteRuleEffects(ruleID: String, removeLabels: Bool) async throws -> RevertSummary {
        try await write { db, change in
            let now = Date()
            guard removeLabels else {
                var summary = RevertSummary()
                summary.rows = try Self.endOwnership(ofDeletedRule: ruleID, now: now, db)
                return summary
            }
            let summary = try Self.revert(try Self.activeLedgerRows(.rule(ruleID), db), reason: .ruleDeleted, now: now, db, &change)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            return summary
        }
    }

    /// Stamps a deleted rule's ledger rows `rule_deleted`, leaving its labels on their messages.
    /// Returns how many rows that was.
    static func endOwnership(ofDeletedRule ruleID: String, now: Date, _ db: SQLiteDatabase) throws -> Int {
        try db.run(
            "UPDATE rule_ledger SET reverted_at = ?, reverted_by = ? WHERE rule_id = ? AND reverted_at IS NULL",
            [now, LedgerRevertReason.ruleDeleted.rawValue, ruleID]
        )
        return db.changes
    }

    /// Gmail refused an outbox change. When rules queued it, the labels it carried stop being any
    /// rule's there (`gmail_rejected`) and come off under the removal rule; nothing more is sent.
    /// Messages an undo had taken out of the change are left alone.
    /// Returns how many rule labels the change carried, 0 when it was not the rules'.
    public func ruleOutboxRejected(_ outboxID: Int64) async throws -> Int {
        try await write { db, change in
            let carried = try db.scalar("SELECT COUNT(*) FROM rule_ledger WHERE outbox_id = ?", [outboxID])
            guard carried > 0 else { return 0 }
            // Co-owners too: Gmail does not have the label there.
            let rows = try db.query(
                """
                SELECT \(Self.ledgerRowColumns) FROM rule_ledger
                WHERE reverted_at IS NULL AND (message_id, target) IN (SELECT message_id, target FROM rule_ledger WHERE outbox_id = ?)
                """,
                [outboxID], Self.ledgerRow
            )
            _ = try Self.revert(rows, reason: .gmailRejected, now: Date(), syncs: false, db, &change)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            return carried
        }
    }

    // MARK: - Explain

    /// Why the conversation's messages carry their labels: for each label, the rules that own it,
    /// how they decided and Claude's reason; with no owner, you or Gmail added it, and rules that
    /// matched it there agree. Also the rules that judged a message and decided no.
    public func explain(threadID: String) async throws -> ThreadExplanation {
        try await read { db in
            let records = try Self.ruleRecords(db)
            let names = Dictionary(records.map { ($0.id, $0.rule.name) }, uniquingKeysWith: { first, _ in first })
            let targets = Dictionary(records.map { ($0.id, Set($0.rule.labelTargets.map(\.id))) }, uniquingKeysWith: { first, _ in first })
            let carried = try db.query(
                """
                SELECT x.message_id, l.id, l.name, l.kind, l.color_index FROM message_labels x
                JOIN messages m ON m.id = x.message_id JOIN labels l ON l.id = x.label_id
                WHERE m.thread_id = ? AND l.kind != 'system' ORDER BY m.date
                """,
                [threadID]
            ) { row in
                (messageID: row.string(0), label: MailLabel(id: row.string(1), name: row.string(2), kind: MailLabel.Kind(rawValue: row.string(3)) ?? .user, colorIndex: row.isNull(4) ? nil : row.int(4)))
            }
            let owners = try db.query(
                """
                SELECT g.id, g.message_id, g.rule_id, g.revision, g.run_id, r.kind, g.applied_at, g.changed, g.simulated, g.target,
                       d.source, v.reason, v.model, v.served_by
                FROM rule_ledger g
                JOIN messages m ON m.id = g.message_id
                LEFT JOIN rule_runs r ON r.id = g.run_id
                LEFT JOIN rule_decisions d ON d.message_id = g.message_id AND d.rule_id = g.rule_id
                LEFT JOIN verdicts v ON v.message_id = g.message_id AND v.judge_hash = d.judge_hash
                WHERE m.thread_id = ? AND g.reverted_at IS NULL
                ORDER BY g.applied_at, g.id
                """,
                [threadID]
            ) { row in
                (target: row.string(9), owner: LabelOwner(
                    ledgerID: row.int64(0), messageID: row.string(1), ruleID: row.string(2), ruleName: names[row.string(2)], revision: row.int(3),
                    runID: row.int64(4), runKind: row.optionalString(5).flatMap(RunKind.init(rawValue:)), appliedAt: row.date(6), added: row.bool(7),
                    source: row.optionalString(10).flatMap(DecisionSource.init(rawValue:)), reason: row.optionalString(11),
                    model: row.optionalString(12), servedBy: row.optionalString(13), simulated: row.bool(8)
                ))
            }
            var labels: [LabelExplanation] = []
            for (label, rows) in Dictionary(grouping: carried, by: { $0.label }).sorted(by: { $0.key.name.lowercased() < $1.key.name.lowercased() }) {
                let messageIDs = rows.map { $0.messageID }
                labels.append(LabelExplanation(
                    label: label, messageIDs: messageIDs,
                    owners: owners.filter { $0.target == label.id && messageIDs.contains($0.owner.messageID) }.map { $0.owner }
                ))
            }
            let misses = try db.query(
                """
                SELECT d.message_id, d.rule_id, d.revision, d.outcome, d.source, v.reason, v.model
                FROM rule_decisions d JOIN messages m ON m.id = d.message_id
                LEFT JOIN verdicts v ON v.message_id = d.message_id AND v.judge_hash = d.judge_hash
                WHERE m.thread_id = ? AND d.outcome != ? AND d.source != ?
                ORDER BY m.date, d.rule_id
                """,
                [threadID, Verdict.match.rawValue, DecisionSource.gate.rawValue]
            ) { row in
                RuleMiss(
                    messageID: row.string(0), ruleID: row.string(1), ruleName: names[row.string(1)], revision: row.int(2),
                    verdict: Verdict(rawValue: row.string(3)) ?? .noMatch, source: DecisionSource(rawValue: row.string(4)) ?? .gate,
                    reason: row.optionalString(5), model: row.optionalString(6)
                )
            }
            // Matches where the label was already there: the commit recorded the decision, no ledger row.
            let carrying = Set(carried.map { "\($0.messageID) \($0.label.id)" })
            let owned = Set(owners.map { "\($0.owner.messageID) \($0.owner.ruleID) \($0.target)" })
            var agreements: [RuleAgreement] = []
            for (messageID, ruleID, revision, source, reason, model) in try db.query(
                """
                SELECT d.message_id, d.rule_id, d.revision, d.source, v.reason, COALESCE(v.served_by, v.model)
                FROM rule_decisions d JOIN messages m ON m.id = d.message_id
                LEFT JOIN verdicts v ON v.message_id = d.message_id AND v.judge_hash = d.judge_hash
                WHERE m.thread_id = ? AND d.outcome = ? AND d.source != ?
                ORDER BY m.date, d.rule_id
                """,
                [threadID, Verdict.match.rawValue, DecisionSource.mark.rawValue],
                { ($0.string(0), $0.string(1), $0.int(2), DecisionSource(rawValue: $0.string(3)) ?? .gate, $0.optionalString(4), $0.optionalString(5)) }
            ) {
                for target in (targets[ruleID] ?? []).sorted()
                where carrying.contains("\(messageID) \(target)") && !owned.contains("\(messageID) \(ruleID) \(target)") {
                    agreements.append(RuleAgreement(
                        messageID: messageID, ruleID: ruleID, ruleName: names[ruleID], revision: revision, labelID: target, source: source,
                        reason: reason, model: model
                    ))
                }
            }
            return ThreadExplanation(labels: labels, misses: misses, agreements: agreements)
        }
    }
}
