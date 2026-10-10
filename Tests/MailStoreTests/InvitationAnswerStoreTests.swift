import Foundation
import Testing
@testable import MailCore
@testable import MailStore

/// Alex's invitation to a review, in conversation `thread` (the store's account, `me`, is a guest).
private func invite(_ messageID: String, thread: String, sequence: Int = 0, recurrenceID: EventTime? = nil) -> (MailMessage, Invitation) {
    let start = EventTime.timed(Date().addingTimeInterval(2 * 86_400), timeZone: nil)
    let invitation = Invitation(
        method: .request, uid: "review@studio.co", sequence: sequence, recurrenceID: recurrenceID, summary: "Review", start: start,
        organizer: Attendee(email: alex.email, name: alex.name, isOrganizer: true), attendees: [Attendee(email: alex.email), Attendee(email: me.email)]
    )
    let mail = message(messageID, thread: thread, subject: "Invitation: Review", attachments: [MailAttachment(id: "ics-\(messageID)", filename: "invite.ics", mimeType: "text/calendar", size: 900)])
    return (mail, invitation)
}

/// Stores invitation mails and their parsed files.
private func save(_ invites: [(MailMessage, Invitation)], in store: MailStore) async throws {
    try await store.upsertMessages(invites.map(\.0))
    for (mail, invitation) in invites {
        try await store.saveInvitations([invitation], messageID: mail.id, threadID: mail.threadID)
    }
}

/// Your answer by email to the review, ready to queue: the email and its copy in Sent.
private func reply(_ response: ResponseStatus, thread: String = "ti", sequence: Int = 0, recurrenceID: String = "") -> (InvitationReply, MailMessage) {
    let copyID = "local-\(UUID().uuidString.lowercased())"
    let message = OutgoingMessage(
        from: me, to: [alex], subject: "Accepted: Review", textBody: "Sam Carter has accepted this invitation.", threadID: thread,
        messageID: "<vimail.\(UUID().uuidString.lowercased())@studionorth.co>",
        calendar: CalendarPart(method: "REPLY", text: "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nEND:VCALENDAR\r\n")
    )
    let copy = MailMessage(id: copyID, threadID: thread, labelIDs: ["SENT"], from: me, to: [alex], subject: message.subject, snippet: "", date: Date(), textBody: message.textBody)
    let answer = InvitationAnswer(uid: "review@studio.co", recurrenceID: recurrenceID, response: response, sequence: sequence)
    return (InvitationReply(message: message, localMessageID: copyID, answer: answer, summary: "Review"), copy)
}

private func queue(_ response: ResponseStatus, in store: MailStore, thread: String = "ti", sequence: Int = 0, recurrenceID: String = "") async throws -> Int64 {
    let (reply, copy) = reply(response, thread: thread, sequence: sequence, recurrenceID: recurrenceID)
    return try await store.queueInvitationReply(reply, localCopy: copy, notBefore: Date().addingTimeInterval(60))
}

/// The replies waiting in the mail outbox, as queued.
private func queuedReplies(_ store: MailStore) async throws -> [Int64: InvitationReply] {
    var replies: [Int64: InvitationReply] = [:]
    for item in try await store.outboxItems() {
        if case .invitationReply(let reply) = item.operation { replies[item.id] = reply }
    }
    return replies
}

