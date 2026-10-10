import Foundation

/// Repeating events: the RRULE, EXDATE and RDATE lines of RFC 5545, as Google Calendar and invitations carry them.
///
/// Series are expanded locally only for rule shapes verified against RFC 5545 (see `isExpandableLocally`); for
/// anything else the app asks Google (`events.instances`). Foundation's `Calendar.RecurrenceRule` steps through the
/// periods, and every date it yields is checked against the rule here. Numbered weekdays ("2TU", "-1FR") never reach
/// Foundation: it gets them wrong unless the week starts on Sunday, and "-5" makes it trap.
public enum Recurrence {
    public enum Frequency: String, Sendable, Hashable {
        case secondly = "SECONDLY", minutely = "MINUTELY", hourly = "HOURLY", daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
    }

    /// A BYDAY entry: a weekday alone ("MO") or with its place in the month or year ("2TU", "-1FR").
    public struct WeekdayNumber: Hashable, Sendable, CustomStringConvertible {
        /// 1 is the first, -1 the last. Nil means every such weekday.
        public var ordinal: Int?
        public var weekday: Locale.Weekday

        public init(ordinal: Int? = nil, weekday: Locale.Weekday) {
            self.ordinal = ordinal
            self.weekday = weekday
        }

        /// Parses "MO", "2TU", "-1FR" and "+3WE".
        public init?(_ text: String) {
            let upper = text.trimmingCharacters(in: .whitespaces).uppercased()
            guard upper.count >= 2, let weekday = Recurrence.weekday(code: String(upper.suffix(2))) else { return nil }
            let prefix = upper.dropLast(2)
            if prefix.isEmpty {
                self.init(weekday: weekday)
            } else {
                guard let ordinal = Int(prefix), ordinal != 0, (-53...53).contains(ordinal) else { return nil }
                self.init(ordinal: ordinal, weekday: weekday)
            }
        }

        /// "MO", "2TU", "-1FR".
        public var description: String { (ordinal.map(String.init) ?? "") + Recurrence.code(of: weekday) }
    }

    /// One RRULE.
    public struct Rule: Hashable, Sendable {
        public var frequency: Frequency
        /// Every `interval` days, weeks, months or years.
        public var interval: Int
        /// How many occurrences the rule makes, the first one (DTSTART) included.
        public var count: Int?
        /// The last moment an occurrence may start, inclusive: `.allDay` for a date, `.timed(_, timeZone: "UTC")` for
        /// a moment, `.timed(_, timeZone: nil)` for a floating local time (its UTC wall clock read in the event's zone).
        public var until: EventTime?
        public var byDay: [WeekdayNumber]
        /// 1...31, or -31...-1 from the end of the month (-1 is the last day).
        public var byMonthDay: [Int]
        /// 1...12.
        public var byMonth: [Int]
        public var bySetPos: [Int]
        public var byYearDay: [Int]
        public var byWeekNo: [Int]
        public var byHour: [Int]
        public var byMinute: [Int]
        public var bySecond: [Int]
        /// WKST. Nil means Monday, as in RFC 5545.
        public var weekStart: Locale.Weekday?

        public init(
            frequency: Frequency, interval: Int = 1, count: Int? = nil, until: EventTime? = nil, byDay: [WeekdayNumber] = [],
            byMonthDay: [Int] = [], byMonth: [Int] = [], bySetPos: [Int] = [], byYearDay: [Int] = [], byWeekNo: [Int] = [],
            byHour: [Int] = [], byMinute: [Int] = [], bySecond: [Int] = [], weekStart: Locale.Weekday? = nil
        ) {
            self.frequency = frequency
            self.interval = interval
            self.count = count
            self.until = until
            self.byDay = byDay
            self.byMonthDay = byMonthDay
            self.byMonth = byMonth
            self.bySetPos = bySetPos
            self.byYearDay = byYearDay
            self.byWeekNo = byWeekNo
            self.byHour = byHour
            self.byMinute = byMinute
            self.bySecond = bySecond
            self.weekStart = weekStart
        }
    }

