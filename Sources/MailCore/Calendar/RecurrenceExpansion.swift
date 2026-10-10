import Foundation

extension Recurrence {
    /// The most dates Foundation may produce for one expansion, all its rules together.
    static let stepLimit = 20_000
    /// The most RRULE lines a series may have to be expanded here. Real series have one; more go to the provider.
    static let ruleLimit = 4

    /// The occurrences of a series in a window, and how many dates Foundation produced for them.
    struct Expansion {
        var occurrences: [Occurrence]
        var steps: Int
    }

    /// `occurrences(start:end:recurrence:from:to:calendar:)` with its work counted. With `skipsAhead` false, rules
    /// without COUNT are walked from the first occurrence too (tests compare the two).
    static func expansion(
        start: EventTime, end: EventTime, recurrence: [String], from: Date, to: Date, calendar: Calendar,
        skipsAhead: Bool = true, stepLimit: Int = stepLimit
    ) -> Expansion? {
        var rules: [Rule] = []
        var exclusions: [Stamp] = []
        var additions: [Stamp] = []
        for text in recurrence {
            switch parseLine(text) {
            case .rule(let rule)? where isSupported(rule):
                rules.append(rule)
            case .dates(let list)? where !list.hasPeriods:
                if list.isExclusion { exclusions += list.stamps } else { additions += list.stamps }
            default:
                return nil
            }
        }
        guard rules.count <= ruleLimit else { return nil }
        guard from < to else { return Expansion(occurrences: [], steps: 0) }
        let series = Series(start: start, end: end, viewer: calendar)
        let lower = series.lowerBound(from: from)
        let upper = series.upperBound(to: to)
        var starts = [series.first]
        var steps = 0
        for rule in rules {
            // One budget for all the rules, so many rules cannot multiply the work.
            guard let expanded = series.expand(rule, from: lower, to: upper, skipsAhead: skipsAhead, stepLimit: stepLimit - steps) else { return nil }
            starts += expanded.dates
            steps += expanded.steps
        }
        starts += additions.compactMap(series.date(of:))
        let excluded = series.exclusions(exclusions)
        var seen = Set<Int64>()
        let occurrences = starts
            .filter { seen.insert(Series.key($0)).inserted && !excluded.contains($0) }
            .sorted()
            .map(series.occurrence(at:))
            .filter { series.overlaps($0, from: from, to: to) }
        return Expansion(occurrences: occurrences, steps: steps)
    }
}

extension Recurrence {
    /// A proleptic Gregorian date and its day number (days since 1970-01-01), for period arithmetic.
    struct CivilDay: Hashable, Sendable {
        var year: Int
        var month: Int
        var day: Int

        init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        init(number: Int) {
            let shifted = number + 719_468
            let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
            let dayOfEra = shifted - era * 146_097
            let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
            let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            let marchMonth = (5 * dayOfYear + 2) / 153
            day = dayOfYear - (153 * marchMonth + 2) / 5 + 1
            month = marchMonth < 10 ? marchMonth + 3 : marchMonth - 9
            year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        }

        init(_ date: Date, in calendar: Calendar) {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
        }

        var number: Int {
            let shiftedYear = month <= 2 ? year - 1 : year
            let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
            let yearOfEra = shiftedYear - era * 400
            let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
            return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
        }

        /// 1 for Sunday through 7 for Saturday.
        var weekday: Int { ((number + 4) % 7 + 7) % 7 + 1 }
        var length: Int { Recurrence.daysIn(month: month, year: year) }

        /// Midnight of this day plus `days`, in `calendar` (the UTC calendar of all-day series).
        func date(adding days: Int, in calendar: Calendar) -> Date {
            let day = CivilDay(number: number + days)
            return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date(timeIntervalSince1970: 0)
        }
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// The moment an occurrence may start no later than (`through`) or must start before (`before`).
    enum Limit {
        case through(Date)
        case before(Date)

        func excludes(_ date: Date) -> Bool {
            switch self {
            case .through(let limit): date > limit
            case .before(let limit): date >= limit
            }
        }
    }

    /// The days that an EXDATE removes, as instants for timed series and day numbers for both kinds.
    struct Exclusions {
        var instants: Set<Int64> = []
        var days: Set<Int> = []
        let calendar: Calendar

