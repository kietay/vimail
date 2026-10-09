import Foundation
import Testing
@testable import DummyProvider
@testable import MailCore
@testable import MailRules
@testable import MailStore
@testable import MailSync

let me = EmailAddress(name: "Sam", email: "sam@hey.com")
let ana = EmailAddress(name: "Ana Ruiz", email: "ana@studio.co")
let stripe = EmailAddress(name: "Figma via Stripe", email: "receipts@stripe.com")
let apple = EmailAddress(name: "Apple", email: "no_reply@apple.com")
let shop = EmailAddress(name: "Allbirds", email: "hello@allbirds.com")

/// Haiku 5.5's prices: a call is priced at 130 micro-dollars before there are calls.
let testConfig = RuleEngine.JudgeConfig(model: "claude-haiku-5-5", effort: "low", promptVersion: 1, prices: TokenPrices(input: 0.10, cacheRead: 0.01, output: 0.50))

/// A clock tests move by hand. Sleepers wake when it passes their deadline.
final class TestClock: RuleClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = [:]

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        let due: [CheckedContinuation<Void, any Error>] = lock.withLock {
            current = current.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for id in ready.keys { sleepers[id] = nil }
            return ready.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready = lock.withLock {
                    if deadline <= current { return true }
                    sleepers[id] = (deadline, continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// A judge that answers as told and records each call.
final class FakeJudge: RuleJudge, @unchecked Sendable {
    struct Call: Sendable {
        var lane: SpendLane
        var messageID: String
        var subject: String
        var evaluate: [String]
        var catalog: [JudgeRule]
        var examples: [JudgeExample]
    }

    private let lock = NSLock()
    private var log: [Call] = []
    /// Rule key → words: the rule matches an email whose subject contains one (any case).
    private var matching: [String: [String]]
    /// Message ID → rule key → verdict, before `matching`.
    private var verdicts: [String: [String: Verdict]] = [:]
    /// Errors for a message's calls, in order.
    private var errors: [String: [JudgeError]] = [:]
    /// Thrown by every call of a lane: "live", "run" or "preview".
    private var laneErrors: [String: JudgeError] = [:]
    /// Thrown by calls after the first `after`.
    private var laterError: (after: Int, error: JudgeError)?
    /// Rule keys left out of every answer.
    private var omitted: Set<String> = []
    private var holding = false
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    let costMicros: Int64

    init(matching: [String: [String]] = [:], costMicros: Int64 = 1_000) {
        self.matching = matching
        self.costMicros = costMicros
    }

    var calls: [Call] { lock.withLock { log } }

    /// Calls in progress: started and held.
    var waiting: Int { lock.withLock { held.count } }

    func set(_ verdict: Verdict, for messageID: String, rule key: String) {
        lock.withLock { verdicts[messageID, default: [:]][key] = verdict }
    }

    func fail(_ messageID: String, with errors: JudgeError...) {
        lock.withLock { self.errors[messageID, default: []] += errors }
    }

    func failLane(_ lane: String, with error: JudgeError?) {
        lock.withLock { laneErrors[lane] = error }
    }

    func fail(after count: Int, with error: JudgeError) {
        lock.withLock { laterError = (count, error) }
    }

    func omit(_ key: String) {
        lock.withLock { _ = omitted.insert(key) }
    }

    /// Calls wait until `release()` (or until cancelled, then fail as offline).
    func hold() {
        lock.withLock { holding = true }
    }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            holding = false
            defer { held = [:] }
            return Array(held.values)
        }
        for continuation in waiting { continuation.resume() }
    }

    func judge(_ request: JudgeRequest) async throws(JudgeError) -> JudgeResponse {
        let number: Int = lock.withLock {
            log.append(Call(
                lane: request.lane, messageID: request.email.messageID, subject: request.email.subject, evaluate: request.evaluate,
                catalog: request.catalog, examples: request.examples
            ))
            return log.count
        }
        if lock.withLock({ holding }) {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let wait = lock.withLock {
                        guard holding else { return false }
                        held[id] = continuation
                        return true
                    }
                    if !wait { continuation.resume() }
                }
            } onCancel: {
                let continuation = lock.withLock { held.removeValue(forKey: id) }
                continuation?.resume()
            }
        }
        if Task.isCancelled { throw .offline }
        let laneKey = switch request.lane {
        case .live: "live"
        case .run: "run"
        case .preview: "preview"
        }
        let (error, decisions): (JudgeError?, [String: JudgeResponse.Decision]) = lock.withLock {
            if var queued = errors[request.email.messageID], !queued.isEmpty {
                let error = queued.removeFirst()
                errors[request.email.messageID] = queued
                return (error, [:])
            }
            if let error = laneErrors[laneKey] { return (error, [:]) }
            if let later = laterError, number > later.after { return (later.error, [:]) }
            var decisions: [String: JudgeResponse.Decision] = [:]
            for key in request.evaluate where !omitted.contains(key) {
                let subject = request.email.subject.lowercased()
                let verdict = verdicts[request.email.messageID]?[key]
                    ?? ((matching[key] ?? []).contains { subject.contains($0.lowercased()) } ? .match : .noMatch)
                decisions[key] = JudgeResponse.Decision(verdict: verdict, reason: "fake: \(verdict.rawValue)")
            }
            return (nil, decisions)
        }
        if let error { throw error }
        return JudgeResponse(decisions: decisions, model: "claude-haiku-5-5", servedBy: "claude-haiku-5-5", costMicros: costMicros, usage: TokenUsage(input: 100, output: 20))
    }
}

