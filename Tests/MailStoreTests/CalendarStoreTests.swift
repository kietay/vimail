import Foundation
import Testing
@testable import MailCore
@testable import MailStore

private let la: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
    la.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private let primary = CalendarInfo(id: "sam@studionorth.co", summary: "Sam", timeZone: "America/Los_Angeles", isPrimary: true)
private let window = CalendarWindow(from: at(1, 0, month: 9), to: at(1, 0, month: 12))

private func event(
    _ id: String, _ summary: String, start: Date, minutes: Int = 30, response: ResponseStatus? = nil, uid: String? = nil
) -> CalendarEvent {
    var attendees: [Attendee] = []
    if let response {
        attendees = [
            Attendee(email: "jamie@studionorth.co", name: "Jamie Chen", response: .accepted, isOrganizer: true),
            Attendee(email: "sam@studionorth.co", name: "Sam Carter", response: response, isSelf: true),
        ]
    }
    return CalendarEvent(
        id: id, calendarID: primary.id, iCalUID: uid ?? "\(id)@google.com", summary: summary,
        start: .timed(start, timeZone: "America/Los_Angeles"), end: .timed(start.addingTimeInterval(Double(minutes) * 60), timeZone: "America/Los_Angeles"),
        organizer: response == nil ? nil : attendees.first, attendees: attendees, etag: "\"1\""
    )
}

@Suite("Calendar store")
struct CalendarStoreTests {
    @Test func calendarListKeepsPrimaryFirstAndDropsMissingCalendars() async throws {
        let store = try makeStore()
        let shared = CalendarInfo(id: "team@group.calendar.google.com", summary: "Team")
        try await store.applyCalendarList([shared, primary], removed: [], replaceAll: true)
        #expect(try await store.calendars().map(\.id) == [primary.id, shared.id])

        try await store.applyEvents([event("e1", "Team lunch", start: at(12, 12))], calendarID: shared.id, window: window, calendar: la)
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        #expect(try await store.calendars().map(\.id) == [primary.id])
        #expect(try await store.agenda(from: at(12, 0), to: at(13, 0), calendar: la).isEmpty)
    }

    @Test func agendaReadsTimedAndAllDayOccurrencesForADay() async throws {
        let store = try makeStore()
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        let offsite = CalendarEvent(
            id: "e3", calendarID: primary.id, summary: "Offsite", start: .allDay(DayDate("2026-10-12")!), end: .allDay(DayDate("2026-10-14")!)
        )
        try await store.applyEvents([
            event("e1", "Design review", start: at(12, 14), minutes: 45),
            event("e2", "1:1 with Alex", start: at(12, 13)),
            event("e4", "Late", start: at(12, 23, 30), minutes: 60),
            offsite,
        ], calendarID: primary.id, window: window, calendar: la)

        let monday = try await store.agenda(from: at(12, 0), to: at(13, 0), calendar: la)
        #expect(monday.map(\.event.summary) == ["Offsite", "1:1 with Alex", "Design review", "Late"])
        #expect(monday.first?.start == .allDay(DayDate("2026-10-12")!))
        #expect(monday.first?.end == .allDay(DayDate("2026-10-14")!))

        // Tuesday: the all-day event's second day and the event that runs past midnight.
        let tuesday = try await store.agenda(from: at(13, 0), to: at(14, 0), calendar: la)
        #expect(tuesday.map(\.event.summary) == ["Offsite", "Late"])
        // Wednesday: the all-day event ended (its end date is exclusive).
        #expect(try await store.agenda(from: at(14, 0), to: at(15, 0), calendar: la).isEmpty)
    }

    @Test func cancelledEventsLeaveTheCalendar() async throws {
        let store = try makeStore()
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        try await store.applyEvents([event("e1", "Design review", start: at(12, 14))], calendarID: primary.id, window: window, calendar: la)
        var cancelled = event("e1", "Design review", start: at(12, 14))
        cancelled.status = .cancelled
        try await store.applyEvents([cancelled], calendarID: primary.id, window: window, calendar: la)
        #expect(try await store.event(calendarID: primary.id, id: "e1") == nil)
        #expect(try await store.agenda(from: at(12, 0), to: at(13, 0), calendar: la).isEmpty)
    }

    @Test func providerExpansionReplacesASeriesOccurrences() async throws {
        let store = try makeStore()
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        var series = event("s1", "Studio standup", start: at(5, 9, 30), minutes: 15)
        series.recurrence = ["RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"]
        let needsProvider = try await store.applyEvents([series], calendarID: primary.id, window: window, calendar: la)
        #expect(needsProvider == ["s1"])

        var instance = series
        instance.id = "s1_20261030T163000Z"
        instance.recurrence = []
        instance.recurringEventID = "s1"
        instance.start = .timed(at(30, 9, 30), timeZone: "America/Los_Angeles")
        instance.end = .timed(at(30, 9, 45), timeZone: "America/Los_Angeles")
        instance.originalStart = instance.start
        try await store.applyInstances([instance], calendarID: primary.id, seriesID: "s1", calendar: la)

        let day = try await store.agenda(from: at(30, 0), to: at(31, 0), calendar: la)
        #expect(day.count == 1)
        #expect(day.first?.event.id == "s1")
        #expect(day.first?.seriesID == "s1")
        #expect(day.first?.originalStart == "20261030T163000Z")
        #expect(day.first?.answerTargetID == "s1")
    }

