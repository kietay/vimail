import Foundation
import Testing
@testable import DummyProvider
@testable import MailCore
@testable import MailStore
@testable import MailSync

/// Stands in for the rules engine: counts how often sync wakes it.
final class WakeRecorder: RuleWaking, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var wakes: Int { lock.withLock { count } }

    func wake() {
        lock.withLock { count += 1 }
    }
}

struct Harness {
    let directory: URL
    let provider: DummyMailProvider
    let store: MailStore
    let engine: SyncEngine
    let actions: MailActions
    let rules = WakeRecorder()

    init(failureRate: Double = 0) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-sync-\(UUID().uuidString)")
        var configuration = DummyMailProvider.Configuration()
        configuration.latency = 0...0
        configuration.failureRate = failureRate
        configuration.simulateIncomingMail = false
        configuration.simulateReplies = false
        provider = DummyMailProvider(directory: directory.appendingPathComponent("dummy"), configuration: configuration)
        store = try MailStore(url: directory.appendingPathComponent("mail.sqlite"))
        engine = SyncEngine(provider: provider, store: store, initialSyncLimit: 300)
        let engine = engine
        actions = MailActions(store: store, outboxChanged: { engine.wake() })
        await engine.attach(actions: actions, rules: rules)
    }

    func setFailureRate(_ rate: Double) async {
        var configuration = DummyMailProvider.Configuration()
        configuration.latency = 0...0
        configuration.failureRate = rate
        configuration.simulateIncomingMail = false
        configuration.simulateReplies = false
        await provider.configure(configuration)
    }
}

