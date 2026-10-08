import Foundation
import Testing
@testable import MailCore
@testable import MailStore

let me = EmailAddress(name: "Sam Carter", email: "sam@studionorth.co")
let alex = EmailAddress(name: "Alex Morgan", email: "alex@studionorth.co")
let nina = EmailAddress(name: "Nina Park", email: "nina@parkhouse.me")

func makeStore() throws -> MailStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("vimail-tests-\(UUID().uuidString)")
        .appendingPathComponent("mail.sqlite")
    return try MailStore(url: url)
}

func message(
    _ id: String, thread: String, from: EmailAddress = alex, to: [EmailAddress] = [me],
    subject: String = "Hello", body: String = "Body text", labels: Set<String> = ["INBOX", "UNREAD"],
    minutesAgo: Double = 10, attachments: [MailAttachment] = []
) -> MailMessage {
    MailMessage(
        id: id, threadID: thread, labelIDs: labels, from: from, to: to, subject: subject,
        snippet: String(body.prefix(100)), date: Date().addingTimeInterval(-minutesAgo * 60),
        textBody: body, attachments: attachments
    )
}

func seededStore() async throws -> MailStore {
    let store = try makeStore()
    try await store.setAccount(AccountProfile(email: me.email, displayName: me.name!, historyCursor: "1"))
    try await store.replaceProviderLabels([
        MailLabel(id: "INBOX", name: "INBOX", kind: .system),
        MailLabel(id: "UNREAD", name: "UNREAD", kind: .system),
        MailLabel(id: "STARRED", name: "STARRED", kind: .system),
        MailLabel(id: "SENT", name: "SENT", kind: .system),
        MailLabel(id: "TRASH", name: "TRASH", kind: .system),
        MailLabel(id: "Label_1", name: "work", kind: .user, colorIndex: 0),
    ])
    try await store.upsertMessages([
        message("m1", thread: "t1", subject: "Quarterly budget review", body: "Please review the budget spreadsheet", minutesAgo: 30),
        message("m2", thread: "t1", from: me, to: [alex], subject: "Re: Quarterly budget review", body: "Looks good to me", labels: ["SENT"], minutesAgo: 20),
        message("m3", thread: "t2", from: nina, subject: "Coffee on Thursday?", body: "There is a new spot on Valencia", labels: ["INBOX"], minutesAgo: 5),
        message("m4", thread: "t3", subject: "Old archived thing", body: "Nothing to see", labels: ["Label_1"], minutesAgo: 600,
                attachments: [MailAttachment(id: "a1", filename: "notes.pdf", mimeType: "application/pdf", size: 1200)]),
    ])
    return store
}

@Suite("MailStore")
struct MailStoreTests {
    @Test func inboxListsThreadsNewestFirstWithAggregates() async throws {
        let store = try await seededStore()
        let inbox = try await store.threads(.mailbox(.inbox))
        #expect(inbox.map(\.id) == ["t2", "t1"])

        let t1 = try #require(inbox.first { $0.id == "t1" })
        #expect(t1.messageCount == 2)
        #expect(t1.isUnread)
        #expect(t1.participants == "Alex, me")
        #expect(t1.subject == "Quarterly budget review")
        #expect(t1.snippet == "Looks good to me")
    }

    @Test func archiveAndLabelScopes() async throws {
        let store = try await seededStore()
        let archive = try await store.threads(.mailbox(.archive))
        #expect(archive.map(\.id) == ["t3"])
        #expect(archive.first?.hasAttachments == true)

        let work = try await store.threads(.mailbox(.label("Label_1")))
        #expect(work.map(\.id) == ["t3"])
    }

