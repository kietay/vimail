import Foundation
import MailCore

/// A stored rule with what the store keeps beside it.
public struct RuleRecord: Identifiable, Hashable, Sendable {
    public enum State: String, Sendable {
        case ok
        /// The breaker turned it off: it matched most new mail.
        case tripped
        /// Its label was deleted, here or in Gmail. It stays off until it adds an existing label.
        case labelMissing = "label_missing"
        /// Saved by a newer build. It is kept as it is, and stays off.
        case needsUpgrade = "needs_upgrade"
    }

    public var rule: Rule
    public var position: Int
    public var state: State
    /// Since when it judges arriving mail: when it was last turned on.
    public var liveFrom: Date?
    /// The oldest mail it covers: `liveFrom`, or earlier after a run over stored mail.
    public var coveredSince: Date?
    /// When it was turned off, or nil while it is on.
    public var disabledAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { rule.id }
}

/// A ✔ or ✖ you gave one rule for one message. It decides that message for the rule, and its digest
/// joins the prompt once the rule's tested example set (`Rule.promptExampleIDs`) includes it.
public struct RuleExample: Hashable, Sendable {
    public enum Origin: String, Sendable {
        /// The email a rule was made from.
        case seed
        /// `y`/`n` in the editor's preview.
        case preview
        /// `x`/`a` in "why these labels?".
        case explain
        /// Your label edit, for a rule whose edits teach.
        case edit
    }

    public var ruleID: String
    public var messageID: String
    public var matches: Bool
    public var origin: Origin
    /// Sender name, domain and subject (`JudgeExample.digest(of:selfAddresses:)`).
    public var digest: String
    /// The edit that made it, so undoing the edit deletes it.
    public var undoKey: String?
    public var createdAt: Date
}

/// Your own edit of one label on one message. Marks bind every rule: after a removal no rule adds
/// the label there again, and a label you added is never removed by an undo or a re-check.
public struct LabelMark: Hashable, Sendable {
    public var messageID: String
    public var labelID: String
    /// You added the label (true) or removed it (false).
    public var present: Bool
    public var undoKey: String?
    public var createdAt: Date
}

/// A sender rule for one rule: mail from this address or domain matches, or never does.
public struct RuleOverride: Hashable, Sendable {
    public enum Origin: String, Sendable {
        case user
        /// Learned from Claude's verdicts on an automated sender.
        case learned
    }

    public var ruleID: String
    /// An exact address ("a@b.com") or a domain ("@b.com"), lowercased.
    public var subject: String
    public var matches: Bool
    public var origin: Origin
    /// Verdicts that agreed with it.
    public var evidence: Int
    public var createdAt: Date
}

/// Why the store refused a change to rules or their runs.
public enum RuleStoreError: Error, Equatable, Sendable {
    case notFound
    /// The stored rule came from a newer build: saving it here would lose what this build cannot read.
    case needsUpgrade
    /// A label the rule adds no longer exists.
    case labelMissing
    /// A sender override names neither an address nor "@domain".
    case invalidSender
    /// Live runs are made by intake only.
    case liveRun
}

/// Rules, stored per account like saved views. Each semantic change is kept as a revision, so runs
/// and decisions can name the version of a rule they applied.
extension MailStore {
    // MARK: - Reading

    /// Every rule, in the order they run.
    public func rules() async throws -> [RuleRecord] {
        try await read { db in try Self.ruleRecords(db) }
    }

    static let ruleColumns = "id, key, position, enabled, revision, payload, state, live_from, covered_since, disabled_at, created_at, updated_at"

    static func ruleRecords(_ db: SQLiteDatabase) throws -> [RuleRecord] {
        try db.query("SELECT \(ruleColumns) FROM rules ORDER BY position, created_at", [], ruleRecord)
    }

    static func ruleRecord(id: String, _ db: SQLiteDatabase) throws -> RuleRecord? {
        try db.first("SELECT \(ruleColumns) FROM rules WHERE id = ?", [id], ruleRecord)
    }

