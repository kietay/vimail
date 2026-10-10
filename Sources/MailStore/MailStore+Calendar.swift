import Foundation
import MailCore

/// One row of the agenda or the day column: an occurrence and the event that describes it.
public struct AgendaItem: Identifiable, Hashable, Sendable {
    public var calendarID: String
    /// The event with the details: a single event, the series, or a changed occurrence of it.
    public var event: CalendarEvent
    /// The series, for occurrences of a repeating event.
    public var seriesID: String?
    /// The occurrence's key within its series ("" for single events).
    public var originalStart: String
    public var start: EventTime
    public var end: EventTime

    public init(calendarID: String, event: CalendarEvent, seriesID: String?, originalStart: String, start: EventTime, end: EventTime) {
        self.calendarID = calendarID
        self.event = event
        self.seriesID = seriesID
        self.originalStart = originalStart
        self.start = start
        self.end = end
    }

    public var id: String { "\(calendarID)|\(event.id)|\(originalStart)" }
    /// The event an answer applies to: the series for its occurrences, otherwise the event itself.
    public var answerTargetID: String { seriesID ?? event.id }
}

/// The parsed invitation file of one message.
public struct StoredInvitation: Hashable, Sendable {
    public var messageID: String
    public var threadID: String
    /// The file's events: usually one; a series can come with its changed occurrences.
    public var invitations: [Invitation]
    /// When the message arrived.
    public var date: Date

    public init(messageID: String, threadID: String, invitations: [Invitation], date: Date) {
        self.messageID = messageID
        self.threadID = threadID
        self.invitations = invitations
        self.date = date
    }

    /// The event the file is about: the series or single event, before its exceptions.
    public var main: Invitation? { invitations.first { $0.recurrenceID == nil } ?? invitations.first }
}

/// One event's own answer before a change, so an undo puts back exactly that.
public struct SavedAnswer: Hashable, Codable, Sendable {
    public var eventID: String
    public var response: ResponseStatus
    public var comment: String?

    public init(eventID: String, response: ResponseStatus, comment: String?) {
        self.eventID = eventID
        self.response = response
        self.comment = comment
    }
}

/// What removing an event did locally, so an undo can put it all back.
public struct LocalRemoval: Sendable {
    /// The queued removal. Nil when the event had not reached the provider yet, so nothing is sent.
    public var outboxID: Int64?
    /// The changed occurrences a removed series took with it.
    public var exceptions: [CalendarEvent] = []
    /// Operations dropped because the event's create had not left yet; they go back on undo.
    public var dropped: [CalendarOutboxItem] = []
}

/// A message whose invitation file has not been read yet.
public struct InvitationCandidate: Hashable, Sendable {
    public var messageID: String
    public var threadID: String
    public var attachmentID: String
}

/// The span of time the store keeps expanded occurrences for.
public struct CalendarWindow: Hashable, Sendable {
    public var from: Date
    public var to: Date

    public init(from: Date, to: Date) {
        self.from = from
        self.to = to
    }

    /// One year back to 400 days ahead of `now`, from midnight to midnight in `calendar`'s zone.
    public static func around(_ now: Date, calendar: Calendar = .current) -> CalendarWindow {
        let today = calendar.startOfDay(for: now)
        return CalendarWindow(
            from: calendar.date(byAdding: .day, value: -365, to: today) ?? today,
            to: calendar.date(byAdding: .day, value: 400, to: today) ?? today
        )
    }

    /// Identifies a window and a time zone, to notice when either changed.
    public func key(in calendar: Calendar) -> String {
        "\(DayDate(from, in: calendar))/\(DayDate(to, in: calendar))/\(calendar.timeZone.identifier)"
    }
}

/// Calendars, events and the occurrence window. Written by `CalendarSyncEngine` and `CalendarActions`;
/// read by the agenda, the day column and invitation pages.
extension MailStore {
    // MARK: - Calendars

    public func calendars() async throws -> [CalendarInfo] {
        try await read { db in
            try db.query("SELECT payload FROM calendars ORDER BY position, rowid") { row in
                try Self.decoder.decode(CalendarInfo.self, from: Data(row.string(0).utf8))
            }
        }
    }

    /// Stores the calendar list. With `replaceAll`, calendars missing from `calendars` are removed with their events.
    public func applyCalendarList(_ calendars: [CalendarInfo], removed: [String], replaceAll: Bool) async throws {
        try await write { db, change in
            let existing = Set(try db.query("SELECT id FROM calendars") { $0.string(0) })
            let gone = replaceAll ? existing.subtracting(calendars.map(\.id)) : Set(removed).intersection(existing)
            for id in gone {
                try db.run("DELETE FROM calendars WHERE id = ?", [id])
                try db.run("DELETE FROM events WHERE calendar_id = ?", [id])
                try db.run("DELETE FROM occurrences WHERE calendar_id = ?", [id])
            }
            // The primary calendar first, then Google's order.
            for (index, calendar) in calendars.sorted(by: { $0.isPrimary && !$1.isPrimary }).enumerated() {
                let payload = String(decoding: try Self.encoder.encode(calendar), as: UTF8.self)
                try db.run(
                    """
                    INSERT INTO calendars(id, payload, position) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, position = excluded.position
                    """,
                    [calendar.id, payload, index]
                )
            }
            change.calendar = true
        }
    }

    public func calendarSyncToken(_ calendarID: String) async throws -> String? {
        try await read { db in try db.first("SELECT sync_token FROM calendars WHERE id = ?", [calendarID]) { $0.optionalString(0) } ?? nil }
    }

