import Foundation

/// A page of the calendar list. `nextSyncToken` comes on the last page only.
public struct CalendarListPage: Sendable {
    public var calendars: [CalendarInfo]
    /// IDs of calendars removed from the list since the sync token.
    public var removedIDs: [String]
    public var nextPageToken: String?
    public var nextSyncToken: String?

    public init(calendars: [CalendarInfo], removedIDs: [String] = [], nextPageToken: String? = nil, nextSyncToken: String? = nil) {
        self.calendars = calendars
        self.removedIDs = removedIDs
        self.nextPageToken = nextPageToken
        self.nextSyncToken = nextSyncToken
    }
}

/// A page of events. Deleted events come back with status `cancelled`. `nextSyncToken` comes on the last page only.
public struct EventPage: Sendable {
    public var events: [CalendarEvent]
    public var nextPageToken: String?
    public var nextSyncToken: String?

    public init(events: [CalendarEvent], nextPageToken: String? = nil, nextSyncToken: String? = nil) {
        self.events = events
        self.nextPageToken = nextPageToken
        self.nextSyncToken = nextSyncToken
    }
}

/// Who gets email about a change (Google's `sendUpdates`).
public enum SendUpdates: String, Codable, Sendable {
    case all, externalOnly, none
}

/// Calendar failures that `ProviderError` has no case for.
public enum CalendarProviderError: Error, Sendable, Equatable, LocalizedError {
    /// An event with this ID exists already (Google 409 `duplicate`). A retried create gets this.
    case duplicate
    /// The event changed since vimail read it (Google 412 for a stale `If-Match` etag).
    case changedElsewhere
    /// The account has not granted calendar access.
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .duplicate: "The event exists already"
        case .changedElsewhere: "The event changed in Google Calendar"
        case .notConnected: "Google Calendar is not connected"
        }
    }
}

/// The remote side of the calendar. Like `MailProvider`, it mirrors the Google API (Calendar v3),
/// and the app never reads from it directly: `CalendarSyncEngine` copies it into the local store.
///
/// `GoogleCalendarProvider` implements it over HTTPS; `DummyCalendarProvider` with fake data.
/// Errors are `ProviderError` (offline, rate limits, `cursorExpired` for an expired sync token)
/// or `CalendarProviderError`.
public protocol CalendarProvider: Sendable {
    /// Short identifier for logs, for example "dummy" or "google".
    var kind: String { get }

    /// The calendar list. `syncToken` nil downloads all of it.
    func calendars(syncToken: String?, pageToken: String?) async throws -> CalendarListPage
    /// Events of one calendar: series, exceptions and single events (never expanded instances).
    /// The first download passes `timeMin`; later calls pass only `syncToken`.
    func events(calendarID: String, syncToken: String?, pageToken: String?, timeMin: Date?) async throws -> EventPage
    /// The occurrences of one series in a window, as the provider expands them.
    func instances(calendarID: String, eventID: String, from: Date, to: Date) async throws -> [CalendarEvent]
    /// One event, or nil when it does not exist.
    func event(calendarID: String, eventID: String) async throws -> CalendarEvent?
    /// The events with this iCalendar UID (a series with its changed occurrences), hidden invitations included:
    /// Google keeps an invitation from an unknown sender off the calendar, and out of `events`, until it is answered.
    func events(calendarID: String, iCalUID: String) async throws -> [CalendarEvent]

    /// Creates an event with the ID it already has. Throws `CalendarProviderError.duplicate` when that ID exists.
    func insert(_ event: CalendarEvent, sendUpdates: SendUpdates, addConference: Bool) async throws -> CalendarEvent
    /// Changes an event from `previous` to `event`: only what differs is sent, so anything vimail does not know about
    /// (reminders, colors, visibility, other apps' data) stays. Without `previous`, every field vimail knows is sent.
    /// With an etag, throws `CalendarProviderError.changedElsewhere` when the event changed since.
    func update(_ event: CalendarEvent, previous: CalendarEvent?, etag: String?, sendUpdates: SendUpdates) async throws -> CalendarEvent
    func delete(calendarID: String, eventID: String, sendUpdates: SendUpdates) async throws
    /// Sets the account's own answer on an event it is invited to, leaving the other guests alone.
    func respond(calendarID: String, eventID: String, response: ResponseStatus, comment: String?, sendUpdates: SendUpdates) async throws -> CalendarEvent
    /// Busy times per address, for people whose calendars the account can see.
    /// People whose busy times are not shared with the account are left out.
    func freeBusy(emails: [String], from: Date, to: Date) async throws -> [String: [DateInterval]]

    /// Optional push hints, as for mail. The sync engine also polls.
    func changeSignals() -> AsyncStream<Void>
}

extension CalendarProvider {
    public func changeSignals() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }
}