    /// Reads a row leniently: a payload this build cannot read, or a rule it cannot run, comes back
    /// off and `needsUpgrade`, never dropped. The row itself is left as it is.
    static func ruleRecord(_ row: SQLRow) -> RuleRecord {
        let payload = Data(row.string(5).utf8)
        var state = RuleRecord.State(rawValue: row.string(6)) ?? .needsUpgrade
        var rule: Rule
        if let decoded = try? decoder.decode(Rule.self, from: payload) {
            rule = decoded
        } else {
            let fields = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            rule = Rule(id: row.string(0), key: row.string(1), name: fields?["name"] as? String ?? "", enabled: false, revision: row.int(4), then: [])
            rule.schemaVersion = Rule.currentSchemaVersion + 1
        }
        if !rule.isSupported { state = .needsUpgrade }
        // The columns are written with the payload and are what queries test.
        rule.enabled = row.bool(3) && state != .needsUpgrade
        rule.revision = row.int(4)
        return RuleRecord(
            rule: rule, position: row.int(2), state: state, liveFrom: row.optionalDate(7), coveredSince: row.optionalDate(8),
            disabledAt: row.optionalDate(9), createdAt: row.date(10), updatedAt: row.date(11)
        )
    }

    /// Enabled rules this build can run, in order.
    static func runnableRules(_ db: SQLiteDatabase) throws -> [Rule] {
        try ruleRecords(db).map(\.rule).filter(\.enabled)
    }

    /// Rules as they were at the given revisions, such as a run's. Revisions that are gone or that
    /// this build cannot read are left out. Reads on the background connection.
    public func rules(at revisions: [RunRule]) async throws -> [Rule] {
        try await readBackground { db in
            try revisions.compactMap { ref in
                try db.first("SELECT payload FROM rule_revisions WHERE rule_id = ? AND revision = ?", [ref.id, ref.revision]) { row in
                    try? Self.decoder.decode(Rule.self, from: Data(row.string(0).utf8))
                } ?? nil
            }
        }
    }

    /// A stored payload this build can decode and save again without losing anything.
    static func savableRule(_ payload: String) -> Rule? {
        guard let rule = try? decoder.decode(Rule.self, from: Data(payload.utf8)), rule.schemaVersion <= Rule.currentSchemaVersion else { return nil }
        return rule
    }

    /// Labels that rules add, so a reset can bring them back. Gmail labels come back too: the next
    /// sync's `replaceProviderLabels` only notices a label Gmail deleted if it is still stored.
    static func labels(targetedByRules db: SQLiteDatabase) throws -> [MailLabel] {
        let targets = Set(try db.query("SELECT payload FROM rules") { row in
            (try? decoder.decode(Rule.self, from: Data(row.string(0).utf8)))?.labelTargets.map(\.id) ?? []
        }.joined())
        return try labels(db).filter { targets.contains($0.id) }
    }

    // MARK: - Changes

    /// Adds a rule at the end. The store assigns its key ("r1", "r2", …); the draft's key is ignored.
    public func createRule(_ draft: Rule) async throws -> RuleRecord {
        try await write { db, change in
            guard try !Self.missingTargets(draft, db) else { throw RuleStoreError.labelMissing }
            var rule = try Self.rule(draft, key: try Self.nextRuleKey(db))
            rule.revision = 1
            let now = Date()
            let position = try db.scalar("SELECT COALESCE(MAX(position) + 1, 0) FROM rules")
            try db.run(
                """
                INSERT INTO rules(id, key, position, enabled, revision, payload, state, live_from, covered_since, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 'ok', ?, ?, ?, ?)
                """,
                [rule.id, rule.key, position, rule.enabled, rule.revision, try Self.json(rule), rule.enabled ? now : nil, rule.enabled ? now : nil, now, now]
            )
            try Self.saveRevision(rule, db)
            change.rules = true
            guard let record = try Self.ruleRecord(id: rule.id, db) else { throw RuleStoreError.notFound }
            return record
        }
    }

    /// Saves an edited rule. A change to what it decides (`Rule.changesSemantics(from:)`) makes a new
    /// revision and pauses the runs that apply the old one, or marks them out of date when they are
    /// paused or waiting for confirmation already (`rule_changed`); renaming it or changing its
    /// switches keeps the revision. Returns the rule as stored.
    @discardableResult
    public func saveRule(_ rule: Rule) async throws -> Rule {
        try await write { db, change in
            guard let record = try Self.ruleRecord(id: rule.id, db) else { throw RuleStoreError.notFound }
            var saved = rule.key == record.rule.key ? rule : try Self.rule(rule, key: record.rule.key)
            saved.revision = record.rule.revision + (saved.changesSemantics(from: record.rule) ? 1 : 0)
            try Self.update(record, to: saved, db)
            if saved.revision != record.rule.revision {
                try Self.saveRevision(saved, db)
                _ = try Self.pauseRuns(containing: saved.id, reason: .ruleChanged, db)
            }
            change.rules = true
            return saved
        }
    }