/// Counts calls from another task.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() {
        lock.withLock { value += 1 }
    }
}

/// A rule to create in the harness: its label is found or made by name.
struct RuleSpec {
    var name: String
    var label: String
    var when = ""
    var ask: String?
    var stopAfterMatch = false
    var inheritInThread = false
    var editsTeach = true
    var acknowledgedBroad = false
}

/// An account with a store, the dummy provider, sync, and the rules engine attached to sync, with
/// a fake judge and a clock moved by hand.
struct Harness {
    let directory: URL
    let provider: DummyMailProvider
    let store: MailStore
    let sync: SyncEngine
    let actions: MailActions
    let judge: FakeJudge?
    let clock: TestClock
    let engine: RuleEngine
    /// How often the engine asked sync to push the outbox.
    let syncWakes = Counter()

    /// - Parameters:
    ///   - rules: created in order, so their keys are "r1", "r2"…
    ///   - account: set up the account and system labels without syncing.
    init(
        rules: [RuleSpec] = [], judge: FakeJudge? = FakeJudge(), config: RuleEngine.JudgeConfig = testConfig, account: Bool = true,
        initialSyncLimit: Int = 300, runMessageLimit: Int? = nil, spend: SpendFigures? = nil
    ) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-rules-\(UUID().uuidString)")
        var configuration = DummyMailProvider.Configuration()
        configuration.latency = 0...0
        configuration.simulateIncomingMail = false
        configuration.simulateReplies = false
        provider = DummyMailProvider(directory: directory.appendingPathComponent("dummy"), configuration: configuration)
        store = try MailStore(url: directory.appendingPathComponent("mail.sqlite"))
        sync = SyncEngine(provider: provider, store: store, initialSyncLimit: initialSyncLimit)
        let sync = sync
        actions = MailActions(store: store, outboxChanged: { sync.wake() })
        self.judge = judge
        clock = TestClock()
        let wakes = syncWakes
        let figures: (@Sendable () async -> SpendFigures?)? = spend.map { figures in { @Sendable in figures } }
        engine = RuleEngine(
            store: store, judge: judge, config: config, clock: clock, simulatedSync: false, runMessageLimit: runMessageLimit,
            spend: figures, outboxChanged: { wakes.increment() }
        )
        await sync.attach(actions: actions, rules: engine)
        if account {
            try await store.setAccount(AccountProfile(email: me.email, displayName: me.name!, historyCursor: "1"))
            try await store.replaceProviderLabels(["INBOX", "UNREAD", "SENT", "DRAFT", "SPAM", "TRASH"].map { MailLabel(id: $0, name: $0, kind: .system) } + [
                MailLabel(id: "Label_1", name: "work", kind: .user),
            ])
        }
        for spec in rules { try await addRule(spec) }
    }

    /// Another engine on the same store: the app after a relaunch.
    func restart(judge: (any RuleJudge)?) -> RuleEngine {
        RuleEngine(store: store, judge: judge, config: testConfig, clock: clock, simulatedSync: false, outboxChanged: {})
    }

    @discardableResult
    func addRule(_ spec: RuleSpec) async throws -> RuleRecord {
        let label = try await store.resolveLabel(name: spec.label)
        var rule = Rule(
            key: "", name: spec.name, when: spec.when, ask: spec.ask, then: [.addLabel(LabelRef(id: label.id, lastKnownName: label.name))],
            scope: RuleScope(inheritInThread: spec.inheritInThread), stopAfterMatch: spec.stopAfterMatch
        )
        rule.editsTeach = spec.editsTeach
        rule.acknowledgedBroad = spec.acknowledgedBroad
        let record = try await store.createRule(rule)
        try await engine.rulesChanged(.created(ruleID: record.id))
        return record
    }

    func rule(_ name: String) async throws -> Rule {
        try #require(try await store.rules().first { $0.rule.name == name }).rule
    }

    func labelID(_ name: String) async throws -> String {
        try #require(try await store.labels().first { $0.name == name }).id
    }

    /// Stores arriving mail and queues it for rules, as sync does after a history pull.
    @discardableResult
    func deliver(_ messages: MailMessage...) async throws -> [String] {
        try await deliver(messages)
    }

    @discardableResult
    func deliver(_ messages: [MailMessage]) async throws -> [String] {
        try await store.applyRemoteChanges(ChangeSet(cursor: "", upserted: messages), intake: .live(arrived: Set(messages.map(\.id))))
    }

    func labels(_ messageID: String) async throws -> Set<String> {
        try #require(try await store.message(id: messageID)).labelIDs
    }

    func hasLabel(_ messageID: String, _ name: String) async throws -> Bool {
        try await labels(messageID).contains(try await labelID(name))
    }

    /// Queue rows: message, state, attempts, run kind.
    func queue() throws -> [(messageID: String, state: String, attempts: Int, notBefore: Date, kind: String)] {
        try store.readNow { db in
            try db.query(
                "SELECT q.message_id, q.state, q.attempts, q.not_before, r.kind FROM rule_queue q JOIN rule_runs r ON r.id = q.run_id ORDER BY q.message_id"
            ) { ($0.string(0), $0.string(1), $0.int(2), $0.date(3), $0.string(4)) }
        }
    }

    func decision(_ messageID: String, _ rule: Rule) async throws -> RuleDecision? {
        try await store.decisions(for: [messageID])[messageID]?[rule.id]?.decision
    }

    func calls() -> [FakeJudge.Call] { judge?.calls ?? [] }
}

