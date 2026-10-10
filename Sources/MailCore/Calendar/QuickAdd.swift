import Foundation

/// Quick add: one typed line becomes the fields of a new event, like Google Calendar's quick add but local and
/// instant. "lunch with jamie fri 12:30 1h @ Tartine" is lunch next Friday, 12:30 to 13:30, at Tartine, with Jamie.
///
/// The grammar, case-insensitive:
/// - Day: `today`, `tonight` (19:00 unless a time is given, and bare hours mean pm), `tomorrow`/`tom`, `mon`...`sun`
///   and full names (the next such day; today's weekday means a week ahead, as in snooze), `next tue` (7 days after
///   `tue`), `on fri`, `oct 16`, `16 oct`, `october 16th`, `oct 16 2027`, `10/16`, `10/16/27`, `2026-10-16`, `in 3d`,
///   `in 2w`, `in 3 days`. A month and day that has passed means next year. `fri-sun`, `oct 16-18`, `oct 16-18 2027`,
///   `16-18 oct`, `oct 30 - nov 2` and `mon to wed` span several days. A day without a time is an all-day event; so is
///   anything with `all day`. Several days with a time range start on the first day and end on the last:
///   `oct 9-11 09:00-17:00`.
/// - Time: `9am`, `9:30pm`, `9 am`, `14:00`, `noon`, `midnight`, `at 3`, `@ 3`, and the ranges `9-10`, `9:30-11`,
///   `2-3pm`, `11am-1pm`, `14:00-15:30`, `2pm–3pm`, `2pm to 3pm`, `from 9 to 5`. Without am/pm, hours 1-7 are pm,
///   8-11 am and 12 noon, while `03:30` and `15:30` are 24-hour. A bare number is a time only after `at` or `@`, or in
///   a dash range, so "lunch for 2" keeps its 2. A time without a day is today when still ahead, else tomorrow.
///   `in 2h` and `in 30 min` start that long from now.
/// - Length: `30m`, `45min`, `1h`, `1h30`, `1.5h`, `90m`, `2 hours`, `30-min`, `for 1h`; otherwise `defaultLength`.
/// - Guests: `with jamie`, `with jamie and alex`, `with jamie, alex`. Names end at the next recognized part, at a
///   word such as "about", "to" or "for", or at the end, and stay in the title. Email addresses anywhere are guests.
/// - Place: `@ Tartine` or `@Tartine`, up to the next recognized part, `with`, or the end.
/// - Conference: `meet` or `video` as the last word, unless it is the only word.
/// - Repeats: `daily`, `every day`, `every weekday`, `weekly`, `every tue`, `every mon and wed`, `every 2 weeks`,
///   `every other week`, `biweekly`, `monthly`, `yearly`/`annually`, then optionally `until <date>`, `x8` or `8 times`.
///   A weekly rule that names its days starts on one of them: `fri every tue` starts on the Tuesday after that Friday.
/// - Calendar: `#work`.
///
/// When a part appears twice (two days, two times), the first one counts and the second stays in the title.
/// Dates are Gregorian, in `calendar`'s time zone.
public enum QuickAdd {
    /// What a part of the typed line was read as, for highlighting it in the UI.
    public enum Role: String, Sendable, Hashable {
        case day, time, length, guest, place, conference, repeats, calendar
    }

    /// A recognized part of the line. `start` and `end` are Character offsets into the input, `end` exclusive.
    public struct Token: Hashable, Sendable {
        public var role: Role
        public var start: Int
        public var end: Int

        public init(role: Role, start: Int, end: Int) {
            self.role = role
            self.start = start
            self.end = end
        }
    }

    /// The event fields read from one line.
    public struct Result: Hashable, Sendable {
        /// The words not read as anything else, first letter uppercased, or "(no title)".
        public var title: String
        /// Nil when no day or time was understood.
        public var start: EventTime?
        public var end: EventTime?
        /// Contacts matched by the names after "with", and typed email addresses, in typed order.
        public var guests: [EmailAddress]
        /// Names after "with" that matched no contact, as typed.
        public var unknownGuests: [String]
        public var location: String?
        /// The line ends with "meet" or "video".
        public var addConference: Bool
        /// RRULE lines, e.g. ["RRULE:FREQ=WEEKLY;BYDAY=TU"].
        public var recurrence: [String]
        /// The calendar named with "#work", without the "#".
        public var calendarHint: String?
        /// Every recognized part, in order.
        public var tokens: [Token]

        public init(
            title: String, start: EventTime? = nil, end: EventTime? = nil, guests: [EmailAddress] = [], unknownGuests: [String] = [],
            location: String? = nil, addConference: Bool = false, recurrence: [String] = [], calendarHint: String? = nil, tokens: [Token] = []
        ) {
            self.title = title
            self.start = start
            self.end = end
            self.guests = guests
            self.unknownGuests = unknownGuests
            self.location = location
            self.addConference = addConference
            self.recurrence = recurrence
            self.calendarHint = calendarHint
            self.tokens = tokens
        }

        public var hasTime: Bool { start != nil }
    }

    /// Reads one line such as "lunch with jamie fri 12:30 1h @ Tartine".
    /// `contacts` returns address book matches for a typed name (best first); it is called once per name.
    public static func parse(
        _ text: String, now: Date, calendar: Calendar, defaultLength: TimeInterval = 1800, contacts: (String) -> [EmailAddress]
    ) -> Result {
        var parser = QuickAddParser(text: text, now: now, calendar: calendar)
        parser.readConference()
        parser.readCalendar()
        parser.readEmails()
        parser.readRepeat()
        parser.readWhen()
        parser.readPlace()
        parser.readGuests(contacts)
        return parser.result(defaultLength: defaultLength)
    }
}

