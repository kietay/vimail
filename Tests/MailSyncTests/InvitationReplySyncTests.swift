import Foundation
import Testing
@testable import DummyProvider
@testable import MailCore
@testable import MailStore
@testable import MailSync

/// The dummy mailbox's invitation that Google Calendar did not add, with its file read.
private struct SamplesReview {
    var thread: String
    var file: StoredInvitation
    var invitation: Invitation
    var message: MailMessage

    init(_ mail: Harness) async throws {
        await InvitationIndexer(store: mail.store, provider: mail.provider).drain()
        let summary = try #require(try await mail.store.threads(.mailbox(.inbox)).first { $0.subject.hasPrefix("Invitation: Material samples review") })
        thread = summary.id
        file = try #require(try await mail.store.invitations(threadID: summary.id).last)
        invitation = try #require(file.main)
        message = try #require(try await mail.store.message(id: file.messageID))
    }

    /// In the waiting list: only in mail, with a date that waits for your answer.
    func isWaiting(_ mail: Harness) async throws -> Bool {
        try await mail.store.mailOnlyEvents().contains { $0.uid == invitation.uid && $0.event.waitingDate(now: Date(), answers: $0.answers) != nil }
    }
}

@Suite("Answers by email through the mail outbox", .serialized)
struct InvitationReplySyncTests {
    @Test func anAnswerReachesTheOrganizerInTheConversationAndTheInvitationStopsWaiting() async throws {
        let mail = try await Harness()
        #expect(await mail.engine.cycle())
        let review = try await SamplesReview(mail)
        #expect(try await review.isWaiting(mail))

        let actions = CalendarActions(store: mail.store)
        let record = try #require(try await actions.answerByEmail(review.invitation, mail: review.message, response: .accepted, comment: "See you there", undoWindow: 0))
        #expect(record.threadID == review.thread && record.summary == "Material samples review" && record.response == .accepted)
        // Queued in the mail outbox, with the reply as its calendar part.
        let queued = try #require(try await mail.store.outboxItems().first)
        guard case .invitationReply(let reply) = queued.operation else {
            Issue.record("Expected an answer by email in the outbox, got \(queued.operation)")
            return
        }
        #expect(reply.message.to.map(\.email) == ["elena@rossiarchitetti.it"])
        #expect(reply.message.threadID == review.thread && reply.message.inReplyTo == review.message.messageIDHeader)
        #expect(reply.message.calendar?.method == "REPLY")
        #expect(try await review.isWaiting(mail) == false)

        #expect(await mail.engine.cycle())
        #expect(try await mail.store.outboxCount() == 0)
        // The server has it in the conversation, with the reply as invite.ics, as Gmail lists it.
        let remote = try await mail.provider.threads(ids: [review.thread]).flatMap { $0 }
        let sent = try #require(remote.first { $0.from.normalized == "sam@hey.com" })
        #expect(sent.subject.hasPrefix("Accepted: Material samples review @ "))
        #expect(sent.textBody == "Sam Carter has accepted this invitation.\n\nSee you there")
        let ics = try #require(sent.attachments.first { $0.mimeType == "text/calendar" })
        let answer = try #require(ICalendar.invitations(from: try await mail.provider.attachmentData(messageID: sent.id, attachmentID: ics.id)).first)
        #expect(answer.method == .reply && answer.uid == review.invitation.uid)
        #expect(answer.organizer?.email == "elena@rossiarchitetti.it")
        #expect(answer.attendees == [Attendee(email: "sam@hey.com", name: "Sam Carter", response: .accepted, comment: "See you there")])
        // Here the copy is the server's message now, and the answer stays.
        let local = try #require(try await mail.store.thread(id: review.thread))
        #expect(local.messages.contains { $0.id == sent.id } && !local.messages.contains { $0.id.hasPrefix("local-") })
        #expect(try await mail.store.invitationAnswer(uid: review.invitation.uid)?.response == .accepted)

        // Reading the sent answer's own file keeps the conversation about the invitation.
        await InvitationIndexer(store: mail.store, provider: mail.provider).drain()
        let files = try await mail.store.invitations(threadID: review.thread)
        #expect(files.map(\.messageID) == [review.file.messageID])
        #expect(files.last?.answer?.response == .accepted)
        #expect(try await review.isWaiting(mail) == false)
    }