@Suite("Answers by email in the store")
struct InvitationAnswerStoreTests {
    @Test func anAnswerStopsTheInvitationWaitingAndItsEmailWaitsInTheOutbox() async throws {
        let store = try await seededStore()
        try await save([invite("i1", thread: "ti")], in: store)
        #expect(try await store.invitationsWithoutEvents().map(\.messageID) == ["i1"])

        let outboxID = try await queue(.accepted, in: store)
        let queued = try #require(try await queuedReplies(store)[outboxID])
        #expect(queued.message.calendar?.method == "REPLY")
        #expect(queued.answer.response == .accepted && queued.previous == nil)
        #expect(try await store.outboxItems().first?.notBefore ?? .distantPast > Date().addingTimeInterval(30))
        // Its copy shows in the invitation's conversation and in Sent.
        #expect(try await store.thread(id: "ti")?.messages.count == 2)
        #expect(try await store.threads(.mailbox(.sent)).map(\.id).contains("ti"))

        #expect(try await store.invitationsWithoutEvents().isEmpty)
        let answered = try #require(try await store.invitationsWithoutEvents(includingAnswered: true).first)
        #expect(answered.messageID == "i1" && answered.answer?.response == .accepted && answered.answer?.outboxID == outboxID)
        #expect(try await store.invitations(threadID: "ti").last?.answer?.response == .accepted)
        #expect(try await store.latestInvitations(threadIDs: ["ti"])["ti"]?.answer?.response == .accepted)
        #expect(try await store.invitationAnswer(uid: "review@studio.co")?.outboxID == outboxID)
    }

    @Test func aNewerInvitationWaitsAgain() async throws {
        let store = try await seededStore()
        try await save([invite("i1", thread: "ti")], in: store)
        _ = try await queue(.declined, in: store)
        try await save([invite("i2", thread: "tu", sequence: 1)], in: store)
        let waiting = try await store.invitationsWithoutEvents()
        #expect(waiting.map(\.messageID) == ["i2"])
        #expect(waiting.first?.answer == nil)
        // The answer still covers the invitation it answered.
        #expect(try await store.invitations(threadID: "ti").last?.answer?.response == .declined)

        // Answering the newer one covers both.
        _ = try await queue(.accepted, in: store, thread: "tu", sequence: 1)
        #expect(try await store.invitationsWithoutEvents().isEmpty)
        #expect(try await store.invitations(uid: "review@studio.co").map { $0.answer?.response } == [.accepted, .accepted])

        // A later answer from the older mail still covers the newer one.
        _ = try await queue(.tentative, in: store)
        #expect(try await store.invitationsWithoutEvents().isEmpty)
        #expect(try await store.invitationAnswer(uid: "review@studio.co")?.sequence == 1)
        #expect(try await store.invitationAnswer(uid: "review@studio.co")?.response == .tentative)
    }

    @Test func anAnswerIsForTheOccurrenceItNames() async throws {
        let store = try await seededStore()
        let tuesday = EventTime.timed(Date().addingTimeInterval(3 * 86_400), timeZone: nil)
        try await save([invite("i1", thread: "ti", recurrenceID: tuesday)], in: store)
        // An answer to the whole series does not answer one changed date of it.
        _ = try await queue(.accepted, in: store)
        #expect(try await store.invitationsWithoutEvents().map(\.messageID) == ["i1"])
        _ = try await queue(.declined, in: store, recurrenceID: tuesday.occurrenceKey)
        #expect(try await store.invitationsWithoutEvents().isEmpty)
        #expect(try await store.invitationAnswer(uid: "review@studio.co", recurrenceID: tuesday.occurrenceKey)?.response == .declined)
        #expect(try await store.invitationAnswer(uid: "review@studio.co")?.response == .accepted)
    }

    @Test func undoBeforeTheEmailLeavesTakesBackTheEmailItsCopyAndTheAnswer() async throws {
        let store = try await seededStore()
        try await save([invite("i1", thread: "ti")], in: store)
        let outboxID = try await queue(.accepted, in: store)
        #expect(try await store.cancelInvitationReply(outboxID: outboxID))
        #expect(try await store.outboxCount() == 0)
        #expect(try await store.thread(id: "ti")?.messages.map(\.id) == ["i1"])
        #expect(try await store.invitationAnswer(uid: "review@studio.co") == nil)
        #expect(try await store.invitationsWithoutEvents().map(\.messageID) == ["i1"])
        #expect(try await store.cancelInvitationReply(outboxID: outboxID) == false)
    }