/// A received message (or one from `from`), dated `minutesAgo` before now.
func mail(
    _ id: String, thread: String? = nil, from: EmailAddress = ana, to: [EmailAddress] = [me], subject: String, body: String = "Hello there",
    minutesAgo: Double = 1, labels: Set<String> = ["INBOX", "UNREAD"], date: Date? = nil
) -> MailMessage {
    MailMessage(
        id: id, threadID: thread ?? id, labelIDs: labels, from: from, to: to, subject: subject, snippet: String(body.prefix(100)),
        date: date ?? Date().addingTimeInterval(-minutesAgo * 60), textBody: body
    )
}

/// Waits until `condition` holds, or fails after a few seconds.
func eventually(_ what: Comment, timeout: TimeInterval = 5, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while try await !condition() {
        guard Date() < deadline else {
            Issue.record("Timed out waiting: \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Collects a preview stream: its rows in order, and how it ended.
func collect(_ stream: AsyncThrowingStream<PreviewRow, Error>) async -> (rows: [PreviewRow], error: (any Error)?) {
    var rows: [PreviewRow] = []
    do {
        for try await row in stream { rows.append(row) }
        return (rows, nil)
    } catch {
        return (rows, error)
    }
}

/// The last row for each message, in first-seen order.
func latest(_ rows: [PreviewRow]) -> [PreviewRow] {
    var order: [String] = []
    var last: [String: PreviewRow] = [:]
    for row in rows {
        if last[row.messageID] == nil { order.append(row.messageID) }
        last[row.messageID] = row
    }
    return order.compactMap { last[$0] }
}