    public func setCalendarSyncToken(_ calendarID: String, _ token: String?) async throws {
        try await write { db, _ in try db.run("UPDATE calendars SET sync_token = ? WHERE id = ?", [token, calendarID]) }
    }

    /// Forgets one calendar's events before a full download (its sync token expired).
    public func clearCalendarEvents(_ calendarID: String) async throws {
        try await write { db, change in
            try db.run("DELETE FROM events WHERE calendar_id = ?", [calendarID])
            try db.run("DELETE FROM occurrences WHERE calendar_id = ?", [calendarID])
            try db.run("UPDATE calendars SET sync_token = NULL WHERE id = ?", [calendarID])
            change.calendar = true
        }
    }

    // MARK: - Events from the provider

    /// Stores a page of provider events and updates their occurrences inside `window`.
    /// Local changes still waiting in the calendar outbox stay applied on top.
    /// Returns the series that Foundation cannot expand: their occurrences must come from the provider.
    @discardableResult
    public func applyEvents(_ events: [CalendarEvent], calendarID: String, window: CalendarWindow, calendar: Calendar = .current) async throws -> [String] {
        guard !events.isEmpty else { return [] }
        return try await write { db, change in
            let pending = try Self.calendarOutboxItems(db).map(\.operation)
            var series = Set<String>()
            for var event in events {
                event.calendarID = calendarID
                if let operation = pending.last(where: { $0.target.calendarID == calendarID && $0.target.eventID == event.id }) {
                    guard let local = operation.applied(to: event) else { continue }
                    event = local
                }
                if event.status == .cancelled, event.recurringEventID == nil {
                    // Google's removals carry little more than the ID: the UID and sequence come from the stored copy.
                    if let stored = try Self.storedEvent(calendarID: calendarID, eventID: event.id, db), let uid = stored.iCalUID {
                        try db.run(
                            "INSERT INTO removed_events(uid, sequence) VALUES (?, ?) ON CONFLICT(uid) DO UPDATE SET sequence = max(sequence, excluded.sequence)",
                            [uid, max(stored.sequence, event.sequence)]
                        )
                    }
                    try Self.removeEvent(calendarID: calendarID, eventID: event.id, db)
                    continue
                }
                if let uid = event.iCalUID { try db.run("DELETE FROM removed_events WHERE uid = ? AND sequence <= ?", [uid, event.sequence]) }
                try Self.upsertEvent(event, db)
                if let seriesID = event.recurringEventID {
                    series.insert(seriesID)
                } else if event.isSeries {
                    series.insert(event.id)
                } else {
                    try Self.materializeSingle(event, db, calendar: calendar)
                }
            }
            var needsProvider: [String] = []
            for id in series.sorted() {
                if try Self.materializeSeries(calendarID: calendarID, seriesID: id, window: window, db, calendar: calendar) { needsProvider.append(id) }
            }
            change.calendar = true
            return needsProvider
        }
    }

    /// Replaces a series' occurrences with the provider's expansion (`events.instances`).
    public func applyInstances(_ instances: [CalendarEvent], calendarID: String, seriesID: String, calendar: Calendar = .current) async throws {
        try await write { db, change in
            try db.run(
                "DELETE FROM occurrences WHERE calendar_id = ? AND (series_id = ? OR (event_id = ? AND original_start = '' AND series_id IS NULL))",
                [calendarID, seriesID, seriesID]
            )
            for instance in instances where instance.status != .cancelled {
                let stored = try db.scalar("SELECT COUNT(*) FROM events WHERE calendar_id = ? AND id = ?", [calendarID, instance.id]) > 0
                try Self.writeOccurrence(
                    calendarID: calendarID, eventID: stored ? instance.id : seriesID, seriesID: seriesID,
                    key: Self.occurrenceKey(instance.originalStart ?? instance.start), start: instance.start, end: instance.end, db, calendar: calendar
                )
            }
            change.calendar = true
        }
    }

    /// Expands every stored event again, for a new window or a new time zone.
    /// Returns the series whose occurrences must come from the provider.
    public func rematerializeOccurrences(window: CalendarWindow, calendar: Calendar = .current) async throws -> [(calendarID: String, seriesID: String)] {
        try await write { db, change in
            try db.run("DELETE FROM occurrences")
            let rows = try db.query("SELECT payload FROM events") { row in
                try Self.decoder.decode(CalendarEvent.self, from: Data(row.string(0).utf8))
            }
            var series = Set<[String]>()
            for event in rows {
                if let seriesID = event.recurringEventID {
                    series.insert([event.calendarID, seriesID])
                } else if event.isSeries {
                    series.insert([event.calendarID, event.id])
                } else {
                    try Self.materializeSingle(event, db, calendar: calendar)
                }
            }
            var needsProvider: [(calendarID: String, seriesID: String)] = []
            for pair in series.sorted(by: { $0.joined() < $1.joined() }) {
                if try Self.materializeSeries(calendarID: pair[0], seriesID: pair[1], window: window, db, calendar: calendar) {
                    needsProvider.append((pair[0], pair[1]))
                }
            }
            change.calendar = true
            return needsProvider
        }
    }

    // MARK: - Reading