    @Test func undoAfterTheEmailLeftKeepsTheAnswer() async throws {
        let store = try await seededStore()
        try await save([invite("i1", thread: "ti")], in: store)
        let outboxID = try await queue(.tentative, in: store)
        // Being sent: too late to take back, and the organizer will have the answer.
        #expect(try await store.claimNextOutboxItem(now: Date().addingTimeInterval(61))?.id == outboxID)
        #expect(try await store.cancelInvitationReply(outboxID: outboxID) == false)
        #expect(try await store.invitationAnswer(uid: "review@studio.co")?.response == .tentative)
        #expect(try await store.outboxCount() == 1)
        #expect(try await store.invitationsWithoutEvents().isEmpty)
    }

    @Test func undoingTheLaterOfTwoAnswersPutsBackTheEarlierOne() async throws {
        let store = try await seededStore()
        try await save([invite("i1", thread: "ti")], in: store)
        let yes = try await queue(.accepted, in: store)
        let no = try await queue(.declined, in: store)
        #expect(try await queuedReplies(store)[no]?.previous?.response == .accepted)
        #expect(try await store.invitationAnswer(uid: "review@studio.co")?.response == .declined)

        #expect(try await store.cancelInvitationReply(outboxID: no))
        let restored = try #require(try await store.invitationAnswer(uid: "review@studio.co"))
        #expect(restored.response == .accepted && restored.outboxID == yes)
        #expect(try await store.cancelInvitationReply(outboxID: yes))
        #expect(try await store.invitationAnswer(uid: "review@studio.co") == nil)
        #expect(try await store.thread(id: "ti")?.messages.count == 1)
    }

    @Test func aRefusedEmailPutsBackTheAnswerBeforeItUnlessALaterOneReplacedIt() async throws {
        let store = try await seededStore()
        try await save([invite("i1", thread: "ti")], in: store)
        let yes = try await queue(.accepted, in: store)
        let no = try await queue(.declined, in: store)
        let replies = try await queuedReplies(store)
        let first = try #require(replies[yes]), second = try #require(replies[no])

        #expect(second.previous?.outboxID == yes)

        // The first email is refused while the second still waits: the second answer stays, and no longer comes
        // after an answer that went out.
        _ = try await store.cancelOutboxItems([yes])
        try await store.restoreFailedInvitationReply(first, outboxID: yes)
        #expect(try await store.invitationAnswer(uid: "review@studio.co")?.response == .declined)
        #expect(try await store.thread(id: "ti")?.messages.map(\.id).contains(first.localMessageID) == false)
        let waiting = try #require(try await queuedReplies(store)[no])
        #expect(waiting.previous == nil)

        // Then the second is refused too: no answer is left, so the invitation waits again.
        _ = try await store.cancelOutboxItems([no])
        try await store.restoreFailedInvitationReply(waiting, outboxID: no)
        #expect(try await store.invitationAnswer(uid: "review@studio.co") == nil)
        #expect(try await store.thread(id: "ti")?.messages.map(\.id) == ["i1"])
        #expect(try await store.invitationsWithoutEvents().map(\.messageID) == ["i1"])
    }

    @Test func yourOwnRepliesAreNotTheConversationsInvitation() async throws {
        let store = try await seededStore()
        try await save([invite("i1", thread: "ti")], in: store)
        // Your answer's sent copy and a guest's answer, each with a REPLY file.
        let sent = message("r1", thread: "ti", from: me, to: [alex], subject: "Accepted: Review", labels: ["SENT"], minutesAgo: 5)
        let guest = message("r2", thread: "ti", from: nina, to: [alex], subject: "Declined: Review", minutesAgo: 1)
        try await store.upsertMessages([sent, guest])
        let start = EventTime.timed(Date().addingTimeInterval(2 * 86_400), timeZone: nil)
        try await store.saveInvitations([Invitation(method: .reply, uid: "review@studio.co", summary: "Review", start: start, attendees: [Attendee(email: me.email, response: .accepted)])], messageID: "r1", threadID: "ti")
        try await store.saveInvitations([Invitation(method: .reply, uid: "review@studio.co", summary: "Review", start: start, attendees: [Attendee(email: nina.email, response: .declined)])], messageID: "r2", threadID: "ti")

        #expect(try await store.invitations(threadID: "ti").map(\.messageID) == ["i1", "r2"])
        #expect(try await store.invitations(uid: "review@studio.co").map(\.messageID) == ["i1", "r2"])
        #expect(try await store.latestInvitations(threadIDs: ["ti"])["ti"]?.messageID == "r2")
    }

