import Foundation
import MailCore

// Calendar API v3 resources (https://developers.google.com/workspace/calendar/api/v3/reference), only the fields vimail uses.

struct GCalendarListEntry: Decodable {
    var id: String
    var summary: String?
    var summaryOverride: String?
    var timeZone: String?
    var backgroundColor: String?
    var accessRole: String?
    var primary: Bool?
    var selected: Bool?
    var hidden: Bool?
    var deleted: Bool?
}

struct GCalendarList: Decodable {
    var items: [GCalendarListEntry]?
    var nextPageToken: String?
    var nextSyncToken: String?
}

struct GEventDateTime: Codable {
    var date: String?
    var dateTime: String?
    var timeZone: String?
}

struct GEventPerson: Codable {
    var email: String?
    var displayName: String?
    /// Google's `self`: this entry is the calendar's own account.
    var isSelf: Bool?
    var organizer: Bool?
    var resource: Bool?
    var optional: Bool?
    var responseStatus: String?
    var comment: String?

    enum CodingKeys: String, CodingKey {
        case email, displayName, isSelf = "self", organizer, resource, optional, responseStatus, comment
    }
}

struct GConferenceSolutionKey: Codable {
    var type: String
}

struct GConferenceCreateRequest: Codable {
    var requestId: String
    var conferenceSolutionKey: GConferenceSolutionKey
}

struct GEntryPoint: Codable {
    var entryPointType: String?
    var uri: String?
}

struct GConferenceData: Codable {
    var entryPoints: [GEntryPoint]?
    var createRequest: GConferenceCreateRequest?
}

struct GEvent: Codable {
    var id: String?
    var status: String?
    var htmlLink: String?
    var updated: String?
    var summary: String?
    var description: String?
    var location: String?
    var organizer: GEventPerson?
    var start: GEventDateTime?
    var end: GEventDateTime?
    var recurrence: [String]?
    var recurringEventId: String?
    var originalStartTime: GEventDateTime?
    var transparency: String?
    var iCalUID: String?
    var sequence: Int?
    var attendees: [GEventPerson]?
    var attendeesOmitted: Bool?
    var hangoutLink: String?
    var conferenceData: GConferenceData?
    var eventType: String?
    var etag: String?
}

struct GEventList: Decodable {
    var items: [GEvent]?
    var nextPageToken: String?
    var nextSyncToken: String?
}

/// A date or date-time in `events.patch`. All three keys are sent, the unused ones as null, so a switch between
/// timed and all-day clears the old kind.
struct GPatchTime: Encodable {
    var time: GEventDateTime

    enum CodingKeys: String, CodingKey { case date, dateTime, timeZone }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time.date, forKey: .date)
        try container.encode(time.dateTime, forKey: .dateTime)
        try container.encode(time.timeZone, forKey: .timeZone)
    }
}

/// Body of `events.patch`: only the fields that changed (nil ones are left out). Google keeps everything not sent;
/// `events.update` would reset it.
struct GEventPatch: Encodable {
    var status: String?
    var summary: String?
    var description: String?
    var location: String?
    var start: GPatchTime?
    var end: GPatchTime?
    var recurrence: [String]?
    var transparency: String?
    var attendees: [GEventPerson]?

    var isEmpty: Bool {
        status == nil && summary == nil && description == nil && location == nil && start == nil && end == nil && recurrence == nil
            && transparency == nil && attendees == nil
    }
}

/// Body of an answer: only your own guest entry, with `attendeesOmitted` so the other guests stay as they are.
struct GResponsePatch: Encodable {
    var attendeesOmitted = true
    var attendees: [GEventPerson]
}

struct GFreeBusyRequest: Encodable {
    struct Item: Encodable { var id: String }
    var timeMin: String
    var timeMax: String
    var items: [Item]
}

struct GFreeBusyResponse: Decodable {
    struct Period: Decodable {
        var start: String
        var end: String
    }

    struct Calendar: Decodable {
        struct Problem: Decodable { var reason: String? }
        var busy: [Period]?
        /// Set when the account cannot see this person's calendar ("notFound", "groupTooBig").
        var errors: [Problem]?
    }

    var calendars: [String: Calendar]?
}