    /// Turns a rule on or off. Turning it back on returns the time it was off, so the mail that
    /// arrived meanwhile can be offered as a run. Turning it off takes it out of its runs.
    @discardableResult
    public func setRuleEnabled(id: String, _ enabled: Bool) async throws -> DateInterval? {
        try await write { db, change in
            guard let record = try Self.ruleRecord(id: id, db) else { throw RuleStoreError.notFound }
            guard record.rule.enabled != enabled else { return nil }
            var rule = record.rule
            rule.enabled = enabled
            change.rules = true
            return try Self.update(record, to: rule, db)
        }
    }

    /// Moves a rule to `position` (0 runs first), shifting the others.
    public func moveRule(id: String, to position: Int) async throws {
        try await write { db, change in
            var ids = try db.query("SELECT id FROM rules ORDER BY position, created_at") { $0.string(0) }
            guard let index = ids.firstIndex(of: id) else { throw RuleStoreError.notFound }
            ids.remove(at: index)
            ids.insert(id, at: min(max(position, 0), ids.count))
            for (index, ruleID) in ids.enumerated() {
                try db.run("UPDATE rules SET position = ? WHERE id = ?", [index, ruleID])
            }
            change.rules = true
        }
    }

    /// Deletes a rule with its revisions, examples, sender overrides and decisions, and takes it out
    /// of unfinished runs. Labels it added stay, as yours, unless `deleteRuleEffects(ruleID:removeLabels:)`
    /// removed them first.
    public func deleteRule(id: String) async throws {
        try await write { db, change in
            try db.run("DELETE FROM rules WHERE id = ?", [id])
            try db.run("DELETE FROM rule_revisions WHERE rule_id = ?", [id])
            try db.run("DELETE FROM rule_examples WHERE rule_id = ?", [id])
            try db.run("DELETE FROM rule_overrides WHERE rule_id = ?", [id])
            try db.run("DELETE FROM rule_decisions WHERE rule_id = ?", [id])
            try Self.removeFromRuns(ruleID: id, db)
            _ = try Self.endOwnership(ofDeletedRule: id, now: Date(), db)
            change.rules = true
        }
    }

    /// Writes `rule` over its stored `record`. Turning it off stamps `disabled_at` and takes it out of
    /// its runs; turning it on clears it, restarts `live_from` and returns the time it was off.
    @discardableResult
    static func update(_ record: RuleRecord, to rule: Rule, _ db: SQLiteDatabase) throws -> DateInterval? {
        guard record.rule.schemaVersion <= Rule.currentSchemaVersion else { throw RuleStoreError.needsUpgrade }
        let missing = try missingTargets(rule, db)
        if rule.enabled {
            guard rule.isSupported else { throw RuleStoreError.needsUpgrade }
            guard !missing else { throw RuleStoreError.labelMissing }
        }
        let now = Date()
        let turnedOn = rule.enabled && !record.rule.enabled
        var state = try db.first("SELECT state FROM rules WHERE id = ?", [rule.id]) { $0.string(0) } ?? RuleRecord.State.ok.rawValue
        if missing {
            state = RuleRecord.State.labelMissing.rawValue
        } else if turnedOn || state == RuleRecord.State.labelMissing.rawValue {
            state = RuleRecord.State.ok.rawValue
        }
        var gap: DateInterval?
        var liveFrom = record.liveFrom
        var coveredSince = record.coveredSince
        var disabledAt = record.disabledAt
        if turnedOn {
            gap = disabledAt.map { DateInterval(start: $0, end: max($0, now)) }
            disabledAt = nil
            liveFrom = now
            coveredSince = coveredSince ?? now
        } else if !rule.enabled && record.rule.enabled {
            disabledAt = now
            try removeFromRuns(ruleID: rule.id, db)
        }
        try db.run(
            """
            UPDATE rules SET payload = ?, enabled = ?, revision = ?, state = ?, live_from = ?, covered_since = ?,
                disabled_at = ?, updated_at = ?
            WHERE id = ?
            """,
            [try json(rule), rule.enabled, rule.revision, state, liveFrom, coveredSince, disabledAt, now, rule.id]
        )
        return gap
    }

