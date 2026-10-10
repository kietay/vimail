import Foundation
import Testing
@testable import MailCore
@testable import MailStore
@testable import MailSync

/// Your label edits are reported to rules with the messages whose label really changed.
@Suite("Label edits in undo records")
struct LabelEditRecordTests {
    let sender = EmailAddress(name: "Figma via Stripe", email: "receipts@stripe.com")

    func store() async throws -> MailStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-edits-\(UUID().uuidString)")
        let store = try MailStore(url: directory.appendingPathComponent("mail.sqlite"))
        try await store.replaceProviderLabels(["INBOX", "UNREAD", "SENT"].map { MailLabel(id: $0, name: $0, kind: .system) } + [
            MailLabel(id: "Label_1", name: "receipts", kind: .user), MailLabel(id: "Label_2", name: "travel", kind: .user),
        ])
        try await store.upsertMessages([
            message("m1", thread: "t1", labels: ["INBOX", "Label_1"], minutesAgo: 30),
            message("m2", thread: "t1", labels: ["INBOX"], minutesAgo: 20),
            message("m3", thread: "t2", labels: ["INBOX"], minutesAgo: 10),
        ])
        return store
    }

    func message(_ id: String, thread: String, labels: Set<String>, minutesAgo: Double) -> MailMessage {
        MailMessage(id: id, threadID: thread, labelIDs: labels, from: sender, subject: "Your receipt", snippet: "", date: Date().addingTimeInterval(-minutesAgo * 60), textBody: "Thanks")
    }

    @Test func addingListsOnlyMessagesThatLackedTheLabel() async throws {
        let actions = MailActions(store: try await store())
        let record = try #require(try await actions.perform(.addLabel("Label_1"), threads: ["t1", "t2"]))
        #expect(record.messageIDs(changing: "Label_1", added: true).sorted() == ["m2", "m3"])
        #expect(record.messageIDs(changing: "Label_1", added: false).isEmpty)
        #expect(record.messageIDs(changing: "Label_2", added: true).isEmpty)
    }

    @Test func removingListsOnlyMessagesThatHadTheLabel() async throws {
        let actions = MailActions(store: try await store())
        let record = try #require(try await actions.perform(.removeLabel("Label_1"), threads: ["t1"]))
        #expect(record.messageIDs(changing: "Label_1", added: false) == ["m1"])
        #expect(record.messageIDs(changing: "Label_1", added: true).isEmpty)
    }

    @Test func movingAddsTheLabelAndTakesTheInboxAway() async throws {
        let actions = MailActions(store: try await store())
        let record = try #require(try await actions.perform(.moveToLabel("Label_2"), threads: ["t1"]))
        #expect(record.messageIDs(changing: "Label_2", added: true).sorted() == ["m1", "m2"])
        #expect(record.messageIDs(changing: SystemLabel.inbox, added: false).sorted() == ["m1", "m2"])
    }

    @Test func localLabelsCount() async throws {
        let store = try await store()
        let local = try await store.createLabel(name: "later", kind: .local, colorIndex: nil)
        let actions = MailActions(store: store)
        let record = try #require(try await actions.perform(.addLabel(local.id), threads: ["t1", "t2"]))
        #expect(record.messageIDs(changing: local.id, added: true).sorted() == ["m1", "m2", "m3"])
    }

    @Test func oneMessageIsMarkedReadAndTheRestStayNew() async throws {
        let store = try await store()
        try await store.upsertMessages([
            message("u1", thread: "t3", labels: ["INBOX", "UNREAD"], minutesAgo: 9),
            message("u2", thread: "t3", labels: ["INBOX", "UNREAD"], minutesAgo: 8),
        ])
        let actions = MailActions(store: store)
        let record = try #require(try await actions.markRead(message: "u1", inThread: "t3"))
        #expect(record.messageID == "u1")
        var thread = try #require(try await store.thread(id: "t3"))
        #expect(thread.messages.map(\.isUnread) == [false, true])
        // Already read: nothing to do, nothing to undo.
        #expect(try await actions.markRead(message: "u1", inThread: "t3") == nil)

        try await actions.undo(record)
        thread = try #require(try await store.thread(id: "t3"))
        #expect(thread.messages.map(\.isUnread) == [true, true])
    }
}
