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

/// Why a rule could not be saved or turned on.
public enum RuleStoreError: Error, Equatable, Sendable {
    case notFound
    /// The stored rule came from a newer build: saving it here would lose what this build cannot read.
    case needsUpgrade
    /// A label the rule adds no longer exists.
    case labelMissing
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
    /// revision; renaming it or changing its switches keeps the revision. Returns the rule as stored.
    @discardableResult
    public func saveRule(_ rule: Rule) async throws -> Rule {
        try await write { db, change in
            guard let record = try Self.ruleRecord(id: rule.id, db) else { throw RuleStoreError.notFound }
            var saved = rule.key == record.rule.key ? rule : try Self.rule(rule, key: record.rule.key)
            saved.revision = record.rule.revision + (saved.changesSemantics(from: record.rule) ? 1 : 0)
            try Self.update(record, to: saved, db)
            if saved.revision != record.rule.revision { try Self.saveRevision(saved, db) }
            change.rules = true
            return saved
        }
    }

    /// Turns a rule on or off. Turning it back on returns the time it was off, so the mail that
    /// arrived meanwhile can be offered as a run.
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

    /// Deletes a rule with its revisions, examples and sender overrides. What it already did (its
    /// decisions and ledger) is left to the rules engine, which removes or keeps its labels.
    public func deleteRule(id: String) async throws {
        try await write { db, change in
            try db.run("DELETE FROM rules WHERE id = ?", [id])
            try db.run("DELETE FROM rule_revisions WHERE rule_id = ?", [id])
            try db.run("DELETE FROM rule_examples WHERE rule_id = ?", [id])
            try db.run("DELETE FROM rule_overrides WHERE rule_id = ?", [id])
            change.rules = true
        }
    }

    /// Writes `rule` over its stored `record`. Turning it off stamps `disabled_at`; turning it on
    /// clears it, restarts `live_from` and returns the time it was off.
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

    /// A label is gone, deleted here or in Gmail. Rules that add it turn off as `label_missing`, and
    /// the labels they added stop being theirs (`label_deleted`). Runs in the transaction that removes the label.
    static func labelRemoved(_ labelID: String, _ db: SQLiteDatabase, _ change: inout StoreChange) throws {
        let now = Date()
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
            change.rules = true
        }
        try db.run("UPDATE rule_ledger SET reverted_at = ?, reverted_by = 'label_deleted' WHERE target = ? AND reverted_at IS NULL", [now, labelID])
    }
}
