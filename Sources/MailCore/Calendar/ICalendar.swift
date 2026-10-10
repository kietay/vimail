import Foundation

/// Reads the iCalendar files (RFC 5545) that come with invitations, and writes iMIP replies (RFC 5546).
///
/// Reading is forgiving, because invitations come from many calendars: CRLF or LF line endings, a
/// byte order mark, folds inside UTF-8 sequences, missing END lines and garbage lines are all fine,
/// and nothing throws. Times keep the zone they were written in, with Windows and Outlook zone
/// names turned into IANA identifiers, the form Google Calendar uses.
public enum ICalendar {
    /// Parses an iCalendar file (an invitation attachment): one `Invitation` per VEVENT, in file order.
    /// The method comes from the enclosing VCALENDAR, PUBLISH when it has none or an unknown one.
    /// Events without a UID or a start are skipped. Floating times are read in `defaultTimeZone`.
    public static func invitations(from text: String, defaultTimeZone: TimeZone = .current) -> [Invitation] {
        let document = Document(lines: unfoldedLines(text))
        var zones = ZoneResolver(definitions: document.timeZones, defaultZone: defaultTimeZone)
        return document.events.compactMap { event in
            invitation(event.properties, method: document.method(of: event), zones: &zones)
        }
    }

    /// Parses the bytes of an invitation file. Folds are removed before the bytes are decoded, so a
    /// line folded inside a UTF-8 sequence still reads; files that are not UTF-8 are read as Windows-1252.
    public static func invitations(from data: Data, defaultTimeZone: TimeZone = .current) -> [Invitation] {
        invitations(from: text(of: data), defaultTimeZone: defaultTimeZone)
    }
}

// MARK: - Lines

extension ICalendar {
    /// One unfolded content line: `NAME;PARAM=value;PARAM="quoted, value":value`.
    struct ContentLine {
        struct Parameter {
            var name: String
            var values: [String]
        }

        /// Uppercased, as are parameter names.
        var name: String
        var parameters: [Parameter]
        var value: String

        /// The parameter's value. Values a comma split are joined again, as an unquoted `CN=Chen, Jamie` meant.
        func parameter(_ name: String) -> String? {
            parameters.first { $0.name == name }.map { $0.values.joined(separator: ",") }
        }
    }

    /// Splits text into content lines. CRLF, LF and CR end lines, and a line break followed by a space
    /// or tab is a fold: the next line continues this one.
    static func unfoldedLines(_ text: String) -> [String] {
        let scalars = text.unicodeScalars
        var lines: [String] = []
        var start = scalars.startIndex
        if start < scalars.endIndex, scalars[start] == "\u{FEFF}" { scalars.formIndex(after: &start) }

        // Slices go through the scalar view: a fold may sit before a combining mark, which Characters would swallow.
        func add(_ line: Range<String.Index>) {
            if let first = scalars[line].first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += String(scalars[line].dropFirst())
            } else {
                lines.append(String(scalars[line]))
            }
        }

        var index = start
        while index < scalars.endIndex {
            let scalar = scalars[index]
            guard scalar == "\r" || scalar == "\n" else {
                scalars.formIndex(after: &index)
                continue
            }
            add(start..<index)
            scalars.formIndex(after: &index)
            if scalar == "\r", index < scalars.endIndex, scalars[index] == "\n" { scalars.formIndex(after: &index) }
            start = index
        }
        add(start..<index)
        return lines
    }

    /// The text of a file's bytes, unfolded before decoding so that folds inside UTF-8 sequences join up.
    static func text(of data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) {
            return text
        }
        let bytes = [UInt8](data)
        var unfolded: [UInt8] = []
        unfolded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x0D || byte == 0x0A else {
                unfolded.append(byte)
                index += 1
                continue
            }
            var next = index + 1
            if byte == 0x0D, next < bytes.count, bytes[next] == 0x0A { next += 1 }
            if next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x09 {
                index = next + 1
            } else {
                unfolded.append(contentsOf: bytes[index..<next])
                index = next
            }
        }
        return String(bytes: unfolded, encoding: .utf8)
            ?? String(bytes: unfolded, encoding: .windowsCP1252)
            ?? String(decoding: unfolded, as: UTF8.self)
    }

    /// TEXT values: `\n` and `\N` are line breaks, `\,` `\;` and `\\` the characters themselves.
    /// Other backslashes are kept, as files that never escaped a Windows path need.
    static func unescapedText(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = String.UnicodeScalarView()
        var scalars = value.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\" else {
                result.append(scalar)
                continue
            }
            guard let next = scalars.next() else {
                result.append(scalar)
                break
            }
            switch next {
            case "n", "N": result.append("\n")
            case ",", ";", "\\": result.append(next)
            default: result.append(contentsOf: [scalar, next])
            }
        }
        return String(result)
    }
}

