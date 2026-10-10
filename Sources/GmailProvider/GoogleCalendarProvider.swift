import Foundation
import HTTPKit
import MailCore
import VimailLog

/// Google Calendar through its REST API (v3). `CalendarSyncEngine` uses it exactly like the dummy calendar.
///
/// It shares the Gmail sign-in (the same OAuth client and refresh token, with calendar scopes) but has
/// its own pacer: Calendar's quota (600 requests a minute per user by default) is separate from Gmail's.
public actor GoogleCalendarProvider: CalendarProvider {
    public nonisolated let kind = "google"
    private nonisolated let api: GoogleCalendarAPI
    static let log = Log("calendar")

    /// - Parameter credential: nil when signed out. Every call then fails with `ProviderError.unauthorized`.
    public init(credential: GoogleCredential?, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(credential: credential, transport: transport, pacer: QuotaPacer(unitsPerSecond: 5, maxRate: 10, burst: 20, maxConcurrent: 4))
    }

    init(credential: GoogleCredential?, transport: any HTTPTransport, pacer: QuotaPacer) {
        api = GoogleCalendarAPI(transport: transport, tokens: GoogleTokenSource(credential: credential, transport: transport), pacer: pacer)
    }

    static func eventsPath(_ calendarID: String) -> String { "calendars/\(calendarID)/events" }

    // MARK: - Reading

    public func calendars(syncToken: String?, pageToken: String?) async throws -> CalendarListPage {
        var query = [URLQueryItem(name: "maxResults", value: "250")]
        if let syncToken { query.append(URLQueryItem(name: "syncToken", value: syncToken)) }
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let list: GCalendarList = try await api.get("users/me/calendarList", query)
        let items = list.items ?? []
        return CalendarListPage(
            calendars: items.filter { $0.deleted != true }.map(GoogleCalendarMapping.calendar),
            removedIDs: items.filter { $0.deleted == true }.map(\.id),
            nextPageToken: list.nextPageToken, nextSyncToken: list.nextSyncToken
        )
    }

    public func events(calendarID: String, syncToken: String?, pageToken: String?, timeMin: Date?) async throws -> EventPage {
        var query = [
            URLQueryItem(name: "maxResults", value: "2500"),
            URLQueryItem(name: "singleEvents", value: "false"),
            // Invitations Google hides (from unknown senders, until answered) stay hidden, as the account's setting
            // asks: `events(calendarID:iCalUID:)` finds one when you answer it.
        ]
        if let syncToken {
            query.append(URLQueryItem(name: "syncToken", value: syncToken))
        } else if let timeMin {
            query.append(URLQueryItem(name: "timeMin", value: GoogleCalendarMapping.formatDateTime(timeMin)))
        }
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let list: GEventList = try await api.get(Self.eventsPath(calendarID), query, priority: syncToken == nil ? .bulk : .interactive)
        return EventPage(
            events: (list.items ?? []).compactMap { GoogleCalendarMapping.event($0, calendarID: calendarID) },
            nextPageToken: list.nextPageToken, nextSyncToken: list.nextSyncToken
        )
    }

    public func instances(calendarID: String, eventID: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        var result: [CalendarEvent] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "timeMin", value: GoogleCalendarMapping.formatDateTime(from)),
                URLQueryItem(name: "timeMax", value: GoogleCalendarMapping.formatDateTime(to)),
                URLQueryItem(name: "maxResults", value: "2500"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let list: GEventList = try await api.get(Self.eventsPath(calendarID) + "/\(eventID)/instances", query, priority: .bulk)
            result += (list.items ?? []).compactMap { GoogleCalendarMapping.event($0, calendarID: calendarID) }
            pageToken = list.nextPageToken
        } while pageToken != nil
        return result
    }

    public func events(calendarID: String, iCalUID: String) async throws -> [CalendarEvent] {
        let query = [
            URLQueryItem(name: "iCalUID", value: iCalUID),
            URLQueryItem(name: "showHiddenInvitations", value: "true"),
            URLQueryItem(name: "maxResults", value: "250"),
        ]
        let list: GEventList = try await api.get(Self.eventsPath(calendarID), query)
        return (list.items ?? []).compactMap { GoogleCalendarMapping.event($0, calendarID: calendarID) }
    }

    public func event(calendarID: String, eventID: String) async throws -> CalendarEvent? {
        do {
            let resource: GEvent = try await api.get(Self.eventsPath(calendarID) + "/\(eventID)")
            return GoogleCalendarMapping.event(resource, calendarID: calendarID)
        } catch ProviderError.notFound {
            return nil
        } catch ProviderError.cursorExpired {
            // 410: the event was deleted.
            return nil
        }
    }

    // MARK: - Changing

    public func insert(_ event: CalendarEvent, sendUpdates: SendUpdates, addConference: Bool) async throws -> CalendarEvent {
        var query = [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)]
        if addConference { query.append(URLQueryItem(name: "conferenceDataVersion", value: "1")) }
        let created: GEvent = try await api.send("POST", Self.eventsPath(event.calendarID), query: query, json: GoogleCalendarMapping.resource(event, addConference: addConference))
        Self.log.info("Created event \(event.id) with \(event.attendees.count) guest(s)")
        return try Self.mapped(created, calendarID: event.calendarID)
    }

    /// `events.patch` with the changed fields only: `events.update` would reset everything vimail does not model.
    public func update(_ event: CalendarEvent, previous: CalendarEvent?, etag: String?, sendUpdates: SendUpdates) async throws -> CalendarEvent {
        let patch = GoogleCalendarMapping.patch(event, from: previous)
        guard !patch.isEmpty else {
            // Nothing changed: no request, so no update email either.
            return try await self.event(calendarID: event.calendarID, eventID: event.id) ?? event
        }
        let updated: GEvent = try await api.send(
            "PATCH", Self.eventsPath(event.calendarID) + "/\(event.id)",
            query: [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)], json: patch, ifMatch: etag
        )
        Self.log.info("Changed event \(event.id)")
        return try Self.mapped(updated, calendarID: event.calendarID)
    }

    public func delete(calendarID: String, eventID: String, sendUpdates: SendUpdates) async throws {
        do {
            try await api.perform("DELETE", Self.eventsPath(calendarID) + "/\(eventID)", query: [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)])
            Self.log.info("Removed event \(eventID)")
        } catch ProviderError.notFound {
            // Already gone.
        } catch ProviderError.cursorExpired {
            // 410: already deleted.
        }
    }

    public func respond(calendarID: String, eventID: String, response: ResponseStatus, comment: String?, sendUpdates: SendUpdates) async throws -> CalendarEvent {
        // Your own entry is the one Google marks "self": an alias or a group invitation may use another address than the account's.
        let current: GEvent = try await api.get(Self.eventsPath(calendarID) + "/\(eventID)")
        guard let me = current.attendees?.first(where: { $0.isSelf == true })?.email else {
            throw ProviderError.rejected("You are not a guest of this event")
        }
        let patched: GEvent = try await api.send(
            "PATCH", Self.eventsPath(calendarID) + "/\(eventID)",
            query: [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)],
            json: GResponsePatch(attendees: [GEventPerson(email: me, responseStatus: response.rawValue, comment: comment)])
        )
        Self.log.info("Answered \(response.rawValue) to event \(eventID)")
        return try Self.mapped(patched, calendarID: calendarID)
    }

    /// Longest range one free/busy request asks for: Google refuses about three months and more (`timeRangeTooLong`).
    static let freeBusyChunk: TimeInterval = 60 * 86_400

    public func freeBusy(emails: [String], from: Date, to: Date) async throws -> [String: [DateInterval]] {
        guard !emails.isEmpty, from < to else { return [:] }
        var result: [String: [DateInterval]] = [:]
        var hidden = Set<String>()
        var chunkStart = from
        while chunkStart < to {
            let chunkEnd = min(to, chunkStart.addingTimeInterval(Self.freeBusyChunk))
            let request = GFreeBusyRequest(
                timeMin: GoogleCalendarMapping.formatDateTime(chunkStart), timeMax: GoogleCalendarMapping.formatDateTime(chunkEnd),
                items: emails.prefix(50).map { .init(id: $0) }
            )
            let response: GFreeBusyResponse = try await api.send("POST", "freeBusy", json: request)
            for (email, calendar) in response.calendars ?? [:] {
                let key = email.lowercased()
                guard calendar.errors?.isEmpty ?? true else {
                    hidden.insert(key)
                    continue
                }
                result[key, default: []] += (calendar.busy ?? []).compactMap { period in
                    guard let start = GoogleCalendarMapping.parseDateTime(period.start), let end = GoogleCalendarMapping.parseDateTime(period.end), end > start else { return nil }
                    return DateInterval(start: start, end: end)
                }
            }
            chunkStart = chunkEnd
        }
        for key in hidden { result[key] = nil }
        return result
    }

    static func mapped(_ resource: GEvent, calendarID: String) throws -> CalendarEvent {
        guard let event = GoogleCalendarMapping.event(resource, calendarID: calendarID) else {
            throw ProviderError.rejected("Unexpected event from Google Calendar")
        }
        return event
    }
}
