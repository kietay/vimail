import Foundation
import MailCore

/// A local calendar change waiting to be pushed to the provider.
public enum CalendarOperation: Hashable, Codable, Sendable {
    /// The account's own answer to an invitation. `previous` restores it after an undo or a refusal.
    case respond(calendarID: String, eventID: String, response: ResponseStatus, comment: String?, previous: ResponseStatus?, sendUpdates: SendUpdates)
    /// Creates `event` with the ID the Mac chose for it.
    case insert(event: CalendarEvent, sendUpdates: SendUpdates, addConference: Bool)
    /// Replaces an event. `previous` is the version the edit started from (its etag guards against overwriting newer changes).
    case update(event: CalendarEvent, previous: CalendarEvent, sendUpdates: SendUpdates)
    case delete(event: CalendarEvent, sendUpdates: SendUpdates)

    /// The event this operation changes.
    public var target: (calendarID: String, eventID: String) {
        switch self {
        case .respond(let calendarID, let eventID, _, _, _, _): (calendarID, eventID)
        case .insert(let event, _, _), .update(let event, _, _), .delete(let event, _): (event.calendarID, event.id)
        }
    }

    /// Operations on one event leave in the order they were made: the calendar and the event, with an
    /// occurrence (`<series>_<key>`) counted as its series. Google's event IDs never contain "_" otherwise.
    public var queueKey: String {
        let target = target
        let event = target.eventID.split(separator: "_", maxSplits: 1).first.map(String.init) ?? target.eventID
        return "\(target.calendarID)|\(event)"
    }

    /// For logs: the kind and the event ID, never titles or guests.
    public var logDescription: String {
        switch self {
        case .respond(_, let eventID, let response, let comment, _, let updates): "answer \(response.rawValue) to \(eventID)\(comment == nil ? "" : " with a note") (updates: \(updates.rawValue))"
        case .insert(let event, let updates, let conference): "create \(event.id) with \(event.attendees.count) guest(s)\(conference ? " and a conference link" : "") (updates: \(updates.rawValue))"
        case .update(let event, _, let updates): "change \(event.id) (updates: \(updates.rawValue))"
        case .delete(let event, let updates): "remove \(event.id) (updates: \(updates.rawValue))"
        }
    }

    /// The local effect of this operation on a provider version of its event, so a sync that
    /// arrives before the push does not undo what you just did. Nil means "remove the event".
    public func applied(to event: CalendarEvent) -> CalendarEvent? {
        switch self {
        case .respond(_, _, let response, let comment, _, _):
            var copy = event
            if let index = copy.attendees.firstIndex(where: \.isSelf) {
                copy.attendees[index].response = response
                copy.attendees[index].comment = comment
            }
            return copy
        case .insert(let local, _, _), .update(let local, _, _):
            return local
        case .delete:
            return nil
        }
    }
}

public struct CalendarOutboxItem: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var operation: CalendarOperation
    public var attempts: Int
    public var notBefore: Date
    public var lastError: String?
    public var isInFlight: Bool
}

extension MailStore {
    /// Queues an operation. `id` puts a dropped operation back in its old place (undo).
    static func enqueueCalendar(_ operation: CalendarOperation, notBefore: Date = .distantPast, id: Int64? = nil, _ db: SQLiteDatabase) throws -> Int64 {
        let payload = String(decoding: try encoder.encode(operation), as: UTF8.self)
        try db.run(
            "INSERT INTO calendar_outbox(id, target, payload, not_before, created_at) VALUES (?, ?, ?, ?, ?)",
            [id, operation.queueKey, payload, notBefore == .distantPast ? 0 : notBefore.sqlValue, Date()]
        )
        return db.lastInsertRowID
    }

    /// An operation waits while an older one on the same event is still queued or in flight.
    static let headOfQueue = "NOT EXISTS (SELECT 1 FROM calendar_outbox p WHERE p.target = o.target AND p.id < o.id)"