    @Test func answeringIsLocalAtOnceAndUndoBeforeThePushSendsNothing() async throws {
        let store = try makeStore()
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        try await store.applyEvents([event("e1", "Design review", start: at(12, 14), response: .needsAction)], calendarID: primary.id, window: window, calendar: la)
        #expect(try await store.waitingForAnswer(now: at(9, 10), calendar: la).map(\.event.id) == ["e1"])

        let result = try #require(try await store.respond(calendarID: primary.id, eventID: "e1", response: .accepted, comment: nil, notBefore: Date().addingTimeInterval(60)))
        #expect(result.previous == .needsAction)
        #expect(try await store.event(calendarID: primary.id, id: "e1")?.selfResponse == .accepted)
        #expect(try await store.waitingForAnswer(now: at(9, 10), calendar: la).isEmpty)
        #expect(try await store.calendarOutboxCount() == 1)

        // A sync that arrives before the push keeps the local answer.
        try await store.applyEvents([event("e1", "Design review (moved)", start: at(12, 15), response: .needsAction)], calendarID: primary.id, window: window, calendar: la)
        let synced = try #require(try await store.event(calendarID: primary.id, id: "e1"))
        #expect(synced.selfResponse == .accepted)
        #expect(synced.summary == "Design review (moved)")

        #expect(try await store.revertResponse(outboxID: result.outboxID, calendarID: primary.id, eventID: "e1", previous: result.previous))
        #expect(try await store.calendarOutboxCount() == 0)
        #expect(try await store.event(calendarID: primary.id, id: "e1")?.selfResponse == .needsAction)
    }

    @Test func undoAfterThePushQueuesThePreviousAnswer() async throws {
        let store = try makeStore()
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        try await store.applyEvents([event("e1", "Design review", start: at(12, 14), response: .tentative)], calendarID: primary.id, window: window, calendar: la)
        let result = try #require(try await store.respond(calendarID: primary.id, eventID: "e1", response: .declined, comment: "Out that day", notBefore: .distantPast))
        let claimed = try #require(try await store.claimNextCalendarOperation())
        #expect(claimed.id == result.outboxID)

        #expect(try await store.revertResponse(outboxID: result.outboxID, calendarID: primary.id, eventID: "e1", previous: result.previous) == false)
        try await store.completeCalendarOperation(claimed.id)
        let items = try await store.calendarOutboxItems()
        #expect(items.count == 1)
        guard case .respond(_, "e1", .tentative, nil, _, _) = items.first?.operation else {
            Issue.record("Expected the previous answer to be queued, got \(String(describing: items.first?.operation))")
            return
        }
        #expect(try await store.event(calendarID: primary.id, id: "e1")?.selfResponse == .tentative)
    }

    @Test func eventsWithoutAnInvitationCannotBeAnswered() async throws {
        let store = try makeStore()
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        try await store.applyEvents([event("e1", "Focus", start: at(12, 9))], calendarID: primary.id, window: window, calendar: la)
        #expect(try await store.respond(calendarID: primary.id, eventID: "e1", response: .accepted, comment: nil) == nil)
    }

    @Test func localCreateEditAndRemoveCanBeUndone() async throws {
        let store = try makeStore()
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        let lunch = event("vm1lunch", "Lunch with Jamie", start: at(16, 12, 30), minutes: 60)
        let created = try await store.insertLocalEvent(lunch, sendUpdates: .all, addConference: false, notBefore: Date().addingTimeInterval(60), window: window, calendar: la)
        #expect(try await store.agenda(from: at(16, 0), to: at(17, 0), calendar: la).map(\.event.summary) == ["Lunch with Jamie"])
        #expect(try await store.revertEventChange(outboxID: created, current: lunch, restore: nil, sendUpdates: .all, window: window, calendar: la))
        #expect(try await store.agenda(from: at(16, 0), to: at(17, 0), calendar: la).isEmpty)
        #expect(try await store.calendarOutboxCount() == 0)

        try await store.applyEvents([lunch], calendarID: primary.id, window: window, calendar: la)
        var moved = lunch
        moved.start = .timed(at(16, 13), timeZone: "America/Los_Angeles")
        moved.end = .timed(at(16, 14), timeZone: "America/Los_Angeles")
        let edited = try await store.updateLocalEvent(moved, previous: lunch, sendUpdates: .all, notBefore: Date().addingTimeInterval(60), window: window, calendar: la)
        #expect(try await store.agenda(from: at(16, 0), to: at(17, 0), calendar: la).first?.start == moved.start)
        #expect(try await store.revertEventChange(outboxID: edited, current: moved, restore: lunch, sendUpdates: .all, window: window, calendar: la))
        #expect(try await store.agenda(from: at(16, 0), to: at(17, 0), calendar: la).first?.start == lunch.start)

        let removed = try await store.deleteLocalEvent(lunch, sendUpdates: .all, notBefore: Date().addingTimeInterval(60))
        #expect(try await store.agenda(from: at(16, 0), to: at(17, 0), calendar: la).isEmpty)
        #expect(try await store.revertEventChange(outboxID: removed.outboxID, current: nil, restore: lunch, sendUpdates: .all, removal: removed, window: window, calendar: la))
        #expect(try await store.agenda(from: at(16, 0), to: at(17, 0), calendar: la).count == 1)
    }