    /// Parses "RRULE:FREQ=WEEKLY;BYDAY=MO" or a bare "FREQ=...". UNTIL may be a date (20261218), UTC (…T170000Z) or local (…T170000).
    /// Nil for unknown or repeated parts and out-of-range values.
    public static func parseRule(_ line: String) -> Rule? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = text.firstIndex(of: ":") {
            guard propertyName(text) == "RRULE" else { return nil }
            text = String(text[text.index(after: colon)...])
        }
        var parts: [String: String] = [:]
        for part in text.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[1].isEmpty, parts.updateValue(pair[1].uppercased(), forKey: pair[0].uppercased()) == nil else { return nil }
        }
        guard let frequency = parts.removeValue(forKey: "FREQ").flatMap(Frequency.init(rawValue:)) else { return nil }
        var rule = Rule(frequency: frequency)
        for (key, value) in parts {
            switch key {
            case "INTERVAL":
                guard let interval = Int(value), interval >= 1 else { return nil }
                rule.interval = interval
            case "COUNT":
                guard let count = Int(value), count >= 1 else { return nil }
                rule.count = count
            case "UNTIL":
                guard let until = parseUntil(value) else { return nil }
                rule.until = until
            case "BYDAY":
                let days = value.split(separator: ",", omittingEmptySubsequences: false).map { WeekdayNumber(String($0)) }
                guard !days.contains(nil) else { return nil }
                rule.byDay = days.compactMap { $0 }
            case "WKST":
                guard let day = weekday(code: value) else { return nil }
                rule.weekStart = day
            default:
                guard let limits = numberParts[key], let numbers = numbers(value, limits) else { return nil }
                switch key {
                case "BYMONTHDAY": rule.byMonthDay = numbers
                case "BYMONTH": rule.byMonth = numbers
                case "BYSETPOS": rule.bySetPos = numbers
                case "BYYEARDAY": rule.byYearDay = numbers
                case "BYWEEKNO": rule.byWeekNo = numbers
                case "BYHOUR": rule.byHour = numbers
                case "BYMINUTE": rule.byMinute = numbers
                default: rule.bySecond = numbers
                }
            }
        }
        return rule
    }

    /// The RRULE line for a rule ("RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261218T075959Z"). Round-trips with parseRule.
    public static func line(for rule: Rule) -> String {
        var parts = ["FREQ=" + rule.frequency.rawValue]
        func add(_ key: String, _ values: [some CustomStringConvertible]) {
            if !values.isEmpty { parts.append(key + "=" + values.map(\.description).joined(separator: ",")) }
        }
        if rule.interval != 1 { parts.append("INTERVAL=\(rule.interval)") }
        add("BYMONTH", rule.byMonth)
        add("BYWEEKNO", rule.byWeekNo)
        add("BYYEARDAY", rule.byYearDay)
        add("BYMONTHDAY", rule.byMonthDay)
        add("BYDAY", rule.byDay)
        add("BYHOUR", rule.byHour)
        add("BYMINUTE", rule.byMinute)
        add("BYSECOND", rule.bySecond)
        add("BYSETPOS", rule.bySetPos)
        if let weekStart = rule.weekStart { parts.append("WKST=" + code(of: weekStart)) }
        if let count = rule.count { parts.append("COUNT=\(count)") }
        if let until = rule.until { parts.append("UNTIL=" + untilText(until)) }
        return "RRULE:" + parts.joined(separator: ";")
    }

    /// True when every line parses and every RRULE has a shape whose local expansion is verified against RFC 5545:
    /// DAILY; WEEKLY with plain BYDAY; MONTHLY by BYMONTHDAY or numbered BYDAY ("2TU", "-1FR"); YEARLY on its start
    /// date or by BYMONTH with BYMONTHDAY or numbered BYDAY; each with INTERVAL, COUNT, UNTIL and WKST. Anything else
    /// (plain BYDAY in MONTHLY or YEARLY, BYSETPOS, BYYEARDAY, BYWEEKNO, BYHOUR and the like, sub-daily rules,
    /// EXRULE, RDATE periods) is left to the provider.
    public static func isExpandableLocally(_ recurrence: [String]) -> Bool {
        recurrence.filter { propertyName($0) == "RRULE" }.count <= ruleLimit && recurrence.allSatisfy { line in
            switch parseLine(line) {
            case .rule(let rule)?: isSupported(rule)
            case .dates(let list)?: !list.hasPeriods
            case nil: false
            }
        }
    }

    /// Occurrences of a series whose first occurrence is start..end, overlapping [from, to), in order. Nil when
    /// `isExpandableLocally` is false, or when a rule needs more than 20,000 steps to get through the window (a
    /// COUNT series that runs for decades, or a window decades long); ask the provider then.
    ///
    /// Handles RRULE (several make a union), EXDATE (removes), RDATE (adds), COUNT (counted from the first occurrence
    /// of the whole series, which always counts) and UNTIL (inclusive). The first occurrence is always included, even
    /// when it does not match the rule, unless an EXDATE removes it. Timed series repeat at the same wall-clock time in
    /// the event's zone across DST changes; all-day series repeat by date.
    public static func occurrences(start: EventTime, end: EventTime, recurrence: [String], from: Date, to: Date, calendar: Calendar) -> [Occurrence]? {
        expansion(start: start, end: end, recurrence: recurrence, from: from, to: to, calendar: calendar)?.occurrences
    }
}