    /// Occurrences overlapping [from, to), with their events, in start order (all-day first on a day).
    public func agenda(from: Date, to: Date, calendar: Calendar = .current) async throws -> [AgendaItem] {
        try await read { db in
            try db.query(
                Self.agendaSelect + """
                WHERE (o.start_day IS NULL AND o.start_ms < ? AND o.end_ms > ?)
                   OR (o.start_day IS NOT NULL AND o.start_day < ? AND o.end_day > ?)
                ORDER BY o.start_ms, o.start_day IS NULL, o.end_ms
                """,
                [to, from, DayDate(to.addingTimeInterval(-1), in: calendar).adding(days: 1, in: calendar).description, DayDate(from, in: calendar).description],
                Self.decodeAgendaItem
            )
        }
    }

    /// Invitations you have not answered, next occurrence first, one row per event or series.
    public func waitingForAnswer(now: Date = Date(), calendar: Calendar = .current) async throws -> [AgendaItem] {
        let rows = try await read { db in
            try db.query(
                Self.agendaSelect + """
                WHERE e.self_response = 'needsAction' AND e.status != 'cancelled'
                  AND ((o.start_day IS NULL AND o.end_ms > ?) OR (o.start_day IS NOT NULL AND o.end_day > ?))
                ORDER BY o.start_ms
                """,
                [now, DayDate(now, in: calendar).description],
                Self.decodeAgendaItem
            )
        }
        var seen = Set<String>()
        return rows.filter { seen.insert("\($0.calendarID)|\($0.answerTargetID)").inserted }
    }

    public func event(calendarID: String, id: String) async throws -> CalendarEvent? {
        try await read { db in try Self.storedEvent(calendarID: calendarID, eventID: id, db) }
    }

    /// Events with an iCalendar UID on any calendar: series and single events first, then their exceptions.
    public func events(uid: String) async throws -> [CalendarEvent] {
        try await read { db in
            try db.query(
                "SELECT e.payload FROM events e LEFT JOIN calendars c ON c.id = e.calendar_id WHERE e.ical_uid = ? ORDER BY e.recurring_event_id IS NOT NULL, c.position",
                [uid]
            ) { row in try Self.decoder.decode(CalendarEvent.self, from: Data(row.string(0).utf8)) }
        }
    }

    /// A series' occurrences that end after `from`, in order, at most `limit`.
    public func occurrences(calendarID: String, seriesID: String, from: Date, limit: Int) async throws -> [AgendaItem] {
        try await read { db in
            try db.query(
                Self.agendaSelect + "WHERE o.calendar_id = ? AND (o.series_id = ? OR o.event_id = ?) AND o.end_ms > ? ORDER BY o.start_ms LIMIT ?",
                [calendarID, seriesID, seriesID, from, limit], Self.decodeAgendaItem
            )
        }
    }

    /// The next occurrence of an event or series at or after `now` (or its last one when all are past).
    public func nextOccurrence(calendarID: String, eventID: String, now: Date = Date(), calendar: Calendar = .current) async throws -> AgendaItem? {
        try await read { db in
            let rows = try db.query(
                Self.agendaSelect + "WHERE o.calendar_id = ? AND (o.event_id = ? OR o.series_id = ?) ORDER BY o.start_ms",
                [calendarID, eventID, eventID], Self.decodeAgendaItem
            )
            return rows.first { $0.end.instant(in: calendar) > now } ?? rows.last
        }
    }

    // MARK: - Local changes

    /// Sets the account's own answer on an event (and the changed occurrences of a series) and queues it for the provider.
    /// Returns the queued operation, the previous answer, and every answer it replaced (for an exact undo), or nil when
    /// the account is not a guest.
    public func respond(
        calendarID: String, eventID: String, response: ResponseStatus, comment: String?, sendUpdates: SendUpdates = .all, notBefore: Date = .distantPast
    ) async throws -> (outboxID: Int64, previous: ResponseStatus?, saved: [SavedAnswer])? {
        try await write { db, change in
            guard let event = try Self.storedEvent(calendarID: calendarID, eventID: eventID, db), event.selfAttendee != nil else { return nil }
            let previous = event.selfResponse
            let saved = try Self.savedAnswers(calendarID: calendarID, eventID: eventID, db)
            let operation = CalendarOperation.respond(
                calendarID: calendarID, eventID: eventID, response: response, comment: comment, previous: previous, sendUpdates: sendUpdates
            )
            try Self.setResponse(response, comment: comment, calendarID: calendarID, eventID: eventID, db)
            change.calendar = true
            return (try Self.enqueueCalendar(operation, notBefore: notBefore, db), previous, saved)
        }
    }

    /// Undoes an answer. A queued answer is dropped; one that already left is answered again with `previous`.
    /// `dropException`: the answer was for one occurrence the Mac stored only to answer it; it goes again.
    /// Returns true when nothing had reached the provider.
    @discardableResult
    public func revertResponse(
        outboxID: Int64, calendarID: String, eventID: String, previous: ResponseStatus?, saved: [SavedAnswer] = [], dropException: Bool = false,
        window: CalendarWindow = .around(Date()), calendar: Calendar = .current
    ) async throws -> Bool {
        try await write { db, change in
            try db.run("DELETE FROM calendar_outbox WHERE id = ? AND state = 'pending'", [outboxID])
            let cancelled = db.changes > 0
            if cancelled, dropException, let event = try Self.storedEvent(calendarID: calendarID, eventID: eventID, db), let seriesID = event.recurringEventID {
                try Self.dropException(event, seriesID: seriesID, window: window, db, calendar: calendar)
                change.calendar = true
                return true
            }
            let restore = previous ?? .needsAction
            if saved.isEmpty {
                try Self.setResponse(restore, comment: nil, calendarID: calendarID, eventID: eventID, db)
            } else {
                // Each changed row gets its own answer and note back (a series' occurrences can differ from it).
                for answer in saved {
                    try Self.setResponse(answer.response, comment: answer.comment, calendarID: calendarID, eventID: answer.eventID, includingOccurrences: false, db)
                }
            }
            if !cancelled {
                let comment = saved.first { $0.eventID == eventID }?.comment
                _ = try Self.enqueueCalendar(.respond(calendarID: calendarID, eventID: eventID, response: restore, comment: comment, previous: nil, sendUpdates: .all), db)
            }
            change.calendar = true
            return cancelled
        }
    }