    @Test func invitationFilesAreFoundOncePerMessagePreferringTextCalendar() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([
            message("m10", thread: "t10", subject: "Invitation: Design review", attachments: [
                MailAttachment(id: "ics-app", filename: "invite.ics", mimeType: "application/ics", size: 900),
                MailAttachment(id: "ics-text", filename: "invite.ics", mimeType: "text/calendar", size: 900),
            ]),
            message("m11", thread: "t11", subject: "Outlook invite", attachments: [
                MailAttachment(id: "part:1.2", filename: "invite.ics", mimeType: "text/calendar", size: 700),
            ]),
        ])
        let candidates = try await store.invitationCandidates(limit: 10)
        #expect(Set(candidates.map(\.messageID)) == ["m10", "m11"])
        #expect(candidates.first { $0.messageID == "m10" }?.attachmentID == "ics-text")

        let invitation = Invitation(
            method: .request, uid: "review@google.com", sequence: 1, summary: "Design review",
            start: .timed(at(12, 14), timeZone: "America/Los_Angeles"), end: .timed(at(12, 14, 45), timeZone: "America/Los_Angeles")
        )
        try await store.saveInvitations([invitation], messageID: "m10", threadID: "t10")
        try await store.saveInvitations([], messageID: "m11", threadID: "t11", error: "unreadable")
        #expect(try await store.invitationCandidates(limit: 10).isEmpty)

        #expect(try await store.invitations(threadID: "t10").first?.main == invitation)
        #expect(try await store.invitations(uid: "review@google.com").map(\.messageID) == ["m10"])
        #expect(try await store.invitations(threadID: "t11").isEmpty)
        #expect(try await store.latestInvitations(threadIDs: ["t10", "t11", "t1"]).keys.sorted() == ["t10"])
    }

    @Test func eventsAreFoundByUID() async throws {
        let store = try makeStore()
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        try await store.applyEvents([event("e1", "Design review", start: at(12, 14), response: .needsAction, uid: "review@google.com")], calendarID: primary.id, window: window, calendar: la)
        #expect(try await store.events(uid: "review@google.com").map(\.id) == ["e1"])
        #expect(try await store.events(uid: "other@google.com").isEmpty)
    }

    @Test func occurrenceKeysAreStable() {
        #expect(MailStore.occurrenceKey(.timed(at(12, 14), timeZone: "America/Los_Angeles")) == "20261012T210000Z")
        #expect(MailStore.occurrenceKey(.allDay(DayDate("2026-10-12")!)) == "20261012")
    }
}

@Suite("Calendar outbox order and exact undo")
struct CalendarOutboxTests {
    private func store() async throws -> MailStore {
        let store = try makeStore()
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        return store
    }

    private func series(_ id: String, start: Date, rule: String = "RRULE:FREQ=DAILY", response: ResponseStatus? = nil) -> CalendarEvent {
        var series = event(id, "Standup", start: start, minutes: 15, response: response)
        series.recurrence = [rule]
        return series
    }

    private func occurrence(of series: CalendarEvent, day: Int, hour: Int, minute: Int = 0) -> CalendarEvent {
        let original = EventTime.timed(la.date(byAdding: .day, value: day - 5, to: series.start.instant())!, timeZone: "America/Los_Angeles")
        let start = EventTime.timed(at(day, hour, minute), timeZone: "America/Los_Angeles")
        return series.instance(originalStart: original, start: start, end: .timed(at(day, hour, minute).addingTimeInterval(900), timeZone: "America/Los_Angeles"))
    }

    @Test func operationsOnOneEventLeaveInTheOrderTheyWereMade() async throws {
        let store = try await store()
        let lunch = event("vm1lunch", "Lunch", start: at(16, 12))
        let created = try await store.insertLocalEvent(lunch, sendUpdates: .all, addConference: false, notBefore: Date().addingTimeInterval(60), window: window, calendar: la)
        var moved = lunch
        moved.summary = "Lunch (moved)"
        let edited = try await store.updateLocalEvent(moved, previous: lunch, sendUpdates: .none, window: window, calendar: la)
        try await store.applyEvents([event("e2", "Review", start: at(12, 14), response: .needsAction)], calendarID: primary.id, window: window, calendar: la)
        let answered = try #require(try await store.respond(calendarID: primary.id, eventID: "e2", response: .accepted, comment: nil))

        // The edit waits behind the create's undo window; another event's answer does not.
        #expect(try await store.claimNextCalendarOperation()?.id == answered.outboxID)
        try await store.completeCalendarOperation(answered.outboxID)
        #expect(try await store.claimNextCalendarOperation() == nil)
        let due = try #require(try await store.nextCalendarOperationDueDate())
        #expect(due > Date().addingTimeInterval(30))

        let later = Date().addingTimeInterval(61)
        #expect(try await store.claimNextCalendarOperation(now: later)?.id == created)
        // While the create is in flight, the edit still waits.
        #expect(try await store.claimNextCalendarOperation(now: later) == nil)
        try await store.completeCalendarOperation(created)
        #expect(try await store.claimNextCalendarOperation(now: later)?.id == edited)
    }