// MARK: - Lines and values

extension Recurrence {
    /// A DATE or DATE-TIME value.
    enum Stamp: Hashable, Sendable {
        case date(DayDate)
        /// A wall-clock time in `zone`, or floating (in the event's zone) when nil.
        case local(DayDate, secondOfDay: Int, zone: TimeZone?)
        case utc(Date)
    }

    /// An EXDATE or RDATE line.
    struct DateList: Sendable {
        var isExclusion: Bool
        var stamps: [Stamp]
        /// RDATE;VALUE=PERIOD, which local expansion does not handle.
        var hasPeriods: Bool
    }

    enum Line: Sendable {
        case rule(Rule)
        case dates(DateList)
    }

    static let weekdays: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
    static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// The allowed magnitude of each numeric part, and whether it may be negative.
    private static let numberParts: [String: (range: ClosedRange<Int>, signed: Bool)] = [
        "BYMONTHDAY": (1...31, true), "BYMONTH": (1...12, false), "BYSETPOS": (1...366, true), "BYYEARDAY": (1...366, true),
        "BYWEEKNO": (1...53, true), "BYHOUR": (0...23, false), "BYMINUTE": (0...59, false), "BYSECOND": (0...60, false),
    ]

    /// 1 for Sunday through 7 for Saturday, as `Calendar` numbers weekdays.
    static func number(of weekday: Locale.Weekday) -> Int { (weekdays.firstIndex(of: weekday) ?? 0) + 1 }
    static func code(of weekday: Locale.Weekday) -> String { weekdayCodes[number(of: weekday) - 1] }

    static func weekday(code: String) -> Locale.Weekday? {
        weekdayCodes.firstIndex(of: code.uppercased()).map { weekdays[$0] }
    }

    /// "RRULE" for "RRULE:..." and for a bare "FREQ=...", otherwise the name before the first ";" or ":".
    static func propertyName(_ line: String) -> String {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard text.contains(":") else { return text.hasPrefix("FREQ=") ? "RRULE" : "" }
        return String(text.prefix { $0 != ":" && $0 != ";" })
    }

    static func parseLine(_ line: String) -> Line? {
        switch propertyName(line) {
        case "RRULE": parseRule(line).map(Line.rule)
        case "EXDATE", "RDATE": parseDates(line).map(Line.dates)
        default: nil
        }
    }

