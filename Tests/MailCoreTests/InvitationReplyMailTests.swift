import Foundation
import Testing
@testable import MailCore

/// An instant written in ISO 8601 (the distant past for a typo, which fails the comparison).
private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text) ?? .distantPast }

private let sam = EmailAddress(name: "Sam Carter", email: "sam@hey.com")
private let pacific = "America/Los_Angeles"

/// The Google invitation mail the fixtures come in: a conversation to answer in.
private let invitationMail = MailMessage(
    id: "m1", threadID: "t1", labelIDs: ["INBOX"], from: EmailAddress(name: "Jamie Chen", email: "jamie.chen@studio.co"), to: [sam],
    subject: "Invitation: Q4 launch review", snippet: "", date: utc("2026-10-09T17:15:02Z"),
    messageIDHeader: "<invite-1@google.com>", references: ["<root@google.com>"]
)

/// Sam's answer to `invitation`, as vimail mails it.
private func answer(
    _ invitation: Invitation, _ response: ResponseStatus = .accepted, comment: String? = nil, mail: MailMessage? = invitationMail,
    account: EmailAddress = sam, me: Set<String> = ["sam@hey.com"], timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin")!
) -> OutgoingMessage? {
    ICalendar.replyMail(
        to: invitation, mail: mail, account: account, selfAddresses: me, response: response, comment: comment,
        now: utc("2026-10-10T17:00:00Z"), timeZone: timeZone
    )
}

private func meeting(start: EventTime, end: EventTime?) -> Invitation {
    Invitation(method: .request, uid: "when@vimail", summary: "Review", start: start, end: end, organizer: Attendee(email: "jamie@studio.co", name: "Jamie"))
}

@Suite("Answers by email")
struct InvitationReplyMailTests {
    @Test func theReplyGoesToTheOrganizerInTheInvitationsConversation() throws {
        let invitation = try #require(ICalendar.invitations(from: Fixture.googleInvitation).first)
        let mail = try #require(answer(invitation, comment: "  See you there; bringing notes.  "))
        #expect(mail.from == sam)
        #expect(mail.to == [EmailAddress(name: "Jamie Chen", email: "jamie.chen@studio.co")])
        #expect(mail.cc.isEmpty && mail.bcc.isEmpty)
        #expect(mail.subject == "Accepted: Q4 launch review @ Mon Oct 12, 2026 2pm - 2:45pm (PDT)")
        #expect(mail.textBody == "Sam Carter has accepted this invitation.\n\nSee you there; bringing notes.")
        #expect(mail.htmlBody == nil && mail.attachments.isEmpty)
        // In the invitation's conversation.
        #expect(mail.threadID == "t1")
        #expect(mail.inReplyTo == "<invite-1@google.com>")
        #expect(mail.references == ["<root@google.com>", "<invite-1@google.com>"])
        // Fixed when it is made, so a retry finds a copy that already went out.
        #expect(mail.messageID?.hasPrefix("<vimail.") == true && mail.messageID?.hasSuffix("@hey.com>") == true)

        let part = try #require(mail.calendar)
        #expect(part.method == "REPLY")
        let lines = part.text.components(separatedBy: "\r\n")
        #expect(lines.contains("METHOD:REPLY") && lines.contains("DTSTAMP:20261010T170000Z") && lines.contains("SEQUENCE:0"))
        #expect(lines.contains(#"COMMENT:See you there\; bringing notes."#))
        let reply = try #require(ICalendar.invitations(from: part.text).first)
        #expect(reply.method == .reply)
        #expect(reply.uid == invitation.uid && reply.sequence == invitation.sequence && reply.summary == invitation.summary)
        #expect(reply.start.date == invitation.start.date && reply.end?.date == invitation.end?.date)
        #expect(reply.organizer?.email == "jamie.chen@studio.co" && reply.organizer?.name == "Jamie Chen")
        #expect(reply.attendees == [Attendee(email: "sam@hey.com", name: "Sam Carter", response: .accepted, comment: "See you there; bringing notes.")])
    }