/// One pass per kind of part over the words of the line. Each pass claims the words it reads, so later passes
/// (places and guest names, which run until the next recognized part) see where the earlier parts are.
private struct QuickAddParser {
    /// A word of the line. Whitespace separates chunks; a chunk's surrounding punctuation is dropped, and it is
    /// split again at dashes and after a leading "@", so "fri-sun" and "@Tartine" are three and two words.
    struct Word {
        var text: String
        var lower: String
        var start: Int
        var end: Int
        var chunk: Int
        var opensChunk: Bool
        var closesChunk: Bool
    }

    struct Chunk {
        var start: Int
        var end: Int
        /// The chunk ends with a comma ("jamie,").
        var comma: Bool
        /// The chunk ends a sentence or clause ("jamie:", "jamie.").
        var stop: Bool
    }

    struct Span {
        var role: QuickAdd.Role
        var words: Range<Int>
        /// Guest names stay in the title.
        var keepsText = false
    }

    /// A time as typed, before am/pm is settled.
    struct Clock {
        var hour: Int
        var minute: Int
        /// "a" or "p".
        var meridiem: Character?
        /// 24-hour ("15:30", "03:30", "0") or named ("noon"): no am/pm guessing.
        var exact: Bool
        /// A number alone ("3"): a time only after "at" or in a range.
        var bare: Bool
    }

    struct SingleDay {
        var date: DayDate
        var next: Int
        var hasMonth = false
        var weekday: Int?
        var tonight = false
        /// The year was typed ("oct 16 2027", "10/16/27").
        var typedYear = false
    }

    struct DayRange {
        var first: DayDate
        var last: DayDate
        var tonight: Bool
        var next: Int
    }

    struct Repeat {
        var frequency: String
        var interval = 1
        /// Calendar weekdays, 1 = Sunday.
        var weekdays: [Int] = []
        /// "every tue": the rule names its days, so it also picks the start day.
        var namesDays = false
    }

    static let openers: Set<Character> = ["(", "[", "{", "\"", "“", "‘", "'", "<"]
    static let closers: Set<Character> = [",", ";", ".", "!", "?", ":", ")", "]", "}", "\"", "”", "’", "'", ">"]
    static let dashes: Set<Character> = ["-", "–", "—"]
    static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3, "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]
    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6,
        "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10,
        "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]
    static let lengthUnits: [String: Int] = [
        "m": 1, "min": 1, "mins": 1, "minute": 1, "minutes": 1, "h": 60, "hr": 60, "hrs": 60, "hour": 60, "hours": 60,
    ]
    static let frequencies: [String: String] = [
        "day": "DAILY", "days": "DAILY", "week": "WEEKLY", "weeks": "WEEKLY", "month": "MONTHLY", "months": "MONTHLY",
        "year": "YEARLY", "years": "YEARLY",
    ]
    static let workweek = [2, 3, 4, 5, 6]
    static let joiners: Set<String> = ["and", "&", "+"]
    /// Words that end the names after "with": "lunch with jamie about the budget".
    static let nameStops: Set<String> = ["about", "re", "regarding", "to", "for", "on", "at", "in", "from", "until", "|", "/"]
    static let maxMinutes = 7 * 24 * 60

    let chars: [Character]
    let now: Date
    let calendar: Calendar
    let today: DayDate
    var words: [Word] = []
    var chunks: [Chunk] = []
    var used: [Bool] = []
    /// "until fri" without a repeat: left in the title as typed.
    var reserved: [Bool] = []
    var spans: [Span] = []
    /// "tom" is read as tomorrow only when no other day was found, so "talk to tom fri" keeps Tom.
    var allowTom = false

    var addConference = false
    var calendarHint: String?
    var emailSpans: [Int: Int] = [:]
    var rule: Repeat?
    var until: DayDate?
    var count: Int?
    var allDay = false
    var days: DayRange?
    var clock: (start: Clock, end: Clock?)?
    var length: Int?
    var location: String?
    var guests: [(offset: Int, address: EmailAddress)] = []
    var unknownGuests: [String] = []
    var capitals: Set<Int> = []

    init(text: String, now: Date, calendar: Calendar) {
        chars = Array(text)
        self.now = now
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        self.calendar = gregorian
        today = DayDate(now, in: gregorian)
        var index = 0
        while index < chars.count {
            guard !chars[index].isWhitespace else {
                index += 1
                continue
            }
            var end = index
            while end < chars.count, !chars[end].isWhitespace { end += 1 }
            var coreStart = index
            var coreEnd = end
            while coreStart < coreEnd, Self.openers.contains(chars[coreStart]) { coreStart += 1 }
            while coreEnd > coreStart, Self.closers.contains(chars[coreEnd - 1]) { coreEnd -= 1 }
            let trailing = chars[coreEnd..<end]
            let pieces = Self.pieces(of: chars, from: coreStart, to: coreEnd)
            for (position, piece) in pieces.enumerated() {
                let text = String(chars[piece])
                words.append(Word(
                    text: text, lower: text.lowercased(), start: piece.lowerBound, end: piece.upperBound, chunk: chunks.count,
                    opensChunk: position == 0, closesChunk: position == pieces.count - 1
                ))
            }
            chunks.append(Chunk(start: index, end: end, comma: trailing.first == ",", stop: trailing.contains { ".;:!?".contains($0) }))
            index = end
        }
        used = Array(repeating: false, count: words.count)
        reserved = used
    }

