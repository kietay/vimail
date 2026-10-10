import Foundation

extension QuickAdd {
    /// An event's times in the quick-add grammar, for the editor's When field: "oct 12 14:00-14:45", "oct 12 all day",
    /// "oct 16-18", "oct 30 - nov 2", "oct 9-11 09:00-17:00", "oct 9 10:00 48h". The year is added when the date
    /// alone would read as another year. `parse` at the same `now` reads the text back as the same times whenever the
    /// grammar can say them (to the minute, up to a week long); otherwise the text is the nearest it can say.
    public static func text(start: EventTime, end: EventTime, now: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let candidates = WhenText(calendar: gregorian).candidates(start: start, end: end)
        for candidate in candidates {
            let read = parse(candidate, now: now, calendar: gregorian) { _ in [] }
            guard read.title == "(no title)", let readStart = read.start, let readEnd = read.end else { continue }
            if WhenText.same(readStart, start, gregorian), WhenText.same(readEnd, end, gregorian) { return candidate }
        }
        return candidates.first ?? ""
    }
}

extension QuickAdd {
    /// The Repeats text for a stored rule ("every mon and wed until dec 18 2026"), and whether it says the rule exactly:
    /// `repeatRule` reads it back as the same rule for this start. A rule the words cannot say ("monthly on the second
    /// Tuesday", several rules) comes back as its summary, with `exact` false: it is shown, not edited.
    public static func repeatText(_ recurrence: [String], start: EventTime, now: Date, calendar: Calendar) -> (text: String, exact: Bool) {
        let rules = recurrence.filter { Recurrence.propertyName($0) == "RRULE" }
        guard let line = rules.first else { return ("", true) }
        if rules.count == 1, let rule = Recurrence.parseRule(line) {
            for candidate in RepeatText.candidates(rule, calendar: calendar) {
                if let rebuilt = repeatRule(candidate, start: start, now: now, calendar: calendar).flatMap(Recurrence.parseRule),
                   RepeatText.same(rebuilt, rule, start: start, calendar: calendar) {
                    return (candidate, true)
                }
            }
        }
        return (Recurrence.summary(recurrence, start: start, calendar: calendar) ?? "custom", false)
    }

    /// The RRULE a Repeats text means for a series starting at `start`. The start's date is written out, so the rule
    /// repeats on its days, while dates in the text ("until dec 18") count from `now`. Nil when the text is no repeat.
    public static func repeatRule(_ text: String, start: EventTime, now: Date, calendar: Calendar) -> String? {
        let day = start.dayDate(in: calendar)
        let line = "x \(WhenText.months[day.month - 1]) \(day.day) \(day.year) " + (start.isAllDay ? "all day " : "12:00 ") + text
        return parse(line, now: now, calendar: calendar) { _ in [] }.recurrence.first
    }
}

/// Repeat rules in words.
private enum RepeatText {
    static let weekdays: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
    static let names: [Locale.Weekday: String] = [
        .monday: "mon", .tuesday: "tue", .wednesday: "wed", .thursday: "thu", .friday: "fri", .saturday: "sat", .sunday: "sun",
    ]

    /// Ways to say a rule, clearest first. Empty when the grammar has no words for it.
    static func candidates(_ rule: Recurrence.Rule, calendar: Calendar) -> [String] {
        guard rule.byDay.allSatisfy({ $0.ordinal == nil }), rule.bySetPos.isEmpty, rule.byYearDay.isEmpty, rule.byWeekNo.isEmpty,
              rule.byHour.isEmpty, rule.byMinute.isEmpty, rule.bySecond.isEmpty, rule.byMonth.isEmpty else { return [] }
        let days = weekdays.filter { day in rule.byDay.contains { $0.weekday == day } }.compactMap { names[$0] }
        // Monday first, as people say them.
        let ordered = days.filter { $0 != "sun" } + days.filter { $0 == "sun" }
        let named = ordered.joined(separator: " and ")
        let every = rule.interval
        var phrases: [String]
        switch rule.frequency {
        case .daily:
            guard rule.byDay.isEmpty, rule.byMonthDay.isEmpty else { return [] }
            phrases = every == 1 ? ["daily"] : ["every \(every) days"]
        case .weekly:
            guard rule.byMonthDay.isEmpty else { return [] }
            if days.isEmpty {
                phrases = every == 1 ? ["weekly"] : every == 2 ? ["every other week", "every 2 weeks"] : ["every \(every) weeks"]
            } else if every == 1 {
                phrases = Set(days) == ["mon", "tue", "wed", "thu", "fri"] ? ["every weekday", "every \(named)"] : ["every \(named)"]
            } else {
                phrases = (every == 2 ? ["every other \(named)"] : []) + ["every \(every) weeks on \(named)", "every \(every) weeks \(named)"]
            }
        case .monthly:
            guard rule.byDay.isEmpty, rule.byMonthDay.count <= 1 else { return [] }
            phrases = every == 1 ? ["monthly"] : ["every \(every) months"]
        case .yearly:
            guard rule.byDay.isEmpty, rule.byMonthDay.isEmpty else { return [] }
            phrases = every == 1 ? ["yearly"] : ["every \(every) years"]
        default:
            return []
        }
        var tail = ""
        if let until = rule.until {
            let day = until.dayDate(in: calendar)
            tail = " until \(WhenText.months[day.month - 1]) \(day.day) \(day.year)"
        } else if let count = rule.count {
            tail = " x\(count)"
        }
        return phrases.map { $0 + tail }
    }

