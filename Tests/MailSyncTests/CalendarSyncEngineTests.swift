import Foundation
import Testing
@testable import DummyProvider
@testable import MailCore
@testable import MailStore
@testable import MailSync

private let sam = EmailAddress(name: "Sam Carter", email: "sam@hey.com")

struct CalendarHarness {
    let directory: URL
    let provider: DummyCalendarProvider
    let store: MailStore
    let engine: CalendarSyncEngine
    let actions: CalendarActions

    init(invites: [DummyInvite] = []) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-calendar-\(UUID().uuidString)")
        var configuration = DummyCalendarProvider.Configuration()
        configuration.latency = 0...0
        provider = DummyCalendarProvider(directory: directory.appendingPathComponent("dummy"), account: sam, configuration: configuration, invitations: { invites })
        store = try MailStore(url: directory.appendingPathComponent("mail.sqlite"))
        engine = CalendarSyncEngine(provider: provider, store: store, pollInterval: .seconds(3600))
        actions = CalendarActions(store: store)
    }

    var nextMonday: Date { DummyGenerator.nextMonday(after: Date(), hour: 0, calendar: .current) }

    func day(_ start: Date) async throws -> [AgendaItem] {
        try await store.agenda(from: start, to: Calendar.current.date(byAdding: .day, value: 1, to: start)!)
    }

    func primaryEvent(named summary: String) async throws -> CalendarEvent {
        let page = try await provider.events(calendarID: sam.email, syncToken: nil, pageToken: nil, timeMin: nil)
        return try #require(page.events.first { $0.summary == summary })
    }
}

private func designReview(on monday: Date) -> DummyInvite {
    DummyInvite(
        uid: "design-review@vimail.dummy", messageID: "m-invite", title: "Design review",
        start: Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: monday)!, minutes: 45,
        organizer: EmailAddress(name: "Jamie Chen", email: "jamie.chen@studio.co"),
        guests: [EmailAddress(name: "Jamie Chen", email: "jamie.chen@studio.co"), sam], accepted: [], conference: nil, agenda: nil, sequence: 0, sent: Date()
    )
}

@Suite("Calendar sync engine with the dummy calendar", .serialized)
struct CalendarSyncEngineTests {
    @Test func firstSyncDownloadsCalendarsAndEvents() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let calendars = try await harness.store.calendars()
        #expect(calendars.first?.id == sam.email && calendars.first?.isPrimary == true)
        #expect(calendars.contains { $0.summary == "Holidays in United States" && !$0.canEdit })