    static func saveRevision(_ rule: Rule, _ db: SQLiteDatabase) throws {
        try db.run(
            "INSERT OR REPLACE INTO rule_revisions(rule_id, revision, payload, created_at) VALUES (?, ?, ?, ?)",
            [rule.id, rule.revision, try json(rule), Date()]
        )
    }

    /// True when a label the rule adds does not exist.
    static func missingTargets(_ rule: Rule, _ db: SQLiteDatabase) throws -> Bool {
        try rule.labelTargets.contains { try db.scalar("SELECT COUNT(*) FROM labels WHERE id = ?", [$0.id]) == 0 }
    }

    /// The next key from a counter that only goes up: prompts and Claude's answers name rules by key,
    /// so a deleted rule's key is never given to another.
    static func nextRuleKey(_ db: SQLiteDatabase) throws -> String {
        var number = Int(try db.first("SELECT value FROM meta WHERE key = 'rules_next_key'") { $0.string(0) } ?? "") ?? 1
        while try db.scalar("SELECT COUNT(*) FROM rules WHERE key = ?", ["r\(number)"]) > 0 { number += 1 }
        try setMeta("rules_next_key", String(number + 1), db)
        return "r\(number)"
    }

    /// `rule` under another key. `Rule.key` is a constant, so this goes through the stored form.
    static func rule(_ rule: Rule, key: String) throws -> Rule {
        guard var fields = try JSONSerialization.jsonObject(with: encoder.encode(rule)) as? [String: Any] else { return rule }
        fields["key"] = key
        return try decoder.decode(Rule.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    // MARK: - Labels

    /// Applies `transform` to every rule this build can save, earlier revisions included. Non-nil
    /// results are saved without a new revision: for label ID changes, which keep a rule's meaning.
    static func rewriteRules(_ db: SQLiteDatabase, _ transform: (Rule) -> Rule?) throws {
        for (id, payload) in try db.query("SELECT id, payload FROM rules", [], { ($0.string(0), $0.string(1)) }) {
            guard let rule = savableRule(payload), let updated = transform(rule) else { continue }
            try db.run("UPDATE rules SET payload = ? WHERE id = ?", [try json(updated), id])
        }
        for (id, revision, payload) in try db.query("SELECT rule_id, revision, payload FROM rule_revisions", [], { ($0.string(0), $0.int(1), $0.string(2)) }) {
            guard let rule = savableRule(payload), let updated = transform(rule) else { continue }
            try db.run("UPDATE rule_revisions SET payload = ? WHERE rule_id = ? AND revision = ?", [try json(updated), id, revision])
        }
    }

    /// A label is gone, deleted here or in Gmail. Rules that add it turn off as `label_missing` and
    /// leave their runs, and the labels they added stop being theirs (`label_deleted`). Runs in the
    /// transaction that removes the label. Returns the IDs of the rules it turned off.
    @discardableResult
    static func labelRemoved(_ labelID: String, _ db: SQLiteDatabase, _ change: inout StoreChange) throws -> [String] {
        let now = Date()
        var turnedOff: [String] = []
        for (id, payload) in try db.query("SELECT id, payload FROM rules", [], { ($0.string(0), $0.string(1)) }) {
            guard let rule = try? decoder.decode(Rule.self, from: Data(payload.utf8)), rule.labelTargets.contains(where: { $0.id == labelID }) else { continue }
            var disabled = rule
            disabled.enabled = false
            // A payload from a newer build is kept as it is; the columns turn it off.
            let updated = rule.schemaVersion <= Rule.currentSchemaVersion ? try json(disabled) : payload
            try db.run(
                """
                UPDATE rules SET state = 'label_missing', enabled = 0, payload = ?, updated_at = ?,
                    disabled_at = CASE WHEN enabled = 1 THEN ? ELSE disabled_at END
                WHERE id = ?
                """,
                [updated, now, now, id]
            )
            try removeFromRuns(ruleID: id, db)
            turnedOff.append(id)
            change.rules = true
        }
        try db.run(
            "UPDATE rule_ledger SET reverted_at = ?, reverted_by = ? WHERE target = ? AND reverted_at IS NULL",
            [now, LedgerRevertReason.labelDeleted.rawValue, labelID]
        )
        return turnedOff
    }
}

/// What rules learn from you: examples, your label edits and sender overrides.
extension MailStore {
    // MARK: - Examples

    /// Adds or replaces the example `ruleID` has for `messageID`. The digest is taken from the message now.
    @discardableResult
    public func setExample(ruleID: String, messageID: String, matches: Bool, origin: RuleExample.Origin, undoKey: String? = nil) async throws -> RuleExample {
        let me = selfAddresses
        return try await write { db, change in
            guard try db.scalar("SELECT COUNT(*) FROM rules WHERE id = ?", [ruleID]) > 0,
                  let message = try db.first("SELECT \(Self.messageColumns) FROM messages m WHERE m.id = ?", [messageID], { try Self.decodeMessage($0, labels: []) })
            else { throw RuleStoreError.notFound }
            let example = RuleExample(
                ruleID: ruleID, messageID: messageID, matches: matches, origin: origin,
                digest: JudgeExample.digest(of: message, selfAddresses: me), undoKey: undoKey, createdAt: Date()
            )
            try db.run(
                "INSERT OR REPLACE INTO rule_examples(rule_id, message_id, verdict, origin, digest, undo_key, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [ruleID, messageID, matches, origin.rawValue, example.digest, undoKey, example.createdAt]
            )
            change.rules = true
            return example
        }
    }

    public func removeExample(ruleID: String, messageID: String) async throws {
        try await write { db, change in
            try db.run("DELETE FROM rule_examples WHERE rule_id = ? AND message_id = ?", [ruleID, messageID])
            change.rules = true
        }
    }

    /// A rule's examples, newest first.
    public func examples(ruleID: String) async throws -> [RuleExample] {
        try await read { db in try db.query("SELECT \(Self.exampleColumns) FROM rule_examples WHERE rule_id = ? ORDER BY created_at DESC", [ruleID], Self.example) }
    }

    /// Every rule's example for one message.
    public func examples(messageID: String) async throws -> [RuleExample] {
        try await read { db in try db.query("SELECT \(Self.exampleColumns) FROM rule_examples WHERE message_id = ? ORDER BY created_at DESC", [messageID], Self.example) }
    }

    static let exampleColumns = "rule_id, message_id, verdict, origin, digest, undo_key, created_at"

    static func example(_ row: SQLRow) -> RuleExample {
        RuleExample(
            ruleID: row.string(0), messageID: row.string(1), matches: row.bool(2), origin: RuleExample.Origin(rawValue: row.string(3)) ?? .preview,
            digest: row.string(4), undoKey: row.optionalString(5), createdAt: row.date(6)
        )
    }

    // MARK: - Label marks

    /// Records your edit of `labelID` on these messages. A removal also ends the rules' ownership of
    /// the label there (ledger rows stamped `user`); nothing is removed, since you already removed it.
    /// Returns how many rule-added labels that was.
    @discardableResult
    public func setLabelMarks(messageIDs: [String], labelID: String, present: Bool, undoKey: String? = nil) async throws -> Int {
        try await write { db, change in
            let now = Date()
            var stamped = 0
            for id in messageIDs {
                try db.run(
                    "INSERT OR REPLACE INTO label_marks(message_id, label_id, present, undo_key, created_at) VALUES (?, ?, ?, ?, ?)",
                    [id, labelID, present, undoKey, now]
                )
                guard !present else { continue }
                try db.run(
                    "UPDATE rule_ledger SET reverted_at = ?, reverted_by = ? WHERE message_id = ? AND target = ? AND reverted_at IS NULL",
                    [now, LedgerRevertReason.user.rawValue, id, labelID]
                )
                stamped += db.changes
            }
            change.rules = true
            return stamped
        }
    }

    /// Forgets your edits of `labelID` on these messages.
    public func removeLabelMarks(messageIDs: [String], labelID: String) async throws {
        try await write { db, change in
            for id in messageIDs {
                try db.run("DELETE FROM label_marks WHERE message_id = ? AND label_id = ?", [id, labelID])
            }
            change.rules = true
        }
    }

    public func labelMarks(messageIDs: [String]) async throws -> [LabelMark] {
        try await read { db in
            try db.query("SELECT \(Self.markColumns) FROM label_marks WHERE message_id IN (SELECT value FROM json_each(?))", [try Self.json(messageIDs)], Self.mark)
        }
    }

    public func labelMarks(labelID: String) async throws -> [LabelMark] {
        try await read { db in try db.query("SELECT \(Self.markColumns) FROM label_marks WHERE label_id = ?", [labelID], Self.mark) }
    }

    static let markColumns = "message_id, label_id, present, undo_key, created_at"

    static func mark(_ row: SQLRow) -> LabelMark {
        LabelMark(messageID: row.string(0), labelID: row.string(1), present: row.bool(2), undoKey: row.optionalString(3), createdAt: row.date(4))
    }

    /// Undoes what one label edit taught: deletes the marks and examples it made. Where its removal
    /// had ended a rule's ownership and the label is back (undo it first), the rule owns it again.
    public func deleteMarksAndExamples(undoKey: String) async throws {
        try await write { db, change in
            let removals = try db.query(
                "SELECT message_id, label_id, created_at FROM label_marks WHERE undo_key = ? AND present = 0", [undoKey]
            ) { ($0.string(0), $0.string(1), $0.int64(2)) }
            for (messageID, labelID, stampedAt) in removals {
                guard try db.scalar("SELECT COUNT(*) FROM message_labels WHERE message_id = ? AND label_id = ?", [messageID, labelID]) > 0 else { continue }
                try db.run(
                    """
                    UPDATE rule_ledger SET reverted_at = NULL, reverted_by = NULL
                    WHERE message_id = ? AND target = ? AND reverted_by = ? AND reverted_at = ?
                      AND NOT EXISTS (SELECT 1 FROM rule_ledger a WHERE a.message_id = rule_ledger.message_id
                          AND a.rule_id = rule_ledger.rule_id AND a.target = rule_ledger.target AND a.reverted_at IS NULL)
                    """,
                    [messageID, labelID, LedgerRevertReason.user.rawValue, stampedAt]
                )
            }
            try db.run("DELETE FROM label_marks WHERE undo_key = ?", [undoKey])
            try db.run("DELETE FROM rule_examples WHERE undo_key = ?", [undoKey])
            change.rules = true
        }
    }

    // MARK: - Sender overrides

    /// Sets what `ruleID` decides for mail from `subject`: an address, or "@domain" for a whole domain.
    public func setOverride(ruleID: String, subject: String, matches: Bool, origin: RuleOverride.Origin, evidence: Int = 0) async throws {
        let subject = subject.trimmingCharacters(in: .whitespaces).lowercased()
        // "local@domain" or "@domain": one "@", a domain, no spaces.
        let parts = subject.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, !subject.contains(where: \.isWhitespace) else { throw RuleStoreError.invalidSender }
        try await write { db, change in
            guard try db.scalar("SELECT COUNT(*) FROM rules WHERE id = ?", [ruleID]) > 0 else { throw RuleStoreError.notFound }
            try db.run(
                "INSERT OR REPLACE INTO rule_overrides(rule_id, subject, verdict, origin, evidence, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                [ruleID, subject, matches, origin.rawValue, evidence, Date()]
            )
            change.rules = true
        }
    }

    public func removeOverride(ruleID: String, subject: String) async throws {
        try await write { db, change in
            try db.run("DELETE FROM rule_overrides WHERE rule_id = ? AND subject = ?", [ruleID, subject.trimmingCharacters(in: .whitespaces).lowercased()])
            change.rules = true
        }
    }

    /// A rule's sender overrides, addresses and domains in order.
    public func overrides(ruleID: String) async throws -> [RuleOverride] {
        try await read { db in
            try db.query("SELECT rule_id, subject, verdict, origin, evidence, created_at FROM rule_overrides WHERE rule_id = ? ORDER BY subject", [ruleID]) { row in
                RuleOverride(
                    ruleID: row.string(0), subject: row.string(1), matches: row.bool(2), origin: RuleOverride.Origin(rawValue: row.string(3)) ?? .user,
                    evidence: row.int(4), createdAt: row.date(5)
                )
            }
        }
    }
}
