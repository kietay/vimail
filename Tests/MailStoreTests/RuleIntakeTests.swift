import Foundation
import Testing
@testable import MailCore
@testable import MailStore

/// Adds an enabled rule that labels everything "receipts" (a new local label).
@discardableResult
func addRule(_ store: MailStore, name: String = "Receipts", when: String = "", enabled: Bool = true) async throws -> RuleRecord {
    let label = try await store.resolveLabel(name: name.lowercased())
    return try await store.createRule(Rule(key: "", name: name, enabled: enabled, when: when, then: [.addLabel(LabelRef(id: label.id, lastKnownName: label.name))]))
}

struct QueueRow: Hashable {
    var messageID: String
    var runID: Int64
    var priority: Int
    var state: String
}

func queueRows(_ store: MailStore) throws -> Set<QueueRow> {
    try store.readNow { db in
        Set(try db.query("SELECT message_id, run_id, priority, state FROM rule_queue") {
            QueueRow(messageID: $0.string(0), runID: $0.int64(1), priority: $0.int(2), state: $0.string(3))
        })
    }
}

struct RunRow {
    var id: Int64
    var kind: String
    var day: String?
    var rules: [RunRule]
    var state: String
    var total: Int
}

func runRows(_ store: MailStore) throws -> [RunRow] {
    try store.readNow { db in
        try db.query("SELECT id, kind, day, rules, state, total FROM rule_runs ORDER BY id") {
            RunRow(
                id: $0.int64(0), kind: $0.string(1), day: $0.optionalString(2),
                rules: try JSONDecoder().decode([RunRule].self, from: Data($0.string(3).utf8)), state: $0.string(4), total: $0.int(5)
            )
        }
    }
}

@Suite("Rule intake")
struct RuleIntakeTests {
    /// Newly arrived mail of every kind, plus a reply-context message that did not arrive now.
    func arrivals() -> [MailMessage] {
        [
            message("n1", thread: "n1", from: nina, subject: "Your receipt", labels: ["INBOX", "UNREAD"], minutesAgo: 1),
            message("n2", thread: "n2", from: alex, subject: "Archived by a Gmail filter", labels: [], minutesAgo: 2),
            message("n3", thread: "n3", from: me, to: [nina], subject: "Sent from here", labels: ["SENT"], minutesAgo: 3),
            message("n4", thread: "n4", from: EmailAddress(email: "sam@alias.co"), to: [nina], subject: "Sent from an alias", labels: ["INBOX"], minutesAgo: 3),
            message("n5", thread: "n5", from: alex, subject: "Prize", labels: ["SPAM"], minutesAgo: 4),
            message("n6", thread: "n6", from: alex, subject: "Old", labels: ["TRASH"], minutesAgo: 4),
            message("n7", thread: "n7", from: me, subject: "Draft", labels: ["DRAFT"], minutesAgo: 4),
            message("c1", thread: "n1", from: alex, subject: "Earlier in the conversation", labels: [], minutesAgo: 600),
        ]
    }

    func aliasStore() async throws -> MailStore {
        let store = try await seededStore()
        try await store.setAccount(AccountProfile(email: me.email, displayName: "Sam Carter", historyCursor: "1", aliases: ["sam@alias.co"]))
        return store
    }