        let monday = try await harness.day(harness.nextMonday).map(\.event.summary)
        #expect(monday.contains("Portfolio planning"))
        #expect(monday.contains("Lumen check-in"))
    }

    @Test func mailboxInvitationsArriveAndAnswersReachTheProvider() async throws {
        let harness = try await CalendarHarness(invites: [designReview(on: try await CalendarHarness().nextMonday)])
        #expect(await harness.engine.cycle())
        let waiting = try await harness.store.waitingForAnswer()
        let review = try #require(waiting.first { $0.event.summary == "Design review" })
        #expect(review.event.iCalUID == "design-review@vimail.dummy")

        let record = try #require(try await harness.actions.answer(calendarID: review.calendarID, eventID: review.event.id, response: .accepted, comment: "Yes", undoWindow: 0))
        #expect(record.previous == .needsAction)
        #expect(try await harness.store.waitingForAnswer().contains { $0.event.summary == "Design review" } == false)
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.calendarOutboxCount() == 0)
        let remote = try #require(try await harness.provider.event(calendarID: review.calendarID, eventID: review.event.id))
        #expect(remote.selfResponse == .accepted)
        #expect(remote.selfAttendee?.comment == "Yes")
    }

    @Test func oneOccurrenceChangesAndGoesAlone() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let calendar = Calendar.current
        let zone = TimeZone.current.identifier
        let monday = harness.nextMonday
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: monday)! }
        let first = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: monday)!
        let series = CalendarEvent(
            id: CalendarActions.newEventID(), calendarID: sam.email, summary: "Morning review",
            start: .timed(first, timeZone: zone), end: .timed(first.addingTimeInterval(900), timeZone: zone), recurrence: ["RRULE:FREQ=DAILY;COUNT=5"]
        )
        _ = try await harness.actions.create(series, sendUpdates: .none, addConference: false, undoWindow: 0)
        #expect(await harness.engine.cycle())

        func occurrence(_ offset: Int) async throws -> CalendarEvent {
            let item = try #require(try await harness.day(day(offset)).first { $0.event.summary == "Morning review" })
            let stored = try #require(try await harness.store.event(calendarID: sam.email, id: series.id))
            return stored.instance(originalStart: try #require(EventTime(occurrenceKey: item.originalStart, timeZone: zone)), start: item.start, end: item.end)
        }
        // Tuesday moves to 10:00 with a new title; Wednesday is removed.
        let tuesday = try await occurrence(1)
        var moved = tuesday
        let ten = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day(1))!
        moved.start = .timed(ten, timeZone: zone)
        moved.end = .timed(ten.addingTimeInterval(900), timeZone: zone)
        moved.summary = "Morning review (moved)"
        let edit = try await harness.actions.update(moved, from: tuesday, sendUpdates: .none, undoWindow: 0)
        #expect(edit.madeException)
        let removal = try await harness.actions.remove(try await occurrence(2), sendUpdates: .none, undoWindow: 0)

        func check() async throws {
            let onTuesday = try await harness.day(day(1)).filter { $0.event.summary.hasPrefix("Morning review") }
            #expect(onTuesday.map(\.event.summary) == ["Morning review (moved)"])
            #expect(onTuesday.first?.start.instant() == ten)
            #expect(try await harness.day(day(2)).contains { $0.event.summary.hasPrefix("Morning review") } == false)
            for offset in [0, 3, 4] {
                #expect(try await harness.day(day(offset)).contains { $0.event.summary == "Morning review" })
            }
        }
        try await check()
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.calendarOutboxCount() == 0)
        try await check()
        let remote = try #require(try await harness.provider.event(calendarID: sam.email, eventID: series.id))
        #expect(remote.summary == "Morning review" && remote.isSeries)
        #expect(try await harness.provider.event(calendarID: sam.email, eventID: moved.id)?.summary == "Morning review (moved)")

        // Undo after it left: Wednesday comes back on Google too.
        try await harness.actions.undo(removal)
        #expect(try await harness.day(day(2)).contains { $0.event.summary == "Morning review" })
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.calendarOutboxCount() == 0)
        let wednesday = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: day(2))!
        #expect(try await harness.provider.event(calendarID: sam.email, eventID: "\(series.id)_\(EventTime.timed(wednesday, timeZone: nil).occurrenceKey)") != nil)
        #expect(try await harness.day(day(2)).contains { $0.event.summary == "Morning review" })
    }

    @Test func undoOfAnOccurrenceChangeThatNeverLeftLeavesNoException() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let zone = TimeZone.current.identifier
        let monday = harness.nextMonday
        let first = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: monday)!
        let series = CalendarEvent(
            id: CalendarActions.newEventID(), calendarID: sam.email, summary: "Morning review",
            start: .timed(first, timeZone: zone), end: .timed(first.addingTimeInterval(900), timeZone: zone), recurrence: ["RRULE:FREQ=DAILY;COUNT=3"]
        )
        _ = try await harness.actions.create(series, sendUpdates: .none, addConference: false, undoWindow: 0)
        let instance = series.instance(originalStart: series.start, start: series.start, end: series.end)
        var renamed = instance
        renamed.summary = "Renamed once"
        let record = try await harness.actions.update(renamed, from: instance, sendUpdates: .all, undoWindow: 60)
        #expect(try await harness.day(monday).map(\.event.summary).contains("Renamed once"))
        #expect(try await harness.actions.undo(record))
        #expect(try await harness.store.event(calendarID: sam.email, id: instance.id) == nil)
        #expect(try await harness.day(monday).map(\.event.summary).contains("Morning review"))
    }

    @Test func undoInsideTheWindowSendsNothing() async throws {
        let harness = try await CalendarHarness(invites: [designReview(on: try await CalendarHarness().nextMonday)])
        #expect(await harness.engine.cycle())
        let review = try #require(try await harness.store.waitingForAnswer().first)
        let record = try #require(try await harness.actions.answer(calendarID: review.calendarID, eventID: review.event.id, response: .declined, undoWindow: 60))
        try await harness.actions.undo(record)
        #expect(await harness.engine.cycle())
        #expect(try await harness.provider.event(calendarID: review.calendarID, eventID: review.event.id)?.selfResponse == .needsAction)
        #expect(try await harness.store.waitingForAnswer().map(\.event.id) == [review.event.id])
    }

    @Test func undoAfterThePushSendsThePreviousAnswer() async throws {
        let harness = try await CalendarHarness(invites: [designReview(on: try await CalendarHarness().nextMonday)])
        #expect(await harness.engine.cycle())
        let review = try #require(try await harness.store.waitingForAnswer().first)
        let record = try #require(try await harness.actions.answer(calendarID: review.calendarID, eventID: review.event.id, response: .tentative, undoWindow: 0))
        #expect(await harness.engine.cycle())
        #expect(try await harness.provider.event(calendarID: review.calendarID, eventID: review.event.id)?.selfResponse == .tentative)
        try await harness.actions.undo(record)
        #expect(await harness.engine.cycle())
        #expect(try await harness.provider.event(calendarID: review.calendarID, eventID: review.event.id)?.selfResponse == .needsAction)
    }

    @Test func expiredSyncTokenDownloadsTheCalendarAgain() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let lumen = try await harness.primaryEvent(named: "Lumen check-in")
        try await harness.provider.expireSyncTokens()
        try await harness.provider.organizerChange(calendarID: sam.email, eventID: lumen.id) { $0.summary = "Lumen check-in (moved)" }
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.event(calendarID: sam.email, id: lumen.id)?.summary == "Lumen check-in (moved)")
        #expect(try await harness.day(harness.nextMonday).contains { $0.event.summary == "Portfolio planning" })
    }

    @Test func aRetriedCreateDoesNotMakeASecondEvent() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let start = Calendar.current.date(bySettingHour: 12, minute: 30, second: 0, of: harness.nextMonday)!
        let lunch = CalendarEvent(
            id: CalendarActions.newEventID(), calendarID: sam.email, summary: "Lunch with Jamie",
            start: .timed(start, timeZone: TimeZone.current.identifier), end: .timed(start.addingTimeInterval(3600), timeZone: TimeZone.current.identifier)
        )
        _ = try await harness.actions.create(lunch, sendUpdates: .all, addConference: false, undoWindow: 0)
        // An earlier attempt reached the provider before the app lost the answer.
        _ = try await harness.provider.insert(lunch, sendUpdates: .all, addConference: false)
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.calendarOutboxCount() == 0)
        let page = try await harness.provider.events(calendarID: sam.email, syncToken: nil, pageToken: nil, timeMin: nil)
        #expect(page.events.filter { $0.summary == "Lunch with Jamie" }.count == 1)
        #expect(try await harness.day(harness.nextMonday).filter { $0.event.summary == "Lunch with Jamie" }.count == 1)
    }

    @Test func undoOfAPushedRemovalBringsTheEventBack() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let call = try #require(try await harness.store.events(uid: try await harness.primaryEvent(named: "Typeface licensing call").iCalUID ?? "").first)
        let record = try await harness.actions.remove(call, sendUpdates: .all, undoWindow: 0)
        #expect(await harness.engine.cycle())
        #expect(try await harness.provider.event(calendarID: sam.email, eventID: call.id) == nil)
        try await harness.actions.undo(record)
        #expect(await harness.engine.cycle())
        #expect(try await harness.provider.event(calendarID: sam.email, eventID: call.id)?.status == .confirmed)
        #expect(try await harness.store.event(calendarID: sam.email, id: call.id) != nil)
    }

    @Test func anEditMergesWithAnOrganizerChangeToOtherFields() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let stored = try #require(try await harness.store.event(calendarID: sam.email, id: try await harness.primaryEvent(named: "Typeface licensing call").id))
        try await harness.provider.organizerChange(calendarID: sam.email, eventID: stored.id) { $0.summary = "Typeface licensing" }
        var edited = stored
        edited.location = "Studio, room 2"
        _ = try await harness.actions.update(edited, from: stored, sendUpdates: .all, undoWindow: 0)
        #expect(await harness.engine.cycle())
        let remote = try #require(try await harness.provider.event(calendarID: sam.email, eventID: stored.id))
        #expect(remote.summary == "Typeface licensing")
        #expect(remote.location == "Studio, room 2")
    }

    @Test func aConflictingEditKeepsTheProviderVersionAndSaysSo() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let stored = try #require(try await harness.store.event(calendarID: sam.email, id: try await harness.primaryEvent(named: "Typeface licensing call").id))
        try await harness.provider.organizerChange(calendarID: sam.email, eventID: stored.id) { $0.summary = "Their title" }
        var edited = stored
        edited.summary = "My title"
        _ = try await harness.actions.update(edited, from: stored, sendUpdates: .all, undoWindow: 0)
        var events = harness.engine.events.makeAsyncIterator()
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.event(calendarID: sam.email, id: stored.id)?.summary == "Their title")
        guard case .operationFailed(let message) = await events.next() else { Issue.record("Expected a failure event"); return }
        #expect(message.contains("changed in Google Calendar"))
    }

    @Test func aRefusedCreateIsUndoneLocally() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: harness.nextMonday)!
        let bad = CalendarEvent(id: "BAD!", calendarID: sam.email, summary: "Bad", start: .timed(start, timeZone: nil), end: .timed(start.addingTimeInterval(600), timeZone: nil))
        _ = try await harness.actions.create(bad, sendUpdates: .none, addConference: false, undoWindow: 0)
        #expect(try await harness.day(harness.nextMonday).contains { $0.event.id == "BAD!" })
        #expect(await harness.engine.cycle())
        #expect(try await harness.day(harness.nextMonday).contains { $0.event.id == "BAD!" } == false)
        #expect(try await harness.store.calendarOutboxCount() == 0)
    }

    @Test func anEditQueuedBehindARefusedCreateGoesWithIt() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: harness.nextMonday)!
        let bad = CalendarEvent(id: "BAD!", calendarID: sam.email, summary: "Bad", start: .timed(start, timeZone: nil), end: .timed(start.addingTimeInterval(600), timeZone: nil))
        _ = try await harness.actions.create(bad, sendUpdates: .none, addConference: false, undoWindow: 0)
        var moved = bad
        moved.summary = "Bad (moved)"
        _ = try await harness.actions.update(moved, from: bad, sendUpdates: .none, undoWindow: 0)
        #expect(await harness.engine.cycle())
        #expect(try await harness.day(harness.nextMonday).contains { $0.event.id == "BAD!" } == false)
        #expect(try await harness.store.calendarOutboxCount() == 0)
    }

    @Test func aGuestChangeMergesWithAnswersGivenMeanwhile() {
        let me = Attendee(email: "sam@hey.com", response: .accepted, isSelf: true, isOrganizer: true)
        let jamie = Attendee(email: "jamie@studio.co", response: .needsAction)
        let alex = Attendee(email: "alex@studio.co", response: .needsAction)
        let priya = Attendee(email: "priya@studio.co")
        var answered = jamie
        answered.response = .accepted
        answered.comment = "See you there"
        let nina = Attendee(email: "nina@studio.co")
        // You added Priya and removed Alex; meanwhile Jamie accepted and the organizer's copy gained Nina.
        let merged = CalendarSyncEngine.mergeGuests(edit: [me, jamie, priya], base: [me, jamie, alex], current: [me, answered, alex, nina])
        #expect(merged == [me, answered, nina, priya])

        var base = CalendarEvent(id: "e1", calendarID: "sam@hey.com", summary: "Review", start: .allDay(DayDate("2026-10-12")!), end: .allDay(DayDate("2026-10-13")!))
        base.attendees = [me, jamie, alex]
        var edit = base
        edit.attendees = [me, jamie, priya]
        var current = base
        current.attendees = [me, answered, alex]
        current.etag = "\"2\""
        #expect(CalendarSyncEngine.merge(edit: edit, base: base, current: current)?.attendees == [me, answered, priya])
    }

    @Test func eventIDsUseGooglesAlphabet() {
        let id = CalendarActions.newEventID()
        #expect(id.count == 26)
        #expect(id.allSatisfy { "0123456789abcdefghijklmnopqrstuv".contains($0) })
    }
}