extension ICalendar.ContentLine {
    /// Reads one line, or returns nil for garbage. A quote that never closes is read as an ordinary character.
    init?(_ line: String) {
        guard let parsed = Self.parse(line, honoringQuotes: true) ?? Self.parse(line, honoringQuotes: false) else { return nil }
        self = parsed
    }

    private static func parse(_ line: String, honoringQuotes: Bool) -> Self? {
        let scalars = line.unicodeScalars
        var index = scalars.startIndex
        func read(upTo stops: String) -> String {
            let start = index
            while index < scalars.endIndex, !stops.unicodeScalars.contains(scalars[index]) { scalars.formIndex(after: &index) }
            return String(scalars[start..<index])
        }
        // Unquoted values end at `,` `;` or `:`, but not at the `://` Exchange leaves in TZID=tzone://Microsoft/Utc.
        func readUnquoted() -> String {
            let start = index
            while index < scalars.endIndex, scalars[index] != ",", scalars[index] != ";" {
                if scalars[index] == ":" {
                    guard scalars[index...].dropFirst().prefix(2).elementsEqual("//".unicodeScalars) else { break }
                    index = scalars.index(index, offsetBy: 2)
                }
                scalars.formIndex(after: &index)
            }
            return String(scalars[start..<index])
        }

        let name = read(upTo: ";:").trimmingCharacters(in: .whitespaces).uppercased()
        guard !name.isEmpty else { return nil }
        var parameters: [Parameter] = []
        while index < scalars.endIndex, scalars[index] == ";" {
            scalars.formIndex(after: &index)
            let parameterName = read(upTo: "=;:").trimmingCharacters(in: .whitespaces).uppercased()
            guard index < scalars.endIndex, scalars[index] == "=" else { continue }
            var values: [String] = []
            repeat {
                scalars.formIndex(after: &index)
                if honoringQuotes, index < scalars.endIndex, scalars[index] == "\"" {
                    scalars.formIndex(after: &index)
                    values.append(read(upTo: "\""))
                    guard index < scalars.endIndex else { return nil }
                    scalars.formIndex(after: &index)
                    _ = read(upTo: ",;:")
                } else {
                    values.append(readUnquoted())
                }
            } while index < scalars.endIndex && scalars[index] == ","
            if !parameterName.isEmpty {
                parameters.append(Parameter(name: parameterName, values: values.map(Self.decodingCarets)))
            }
        }
        guard index < scalars.endIndex, scalars[index] == ":" else { return nil }
        return Self(name: name, parameters: parameters, value: String(scalars[scalars.index(after: index)...]))
    }

    /// RFC 6868 parameter escapes: `^n` is a line break, `^'` a double quote and `^^` a caret.
    static func decodingCarets(_ value: String) -> String {
        guard value.contains("^") else { return value }
        var result = String.UnicodeScalarView()
        var scalars = value.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "^" else {
                result.append(scalar)
                continue
            }
            switch scalars.next() {
            case "n"?, "N"?: result.append("\n")
            case "'"?: result.append("\"")
            case "^"?: result.append("^")
            case let other?: result.append(contentsOf: [scalar, other])
            case nil: result.append(scalar)
            }
        }
        return String(result)
    }
}

// MARK: - Components