    @Test func liveIntakeQueuesArrivedReceivedMailWithTheCursor() async throws {
        let store = try await aliasStore()
        let rule = try await addRule(store)
        let messages = arrivals()
        let arrived = Set(messages.map(\.id)).subtracting(["c1"]).union(["m3"])
        // m3 is already stored: arriving again does not queue it.
        let inserted = try await store.applyRemoteChanges(
            ChangeSet(cursor: "9", upserted: messages + [message("m3", thread: "t2", from: nina, labels: ["INBOX"], minutesAgo: 5)]),
            cursor: "9", intake: .live(arrived: arrived)
        )
        #expect(Set(inserted) == Set(messages.map(\.id)))
        #expect(try await store.meta("cursor") == "9")

        let runs = try runRows(store)
        let live = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(live.kind == "live")
        #expect(live.day == MailStore.liveDay(Date()))
        #expect(live.rules == [RunRule(id: rule.id, revision: 1)])
        #expect(live.state == "running")
        #expect(live.total == 2)
        #expect(try queueRows(store) == [
            QueueRow(messageID: "n1", runID: live.id, priority: 0, state: "queued"),
            QueueRow(messageID: "n2", runID: live.id, priority: 0, state: "queued"),
        ])

        // Later arrivals the same day join the same run.
        _ = try await store.applyRemoteChanges(ChangeSet(cursor: "10", upserted: [message("n8", thread: "n8", from: nina, minutesAgo: 0)]), cursor: "10", intake: .live(arrived: ["n8"]))
        #expect(try runRows(store).map(\.total) == [3])
        #expect(try queueRows(store).count == 3)
    }

    @Test func noQueueWithoutARuleThatCanRun() async throws {
        let store = try await aliasStore()
        try await addRule(store, enabled: false)
        // A rule from a newer build is kept but cannot run.
        try store.writeNow { db, _ in
            try db.run(
                "INSERT INTO rules(id, key, position, enabled, revision, payload, created_at, updated_at) VALUES ('r_new', 'r9', 5, 1, 1, ?, 0, 0)",
                [#"{"id":"r_new","key":"r9","enabled":true,"then":[{"type":"forward","to":"x@y.z"}]}"#]
            )
        }
        let inserted = try await store.applyRemoteChanges(ChangeSet(cursor: "3", upserted: arrivals()), cursor: "3", intake: .live(arrived: Set(arrivals().map(\.id))))
        #expect(inserted.count == arrivals().count)
        #expect(try queueRows(store).isEmpty)
        #expect(try runRows(store).isEmpty)
        #expect(try await store.meta("cursor") == "3")
    }

    @Test func otherIntakesQueueNothing() async throws {
        let store = try await aliasStore()
        try await addRule(store)
        _ = try await store.applyRemoteChanges(ChangeSet(cursor: "", upserted: arrivals()))
        try await store.upsertMessages([message("n9", thread: "n9", from: nina, minutesAgo: 1)])
        #expect(try queueRows(store).isEmpty)
        // A download leaves the history cursor alone.
        #expect(try await store.meta("cursor") == nil)
    }

    @Test(arguments: ["rule_queue", "cursor"])
    func intakeIsAtomic(_ failingWrite: String) async throws {
        let store = try await aliasStore()
        try await addRule(store)
        try await store.setMeta("cursor", "1")
        try store.writeNow { db, _ in
            if failingWrite == "rule_queue" {
                try db.execute("CREATE TRIGGER fail BEFORE INSERT ON rule_queue BEGIN SELECT RAISE(ABORT, 'injected'); END")
            } else {
                try db.execute("CREATE TRIGGER fail BEFORE UPDATE ON meta WHEN NEW.key = 'cursor' BEGIN SELECT RAISE(ABORT, 'injected'); END")
            }
        }
        await #expect(throws: SQLiteError.self) {
            try await store.applyRemoteChanges(ChangeSet(cursor: "2", upserted: arrivals()), cursor: "2", intake: .live(arrived: ["n1", "n2"]))
        }
        #expect(try await store.message(id: "n1") == nil)
        #expect(try await store.meta("cursor") == "1")
        #expect(try queueRows(store).isEmpty)
        #expect(try runRows(store).isEmpty)
    }

    @Test func resyncQueuesNewestLiveAndHoldsTheRest() async throws {
        let store = try await aliasStore()
        let rule = try await addRule(store)
        let watermark = Date().addingTimeInterval(-3 * 86_400)
        try await store.setMeta("rules_live_watermark", String(Int64(watermark.timeIntervalSince1970 * 1000)))
        // 650 received messages since the watermark, newest first in each batch, plus older mail and mail you sent.
        let fresh = (0..<650).map { message("r\($0)", thread: "r\($0)", from: nina, minutesAgo: Double($0 + 1)) }
        let old = (0..<5).map { message("o\($0)", thread: "o\($0)", from: nina, minutesAgo: 5 * 1440) }
        let sent = message("s0", thread: "s0", from: me, to: [nina], labels: ["SENT"], minutesAgo: 1)

        _ = try await store.applyRemoteChanges(ChangeSet(cursor: "", upserted: Array(fresh[..<300]) + old + [sent]), intake: .resync)
        // Live processing moves the watermark meanwhile; the resync keeps the one it started from.
        try await store.setMeta("rules_live_watermark", String(Int64(Date().timeIntervalSince1970 * 1000)))
        _ = try await store.applyRemoteChanges(ChangeSet(cursor: "", upserted: Array(fresh[300...])), intake: .resync)

        let runs = try runRows(store)
        #expect(runs.map(\.kind) == ["live", "backlog"])
        #expect(runs.map(\.state) == ["running", "awaiting_confirm"])
        #expect(runs.map(\.total) == [500, 150])
        #expect(runs.allSatisfy { $0.rules == [RunRule(id: rule.id, revision: 1)] })
        let rows = try queueRows(store)
        let live = rows.filter { $0.runID == runs[0].id }
        let held = rows.filter { $0.runID == runs[1].id }
        #expect(live.allSatisfy { $0.state == "queued" && $0.priority == 0 })
        #expect(held.allSatisfy { $0.state == "held" && $0.priority == 2 })
        #expect(Set(live.map(\.messageID)) == Set(fresh[..<500].map(\.id)))
        #expect(Set(held.map(\.messageID)) == Set(fresh[500...].map(\.id)))

        try await store.endResync()
        #expect(try await store.meta("rules_resync") == nil)
    }

    @Test func resyncQueuesNothingBeforeRulesProcessedLiveMail() async throws {
        let store = try await aliasStore()
        try await addRule(store)
        _ = try await store.applyRemoteChanges(ChangeSet(cursor: "", upserted: arrivals()), intake: .resync)
        // Rules start processing live mail during the resync: the resync still queues nothing.
        try await store.setMeta("rules_live_watermark", "0")
        _ = try await store.applyRemoteChanges(ChangeSet(cursor: "", upserted: [message("n9", thread: "n9", from: nina, minutesAgo: 1)]), intake: .resync)
        #expect(try queueRows(store).isEmpty)
    }
}