        func contains(_ date: Date) -> Bool {
            instants.contains(Series.key(date)) || (!days.isEmpty && days.contains(CivilDay(date, in: calendar).number))
        }
    }

    /// A series being expanded: where it starts, how long each occurrence lasts, and the calendar it repeats in.
    /// All-day series repeat by date in a UTC calendar, so their dates are UTC midnights here.
    struct Series {
        /// Gregorian, in the event's zone (UTC for all-day series).
        let calendar: Calendar
        /// The caller's calendar, which places all-day occurrences in the window.
        let viewer: Calendar
        let first: Date
        let firstDay: CivilDay
        let isAllDay: Bool
        let zone: String?
        let endZone: String?
        let duration: TimeInterval
        /// Days an all-day occurrence covers (its end is exclusive).
        let days: Int

        init(start: EventTime, end: EventTime, viewer: Calendar) {
            var calendar = Calendar(identifier: .gregorian)
            self.viewer = viewer
            switch start {
            case .allDay(let day):
                calendar.timeZone = .gmt
                first = day.start(in: calendar)
                firstDay = CivilDay(year: day.year, month: day.month, day: day.day)
                isAllDay = true
                zone = nil
                endZone = nil
                duration = 0
                let last = end.dayDate(in: calendar)
                days = max(0, CivilDay(year: last.year, month: last.month, day: last.day).number - firstDay.number)
            case .timed(let date, let zoneID):
                calendar.timeZone = zoneID.flatMap(TimeZone.init(identifier:)) ?? viewer.timeZone
                first = date
                firstDay = CivilDay(date, in: calendar)
                isAllDay = false
                zone = zoneID
                endZone = end.isAllDay ? zoneID : end.timeZone
                duration = max(0, end.instant(in: calendar).timeIntervalSince(date))
                days = 0
            }
            self.calendar = calendar
        }

        /// Whole seconds, so the same moment computed two ways compares equal.
        static func key(_ date: Date) -> Int64 { Int64(date.timeIntervalSinceReferenceDate.rounded()) }

        /// Starts before this cannot overlap a window that begins at `from`.
        func lowerBound(from: Date) -> Date {
            guard isAllDay else { return from.addingTimeInterval(-duration) }
            let day = DayDate(from, in: viewer)
            return CivilDay(year: day.year, month: day.month, day: day.day).date(adding: -days, in: calendar)
        }

        /// Starts from this on are past a window that ends at `to`.
        func upperBound(to: Date) -> Date {
            guard isAllDay else { return to }
            let day = DayDate(to, in: viewer)
            let civil = CivilDay(year: day.year, month: day.month, day: day.day)
            return civil.date(adding: day.start(in: viewer) < to ? 1 : 0, in: calendar)
        }

        func overlaps(_ occurrence: Occurrence, from: Date, to: Date) -> Bool {
            let start = occurrence.start.instant(in: viewer)
            let end = occurrence.end.instant(in: viewer)
            return start < to && (end > from || (end <= start && start >= from))
        }

        func occurrence(at date: Date) -> Occurrence {
            guard isAllDay else {
                let start = EventTime.timed(date, timeZone: zone)
                return Occurrence(start: start, end: .timed(date.addingTimeInterval(duration), timeZone: endZone), originalStart: start)
            }
            let day = DayDate(date, in: calendar)
            return Occurrence(start: .allDay(day), end: .allDay(day.adding(days: days, in: calendar)), originalStart: .allDay(day))
        }

        /// The start an RDATE adds. A date on a timed series starts at the series' time of day.
        func date(of stamp: Stamp) -> Date? {
            switch stamp {
            case .utc(let date):
                return isAllDay ? CivilDay(date, in: Recurrence.utc).date(adding: 0, in: calendar) : date
            case .local(let day, let second, let zone):
                guard !isAllDay else { return day.start(in: calendar) }
                return Recurrence.instant(day, secondOfDay: second, in: zone.map(zoned) ?? calendar)
            case .date(let day):
                guard !isAllDay else { return day.start(in: calendar) }
                return calendar.date(byAdding: .day, value: CivilDay(year: day.year, month: day.month, day: day.day).number - firstDay.number, to: first)
            }
        }

