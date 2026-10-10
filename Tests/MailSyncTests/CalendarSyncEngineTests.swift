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

    @Test func thisAndFollowingSplitsTheSeriesOnTheProviderAndUndoJoinsItAgain() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let calendar = Calendar.current
        let zone = TimeZone.current.identifier
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: harness.nextMonday)! }
        func time(_ offset: Int, _ hour: Int) -> Date { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day(offset))! }
        func quarter(_ start: Date) -> (EventTime, EventTime) { (.timed(start, timeZone: zone), .timed(start.addingTimeInterval(900), timeZone: zone)) }
        let series = CalendarEvent(
            id: CalendarActions.newEventID(), calendarID: sam.email, summary: "Morning review",
            start: quarter(time(0, 8)).0, end: quarter(time(0, 8)).1, recurrence: ["RRULE:FREQ=DAILY;COUNT=10"]
        )
        _ = try await harness.actions.create(series, sendUpdates: .none, addConference: false, undoWindow: 0)
        #expect(await harness.engine.cycle())
        // The sixth day moves to 11:00 on its own.
        let stored = try #require(try await harness.store.event(calendarID: sam.email, id: series.id))
        let sixth = stored.instance(originalStart: quarter(time(5, 8)).0, start: quarter(time(5, 8)).0, end: quarter(time(5, 8)).1)
        var moved = sixth
        (moved.start, moved.end) = quarter(time(5, 11))
        _ = try await harness.actions.update(moved, from: sixth, sendUpdates: .none, undoWindow: 0)
        #expect(await harness.engine.cycle())

        // From the third day on it is at 09:00: the series ends after two days and a new one takes the other eight.
        let current = try #require(try await harness.store.event(calendarID: sam.email, id: series.id))
        let cut = quarter(time(2, 8)).0
        guard case .split(let before, let after)? = Recurrence.split(recurrence: current.recurrence, seriesStart: current.start, at: cut, calendar: calendar) else {
            Issue.record("Expected the series to be cut in two")
            return
        }
        #expect(after == ["RRULE:FREQ=DAILY;COUNT=8"])
        var following = CalendarActions.followingSeries(of: current)
        (following.start, following.end) = quarter(time(2, 9))
        following.recurrence = after
        let records = try await harness.actions.split(current, at: cut, keeping: before, following: following, sendUpdates: .none, undoWindow: 0)
        #expect(records.count == 2)
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.calendarOutboxCount() == 0)

        // The provider has both series right; the old one's moved day went with the days it lost.
        #expect(try await harness.provider.event(calendarID: sam.email, eventID: series.id)?.recurrence == before)
        let new = try #require(try await harness.provider.event(calendarID: sam.email, eventID: following.id))
        #expect(new.recurrence == after && new.start == following.start)
        func starts(_ id: String) async throws -> [Date] {
            try await harness.provider.instances(calendarID: sam.email, eventID: id, from: day(-1), to: day(30)).compactMap(\.start.date)
        }
        #expect(try await starts(series.id) == [time(0, 8), time(1, 8)])
        #expect(try await starts(following.id) == (2..<10).map { time($0, 9) })
        #expect(try await harness.provider.event(calendarID: sam.email, eventID: moved.id) == nil)
        // So does the Mac: one review a day, at 08:00 and then at 09:00.
        for offset in 0..<10 {
            let items = try await harness.day(day(offset)).filter { $0.event.summary == "Morning review" }
            #expect(items.map(\.start.date) == [time(offset, offset < 2 ? 8 : 9)], "day \(offset)")
        }

        // Undo after both left: the new series goes, and the old one comes back with its moved day, on the provider too.
        for record in records.reversed() { try await harness.actions.undo(record) }
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.calendarOutboxCount() == 0)
        #expect(try await harness.provider.event(calendarID: sam.email, eventID: following.id) == nil)
        #expect(try await harness.provider.event(calendarID: sam.email, eventID: series.id)?.recurrence == ["RRULE:FREQ=DAILY;COUNT=10"])
        #expect(try await starts(series.id) == (0..<10).map { time($0, $0 == 5 ? 11 : 8) })
        for offset in 0..<10 {
            let items = try await harness.day(day(offset)).filter { $0.event.summary == "Morning review" }
            #expect(items.map(\.start.date) == [time(offset, offset == 5 ? 11 : 8)], "day \(offset)")
        }
    }

    @Test func aChangeToADayTheCutTookNeverReachesTheProvider() async throws {
        let harness = try await CalendarHarness()
        #expect(await harness.engine.cycle())
        let calendar = Calendar.current
        let zone = TimeZone.current.identifier
        func time(_ offset: Int, _ hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: offset, to: harness.nextMonday)!)!
        }
        func quarter(_ start: Date) -> (EventTime, EventTime) { (.timed(start, timeZone: zone), .timed(start.addingTimeInterval(900), timeZone: zone)) }
        let series = CalendarEvent(
            id: CalendarActions.newEventID(), calendarID: sam.email, summary: "Morning review",
            start: quarter(time(0, 8)).0, end: quarter(time(0, 8)).1, recurrence: ["RRULE:FREQ=DAILY;COUNT=10"]
        )
        _ = try await harness.actions.create(series, sendUpdates: .none, addConference: false, undoWindow: 0)
        #expect(await harness.engine.cycle())

        // The seventh day moves to 11:00 on its own, and before that leaves, the series is cut at the third day.
        let stored = try #require(try await harness.store.event(calendarID: sam.email, id: series.id))
        let seventh = stored.instance(originalStart: quarter(time(6, 8)).0, start: quarter(time(6, 8)).0, end: quarter(time(6, 8)).1)
        var moved = seventh
        (moved.start, moved.end) = quarter(time(6, 11))
        _ = try await harness.actions.update(moved, from: seventh, sendUpdates: .none, undoWindow: 0)
        let cut = quarter(time(2, 8)).0
        guard case .split(let before, let after)? = Recurrence.split(recurrence: stored.recurrence, seriesStart: stored.start, at: cut, calendar: calendar) else {
            Issue.record("Expected the series to be cut in two")
            return
        }
        var following = CalendarActions.followingSeries(of: stored)
        (following.start, following.end) = quarter(time(2, 9))
        following.recurrence = after
        _ = try await harness.actions.split(stored, at: cut, keeping: before, following: following, sendUpdates: .none, undoWindow: 0)
        #expect(await harness.engine.cycle())
        #expect(try await harness.store.calendarOutboxCount() == 0)

        // That day was never changed on the provider, and the Mac shows one review a day.
        let uid = try #require(try await harness.provider.event(calendarID: sam.email, eventID: series.id)?.iCalUID)
        #expect(try await harness.provider.events(calendarID: sam.email, iCalUID: uid).allSatisfy { $0.id != moved.id })
        for offset in 0..<10 {
            let items = try await harness.day(calendar.date(byAdding: .day, value: offset, to: harness.nextMonday)!).filter { $0.event.summary == "Morning review" }
            #expect(items.map(\.start.date) == [time(offset, offset < 2 ? 8 : 9)], "day \(offset)")
        }
    }

    @Test func theNewSeriesIsNewToGoogleAndAsksForItsOwnMeetLink() async throws {
        let harness = try await CalendarHarness()
        let zone = TimeZone.current.identifier
        let first = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: harness.nextMonday)!
        let cut = EventTime.timed(Calendar.current.date(byAdding: .day, value: 14, to: first)!, timeZone: zone)
        /// Whether the create of the series that takes over asks for a join link of its own.
        func asksForLink(link: String, location: String?) async throws -> Bool? {
            var series = CalendarEvent(
                id: CalendarActions.newEventID(), calendarID: sam.email, iCalUID: "planning@google.com", summary: "Planning", location: location,
                start: .timed(first, timeZone: zone), end: .timed(first.addingTimeInterval(1800), timeZone: zone), recurrence: ["RRULE:FREQ=WEEKLY"],
                conferenceURL: link, etag: "\"7\"", sequence: 3
            )
            series.htmlLink = "https://calendar.example.com/event?eid=1"
            guard case .split(let before, let after)? = Recurrence.split(recurrence: series.recurrence, seriesStart: series.start, at: cut, calendar: .current)
            else { return nil }
            var following = CalendarActions.followingSeries(of: series)
            #expect(following.id != series.id && following.iCalUID == nil && following.etag == nil && following.htmlLink == nil && following.sequence == 0)
            #expect(following.summary == "Planning" && following.conferenceURL == link)
            following.start = cut
            following.recurrence = after
            let records = try await harness.actions.split(series, at: cut, keeping: before, following: following, sendUpdates: .none, undoWindow: 60)
            let item = try await harness.store.calendarOutboxItems().first { $0.id == records.last?.outboxID }
            guard case .insert(let created, _, let conference)? = item?.operation, created.id == following.id else { return nil }
            return conference
        }
        // vimail keeps Google's link, not its conference: the new series gets a Meet link of its own.
        #expect(try await asksForLink(link: "https://meet.google.com/abc-defg-hij", location: nil) == true)
        // A link written in the place goes along with it.
        #expect(try await asksForLink(link: "https://zoom.us/j/123", location: "https://zoom.us/j/123") == false)
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
