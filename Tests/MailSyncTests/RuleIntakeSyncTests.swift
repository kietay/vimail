import Foundation
import Testing
@testable import DummyProvider
@testable import MailCore
@testable import MailStore
@testable import MailSync

/// Counts committed store writes.
final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() {
        lock.withLock { value += 1 }
    }
}

extension Harness {
    /// An enabled rule that labels all received mail with a new local label.
    @discardableResult
    func addRule() async throws -> RuleRecord {
        let label = try await store.resolveLabel(name: "everything")
        return try await store.createRule(Rule(key: "", name: "Everything", then: [.addLabel(LabelRef(id: label.id, lastKnownName: label.name))]))
    }

    func syncUntilCached() async throws {
        repeat {
            #expect(await engine.cycle())
        } while try await store.meta("backfill_done") == nil
    }

    /// Queued message IDs with their run's kind.
    func queued() throws -> [(messageID: String, kind: String)] {
        try store.readNow { db in
            try db.query("SELECT q.message_id, r.kind FROM rule_queue q JOIN rule_runs r ON r.id = q.run_id") { ($0.string(0), $0.string(1)) }
        }
    }
}

@Suite("Sync queues arriving mail for rules", .serialized)
struct RuleIntakeSyncTests {
    @Test func onlyArrivingMailIsQueued() async throws {
        let harness = try await Harness()
        try await harness.addRule()
        // The first sync and the background download store old mail: never queued.
        try await harness.syncUntilCached()
        #expect(try harness.queued().isEmpty)
        #expect(harness.rules.wakes == 0)

        try await harness.provider.deliverIncomingMail(count: 3)
        #expect(await harness.engine.cycle())
        let queued = try harness.queued()
        #expect(!queued.isEmpty)
        #expect(queued.allSatisfy { $0.kind == "live" })
        for row in queued {
            let message = try #require(try await harness.store.message(id: row.messageID))
            #expect(!harness.store.selfAddresses.contains(message.from.normalized))
            #expect(message.labelIDs.isDisjoint(with: ["SENT", "DRAFT", "SPAM", "TRASH"]))
        }
        #expect(harness.rules.wakes == 1)
        #expect(try await harness.store.meta("cursor") == (try await harness.provider.profile().historyCursor))
    }

    @Test func resyncQueuesMailThatArrivedSinceRulesLastRan() async throws {
        let harness = try await Harness()
        try await harness.syncUntilCached()
        try await harness.addRule()
        let hourAgo = Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        try await harness.store.setMeta("rules_live_watermark", String(hourAgo))
        try await harness.provider.deliverIncomingMail(count: 2)
        // Offline too long: the history cursor expired and everything downloads again.
        try await harness.store.setMeta("cursor", "expired")

        try await harness.syncUntilCached()
        let queued = try harness.queued()
        #expect(!queued.isEmpty)
        #expect(queued.allSatisfy { $0.kind == "live" })
        for row in queued {
            let message = try #require(try await harness.store.message(id: row.messageID))
            #expect(message.date.timeIntervalSince1970 * 1000 >= Double(hourAgo))
        }
        #expect(harness.rules.wakes >= 1)
        #expect(try await harness.store.meta("resync") == nil)
        #expect(try await harness.store.meta("rules_resync") == nil)
    }

    @Test func aliasesAreFetchedForAccountsSyncedBeforeThem() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.meta("account_aliases") == "[]")
        try await harness.store.setMeta("account_aliases", nil)
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.meta("account_aliases") == "[]")
    }

    @Test func stopWaitsForTheRunningCycle() async throws {
        let harness = try await Harness()
        let writes = WriteCounter()
        harness.store.observe { _ in writes.increment() }
        await harness.engine.start()
        // Stop in the middle of the first sync.
        let deadline = Date().addingTimeInterval(5)
        while writes.count == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(writes.count > 0)
        await harness.engine.stop()

        let stopped = writes.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(writes.count == stopped)
        // The cycle it waited for wanted the app kept awake; a closed account no longer does.
        #expect(await harness.engine.activityReason == nil)
        // The streams have ended.
        for await _ in harness.engine.statusUpdates {}
        for await _ in harness.engine.events {}
    }
}
