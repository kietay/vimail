import Foundation

/// Free time for proposing meetings: the gaps between busy times inside working hours, and a short Markdown list
/// of them to paste into a reply. Dates are Gregorian, in `calendar`'s time zone.
public enum FreeTime {
    /// Free intervals per day inside working hours, after removing busy intervals; only slots at least `minimum` long, never before `now`.
    /// `workStart`/`workEnd` are minutes after midnight (e.g. 9*60, 17*60). Days are processed in `calendar`'s zone.
    ///
    /// Overlapping busy intervals are merged. Slot starts round up and ends round down to a quarter hour, and
    /// `minimum` applies after rounding. Every day in `days` gets an entry, in order, with no slots when it is full.
    public static func slots(
        busy: [DateInterval], days: [DayDate], workStart: Int, workEnd: Int, minimum: TimeInterval, now: Date, calendar: Calendar
    ) -> [(day: DayDate, slots: [DateInterval])] {
        let calendar = gregorian(calendar)
        let merged = merge(busy)
        let first = min(max(workStart, 0), 1440)
        let last = min(max(workEnd, 0), 1440)
        return days.map { day in
            guard first < last else { return (day, []) }
            let close = moment(day, last, calendar)
            var cursor = max(moment(day, first, calendar), now)
            var gaps: [DateInterval] = []
            for interval in merged where interval.end > cursor {
                if interval.start >= close { break }
                if interval.start > cursor { gaps.append(DateInterval(start: cursor, end: interval.start)) }
                cursor = max(cursor, interval.end)
            }
            if cursor < close { gaps.append(DateInterval(start: cursor, end: close)) }
            let slots = gaps.compactMap { gap -> DateInterval? in
                let start = rounded(gap.start, .up)
                let end = rounded(gap.end, .down)
                guard end > start, end.timeIntervalSince(start) >= minimum else { return nil }
                return DateInterval(start: start, end: end)
            }
            return (day, slots)
        }
    }

    /// Markdown for a reply, e.g. "Free times (PT):\n- Tue Oct 13: 09:45–17:00\n- Wed Oct 14: 09:45–12:00". Days without slots are left out. `zoneLabel` like "PT".
    ///
    /// Several slots on one day are joined with ", ". Returns "" when no day has a slot, so the caller can say so its own way.
    public static func markdown(_ days: [(day: DayDate, slots: [DateInterval])], calendar: Calendar, zoneLabel: String) -> String {
        let calendar = gregorian(calendar)
        let dayFormat = formatter("EEE MMM d", calendar)
        let timeFormat = formatter("HH:mm", calendar)
        let lines = days.filter { !$0.slots.isEmpty }.map { entry in
            let times = entry.slots.map { slot in
                let end = timeFormat.string(from: slot.end)
                return "\(timeFormat.string(from: slot.start))–\(end == "00:00" ? "24:00" : end)"
            }
            return "- \(dayFormat.string(from: entry.day.start(in: calendar))): " + times.joined(separator: ", ")
        }
        guard !lines.isEmpty else { return "" }
        return (["Free times (\(zoneLabel)):"] + lines).joined(separator: "\n")
    }

    /// Find a time: the next (or previous) start after `current` where `length` fits in everyone's free time,
    /// inside working hours on working days, never before `now`. Candidates are the starts of the free slots
    /// over the next `workingDays` working days, so each step jumps past a busy time.
    public static func nextSlot(
        from current: Date, forward: Bool, length: TimeInterval, busy: [DateInterval], workStart: Int, workEnd: Int,
        now: Date, workingDays: Int = 15, calendar: Calendar
    ) -> DateInterval? {
        let length = max(length, 60)
        let first = min(current, now)
        let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: max(current, now))).day ?? 0
        let days = Self.workingDays(from: first, count: span + workingDays, calendar: calendar)
        let starts = slots(busy: busy, days: days, workStart: workStart, workEnd: workEnd, minimum: length, now: now, calendar: calendar)
            .flatMap(\.slots).map(\.start)
        let start = forward ? starts.first { $0 > current } : starts.last { $0 < current }
        return start.map { DateInterval(start: $0, duration: length) }
    }

    /// `intervals` without the parts that `holes` cover: guests' busy times without the event being edited.
    public static func subtracting(_ holes: [DateInterval], from intervals: [DateInterval]) -> [DateInterval] {
        holes.reduce(intervals) { result, hole in
            result.flatMap { span -> [DateInterval] in
                guard span.start < hole.end, hole.start < span.end else { return [span] }
                var parts: [DateInterval] = []
                if span.start < hole.start { parts.append(DateInterval(start: span.start, end: hole.start)) }
                if hole.end < span.end { parts.append(DateInterval(start: hole.end, end: span.end)) }
                return parts
            }
        }
    }

    /// The next `count` working days starting at `from`'s day (skipping Saturday and Sunday).
    public static func workingDays(from: Date, count: Int, calendar: Calendar) -> [DayDate] {
        let calendar = gregorian(calendar)
        let wanted = min(max(count, 0), 10_000)
        var result: [DayDate] = []
        var day = DayDate(from, in: calendar)
        while result.count < wanted {
            let weekday = calendar.component(.weekday, from: day.start(in: calendar))
            if weekday != 1, weekday != 7 { result.append(day) }
            let next = day.adding(days: 1, in: calendar)
            guard next > day else { break }
            day = next
        }
        return result
    }

    private static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                if interval.end > last.end { merged[merged.count - 1] = DateInterval(start: last.start, end: interval.end) }
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// To a quarter hour. Every current zone is a whole number of quarter hours from UTC, so this is the wall clock's quarter hour too.
    private static func rounded(_ date: Date, _ rule: FloatingPointRoundingRule) -> Date {
        let seconds = (date.timeIntervalSince1970 * 1000).rounded() / 1000
        return Date(timeIntervalSince1970: (seconds / 900).rounded(rule) * 900)
    }

    /// The wall-clock moment `minutes` after the start of `day` (1440 is the next midnight).
    private static func moment(_ day: DayDate, _ minutes: Int, _ calendar: Calendar) -> Date {
        let date = day.adding(days: minutes / 1440, in: calendar)
        let rest = minutes % 1440
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: rest / 60, minute: rest % 60))
            ?? date.start(in: calendar).addingTimeInterval(TimeInterval(rest * 60))
    }

    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = calendar.timeZone
        return result
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