    @Test func anOccurrenceWaitsBehindItsSeries() async throws {
        let store = try await store()
        let standup = series("vm2series", start: at(5, 9, 30))
        let created = try await store.insertLocalEvent(standup, sendUpdates: .all, addConference: false, notBefore: Date().addingTimeInterval(60), window: window, calendar: la)
        let removed = try await store.deleteLocalEvent(occurrence(of: standup, day: 7, hour: 9, minute: 30), sendUpdates: .none, window: window, calendar: la)
        #expect(try await store.claimNextCalendarOperation() == nil)
        let later = Date().addingTimeInterval(61)
        #expect(try await store.claimNextCalendarOperation(now: later)?.id == created)
        try await store.completeCalendarOperation(created)
        #expect(try await store.claimNextCalendarOperation(now: later)?.id == removed.outboxID)
    }

    @Test func removingAnEventWhoseCreateWaitsSendsNothingAndUndoPutsTheCreateBack() async throws {
        let store = try await store()
        let lunch = event("vm3lunch", "Lunch with Alex", start: at(16, 12))
        let created = try await store.insertLocalEvent(lunch, sendUpdates: .all, addConference: false, notBefore: Date().addingTimeInterval(60), window: window, calendar: la)
        let removal = try await store.deleteLocalEvent(lunch, sendUpdates: .all, notBefore: Date().addingTimeInterval(60), window: window, calendar: la)
        #expect(removal.outboxID == nil)
        #expect(removal.dropped.map(\.id) == [created])
        #expect(try await store.calendarOutboxCount() == 0)
        #expect(try await store.agenda(from: at(16, 0), to: at(17, 0), calendar: la).isEmpty)

        #expect(try await store.revertEventChange(outboxID: nil, current: nil, restore: lunch, sendUpdates: .all, removal: removal, window: window, calendar: la))
        let queued = try await store.calendarOutboxItems()
        #expect(queued.map(\.id) == [created])
        guard case .insert(let event, _, _) = queued.first?.operation else {
            Issue.record("Expected the create back, got \(String(describing: queued.first?.operation))")
            return
        }
        #expect(event.id == lunch.id)
        #expect(try await store.agenda(from: at(16, 0), to: at(17, 0), calendar: la).map(\.event.id) == [lunch.id])
        // Undoing the create after that still takes it back before it leaves.
        #expect(try await store.revertEventChange(outboxID: created, current: lunch, restore: nil, sendUpdates: .all, window: window, calendar: la))
        #expect(try await store.calendarOutboxCount() == 0)
    }

    @Test func removingAnEventWhoseCreateMayHaveLeftQueuesTheRemoval() async throws {
        let store = try await store()
        let lunch = event("vm4lunch", "Lunch with Alex", start: at(16, 12))
        let created = try await store.insertLocalEvent(lunch, sendUpdates: .all, addConference: false, window: window, calendar: la)
        // Sent once; the answer was lost and the create waits to be tried again.
        #expect(try await store.claimNextCalendarOperation()?.id == created)
        try await store.retryCalendarOperation(created, error: "offline", retryAt: Date().addingTimeInterval(30))
        let removal = try await store.deleteLocalEvent(lunch, sendUpdates: .all, window: window, calendar: la)
        #expect(removal.dropped.isEmpty)
        let removed = try #require(removal.outboxID)
        #expect(try await store.calendarOutboxItems().map(\.id) == [created, removed])
    }

    @Test func aSingleEventThatStartsRepeatingIsShownOncePerDay() async throws {
        let store = try await store()
        let review = event("e1", "Review", start: at(12, 10))
        try await store.applyEvents([review], calendarID: primary.id, window: window, calendar: la)
        var weekly = review
        weekly.recurrence = ["RRULE:FREQ=WEEKLY"]
        _ = try await store.updateLocalEvent(weekly, previous: review, sendUpdates: .none, window: window, calendar: la)
        #expect(try await store.agenda(from: at(12, 0), to: at(13, 0), calendar: la).count == 1)
        #expect(try await store.agenda(from: at(19, 0), to: at(20, 0), calendar: la).count == 1)
    }

