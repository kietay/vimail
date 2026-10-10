import Foundation
import MailCore

/// Converts Calendar API resources to vimail's models and back.
enum GoogleCalendarMapping {
    static func calendar(_ entry: GCalendarListEntry) -> CalendarInfo {
        let role = CalendarInfo.AccessRole(rawValue: entry.accessRole ?? "") ?? .reader
        return CalendarInfo(
            id: entry.id, summary: entry.summaryOverride ?? entry.summary ?? entry.id, timeZone: entry.timeZone,
            color: entry.backgroundColor, accessRole: role, isPrimary: entry.primary ?? false,
            isSelected: (entry.selected ?? false) && !(entry.hidden ?? false)
        )
    }

    /// The event, or nil when Google sent one without an ID.
    static func event(_ resource: GEvent, calendarID: String) -> CalendarEvent? {
        guard let id = resource.id else { return nil }
        let originalStart = resource.originalStartTime.flatMap(time)
        let cancelled = resource.status == "cancelled"
        // Removed events may carry only their ID and status (occurrences also their series and original
        // start). They still come through, so the store can remove them.
        guard let start = resource.start.flatMap(time) ?? originalStart ?? (cancelled ? .allDay(DayDate(year: 1970, month: 1, day: 1)) : nil) else { return nil }
        let end = resource.end.flatMap(time) ?? start
        let organizer = resource.organizer.flatMap { person(isOrganizer: true, $0) }
        var attendees = (resource.attendees ?? []).compactMap { person(isOrganizer: false, $0) }
        if let organizer {
            for index in attendees.indices where attendees[index].normalized == organizer.normalized { attendees[index].isOrganizer = true }
        }
        return CalendarEvent(
            id: id, calendarID: calendarID, iCalUID: resource.iCalUID,
            status: EventStatus(rawValue: resource.status ?? "") ?? .confirmed,
            summary: resource.summary.flatMap { $0.isEmpty ? nil : $0 } ?? "(no title)",
            details: resource.description.flatMap { $0.isEmpty ? nil : $0 },
            location: resource.location.flatMap { $0.isEmpty ? nil : $0 },
            start: start, end: end, recurrence: resource.recurrence ?? [], recurringEventID: resource.recurringEventId,
            originalStart: originalStart, organizer: organizer, attendees: attendees,
            conferenceURL: conferenceURL(resource), htmlLink: resource.htmlLink, etag: resource.etag,
            updated: resource.updated.flatMap(parseDateTime), sequence: resource.sequence ?? 0,
            isBusy: resource.transparency != "transparent", eventType: resource.eventType ?? "default"
        )
    }

    /// The resource for `events.insert` and `events.update`.
    static func resource(_ event: CalendarEvent, addConference: Bool) -> GEvent {
        GEvent(
            id: event.id, status: event.status.rawValue, summary: event.summary, description: event.details, location: event.location,
            start: dateTime(event.start), end: dateTime(event.end), recurrence: event.recurrence.isEmpty ? nil : event.recurrence,
            // One occurrence of a series names its series and the time it replaces.
            recurringEventId: event.recurringEventID, originalStartTime: event.originalStart.map(dateTime),
            transparency: event.isBusy ? "opaque" : "transparent",
            attendees: event.attendees.isEmpty ? nil : event.attendees.map { person($0, comments: false) },
            conferenceData: addConference
                ? GConferenceData(createRequest: GConferenceCreateRequest(requestId: UUID().uuidString.lowercased(), conferenceSolutionKey: .init(type: "hangoutsMeet")))
                : nil
        )
    }

    /// The `events.patch` body that turns `previous` into `event`: the changed fields only, or every field vimail
    /// knows without `previous`. A cleared text goes as "", a cleared list as []. Guests go whole when they changed
    /// (a patch replaces the list), with the answers and notes Google sent.
    static func patch(_ event: CalendarEvent, from previous: CalendarEvent?) -> GEventPatch {
        func changed<Value: Equatable>(_ path: KeyPath<CalendarEvent, Value>) -> Bool {
            previous.map { $0[keyPath: path] != event[keyPath: path] } ?? true
        }
        var patch = GEventPatch()
        if changed(\.status) { patch.status = event.status.rawValue }
        if changed(\.summary) { patch.summary = event.summary }
        if changed(\.details) { patch.description = event.details ?? "" }
        if changed(\.location) { patch.location = event.location ?? "" }
        if changed(\.start) || changed(\.end) {
            patch.start = GPatchTime(time: dateTime(event.start))
            patch.end = GPatchTime(time: dateTime(event.end))
        }
        // An occurrence of a series has no rule of its own.
        if event.recurringEventID == nil, changed(\.recurrence) { patch.recurrence = event.recurrence }
        if changed(\.isBusy) { patch.transparency = event.isBusy ? "opaque" : "transparent" }
        if changed(\.attendees) { patch.attendees = event.attendees.map { person($0, comments: true) } }
        return patch
    }

    /// A guest entry to send. Only your own answer is yours to set; others' answers are sent as Google gave them,
    /// so it keeps them. `comments`: every guest's note too (a patch replaces the whole list).
    static func person(_ attendee: Attendee, comments: Bool) -> GEventPerson {
        GEventPerson(
            email: attendee.email, displayName: attendee.name, resource: attendee.isResource ? true : nil, optional: attendee.isOptional ? true : nil,
            responseStatus: attendee.isSelf || attendee.response != .needsAction ? attendee.response.rawValue : nil,
            comment: attendee.isSelf || comments ? attendee.comment : nil
        )
    }

    static func person(isOrganizer: Bool, _ person: GEventPerson) -> Attendee? {
        guard let email = person.email, !email.isEmpty else { return nil }
        return Attendee(
            email: email, name: person.displayName, response: ResponseStatus(rawValue: person.responseStatus ?? "") ?? (isOrganizer ? .accepted : .needsAction),
            isSelf: person.isSelf ?? false, isOrganizer: isOrganizer || (person.organizer ?? false), isOptional: person.optional ?? false,
            isResource: person.resource ?? false, comment: person.comment
        )
    }

    static func conferenceURL(_ resource: GEvent) -> String? {
        // Only web links: an entry point can be any URI the event's creator set.
        if let video = ICalendar.webLink(resource.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri) { return video }
        if let hangout = ICalendar.webLink(resource.hangoutLink) { return hangout }
        for text in [resource.location, resource.description].compactMap({ $0 }) {
            if let url = firstMeetingURL(in: text) { return url }
        }
        return nil
    }

    /// The first video-meeting link in free text (Meet, Zoom, Teams, Webex, Whereby): the invitation parser's scanner,
    /// which stays fast on very long descriptions.
    static func firstMeetingURL(in text: String) -> String? {
        ICalendar.firstMeetingURL(in: text)
    }

    // MARK: - Times

    static func time(_ value: GEventDateTime) -> EventTime? {
        if let date = value.date, let day = DayDate(date) { return .allDay(day) }
        if let text = value.dateTime, let date = parseDateTime(text) { return .timed(date, timeZone: value.timeZone) }
        return nil
    }

    static func dateTime(_ time: EventTime) -> GEventDateTime {
        switch time {
        case .allDay(let day):
            return GEventDateTime(date: day.description)
        case .timed(let date, let zone):
            return GEventDateTime(dateTime: formatDateTime(date), timeZone: zone)
        }
    }

    static func parseDateTime(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func formatDateTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