    /// Splits a chunk's core at dashes and after a leading "@". Email addresses, "#calendars", links and ISO dates stay whole.
    static func pieces(of chars: [Character], from start: Int, to end: Int) -> [Range<Int>] {
        guard start < end else { return [] }
        var result: [Range<Int>] = []
        var from = start
        if chars[from] == "@", end - from > 1 {
            result.append(from..<from + 1)
            from += 1
        }
        let core = String(chars[from..<end])
        if core.contains("@") || core.hasPrefix("#") || core.contains("://") || isoDate(core) != nil {
            result.append(from..<end)
            return result
        }
        var pieceStart = from
        for index in from..<end where dashes.contains(chars[index]) {
            if pieceStart < index { result.append(pieceStart..<index) }
            result.append(index..<index + 1)
            pieceStart = index + 1
        }
        if pieceStart < end { result.append(pieceStart..<end) }
        return result
    }

    /// The word at `index` when no pass has claimed it.
    func free(_ index: Int) -> Word? {
        guard index >= 0, index < words.count, !used[index], !reserved[index] else { return nil }
        return words[index]
    }

    func isDash(_ word: Word?) -> Bool {
        guard let word, word.text.count == 1, let char = word.text.first else { return false }
        return Self.dashes.contains(char)
    }

    func isSeparator(_ word: Word?, days: Bool) -> Bool {
        guard let word else { return false }
        return isDash(word) || word.lower == "to" || (days && (word.lower == "through" || word.lower == "thru"))
    }

    /// Marks words as read. A part must cover whole chunks, so "kickoff-tomorrow" keeps its "tomorrow".
    @discardableResult
    mutating func claim(_ range: Range<Int>, as role: QuickAdd.Role) -> Bool {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= words.count,
              words[range.lowerBound].opensChunk, words[range.upperBound - 1].closesChunk,
              range.allSatisfy({ !used[$0] && !reserved[$0] }) else { return false }
        for index in range { used[index] = true }
        spans.append(Span(role: role, words: range))
        return true
    }

    // MARK: Passes

    mutating func readConference() {
        guard let last = words.indices.last, last > 0, ["meet", "video"].contains(words[last].lower) else { return }
        addConference = claim(last..<last + 1, as: .conference)
    }

    mutating func readCalendar() {
        for index in words.indices where words[index].text.hasPrefix("#") {
            let name = String(words[index].text.dropFirst())
            guard name.contains(where: \.isLetter), !name.contains("#"), claim(index..<index + 1, as: .calendar) else { continue }
            calendarHint = name
            return
        }
    }

    mutating func readEmails() {
        for index in words.indices where Self.isEmail(words[index].text) {
            guard claim(index..<index + 1, as: .guest) else { continue }
            emailSpans[index] = spans.count - 1
            guests.append((words[index].start, EmailAddress(email: words[index].text)))
        }
    }

    mutating func readRepeat() {
        for index in words.indices {
            guard let (found, next) = repeatPhrase(at: index), claim(index..<next, as: .repeats) else { continue }
            rule = found
            break
        }
        for index in words.indices {
            guard let word = free(index) else { continue }
            if word.lower == "until", let date = day(at: index + 1, ranges: false) {
                if rule != nil, until == nil, count == nil, claim(index..<date.next, as: .repeats) {
                    until = date.first
                } else {
                    for reservedIndex in index..<date.next { reserved[reservedIndex] = true }
                }
            } else if rule != nil, until == nil, count == nil, let (times, next) = countPhrase(at: index),
                      claim(index..<next, as: .repeats) {
                count = times
            }
        }
    }

    func repeatPhrase(at index: Int) -> (Repeat, Int)? {
        guard let word = free(index) else { return nil }
        switch word.lower {
        case "daily", "everyday": return (Repeat(frequency: "DAILY"), index + 1)
        case "weekly": return (Repeat(frequency: "WEEKLY"), index + 1)
        case "biweekly", "fortnightly": return (Repeat(frequency: "WEEKLY", interval: 2), index + 1)
        case "monthly": return (Repeat(frequency: "MONTHLY"), index + 1)
        case "yearly", "annually": return (Repeat(frequency: "YEARLY"), index + 1)
        case "weekdays": return (Repeat(frequency: "WEEKLY", weekdays: Self.workweek), index + 1)
        case "every": break
        default: return nil
        }
        guard let next = free(index + 1) else { return nil }
        if next.lower == "weekday" { return (Repeat(frequency: "WEEKLY", weekdays: Self.workweek), index + 2) }
        var interval = 1
        var cursor = index + 1
        if next.lower == "other" {
            interval = 2
            cursor += 1
        } else if let amount = Self.number(next.lower) {
            guard (1...999).contains(amount), let unit = free(cursor + 1), let frequency = Self.frequencies[unit.lower] else { return nil }
            return (Repeat(frequency: frequency, interval: amount), cursor + 2)
        }
        guard let unit = free(cursor) else { return nil }
        if let frequency = Self.frequencies[unit.lower] { return (Repeat(frequency: frequency, interval: interval), cursor + 1) }
        guard let (weekdays, end) = weekdayList(at: cursor) else { return nil }
        return (Repeat(frequency: "WEEKLY", interval: interval, weekdays: weekdays, namesDays: true), end)
    }

