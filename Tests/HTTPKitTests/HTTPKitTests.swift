import Foundation
import Testing
@testable import HTTPKit

@Suite("Priority slots")
struct PrioritySlotsTests {
    @Test func limitsRequestsInFlight() async {
        let slots = PrioritySlots(limit: 2)
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await slots.enter()
                    peak.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    peak.leave()
                    await slots.leave()
                }
            }
        }
        #expect(peak.highest == 2)
        #expect(await slots.inFlight == 0)
    }

    @Test func interactiveWaitersGoBeforeBulkOnes() async {
        let slots = PrioritySlots(limit: 1)
        await slots.enter(priority: .bulk)
        let order = Order()
        // Bulk queues first; interactive arrives later but gets the slot first.
        let bulk = Task {
            await slots.enter(priority: .bulk)
            order.append("bulk")
            await slots.leave(priority: .bulk)
        }
        await waitUntil(slots, hasWaiting: 1)
        let interactive = Task {
            await slots.enter(priority: .interactive)
            order.append("interactive")
            await slots.leave(priority: .interactive)
        }
        await waitUntil(slots, hasWaiting: 2)
        #expect(order.items.isEmpty)
        await slots.leave(priority: .bulk)
        await bulk.value
        await interactive.value
        #expect(order.items == ["interactive", "bulk"])
    }

    @Test func bulkLimitKeepsSlotsForInteractiveWork() async {
        let slots = PrioritySlots(limit: 3, bulkLimit: 2)
        await slots.enter(priority: .bulk)
        await slots.enter(priority: .bulk)
        let started = Order()
        let thirdBulk = Task {
            await slots.enter(priority: .bulk)
            started.append("bulk")
        }
        // The third slot is free, but not for bulk work.
        await waitUntil(slots, hasWaiting: 1)
        #expect(started.items.isEmpty)
        await slots.enter(priority: .interactive)
        #expect(await slots.inFlight == 3)
        await slots.leave(priority: .bulk)
        await thirdBulk.value
        #expect(started.items == ["bulk"])
    }

    @Test func raisingTheLimitStartsWaitingRequests() async {
        let slots = PrioritySlots(limit: 1)
        await slots.enter()
        let started = Order()
        let waiting = (0..<2).map { _ in
            Task {
                await slots.enter()
                started.append("started")
            }
        }
        await waitUntil(slots, hasWaiting: 2)
        #expect(started.items.isEmpty)
        await slots.setLimit(3)
        for task in waiting { await task.value }
        #expect(started.items.count == 2)
        #expect(await slots.inFlight == 3)
        #expect(await slots.waiting == 0)
    }

    /// Waits until `count` requests are queued on `slots`.
    func waitUntil(_ slots: PrioritySlots, hasWaiting count: Int) async {
        while await slots.waiting < count { await Task.yield() }
    }
}

@Suite("Backoff")
struct BackoffTests {
    let backoff = Backoff(first: .seconds(5), factor: 2, maximum: .seconds(1800), jitter: 0.2)

    @Test func growsExponentiallyWithinTheJitter() {
        for attempt in 1...8 {
            let base = 5 * pow(2, Double(attempt - 1))
            for _ in 0..<50 {
                let delay = Backoff.seconds(backoff.delay(afterAttempt: attempt))
                #expect(delay >= base * 0.8 - 1e-9 && delay <= base * 1.2 + 1e-9)
            }
        }
    }

    @Test func isCappedEvenForHugeAttemptCounts() {
        for attempt in [10, 12, 64, 1_000, Int.max] {
            let delay = Backoff.seconds(backoff.delay(afterAttempt: attempt))
            #expect(delay >= 1800 * 0.8 - 1e-9 && delay <= 1800 * 1.2 + 1e-9)
        }
    }

    @Test func retryAfterIsNeverShortened() {
        for _ in 0..<50 {
            let delay = Backoff.seconds(backoff.delay(afterAttempt: 1, retryAfter: .seconds(42)))
            #expect(delay >= 42 && delay <= 42 * 1.2 + 1e-9)
        }
        // A server asking for hours still waits at most the cap (plus jitter).
        let capped = Backoff.seconds(backoff.delay(afterAttempt: 1, retryAfter: .seconds(86_400)))
        #expect(capped >= 1800 && capped <= 1800 * 1.2 + 1e-9)
    }

    @Test func withoutJitterTheDelayIsExact() {
        let exact = Backoff(first: .milliseconds(500), factor: 3, maximum: .seconds(10), jitter: 0)
        #expect(exact.delay(afterAttempt: 1) == .milliseconds(500))
        #expect(exact.delay(afterAttempt: 3) == .milliseconds(4500))
        #expect(exact.delay(afterAttempt: 4) == .seconds(10))
        #expect(exact.delay(afterAttempt: 0) == .milliseconds(500))
    }
}

@Suite("Private files")
struct PrivateFileTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-private-\(UUID().uuidString)")

    func mode(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func writesOwnerOnlyFilesInOwnerOnlyFolders() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("secrets/api-key")
        try PrivateFile.write(Data("sk-1".utf8), to: url)
        #expect(try mode(url) == 0o600)
        #expect(try mode(url.deletingLastPathComponent()) == 0o700)
        #expect(PrivateFile.read(url) == Data("sk-1".utf8))
    }

    @Test func replacingKeepsTheFilePrivateAndLeavesNoTemporaryFiles() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("api-key")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A file someone made readable by everyone.
        FileManager.default.createFile(atPath: url.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])
        try PrivateFile.write(Data("new".utf8), to: url)
        #expect(PrivateFile.read(url) == Data("new".utf8))
        #expect(try mode(url) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["api-key"])
    }

    @Test func readingAMissingFileIsNil() {
        #expect(PrivateFile.read(directory.appendingPathComponent("missing")) == nil)
    }
}

/// Highest number of concurrent holders seen.
final class Peak: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maximum = 0

    var highest: Int { lock.withLock { maximum } }

    func enter() {
        lock.withLock {
            current += 1
            maximum = max(maximum, current)
        }
    }

    func leave() {
        lock.withLock { current -= 1 }
    }
}

final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    var items: [String] { lock.withLock { list } }

    func append(_ item: String) {
        lock.withLock { list.append(item) }
    }
}