extension ICalendar {
    /// What invitations need from a file: its events, the METHOD of each VCALENDAR, and its VTIMEZONE blocks.
    struct Document {
        struct Event {
            /// Index into `methods`.
            var calendar: Int
            var properties: [ContentLine]
        }

        /// METHOD of each VCALENDAR in file order. The first entry stands for events outside any VCALENDAR.
        var methods: [String?]
        var events: [Event]
        /// By TZID, as `normalizedTZID` writes it.
        var timeZones: [String: ZoneDefinition]

        /// Components that only appear directly inside a VCALENDAR: when one begins, any open one was never ended.
        static let topLevel: Set<String> = ["VEVENT", "VTODO", "VJOURNAL", "VFREEBUSY", "VTIMEZONE", "VAVAILABILITY"]
        /// Deeper BEGIN lines are ignored, which bounds the work a hostile file can cause.
        static let maximumDepth = 16

        /// Reads the component structure of a file's lines. Properties of nested components (VALARM)
        /// stay out of their event, and components left open at a new BEGIN or at the end are closed.
        init(lines: [String]) {
            var methods: [String?] = [nil]
            var events: [Event] = []
            var timeZones: [String: ZoneDefinition] = [:]
            var stack: [String] = []
            var calendar = 0
            var event: [ContentLine]?
            var zone: ZoneDefinition?
            var observance: ZoneDefinition.Observance?

            func close(downTo depth: Int) {
                while stack.count > depth {
                    switch stack.removeLast() {
                    case "VEVENT":
                        if let properties = event { events.append(Event(calendar: calendar, properties: properties)) }
                        event = nil
                    case "STANDARD", "DAYLIGHT":
                        if let observance { zone?.observances.append(observance) }
                        observance = nil
                    case "VTIMEZONE":
                        if let zone, !zone.id.isEmpty, timeZones[zone.id] == nil { timeZones[zone.id] = zone }
                        zone = nil
                    case "VCALENDAR":
                        calendar = 0
                    default:
                        break
                    }
                }
            }

            for text in lines {
                guard let line = ContentLine(text) else { continue }
                switch line.name {
                case "BEGIN":
                    let component = line.value.trimmingCharacters(in: .whitespaces).uppercased()
                    if component == "VCALENDAR" {
                        close(downTo: 0)
                        methods.append(nil)
                        calendar = methods.count - 1
                    } else if Self.topLevel.contains(component) {
                        close(downTo: stack.first == "VCALENDAR" ? 1 : 0)
                    } else if stack.count >= Self.maximumDepth {
                        continue
                    }
                    switch component {
                    case "VEVENT":
                        event = []
                    case "VTIMEZONE":
                        zone = ZoneDefinition()
                    case "STANDARD", "DAYLIGHT":
                        if stack.last == "VTIMEZONE" { observance = ZoneDefinition.Observance(isDaylight: component == "DAYLIGHT") }
                    default:
                        break
                    }
                    stack.append(component)
                case "END":
                    let component = line.value.trimmingCharacters(in: .whitespaces).uppercased()
                    if let depth = stack.lastIndex(of: component) { close(downTo: depth) }
                default:
                    switch stack.last {
                    case "VCALENDAR":
                        if line.name == "METHOD", methods[calendar] == nil { methods[calendar] = line.value }
                    case "VEVENT":
                        event?.append(line)
                    case "VTIMEZONE":
                        if line.name == "TZID" { zone?.id = normalizedTZID(line.value) }
                    case "STANDARD", "DAYLIGHT":
                        observance?.read(line)
                    default:
                        break
                    }
                }
            }
            close(downTo: 0)
            self.methods = methods
            self.events = events
            self.timeZones = timeZones
        }

        func method(of event: Event) -> Invitation.Method {
            let written = methods[event.calendar]?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
            return Invitation.Method(rawValue: written) ?? .publish
        }
    }
}

// MARK: - Events