    /// Adds an event made on the Mac and queues its creation.
    public func insertLocalEvent(
        _ event: CalendarEvent, sendUpdates: SendUpdates, addConference: Bool, notBefore: Date = .distantPast, window: CalendarWindow, calendar: Calendar = .current
    ) async throws -> Int64 {
        try await write { db, change in
            try Self.upsertEvent(event, db)
            if event.isSeries {
                _ = try Self.materializeSeries(calendarID: event.calendarID, seriesID: event.id, window: window, db, calendar: calendar)
            } else {
                try Self.materializeSingle(event, db, calendar: calendar)
            }
            change.calendar = true
            return try Self.enqueueCalendar(.insert(event: event, sendUpdates: sendUpdates, addConference: addConference), notBefore: notBefore, db)
        }
    }

    /// Replaces an event with an edited version and queues the change.
    public func updateLocalEvent(
        _ event: CalendarEvent, previous: CalendarEvent, sendUpdates: SendUpdates, notBefore: Date = .distantPast, window: CalendarWindow, calendar: Calendar = .current
    ) async throws -> Int64 {
        try await write { db, change in
            try Self.storeLocally(event, window: window, db, calendar: calendar)
            change.calendar = true
            return try Self.enqueueCalendar(.update(event: event, previous: previous, sendUpdates: sendUpdates), notBefore: notBefore, db)
        }
    }

    /// Removes an event locally and queues its removal. One occurrence of a series becomes a cancelled exception.
    /// An event whose create is still waiting has reached no one: its waiting operations are dropped and nothing is sent.
    public func deleteLocalEvent(
        _ event: CalendarEvent, sendUpdates: SendUpdates, notBefore: Date = .distantPast, window: CalendarWindow = .around(Date()), calendar: Calendar = .current
    ) async throws -> LocalRemoval {
        try await write { db, change in
            var removal = LocalRemoval()
            var waiting: [CalendarOutboxItem] = []
            if event.recurringEventID == nil {
                let key = CalendarOperation.delete(event: event, sendUpdates: sendUpdates).queueKey
                waiting = try Self.calendarOutboxItems(db).filter { !$0.isInFlight && $0.operation.queueKey == key }
                // Only a create that was never tried: one tried before may have reached Google (its answer lost), so the
                // removal is queued behind it instead.
                let created = waiting.contains { item in
                    if case .insert(let queued, _, _) = item.operation { return queued.id == event.id && item.attempts == 0 }
                    return false
                }
                if !created { waiting = [] }
            }
            if event.recurringEventID != nil {
                var cancelled = event
                cancelled.status = .cancelled
                try Self.storeLocally(cancelled, window: window, db, calendar: calendar)
            } else {
                if event.isSeries {
                    removal.exceptions = try db.query(
                        "SELECT payload FROM events WHERE calendar_id = ? AND recurring_event_id = ?", [event.calendarID, event.id]
                    ) { row in try Self.decoder.decode(CalendarEvent.self, from: Data(row.string(0).utf8)) }
                }
                try Self.removeEvent(calendarID: event.calendarID, eventID: event.id, db)
            }
            change.calendar = true
            if !waiting.isEmpty {
                for item in waiting { try db.run("DELETE FROM calendar_outbox WHERE id = ?", [item.id]) }
                removal.dropped = waiting
                return removal
            }
            removal.outboxID = try Self.enqueueCalendar(.delete(event: event, sendUpdates: sendUpdates), notBefore: notBefore, db)
            return removal
        }
    }