    @Test func subjectAndTextSayTheAnswer() throws {
        let invitation = try #require(ICalendar.invitations(from: Fixture.googleInvitation).first)
        #expect(answer(invitation, .tentative)?.subject == "Tentatively accepted: Q4 launch review @ Mon Oct 12, 2026 2pm - 2:45pm (PDT)")
        #expect(answer(invitation, .tentative)?.textBody == "Sam Carter has tentatively accepted this invitation.")
        #expect(answer(invitation, .declined)?.subject == "Declined: Q4 launch review @ Mon Oct 12, 2026 2pm - 2:45pm (PDT)")
        #expect(answer(invitation, .declined, comment: "Out that week\nSorry!")?.textBody == "Sam Carter has declined this invitation.\n\nOut that week\nSorry!")
        #expect(answer(invitation, .declined)?.calendar?.text.contains("\r\nATTENDEE;PARTSTAT=DECLINED;CN=Sam Carter:mailto:sam@hey.com\r\n") == true)
        // A blank note is no note.
        #expect(answer(invitation, comment: " \n ")?.textBody == "Sam Carter has accepted this invitation.")
        #expect(answer(invitation, comment: " \n ")?.calendar?.text.contains("COMMENT") == false)
        #expect(answer(invitation, .needsAction) == nil)
        // A title over several lines stays on one.
        var multiline = invitation
        multiline.summary = "Q4\nlaunch review"
        #expect(answer(multiline)?.subject.hasPrefix("Accepted: Q4 launch review @ ") == true)
    }