        /// EXDATEs match timed occurrences by instant (or by local date for a DATE value) and all-day ones by date.
        func exclusions(_ stamps: [Stamp]) -> Exclusions {
            var result = Exclusions(calendar: calendar)
            for stamp in stamps {
                switch stamp {
                case .date(let day):
                    result.days.insert(CivilDay(year: day.year, month: day.month, day: day.day).number)
                case .utc(let date):
                    if isAllDay { result.days.insert(CivilDay(date, in: Recurrence.utc).number) } else { result.instants.insert(Series.key(date)) }
                case .local(let day, let second, let zone):
                    if isAllDay {
                        result.days.insert(CivilDay(year: day.year, month: day.month, day: day.day).number)
                    } else if let date = Recurrence.instant(day, secondOfDay: second, in: zone.map(zoned) ?? calendar) {
                        result.instants.insert(Series.key(date))
                    }
                }
            }
            return result
        }

        func untilLimit(_ until: EventTime?) -> Limit? {
            switch until {
            case nil:
                return nil
            case .allDay(let day)?:
                let civil = CivilDay(year: day.year, month: day.month, day: day.day)
                return isAllDay ? .through(civil.date(adding: 0, in: calendar)) : .before(civil.date(adding: 1, in: calendar))
            case .timed(let date, let zone)?:
                guard zone == nil, !isAllDay else { return .through(date) }
                let parts = Recurrence.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                return .through(calendar.date(from: parts) ?? date)
            }
        }

        /// The starts one rule makes in [lower, upper), apart from the first occurrence, and the dates Foundation
        /// produced for them. Nil past `stepLimit`.
        func expand(_ rule: Rule, from lower: Date, to upper: Date, skipsAhead: Bool, stepLimit: Int) -> (dates: [Date], steps: Int)? {
            let plan = Plan(rule, series: self)
            let limit = untilLimit(rule.until)
            var made = 1
            if let count = rule.count, made >= count { return ([], 0) }
            let anchor = skipsAhead && rule.count == nil ? self.anchor(for: plan, before: lower) : first
            var dates: [Date] = []
            var steps = 0
            var last = first
            for date in plan.recurrence.recurrences(of: anchor) {
                if date >= upper || limit?.excludes(date) == true { break }
                steps += 1
                if steps > stepLimit { return nil }
                guard date > last else { continue }
                last = date
                guard plan.matches(CivilDay(date, in: calendar)) else { continue }
                if date >= lower { dates.append(date) }
                if let count = rule.count {
                    made += 1
                    if made >= count { break }
                }
            }
            return (dates, steps)
        }

        /// A start in the rule's phase (same weekday, week, month or year alignment) at least one period before
        /// `lower`, so a rule without COUNT can skip the years before the window. The first start when there is none.
        func anchor(for plan: Plan, before lower: Date) -> Date {
            guard lower > first else { return first }
            let target = CivilDay(lower, in: calendar)
            let interval = plan.rule.interval
            let time = calendar.dateComponents([.hour, .minute, .second], from: first)
            for back in 1...3 {
                let day: Int
                switch plan.rule.frequency {
                case .daily:
                    let periods = (target.number - firstDay.number) / interval - back
                    guard periods > 0 else { return first }
                    day = firstDay.number + periods * interval
                case .weekly:
                    let periods = (plan.weekStart(of: target) - plan.weekStart(of: firstDay)) / 7 / interval - back
                    guard periods > 0 else { return first }
                    day = firstDay.number + periods * interval * 7
                case .monthly:
                    let periods = ((target.year - firstDay.year) * 12 + target.month - firstDay.month) / interval - back
                    guard periods > 0 else { return first }
                    let month = firstDay.year * 12 + firstDay.month - 1 + periods * interval
                    day = CivilDay(year: month / 12, month: month % 12 + 1, day: 1).number
                case .yearly:
                    let periods = (target.year - firstDay.year) / interval - back
                    guard periods > 0 else { return first }
                    day = CivilDay(year: firstDay.year + periods * interval, month: 1, day: 1).number
                case .secondly, .minutely, .hourly:
                    return first
                }
                // Moving by whole days keeps the wall-clock time unless that day skips it (a DST gap); try a period earlier then.
                if let date = calendar.date(byAdding: .day, value: day - firstDay.number, to: first),
                   calendar.dateComponents([.hour, .minute, .second], from: date) == time {
                    return date
                }
            }
            return first
        }