    /// Undoes a create, edit or removal. A queued operation is dropped; one that already left gets its inverse.
    /// `restore` is the event as it was before (nil after a create). `dropException`: `restore` is an occurrence
    /// that was not changed before, so a change that never left leaves no exception behind. `removal` is what a
    /// removal did locally: a series' changed occurrences come back, and a create it dropped is queued again in its old place.
    /// Returns true when nothing had reached the provider.
    @discardableResult
    public func revertEventChange(
        outboxID: Int64?, current: CalendarEvent?, restore: CalendarEvent?, sendUpdates: SendUpdates, dropException: Bool = false,
        removal: LocalRemoval? = nil, window: CalendarWindow, calendar: Calendar = .current
    ) async throws -> Bool {
        try await write { db, change in
            var cancelled = false
            if let outboxID {
                try db.run("DELETE FROM calendar_outbox WHERE id = ? AND state = 'pending'", [outboxID])
                cancelled = db.changes > 0
            }
            if let removal, !removal.dropped.isEmpty {
                for item in removal.dropped { _ = try Self.enqueueCalendar(item.operation, notBefore: item.notBefore, id: item.id, db) }
                cancelled = true
            }
            if let restore {
                for exception in removal?.exceptions ?? [] { try Self.upsertEvent(exception, db) }
                if cancelled, dropException, let seriesID = restore.recurringEventID {
                    try Self.dropException(restore, seriesID: seriesID, window: window, db, calendar: calendar)
                } else {
                    try Self.storeLocally(restore, window: window, db, calendar: calendar)
                }
            } else if let current {
                try Self.removeEvent(calendarID: current.calendarID, eventID: current.id, db)
            }
            if !cancelled {
                switch (current, restore) {
                case (let current?, nil):
                    _ = try Self.enqueueCalendar(.delete(event: current, sendUpdates: sendUpdates), db)
                case (nil, let restore?) where restore.recurringEventID != nil:
                    // A removed occurrence comes back by changing it again: Google keeps it as a cancelled exception.
                    var restored = restore
                    restored.status = .confirmed
                    restored.etag = nil
                    var removed = restored
                    removed.status = .cancelled
                    _ = try Self.enqueueCalendar(.update(event: restored, previous: removed, sendUpdates: sendUpdates), db)
                case (nil, let restore?):
                    // The removed event comes back under its own ID (the provider restores a cancelled event).
                    _ = try Self.enqueueCalendar(.insert(event: restore, sendUpdates: sendUpdates, addConference: false), db)
                case (let current?, let restore?):
                    _ = try Self.enqueueCalendar(.update(event: restore, previous: current, sendUpdates: sendUpdates), db)
                case (nil, nil):
                    break
                }
            }
            change.calendar = true
            return cancelled
        }
    }

    /// Replaces a series (or event) and its changed occurrences with the provider's copies, after the provider refused
    /// a change to it.
    public func replaceEvents(_ events: [CalendarEvent], calendarID: String, eventID: String, window: CalendarWindow, calendar: Calendar = .current) async throws {
        try await write { db, change in
            try Self.removeEvent(calendarID: calendarID, eventID: eventID, db)
            change.calendar = true
        }
        _ = try await applyEvents(events, calendarID: calendarID, window: window, calendar: calendar)
    }

    /// Drops the queued (not in flight) operations on one event, which cannot succeed once its create was refused.
    public func dropCalendarOperations(queueKey: String) async throws {
        try await write { db, change in
            try db.run("DELETE FROM calendar_outbox WHERE target = ? AND state = 'pending'", [queueKey])
            change.calendar = true
        }
    }

    /// Stores an event as the Mac sees it, without queueing anything: an occurrence about to be answered on its own.
    public func storeLocalEvent(_ event: CalendarEvent, window: CalendarWindow, calendar: Calendar = .current) async throws {
        try await write { db, change in
            try Self.storeLocally(event, window: window, db, calendar: calendar)
            change.calendar = true
        }
    }

    /// Stores the provider's version of an event after a push (the outbox entry is already gone).
    public func storeProviderEvent(_ event: CalendarEvent, window: CalendarWindow, calendar: Calendar = .current) async throws {
        _ = try await applyEvents([event], calendarID: event.calendarID, window: window, calendar: calendar)
    }

    // MARK: - Event drafts

    /// An event closed with esc before it was saved (JSON), by event ID ("new" for an event not created yet).
    public func eventDraft(id: String) async throws -> String? {
        try await read { db in try db.first("SELECT payload FROM event_drafts WHERE id = ?", [id]) { $0.string(0) } }
    }

    public func saveEventDraft(id: String, payload: String) async throws {
        try await write { db, _ in
            try db.run(
                "INSERT INTO event_drafts(id, payload, updated_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at",
                [id, payload, Date()]
            )
        }
    }

    public func deleteEventDraft(id: String) async throws {
        try await write { db, _ in try db.run("DELETE FROM event_drafts WHERE id = ?", [id]) }
    }

    // MARK: - Invitations

    /// Messages with an invitation file (a `text/calendar` part) that has not been read yet, newest first.
    public func invitationCandidates(limit: Int) async throws -> [InvitationCandidate] {
        let rows = try await read { db in
            try db.query(
                """
                SELECT m.id, m.thread_id, json_extract(a.value, '$.id'), lower(json_extract(a.value, '$.mimeType'))
                FROM messages m, json_each(m.attachments_json) a
                WHERE m.is_local = 0
                  AND (lower(json_extract(a.value, '$.mimeType')) IN ('text/calendar', 'application/ics')
                       OR lower(json_extract(a.value, '$.filename')) LIKE '%.ics')
                  AND NOT EXISTS (SELECT 1 FROM invitations i WHERE i.message_id = m.id)
                ORDER BY m.date DESC
                LIMIT ?
                """,
                [limit * 3]
            ) { row in (InvitationCandidate(messageID: row.string(0), threadID: row.string(1), attachmentID: row.string(2)), row.optionalString(3) == "text/calendar") }
        }
        // One file per message; Google sends the same invitation as text/calendar and application/ics.
        var chosen: [String: (InvitationCandidate, Bool)] = [:]
        var order: [String] = []
        for (candidate, isText) in rows {
            if let existing = chosen[candidate.messageID] {
                if isText && !existing.1 { chosen[candidate.messageID] = (candidate, isText) }
            } else {
                chosen[candidate.messageID] = (candidate, isText)
                order.append(candidate.messageID)
            }
        }
        return order.prefix(limit).compactMap { chosen[$0]?.0 }
    }