    /// "tue", "mon and wed", "mon, wed & fri".
    func weekdayList(at index: Int) -> ([Int], Int)? {
        guard let first = free(index), let weekday = Self.weekdays[first.lower] else { return nil }
        var weekdays = [weekday]
        var end = index + 1
        while true {
            let previous = words[end - 1]
            if let joiner = free(end), Self.joiners.contains(joiner.lower), let word = free(end + 1), let next = Self.weekdays[word.lower] {
                weekdays.append(next)
                end += 2
            } else if previous.closesChunk, chunks[previous.chunk].comma, let word = free(end), let next = Self.weekdays[word.lower] {
                weekdays.append(next)
                end += 1
            } else {
                break
            }
        }
        return (weekdays, end)
    }

    /// "x8" or "8 times".
    func countPhrase(at index: Int) -> (Int, Int)? {
        guard let word = free(index) else { return nil }
        if word.lower.hasPrefix("x"), let times = Self.number(word.lower.dropFirst()), times > 0 { return (times, index + 1) }
        if let times = Self.number(word.lower), times > 0, let unit = free(index + 1), unit.lower == "times" || unit.lower == "time" {
            return (times, index + 2)
        }
        return nil
    }

    mutating func readWhen() {
        scanWhen()
        if days == nil {
            allowTom = true
            scanWhen()
        }
    }

    mutating func scanWhen() {
        var index = 0
        while index < words.count {
            guard free(index) != nil else {
                index += 1
                continue
            }
            if !allDay, let next = allDayPhrase(at: index), claim(index..<next, as: .time) {
                allDay = true
                index = next
            } else if days == nil, let found = day(at: index, ranges: true), claim(index..<found.next, as: .day) {
                days = found
                index = found.next
            } else if days == nil, clock == nil, let found = relativeTime(at: index), claim(index..<found.next, as: .time) {
                days = DayRange(first: found.day, last: found.day, tonight: false, next: found.next)
                clock = (found.clock, nil)
                index = found.next
            } else if clock == nil, let found = time(at: index), claim(index..<found.next, as: .time) {
                clock = (found.start, found.end)
                index = found.next
            } else if length == nil, let found = duration(at: index), claim(index..<found.next, as: .length) {
                length = found.minutes
                index = found.next
            } else {
                index += 1
            }
        }
    }

    func allDayPhrase(at index: Int) -> Int? {
        guard let word = free(index) else { return nil }
        if word.lower == "allday" { return index + 1 }
        guard word.lower == "all" else { return nil }
        if free(index + 1)?.lower == "day" { return index + 2 }
        if isDash(free(index + 1)), free(index + 2)?.lower == "day" { return index + 3 }
        return nil
    }

    // MARK: Days

    /// A day or a range of days, optionally after "on".
    func day(at start: Int, ranges: Bool) -> DayRange? {
        var index = start
        if free(index)?.lower == "on" { index += 1 }
        if ranges, let found = numberRange(at: index) { return found }
        guard let first = singleDay(at: index) else { return nil }
        var found = DayRange(first: first.date, last: first.date, tonight: first.tonight, next: first.next)
        guard ranges, isSeparator(free(first.next), days: true) else { return found }
        let after = first.next + 1
        if let second = singleDay(at: after) {
            let last = second.weekday.map { firstDay(from: first.date.adding(days: 1, in: calendar), in: [$0]) } ?? second.date
            if last > first.date {
                found.last = last
                found.next = second.next
            }
        } else if first.hasMonth, let word = free(after), let number = Self.dayNumber(word.lower) {
            var start = first.date
            var next = after + 1
            // "oct 16-18 2027": a year after the range is the first day's year too.
            if !first.typedYear, let yearWord = free(next), let year = Self.year(yearWord.lower), let date = validDay(year, start.month, start.day) {
                start = date
                next += 1
            }
            var last = validDay(start.year, start.month, number)
            if let candidate = last, candidate <= start {
                let nextMonth = start.month == 12 ? 1 : start.month + 1
                last = validDay(start.month == 12 ? start.year + 1 : start.year, nextMonth, number)
            }
            if let last, last > start {
                found.first = start
                found.last = last
                found.next = next
            }
        }
        return found
    }

    /// "16-18 oct".
    func numberRange(at index: Int) -> DayRange? {
        guard let firstWord = free(index), let firstNumber = Self.dayNumber(firstWord.lower), isSeparator(free(index + 1), days: true),
              let lastWord = free(index + 2), let lastNumber = Self.dayNumber(lastWord.lower),
              let monthWord = free(index + 3), let month = Self.months[monthWord.lower] else { return nil }
        var next = index + 4
        var year: Int?
        if let word = free(next), let value = Self.year(word.lower) {
            year = value
            next += 1
        }
        guard let first = resolveDate(month: month, day: firstNumber, year: year),
              let last = validDay(first.year, month, lastNumber), last > first else { return nil }
        return DayRange(first: first, last: last, tonight: false, next: next)
    }