@Suite("Sync engine with the dummy provider", .serialized)
struct SyncEngineTests {
    @Test func initialSyncShowsTheDesignInbox() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())

        let inbox = try await harness.store.threads(.mailbox(.inbox))
        let subjects = inbox.prefix(6).map(\.subject)
        #expect(subjects.first == "A little direction for the next chapter")
        #expect(subjects.contains("Coffee on Thursday?"))
        #expect(inbox.first?.participants == "Alex Morgan")
        #expect(inbox.first?.isStarred == true)

        let labels = try await harness.store.labels()
        #expect(labels.contains { $0.name == "work" && $0.kind == .user })
        let account = try await harness.store.account()
        #expect(account?.email == "sam@hey.com")
    }

    @Test func archivePushesToProviderAndSurvivesResync() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let first = try #require(try await harness.store.threads(.mailbox(.inbox)).first)

        let undo = try await harness.actions.perform(.archive, threads: [first.id])
        #expect(undo != nil)
        #expect(try await harness.store.outboxCount() == 1)
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.outboxCount() == 0)

        // The provider now agrees.
        let remote = try await harness.provider.threads(ids: [first.id]).flatMap { $0 }
        #expect(remote.allSatisfy { !$0.labelIDs.contains("INBOX") })
        #expect(!(try await harness.store.threads(.mailbox(.inbox)).map(\.id).contains(first.id)))

        // Undo after the push sends the inverse.
        try await harness.actions.undo(try #require(undo))
        #expect(await harness.engine.cycle())
        let restored = try await harness.provider.threads(ids: [first.id]).flatMap { $0 }
        #expect(restored.contains { $0.labelIDs.contains("INBOX") })
        #expect(try await harness.store.threads(.mailbox(.inbox)).map(\.id).contains(first.id))
    }

    @Test func offlineActionsQueueAndRetry() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let thread = try #require(try await harness.store.threads(.mailbox(.inbox)).first { !$0.isStarred })

        await harness.setFailureRate(1)
        try await harness.actions.perform(.star, threads: [thread.id])
        #expect(await harness.engine.cycle() == false)
        // Still starred locally while offline.
        #expect(try await harness.store.threadSummary(id: thread.id)?.isStarred == true)
        let item = try #require(try await harness.store.outboxItems().first)
        #expect(item.attempts == 1)

        await harness.setFailureRate(0)
        // Make the retry due now.
        try await harness.store.retryOutboxItem(item.id, error: "test", retryAt: Date())
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.outboxCount() == 0)
        let remote = try await harness.provider.threads(ids: [thread.id]).flatMap { $0 }
        #expect(remote.contains { $0.labelIDs.contains("STARRED") })
    }

    @Test func sendReplacesOptimisticCopy() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let me = EmailAddress(name: "Sam Carter", email: "sam@hey.com")
        let nina = EmailAddress(name: "Nina Park", email: "nina.park@fastmail.com")
        let draft = Draft(to: [nina], subject: "Thursday works", body: "See you at 9!")
        let outgoing = OutgoingMessage(from: me, to: [nina], subject: draft.subject, textBody: draft.body, htmlBody: "<p>See you at 9!</p>")
        let local = MailMessage(id: "local-\(UUID().uuidString)", threadID: "local-thread", labelIDs: ["SENT"], from: me, to: [nina], subject: draft.subject, snippet: draft.body, date: Date(), textBody: draft.body)
        _ = try await harness.store.queueSend(draft: draft, message: outgoing, localCopy: local, notBefore: Date())

        #expect(await harness.engine.cycle())
        let sent = try await harness.store.threads(.mailbox(.sent))
        let top = try #require(sent.first)
        #expect(top.subject == "Thursday works")
        #expect(top.id != "local-thread")
        let thread = try #require(try await harness.store.thread(id: top.id))
        #expect(thread.messages.first?.htmlBody == "<p>See you at 9!</p>")
    }

    @Test func rejectedSendRestoresTheDraft() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let me = EmailAddress(name: "Sam Carter", email: "sam@hey.com")
        let bad = EmailAddress(email: "not-an-address")
        let draft = Draft(to: [bad], subject: "Oops", body: "Hello")
        let local = MailMessage(id: "local-x", threadID: "local-tx", labelIDs: ["SENT"], from: me, to: [bad], subject: "Oops", snippet: "Hello", date: Date(), textBody: "Hello")
        _ = try await harness.store.queueSend(draft: draft, message: OutgoingMessage(from: me, to: [bad], subject: "Oops", textBody: "Hello"), localCopy: local, notBefore: Date())

        #expect(await harness.engine.cycle())
        #expect(try await harness.store.drafts().map(\.subject) == ["Oops"])
        #expect(!(try await harness.store.threads(.mailbox(.sent)).map(\.id).contains("local-tx")))
    }

    @Test func incomingMailArrivesThroughHistory() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        // Count messages, not conversations: incoming mail is sometimes a reply in a conversation already in the inbox.
        let messages = { try await harness.store.read { db in try db.scalar("SELECT COUNT(*) FROM message_labels WHERE label_id = 'INBOX'") } }
        let before = try await messages()
        try await harness.provider.deliverIncomingMail(count: 2)
        #expect(await harness.engine.cycle())
        #expect(try await messages() == before + 2)
    }

    @Test func labelCreatedOfflineGetsRemapped() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let thread = try #require(try await harness.store.threads(.mailbox(.inbox)).first)
        let label = try await harness.actions.ensureLabel(named: "clients", kind: .user)
        #expect(label.id.hasPrefix("pending-"))
        try await harness.actions.perform(.addLabel(label.id), threads: [thread.id])

        #expect(await harness.engine.cycle())
        let labels = try await harness.store.labels()
        let synced = try #require(labels.first { $0.name == "clients" })
        #expect(synced.id.hasPrefix("Label_"))
        let remote = try await harness.provider.threads(ids: [thread.id]).flatMap { $0 }
        #expect(remote.allSatisfy { $0.labelIDs.contains(synced.id) })
    }

    @Test func onlyArrivingMailWakesRules() async throws {
        let harness = try await Harness()
        // The first sync and the background download store old mail: rules never see it implicitly.
        while try await harness.store.meta("backfill_done") == nil {
            #expect(await harness.engine.cycle())
        }
        #expect(harness.rules.wakes == 0)

        try await harness.provider.deliverIncomingMail(count: 2)
        #expect(await harness.engine.cycle())
        #expect(harness.rules.wakes == 1)

        // Nothing new: no wake.
        #expect(await harness.engine.cycle())
        #expect(harness.rules.wakes == 1)
    }

    @Test func snoozeWakesUpBackInInbox() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let thread = try #require(try await harness.store.threads(.mailbox(.inbox)).first)
        try await harness.actions.perform(.snooze(until: Date().addingTimeInterval(-1)), threads: [thread.id])
        #expect(!(try await harness.store.threads(.mailbox(.inbox)).map(\.id).contains(thread.id)))

        #expect(await harness.engine.cycle())
        let summary = try #require(try await harness.store.threadSummary(id: thread.id))
        #expect(summary.labelIDs.contains("INBOX"))
        #expect(summary.isUnread)
        #expect(summary.snoozedUntil == nil)
    }

    @Test func providerStatePersistsAcrossRestarts() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let thread = try #require(try await harness.store.threads(.mailbox(.inbox)).first)
        try await harness.actions.perform(.trash, threads: [thread.id])
        #expect(await harness.engine.cycle())
        await harness.provider.flush()

        var configuration = DummyMailProvider.Configuration()
        configuration.latency = 0...0
        configuration.simulateIncomingMail = false
        let reopened = DummyMailProvider(directory: harness.directory.appendingPathComponent("dummy"), configuration: configuration)
        let remote = try await reopened.threads(ids: [thread.id]).flatMap { $0 }
        #expect(remote.allSatisfy { $0.labelIDs.contains("TRASH") })
    }

    @Test func dummyNewslettersUnsubscribeInDifferentWays() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let inbox = try await harness.store.threads(.mailbox(.inbox))
        func method(_ subject: String) async throws -> UnsubscribeMethod? {
            let summary = try #require(inbox.first { $0.subject == subject })
            return try await harness.store.thread(id: summary.id)?.unsubscribeTarget(excluding: ["sam@hey.com"])?.method
        }
        #expect(try await method("Five things worth your time") == .oneClick(URL(string: "https://thebrowser.example/unsubscribe?u=sam")!))
        #expect(try await method("New connections in your channels") == .email(to: EmailAddress(email: "leave@are.na.example"), subject: "Unsubscribe", body: "Unsubscribe"))
        #expect(try await method("Coffee on Thursday?") == nil)
    }

    @Test func unsubscribeLeavesAfterTheUndoWindow() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let url = URL(string: "https://thebrowser.example/unsubscribe?u=sam")!
        let request = UnsubscribeRequest(method: .oneClick(url), list: "The Browser")
        let id = try await harness.store.enqueue(.unsubscribe(request), notBefore: Date().addingTimeInterval(60))
        #expect(await harness.engine.cycle())
        #expect(await harness.provider.oneClickUnsubscribes.isEmpty)
        // u within the window: nothing ever left.
        #expect(try await harness.store.cancelOutboxItems([id]) == [id])

        _ = try await harness.store.enqueue(.unsubscribe(request), notBefore: Date())
        #expect(await harness.engine.cycle())
        #expect(await harness.provider.oneClickUnsubscribes == [url])
        #expect(try await harness.store.outboxCount() == 0)
    }

    @Test func emailUnsubscribeIsSentButNotSuggested() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let me = EmailAddress(name: "Sam Carter", email: "sam@hey.com")
        let method = UnsubscribeMethod.email(to: EmailAddress(email: "leave@are.na.example"), subject: "unsubscribe", body: "Unsubscribe")
        let request = try #require(UnsubscribeRequest(method, list: "Are.na", from: me))
        _ = try await harness.store.enqueue(.unsubscribe(request), notBefore: Date())
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.threads(.mailbox(.sent)).first?.subject == "unsubscribe")
        // The next sync brings Gmail's copy; the list's address still stays out of compose suggestions.
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.contacts(matching: "leave").isEmpty)
    }

    @Test func refreshReadsWhatOlderCachesLack() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let summary = try #require(try await harness.store.threads(.mailbox(.inbox)).first { $0.subject == "Five things worth your time" })
        var cached = try #require(try await harness.store.thread(id: summary.id)?.messages.first)
        cached.oneClickUnsubscribe = nil
        try await harness.store.upsertMessages([cached])
        #expect(try await harness.store.message(id: cached.id)?.needsOneClickCheck == true)

        try await harness.engine.refresh(threadIDs: [summary.id])
        #expect(try await harness.store.message(id: cached.id)?.oneClickUnsubscribe == true)
    }

    @Test func aListServerThatIsDownDoesNotHoldUpMail() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let thread = try #require(try await harness.store.threads(.mailbox(.inbox)).first)
        let request = UnsubscribeRequest(method: .oneClick(URL(string: "https://down.example/u")!), list: "Down")
        _ = try await harness.store.enqueue(.unsubscribe(request), notBefore: Date())
        try await harness.actions.perform(.archive, threads: [thread.id])

        // The cycle succeeds and the archive reaches the provider; the unsubscribe waits for another try.
        #expect(await harness.engine.cycle())
        let remote = try await harness.provider.threads(ids: [thread.id]).flatMap { $0 }
        #expect(remote.allSatisfy { !$0.labelIDs.contains("INBOX") })
        let waiting = try #require(try await harness.store.outboxItems().first)
        #expect(waiting.operation == .unsubscribe(request))
        #expect(waiting.attempts == 1 && waiting.notBefore > Date())

        // After the last attempt it is given up and the outbox is clear.
        for _ in 0..<(SyncEngine.unsubscribeAttempts - 2) {
            try await harness.store.retryOutboxItem(waiting.id, error: "test", retryAt: Date())
        }
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.outboxCount() == 0)
        #expect(await harness.provider.oneClickUnsubscribes.isEmpty)
    }

    @Test func aListThatRefusesIsGivenUpAtOnce() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let request = UnsubscribeRequest(method: .oneClick(URL(string: "https://gone.example/u")!), list: "Gone")
        _ = try await harness.store.enqueue(.unsubscribe(request), notBefore: Date())
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.outboxCount() == 0)
    }

    @Test func changesWaitForSignIn() async throws {
        let harness = try await Harness()
        #expect(await harness.engine.cycle())
        let thread = try #require(try await harness.store.threads(.mailbox(.inbox)).first)
        try await harness.actions.perform(.archive, threads: [thread.id])

        // Signed out: the cycle fails, but the archive stays queued.
        let signedOut = SyncEngine(provider: SignedOut(base: harness.provider), store: harness.store, initialSyncLimit: 300)
        #expect(await signedOut.cycle() == false)
        #expect(try await harness.store.outboxCount() == 1)

        // Signed in again: it goes out.
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.outboxCount() == 0)
        let remote = try await harness.provider.threads(ids: [thread.id]).flatMap { $0 }
        #expect(remote.allSatisfy { !$0.labelIDs.contains("INBOX") })
    }
}