    static func decodeCalendarOutbox(_ row: SQLRow) throws -> CalendarOutboxItem {
        CalendarOutboxItem(
            id: row.int64(0),
            operation: try decoder.decode(CalendarOperation.self, from: Data(row.string(1).utf8)),
            attempts: row.int(2),
            notBefore: row.date(3),
            lastError: row.optionalString(4),
            isInFlight: row.string(5) == "inflight"
        )
    }

    /// Pending and in-flight calendar operations, oldest first.
    static func calendarOutboxItems(_ db: SQLiteDatabase) throws -> [CalendarOutboxItem] {
        try db.query("SELECT id, payload, attempts, not_before, last_error, state FROM calendar_outbox ORDER BY id", [], decodeCalendarOutbox)
    }

    public func enqueueCalendar(_ operation: CalendarOperation, notBefore: Date = .distantPast) async throws -> Int64 {
        try await write { db, change in
            change.calendar = true
            return try Self.enqueueCalendar(operation, notBefore: notBefore, db)
        }
    }

    public func calendarOutboxItems() async throws -> [CalendarOutboxItem] {
        try await read { db in try Self.calendarOutboxItems(db) }
    }

    /// Claims the oldest due calendar operation by marking it in flight. Operations on one event go one at a time, in order.
    public func claimNextCalendarOperation(now: Date = Date()) async throws -> CalendarOutboxItem? {
        try await write { db, _ in
            guard var item = try db.first(
                """
                SELECT o.id, o.payload, o.attempts, o.not_before, o.last_error, o.state FROM calendar_outbox o
                WHERE o.state = 'pending' AND o.not_before <= ? AND \(Self.headOfQueue) ORDER BY o.id LIMIT 1
                """,
                [now], Self.decodeCalendarOutbox
            ) else { return nil }
            try db.run("UPDATE calendar_outbox SET state = 'inflight' WHERE id = ?", [item.id])
            item.isInFlight = true
            return item
        }
    }

    /// When the next operation that can leave is due (the first of each event's queue).
    public func nextCalendarOperationDueDate() async throws -> Date? {
        try await read { db in
            try db.first("SELECT MIN(o.not_before) FROM calendar_outbox o WHERE o.state = 'pending' AND \(Self.headOfQueue)") { $0.optionalDate(0) } ?? nil
        }
    }

    public func completeCalendarOperation(_ id: Int64) async throws {
        try await write { db, change in
            try db.run("DELETE FROM calendar_outbox WHERE id = ?", [id])
            change.calendar = true
        }
    }

    /// Returns a calendar operation to the queue after a transient failure.
    public func retryCalendarOperation(_ id: Int64, error: String, retryAt: Date) async throws {
        try await write { db, _ in
            try db.run(
                "UPDATE calendar_outbox SET state = 'pending', attempts = attempts + 1, last_error = ?, not_before = ? WHERE id = ?",
                [error, retryAt, id]
            )
        }
    }

    /// On launch, calendar operations left in flight by a crash go back to pending (as an attempt).
    /// Only the calendar outbox: the mail engine resets its own.
    public func resetInflightCalendarOperations() async throws {
        try await write { db, _ in try db.run("UPDATE calendar_outbox SET state = 'pending', attempts = attempts + 1 WHERE state = 'inflight'") }
    }

    public func calendarOutboxCount() async throws -> Int {
        try await read { db in try db.scalar("SELECT COUNT(*) FROM calendar_outbox") }
    }

    /// Removes a calendar operation if it has not been picked up yet. Returns true when it was removed.
    public func cancelCalendarOperation(_ id: Int64) async throws -> Bool {
        try await write { db, change in
            try db.run("DELETE FROM calendar_outbox WHERE id = ? AND state = 'pending'", [id])
            let removed = db.changes > 0
            if removed { change.calendar = true }
            return removed
        }
    }
}