    func singleDay(at index: Int) -> SingleDay? {
        guard let word = free(index), index == 0 || words[index - 1].text != "@" else { return nil }
        let lower = word.lower
        switch lower {
        case "today": return SingleDay(date: today, next: index + 1)
        case "tonight": return SingleDay(date: today, next: index + 1, tonight: true)
        case "tomorrow": return SingleDay(date: today.adding(days: 1, in: calendar), next: index + 1)
        case "tom":
            guard allowTom, !followsNameWord(index) else { return nil }
            return SingleDay(date: today.adding(days: 1, in: calendar), next: index + 1)
        case "next":
            guard let dayWord = free(index + 1), let weekday = Self.weekdays[dayWord.lower] else { return nil }
            return SingleDay(date: upcoming(weekday).adding(days: 7, in: calendar), next: index + 2)
        case "in":
            return relativeDay(at: index)
        default:
            break
        }
        if let weekday = Self.weekdays[lower] {
            return SingleDay(date: upcoming(weekday), next: index + 1, weekday: weekday)
        }
        if let month = Self.months[lower] {
            guard let dayWord = free(index + 1), let number = Self.dayNumber(dayWord.lower) else { return nil }
            return monthDay(month: month, day: number, yearAt: index + 2)
        }
        if let number = Self.dayNumber(lower), let monthWord = free(index + 1), let month = Self.months[monthWord.lower] {
            // "2 oct 16" reads as "2" and "oct 16".
            if let after = free(index + 2), Self.dayNumber(after.lower) != nil { return nil }
            return monthDay(month: month, day: number, yearAt: index + 2)
        }
        let parts = lower.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2 || parts.count == 3, parts[0].count <= 2, parts[1].count <= 2,
           let month = Self.number(parts[0]), let number = Self.number(parts[1]) {
            var year: Int?
            if parts.count == 3 {
                guard let value = Self.number(parts[2]), parts[2].count == 2 || parts[2].count == 4 else { return nil }
                year = parts[2].count == 2 ? 2000 + value : value
            }
            guard let date = resolveDate(month: month, day: number, year: year) else { return nil }
            return SingleDay(date: date, next: index + 1, hasMonth: true, typedYear: year != nil)
        }
        if let (year, month, number) = Self.isoDate(lower), let date = validDay(year, month, number) {
            return SingleDay(date: date, next: index + 1, hasMonth: true, typedYear: true)
        }
        return nil
    }

    func monthDay(month: Int, day: Int, yearAt index: Int) -> SingleDay? {
        var next = index
        var year: Int?
        if let word = free(index), let value = Self.year(word.lower) {
            year = value
            next += 1
        }
        guard let date = resolveDate(month: month, day: day, year: year) else { return nil }
        return SingleDay(date: date, next: next, hasMonth: true, typedYear: year != nil)
    }

    /// "in 3d", "in 2w", "in 3 days", "in 2 weeks".
    func relativeDay(at index: Int) -> SingleDay? {
        guard let amountWord = free(index + 1) else { return nil }
        var amount: Int?
        var unit: String?
        var next = index + 2
        if let value = Self.number(amountWord.lower) {
            amount = value
            unit = free(index + 2)?.lower
            next = index + 3
        } else if let last = amountWord.lower.last, last == "d" || last == "w", let value = Self.number(amountWord.lower.dropLast()) {
            amount = value
            unit = String(last)
        }
        guard let amount, let unit, (1...3660).contains(amount) else { return nil }
        let days: Int
        switch unit {
        case "d", "day", "days": days = amount
        case "w", "wk", "wks", "week", "weeks": days = amount * 7
        default: return nil
        }
        guard days <= 3660 else { return nil }
        return SingleDay(date: today.adding(days: days, in: calendar), next: next)
    }

    /// "with tom", "jamie and tom", "jamie, tom": Tom is a person there, not tomorrow.
    func followsNameWord(_ index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = words[index - 1]
        return previous.lower == "with" || previous.lower == "to" || Self.joiners.contains(previous.lower)
            || (previous.closesChunk && chunks[previous.chunk].comma)
    }

    /// The next `weekday` after today; today's weekday means a week ahead, as in snooze.
    func upcoming(_ weekday: Int) -> DayDate {
        var delta = (weekday - self.weekday(of: today) + 7) % 7
        if delta == 0 { delta = 7 }
        return today.adding(days: delta, in: calendar)
    }

    func weekday(of day: DayDate) -> Int {
        calendar.component(.weekday, from: day.start(in: calendar))
    }

    /// The first day on or after `day` that falls on one of `weekdays`.
    func firstDay(from day: DayDate, in weekdays: [Int]) -> DayDate {
        var candidate = day
        for _ in 0..<7 {
            if weekdays.contains(weekday(of: candidate)) { return candidate }
            candidate = candidate.adding(days: 1, in: calendar)
        }
        return day
    }

    /// A month and day; without a year, one that has passed means next year.
    func resolveDate(month: Int, day: Int, year: Int?) -> DayDate? {
        if let year { return validDay(year, month, day) }
        if let date = validDay(today.year, month, day), date >= today { return date }
        return validDay(today.year + 1, month, day)
    }