    @Test func undoingASeriesRemovalBringsBackItsChangedOccurrences() async throws {
        let store = try await store()
        let standup = series("s1", start: at(5, 9, 30))
        var skipped = occurrence(of: standup, day: 7, hour: 9, minute: 30)
        skipped.status = .cancelled
        let moved = occurrence(of: standup, day: 8, hour: 11)
        try await store.applyEvents([standup, skipped, moved], calendarID: primary.id, window: window, calendar: la)
        #expect(try await store.agenda(from: at(7, 0), to: at(8, 0), calendar: la).isEmpty)

        let removal = try await store.deleteLocalEvent(standup, sendUpdates: .all, notBefore: Date().addingTimeInterval(60), window: window, calendar: la)
        #expect(removal.exceptions.count == 2)
        #expect(try await store.agenda(from: at(8, 0), to: at(9, 0), calendar: la).isEmpty)

        #expect(try await store.revertEventChange(outboxID: removal.outboxID, current: nil, restore: standup, sendUpdates: .all, removal: removal, window: window, calendar: la))
        #expect(try await store.agenda(from: at(7, 0), to: at(8, 0), calendar: la).isEmpty)
        #expect(try await store.agenda(from: at(8, 0), to: at(9, 0), calendar: la).map(\.start) == [moved.start])
        #expect(try await store.agenda(from: at(9, 0), to: at(10, 0), calendar: la).count == 1)
    }

    @Test func undoingASeriesAnswerPutsBackEachOccurrencesOwnAnswer() async throws {
        let store = try await store()
        let standup = series("s1", start: at(5, 9, 30), response: .accepted)
        var away = occurrence(of: standup, day: 7, hour: 9, minute: 30)
        let index = try #require(away.attendees.firstIndex { $0.isSelf })
        away.attendees[index].response = .declined
        away.attendees[index].comment = "Away"
        try await store.applyEvents([standup, away], calendarID: primary.id, window: window, calendar: la)

        let answer = try #require(try await store.respond(
            calendarID: primary.id, eventID: "s1", response: .tentative, comment: nil, notBefore: Date().addingTimeInterval(60)
        ))
        #expect(try await store.event(calendarID: primary.id, id: away.id)?.selfResponse == .tentative)
        #expect(try await store.revertResponse(
            outboxID: answer.outboxID, calendarID: primary.id, eventID: "s1", previous: answer.previous, saved: answer.saved, window: window, calendar: la
        ))
        let restored = try #require(try await store.event(calendarID: primary.id, id: away.id))
        #expect(restored.selfResponse == .declined)
        #expect(restored.selfAttendee?.comment == "Away")
        #expect(try await store.event(calendarID: primary.id, id: "s1")?.selfResponse == .accepted)
    }

    @Test func undoOnAnOccurrenceOfASeriesOnlyGoogleExpandsKeepsTheOccurrence() async throws {
        let store = try await store()
        var standup = series("s1", start: at(5, 9, 30), rule: "RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", response: .accepted)
        standup.end = .timed(at(5, 9, 45), timeZone: "America/Los_Angeles")
        #expect(try await store.applyEvents([standup], calendarID: primary.id, window: window, calendar: la) == ["s1"])
        let last = occurrence(of: standup, day: 30, hour: 9, minute: 30)
        var provided = last
        provided.id = "s1_20261030T163000Z"
        try await store.applyInstances([provided], calendarID: primary.id, seriesID: "s1", calendar: la)
        #expect(try await store.agenda(from: at(30, 0), to: at(31, 0), calendar: la).count == 1)

        // Answer that day alone (stored as an exception first), then take it back before it leaves.
        try await store.storeLocalEvent(last, window: window, calendar: la)
        let answer = try #require(try await store.respond(
            calendarID: primary.id, eventID: last.id, response: .declined, comment: nil, notBefore: Date().addingTimeInterval(60)
        ))
        #expect(try await store.revertResponse(
            outboxID: answer.outboxID, calendarID: primary.id, eventID: last.id, previous: answer.previous, saved: answer.saved,
            dropException: true, window: window, calendar: la
        ))
        let day = try await store.agenda(from: at(30, 0), to: at(31, 0), calendar: la)
        #expect(day.map(\.event.id) == ["s1"])
        #expect(day.first?.start == last.start)
        #expect(day.first?.end == last.end)
    }
}

@Suite("Invitation search")
struct InvitationSearchTests {
    @Test func searchFindsInvitationsByKindAndAnswer() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([
            message("i1", thread: "ti1", subject: "Invitation: Design review"),
            message("i2", thread: "ti2", subject: "Updated invitation: Design review"),
            message("i3", thread: "ti3", subject: "Accepted: Weekly sync"),
        ])
        let start = EventTime.timed(Date().addingTimeInterval(86_400), timeZone: nil)
        try await store.saveInvitations([Invitation(method: .request, uid: "review", summary: "Design review", start: start)], messageID: "i1", threadID: "ti1")
        try await store.saveInvitations([Invitation(method: .request, uid: "review", sequence: 1, summary: "Design review", start: start)], messageID: "i2", threadID: "ti2")
        try await store.saveInvitations([Invitation(method: .reply, uid: "sync", summary: "Weekly sync", start: start)], messageID: "i3", threadID: "ti3")
        let calendar = CalendarInfo(id: "sam@studionorth.co", summary: "Sam", isPrimary: true)
        try await store.applyCalendarList([calendar], removed: [], replaceAll: true)
        try await store.applyEvents([CalendarEvent(
            id: "e1", calendarID: calendar.id, iCalUID: "review", summary: "Design review", start: start, end: start,
            attendees: [Attendee(email: "sam@studionorth.co", response: .needsAction, isSelf: true)]
        )], calendarID: calendar.id, window: CalendarWindow.around(Date()))