    /// Stores the parsed invitation file of a message (or why it could not be read).
    public func saveInvitations(_ invitations: [Invitation], messageID: String, threadID: String, error: String? = nil) async throws {
        try await write { db, change in
            let main = invitations.first { $0.recurrenceID == nil } ?? invitations.first
            let payload = invitations.isEmpty ? nil : String(decoding: try Self.encoder.encode(invitations), as: UTF8.self)
            try db.run(
                """
                INSERT INTO invitations(message_id, thread_id, uid, method, sequence, recurrence_id, payload, error, parsed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(message_id) DO UPDATE SET thread_id = excluded.thread_id, uid = excluded.uid, method = excluded.method,
                    sequence = excluded.sequence, recurrence_id = excluded.recurrence_id, payload = excluded.payload, error = excluded.error,
                    parsed_at = excluded.parsed_at
                """,
                [
                    messageID, threadID, main?.uid, main?.method.rawValue, main?.sequence ?? 0, main?.recurrenceID?.occurrenceKey, payload,
                    error ?? (invitations.isEmpty ? "no events" : nil), Date(),
                ]
            )
            change.threadIDs.insert(threadID)
            change.calendar = true
        }
    }

    /// Invitation files in a conversation, oldest message first.
    public func invitations(threadID: String) async throws -> [StoredInvitation] {
        try await read { db in try Self.storedInvitations(where: "i.thread_id = ?", [threadID], db) }
    }

    /// Invitation files about one event (same UID), oldest first.
    public func invitations(uid: String) async throws -> [StoredInvitation] {
        try await read { db in try Self.storedInvitations(where: "i.uid = ?", [uid], db) }
    }

    /// Invitations (REQUEST) whose event is on no calendar: Google has not added them, or they arrived before calendar sync.
    /// Left out: meetings cancelled since (a CANCEL as new or newer, for the whole event or that occurrence), meetings the
    /// sync removed from your calendar (the organizer deleted them, or took you off), and mail in Trash or Spam.
    public func invitationsWithoutEvents() async throws -> [StoredInvitation] {
        try await read { db in try Self.storedInvitations(where: Self.withoutEvents, [], db) }
    }

    /// Events known only from mail: those of `invitationsWithoutEvents`, each read together with the cancellations of
    /// its single dates (which count wherever their mail is, as for whole events). Only `uid`'s event when it is given.
    public func mailOnlyEvents(uid: String? = nil) async throws -> [InvitedEvent] {
        try await read { db in
            let only = uid == nil ? "" : " AND i.uid = ?"
            let values: [SQLBindable] = uid.map { [$0] } ?? []
            let waiting = try Self.storedInvitations(where: Self.withoutEvents + only, values, db)
            let uids = Set(waiting.compactMap(\.main?.uid))
            guard !uids.isEmpty else { return [] }
            let cancelled = try Self.storedInvitations(where: "i.method = 'CANCEL' AND i.recurrence_id IS NOT NULL" + only, values, db)
                .filter { $0.main.map { uids.contains($0.uid) } ?? false }
            let files = (waiting + cancelled).sorted { $0.date < $1.date }
            return InvitedEvent.events(from: files.flatMap(\.invitations).filter { uids.contains($0.uid) })
        }
    }