    func validDay(_ year: Int, _ month: Int, _ day: Int) -> DayDate? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let found = DayDate(date, in: calendar)
        return found == DayDate(year: year, month: month, day: day) ? found : nil
    }

    // MARK: Times and lengths

    /// A time or a time range, optionally after "at", "@" or "from".
    func time(at start: Int) -> (start: Clock, end: Clock?, next: Int)? {
        var index = start
        var prefix: String?
        if let word = free(index), ["at", "@", "from"].contains(word.lower) {
            prefix = word.lower
            index += 1
        }
        guard let (first, afterFirst) = clock(at: index) else { return nil }
        if let separator = free(afterFirst), isSeparator(separator, days: false), let (second, afterSecond) = clock(at: afterFirst + 1),
           separator.lower != "to" || prefix != nil || !first.bare || !second.bare {
            return (first, second, afterSecond)
        }
        if first.bare, prefix != "at", prefix != "@" { return nil }
        return (first, nil, afterFirst)
    }

    /// "in 2h", "in 30 min": a start that long from now, to the minute, as snooze reads "2h".
    func relativeTime(at index: Int) -> (day: DayDate, clock: Clock, next: Int)? {
        guard free(index)?.lower == "in", free(index + 1)?.lower != "for", let found = duration(at: index + 1) else { return nil }
        let moment = now.addingTimeInterval(TimeInterval(found.minutes * 60))
        let parts = calendar.dateComponents([.hour, .minute], from: moment)
        let clock = Clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0, meridiem: nil, exact: true, bare: false)
        return (DayDate(moment, in: calendar), clock, found.next)
    }

    func clock(at index: Int) -> (Clock, Int)? {
        guard let word = free(index) else { return nil }
        switch word.lower {
        case "noon", "midday": return (Clock(hour: 12, minute: 0, meridiem: nil, exact: true, bare: false), index + 1)
        case "midnight": return (Clock(hour: 0, minute: 0, meridiem: nil, exact: true, bare: false), index + 1)
        default: break
        }
        guard var clock = Self.clockWord(word.lower) else { return nil }
        if clock.meridiem == nil, (1...12).contains(clock.hour), let suffix = free(index + 1), let meridiem = Self.meridiem(suffix.lower) {
            clock.meridiem = meridiem
            clock.bare = false
            return (clock, index + 2)
        }
        return (clock, index + 1)
    }

    static func clockWord(_ text: String) -> Clock? {
        var body = Substring(text)
        var meridiem: Character?
        for (suffix, value) in [("a.m", "a"), ("p.m", "p"), ("am", "a"), ("pm", "p")] as [(String, Character)] where body.hasSuffix(suffix) {
            body = body.dropLast(suffix.count)
            meridiem = value
            break
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), (1...2).contains(parts[0].count), let hour = number(parts[0]) else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let value = number(parts[1]), value < 60 else { return nil }
            minute = value
        }
        if meridiem != nil {
            guard (1...12).contains(hour) else { return nil }
            return Clock(hour: hour, minute: minute, meridiem: meridiem, exact: false, bare: false)
        }
        guard hour <= 23 else { return nil }
        let exact = hour >= 13 || hour == 0 || parts[0].hasPrefix("0")
        return Clock(hour: hour, minute: minute, meridiem: nil, exact: exact, bare: parts.count == 1)
    }

    static func meridiem(_ text: String) -> Character? {
        switch text {
        case "am", "a.m": "a"
        case "pm", "p.m": "p"
        default: nil
        }
    }

    /// A length such as "30m", "1h30", "2 hours", "30-min" or "1h 30m", optionally after "for".
    func duration(at start: Int) -> (minutes: Int, next: Int)? {
        var index = start
        if free(index)?.lower == "for" { index += 1 }
        guard let first = lengthPart(at: index) else { return nil }
        var total = first.minutes
        var next = first.next
        if first.unit == "h", let extra = lengthPart(at: next), extra.unit == "m", extra.minutes < 60 {
            total += extra.minutes
            next = extra.next
        }
        guard total > 0, total <= Self.maxMinutes else { return nil }
        return (total, next)
    }

    /// One length. `unit` is "m" for minutes, "h" for whole hours, "x" for anything else.
    func lengthPart(at index: Int) -> (minutes: Int, next: Int, unit: Character)? {
        guard let word = free(index) else { return nil }
        if let found = Self.compactLength(word.lower) { return (found.minutes, index + 1, found.unit) }
        guard let value = Self.decimal(word.lower) else { return nil }
        var unitIndex = index + 1
        if let dash = free(unitIndex), isDash(dash), !dash.opensChunk { unitIndex += 1 }
        guard let unitWord = free(unitIndex), let factor = Self.lengthUnits[unitWord.lower], let minutes = Self.minutes(value, factor) else { return nil }
        return (minutes, unitIndex + 1, Self.unit(value, factor))
    }

    /// "30m", "45min", "1h", "1.5h", "2hrs", "1h30", "1h30m".
    static func compactLength(_ text: String) -> (minutes: Int, unit: Character)? {
        guard let letter = text.firstIndex(where: \.isLetter), let value = decimal(text[..<letter]) else { return nil }
        let unitText = String(text[letter...])
        if let factor = lengthUnits[unitText], let minutes = minutes(value, factor) { return (minutes, unit(value, factor)) }
        for hourUnit in ["h", "hr"] where unitText.hasPrefix(hourUnit) {
            let rest = unitText.dropFirst(hourUnit.count)
            let digits = rest.prefix(while: \.isNumber)
            let tail = String(rest.dropFirst(digits.count))
            guard value == value.rounded(), let extra = number(digits), extra < 60, tail.isEmpty || lengthUnits[tail] == 1,
                  let hours = minutes(value, 60) else { continue }
            return (hours + extra, "x")
        }
        return nil
    }

    static func minutes(_ value: Double, _ factor: Int) -> Int? {
        let total = value * Double(factor)
        guard total.isFinite, total > 0, total <= Double(maxMinutes) else { return nil }
        let rounded = Int(total.rounded())
        return rounded > 0 ? rounded : nil
    }

    static func unit(_ value: Double, _ factor: Int) -> Character {
        factor == 1 ? "m" : (value == value.rounded() ? "h" : "x")
    }

    // MARK: Places and guests

    mutating func readPlace() {
        for index in words.indices where words[index].text == "@" && free(index) != nil {
            var end = index + 1
            while let word = free(end), word.lower != "with", word.text != "@" { end += 1 }
            while end > index + 1, !words[end - 1].closesChunk { end -= 1 }
            guard end > index + 1, claim(index..<end, as: .place) else { continue }
            location = Self.collapse(String(chars[words[index + 1].start..<words[end - 1].end]))
            return
        }
    }

    mutating func readGuests(_ contacts: (String) -> [EmailAddress]) {
        var matches: [String: EmailAddress?] = [:]
        var unknown: Set<String> = []
        var index = 0
        while index < words.count {
            guard words[index].lower == "with", free(index) != nil else {
                index += 1
                continue
            }
            var names: [Range<Int>] = []
            var nameStart: Int?
            func close(_ end: Int) {
                if let start = nameStart, start < end { names.append(start..<end) }
                nameStart = nil
            }
            var cursor = index + 1
            while cursor < words.count {
                let word = words[cursor]
                if let span = emailSpans[cursor] {
                    close(cursor)
                    spans[span].keepsText = true
                    cursor += 1
                    if chunks[word.chunk].stop { break }
                    continue
                }
                guard free(cursor) != nil, word.lower != "with", word.text != "@", !Self.nameStops.contains(word.lower),
                      !(isDash(word) && word.opensChunk) else { break }
                if Self.joiners.contains(word.lower) {
                    close(cursor)
                    cursor += 1
                    continue
                }
                if nameStart == nil { nameStart = cursor }
                cursor += 1
                if word.closesChunk, chunks[word.chunk].comma { close(cursor) }
                if word.closesChunk, chunks[word.chunk].stop { break }
            }
            close(cursor)
            for range in names {
                let name = Self.collapse(String(chars[words[range.lowerBound].start..<words[range.upperBound - 1].end]))
                let key = name.lowercased()
                let match: EmailAddress?
                if let cached = matches[key] {
                    match = cached
                } else {
                    match = contacts(name).first
                    matches[key] = match
                }
                for word in range { used[word] = true }
                spans.append(Span(role: .guest, words: range, keepsText: true))
                if let match {
                    guests.append((words[range.lowerBound].start, match))
                    for word in range { capitals.insert(words[word].start) }
                } else if unknown.insert(key).inserted {
                    unknownGuests.append(name)
                }
            }
            index = max(cursor, index + 1)
        }
    }

    // MARK: Result

    func result(defaultLength: TimeInterval) -> QuickAdd.Result {
        let evening = days?.tonight ?? false
        let minutes = clock.map { Self.resolve($0.start, $0.end, evening: evening) }
        var first = days?.first
        var last = days?.last
        if first == nil, let rule, !rule.weekdays.isEmpty {
            if let minutes {
                first = firstDay(from: moment(today, minutes.start) > now ? today : today.adding(days: 1, in: calendar), in: rule.weekdays)
            } else if rule.namesDays {
                first = firstDay(from: today, in: rule.weekdays)
            }
            last = first
        } else if let day = first, let rule, rule.frequency == "WEEKLY", !rule.weekdays.isEmpty, !rule.weekdays.contains(weekday(of: day)) {
            // "fri every tue": the first event is on a day the rule names.
            let moved = firstDay(from: day, in: rule.weekdays)
            let offset = calendar.dateComponents([.day], from: day.start(in: calendar), to: moved.start(in: calendar)).day ?? 0
            first = moved
            last = last.map { $0.adding(days: offset, in: calendar) }
        }
        var start: EventTime?
        var end: EventTime?
        if allDay || (first != nil && minutes == nil && !evening) {
            let day = first ?? today
            start = .allDay(day)
            end = .allDay((last ?? day).adding(days: 1, in: calendar))
        } else if minutes != nil || evening {
            let startMinutes = minutes?.start ?? 19 * 60
            let day = first ?? (moment(today, startMinutes) > now ? today : today.adding(days: 1, in: calendar))
            let endDate: Date
            if let endMinutes = minutes?.end {
                endDate = moment(last ?? day, endMinutes)
            } else {
                let fallback = defaultLength.isFinite ? min(max(defaultLength, 0), TimeInterval(Self.maxMinutes * 60)) : 1800
                endDate = moment(last ?? day, startMinutes).addingTimeInterval(length.map { TimeInterval($0 * 60) } ?? fallback)
            }
            let zone = calendar.timeZone.identifier
            start = .timed(moment(day, startMinutes), timeZone: zone)
            end = .timed(endDate, timeZone: zone)
        }
        let orderedGuests = guests.sorted { $0.offset < $1.offset }.map(\.address).deduplicated()
        let tokens = spans
            .map { QuickAdd.Token(role: $0.role, start: words[$0.words.lowerBound].start, end: words[$0.words.upperBound - 1].end) }
            .sorted { $0.start < $1.start }
        return QuickAdd.Result(
            title: title(), start: start, end: end, guests: orderedGuests, unknownGuests: unknownGuests, location: location,
            addConference: addConference, recurrence: recurrence(start: start), calendarHint: calendarHint, tokens: tokens
        )
    }

    /// Settles am/pm: minutes after midnight of the start day, the end later than the start (past 24:00 when it ends the next day).
    static func resolve(_ first: Clock, _ second: Clock?, evening: Bool) -> (start: Int, end: Int?) {
        let start: Int
        if let fixed = fixedMinutes(first) {
            start = fixed
        } else if let second, let meridiem = second.meridiem, let end = fixedMinutes(second), minutes(first, meridiem) < end {
            start = minutes(first, meridiem)
        } else if evening {
            start = (first.hour + 12) * 60 + first.minute
        } else {
            start = (first.hour >= 8 && first.hour <= 12 ? first.hour : first.hour + 12) * 60 + first.minute
        }
        guard let second else { return (start, nil) }
        if let fixed = fixedMinutes(second) { return (start, fixed > start ? fixed : fixed + 1440) }
        let base = second.hour % 12 * 60 + second.minute
        return (start, [base, base + 720, base + 1440, base + 2160].first { $0 > start } ?? base + 1440)
    }

    static func minutes(_ clock: Clock, _ meridiem: Character) -> Int {
        (clock.hour % 12 + (meridiem == "p" ? 12 : 0)) * 60 + clock.minute
    }

    static func fixedMinutes(_ clock: Clock) -> Int? {
        if let meridiem = clock.meridiem { return minutes(clock, meridiem) }
        return clock.exact ? clock.hour * 60 + clock.minute : nil
    }

    /// The moment `minutes` after the start of `day`, on the wall clock (so 9:00 stays 9:00 on days that change clocks).
    func moment(_ day: DayDate, _ minutes: Int) -> Date {
        let date = day.adding(days: minutes / 1440, in: calendar)
        let rest = minutes % 1440
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: rest / 60, minute: rest % 60))
            ?? date.start(in: calendar).addingTimeInterval(TimeInterval(rest * 60))
    }

    func recurrence(start: EventTime?) -> [String] {
        guard let rule else { return [] }
        var parts = ["FREQ=\(rule.frequency)"]
        if rule.interval > 1 { parts.append("INTERVAL=\(rule.interval)") }
        let startDay = start?.dayDate(in: calendar)
        if rule.frequency == "WEEKLY" {
            let weekdays = rule.weekdays.isEmpty ? startDay.map { [weekday(of: $0)] } ?? [] : rule.weekdays
            let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
            let sorted = Set(weekdays).filter { (1...7).contains($0) }.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
            if !sorted.isEmpty { parts.append("BYDAY=" + sorted.map { codes[$0 - 1] }.joined(separator: ",")) }
        } else if rule.frequency == "MONTHLY", let startDay {
            parts.append("BYMONTHDAY=\(startDay.day)")
        }
        if let until {
            parts.append("UNTIL=" + untilText(until, allDay: start?.isAllDay ?? false))
        } else if let count {
            parts.append("COUNT=\(count)")
        }
        return ["RRULE:" + parts.joined(separator: ";")]
    }

    /// A DATE for all-day events, otherwise the UTC instant at the end of that local day.
    func untilText(_ day: DayDate, allDay: Bool) -> String {
        if allDay { return Self.pad(day.year, 4) + Self.pad(day.month, 2) + Self.pad(day.day, 2) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let last = day.adding(days: 1, in: calendar).start(in: calendar).addingTimeInterval(-1)
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: last)
        return Self.pad(parts.year ?? 0, 4) + Self.pad(parts.month ?? 0, 2) + Self.pad(parts.day ?? 0, 2) + "T"
            + Self.pad(parts.hour ?? 0, 2) + Self.pad(parts.minute ?? 0, 2) + Self.pad(parts.second ?? 0, 2) + "Z"
    }

    func title() -> String {
        var removed = [Bool](repeating: false, count: chars.count)
        for span in spans where !span.keepsText {
            let from = chunks[words[span.words.lowerBound].chunk].start
            let to = chunks[words[span.words.upperBound - 1].chunk].end
            for offset in from..<to { removed[offset] = true }
        }
        var text = ""
        for (offset, char) in chars.enumerated() where !removed[offset] {
            text += capitals.contains(offset) ? char.uppercased() : String(char)
        }
        var title = Self.collapse(text).trimmingCharacters(in: Self.titleEdges)
        if let index = title.firstIndex(where: { $0.isLetter || $0.isNumber }), title[index].isLetter {
            title.replaceSubrange(index...index, with: title[index].uppercased())
        }
        return title.isEmpty ? "(no title)" : title
    }

    // MARK: Helpers

    static let titleEdges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—,;:|·"))

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// ASCII digits only, so no word can overflow or read as a number in another script.
    static func number(_ text: some StringProtocol) -> Int? {
        guard !text.isEmpty, text.count <= 9, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(String(text))
    }

    static func decimal(_ text: some StringProtocol) -> Double? {
        guard !text.isEmpty, text.count <= 9, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              text.filter({ $0 == "." }).count <= 1, text.contains(where: \.isNumber) else { return nil }
        return Double(String(text))
    }

    /// "16", "16th", "1st".
    static func dayNumber(_ text: String) -> Int? {
        var digits = Substring(text)
        for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) {
            digits = digits.dropLast(2)
            break
        }
        guard digits.count <= 2, let value = number(digits), (1...31).contains(value) else { return nil }
        return value
    }

    static func year(_ text: String) -> Int? {
        guard text.count == 4, let value = number(text), (1900...9999).contains(value) else { return nil }
        return value
    }

    static func isoDate(_ text: String) -> (Int, Int, Int)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, (1...2).contains(parts[1].count), (1...2).contains(parts[2].count),
              let year = number(parts[0]), let month = number(parts[1]), let day = number(parts[2]) else { return nil }
        return (year, month, day)
    }

    static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && domain.contains(where: \.isLetter)
            && !text.contains { $0.isWhitespace || "<>()[],;:\"".contains($0) }
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
