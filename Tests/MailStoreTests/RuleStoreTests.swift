import Foundation
import Testing
@testable import MailCore
@testable import MailStore

/// Adds one row to every table that records rules' work on `messageID`.
func addRuleWork(_ store: MailStore, messageID: String, ruleID: String, labelID: String) throws {
    try store.writeNow { db, _ in
        try db.run("INSERT INTO rule_runs(kind, rules, state, created_at) VALUES ('manual', '[]', 'done', 0)")
        let run = db.lastInsertRowID
        try db.run("INSERT INTO rule_queue(message_id, run_id, priority) VALUES (?, ?, 1)", [messageID, run])
        try db.run("INSERT INTO rule_decisions(message_id, rule_id, revision, outcome, source, run_id, decided_at) VALUES (?, ?, 1, 'match', 'gate', ?, 0)", [messageID, ruleID, run])
        try db.run(
            "INSERT INTO rule_ledger(run_id, rule_id, revision, message_id, thread_id, effect, target, changed, applied_at) VALUES (?, ?, 1, ?, 't', 'add_label', ?, 1, 0)",
            [run, ruleID, messageID, labelID]
        )
        try db.run("INSERT INTO label_marks(message_id, label_id, present, created_at) VALUES (?, ?, 0, 0)", [messageID, labelID])
        try db.run("INSERT INTO rule_examples(rule_id, message_id, verdict, origin, digest, created_at) VALUES (?, ?, 1, 'preview', 'Nina · @parkhouse.me · Hi', 0)", [ruleID, messageID])
        try db.run("INSERT INTO rule_overrides(rule_id, subject, verdict, origin, created_at) VALUES (?, ?, 1, 'explain', 0)", [ruleID, "@\(messageID).example"])
        try db.run("INSERT INTO verdicts(message_id, judge_hash, verdict, reason, examples_digest, model, served_by, created_at) VALUES (?, 'h', 'match', 'r', 'd', 'm', 'm', 0)", [messageID])
    }
}

func rowCounts(_ store: MailStore, messageID: String? = nil) throws -> [String: Int] {
    let tables = ["rule_queue", "rule_decisions", "rule_ledger", "label_marks", "rule_examples", "verdicts", "rule_runs", "rule_overrides", "rules", "rule_revisions"]
    return try store.readNow { db in
        var counts: [String: Int] = [:]
        for table in tables {
            let filtered = messageID != nil && !["rule_runs", "rule_overrides", "rules", "rule_revisions"].contains(table)
            counts[table] = try db.scalar("SELECT COUNT(*) FROM \(table)\(filtered ? " WHERE message_id = ?" : "")", filtered ? [messageID!] : [])
        }
        return counts
    }
}

@Suite("Rules in the store")
struct RuleStoreTests {
    // MARK: - Migration