    @Test func whenIsWrittenAsGoogleWritesIt() throws {
        let la = TimeZone(identifier: pacific)!
        func when(_ start: EventTime, _ end: EventTime?, fallback: TimeZone = la) -> String {
            ICalendar.replyWhen(meeting(start: start, end: end), timeZone: fallback)
        }
        func day(_ text: String) -> EventTime { .allDay(DayDate(text)!) }
        func at(_ text: String, _ zone: String? = pacific) -> EventTime { .timed(utc(text), timeZone: zone) }

        #expect(when(day("2026-10-12"), day("2026-10-13")) == "Mon Oct 12, 2026")
        #expect(when(day("2026-10-12"), nil) == "Mon Oct 12, 2026")
        #expect(when(day("2026-10-16"), day("2026-10-19")) == "Fri Oct 16 - Sun Oct 18, 2026")
        #expect(when(day("2026-12-30"), day("2027-01-03")) == "Wed Dec 30, 2026 - Sat Jan 2, 2027")
        #expect(when(at("2026-10-12T21:00:00Z"), at("2026-10-12T21:45:00Z")) == "Mon Oct 12, 2026 2pm - 2:45pm (PDT)")
        #expect(when(at("2026-10-12T21:00:00Z"), nil) == "Mon Oct 12, 2026 2pm (PDT)")
        #expect(when(at("2026-10-12T19:00:00Z"), at("2026-10-12T19:30:00Z")) == "Mon Oct 12, 2026 12pm - 12:30pm (PDT)")
        // Across midnight, and up to it.
        #expect(when(at("2026-10-13T06:00:00Z"), at("2026-10-13T08:00:00Z")) == "Mon Oct 12, 2026 11pm - Tue Oct 13, 2026 1am (PDT)")
        #expect(when(at("2026-10-13T05:00:00Z"), at("2026-10-13T07:00:00Z")) == "Mon Oct 12, 2026 10pm - 12am (PDT)")
        // UTC times are written in your zone.
        #expect(when(at("2026-10-12T09:30:00Z", nil), at("2026-10-12T10:00:00Z", nil), fallback: TimeZone(identifier: "Europe/Berlin")!)
            == "Mon Oct 12, 2026 11:30am - 12pm (GMT+2)")
    }

    @Test func aSeriesSaysHowItRepeatsNotItsFirstDate() throws {
        let la = TimeZone(identifier: pacific)!
        // Added to a weekly meeting that started a month before.
        var weekly = meeting(start: .timed(utc("2026-09-07T17:00:00Z"), timeZone: pacific), end: .timed(utc("2026-09-07T17:30:00Z"), timeZone: pacific))
        weekly.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO"]
        #expect(ICalendar.replyWhen(weekly, timeZone: la) == "Weekly on Mon from 10am to 10:30am (Pacific Time)")
        #expect(answer(weekly)?.subject == "Accepted: Review @ Weekly on Mon from 10am to 10:30am (Pacific Time)")
        weekly.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;UNTIL=20261218T170000Z"]
        #expect(ICalendar.replyWhen(weekly, timeZone: la) == "Every weekday, until Dec 18 from 10am to 10:30am (Pacific Time)")
        // A rule words cannot say keeps the first date.
        weekly.recurrence = ["RRULE:FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2"]
        #expect(ICalendar.replyWhen(weekly, timeZone: la) == "Mon Sep 7, 2026 10am - 10:30am (PDT)")

        var birthday = meeting(start: .allDay(DayDate("2026-10-12")!), end: .allDay(DayDate("2026-10-13")!))
        birthday.recurrence = ["RRULE:FREQ=YEARLY"]
        #expect(ICalendar.replyWhen(birthday, timeZone: la) == "Yearly on Oct 12")
        // The reply itself still names the series' first date: the organizer's calendar knows the series by it.
        let file = try #require(answer(weekly)?.calendar?.text)
        #expect(file.contains("\r\nDTSTART:20260907T170000Z\r\n") && !file.contains("RRULE"))
    }

    @Test func oneOccurrenceIsAnsweredWithItsRecurrenceID() throws {
        let moved = try #require(ICalendar.invitations(from: Fixture.googleSeries).last)
        let mail = try #require(answer(moved, .declined))
        #expect(mail.subject == "Declined: Weekly standup (Tuesday this week) @ Tue Oct 20, 2026 10am - 10:15am (PDT)")
        #expect(mail.calendar?.text.contains("\r\nRECURRENCE-ID:20261019T160000Z\r\nDTSTART:20261020T170000Z\r\n") == true)
        #expect(mail.calendar?.text.contains("\r\nSEQUENCE:1\r\n") == true)
    }

    @Test func youAreTheAddressTheInvitationWasSentTo() {
        let invitation = Invitation(
            method: .request, uid: "sync@vimail", summary: "Sync", start: .timed(utc("2026-10-12T16:00:00Z"), timeZone: pacific),
            organizer: Attendee(email: "jamie@studio.co", name: "Jamie"), attendees: [Attendee(email: "Sam.Carter@Studio.co", name: "Sam (work)")]
        )
        // Named under one of your addresses: that address as the invitation spells it, with the account's name.
        let named = answer(invitation, mail: nil, me: ["sam@hey.com", "sam.carter@studio.co"])
        #expect(named?.from == EmailAddress(name: "Sam Carter", email: "Sam.Carter@Studio.co"))
        #expect(named?.calendar?.text.contains("\r\nATTENDEE;PARTSTAT=ACCEPTED;CN=Sam Carter:mailto:Sam.Carter@Studio.co\r\n") == true)
        // Invited through a list: the account's address.
        #expect(answer(invitation, mail: nil)?.from == sam)
        // An account without a name: the invitation's name for you.
        let nameless = answer(invitation, mail: nil, account: EmailAddress(email: "sam.carter@studio.co"), me: ["sam.carter@studio.co"])
        #expect(nameless?.from == EmailAddress(name: "Sam (work)", email: "Sam.Carter@Studio.co"))
        #expect(nameless?.textBody == "Sam (work) has accepted this invitation.")
        // Without the invitation's mail, it starts a conversation.
        #expect(named?.threadID == nil && named?.inReplyTo == nil && named?.references.isEmpty == true)
    }

    @Test func onlyRequestsWithAnOrganizerCanBeAnsweredByEmail() {
        let me: Set<String> = ["sam@hey.com"]
        let request = meeting(start: .timed(utc("2026-10-12T16:00:00Z"), timeZone: nil), end: nil)
        #expect(request.canBeAnsweredByEmail(by: me))
        var noOrganizer = request
        noOrganizer.organizer = nil
        var yours = request
        yours.organizer = Attendee(email: "Sam@Hey.com")
        var yoursByCalendar = request
        yoursByCalendar.organizer?.isSelf = true
        var cancelled = request
        cancelled.status = .cancelled
        for method in [Invitation.Method.cancel, .reply, .publish, .counter] {
            var other = request
            other.method = method
            #expect(!other.canBeAnsweredByEmail(by: me), "\(method)")
        }
        for invitation in [noOrganizer, yours, yoursByCalendar, cancelled] {
            #expect(!invitation.canBeAnsweredByEmail(by: me))
            #expect(answer(invitation) == nil)
        }
    }

    @Test func aHostileOrganizerCannotAddRecipientsOrHeaders() throws {
        func organizer(_ line: String, summary: String = "Hi") throws -> Invitation {
            let file = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:evil@vimail\r\nDTSTART:20991012T090000Z\r\nSUMMARY:\(summary)\r\n"
                + line + "\r\nATTENDEE:mailto:sam@hey.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
            return try #require(ICalendar.invitations(from: file).first)
        }
        // A line break in the address, written as %0D%0A, would start headers of its own: such an organizer is not mailed.
        for line in [
            "ORGANIZER:mailto:jamie@studio.co%0D%0AX-Evil:%201", "ORGANIZER:mailto:jamie@studio.co%0D%0ABcc:%20nina%40evil.example",
            "ORGANIZER:mailto:jamie@studio.co%3E%2C%20%3Cnina@evil.example", "ORGANIZER:mailto:jamie@studio",
        ] {
            let invitation = try organizer(line)
            #expect(invitation.organizer != nil, "\(line)")
            #expect(!invitation.canBeAnsweredByEmail(by: ["sam@hey.com"]), "\(line)")
            #expect(answer(invitation) == nil, "\(line)")
        }
        // A line break in the name or the title stays on its line.
        let named = try organizer(#"ORGANIZER;CN="Jamie^nBcc: nina@evil.example":mailto:jamie@studio.co"#, summary: "Hi\u{1B}\\nthere")
        let mail = try #require(answer(named))
        #expect(mail.to == [EmailAddress(name: "Jamie Bcc: nina@evil.example", email: "jamie@studio.co")])
        #expect(mail.subject.hasPrefix("Accepted: Hi there @ "))
    }

    @Test func onlyPlainAddressesAreMailed() {
        for address in ["jamie@studio.co", "jamie.chen+cal@studio.co.uk", "zoë@exämple.de", "JAMIE@STUDIO.CO"] {
            #expect(ICalendar.isMailable(address), "\(address)")
        }
        for address in [
            "", "jamie", "jamie@", "@studio.co", "jamie@studio", "jamie@.co", "jamie@studio.co.", "jamie@@studio.co", "jamie@x@studio.co",
            "jamie @studio.co", "jamie@studio.co\r\nX-Evil: 1", "jamie@studio.co\nBcc:nina", "jamie@studio.co\u{85}x", "jamie\t@studio.co",
            "Jamie <jamie@studio.co>", "jamie@studio.co>, <nina@evil.example", "a,b@studio.co", "a;b@studio.co", "\"a\"@studio.co", "a(b)@studio.co",
        ] {
            #expect(!ICalendar.isMailable(address), "\(address.debugDescription)")
        }
    }

    @Test func messagesQueuedBeforeCalendarPartsStillDecode() throws {
        let older = #"{"from":{"email":"me@example.com"},"to":[{"email":"a@b.co"}],"cc":[],"bcc":[],"subject":"Hi","textBody":"Hello","references":[],"attachments":[],"messageID":"<x@example.com>"}"#
        let message = try JSONDecoder().decode(OutgoingMessage.self, from: Data(older.utf8))
        #expect(message.subject == "Hi" && message.messageID == "<x@example.com>")
        #expect(message.calendar == nil)
        // Mail without a calendar part is written as before.
        #expect(!String(decoding: try JSONEncoder().encode(message), as: UTF8.self).contains("calendar"))
        var answer = message
        answer.calendar = CalendarPart(method: "REPLY", text: "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nEND:VCALENDAR\r\n")
        #expect(try JSONDecoder().decode(OutgoingMessage.self, from: JSONEncoder().encode(answer)) == answer)
    }
}