        func ids(_ text: String) async throws -> [String] {
            try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: SearchQuery.parse(text))).map(\.id).sorted()
        }
        #expect(try await ids("has:invite") == ["ti1", "ti2", "ti3"])
        #expect(try await ids("invite:request") == ["ti1"])
        #expect(try await ids("invite:update") == ["ti2"])
        #expect(try await ids("invite:reply") == ["ti3"])
        #expect(try await ids("invite:pending") == ["ti1", "ti2"])
        _ = try await store.respond(calendarID: calendar.id, eventID: "e1", response: .accepted, comment: nil)
        #expect(try await ids("invite:pending").isEmpty)
    }

    @Test func conflictFindsInvitationsThatOverlapYourEvents() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([message("c1", thread: "tc1", subject: "Invitation: Review"), message("c2", thread: "tc2", subject: "Invitation: Lunch")])
        let base = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))!
        func at(_ hour: Int) -> EventTime { .timed(base.addingTimeInterval(TimeInterval(hour * 3600)), timeZone: nil) }
        try await store.saveInvitations([Invitation(method: .request, uid: "review", summary: "Review", start: at(14))], messageID: "c1", threadID: "tc1")
        try await store.saveInvitations([Invitation(method: .request, uid: "lunch", summary: "Lunch", start: at(12))], messageID: "c2", threadID: "tc2")
        let calendar = CalendarInfo(id: "sam@studionorth.co", summary: "Sam", isPrimary: true)
        try await store.applyCalendarList([calendar], removed: [], replaceAll: true)
        let me = Attendee(email: "sam@studionorth.co", response: .needsAction, isSelf: true)
        try await store.applyEvents([
            CalendarEvent(id: "review", calendarID: calendar.id, iCalUID: "review", summary: "Review", start: at(14), end: at(15), attendees: [me]),
            CalendarEvent(id: "lunch", calendarID: calendar.id, iCalUID: "lunch", summary: "Lunch", start: at(12), end: at(13), attendees: [me]),
            CalendarEvent(id: "sync", calendarID: calendar.id, summary: "Sync", start: at(14), end: at(15)),
            // Time marked free does not count.
            CalendarEvent(id: "focus", calendarID: calendar.id, summary: "Focus", start: at(12), end: at(13), isBusy: false),
        ], calendarID: calendar.id, window: CalendarWindow.around(Date()))
        let found = try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: SearchQuery.parse("invite:conflict"))).map(\.id)
        #expect(found == ["tc1"])
    }

    @Test func organizerMeFindsYourEventsAndYourGuestsAnswers() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([
            message("o1", thread: "to1", subject: "Invitation: Studio sync"),
            message("o2", thread: "to2", from: nina, subject: "Accepted: Studio sync"),
            message("o3", thread: "to3", subject: "Invitation: Design review"),
            message("o4", thread: "to4", from: nina, subject: "Declined: Design review"),
        ])
        let start = EventTime.timed(Date().addingTimeInterval(86_400), timeZone: nil)
        // You organize the sync (the file writes your address in capitals); Jamie organizes the review.
        let sam = Attendee(email: "Sam@StudioNorth.co", name: "Sam Carter", response: .accepted, isOrganizer: true)
        let jamie = Attendee(email: "jamie@studionorth.co", name: "Jamie Chen", response: .accepted, isOrganizer: true)
        let answer = [Attendee(email: nina.email, name: nina.name, response: .accepted)]
        try await store.saveInvitations([Invitation(method: .request, uid: "sync", summary: "Studio sync", start: start, organizer: sam)], messageID: "o1", threadID: "to1")
        try await store.saveInvitations(
            [Invitation(method: .reply, uid: "sync", summary: "Studio sync", start: start, organizer: sam, attendees: answer)], messageID: "o2", threadID: "to2"
        )
        try await store.saveInvitations([Invitation(method: .request, uid: "review", summary: "Design review", start: start, organizer: jamie)], messageID: "o3", threadID: "to3")
        try await store.saveInvitations(
            [Invitation(method: .reply, uid: "review", summary: "Design review", start: start, organizer: jamie, attendees: answer)], messageID: "o4", threadID: "to4"
        )

        func query(_ text: String) -> ThreadQuery { ThreadQuery(scope: .anywhere).narrowed(by: SearchQuery.parse(text)) }
        func ids(_ text: String) async throws -> [String] { try await store.threads(query(text)).map(\.id).sorted() }
        #expect(try await ids("organizer:me") == ["to1", "to2"])
        #expect(try await ids("invite:reply organizer:me") == ["to2"])
        #expect(try await ids("organizer:me invite:request") == ["to1"])
        #expect(try await store.count(query("organizer:me")) == 2)
        #expect(try await store.counts(["mine": query("organizer:me"), "answers": query("invite:reply organizer:me")]) == ["mine": 2, "answers": 1])

        // Without an account there is no "me".
        let unknown = try makeStore()
        try await unknown.upsertMessages([message("o1", thread: "to1", subject: "Invitation: Studio sync")])
        try await unknown.saveInvitations([Invitation(method: .request, uid: "sync", summary: "Studio sync", start: start, organizer: sam)], messageID: "o1", threadID: "to1")
        #expect(try await unknown.threads(query("organizer:me")).isEmpty)
    }

    @Test func eventsOnlyInMailBringTheirMovedAndCancelledDates() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([
            message("s1", thread: "ts1", subject: "Invitation: Weekly sync", minutesAgo: 300),
            message("s2", thread: "ts2", subject: "Updated invitation: Weekly sync @ Tue Oct 13", labels: ["TRASH"], minutesAgo: 200),
            message("s3", thread: "ts3", subject: "Canceled event: Weekly sync @ Mon Oct 19", labels: ["TRASH"], minutesAgo: 100),
            message("s4", thread: "ts4", subject: "Invitation: Lunch", minutesAgo: 50),
            message("s5", thread: "ts5", subject: "Canceled event: Retro @ Mon Oct 19", minutesAgo: 40),
        ])
        func time(_ date: Date) -> EventTime { .timed(date, timeZone: "America/Los_Angeles") }
        // Mondays 9:00 from Oct 5; Oct 12 moved to Tuesday, Oct 19 cancelled.
        let weekly = Invitation(method: .request, uid: "weekly", summary: "Weekly sync", start: time(at(5, 9)), end: time(at(5, 9, 30)), recurrence: ["RRULE:FREQ=WEEKLY"])
        let moved = Invitation(method: .request, uid: "weekly", sequence: 1, recurrenceID: time(at(12, 9)), summary: "Weekly sync", start: time(at(13, 9)), end: time(at(13, 9, 30)))
        let cancelled = Invitation(method: .cancel, uid: "weekly", sequence: 1, recurrenceID: time(at(19, 9)), summary: "Weekly sync", start: time(at(19, 9)))
        let lunch = Invitation(method: .request, uid: "lunch", summary: "Lunch", start: time(at(14, 12)), end: time(at(14, 13)))
        // A cancelled date of an event whose invitation is not in the mail.
        let retro = Invitation(method: .cancel, uid: "retro", sequence: 1, recurrenceID: time(at(19, 16)), summary: "Retro", start: time(at(19, 16)))
        for (index, invitation) in [weekly, moved, cancelled, lunch, retro].enumerated() {
            try await store.saveInvitations([invitation], messageID: "s\(index + 1)", threadID: "ts\(index + 1)")
        }

        let events = try await store.mailOnlyEvents()
        #expect(events.map(\.uid).sorted() == ["lunch", "weekly"])
        let series = try #require(events.first { $0.uid == "weekly" })
        #expect(series.main == weekly)
        // The move and the cancellation count though their mail is in Trash: binning an update does not undo it.
        #expect(series.dates(from: at(9, 0), to: at(23, 0), calendar: la).map(\.start) == [time(at(13, 9))])
        #expect(try await store.invitedEvent(uid: "lunch").main == lunch)
        // An event that does not wait still has its mail, for its page; the retro has only a cancelled date.
        #expect(try await store.invitedEvent(uid: "retro").dates(from: at(9, 0), to: at(23, 0), calendar: la).isEmpty)
        #expect(try await store.invitedEvent(uid: "unknown") == InvitedEvent([]))

        // Once the event is on the calendar, it is no longer only in mail.
        try await store.applyCalendarList([primary], removed: [], replaceAll: true)
        try await store.applyEvents([event("e1", "Weekly sync", start: at(5, 9), uid: "weekly")], calendarID: primary.id, window: window, calendar: la)
        #expect(try await store.mailOnlyEvents().map(\.uid) == ["lunch"])
    }

    @Test func eventsOnlyInMailFollowTheirNewestUpdateButNotSpam() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([
            message("n1", thread: "tn1", subject: "Invitation: Design sync", minutesAgo: 300),
            message("n2", thread: "tn2", subject: "Updated invitation: Design sync", labels: ["TRASH"], minutesAgo: 200),
            message("n3", thread: "tn3", subject: "Updated invitation: Design sync", labels: ["SPAM"], minutesAgo: 100),
            message("n4", thread: "tn4", subject: "Canceled event: Design sync @ Thu Oct 15", labels: ["SPAM"], minutesAgo: 50),
            message("n5", thread: "tn5", subject: "Invitation: Offsite", labels: ["TRASH"], minutesAgo: 40),
        ])
        func time(_ date: Date) -> EventTime { .timed(date, timeZone: "America/Los_Angeles") }
        // Thursdays 10:00 from Oct 1, moved to 11:00 by an update you binned. Mail in Spam that says 23:00 changes nothing.
        let sync = Invitation(
            method: .request, uid: "sync", summary: "Design sync", start: time(at(1, 10)), end: time(at(1, 10, 30)), recurrence: ["RRULE:FREQ=WEEKLY"]
        )
        var later = sync
        later.sequence = 1
        later.start = time(at(1, 11))
        later.end = time(at(1, 11, 30))
        var spam = sync
        spam.sequence = 5
        spam.start = time(at(1, 23))
        spam.end = time(at(1, 23, 30))
        spam.conferenceURL = "https://example.com/join"
        let off = Invitation(method: .cancel, uid: "sync", sequence: 1, recurrenceID: time(at(15, 11)), summary: "Design sync", start: time(at(15, 11)))
        let offsite = Invitation(method: .request, uid: "offsite", summary: "Offsite", start: time(at(20, 9)), end: time(at(20, 17)))
        for (index, invitation) in [sync, later, spam, off, offsite].enumerated() {
            try await store.saveInvitations([invitation], messageID: "n\(index + 1)", threadID: "tn\(index + 1)")
        }

        let events = try await store.mailOnlyEvents()
        // The offsite's only invitation is binned: it does not wait, but its page still reads it.
        #expect(events.map(\.uid) == ["sync"])
        #expect(try await store.invitedEvent(uid: "offsite").main == offsite)
        // Oct 15 is cancelled: a cancellation counts wherever its mail is.
        let dates = try #require(events.first).dates(from: at(9, 0), to: at(23, 0), calendar: la)
        #expect(dates.map(\.start) == [time(at(22, 11))])
        #expect(dates.first?.invitation == later)
        #expect(try await store.invitedEvent(uid: "sync") == events.first)
    }

    @Test func cancelledAndBinnedInvitationsAreNotWaiting() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([
            message("w1", thread: "tw1", subject: "Invitation: Review"),
            message("w2", thread: "tw1", subject: "Canceled: Review"),
            message("w3", thread: "tw3", subject: "Invitation: Spam", labels: ["TRASH"]),
            message("w4", thread: "tw4", subject: "Invitation: Weekly"),
            message("w5", thread: "tw4", subject: "Canceled: Weekly on Oct 20"),
            message("w6", thread: "tw6", subject: "Invitation: Lunch"),
        ])
        let start = EventTime.timed(Date().addingTimeInterval(86_400), timeZone: nil)
        try await store.saveInvitations([Invitation(method: .request, uid: "review", summary: "Review", start: start)], messageID: "w1", threadID: "tw1")
        try await store.saveInvitations([Invitation(method: .cancel, uid: "review", sequence: 1, summary: "Review", start: start)], messageID: "w2", threadID: "tw1")
        try await store.saveInvitations([Invitation(method: .request, uid: "spam", summary: "Spam", start: start)], messageID: "w3", threadID: "tw3")
        try await store.saveInvitations([Invitation(method: .request, uid: "weekly", summary: "Weekly", start: start)], messageID: "w4", threadID: "tw4")
        // Cancelling one occurrence keeps the series waiting.
        try await store.saveInvitations([Invitation(
            method: .cancel, uid: "weekly", sequence: 1, recurrenceID: .timed(Date().addingTimeInterval(8 * 86_400), timeZone: nil), summary: "Weekly", start: start
        )], messageID: "w5", threadID: "tw4")
        try await store.saveInvitations([Invitation(method: .request, uid: "lunch", summary: "Lunch", start: start)], messageID: "w6", threadID: "tw6")
        let waiting = try await store.invitationsWithoutEvents().compactMap(\.main?.uid)
        #expect(Set(waiting) == ["weekly", "lunch"])
    }

    @Test func invitationsToMeetingsTheSyncRemovedStopWaiting() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([message("r1", thread: "tr1", subject: "Invitation: Review"), message("r2", thread: "tr2", subject: "Invitation: Review (again)")])
        let start = EventTime.timed(Date().addingTimeInterval(2 * 86_400), timeZone: nil)
        let calendar = CalendarInfo(id: "sam@studionorth.co", summary: "Sam", isPrimary: true)
        try await store.applyCalendarList([calendar], removed: [], replaceAll: true)
        let me = Attendee(email: "sam@studionorth.co", response: .needsAction, isSelf: true)
        var review = CalendarEvent(id: "e1", calendarID: calendar.id, iCalUID: "review", summary: "Review", start: start, end: start, attendees: [me])
        review.sequence = 1
        try await store.applyEvents([review], calendarID: calendar.id, window: CalendarWindow.around(Date()))
        try await store.saveInvitations([Invitation(method: .request, uid: "review", sequence: 1, summary: "Review", start: start)], messageID: "r1", threadID: "tr1")
        #expect(try await store.invitationsWithoutEvents().isEmpty)

        // The organizer deletes it without telling anyone: Google's removal carries only the ID.
        var removed = CalendarEvent(id: "e1", calendarID: calendar.id, summary: "", start: start, end: start)
        removed.status = .cancelled
        try await store.applyEvents([removed], calendarID: calendar.id, window: CalendarWindow.around(Date()))
        #expect(try await store.invitationsWithoutEvents().isEmpty)

        // A newer invitation for the same meeting waits again.
        try await store.saveInvitations([Invitation(method: .request, uid: "review", sequence: 2, summary: "Review", start: start)], messageID: "r2", threadID: "tr2")
        #expect(try await store.invitationsWithoutEvents().map(\.messageID) == ["r2"])
    }
}