    @Test func meetingsCancelledOrRemovedSinceTheirInvitationAreWithdrawn() async throws {
        let store = try await seededStore()
        let tuesday = EventTime.timed(Date().addingTimeInterval(3 * 86_400), timeZone: nil)
        let (mail, review) = invite("i1", thread: "ti")
        try await save([(mail, review)], in: store)
        #expect(try await store.isWithdrawn(review) == false)

        // One cancelled day of a series takes only that day.
        try await store.upsertMessages([message("c1", thread: "tc1", from: alex, subject: "Canceled: Review on Tuesday")])
        try await store.saveInvitations([Invitation(method: .cancel, uid: review.uid, sequence: 1, recurrenceID: tuesday, summary: "Review", start: tuesday)], messageID: "c1", threadID: "tc1")
        var tuesdayOnly = review
        tuesdayOnly.recurrenceID = tuesday
        #expect(try await store.isWithdrawn(review) == false)
        #expect(try await store.isWithdrawn(tuesdayOnly))

        // Cancelling the meeting, in a conversation of its own, takes it and every older invitation; not a newer one.
        try await store.upsertMessages([message("c2", thread: "tc2", from: alex, subject: "Canceled: Review")])
        try await store.saveInvitations([Invitation(method: .cancel, uid: review.uid, sequence: 1, summary: "Review", start: review.start)], messageID: "c2", threadID: "tc2")
        #expect(try await store.isWithdrawn(review))
        var again = review
        again.sequence = 2
        #expect(try await store.isWithdrawn(again) == false)

        // The sync removed it from your calendar: the organizer deleted it, or took you off.
        let calendar = CalendarInfo(id: me.email, summary: "Sam", isPrimary: true)
        try await store.applyCalendarList([calendar], removed: [], replaceAll: true)
        let start = EventTime.timed(Date().addingTimeInterval(4 * 86_400), timeZone: nil)
        var sync = CalendarEvent(id: "e1", calendarID: calendar.id, iCalUID: "sync@studio.co", summary: "Sync", start: start, end: start)
        sync.sequence = 1
        try await store.applyEvents([sync], calendarID: calendar.id, window: CalendarWindow.around(Date()))
        let syncInvitation = Invitation(method: .request, uid: "sync@studio.co", sequence: 1, summary: "Sync", start: start)
        #expect(try await store.isWithdrawn(syncInvitation) == false)
        var removal = CalendarEvent(id: "e1", calendarID: calendar.id, summary: "", start: start, end: start)
        removal.status = .cancelled
        try await store.applyEvents([removal], calendarID: calendar.id, window: CalendarWindow.around(Date()))
        #expect(try await store.isWithdrawn(syncInvitation))
    }

    @Test func resettingTheMailCacheDropsAnswersWhoseEmailNeverLeft() async throws {
        let store = try await seededStore()
        try await save([invite("i1", thread: "ti")], in: store)
        let sent = try await queue(.accepted, in: store)
        #expect(try await store.claimNextOutboxItem(now: Date().addingTimeInterval(61))?.id == sent)
        try await store.completeOutboxItem(sent)
        // A later answer to another occurrence, still waiting to leave.
        _ = try await queue(.declined, in: store, recurrenceID: "20991231T090000Z")
        try await store.resetMailData()
        #expect(try await store.invitationAnswer(uid: "review@studio.co")?.response == .accepted)
        #expect(try await store.invitationAnswer(uid: "review@studio.co", recurrenceID: "20991231T090000Z") == nil)
        try await store.resetMailData(everything: true)
        #expect(try await store.invitationAnswer(uid: "review@studio.co") == nil)
    }
}