    @Test func fullTextSearchWithOperators() async throws {
        let store = try await seededStore()
        let budget = try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: .parse("budg")))
        #expect(budget.map(\.id) == ["t1"])

        let fromNina = try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: .parse("from:nina")))
        #expect(fromNina.map(\.id) == ["t2"])

        let attachments = try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: .parse("has:attachment")))
        #expect(attachments.map(\.id) == ["t3"])

        let unreadInInbox = try await store.threads(ThreadQuery.mailbox(.inbox).narrowed(by: .parse("is:unread")))
        #expect(unreadInInbox.map(\.id) == ["t1"])

        let byLabelName = try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: .parse("label:work")))
        #expect(byLabelName.map(\.id) == ["t3"])

        let excluded = try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: .parse("-budget")))
        #expect(!excluded.map(\.id).contains("t1"))
    }

    @Test func applyAndRevertMutationCancelsPendingOutbox() async throws {
        let store = try await seededStore()
        let applied = try await store.apply(LocalMutation(deltas: [
            PlannedDelta(LabelDelta(messageIDs: ["m1"], remove: ["INBOX"]), syncs: true),
        ]))
        #expect(try await store.threads(.mailbox(.inbox)).map(\.id) == ["t2"])
        #expect(try await store.outboxCount() == 1)

        try await store.revert(applied)
        #expect(try await store.threads(.mailbox(.inbox)).map(\.id) == ["t2", "t1"])
        #expect(try await store.outboxCount() == 0)
    }

    @Test func revertAfterSendEnqueuesInverse() async throws {
        let store = try await seededStore()
        let applied = try await store.apply(LocalMutation(deltas: [
            PlannedDelta(LabelDelta(messageIDs: ["m3"], add: ["STARRED"]), syncs: true),
        ]))
        // Simulate the sync engine sending it.
        let claimed = try #require(try await store.claimNextOutboxItem())
        try await store.completeOutboxItem(claimed.id)

        try await store.revert(applied)
        let items = try await store.outboxItems()
        #expect(items.count == 1)
        #expect(items.first?.operation == .modifyLabels(LabelDelta(messageIDs: ["m3"], add: [], remove: ["STARRED"])))
    }

    @Test func remoteChangesDoNotRevertPendingLocalChanges() async throws {
        let store = try await seededStore()
        _ = try await store.apply(LocalMutation(deltas: [
            PlannedDelta(LabelDelta(messageIDs: ["m3"], remove: ["INBOX"]), syncs: true),
        ]))
        // The provider still reports the old state (archive not pushed yet).
        _ = try await store.applyRemoteChanges(ChangeSet(cursor: "2", labelUpdates: ["m3": ["INBOX"]]))
        #expect(try await store.threads(.mailbox(.inbox)).map(\.id) == ["t1"])
    }

    @Test func localLabelsSurviveProviderUpdates() async throws {
        let store = try await seededStore()
        let local = try await store.createLabel(name: "newsletter", kind: .local, colorIndex: 2)
        _ = try await store.apply(LocalMutation(deltas: [PlannedDelta(LabelDelta(messageIDs: ["m3"], add: [local.id]), syncs: false)]))
        #expect(try await store.outboxCount() == 0)

        _ = try await store.applyRemoteChanges(ChangeSet(cursor: "2", labelUpdates: ["m3": ["INBOX", "STARRED"]]))
        let thread = try #require(try await store.thread(id: "t2"))
        #expect(thread.labelIDs == ["INBOX", "STARRED", local.id])
    }

    @Test func snoozeHidesFromArchiveAndListsInSnoozed() async throws {
        let store = try await seededStore()
        let until = Date().addingTimeInterval(3600)
        _ = try await store.apply(LocalMutation(
            deltas: [PlannedDelta(LabelDelta(messageIDs: ["m3"], remove: ["INBOX"]), syncs: true)],
            snoozes: ["t2": until]
        ))
        #expect(try await store.threads(.mailbox(.snoozed)).map(\.id) == ["t2"])
        #expect(!(try await store.threads(.mailbox(.archive)).map(\.id).contains("t2")))
        #expect(try await store.dueSnoozes(now: until.addingTimeInterval(1)) == ["t2"])
    }

    @Test func remappingTemporaryLabelUpdatesMessagesAndOutbox() async throws {
        let store = try await seededStore()
        let pending = try await store.createLabel(name: "clients", kind: .user, colorIndex: nil)
        _ = try await store.apply(LocalMutation(deltas: [PlannedDelta(LabelDelta(messageIDs: ["m1"], add: [pending.id]), syncs: true)]))
        try await store.remapLabel(from: pending.id, to: MailLabel(id: "Label_9", name: "clients", kind: .user))

        let thread = try #require(try await store.thread(id: "t1"))
        #expect(thread.labelIDs.contains("Label_9"))
        #expect(!thread.labelIDs.contains(pending.id))
        let operations = try await store.outboxItems().map(\.operation)
        #expect(operations.contains(.modifyLabels(LabelDelta(messageIDs: ["m1"], add: ["Label_9"]))))
    }

    @Test func sendQueueAndUndo() async throws {
        let store = try await seededStore()
        var draft = Draft(to: [nina], subject: "Lunch", body: "Tomorrow?")
        try await store.saveDraft(draft)
        let local = MailMessage(id: "local-1", threadID: "local-t1", labelIDs: ["SENT"], from: me, to: [nina], subject: "Lunch", snippet: "Tomorrow?", date: Date(), textBody: "Tomorrow?")
        let outgoing = OutgoingMessage(from: me, to: [nina], subject: "Lunch", textBody: "Tomorrow?")
        let id = try await store.queueSend(draft: draft, message: outgoing, localCopy: local, notBefore: Date().addingTimeInterval(5))

        #expect(try await store.threads(.mailbox(.sent)).map(\.id).contains("local-t1"))
        #expect(try await store.drafts().isEmpty)

        draft.updatedAt = Date()
        #expect(try await store.cancelSend(outboxID: id, draft: draft, localMessageID: "local-1"))
        #expect(!(try await store.threads(.mailbox(.sent)).map(\.id).contains("local-t1")))
        #expect(try await store.drafts().count == 1)
    }

    @Test func contactsRankPeopleYouWriteTo() async throws {
        let store = try await seededStore()
        let suggestions = try await store.contacts(matching: "al")
        #expect(suggestions.first?.email == alex.email)
        let byName = try await store.contacts(matching: "park")
        #expect(byName.first?.email == nina.email)
    }

    @Test func savedViewQueries() async throws {
        let store = try await seededStore()
        try await store.seedDefaultViewsIfNeeded(workLabelID: "Label_1")
        let views = try await store.savedViews()
        #expect(views.map(\.name) == ["Unread", "Work", "Starred"])

        let unread = try await store.threads(views[0].query)
        #expect(unread.map(\.id) == ["t1"])
        let work = try await store.threads(views[1].query)
        #expect(work.map(\.id) == ["t3"])

        let senderView = SavedView(name: "Nina", sender: "nina")
        #expect(try await store.threads(senderView.query).map(\.id) == ["t2"])
        let textView = SavedView(name: "Valencia", text: "valencia")
        #expect(try await store.threads(textView.query).map(\.id) == ["t2"])
    }

    @Test func idsFilterKeepsStickyRowsThatStillMatch() async throws {
        let store = try await seededStore()
        // t1 was read while browsing the Unread tab: it still matches the Inbox when read status is ignored.
        var query = ThreadQuery.mailbox(.inbox)
        query.ids = ["t1", "t3"]
        #expect(try await store.threads(query).map(\.id) == ["t1"])
        query.ids = []
        #expect(try await store.threads(query).isEmpty)
    }

    @Test func storeChangeNotificationsCarryThreadIDs() async throws {
        let store = try await seededStore()
        let box = ChangeBox()
        store.observe { box.append($0) }
        _ = try await store.apply(LocalMutation(deltas: [PlannedDelta(LabelDelta(messageIDs: ["m3"], add: ["STARRED"]), syncs: true)]))
        #expect(box.changes.contains { $0.threadIDs.contains("t2") })
    }
}

final class ChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StoreChange] = []
    func append(_ change: StoreChange) { lock.lock(); storage.append(change); lock.unlock() }
    var changes: [StoreChange] { lock.lock(); defer { lock.unlock() }; return storage }
}
