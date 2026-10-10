import Foundation

/// A calendar date without a time or a zone, as all-day events use ("2026-10-12").
/// All-day events stay on their dates in every time zone, so they are never stored as instants.
public struct DayDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses "2026-10-12" and the iCalendar form "20261012".
    public init?(_ string: String) {
        let digits = string.filter(\.isNumber)
        guard digits.count == 8, string.count == 8 || string.count == 10,
              let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)), let day = Int(digits.suffix(2)),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The date of `date` in `calendar`'s time zone.
    public init(_ date: Date, in calendar: Calendar = .current) {
        let parts = Self.gregorian(calendar).dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// The Gregorian calendar in `calendar`'s time zone: a DayDate's fields are Gregorian whichever calendar the Mac uses
    /// (Buddhist, Japanese, …), as in Google and iCalendar.
    public static func gregorian(_ calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// "2026-10-12", the form Google and the store use.
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Midnight at the start of this date in `calendar`'s time zone.
    public func start(in calendar: Calendar = .current) -> Date {
        Self.gregorian(calendar).date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days: Int, in calendar: Calendar = .current) -> DayDate {
        let gregorian = Self.gregorian(calendar)
        return DayDate(gregorian.date(byAdding: .day, value: days, to: start(in: gregorian)) ?? start(in: gregorian), in: gregorian)
    }

    public static func < (lhs: DayDate, rhs: DayDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension DayDate: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = DayDate(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// When an event starts or ends: a moment with the zone it was written in, or a whole day.
public enum EventTime: Hashable, Sendable {
    /// A moment. `timeZone` is the IANA zone of the event (for display and for repeating it); nil means UTC or unknown.
    case timed(Date, timeZone: String?)
    /// An all-day date. The end of an all-day event is the day after its last day, as in Google and iCalendar.
    case allDay(DayDate)

    public var isAllDay: Bool {
        if case .allDay = self { return true }
        return false
    }

    /// The moment, for timed values.
    public var date: Date? {
        if case .timed(let date, _) = self { return date }
        return nil
    }

    /// The date, for all-day values.
    public var day: DayDate? {
        if case .allDay(let day) = self { return day }
        return nil
    }

    public var timeZone: String? {
        if case .timed(_, let zone) = self { return zone }
        return nil
    }

    /// The moment this time starts. All-day values start at midnight in `calendar`'s zone.
    public func instant(in calendar: Calendar = .current) -> Date {
        switch self {
        case .timed(let date, _): date
        case .allDay(let day): day.start(in: calendar)
        }
    }

    /// The date this time falls on in `calendar`'s zone.
    public func dayDate(in calendar: Calendar = .current) -> DayDate {
        switch self {
        case .timed(let date, _): DayDate(date, in: calendar)
        case .allDay(let day): day
        }
    }
}

extension EventTime {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A stable key for one occurrence of a series, the suffix Google uses in instance IDs:
    /// "20261012T210000Z", or "20261012" for all-day occurrences.
    public var occurrenceKey: String {
        switch self {
        case .allDay(let day):
            return String(format: "%04d%02d%02d", day.year, day.month, day.day)
        case .timed(let date, _):
            let parts = Self.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            return String(format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        }
    }

    /// The time an occurrence key names: "20261012T210000Z" (shown in `timeZone`) or "20261012" (all day).
    public init?(occurrenceKey key: String, timeZone: String? = nil) {
        if key.count == 8 {
            guard let day = DayDate(key) else { return nil }
            self = .allDay(day)
            return
        }
        let digits = Array(key)
        guard key.count == 16, digits[8] == "T", digits[15] == "Z",
              let year = Int(String(digits[0..<4])), let month = Int(String(digits[4..<6])), let day = Int(String(digits[6..<8])),
              let hour = Int(String(digits[9..<11])), let minute = Int(String(digits[11..<13])), let second = Int(String(digits[13..<15])),
              let date = Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
        else { return nil }
        self = .timed(date, timeZone: timeZone)
    }
}

extension EventTime: Codable {
    private enum CodingKeys: String, CodingKey { case date, dateTime, timeZone }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let day = try container.decodeIfPresent(DayDate.self, forKey: .date) {
            self = .allDay(day)
        } else {
            let milliseconds = try container.decode(Double.self, forKey: .dateTime)
            self = .timed(Date(timeIntervalSince1970: milliseconds / 1000), timeZone: try container.decodeIfPresent(String.self, forKey: .timeZone))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allDay(let day):
            try container.encode(day, forKey: .date)
        case .timed(let date, let zone):
            try container.encode((date.timeIntervalSince1970 * 1000).rounded(), forKey: .dateTime)
            try container.encodeIfPresent(zone, forKey: .timeZone)
        }
    }
}

/// A guest's answer to an invitation. Raw values are Google's.
public enum ResponseStatus: String, Codable, Sendable, CaseIterable {
    case needsAction, accepted, tentative, declined

    /// iCalendar's PARTSTAT for this answer.
    public var partstat: String {
        switch self {
        case .needsAction: "NEEDS-ACTION"
        case .accepted: "ACCEPTED"
        case .tentative: "TENTATIVE"
        case .declined: "DECLINED"
        }
    }

    public init?(partstat: String) {
        switch partstat.uppercased() {
        case "NEEDS-ACTION": self = .needsAction
        case "ACCEPTED": self = .accepted
        case "TENTATIVE": self = .tentative
        case "DECLINED": self = .declined
        default: return nil
        }
    }

    /// "yes", "maybe", "no", "waiting": the words the event page uses.
    public var word: String {
        switch self {
        case .needsAction: "waiting"
        case .accepted: "yes"
        case .tentative: "maybe"
        case .declined: "no"
        }
    }
}

public enum EventStatus: String, Codable, Sendable {
    case confirmed, tentative, cancelled
}

/// A guest or organizer of an event.
public struct Attendee: Hashable, Codable, Sendable {
    public var email: String
    public var name: String?
    public var response: ResponseStatus
    /// This entry is the calendar's own account.
    public var isSelf: Bool
    public var isOrganizer: Bool
    public var isOptional: Bool
    /// A room or other resource rather than a person.
    public var isResource: Bool
    /// The guest's note with their answer.
    public var comment: String?

    public init(
        email: String, name: String? = nil, response: ResponseStatus = .needsAction, isSelf: Bool = false,
        isOrganizer: Bool = false, isOptional: Bool = false, isResource: Bool = false, comment: String? = nil
    ) {
        self.email = email
        self.name = name
        self.response = response
        self.isSelf = isSelf
        self.isOrganizer = isOrganizer
        self.isOptional = isOptional
        self.isResource = isResource
        self.comment = comment
    }

    public var address: EmailAddress { EmailAddress(name: name, email: email) }
    public var normalized: String { email.lowercased() }
}

/// A calendar the account can see.
public struct CalendarInfo: Identifiable, Hashable, Codable, Sendable {
    public enum AccessRole: String, Codable, Sendable {
        case freeBusyReader, reader, writer, owner
    }

    public var id: String
    public var summary: String
    /// IANA time zone of the calendar.
    public var timeZone: String?
    /// "#9fe1e7"-style background color from Google.
    public var color: String?
    public var accessRole: AccessRole
    public var isPrimary: Bool
    /// Shown in Google Calendar's list. vimail syncs and shows these.
    public var isSelected: Bool

    public init(id: String, summary: String, timeZone: String? = nil, color: String? = nil, accessRole: AccessRole = .owner, isPrimary: Bool = false, isSelected: Bool = true) {
        self.id = id
        self.summary = summary
        self.timeZone = timeZone
        self.color = color
        self.accessRole = accessRole
        self.isPrimary = isPrimary
        self.isSelected = isSelected
    }

    public var canEdit: Bool { accessRole == .owner || accessRole == .writer }
}

/// One event as the calendar provider stores it: a single event, a repeating series, or one changed
/// occurrence of a series (an exception, with `recurringEventID` and `originalStart`).
public struct CalendarEvent: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var calendarID: String
    /// The iCalendar UID. Invitations in mail carry the same UID.
    public var iCalUID: String?
    public var status: EventStatus
    public var summary: String
    public var details: String?
    public var location: String?
    public var start: EventTime
    public var end: EventTime
    /// RRULE, EXDATE and RDATE lines of a series. Empty for single events and exceptions.
    public var recurrence: [String]
    /// For an exception: the series it belongs to.
    public var recurringEventID: String?
    /// For an exception: when this occurrence would have started.
    public var originalStart: EventTime?
    public var organizer: Attendee?
    public var attendees: [Attendee]
    /// The join link (Google Meet, Zoom, ...).
    public var conferenceURL: String?
    /// Google's web link to the event.
    public var htmlLink: String?
    public var etag: String?
    public var updated: Date?
    public var sequence: Int
    /// False when the event does not block time ("free" in Google Calendar).
    public var isBusy: Bool
    /// "default", "outOfOffice", "focusTime", "workingLocation", "birthday", "fromGmail".
    public var eventType: String

    public init(
        id: String, calendarID: String, iCalUID: String? = nil, status: EventStatus = .confirmed, summary: String,
        details: String? = nil, location: String? = nil, start: EventTime, end: EventTime, recurrence: [String] = [],
        recurringEventID: String? = nil, originalStart: EventTime? = nil, organizer: Attendee? = nil, attendees: [Attendee] = [],
        conferenceURL: String? = nil, htmlLink: String? = nil, etag: String? = nil, updated: Date? = nil, sequence: Int = 0,
        isBusy: Bool = true, eventType: String = "default"
    ) {
        self.id = id
        self.calendarID = calendarID
        self.iCalUID = iCalUID
        self.status = status
        self.summary = summary
        self.details = details
        self.location = location
        self.start = start
        self.end = end
        self.recurrence = recurrence
        self.recurringEventID = recurringEventID
        self.originalStart = originalStart
        self.organizer = organizer
        self.attendees = attendees
        self.conferenceURL = conferenceURL
        self.htmlLink = htmlLink
        self.etag = etag
        self.updated = updated
        self.sequence = sequence
        self.isBusy = isBusy
        self.eventType = eventType
    }

    public var isSeries: Bool { !recurrence.isEmpty }
    public var isException: Bool { recurringEventID != nil }
    /// The account's own guest entry, when it was invited.
    public var selfAttendee: Attendee? { attendees.first(where: \.isSelf) }
    /// The account's answer, or nil when it is not a guest (its own events).
    public var selfResponse: ResponseStatus? { selfAttendee?.response }
    public var organizerIsSelf: Bool { organizer?.isSelf ?? (selfAttendee?.isOrganizer ?? attendees.isEmpty) }

    /// One occurrence of this series as its own event, the way Google names it (`<series ID>_<occurrence key>`).
    /// Changing or removing it changes only that occurrence.
    public func instance(originalStart: EventTime, start: EventTime, end: EventTime) -> CalendarEvent {
        var instance = self
        instance.id = "\(id)_\(originalStart.occurrenceKey)"
        instance.recurrence = []
        instance.recurringEventID = id
        instance.originalStart = originalStart
        instance.start = start
        instance.end = end
        instance.etag = nil
        return instance
    }
}

/// One occurrence on the calendar: a single event, or one date of a series.
public struct Occurrence: Hashable, Sendable {
    public var start: EventTime
    public var end: EventTime
    /// For series: the start this occurrence has in the rule (stable even when moved). Nil for single events.
    public var originalStart: EventTime?

    public init(start: EventTime, end: EventTime, originalStart: EventTime? = nil) {
        self.start = start
        self.end = end
        self.originalStart = originalStart
    }
}

/// A calendar invitation found in mail: the parsed `text/calendar` part of a message.
public struct Invitation: Hashable, Codable, Sendable {
    /// iTIP METHOD of the file.
    public enum Method: String, Codable, Sendable {
        case request = "REQUEST"
        case cancel = "CANCEL"
        case reply = "REPLY"
        case counter = "COUNTER"
        case publish = "PUBLISH"
        case refresh = "REFRESH"
        case declineCounter = "DECLINECOUNTER"
        case add = "ADD"
    }

    public var method: Method
    public var uid: String
    public var sequence: Int
    /// Set when the invitation is about one occurrence of a series.
    public var recurrenceID: EventTime?
    public var summary: String
    public var details: String?
    public var location: String?
    public var start: EventTime
    public var end: EventTime?
    /// RRULE, EXDATE and RDATE lines, as in `CalendarEvent.recurrence`.
    public var recurrence: [String]
    public var organizer: Attendee?
    public var attendees: [Attendee]
    public var conferenceURL: String?
    public var status: EventStatus?
    /// DTSTAMP: when the organizer's calendar wrote the file.
    public var stamp: Date?
    /// True when the event shows as free: Outlook's status for your copy (X-MICROSOFT-CDO-INTENDEDSTATUS, else
    /// BUSYSTATUS) is Free or Working elsewhere, or, without it, TRANSP:TRANSPARENT. It does not take your time. Nil
    /// (busy) in files read before this was kept.
    public var showsAsFree: Bool?

    public init(
        method: Method, uid: String, sequence: Int = 0, recurrenceID: EventTime? = nil, summary: String, details: String? = nil,
        location: String? = nil, start: EventTime, end: EventTime? = nil, recurrence: [String] = [], organizer: Attendee? = nil,
        attendees: [Attendee] = [], conferenceURL: String? = nil, status: EventStatus? = nil, stamp: Date? = nil, showsAsFree: Bool? = nil
    ) {
        self.method = method
        self.uid = uid
        self.sequence = sequence
        self.recurrenceID = recurrenceID
        self.summary = summary
        self.details = details
        self.location = location
        self.start = start
        self.end = end
        self.recurrence = recurrence
        self.organizer = organizer
        self.attendees = attendees
        self.conferenceURL = conferenceURL
        self.status = status
        self.stamp = stamp
        self.showsAsFree = showsAsFree
    }

    public var isCancellation: Bool { method == .cancel || status == .cancelled }

    /// The end, or the start plus a default length when the file has none.
    public var effectiveEnd: EventTime {
        if let end { return end }
        switch start {
        case .allDay(let day): return .allDay(day.adding(days: 1))
        case .timed(let date, let zone): return .timed(date.addingTimeInterval(3600), timeZone: zone)
        }
    }

    /// The guest entry for one of `addresses` (the account's own addresses, lowercased).
    public func attendee(matching addresses: Set<String>) -> Attendee? {
        attendees.first { addresses.contains($0.normalized) }
    }
}
