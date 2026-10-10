import Foundation

extension Recurrence {
    /// A short description in words, en_US: "Daily", "Every 2 days", "Weekly on Mon, Wed", "Every weekday",
    /// "Every 2 weeks on Tue", "Monthly on day 12", "Monthly on the 2nd Tue", "Monthly on the last Fri",
    /// "Yearly on Nov 26", "Yearly on the 4th Thu of Nov", then ", until Dec 18" (", until Dec 18, 2027" in another
    /// year than `start`) or ", 8 times". The until date is the last day an occurrence may start, in the event's zone.
    /// Nil when there is no RRULE, there are several, or the rule cannot be described.
    public static func summary(_ recurrence: [String], start: EventTime, calendar: Calendar) -> String? {
        let lines = recurrence.filter { propertyName($0) == "RRULE" }
        guard lines.count == 1, let rule = lines.first.flatMap(parseRule), rule.interval >= 1, rule.bySetPos.isEmpty,
              rule.byYearDay.isEmpty, rule.byWeekNo.isEmpty, rule.byHour.isEmpty, rule.byMinute.isEmpty, rule.bySecond.isEmpty
        else { return nil }
        let series = Series(start: start, end: start, viewer: calendar)
        guard let text = phrase(for: rule, first: series.firstDay) else { return nil }
        if let count = rule.count { return text + (count == 1 ? ", once" : ", \(count) times") }
        guard let until = rule.until else { return text }
        let last: CivilDay
        switch until {
        case .allDay(let day): last = CivilDay(year: day.year, month: day.month, day: day.day)
        case .timed(let date, nil): last = CivilDay(date, in: utc)
        case .timed(let date, _): last = CivilDay(date, in: series.calendar)
        }
        let year = last.year == series.firstDay.year ? "" : ", \(last.year)"
        return text + ", until \(monthNames[last.month - 1]) \(last.day)" + year
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static func phrase(for rule: Rule, first: CivilDay) -> String? {
        let unnumbered = rule.byDay.allSatisfy { $0.ordinal == nil }
        switch rule.frequency {
        case .daily:
            guard rule.byMonth.isEmpty, rule.byMonthDay.isEmpty, unnumbered else { return nil }
            if rule.byDay.isEmpty { return rule.interval == 1 ? "Daily" : "Every \(rule.interval) days" }
            return rule.interval == 1 ? weekly(Set(rule.byDay.map { number(of: $0.weekday) }), interval: 1) : nil
        case .weekly:
            guard rule.byMonth.isEmpty, rule.byMonthDay.isEmpty, unnumbered else { return nil }
            return weekly(rule.byDay.isEmpty ? [first.weekday] : Set(rule.byDay.map { number(of: $0.weekday) }), interval: rule.interval)
        case .monthly:
            guard rule.byMonth.isEmpty, let days = monthDays(rule, first: first) else { return nil }
            return (rule.interval == 1 ? "Monthly" : "Every \(rule.interval) months") + " on " + days
        case .yearly:
            let prefix = rule.interval == 1 ? "Yearly" : "Every \(rule.interval) years"
            if rule.byMonth.isEmpty {
                guard rule.byDay.isEmpty, rule.byMonthDay.isEmpty else { return nil }
                return "\(prefix) on \(monthNames[first.month - 1]) \(first.day)"
            }
            guard rule.byMonth.count == 1, let month = rule.byMonth.first.map({ monthNames[$0 - 1] }) else { return nil }
            if rule.byDay.isEmpty {
                let days = rule.byMonthDay.isEmpty ? [first.day] : rule.byMonthDay
                guard days.count == 1, let day = days.first else { return nil }
                if day == -1 { return "\(prefix) on the last day of \(month)" }
                return day > 0 ? "\(prefix) on \(month) \(day)" : nil
            }
            guard rule.byMonthDay.isEmpty, rule.byDay.count == 1, let item = rule.byDay.first, let ordinal = item.ordinal else { return nil }
            return "\(prefix) on the \(word(for: ordinal)) \(dayNames[number(of: item.weekday) - 1]) of \(month)"
        case .secondly, .minutely, .hourly:
            return nil
        }
    }

    /// Days listed Monday first.
    private static func weekly(_ days: Set<Int>, interval: Int) -> String {
        if interval == 1 && days == [2, 3, 4, 5, 6] { return "Every weekday" }
        let names = days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { dayNames[$0 - 1] }
        return (interval == 1 ? "Weekly" : "Every \(interval) weeks") + " on " + names.joined(separator: ", ")
    }

    /// "day 12", "days 1, 15", "the last day", "the 2nd Tue", "the last Fri".
    private static func monthDays(_ rule: Rule, first: CivilDay) -> String? {
        if rule.byDay.isEmpty {
            let days = rule.byMonthDay.isEmpty ? [first.day] : rule.byMonthDay
            if days == [-1] { return "the last day" }
            guard days.allSatisfy({ $0 > 0 }) else { return nil }
            let sorted = Set(days).sorted()
            return (sorted.count == 1 ? "day " : "days ") + sorted.map(String.init).joined(separator: ", ")
        }
        guard rule.byMonthDay.isEmpty else { return nil }
        let items = rule.byDay.compactMap { item in item.ordinal.map { "\(word(for: $0)) \(dayNames[number(of: item.weekday) - 1])" } }
        return items.count == rule.byDay.count ? "the " + items.joined(separator: ", ") : nil
    }

    /// "1st", "2nd", "last", "2nd to last".
    private static func word(for ordinal: Int) -> String {
        if ordinal == -1 { return "last" }
        if ordinal < 0 { return word(for: -ordinal) + " to last" }
        let suffix = switch (ordinal % 10, ordinal % 100) {
        case (1, let tens) where tens != 11: "st"
        case (2, let tens) where tens != 12: "nd"
        case (3, let tens) where tens != 13: "rd"
        default: "th"
        }
        return "\(ordinal)\(suffix)"
    }
}