    /// Parses `EXDATE;TZID=America/Los_Angeles:20261013T090000,20261020T090000`, `EXDATE:20261013T160000Z`,
    /// `EXDATE;VALUE=DATE:20261013` and the same forms of RDATE.
    static func parseDates(_ line: String) -> DateList? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let head = text[..<colon].split(separator: ";")
        guard let name = head.first?.uppercased(), name == "EXDATE" || name == "RDATE" else { return nil }
        var zone: TimeZone?
        var kind = "DATE-TIME"
        for parameter in head.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            switch pair[0].trimmingCharacters(in: .whitespaces).uppercased() {
            case "TZID":
                guard let found = TimeZone(identifier: value.hasPrefix("/") ? String(value.dropFirst()) : value) else { return nil }
                zone = found
            case "VALUE": kind = value.uppercased()
            default: continue
            }
        }
        let values = text[text.index(after: colon)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !values.isEmpty else { return nil }
        if kind == "PERIOD" { return DateList(isExclusion: name == "EXDATE", stamps: [], hasPeriods: true) }
        guard kind == "DATE" || kind == "DATE-TIME" else { return nil }
        var stamps: [Stamp] = []
        for value in values {
            guard let stamp = parseStamp(value, zone: zone) else { return nil }
            if kind == "DATE" {
                guard case .date = stamp else { return nil }
            }
            stamps.append(stamp)
        }
        return DateList(isExclusion: name == "EXDATE", stamps: stamps, hasPeriods: false)
    }

    /// Parses "20261013", "20261013T090000" (wall clock in `zone`, floating when nil) and "20261013T160000Z".
    static func parseStamp(_ text: String, zone: TimeZone? = nil) -> Stamp? {
        let chars = Array(text.uppercased())
        guard chars.count == 8 || chars.count == 15 || (chars.count == 16 && chars[15] == "Z") else { return nil }
        let digits = chars.count == 8 ? chars[0..<8] : chars[0..<8] + chars[9..<15]
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let day = DayDate(String(chars[0..<8])),
              day.day <= daysIn(month: day.month, year: day.year) else { return nil }
        if chars.count == 8 { return .date(day) }
        guard chars[8] == "T", let hour = Int(String(chars[9..<11])), let minute = Int(String(chars[11..<13])),
              let second = Int(String(chars[13..<15])), hour < 24, minute < 60, second <= 60 else { return nil }
        let seconds = hour * 3600 + minute * 60 + second
        if chars.count == 15 { return .local(day, secondOfDay: seconds, zone: zone) }
        return instant(day, secondOfDay: seconds, in: utc).map(Stamp.utc)
    }

    static func parseUntil(_ text: String) -> EventTime? {
        switch parseStamp(text) {
        case .date(let day)?: .allDay(day)
        case .utc(let date)?: .timed(date, timeZone: "UTC")
        case .local(let day, let second, _)?: instant(day, secondOfDay: second, in: utc).map { .timed($0, timeZone: nil) }
        case nil: nil
        }
    }

    static func untilText(_ until: EventTime) -> String {
        switch until {
        case .allDay(let day):
            return String(format: "%04d%02d%02d", day.year, day.month, day.day)
        case .timed(let date, let zone):
            let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let text = String(
                format: "%04d%02d%02dT%02d%02d%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1,
                parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
            )
            return zone == nil ? text : text + "Z"
        }
    }

    static func instant(_ day: DayDate, secondOfDay: Int, in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: secondOfDay / 3600, minute: secondOfDay / 60 % 60, second: secondOfDay % 60
        ))
    }

    private static func numbers(_ text: String, _ limits: (range: ClosedRange<Int>, signed: Bool)) -> [Int]? {
        var result: [Int] = []
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard let number = Int(item.trimmingCharacters(in: .whitespaces)) else { return nil }
            let valid = limits.signed
                ? number != 0 && (-limits.range.upperBound...limits.range.upperBound).contains(number)
                : limits.range.contains(number)
            guard valid else { return nil }
            result.append(number)
        }
        return result
    }

    /// Whether the rule has a shape whose expansion here is verified (see `isExpandableLocally`).
    static func isSupported(_ rule: Rule) -> Bool {
        guard (1...1000).contains(rule.interval), (rule.count ?? 1) >= 1, rule.bySetPos.isEmpty, rule.byYearDay.isEmpty,
              rule.byWeekNo.isEmpty, rule.byHour.isEmpty, rule.byMinute.isEmpty, rule.bySecond.isEmpty,
              rule.byMonthDay.allSatisfy({ $0 != 0 && (-31...31).contains($0) }), rule.byMonth.allSatisfy({ (1...12).contains($0) })
        else { return false }
        let numbered = rule.byDay.allSatisfy { $0.ordinal.map { $0 != 0 && (-5...5).contains($0) } ?? false }
        switch rule.frequency {
        case .daily:
            return rule.byDay.isEmpty && rule.byMonthDay.isEmpty && rule.byMonth.isEmpty
        case .weekly:
            return rule.byMonthDay.isEmpty && rule.byMonth.isEmpty && rule.byDay.allSatisfy { $0.ordinal == nil }
        case .monthly:
            return rule.byMonth.isEmpty && (rule.byDay.isEmpty || (rule.byMonthDay.isEmpty && numbered))
        case .yearly:
            if rule.byMonth.isEmpty { return rule.byDay.isEmpty && rule.byMonthDay.isEmpty }
            return rule.byDay.isEmpty || (rule.byMonthDay.isEmpty && numbered)
        case .secondly, .minutely, .hourly:
            return false
        }
    }
}