    /// Two rules repeat the same way for a series starting at `start`: a weekly rule without days repeats on the
    /// start's day, a monthly one on its date, and an end counts by its day.
    static func same(_ a: Recurrence.Rule, _ b: Recurrence.Rule, start: EventTime, calendar: Calendar) -> Bool {
        let gregorian = DayDate.gregorian(calendar)
        let day = start.dayDate(in: gregorian)
        let weekday = weekdays[gregorian.component(.weekday, from: day.start(in: gregorian)) - 1]
        func normal(_ rule: Recurrence.Rule) -> Recurrence.Rule {
            var rule = rule
            // The week start changes only a weekly rule every 2+ weeks on several days ("every other sun and mon").
            let weekStartMatters = rule.frequency == .weekly && rule.interval > 1 && rule.byDay.count > 1
            rule.weekStart = weekStartMatters ? (rule.weekStart ?? .monday) : nil
            if rule.frequency == .weekly, rule.byDay.isEmpty { rule.byDay = [Recurrence.WeekdayNumber(weekday: weekday)] }
            if rule.frequency == .monthly, rule.byDay.isEmpty, rule.byMonthDay.isEmpty { rule.byMonthDay = [day.day] }
            rule.byDay = rule.byDay.sorted { (weekdays.firstIndex(of: $0.weekday) ?? 0) < (weekdays.firstIndex(of: $1.weekday) ?? 0) }
            if let until = rule.until { rule.until = .allDay(until.dayDate(in: gregorian)) }
            return rule
        }
        return normal(a) == normal(b)
    }
}

/// The ways to write one event's times, clearest first, each without and then with years.
private struct WhenText {
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    let calendar: Calendar

    func candidates(start: EventTime, end: EventTime) -> [String] {
        var forms: [(Bool) -> String] = []
        switch (start, end) {
        case (.allDay(let first), .allDay(let after)):
            let last = after.adding(days: -1, in: calendar)
            if last <= first {
                forms.append { "\(day(first, $0)) all day" }
            } else {
                forms.append { range(first, last, $0) }
            }
        default:
            let from = start.instant(in: calendar)
            let to = end.instant(in: calendar)
            let firstDay = DayDate(from, in: calendar)
            let lastDay = DayDate(to, in: calendar)
            let fromMinutes = minutes(from)
            let toMinutes = minutes(to)
            let length = Int((to.timeIntervalSince(from) / 60).rounded())
            guard length > 0 else { return [false, true].map { "\(day(firstDay, $0)) \(clock(from))" } }
            let times = "\(clock(from))-\(clock(to))"
            // One day, or overnight: an end before the start time ends the next day.
            if lastDay == firstDay || (lastDay == firstDay.adding(days: 1, in: calendar) && toMinutes < fromMinutes) {
                forms.append { "\(day(firstDay, $0)) \(times)" }
            }
            // Several days: from the first day's start time to the last day's end time.
            if lastDay > firstDay, toMinutes > fromMinutes {
                forms.append { "\(range(firstDay, lastDay, $0)) \(times)" }
            }
            forms.append { "\(day(firstDay, $0)) \(clock(from)) \(lengthText(length))" }
        }
        return forms.flatMap { form in [false, true].map(form) }
    }

    /// "oct 16", or "oct 16 2027" with the year.
    func day(_ date: DayDate, _ years: Bool) -> String {
        "\(Self.months[date.month - 1]) \(date.day)" + (years ? " \(date.year)" : "")
    }

    /// "oct 16-18", "oct 16-18 2027", "oct 30 - nov 2", "dec 30 2026 - jan 2 2027".
    func range(_ first: DayDate, _ last: DayDate, _ years: Bool) -> String {
        if first.year == last.year, first.month == last.month { return "\(day(first, false))-\(last.day)" + (years ? " \(first.year)" : "") }
        return "\(day(first, years)) - \(day(last, years))"
    }

    /// "09:30": 24-hour with two digits, which quick add reads without guessing am or pm.
    func clock(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    func minutes(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// "45m", "2h", "1h30".
    func lengthText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes / 60)h" + String(format: "%02d", minutes % 60)
    }

    /// The same moment, or the same day.
    static func same(_ read: EventTime, _ time: EventTime, _ calendar: Calendar) -> Bool {
        switch (read, time) {
        case (.allDay(let a), .allDay(let b)): a == b
        case (.timed(let a, _), .timed(let b, _)): abs(a.timeIntervalSince(b)) < 1
        default: false
        }
    }
}