    /// A database from before rules: version 2, which the installed app may already have.
    @Test func migratesADatabaseFromBeforeRules() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-tests-\(UUID().uuidString)").appendingPathComponent("mail.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.execute("PRAGMA journal_mode = WAL")
            try db.transaction {
                try db.execute(Schema.migrations[0])
                try db.execute(Schema.migrations[1])
                try db.execute("PRAGMA user_version = 2")
            }
            try db.transaction {
                try MailStore.upsertLabel(MailLabel(id: "Label_1", name: "work", kind: .user, colorIndex: 3), db)
                try MailStore.upsertLabel(MailLabel(id: "local-1", name: "later", kind: .local), db)
                _ = try MailStore.upsertMessage(message("m1", thread: "t1", subject: "Budget", labels: ["INBOX", "Label_1"]), localLabels: [], me: [], db)
                try MailStore.refreshThreads(["t1"], db, selfAddresses: [])
                try MailStore.saveView(SavedView(id: "v1", name: "Work", labelID: "Label_1"), db)
                try MailStore.setMeta("cursor", "42", db)
            }
        }

        let store = try MailStore(url: url)
        #expect(try store.readNow { try $0.scalar("PRAGMA user_version") } == Schema.migrations.count)
        #expect(try await store.threads(.mailbox(.label("Label_1"))).map(\.id) == ["t1"])
        #expect(try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: .parse("budget"))).map(\.id) == ["t1"])
        #expect(Set(try await store.labels().map(\.id)) == ["Label_1", "local-1"])
        #expect(try await store.savedViews().map(\.id) == ["v1"])
        #expect(try await store.meta("cursor") == "42")

        let names = Set(try store.readNow { db in try db.query("SELECT name FROM sqlite_master WHERE type IN ('table', 'index')") { $0.string(0) } })
        let expected: Set<String> = [
            "messages_date", "rules", "rule_revisions", "rule_examples", "label_marks", "rule_overrides", "verdicts",
            "rule_decisions", "rule_decisions_rule", "rule_runs", "rule_runs_live_day", "rule_queue", "rule_queue_due",
            "rule_ledger", "rule_ledger_message", "rule_ledger_run", "rule_ledger_outbox", "rule_ledger_active",
            "rule_call_costs", "rule_call_costs_model",
        ]
        #expect(expected.isSubset(of: names))
        let runColumns = try store.readNow { db in try db.query("SELECT name FROM pragma_table_info('rule_runs')") { $0.string(0) } }
        #expect(runColumns.contains("confirmed_at"))
        // Opening again does not migrate twice.
        _ = try MailStore(url: url)
    }

    // MARK: - Rules

    @Test func createdRulesGetKeysThatAreNeverReused() async throws {
        let store = try await seededStore()
        let first = try await addRule(store, name: "Receipts")
        let second = try await addRule(store, name: "Travel")
        #expect([first.rule.key, second.rule.key] == ["r1", "r2"])
        #expect(first.position == 0 && second.position == 1)
        #expect(first.rule.revision == 1 && first.state == .ok)
        #expect(first.liveFrom != nil && first.coveredSince != nil && first.disabledAt == nil)

        try await store.deleteRule(id: second.id)
        let third = try await addRule(store, name: "Deploys")
        #expect(third.rule.key == "r3")
        #expect(try await store.rules().map(\.rule.name) == ["Receipts", "Deploys"])
        #expect(try rowCounts(store)["rule_revisions"] == 2)

        // A rule created off covers nothing yet.
        let off = try await addRule(store, name: "Later", enabled: false)
        #expect(off.liveFrom == nil && off.coveredSince == nil && off.disabledAt == nil)
    }

    @Test func onlySemanticEditsMakeRevisions() async throws {
        let store = try await seededStore()
        var rule = try await addRule(store).rule

        rule.name = "Receipts and invoices"
        rule.editsTeach = false
        rule = try await store.saveRule(rule)
        #expect(rule.revision == 1)

        rule.when = "from:stripe"
        rule = try await store.saveRule(rule)
        #expect(rule.revision == 2)
        let stored = try #require(try await store.rules().first)
        #expect(stored.rule == rule)
        let revisions = try store.readNow { db in
            try db.query("SELECT revision, payload FROM rule_revisions WHERE rule_id = ? ORDER BY revision", [rule.id]) {
                ($0.int(0), try JSONDecoder().decode(Rule.self, from: Data($0.string(1).utf8)))
            }
        }
        #expect(revisions.map(\.0) == [1, 2])
        #expect(revisions.map(\.1.when) == ["", "from:stripe"])
    }

    @Test func switchingOffStampsTheGap() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        #expect(try await store.setRuleEnabled(id: rule.id, false) == nil)
        let off = try #require(try await store.rules().first)
        let disabledAt = try #require(off.disabledAt)
        #expect(!off.rule.enabled)
        #expect(try await store.setRuleEnabled(id: rule.id, false) == nil)

        let gap = try #require(try await store.setRuleEnabled(id: rule.id, true))
        #expect(gap.start == disabledAt)
        let on = try #require(try await store.rules().first)
        #expect(on.rule.enabled && on.disabledAt == nil)
        #expect(on.coveredSince == rule.coveredSince)
        #expect(try #require(on.liveFrom) >= disabledAt)
        // The payload agrees with the columns.
        let payload = try store.readNow { db in try db.first("SELECT payload FROM rules") { $0.string(0) } }
        #expect(try JSONDecoder().decode(Rule.self, from: Data(try #require(payload).utf8)).enabled)
    }

    @Test func movingReordersRules() async throws {
        let store = try await seededStore()
        let a = try await addRule(store, name: "A")
        try await addRule(store, name: "B")
        try await addRule(store, name: "C")
        try await store.moveRule(id: a.id, to: 2)
        #expect(try await store.rules().map(\.rule.name) == ["B", "C", "A"])
        #expect(try await store.rules().map(\.position) == [0, 1, 2])
        try await store.moveRule(id: a.id, to: 0)
        #expect(try await store.rules().map(\.rule.name) == ["A", "B", "C"])
    }

    @Test func rulesFromANewerBuildAreKeptOff() async throws {
        let store = try await seededStore()
        try store.writeNow { db, _ in
            try db.run(
                "INSERT INTO rules(id, key, position, enabled, revision, payload, created_at, updated_at) VALUES (?, ?, 0, 1, 4, ?, 0, 0)",
                ["r_unread", "r1", #"{"id":"r_unread","key":"r1","name":"Future","when":{"all":[]}}"#]
            )
            try db.run(
                "INSERT INTO rules(id, key, position, enabled, revision, payload, created_at, updated_at) VALUES (?, ?, 1, 1, 1, ?, 0, 0)",
                ["r_action", "r2", #"{"id":"r_action","key":"r2","name":"Forward","enabled":true,"then":[{"type":"forward","to":"x@y.z"}]}"#]
            )
        }
        let records = try await store.rules()
        #expect(records.map(\.id) == ["r_unread", "r_action"])
        #expect(records.map(\.state) == [.needsUpgrade, .needsUpgrade])
        #expect(records.allSatisfy { !$0.rule.enabled })
        #expect(records.map(\.rule.name) == ["Future", "Forward"])
        #expect(records[0].rule.revision == 4)

        // Saving would lose what this build cannot read; switching on would run what it cannot do.
        await #expect(throws: RuleStoreError.needsUpgrade) { try await store.saveRule(records[0].rule) }
        await #expect(throws: RuleStoreError.needsUpgrade) { try await store.setRuleEnabled(id: "r_unread", true) }
        await #expect(throws: RuleStoreError.needsUpgrade) { try await store.setRuleEnabled(id: "r_action", true) }
        let payload = try store.readNow { db in try db.first("SELECT payload FROM rules WHERE id = 'r_unread'") { $0.string(0) } }
        #expect(payload?.contains("\"all\"") == true)
        // A new rule takes the next free key.
        #expect(try await addRule(store).rule.key == "r3")
    }

    @Test func ruleChangesNotifyObservers() async throws {
        let store = try await seededStore()
        let box = ChangeBox()
        store.observe { box.append($0) }
        let rule = try await addRule(store)
        try await store.setRuleEnabled(id: rule.id, false)
        try await store.deleteRule(id: rule.id)
        #expect(box.changes.filter(\.rules).count == 3)
    }

    // MARK: - Labels

    @Test func concurrentEnsureLabelMakesOneLabel() async throws {
        let store = try await seededStore()
        let results = try await withThrowingTaskGroup(of: (label: MailLabel, created: Bool).self) { group in
            for index in 0..<16 { group.addTask { try await store.ensureLabel(named: index.isMultiple(of: 2) ? "Clients" : " clients ", kind: .local) } }
            var results: [(label: MailLabel, created: Bool)] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(Set(results.map(\.label.id)).count == 1)
        #expect(results.filter(\.created).count == 1)
        #expect(try await store.labels().filter { $0.name.lowercased() == "clients" }.count == 1)
    }

    @Test func ensureLabelPrefersTheKindAskedFor() async throws {
        let store = try await seededStore()
        // Only the Gmail label exists: the picker reuses it, as before.
        #expect(try await store.ensureLabel(named: "Work", kind: .local).label.id == "Label_1")
        let local = try await store.createLabel(name: "work", kind: .local, colorIndex: nil)
        #expect(try await store.ensureLabel(named: "work", kind: .local).label.id == local.id)
        #expect(try await store.ensureLabel(named: "work", kind: .user).label.id == "Label_1")
        let created = try await store.ensureLabel(named: "Clients", kind: .user)
        #expect(created.created && created.label.kind == .user && created.label.id.hasPrefix("pending-"))
        #expect(try await store.outboxItems().map(\.operation) == [.createLabel(localID: created.label.id, name: "Clients")])
    }

    @Test func resolveLabelPrefersGmailThenLocalThenCreatesLocal() async throws {
        let store = try await seededStore()
        #expect(try await store.resolveLabel(name: "WORK").id == "Label_1")
        _ = try await store.createLabel(name: "work", kind: .local, colorIndex: nil)
        #expect(try await store.resolveLabel(name: "work").id == "Label_1")

        let receipts = try await store.resolveLabel(name: " Receipts ")
        #expect(receipts.kind == .local && receipts.name == "Receipts")
        #expect(try await store.resolveLabel(name: "receipts") == receipts)
        // System labels are never targets.
        #expect(try await store.resolveLabel(name: "inbox").kind == .local)
        #expect(try await store.outboxCount() == 0)
    }

    @Test func deletingATargetLabelTurnsItsRulesOff() async throws {
        let store = try await seededStore()
        let receipts = try await addRule(store, name: "Receipts")
        let travel = try await addRule(store, name: "Travel")
        let target = receipts.rule.labelTargets[0].id
        try addRuleWork(store, messageID: "m3", ruleID: receipts.id, labelID: target)
        let box = ChangeBox()
        store.observe { box.append($0) }

        try await store.deleteLabel(id: target)
        let records = try await store.rules()
        #expect(records.map(\.state) == [.labelMissing, .ok])
        #expect(records.map(\.rule.enabled) == [false, true])
        #expect(records[0].disabledAt != nil)
        #expect(records[1].id == travel.id)
        let ledger = try store.readNow { db in try db.first("SELECT reverted_at IS NOT NULL, reverted_by FROM rule_ledger") { ($0.bool(0), $0.string(1)) } }
        #expect(ledger?.0 == true && ledger?.1 == "label_deleted")
        #expect(box.changes.contains { $0.rules && $0.labels })

        // It stays off until it adds a label that exists.
        await #expect(throws: RuleStoreError.labelMissing) { try await store.setRuleEnabled(id: receipts.id, true) }
        var fixed = records[0].rule
        let other = try await store.resolveLabel(name: "Bills")
        fixed.then = [.addLabel(LabelRef(id: other.id, lastKnownName: other.name))]
        fixed.enabled = true
        try await store.saveRule(fixed)
        let saved = try #require(try await store.rules().first)
        #expect(saved.state == .ok && saved.rule.enabled && saved.rule.revision == 2)
    }

    @Test func gmailDeletingATargetLabelTurnsItsRulesOff() async throws {
        let store = try await seededStore()
        let work = try #require(try await store.labels().first { $0.id == "Label_1" })
        let rule = try await store.createRule(Rule(key: "", name: "Work", then: [.addLabel(LabelRef(id: work.id, lastKnownName: work.name))]))
        try await store.replaceProviderLabels([
            MailLabel(id: "INBOX", name: "INBOX", kind: .system),
            MailLabel(id: "SENT", name: "SENT", kind: .system),
        ])
        let record = try #require(try await store.rules().first)
        #expect(record.state == .labelMissing && !record.rule.enabled)
        // The label is not recreated.
        #expect(!(try await store.labels().contains { $0.id == work.id }))
        await #expect(throws: RuleStoreError.labelMissing) { try await store.setRuleEnabled(id: rule.id, true) }

        // Renaming in Gmail keeps the ID, and the rule.
        try await store.replaceProviderLabels([MailLabel(id: "Label_2", name: "Deploys", kind: .user)])
        let deploys = try await store.createRule(Rule(key: "", name: "Deploys", then: [.addLabel(LabelRef(id: "Label_2", lastKnownName: "Deploys"))]))
        try await store.replaceProviderLabels([MailLabel(id: "Label_2", name: "Deployments", kind: .user)])
        #expect(try await store.rules().first { $0.id == deploys.id }?.state == .ok)
    }

    @Test func remappingALabelRewritesRulesLedgerAndMarks() async throws {
        let store = try await seededStore()
        let pending = try await store.createLabel(name: "clients", kind: .user, colorIndex: nil)
        var rule = try await store.createRule(Rule(key: "", name: "Clients", then: [.addLabel(LabelRef(id: pending.id, lastKnownName: "clients"))])).rule
        rule.when = "from:lumen"
        rule = try await store.saveRule(rule)
        try addRuleWork(store, messageID: "m1", ruleID: rule.id, labelID: pending.id)

        try await store.remapLabel(from: pending.id, to: MailLabel(id: "Label_9", name: "Clients", kind: .user))
        let record = try #require(try await store.rules().first)
        #expect(record.rule.labelTargets == [LabelRef(id: "Label_9", lastKnownName: "Clients")])
        #expect(record.rule.revision == 2)
        let revisions = try store.readNow { db in
            try db.query("SELECT payload FROM rule_revisions") { try JSONDecoder().decode(Rule.self, from: Data($0.string(0).utf8)).labelTargets.map(\.id) }
        }
        #expect(revisions == [["Label_9"], ["Label_9"]])
        let targets = try store.readNow { db in
            (try db.query("SELECT target FROM rule_ledger") { $0.string(0) }, try db.query("SELECT label_id FROM label_marks") { $0.string(0) })
        }
        #expect(targets.0 == ["Label_9"] && targets.1 == ["Label_9"])
        #expect(try await store.setRuleEnabled(id: rule.id, false) == nil)
        #expect(try await store.setRuleEnabled(id: rule.id, true) != nil)
    }

    // MARK: - Background reader

    @Test func backgroundReaderSeesCommittedWrites() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([message("m9", thread: "t9", subject: "Fresh", minutesAgo: 0)])
        #expect(try await store.readBackground { db in try db.scalar("SELECT COUNT(*) FROM messages WHERE id = 'm9'") } == 1)
    }

    @Test func backgroundReadsDoNotBlockTheReader() async throws {
        let store = try await seededStore()
        let (started, starting) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let background = Task {
            try await store.readBackground { db -> Bool in
                starting.yield()
                // Released by the test only after the UI reader answered.
                let released = release.wait(timeout: .now() + 5) == .success
                _ = try db.scalar("SELECT COUNT(*) FROM messages")
                return released
            }
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        #expect(try await store.read { db in try db.scalar("SELECT COUNT(*) FROM messages") } == 4)
        release.signal()
        #expect(try await background.value)
    }

    // MARK: - Deletes and resets

    @Test func deletingAMessageDeletesItsRuleWork() async throws {
        let store = try await seededStore()
        let rule = try await addRule(store)
        let label = rule.rule.labelTargets[0].id
        try addRuleWork(store, messageID: "m3", ruleID: rule.id, labelID: label)
        try addRuleWork(store, messageID: "m1", ruleID: rule.id, labelID: label)

        try await store.deleteMessages(["m3"])
        let gone = try rowCounts(store, messageID: "m3")
        for table in ["rule_queue", "rule_decisions", "rule_ledger", "label_marks", "rule_examples", "verdicts"] {
            #expect(gone[table] == 0, "\(table)")
        }
        let kept = try rowCounts(store, messageID: "m1")
        for table in ["rule_queue", "rule_decisions", "rule_ledger", "label_marks", "rule_examples", "verdicts"] {
            #expect(kept[table] == 1, "\(table)")
        }
    }

    @Test func resetKeepsRulesAndWhatTheyLearned() async throws {
        let store = try await seededStore()
        let receipts = try await store.createLabel(name: "receipts", kind: .local, colorIndex: 5)
        _ = try await store.createLabel(name: "unused", kind: .local, colorIndex: 1)
        let rule = try await store.createRule(Rule(key: "", name: "Receipts", then: [.addLabel(LabelRef(id: receipts.id, lastKnownName: "receipts"))]))
        let off = try await addRule(store, name: "Travel", enabled: false)
        try addRuleWork(store, messageID: "m3", ruleID: rule.id, labelID: receipts.id)
        try await store.setMeta("rules_next_key", "7")

        try await store.resetMailData()
        let counts = try rowCounts(store)
        for table in ["rule_queue", "rule_decisions", "rule_ledger", "label_marks", "rule_runs"] {
            #expect(counts[table] == 0, "\(table)")
        }
        #expect(counts["rules"] == 2 && counts["rule_revisions"] == 2)
        #expect(counts["rule_examples"] == 1 && counts["rule_overrides"] == 1 && counts["verdicts"] == 1)
        let labels = try await store.labels()
        #expect(labels.contains(receipts))
        #expect(labels.contains { $0.id == off.rule.labelTargets[0].id })
        #expect(!labels.contains { $0.name == "unused" })
        #expect(!labels.contains { $0.kind != .local })
        #expect(try await store.rules().map(\.state) == [.ok, .ok])
        #expect(try await store.meta("rules_next_key") == "7")

        try await store.resetMailData(everything: true)
        #expect(try rowCounts(store).values.allSatisfy { $0 == 0 })
        #expect(try await store.labels().isEmpty)
    }

    @Test func gmailDeletingATargetLabelDuringAResetTurnsItsRuleOff() async throws {
        let store = try await seededStore()
        try await store.upsertLabel(MailLabel(id: "Label_2", name: "travel", kind: .user, colorIndex: 4))
        let work = try await store.createRule(Rule(key: "", name: "Work", then: [.addLabel(LabelRef(id: "Label_1", lastKnownName: "work"))]))
        let travel = try await store.createRule(Rule(key: "", name: "Travel", then: [.addLabel(LabelRef(id: "Label_2", lastKnownName: "travel"))]))

        try await store.resetMailData()
        #expect(Set(try await store.labels().map(\.id)) == ["Label_1", "Label_2"])
        // The sync after the reset: Gmail no longer has Label_1.
        try await store.replaceProviderLabels([MailLabel(id: "INBOX", name: "INBOX", kind: .system), MailLabel(id: "Label_2", name: "travel", kind: .user)])
        let records = try await store.rules()
        let off = try #require(records.first { $0.id == work.id })
        #expect(off.state == .labelMissing && !off.rule.enabled)
        let on = try #require(records.first { $0.id == travel.id })
        #expect(on.state == .ok && on.rule.enabled)
        #expect(try await store.labels().first { $0.id == "Label_2" }?.colorIndex == 4)
    }

    // MARK: - Aliases

    @Test func aliasesAreSelfAddresses() async throws {
        let store = try await seededStore()
        try await store.setAccount(AccountProfile(email: me.email, displayName: "Sam Carter", historyCursor: "1", aliases: ["Sam@Alias.CO", "hello@studionorth.co"]))
        #expect(store.selfAddresses == [me.email, "sam@alias.co", "hello@studionorth.co"])
        #expect(try MailStore(url: store.url).selfAddresses == store.selfAddresses)

        try await store.resetMailData()
        #expect(store.selfAddresses.isEmpty)
        #expect(try await store.meta("account_aliases") == nil)
    }
}