extension ICalendar {
    /// One VEVENT as an invitation, or nil when it has no UID or no start.
    static func invitation(_ properties: [ContentLine], method: Invitation.Method, zones: inout ZoneResolver) -> Invitation? {
        func first(_ name: String) -> ContentLine? { properties.first { $0.name == name } }
        func text(_ name: String) -> String? {
            guard let line = first(name) else { return nil }
            let value = unescapedText(line.value).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        func time(_ name: String) -> EventTime? {
            first(name).flatMap { eventTime($0, zones: &zones) }
        }

        guard let uid = text("UID") else { return nil }
        let recurrenceID = time("RECURRENCE-ID")
        guard let start = time("DTSTART") ?? recurrenceID else { return nil }
        var end = time("DTEND")
        if end == nil, let line = first("DURATION"), let length = duration(line.value) {
            end = adding(length, to: start)
        }
        if let written = end, !isValidEnd(written, for: start) { end = nil }

        var recurrence: [String] = []
        for line in properties {
            switch line.name {
            case "RRULE":
                let rule = line.value.trimmingCharacters(in: .whitespaces)
                if !rule.isEmpty { recurrence.append("RRULE:" + rule) }
            case "EXDATE", "RDATE":
                if let dates = recurrenceDates(line, zones: &zones) { recurrence.append(dates) }
            default:
                break
            }
        }

        let organizerLine = first("ORGANIZER")
        var organizer = organizerLine.flatMap { person($0, response: .accepted) }
        var attendees = properties.filter { $0.name == "ATTENDEE" }.compactMap { person($0, response: .needsAction) }
        if var found = organizer {
            found.isOrganizer = true
            for index in attendees.indices where attendees[index].normalized == found.normalized {
                attendees[index].isOrganizer = true
                // ORGANIZER lines rarely carry an answer; the organizer's own guest entry does.
                if organizerLine?.parameter("PARTSTAT") == nil { found.response = attendees[index].response }
                found.name = found.name ?? attendees[index].name
                attendees[index].name = attendees[index].name ?? found.name
            }
            organizer = found
        }
        if method == .reply, attendees.count == 1, attendees[0].comment == nil {
            attendees[0].comment = text("COMMENT")
        }

        let description = first("DESCRIPTION").map { unescapedText($0.value) }
        let location = text("LOCATION")
        // Outlook's busy status wins over TRANSP, as Outlook writes both and reads its own.
        let busyStatus = first("X-MICROSOFT-CDO-BUSYSTATUS")?.value.trimmingCharacters(in: .whitespaces).uppercased()
        let transparent = first("TRANSP")?.value.trimmingCharacters(in: .whitespaces).uppercased() == "TRANSPARENT"
        let free = busyStatus.map { $0 == "FREE" } ?? transparent
        let details = description.map { withoutGoogleBoilerplate($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return Invitation(
            method: method, uid: uid, sequence: first("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0,
            recurrenceID: recurrenceID, summary: text("SUMMARY") ?? "(no title)", details: details.flatMap { $0.isEmpty ? nil : $0 },
            location: location, start: start, end: end, recurrence: recurrence, organizer: organizer, attendees: attendees,
            conferenceURL: conferenceURL(google: first("X-GOOGLE-CONFERENCE")?.value, location: location, description: description),
            status: status(first("STATUS")?.value), stamp: time("DTSTAMP")?.date, showsAsFree: free ? true : nil
        )
    }

    /// An ORGANIZER or ATTENDEE line as a person, or nil when it has no email address.
    static func person(_ line: ContentLine, response defaultResponse: ResponseStatus) -> Attendee? {
        guard let email = emailAddress(line) else { return nil }
        var name = line.parameter("CN")?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Google writes the address as the name of guests it knows no name for.
        if let written = name, written.isEmpty || written.caseInsensitiveCompare(email) == .orderedSame { name = nil }
        let role = line.parameter("ROLE")?.trimmingCharacters(in: .whitespaces).uppercased()
        let type = line.parameter("CUTYPE")?.trimmingCharacters(in: .whitespaces).uppercased()
        let comment = line.parameter("X-RESPONSE-COMMENT")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Attendee(
            email: email, name: name,
            response: line.parameter("PARTSTAT").flatMap { ResponseStatus(partstat: $0.trimmingCharacters(in: .whitespaces)) } ?? defaultResponse,
            isOptional: role == "OPT-PARTICIPANT", isResource: type == "ROOM" || type == "RESOURCE",
            comment: comment?.isEmpty == false ? comment : nil
        )
    }

    /// The address of a CAL-ADDRESS line: its `mailto:` URI (in any case), else its EMAIL parameter
    /// (Apple writes `urn:uuid:` values), else a bare address. Nil when none has an `@`.
    static func emailAddress(_ line: ContentLine) -> String? {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        let mailto = value.lowercased().hasPrefix("mailto:") ? String(value.dropFirst(7)) : nil
        let bare = value.contains(":") ? nil : value
        for candidate in [mailto, line.parameter("EMAIL"), bare].compactMap({ $0 }) {
            let address = (candidate.removingPercentEncoding ?? candidate).trimmingCharacters(in: .whitespaces)
            if address.contains("@") { return address }
        }
        return nil
    }

    static func status(_ value: String?) -> EventStatus? {
        switch value?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "CONFIRMED": .confirmed
        case "TENTATIVE": .tentative
        case "CANCELLED", "CANCELED": .cancelled
        default: nil
        }
    }

    /// The join link: Google's X-GOOGLE-CONFERENCE when it is a web link, else the first meeting link in the location,
    /// then the description.
    static func conferenceURL(google: String?, location: String?, description: String?) -> String? {
        if let google = webLink(google) { return google }
        for text in [location, description].compactMap({ $0 }) {
            if let url = firstMeetingURL(in: text) { return url }
        }
        return nil
    }

    /// A link that is safe to show and open from an invitation or event: http or https, with a host. Anything else
    /// (javascript:, data:, file:, smb:, other apps' schemes) comes from whoever wrote the event, so it is dropped.
    public static func webLink(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 2048,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return text
    }

    /// The hosts `GoogleCalendarMapping.firstMeetingURL` accepts, matched the same way (the host or a subdomain).
    private static let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "webex.com", "whereby.com"]

    /// The first https video-meeting link in free text: Meet, Zoom, Teams, Webex or Whereby, subdomains
    /// included. A link ends at whitespace, `<`, `>` or a quote, and loses trailing punctuation. A byte
    /// scan rather than NSDataDetector, which takes seconds on the megabytes a hostile file can hold.
    public static func firstMeetingURL(in text: String) -> String? {
        let bytes = Array(text.utf8)
        let scheme = Array("https://".utf8)
        let stops = Array("<>\"'`".utf8), trailing = Array(".,;:!?)]}".utf8), pathStart = Array("/?#".utf8)
        var index = 0
        while index + scheme.count <= bytes.count {
            // Setting 0x20 lowercases ASCII letters and leaves ":" and "/" as they are.
            guard bytes[index] | 0x20 == scheme[0], zip(scheme, bytes[index...]).allSatisfy({ $0 == $1 | 0x20 }) else {
                index += 1
                continue
            }
            let hostStart = index + scheme.count
            var end = hostStart
            while end < bytes.count, bytes[end] > 0x20, bytes[end] < 0x7F, !stops.contains(bytes[end]) { end += 1 }
            while end > hostStart, trailing.contains(bytes[end - 1]) { end -= 1 }
            let authority = bytes[hostStart..<end].prefix { !pathStart.contains($0) }
            let hostAndPort = authority.split(separator: UInt8(ascii: "@")).last ?? []
            let host = String(decoding: hostAndPort.prefix { $0 != UInt8(ascii: ":") }, as: UTF8.self).lowercased()
            if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return String(decoding: bytes[index..<end], as: UTF8.self)
            }
            index = max(end, index + 1)
        }
        return nil
    }

    /// The description without the block Google Calendar adds between `-::~:~::~` lines (the Meet link,
    /// dial-in numbers and "Please do not edit this section."), and without the blank lines around it.
    static func withoutGoogleBoilerplate(_ text: String) -> String {
        guard text.contains("-::~:~::~") else { return text }
        var sections: [[Substring]] = [[]]
        var inBlock = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-::~:~::~"), trimmed.allSatisfy({ $0 == "-" || $0 == ":" || $0 == "~" }) {
                inBlock.toggle()
                if !inBlock { sections.append([]) }
            } else if !inBlock {
                sections[sections.count - 1].append(line)
            }
        }
        return sections.compactMap { lines -> String? in
            let isBlank: (Substring) -> Bool = { $0.allSatisfy(\.isWhitespace) }
            guard let first = lines.firstIndex(where: { !isBlank($0) }), let last = lines.lastIndex(where: { !isBlank($0) }) else { return nil }
            return lines[first...last].joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

// MARK: - Times

extension ICalendar {
    /// A DATE or DATE-TIME value as written, before a zone is applied.
    enum WrittenTime {
        case date(DayDate)
        case dateTime(DateComponents, isUTC: Bool)

        /// Reads `20261012`, `20261012T140000` and `20261012T140000Z`. Dashes and colons are skipped, for
        /// files that use ISO 8601's extended form. `dateOnly` (VALUE=DATE) reads just the date.
        init?(_ text: String, dateOnly: Bool = false) {
            let bytes = text.trimmingCharacters(in: .whitespaces).uppercased().utf8.filter { $0 != UInt8(ascii: "-") && $0 != UInt8(ascii: ":") }
            guard let year = ICalendar.number(bytes, 0..<4), let month = ICalendar.number(bytes, 4..<6), let day = ICalendar.number(bytes, 6..<8),
                  (1...12).contains(month), (1...31).contains(day) else { return nil }
            if bytes.count == 8 || dateOnly {
                self = .date(DayDate(year: year, month: month, day: day))
                return
            }
            guard bytes.count == 15 || (bytes.count == 16 && bytes[15] == UInt8(ascii: "Z")), bytes[8] == UInt8(ascii: "T"),
                  let hour = ICalendar.number(bytes, 9..<11), let minute = ICalendar.number(bytes, 11..<13),
                  let second = ICalendar.number(bytes, 13..<15), hour < 24, minute < 60, second <= 60 else { return nil }
            let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: min(second, 59))
            self = .dateTime(parts, isUTC: bytes.count == 16)
        }
    }

    /// The number ASCII digits `range` of `bytes` spell, or nil when one is not a digit.
    static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        guard range.upperBound <= bytes.count else { return nil }
        var result = 0
        for byte in bytes[range] {
            guard (48...57).contains(byte) else { return nil }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }

    /// Gregorian in UTC, for `Z` times and day arithmetic.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// A DTSTART, DTEND, RECURRENCE-ID or DTSTAMP value. A TZID names the zone, `Z` means UTC (stored
    /// without a zone), and a floating time is read in the default zone and keeps its identifier.
    static func eventTime(_ line: ContentLine, zones: inout ZoneResolver) -> EventTime? {
        let dateOnly = line.parameter("VALUE")?.trimmingCharacters(in: .whitespaces).uppercased() == "DATE"
        guard let written = WrittenTime(line.value, dateOnly: dateOnly) else { return nil }
        switch written {
        case .date(let day):
            return .allDay(day)
        case .dateTime(let parts, isUTC: true):
            return utcCalendar.date(from: parts).map { .timed($0, timeZone: nil) }
        case .dateTime(let parts, isUTC: false):
            let zone = line.parameter("TZID").map { zones.zone(forTZID: $0, year: parts.year ?? 2000) } ?? zones.floating
            return zone.date(from: parts).map { .timed($0, timeZone: zone.identifier) }
        }
    }

    /// An EXDATE or RDATE line in the form Google stores: parameters kept, a zone name rewritten to its
    /// IANA identifier, and times in a zone known only by its UTC offset rewritten in UTC.
    static func recurrenceDates(_ line: ContentLine, zones: inout ZoneResolver) -> String? {
        var parameters = line.parameters
        var value = line.value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if let index = parameters.firstIndex(where: { $0.name == "TZID" }) {
            var year = 2000
            if case .dateTime(let parts, _)? = WrittenTime(String(value.prefix { $0 != "," })) { year = parts.year ?? year }
            let zone = zones.zone(forTZID: parameters[index].values.joined(separator: ","), year: year)
            if let identifier = zone.identifier {
                parameters[index].values = [identifier]
            } else {
                parameters.remove(at: index)
                value = value.split(separator: ",").map { item in
                    guard case .dateTime(let parts, isUTC: false)? = WrittenTime(String(item)), let date = zone.date(from: parts) else { return String(item) }
                    return utcText(date)
                }.joined(separator: ",")
            }
        }
        let written = parameters.map { ";" + $0.name + "=" + $0.values.map(parameterValue).joined(separator: ",") }.joined()
        return line.name + written + ":" + value
    }

    /// A DURATION such as `PT1H30M`, `P1D` or `P2W`, as days and seconds. Nil for negative or unreadable values.
    static func duration(_ value: String) -> (days: Int, seconds: Int)? {
        var text = value.trimmingCharacters(in: .whitespaces).uppercased()[...]
        if text.first == "+" { text = text.dropFirst() }
        guard text.first == "P" else { return nil }
        let units: [Character] = ["W", "D", "T", "H", "M", "S"]
        var days = 0, seconds = 0, digits = "", next = 0, inTime = false, found = false
        for character in text.dropFirst() {
            if character.isASCII, character.isNumber {
                guard digits.count < 9 else { return nil }
                digits.append(character)
                continue
            }
            // Each unit at most once and in order, with hours, minutes and seconds after the T.
            guard let unit = units.firstIndex(of: character), unit >= next else { return nil }
            next = unit + 1
            if character == "T" {
                guard digits.isEmpty else { return nil }
                inTime = true
                continue
            }
            guard let amount = Int(digits), inTime == (unit > 2) else { return nil }
            digits = ""
            found = true
            switch character {
            case "W": days += amount * 7
            case "D": days += amount
            case "H": seconds += amount * 3600
            case "M": seconds += amount * 60
            default: seconds += amount
            }
        }
        return found && digits.isEmpty ? (days, seconds) : nil
    }

    /// `start` moved by a duration. Days count in the event's zone, so 9:00 stays 9:00 across a daylight
    /// saving change (RFC 5545's nominal days); all-day starts move by whole days only.
    static func adding(_ length: (days: Int, seconds: Int), to start: EventTime) -> EventTime? {
        switch start {
        case .allDay(let day):
            let days = length.days + length.seconds / 86_400
            return days > 0 ? .allDay(day.adding(days: days, in: utcCalendar)) : nil
        case .timed(let date, let zone):
            var calendar = utcCalendar
            if let zone, let timeZone = TimeZone(identifier: zone) { calendar.timeZone = timeZone }
            guard let moved = calendar.date(byAdding: .day, value: length.days, to: date) else { return nil }
            return .timed(moved.addingTimeInterval(TimeInterval(length.seconds)), timeZone: zone)
        }
    }

    /// An end must be the same kind of time as the start and not before it. All-day ends are exclusive,
    /// so they must be a later day; files that repeat the start day mean a one-day event.
    static func isValidEnd(_ end: EventTime, for start: EventTime) -> Bool {
        switch (start, end) {
        case (.allDay(let first), .allDay(let last)): last > first
        case (.timed(let first, _), .timed(let last, _)): last >= first
        default: false
        }
    }
}

// MARK: - Writing

extension ICalendar {
    /// `20261012T210000Z`.
    static func utcText(_ date: Date) -> String {
        let parts = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// A parameter value as written: RFC 6868 escapes for carets, double quotes and line breaks, other
    /// control characters dropped, and quotes around values with `;`, `:` or `,`.
    static func parameterValue(_ value: String) -> String {
        var encoded = ""
        for scalar in value.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            switch scalar {
            case "^": encoded += "^^"
            case "\"": encoded += "^'"
            case "\n", "\r": encoded += "^n"
            default: if scalar.properties.generalCategory != .control { encoded.unicodeScalars.append(scalar) }
            }
        }
        return encoded.contains(where: { ";:,".contains($0) }) ? "\"" + encoded + "\"" : encoded
    }
}