    @Test func undoWithinTheWindowSendsNothing() async throws {
        let mail = try await Harness()
        #expect(await mail.engine.cycle())
        let review = try await SamplesReview(mail)
        let actions = CalendarActions(store: mail.store)
        let record = try #require(try await actions.answerByEmail(review.invitation, mail: review.message, response: .declined, undoWindow: 60))
        #expect(try await mail.store.thread(id: review.thread)?.messages.count == 2)
        #expect(try await actions.undo(record))
        #expect(await mail.engine.cycle())
        #expect(try await mail.provider.threads(ids: [review.thread]).flatMap { $0 }.count == 1)
        #expect(try await mail.store.thread(id: review.thread)?.messages.count == 1)
        #expect(try await review.isWaiting(mail))

        // Once it left it cannot be unsent, and the answer stays: the organizer has it.
        let sent = try #require(try await actions.answerByEmail(review.invitation, mail: review.message, response: .tentative, undoWindow: 0))
        #expect(await mail.engine.cycle())
        #expect(try await actions.undo(sent) == false)
        #expect(try await mail.store.invitationAnswer(uid: review.invitation.uid)?.response == .tentative)
        #expect(try await review.isWaiting(mail) == false)
    }

    @Test func aRefusedAnswerWaitsAgainAndSaysWhy() async throws {
        let mail = try await Harness()
        #expect(await mail.engine.cycle())
        let review = try await SamplesReview(mail)
        // Organizers without a plain address are not mailed at all.
        var invitation = review.invitation
        invitation.organizer = Attendee(email: "elena@rossiarchitetti", name: "Elena Rossi", isOrganizer: true)
        #expect(try await CalendarActions(store: mail.store).answerByEmail(invitation, mail: review.message, response: .accepted, undoWindow: 0) == nil)
        #expect(try await mail.store.outboxCount() == 0)

        // A reply queued as CalendarActions queues it, that the server refuses.
        let account = try #require(try await mail.store.account())
        var message = try #require(ICalendar.replyMail(
            to: review.invitation, mail: review.message, account: account, selfAddresses: mail.store.selfAddresses, response: .accepted, comment: nil
        ))
        message.to = [EmailAddress(name: "Elena Rossi", email: "elena@rossiarchitetti")]
        let copy = MailMessage(
            id: "local-refused", threadID: review.thread, labelIDs: [SystemLabel.sent], from: message.from, to: message.to, subject: message.subject,
            snippet: "", date: Date(), textBody: message.textBody
        )
        let answer = InvitationAnswer(uid: invitation.uid, response: .accepted, sequence: invitation.sequence)
        _ = try await mail.store.queueInvitationReply(
            InvitationReply(message: message, localMessageID: copy.id, answer: answer, summary: invitation.summary), localCopy: copy, notBefore: .distantPast
        )
        #expect(try await review.isWaiting(mail) == false)

        var events = mail.engine.events.makeAsyncIterator()
        #expect(await mail.engine.cycle())
        guard case .answerFailed(_, let summary, let reason, let stands)? = await events.next() else {
            Issue.record("Expected the refusal to be reported")
            return
        }
        #expect(summary == "Material samples review" && reason.contains("Invalid address") && stands == false)
        #expect(try await mail.store.outboxCount() == 0)
        #expect(try await mail.store.invitationAnswer(uid: invitation.uid) == nil)
        #expect(try await mail.store.thread(id: review.thread)?.messages.count == 1)
        #expect(try await review.isWaiting(mail))
    }

    @Test func anOlderMailAnswersTheNewestVersionOfTheInvitation() async throws {
        let mail = try await Harness()
        #expect(await mail.engine.cycle())
        let review = try await SamplesReview(mail)
        // The organizer moved the meeting, and the update came in another conversation.
        var moved = review.invitation
        moved.sequence = 1
        moved.start = .timed(review.invitation.start.instant().addingTimeInterval(3600), timeZone: review.invitation.start.timeZone)
        moved.end = review.invitation.end.map { EventTime.timed($0.instant().addingTimeInterval(3600), timeZone: $0.timeZone) }
        let update = MailMessage(
            id: "update-1", threadID: "update-1", labelIDs: [SystemLabel.inbox], from: review.message.from, to: review.message.to,
            subject: "Updated invitation: Material samples review", snippet: "", date: Date()
        )
        try await mail.store.upsertMessages([update])
        try await mail.store.saveInvitations([moved], messageID: update.id, threadID: update.threadID)

        // Answered from the first mail: in its conversation, but for the moved meeting.
        let record = try #require(try await CalendarActions(store: mail.store).answerByEmail(review.invitation, mail: review.message, response: .accepted, undoWindow: 60))
        #expect(record.threadID == review.thread)
        #expect(record.uid == review.invitation.uid && record.recurrenceID == "" && record.sequence == 1)
        guard case .invitationReply(let reply)? = try await mail.store.outboxItems().first?.operation else {
            Issue.record("Expected an answer by email in the outbox")
            return
        }
        #expect(reply.answer.sequence == 1 && reply.message.threadID == review.thread)
        let answer = try #require(reply.message.calendar.flatMap { ICalendar.invitations(from: $0.text).first })
        #expect(answer.sequence == 1 && answer.start.instant() == moved.start.instant())
        #expect(try await review.isWaiting(mail) == false)
    }

    @Test func aMeetingCancelledSinceIsNotAnsweredByEmail() async throws {
        let mail = try await Harness()
        #expect(await mail.engine.cycle())
        let review = try await SamplesReview(mail)
        // The cancellation came in a conversation of its own, as Google's and Outlook's do.
        let notice = MailMessage(
            id: "cancel-1", threadID: "cancel-1", labelIDs: [SystemLabel.inbox], from: review.message.from, to: review.message.to,
            subject: "Canceled event: Material samples review", snippet: "", date: Date()
        )
        try await mail.store.upsertMessages([notice])
        var cancellation = review.invitation
        cancellation.method = .cancel
        try await mail.store.saveInvitations([cancellation], messageID: notice.id, threadID: notice.threadID)
        #expect(try await review.isWaiting(mail) == false)

        let actions = CalendarActions(store: mail.store)
        await #expect(throws: CalendarActions.EmailAnswerError.withdrawn(summary: "Material samples review")) {
            try await actions.answerByEmail(review.invitation, mail: review.message, response: .accepted, undoWindow: 0)
        }
        #expect(try await mail.store.outboxCount() == 0)
        #expect(try await mail.store.invitationAnswer(uid: review.invitation.uid) == nil)
        #expect(try await mail.store.thread(id: review.thread)?.messages.count == 1)
        #expect(await mail.engine.cycle())
        #expect(try await mail.provider.threads(ids: [review.thread]).flatMap { $0 }.count == 1)
    }

    @Test func theDummyCalendarLeavesOffTheInvitationGoogleDidNotAdd() async throws {
        let mail = try await Harness()
        #expect(await mail.engine.cycle())
        let review = try await SamplesReview(mail)
        var configuration = DummyCalendarProvider.Configuration()
        configuration.latency = 0...0
        let provider = mail.provider
        let calendar = DummyCalendarProvider(directory: mail.directory.appendingPathComponent("calendar"), configuration: configuration) {
            (try? await provider.invites()) ?? []
        }
        let engine = CalendarSyncEngine(provider: calendar, store: mail.store, pollInterval: .seconds(3600))
        #expect(await engine.cycle())
        // Not on the calendar, not even hidden: Y M N answer it by email.
        #expect(try await engine.fetchEvents(uid: review.invitation.uid).isEmpty)
        #expect(try await CalendarActions(store: mail.store).event(for: review.invitation) == nil)
        #expect(try await review.isWaiting(mail))
        // The other invitations are on it.
        let designReview = try #require(try await mail.store.threads(.mailbox(.inbox)).first { $0.subject.hasPrefix("Invitation: Design review") })
        let other = try #require(try await mail.store.invitations(threadID: designReview.id).last?.main)
        #expect(try await CalendarActions(store: mail.store).event(for: other) != nil)
    }
}