        private func zoned(_ zone: TimeZone) -> Calendar {
            var copy = calendar
            copy.timeZone = zone
            return copy
        }
    }

    /// One supported rule with the parts RFC 5545 takes from DTSTART filled in, and the Foundation rule that
    /// lists candidate dates for it. `matches` decides which candidates are occurrences.
    struct Plan {
        let rule: Rule
        let first: CivilDay
        /// WEEKLY days, 1 for Sunday through 7 for Saturday.
        let weekdays: Set<Int>
        let monthDays: [Int]
        let ordinals: [WeekdayNumber]
        let months: Set<Int>
        /// WKST, 1 for Sunday.
        let weekStart: Int
        let recurrence: Calendar.RecurrenceRule

        init(_ rule: Rule, series: Series) {
            self.rule = rule
            first = series.firstDay
            weekStart = Recurrence.number(of: rule.weekStart ?? .monday)
            var calendar = series.calendar
            calendar.firstWeekday = weekStart
            weekdays = rule.byDay.isEmpty ? [first.weekday] : Set(rule.byDay.map { Recurrence.number(of: $0.weekday) })
            ordinals = rule.byDay.filter { $0.ordinal != nil }
            monthDays = rule.byDay.isEmpty && rule.byMonthDay.isEmpty ? [first.day] : rule.byMonthDay
            months = rule.byMonth.isEmpty ? [first.month] : Set(rule.byMonth)
            switch rule.frequency {
            case .weekly:
                let days = weekdays.sorted().map { Calendar.RecurrenceRule.Weekday.every(Recurrence.weekdays[$0 - 1]) }
                recurrence = .init(calendar: calendar, frequency: .weekly, interval: rule.interval, weekdays: days)
            case .monthly, .yearly:
                // Candidate days of the month only: Foundation misplaces numbered weekdays. Day 1 is always a candidate,
                // so every period has one and Foundation never searches on for a day that does not come.
                let candidates = Set(monthDays + ordinals.flatMap(Plan.days(for:)) + [1]).sorted()
                recurrence = .init(
                    calendar: calendar, frequency: rule.frequency == .monthly ? .monthly : .yearly, interval: rule.interval,
                    months: rule.frequency == .yearly ? months.sorted().map { .init($0) } : [], daysOfTheMonth: candidates
                )
            case .daily, .secondly, .minutely, .hourly:
                recurrence = .init(calendar: calendar, frequency: .daily, interval: rule.interval)
            }
        }

        /// The days of the month the nth weekday can fall on: 8...14 for "2TU", -7 ... -1 for "-1FR".
        static func days(for weekday: WeekdayNumber) -> [Int] {
            guard let ordinal = weekday.ordinal else { return [] }
            let range = ordinal > 0 ? (7 * ordinal - 6)...(7 * ordinal) : (7 * ordinal)...(7 * ordinal + 6)
            return range.filter { (-31...31).contains($0) && $0 != 0 }
        }

        func weekStart(of day: CivilDay) -> Int { day.number - (day.weekday - weekStart + 7) % 7 }

        /// RFC 5545 for the supported shapes: the day is in the rule's period phase and in its BY parts.
        func matches(_ day: CivilDay) -> Bool {
            switch rule.frequency {
            case .daily:
                return (day.number - first.number) % rule.interval == 0
            case .weekly:
                return weekdays.contains(day.weekday) && (weekStart(of: day) - weekStart(of: first)) / 7 % rule.interval == 0
            case .monthly:
                return ((day.year - first.year) * 12 + day.month - first.month) % rule.interval == 0 && matchesDayOfMonth(day)
            case .yearly:
                return (day.year - first.year) % rule.interval == 0 && months.contains(day.month) && matchesDayOfMonth(day)
            case .secondly, .minutely, .hourly:
                return false
            }
        }

        private func matchesDayOfMonth(_ day: CivilDay) -> Bool {
            let length = day.length
            if monthDays.contains(where: { $0 > 0 ? $0 == day.day : length + 1 + $0 == day.day }) { return true }
            return ordinals.contains { item in
                guard let ordinal = item.ordinal, Recurrence.number(of: item.weekday) == day.weekday else { return false }
                return ordinal > 0 ? (day.day - 1) / 7 + 1 == ordinal : -((length - day.day) / 7 + 1) == ordinal
            }
        }
    }
}
