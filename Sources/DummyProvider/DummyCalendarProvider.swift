import Foundation
import MailCore

/// A fake Google Calendar. It behaves like the real API (calendar list, sync tokens that expire,
/// series and exceptions, client-chosen event IDs, etags, answers, latency, failures), so the whole
/// calendar runs without touching a real calendar.
///
/// Invitations in the dummy mailbox appear on the calendar the way Google adds them, with your answer
/// still needed. State persists to a JSON file, like the dummy mail server's.
public actor DummyCalendarProvider: CalendarProvider {
    public struct Configuration: Sendable {
        public var latency: ClosedRange<Int> = 40...160
        public var failureRate: Double = 0
        public var seed: UInt64 = 2026

        public init() {}
    }

    struct Stored: Codable {
        var event: CalendarEvent
        /// The change number that last touched the event.
        var version: Int
    }

    struct State: Codable {
        var calendars: [CalendarInfo]
        /// Keyed by "calendarID\u{1}eventID". Removed events stay as cancelled tombstones, as in Google.
        var events: [String: Stored]
        var version: Int
        /// Sync tokens older than this are expired (410).
        var oldestToken: Int
        /// UIDs of mailbox invitations already on the calendar.
        var addedInvites: Set<String>
    }

    public nonisolated let kind = "dummy"
    private let storageURL: URL
    private let account: EmailAddress
    private var configuration: Configuration
    private let invitations: @Sendable () async -> [DummyInvite]
    private var state: State?
    private var saveTask: Task<Void, Never>?
    private var generator: SeededGenerator

    /// - Parameters:
    ///   - directory: where the fake server keeps its state (`calendar.json`).
    ///   - invitations: the dummy mailbox's invitations, added to the calendar like Google adds them.
    public init(directory: URL, account: EmailAddress? = nil, configuration: Configuration = Configuration(), invitations: @escaping @Sendable () async -> [DummyInvite] = { [] }) {
        storageURL = directory.appendingPathComponent("calendar.json")
        self.account = account ?? DummyContent.account
        self.configuration = configuration
        self.invitations = invitations
        generator = SeededGenerator(seed: configuration.seed &+ UInt64(Date().timeIntervalSince1970))
    }

    public func configure(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Wipes the fake calendar and builds it again.
    public func reset() throws {
        state = nil
        try? FileManager.default.removeItem(at: storageURL)
        try ensureLoaded()
    }

    /// Expires every sync token (for tests): the next incremental sync gets 410.
    public func expireSyncTokens() throws {
        try ensureLoaded()
        bump()
        state!.oldestToken = state!.version
    }

    /// Changes an event as if its organizer did it in Google Calendar (for tests and the simulation).
    public func organizerChange(calendarID: String, eventID: String, _ change: (inout CalendarEvent) -> Void) throws {
        try ensureLoaded()
        guard var stored = state!.events[Self.key(calendarID, eventID)] else { return }
        change(&stored.event)
        store(stored.event)
    }

    // MARK: - CalendarProvider

    public func calendars(syncToken: String?, pageToken: String?) async throws -> CalendarListPage {
        try await network()
        return CalendarListPage(calendars: syncToken == nil ? state!.calendars : [], nextSyncToken: "calendars-1")
    }

    public func events(calendarID: String, syncToken: String?, pageToken: String?, timeMin: Date?) async throws -> EventPage {
        try await network()
        await addMailboxInvitations()
        let since: Int
        if let syncToken {
            guard let number = Int(syncToken.dropFirst(2)), syncToken.hasPrefix("v:") else { throw ProviderError.cursorExpired }
            if number < state!.oldestToken { throw ProviderError.cursorExpired }
            since = number
        } else {
            since = -1
        }
        let events = state!.events.values
            .filter { $0.event.calendarID == calendarID && $0.version > since }
            .filter { since >= 0 || $0.event.status != .cancelled }
            .filter { stored in
                // A first download skips events that ended before timeMin; series always come.
                guard since < 0, let timeMin, !stored.event.isSeries else { return true }
                return stored.event.end.instant() > timeMin
            }
            .sorted { $0.version < $1.version }
            .map(\.event)
        return EventPage(events: events, nextSyncToken: "v:\(state!.version)")
    }

    public func instances(calendarID: String, eventID: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        try await network()
        return expandedInstances(calendarID: calendarID, seriesID: eventID, from: from, to: to)
    }

    public func event(calendarID: String, eventID: String) async throws -> CalendarEvent? {
        try await network()
        await addMailboxInvitations()
        guard let event = storedOrInstance(calendarID, eventID), event.status != .cancelled else { return nil }
        return event
    }

    public func insert(_ event: CalendarEvent, sendUpdates: SendUpdates, addConference: Bool) async throws -> CalendarEvent {
        try await network()
        guard state!.events[Self.key(event.calendarID, event.id)] == nil else { throw CalendarProviderError.duplicate }
        guard event.id.count >= 5, event.id.allSatisfy({ "0123456789abcdefghijklmnopqrstuv".contains($0) }) else {
            throw ProviderError.rejected("Invalid resource id value.")
        }
        var created = event
        created.iCalUID = created.iCalUID ?? "\(event.id)@google.com"
        if addConference, created.conferenceURL == nil {
            created.conferenceURL = "https://meet.example.com/\(Int.random(in: 100...999, using: &generator))-new"
        }
        if created.organizer == nil {
            created.organizer = Attendee(email: account.email, name: account.name, response: .accepted, isSelf: true, isOrganizer: true)
        }
        for index in created.attendees.indices where created.attendees[index].normalized == account.normalized {
            created.attendees[index].isSelf = true
            created.attendees[index].isOrganizer = true
            created.attendees[index].response = .accepted
        }
        created.htmlLink = "https://calendar.example.com/event?eid=\(event.id)"
        return store(created)
    }

    public func events(calendarID: String, iCalUID: String) async throws -> [CalendarEvent] {
        try await network()
        // As Google: a removed event is left out, a removed occurrence of a series is listed as cancelled.
        return state!.events.values.map(\.event).filter {
            $0.calendarID == calendarID && $0.iCalUID == iCalUID && ($0.status != .cancelled || $0.recurringEventID != nil)
        }
    }

    public func update(_ event: CalendarEvent, previous: CalendarEvent?, etag: String?, sendUpdates: SendUpdates) async throws -> CalendarEvent {
        try await network()
        guard let stored = storedOrInstance(event.calendarID, event.id) else { throw ProviderError.notFound("event") }
        if let etag, etag != stored.etag { throw CalendarProviderError.changedElsewhere }
        var updated = event
        updated.sequence = stored.sequence + 1
        updated.iCalUID = stored.iCalUID
        if updated.recurringEventID != nil { updated.recurrence = [] }
        let result = store(updated)
        if result.isSeries, result.recurrence != stored.recurrence { cancelExceptions(outside: result) }
        return result
    }

    public func delete(calendarID: String, eventID: String, sendUpdates: SendUpdates) async throws {
        try await network()
        // One occurrence of a series becomes a cancelled exception, as in Google Calendar.
        guard var event = storedOrInstance(calendarID, eventID), event.status != .cancelled else { return }
        event.status = .cancelled
        store(event)
        // A removed series takes its changed occurrences with it.
        for (_, exception) in state!.events where exception.event.calendarID == calendarID && exception.event.recurringEventID == eventID {
            var cancelled = exception.event
            cancelled.status = .cancelled
            store(cancelled)
        }
    }

    public func respond(calendarID: String, eventID: String, response: ResponseStatus, comment: String?, sendUpdates: SendUpdates) async throws -> CalendarEvent {
        try await network()
        guard var event = storedOrInstance(calendarID, eventID), event.status != .cancelled else { throw ProviderError.notFound("event") }
        guard let index = event.attendees.firstIndex(where: \.isSelf) else { throw ProviderError.rejected("You are not a guest of this event") }
        event.attendees[index].response = response
        event.attendees[index].comment = comment
        return store(event)
    }

    public func freeBusy(emails: [String], from: Date, to: Date) async throws -> [String: [DateInterval]] {
        try await network()
        var result: [String: [DateInterval]] = [:]
        let wanted = Set(emails.map { $0.lowercased() })
        for stored in state!.events.values where stored.event.status != .cancelled && stored.event.isBusy && stored.event.recurringEventID == nil {
            let event = stored.event
            let people = (event.attendees.filter { $0.response != .declined }.map(\.normalized) + [event.organizer?.normalized].compactMap { $0 })
            let busy = Set(people).intersection(wanted)
            guard !busy.isEmpty else { continue }
            let spans: [DateInterval] = event.isSeries
                ? expandedInstances(calendarID: event.calendarID, seriesID: event.id, from: from, to: to).map { DateInterval(start: $0.start.instant(), end: max($0.start.instant(), $0.end.instant())) }
                : [DateInterval(start: event.start.instant(), end: max(event.start.instant(), event.end.instant()))]
            for span in spans where span.end > from && span.start < to {
                for email in busy { result[email, default: []].append(span) }
            }
        }
        // Colleagues share their busy times, with a few meetings of their own; clients and friends do not.
        for email in wanted where Self.sharesFreeBusy(email) {
            result[email, default: []] += Self.colleagueMeetings(email, from: from, to: to)
        }
        return result.filter { Self.sharesFreeBusy($0.key) }.mapValues { $0.sorted { $0.start < $1.start } }
    }

    static func sharesFreeBusy(_ email: String) -> Bool {
        DummyContent.people.contains { $0.group == .colleague && $0.address.normalized == email }
    }

    /// One to three meetings on each working day, the same on every run.
    static func colleagueMeetings(_ email: String, from: Date, to: Date) -> [DateInterval] {
        let calendar = Calendar.current
        var result: [DateInterval] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            let weekday = calendar.component(.weekday, from: day)
            if weekday != 1, weekday != 7 {
                var seed = (email + DayDate(day, in: calendar).description).utf8.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1) }
                for _ in 0...(seed % 3) {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let minute = 9 * 60 + Int((seed >> 33) % 16) * 30
                    let length = [30, 45, 60, 90][Int((seed >> 20) % 4)]
                    if let start = calendar.date(byAdding: .minute, value: minute, to: day) {
                        result.append(DateInterval(start: start, duration: TimeInterval(length * 60)))
                    }
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? to
        }
        return result.filter { $0.end > from && $0.start < to }
    }

    // MARK: - State

    static func key(_ calendarID: String, _ eventID: String) -> String { "\(calendarID)\u{1}\(eventID)" }

    private func bump() {
        state!.version += 1
    }

    @discardableResult
    private func store(_ event: CalendarEvent) -> CalendarEvent {
        bump()
        var stored = event
        stored.etag = "\"v\(state!.version)\""
        stored.updated = Date()
        state!.events[Self.key(event.calendarID, event.id)] = Stored(event: stored, version: state!.version)
        scheduleSave()
        return stored
    }

    private func network() async throws {
        let delay = Int.random(in: configuration.latency, using: &generator)
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        if configuration.failureRate > 0, Double.random(in: 0..<1, using: &generator) < configuration.failureRate {
            throw ProviderError.offline("Simulated network failure")
        }
        try ensureLoaded()
    }

    private func ensureLoaded() throws {
        guard state == nil else { return }
        if let data = try? Data(contentsOf: storageURL), let decoded = try? Self.decoder.decode(State.self, from: data) {
            state = decoded
            return
        }
        state = DummyCalendarSeed(account: account, now: Date()).makeState()
        scheduleSave(immediately: true)
    }

    /// Puts the mailbox's new invitations on the calendar, as Google does for organizers you know.
    private func addMailboxInvitations() async {
        let invites = await invitations()
        guard state != nil else { return }
        let calendarID = state!.calendars.first(where: \.isPrimary)?.id ?? account.email
        for invite in invites.sorted(by: { $0.sent < $1.sent }) where !state!.addedInvites.contains(invite.uid) {
            state!.addedInvites.insert(invite.uid)
            let attendees = invite.guests.map { guest in
                Attendee(
                    email: guest.email, name: guest.name,
                    response: guest.normalized == invite.organizer.normalized || invite.accepted.contains(guest.normalized) ? .accepted : .needsAction,
                    isSelf: guest.normalized == account.normalized, isOrganizer: guest.normalized == invite.organizer.normalized
                )
            }
            store(CalendarEvent(
                id: DummyCalendarSeed.eventID(&generator), calendarID: calendarID, iCalUID: invite.uid, summary: invite.title, details: invite.agenda,
                start: .timed(invite.start, timeZone: TimeZone.current.identifier), end: .timed(invite.end, timeZone: TimeZone.current.identifier),
                organizer: Attendee(email: invite.organizer.email, name: invite.organizer.name, response: .accepted, isOrganizer: true),
                attendees: attendees, conferenceURL: invite.conference, sequence: invite.sequence
            ))
        }
    }

    /// A stored event, or one occurrence of a stored series by the ID Google gives it (`<series ID>_<occurrence key>`).
    private func storedOrInstance(_ calendarID: String, _ eventID: String) -> CalendarEvent? {
        if let stored = state!.events[Self.key(calendarID, eventID)] { return stored.event }
        guard let separator = eventID.lastIndex(of: "_") else { return nil }
        let seriesID = String(eventID[..<separator])
        guard let master = state!.events[Self.key(calendarID, seriesID)]?.event,
              let original = EventTime(occurrenceKey: String(eventID[eventID.index(after: separator)...]), timeZone: master.start.timeZone) else { return nil }
        let moment = original.instant()
        return expandedInstances(calendarID: calendarID, seriesID: seriesID, from: moment.addingTimeInterval(-2 * 86_400), to: moment.addingTimeInterval(2 * 86_400))
            .first { $0.id == eventID }
    }

    /// A series whose rules changed (one that now ends sooner, for example) loses the changed occurrences of days it no
    /// longer has: they are cancelled, so a sync reports them gone.
    private func cancelExceptions(outside master: CalendarEvent) {
        for (_, stored) in state!.events where stored.event.calendarID == master.calendarID && stored.event.recurringEventID == master.id
            && stored.event.status != .cancelled {
            guard let original = stored.event.originalStart else { continue }
            let moment = original.instant()
            guard let days = Recurrence.occurrences(
                start: master.start, end: master.end, recurrence: master.recurrence,
                from: moment.addingTimeInterval(-86_400), to: moment.addingTimeInterval(86_400), calendar: .current
            ), !days.contains(where: { ($0.originalStart ?? $0.start).occurrenceKey == original.occurrenceKey }) else { continue }
            var cancelled = stored.event
            cancelled.status = .cancelled
            store(cancelled)
        }
    }

    private func expandedInstances(calendarID: String, seriesID: String, from: Date, to: Date) -> [CalendarEvent] {
        guard let master = state!.events[Self.key(calendarID, seriesID)]?.event, master.isSeries, master.status != .cancelled else { return [] }
        let exceptions = state!.events.values.map(\.event).filter { $0.calendarID == calendarID && $0.recurringEventID == seriesID }
        let occurrences = Recurrence.occurrences(start: master.start, end: master.end, recurrence: master.recurrence, from: from, to: to, calendar: .current) ?? []
        return occurrences.compactMap { occurrence -> CalendarEvent? in
            let original = occurrence.originalStart ?? occurrence.start
            if let exception = exceptions.first(where: { ($0.originalStart ?? $0.start) == original }) {
                return exception.status == .cancelled ? nil : exception
            }
            var instance = master
            instance.id = "\(seriesID)_\(original.occurrenceKey)"
            instance.recurrence = []
            instance.recurringEventID = seriesID
            instance.originalStart = original
            instance.start = occurrence.start
            instance.end = occurrence.end
            return instance
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private func scheduleSave(immediately: Bool = false) {
        saveTask?.cancel()
        let url = storageURL
        saveTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled, let snapshot = await self?.state else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? Self.encoder.encode(snapshot) else { return }
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    /// Waits for pending writes (for tests).
    public func flush() async {
        await saveTask?.value
    }
}

/// The dummy calendar's own events: a few recurring meetings, some single ones near today, and holidays.
struct DummyCalendarSeed {
    let account: EmailAddress
    let now: Date
    private let calendar = Calendar.current

    static func eventID(_ generator: inout SeededGenerator) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuv")
        return String((0..<20).map { _ in alphabet[Int(generator.next() % 32)] })
    }

    func makeState() -> DummyCalendarProvider.State {
        var generator = SeededGenerator(seed: 2026)
        let zone = TimeZone.current.identifier
        let primary = CalendarInfo(id: account.email, summary: account.name ?? account.email, timeZone: zone, color: "#9fe1e7", accessRole: .owner, isPrimary: true)
        let holidays = CalendarInfo(id: "en.usa#holiday@group.v.calendar.google.com", summary: "Holidays in United States", timeZone: zone, color: "#16a765", accessRole: .reader)
        let person = { (name: String) in DummyContent.person(name).address }
        let alex = person("Alex Morgan"), jamie = person("Jamie Chen"), priya = person("Priya Raman"), chris = person("Chris Yu"), maya = person("Maya Brooks")
        let marcus = person("Marcus Webb"), hannah = person("Hannah Lee")

        func guests(_ organizer: EmailAddress, _ others: [EmailAddress], me response: ResponseStatus) -> [Attendee] {
            ([organizer] + others).map { address in
                Attendee(email: address.email, name: address.name, response: .accepted, isOrganizer: address == organizer)
            } + (organizer == account ? [] : [Attendee(email: account.email, name: account.name, response: response, isSelf: true)])
        }
        func meeting(_ title: String, _ start: Date, minutes: Int, organizer: EmailAddress, others: [EmailAddress], me response: ResponseStatus = .accepted, recurrence: [String] = [], conference: Bool = true) -> CalendarEvent {
            let id = Self.eventID(&generator)
            var attendees = guests(organizer, others, me: response)
            if organizer == account, let index = attendees.firstIndex(where: { $0.normalized == account.normalized }) {
                attendees[index].isSelf = true
            }
            return CalendarEvent(
                id: id, calendarID: primary.id, iCalUID: "\(id)@google.com", summary: title,
                start: .timed(start, timeZone: zone), end: .timed(start.addingTimeInterval(Double(minutes) * 60), timeZone: zone), recurrence: recurrence,
                organizer: Attendee(email: organizer.email, name: organizer.name, response: .accepted, isSelf: organizer == account, isOrganizer: true),
                attendees: attendees, conferenceURL: conference ? "https://meet.example.com/\(Int(generator.next() % 900) + 100)-studio" : nil
            )
        }

        let today = calendar.startOfDay(for: now)
        func at(daysFromToday days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.date(byAdding: .day, value: days, to: today)!)!
        }
        // Series start on the right weekday about four months ago.
        func seriesStart(weekday: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            var day = calendar.date(byAdding: .day, value: -120, to: today)!
            while calendar.component(.weekday, from: day) != weekday { day = calendar.date(byAdding: .day, value: 1, to: day)! }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let monday = DummyGenerator.nextMonday(after: now, hour: 0, calendar: calendar)
        func nextMonday(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: monday)! }

        var events = [
            meeting("Studio standup", seriesStart(weekday: 2, 9, 30), minutes: 15, organizer: alex, others: [jamie, priya, chris, maya],
                    recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"]),
            meeting("Weekly sync", seriesStart(weekday: 6, 16), minutes: 30, organizer: account, others: [alex, jamie, priya],
                    recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=FR"]),
            meeting("1:1 with Alex", seriesStart(weekday: 2, 13), minutes: 30, organizer: alex, others: [], recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO"]),
            meeting("Studio all-hands", seriesStart(weekday: 3, 11), minutes: 60, organizer: chris, others: [alex, jamie, priya, maya], me: .declined,
                    recurrence: ["RRULE:FREQ=MONTHLY;BYDAY=1TU"]),
            meeting("Portfolio planning", nextMonday(10), minutes: 60, organizer: maya, others: [chris], me: .tentative),
            meeting("Lumen check-in", nextMonday(14, 30), minutes: 30, organizer: marcus, others: [hannah]),
            meeting("Typeface licensing call", at(daysFromToday: 2, 11), minutes: 30, organizer: account, others: [person("Dana Whitfield")], conference: true),
            meeting("Studio site review", at(daysFromToday: -3, 15), minutes: 45, organizer: jamie, others: [alex, priya]),
        ]
        let year = calendar.component(.year, from: now)
        for (title, day) in [("Thanksgiving Day", Self.thanksgiving(year: year)), ("Christmas Day", DayDate(year: year, month: 12, day: 25)), ("New Year's Day", DayDate(year: year + 1, month: 1, day: 1))] {
            let id = Self.eventID(&generator)
            events.append(CalendarEvent(
                id: id, calendarID: holidays.id, iCalUID: "\(id)@google.com", summary: title,
                start: .allDay(day), end: .allDay(day.adding(days: 1, in: calendar)), isBusy: false
            ))
        }
        var stored: [String: DummyCalendarProvider.Stored] = [:]
        for (index, event) in events.enumerated() {
            var copy = event
            copy.etag = "\"v\(index + 1)\""
            stored[DummyCalendarProvider.key(event.calendarID, event.id)] = .init(event: copy, version: index + 1)
        }
        return DummyCalendarProvider.State(calendars: [primary, holidays], events: stored, version: events.count, oldestToken: 0, addedInvites: [])
    }

    /// The fourth Thursday of November.
    static func thanksgiving(year: Int) -> DayDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let first = calendar.date(from: DateComponents(year: year, month: 11, day: 1))!
        let weekday = calendar.component(.weekday, from: first)
        let offset = (5 - weekday + 7) % 7
        return DayDate(year: year, month: 11, day: 1 + offset + 21)
    }
}
