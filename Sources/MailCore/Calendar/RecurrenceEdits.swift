import Foundation

/// Changing a series from the editor.
extension Recurrence {
    /// "All events" changed from one occurrence: the occurrence's new times, moved back to the series' own first day,
    /// so every event changes the same way. All events keep their days: new times on another day than the
    /// occurrence's give nil. Days and times are counted on the series' own clock (its zone), so a series kept in
    /// another zone moves by what was typed; timed series keep their time zone.
    public static func seriesTimes(
        seriesStart: EventTime, occurrenceStart: EventTime, newStart: EventTime, newEnd: EventTime, calendar viewer: Calendar
    ) -> (start: EventTime, end: EventTime)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seriesStart.timeZone.flatMap(TimeZone.init(identifier:)) ?? viewer.timeZone
        let occurrenceDay = occurrenceStart.dayDate(in: calendar)
        guard newStart.dayDate(in: calendar) == occurrenceDay else { return nil }
        let seriesDay = seriesStart.dayDate(in: calendar)
        let shift = calendar.dateComponents([.day], from: occurrenceDay.start(in: calendar), to: seriesDay.start(in: calendar)).day ?? 0
        let zone = seriesStart.timeZone
        func moved(_ time: EventTime) -> EventTime {
            switch time {
            case .allDay(let day): .allDay(day.adding(days: shift, in: calendar))
            case .timed(let date, let own): .timed(calendar.date(byAdding: .day, value: shift, to: date) ?? date, timeZone: zone ?? own)
            }
        }
        return (moved(newStart), moved(newEnd))
    }

    /// A weekly rule that names its days ("every thu") starts on one of them: times on another day move to the first
    /// named day after it. Other rules, and times already on a named day, stay as they are. Weekdays are counted in the
    /// event's own time zone.
    public static func aligned(start: EventTime, end: EventTime, recurrence: [String], calendar: Calendar) -> (start: EventTime, end: EventTime) {
        guard let line = recurrence.first(where: { propertyName($0) == "RRULE" }), let rule = parseRule(line), rule.frequency == .weekly,
              !rule.byDay.isEmpty else { return (start, end) }
        var zoned = DayDate.gregorian(calendar)
        if let id = start.timeZone, let zone = TimeZone(identifier: id) { zoned.timeZone = zone }
        let named = Set(rule.byDay.map { number(of: $0.weekday) })
        let first = start.dayDate(in: zoned)
        guard let offset = (0..<7).first(where: { named.contains(zoned.component(.weekday, from: first.adding(days: $0, in: zoned).start(in: zoned))) }),
              offset > 0 else { return (start, end) }
        func moved(_ time: EventTime) -> EventTime {
            switch time {
            case .allDay(let day): .allDay(day.adding(days: offset, in: zoned))
            case .timed(let date, let zone): .timed(zoned.date(byAdding: .day, value: offset, to: date) ?? date, timeZone: zone)
            }
        }
        return (moved(start), moved(end))
    }
}