@Suite("Invitations from mail to the calendar", .serialized)
struct InvitationFlowTests {
    @Test func aDummyInvitationIsReadMatchedToItsEventAndAnswered() async throws {
        let mail = try await Harness()
        #expect(await mail.engine.cycle())
        let indexer = InvitationIndexer(store: mail.store, provider: mail.provider)
        await indexer.drain()

        // The showcase invitation: its file was read, with the guests and the time the mail shows.
        let candidates = try await mail.store.threads(.mailbox(.inbox)).filter { $0.subject.hasPrefix("Invitation: Design review") }
        let thread = try #require(candidates.first)
        let file = try #require(try await mail.store.invitations(threadID: thread.id).last)
        let invitation = try #require(file.main)
        #expect(invitation.method == .request)
        #expect(invitation.summary == "Design review")
        #expect(invitation.organizer?.name == "Jamie Chen")
        #expect(invitation.attendees.contains { $0.email == "sam@hey.com" && $0.response == .needsAction })
        #expect(invitation.conferenceURL == "https://meet.example.com/482-studio")
        #expect(Calendar.current.component(.hour, from: invitation.start.instant()) == 14)

        // The dummy calendar adds it like Google does, and the answer reaches it.
        var configuration = DummyCalendarProvider.Configuration()
        configuration.latency = 0...0
        let provider = mail.provider
        let calendarProvider = DummyCalendarProvider(directory: mail.directory.appendingPathComponent("calendar"), configuration: configuration) {
            (try? await provider.invites()) ?? []
        }
        let calendarEngine = CalendarSyncEngine(provider: calendarProvider, store: mail.store, pollInterval: .seconds(3600))
        #expect(await calendarEngine.cycle())
        let actions = CalendarActions(store: mail.store)
        let event = try #require(try await actions.event(for: invitation))
        #expect(event.selfResponse == .needsAction)
        _ = try #require(try await actions.answer(calendarID: event.calendarID, eventID: event.id, response: .accepted, undoWindow: 0))
        #expect(await calendarEngine.cycle())
        #expect(try await calendarProvider.event(calendarID: event.calendarID, eventID: event.id)?.selfResponse == .accepted)
    }
}