/// The dummy server, as Gmail answers when the sign-in has expired.
struct SignedOut: MailProvider {
    let base: DummyMailProvider
    var kind: String { base.kind }

    func profile() async throws -> AccountProfile { throw ProviderError.unauthorized }
    func labels() async throws -> [MailLabel] { throw ProviderError.unauthorized }
    func listThreadIDs(labelID: String?, pageToken: String?, pageSize: Int) async throws -> ThreadIDPage { throw ProviderError.unauthorized }
    func threads(ids: [String]) async throws -> [[MailMessage]] { throw ProviderError.unauthorized }
    func changes(since cursor: String) async throws -> ChangeSet { throw ProviderError.unauthorized }
    func modifyLabels(messageIDs: [String], add: Set<String>, remove: Set<String>) async throws { throw ProviderError.unauthorized }
    func deleteMessages(ids: [String]) async throws { throw ProviderError.unauthorized }
    func send(_ message: OutgoingMessage, fileData: [String: Data], isRetry: Bool) async throws -> MailMessage { throw ProviderError.unauthorized }
    func unsubscribe(oneClick url: URL) async throws { try await base.unsubscribe(oneClick: url) }
    func attachmentData(messageID: String, attachmentID: String) async throws -> Data { throw ProviderError.unauthorized }
    func createLabel(name: String) async throws -> MailLabel { throw ProviderError.unauthorized }
    func renameLabel(id: String, to name: String) async throws -> MailLabel { throw ProviderError.unauthorized }
    func deleteLabel(id: String) async throws { throw ProviderError.unauthorized }
}