    /// For list rows: the latest invitation in each of these conversations.
    public func latestInvitations(threadIDs: [String]) async throws -> [String: StoredInvitation] {
        guard !threadIDs.isEmpty else { return [:] }
        return try await read { db in
            var result: [String: StoredInvitation] = [:]
            for start in stride(from: 0, to: threadIDs.count, by: 400) {
                let chunk = Array(threadIDs[start..<min(start + 400, threadIDs.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for stored in try Self.storedInvitations(where: "i.thread_id IN (\(placeholders))", chunk, db) {
                    result[stored.threadID] = stored
                }
            }
            return result
        }
    }

    // MARK: - Helpers

    /// `invitationsWithoutEvents`, as a condition on `invitations i`.
    static let withoutEvents = """
        i.method = 'REQUEST' AND NOT EXISTS (SELECT 1 FROM events e WHERE e.ical_uid = i.uid)
        AND NOT EXISTS (
            SELECT 1 FROM invitations c WHERE c.uid = i.uid AND c.method = 'CANCEL' AND c.sequence >= i.sequence
                AND (c.recurrence_id IS NULL OR c.recurrence_id = i.recurrence_id)
        )
        AND NOT EXISTS (SELECT 1 FROM message_labels l WHERE l.message_id = i.message_id AND l.label_id IN ('TRASH', 'SPAM'))
        AND NOT EXISTS (SELECT 1 FROM removed_events r WHERE r.uid = i.uid AND r.sequence >= i.sequence)
        """

    static let agendaSelect = """
        SELECT o.calendar_id, o.series_id, o.original_start, o.start_ms, o.end_ms, o.start_day, o.end_day, e.payload
        FROM occurrences o JOIN events e ON e.calendar_id = o.calendar_id AND e.id = o.event_id

        """

    static func decodeAgendaItem(_ row: SQLRow) throws -> AgendaItem {
        let event = try decoder.decode(CalendarEvent.self, from: Data(row.string(7).utf8))
        let start: EventTime
        let end: EventTime
        if let startDay = row.optionalString(5).flatMap(DayDate.init), let endDay = row.optionalString(6).flatMap(DayDate.init) {
            start = .allDay(startDay)
            end = .allDay(endDay)
        } else {
            start = .timed(row.date(3), timeZone: event.start.timeZone)
            end = .timed(row.date(4), timeZone: event.end.timeZone ?? event.start.timeZone)
        }
        return AgendaItem(calendarID: row.string(0), event: event, seriesID: row.optionalString(1), originalStart: row.string(2), start: start, end: end)
    }

    static func storedInvitations(where condition: String, _ values: [SQLBindable], _ db: SQLiteDatabase) throws -> [StoredInvitation] {
        try db.query(
            """
            SELECT i.message_id, i.thread_id, i.payload, m.date FROM invitations i JOIN messages m ON m.id = i.message_id
            WHERE \(condition) AND i.payload IS NOT NULL ORDER BY m.date
            """,
            values
        ) { row in
            StoredInvitation(
                messageID: row.string(0), threadID: row.string(1),
                invitations: try decoder.decode([Invitation].self, from: Data(row.string(2).utf8)), date: row.date(3)
            )
        }
    }

    static func storedEvent(calendarID: String, eventID: String, _ db: SQLiteDatabase) throws -> CalendarEvent? {
        try db.first("SELECT payload FROM events WHERE calendar_id = ? AND id = ?", [calendarID, eventID]) { row in
            try decoder.decode(CalendarEvent.self, from: Data(row.string(0).utf8))
        }
    }

    static func upsertEvent(_ event: CalendarEvent, _ db: SQLiteDatabase) throws {
        let payload = String(decoding: try encoder.encode(event), as: UTF8.self)
        try db.run(
            """
            INSERT INTO events(calendar_id, id, ical_uid, recurring_event_id, status, self_response, payload) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(calendar_id, id) DO UPDATE SET ical_uid = excluded.ical_uid, recurring_event_id = excluded.recurring_event_id,
                status = excluded.status, self_response = excluded.self_response, payload = excluded.payload
            """,
            [event.calendarID, event.id, event.iCalUID, event.recurringEventID, event.status.rawValue, event.selfResponse?.rawValue, payload]
        )
    }

    /// Writes an event and its occurrences as they are on the Mac.
    static func storeLocally(_ event: CalendarEvent, window: CalendarWindow, _ db: SQLiteDatabase, calendar: Calendar) throws {
        try upsertEvent(event, db)
        if let seriesID = event.recurringEventID {
            _ = try materializeSeries(calendarID: event.calendarID, seriesID: seriesID, window: window, db, calendar: calendar)
        } else if event.isSeries {
            _ = try materializeSeries(calendarID: event.calendarID, seriesID: event.id, window: window, db, calendar: calendar)
        } else {
            try materializeSingle(event, db, calendar: calendar)
        }
    }

    /// Forgets an exception the Mac made, so the occurrence follows its series again.
    static func dropException(_ event: CalendarEvent, seriesID: String, window: CalendarWindow, _ db: SQLiteDatabase, calendar: Calendar) throws {
        try db.run("DELETE FROM events WHERE calendar_id = ? AND id = ?", [event.calendarID, event.id])
        try db.run("DELETE FROM occurrences WHERE calendar_id = ? AND event_id = ?", [event.calendarID, event.id])
        let needsProvider = try materializeSeries(calendarID: event.calendarID, seriesID: seriesID, window: window, db, calendar: calendar)
        // A series only the provider expands keeps its last expansion: the occurrence this exception stood in for comes back from the series.
        guard needsProvider, let original = event.originalStart,
              let master = try storedEvent(calendarID: event.calendarID, eventID: seriesID, db), master.status != .cancelled else { return }
        let end: EventTime
        switch (original, master.start, master.end) {
        case (.allDay(let day), .allDay(let first), .allDay(let after)):
            let days = calendar.dateComponents([.day], from: first.start(in: calendar), to: after.start(in: calendar)).day ?? 1
            end = .allDay(day.adding(days: max(1, days), in: calendar))
        case (.timed(let date, let zone), _, _):
            end = .timed(date.addingTimeInterval(max(0, master.end.instant(in: calendar).timeIntervalSince(master.start.instant(in: calendar)))), timeZone: zone)
        default:
            end = original
        }
        try writeOccurrence(calendarID: event.calendarID, eventID: seriesID, seriesID: seriesID, key: occurrenceKey(original), start: original, end: end, db, calendar: calendar)
    }

    /// Removes an event; for a series also its changed occurrences.
    static func removeEvent(calendarID: String, eventID: String, _ db: SQLiteDatabase) throws {
        try db.run("DELETE FROM events WHERE calendar_id = ? AND (id = ? OR recurring_event_id = ?)", [calendarID, eventID, eventID])
        try db.run("DELETE FROM occurrences WHERE calendar_id = ? AND (event_id = ? OR series_id = ?)", [calendarID, eventID, eventID])
    }

    /// Sets the account's answer on an event and, for a series, on its changed occurrences (unless `includingOccurrences` is false).
    static func setResponse(
        _ response: ResponseStatus, comment: String?, calendarID: String, eventID: String, includingOccurrences: Bool = true, _ db: SQLiteDatabase
    ) throws {
        let rows = try db.query(
            "SELECT payload FROM events WHERE calendar_id = ? AND (id = ? OR (? AND recurring_event_id = ?))", [calendarID, eventID, includingOccurrences, eventID]
        ) { row in try decoder.decode(CalendarEvent.self, from: Data(row.string(0).utf8)) }
        for var event in rows {
            guard let index = event.attendees.firstIndex(where: \.isSelf) else { continue }
            event.attendees[index].response = response
            event.attendees[index].comment = comment
            try upsertEvent(event, db)
        }
    }

    /// The account's own answers on an event and its changed occurrences, as they are now.
    static func savedAnswers(calendarID: String, eventID: String, _ db: SQLiteDatabase) throws -> [SavedAnswer] {
        try db.query(
            "SELECT payload FROM events WHERE calendar_id = ? AND (id = ? OR recurring_event_id = ?)", [calendarID, eventID, eventID]
        ) { row in try decoder.decode(CalendarEvent.self, from: Data(row.string(0).utf8)) }
            .compactMap { event in event.selfAttendee.map { SavedAnswer(eventID: event.id, response: $0.response, comment: $0.comment) } }
    }

    static func materializeSingle(_ event: CalendarEvent, _ db: SQLiteDatabase, calendar: Calendar) throws {
        try db.run("DELETE FROM occurrences WHERE calendar_id = ? AND (event_id = ? OR series_id = ?)", [event.calendarID, event.id, event.id])
        guard event.status != .cancelled else { return }
        try writeOccurrence(calendarID: event.calendarID, eventID: event.id, seriesID: nil, key: "", start: event.start, end: event.end, db, calendar: calendar)
    }

    /// Writes a series' occurrences inside the window, with its changed and cancelled occurrences applied.
    /// Returns true when Foundation cannot expand the series and the provider's expansion is needed.
    static func materializeSeries(calendarID: String, seriesID: String, window: CalendarWindow, _ db: SQLiteDatabase, calendar: Calendar) throws -> Bool {
        let rows = try db.query(
            "SELECT payload FROM events WHERE calendar_id = ? AND (id = ? OR recurring_event_id = ?)", [calendarID, seriesID, seriesID]
        ) { row in try decoder.decode(CalendarEvent.self, from: Data(row.string(0).utf8)) }
        let master = rows.first { $0.id == seriesID }
        var exceptions: [String: CalendarEvent] = [:]
        for event in rows where event.id != seriesID {
            exceptions[occurrenceKey(event.originalStart ?? event.start)] = event
        }
        let needsProvider: Bool
        var generated: [Occurrence] = []
        if let master, master.status != .cancelled, master.isSeries {
            if let occurrences = Recurrence.occurrences(
                start: master.start, end: master.end, recurrence: master.recurrence, from: window.from, to: window.to, calendar: calendar
            ) {
                generated = occurrences
                needsProvider = false
            } else {
                needsProvider = true
            }
        } else {
            needsProvider = false
        }
        if master?.isSeries == true {
            // A single event that became a series leaves its single-occurrence row behind.
            try db.run("DELETE FROM occurrences WHERE calendar_id = ? AND event_id = ? AND original_start = '' AND series_id IS NULL", [calendarID, seriesID])
        }
        if needsProvider {
            // Keep the provider's last expansion until a new one arrives; refresh the changed occurrences only.
            for (key, exception) in exceptions {
                try db.run("DELETE FROM occurrences WHERE calendar_id = ? AND series_id = ? AND original_start = ?", [calendarID, seriesID, key])
                if exception.status != .cancelled {
                    try writeOccurrence(calendarID: calendarID, eventID: exception.id, seriesID: seriesID, key: key, start: exception.start, end: exception.end, db, calendar: calendar)
                }
            }
            return true
        }
        try db.run("DELETE FROM occurrences WHERE calendar_id = ? AND series_id = ?", [calendarID, seriesID])
        var unused = exceptions
        for occurrence in generated {
            let key = occurrenceKey(occurrence.originalStart ?? occurrence.start)
            if let exception = exceptions[key] {
                unused[key] = nil
                if exception.status == .cancelled { continue }
                try writeOccurrence(calendarID: calendarID, eventID: exception.id, seriesID: seriesID, key: key, start: exception.start, end: exception.end, db, calendar: calendar)
            } else if let master {
                try writeOccurrence(calendarID: calendarID, eventID: master.id, seriesID: seriesID, key: key, start: occurrence.start, end: occurrence.end, db, calendar: calendar)
            }
        }
        // Occurrences moved into the window from outside it, or a series that is not stored (yet).
        for (key, exception) in unused where exception.status != .cancelled {
            let start = exception.start.instant(in: calendar)
            let end = exception.end.instant(in: calendar)
            guard end > window.from, start < window.to else { continue }
            try writeOccurrence(calendarID: calendarID, eventID: exception.id, seriesID: seriesID, key: key, start: exception.start, end: exception.end, db, calendar: calendar)
        }
        return false
    }

    static func writeOccurrence(
        calendarID: String, eventID: String, seriesID: String?, key: String, start: EventTime, end: EventTime, _ db: SQLiteDatabase, calendar: Calendar
    ) throws {
        let startDay = start.day?.description
        let endDay = end.day?.description ?? start.day.map { $0.adding(days: 1, in: calendar).description }
        let startInstant = start.instant(in: calendar)
        var endInstant = end.instant(in: calendar)
        if endInstant < startInstant { endInstant = startInstant }
        try db.run(
            """
            INSERT INTO occurrences(calendar_id, event_id, series_id, original_start, start_ms, end_ms, start_day, end_day) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(calendar_id, event_id, original_start) DO UPDATE SET series_id = excluded.series_id, start_ms = excluded.start_ms,
                end_ms = excluded.end_ms, start_day = excluded.start_day, end_day = excluded.end_day
            """,
            [calendarID, eventID, seriesID, key, startInstant, endInstant, startDay, startDay == nil ? nil : endDay]
        )
    }

    /// A stable key for an occurrence within its series ("20261012T210000Z", or "20261012" for all-day).
    public static func occurrenceKey(_ time: EventTime) -> String { time.occurrenceKey }
}
