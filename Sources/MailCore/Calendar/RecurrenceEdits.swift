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

/// "This and following": cutting a series in two at one of its days.
extension Recurrence {
    /// Where "this and following" cuts a series.
    public enum Split: Hashable, Sendable {
        /// Nothing of the series comes before the day (it is the first, or the event does not repeat): every event
        /// changes, as for all events.
        case wholeSeries
        /// The series keeps `before`: its rules end the moment before the day, and the days it skips or adds from then on
        /// are gone. A new series starts that day with `after`: the same rules (COUNT less the events before, UNTIL as it
        /// was) and the days skipped or added from that day on.
        case split(before: [String], after: [String])
    }

    /// Cuts a series at one of its days. `at` is that day's start in the rule (an occurrence's `originalStart`). A timed
    /// series ends one second before it (UNTIL in UTC), an all-day series the day before, and COUNT goes: the new series
    /// gets what is left of it. Nil when a rule does not parse, or has COUNT and cannot be counted here (see
    /// `occurrences`): change it in Google Calendar then.
    public static func split(recurrence: [String], seriesStart: EventTime, at: EventTime, calendar viewer: Calendar) -> Split? {
        let series = Series(start: seriesStart, end: seriesStart, viewer: viewer)
        let day = at.dayDate(in: viewer)
        let cut = series.isAllDay ? day.start(in: series.calendar) : at.instant(in: viewer)
        // The events before the cut, as `occurrences` windows them.
        let from = seriesStart.instant(in: viewer)
        let to = series.isAllDay ? day.start(in: viewer) : cut
        // Without rules or added days there is one event, so nothing follows it either.
        guard cut > series.first, recurrence.contains(where: { ["RRULE", "RDATE"].contains(propertyName($0)) }) else { return .wholeSeries }
        // The first day always comes before the cut, unless an EXDATE takes it away: then another day has to.
        let excluded = recurrence.filter { propertyName($0) == "EXDATE" }.compactMap(parseDates).flatMap(\.stamps)
        if series.exclusions(excluded).contains(series.first),
           occurrences(start: seriesStart, end: seriesStart, recurrence: recurrence, from: from, to: to, calendar: viewer)?.isEmpty == true {
            return .wholeSeries
        }
        var before: [String] = []
        var after: [String] = []
        for line in recurrence {
            switch propertyName(line) {
            case "RRULE":
                guard let rule = parseRule(line) else { return nil }
                // A rule that ended before the day stays as it is, and the new series does without it.
                if series.untilLimit(rule.until)?.excludes(cut) == true {
                    before.append(line)
                    continue
                }
                var rest = rule
                if let count = rule.count {
                    // COUNT counts the rule's own dates, the ones an EXDATE took away too.
                    guard let made = occurrences(start: seriesStart, end: seriesStart, recurrence: [line], from: from, to: to, calendar: viewer)?.count
                    else { return nil }
                    if made >= count {
                        before.append(line)
                        continue
                    }
                    rest.count = count - made
                }
                var ended = rule
                ended.count = nil
                ended.until = series.isAllDay ? .allDay(day.adding(days: -1, in: series.calendar)) : .timed(cut.addingTimeInterval(-1), timeZone: "UTC")
                before.append(Recurrence.line(for: ended))
                after.append(rest == rule ? line : Recurrence.line(for: rest))
            case "EXDATE", "RDATE":
                let parts = dates(line, cutAt: cut, series: series)
                before += parts.before
                after += parts.after
            default:
                before.append(line)
                after.append(line)
            }
        }
        return .split(before: before, after: after)
    }

    /// The first event of the series that takes over ("this and following"): the times as typed, kept on the old series'
    /// clock (its zone), so the new series repeats at the same time as the old one did. All-day times stay as they are.
    public static func followingTimes(start: EventTime, end: EventTime, seriesStart: EventTime, seriesEnd: EventTime) -> (start: EventTime, end: EventTime) {
        func zoned(_ time: EventTime, _ zone: String?) -> EventTime {
            guard case .timed(let date, let own) = time else { return time }
            return .timed(date, timeZone: zone ?? own)
        }
        return (zoned(start, seriesStart.timeZone), zoned(end, seriesEnd.timeZone ?? seriesStart.timeZone))
    }

    /// An EXDATE or RDATE line as the old series keeps it (its values before the cut) and as the new one takes it (the
    /// values on or after it). A value that does not parse stays with the old series.
    private static func dates(_ line: String, cutAt cut: Date, series: Series) -> (before: [String], after: [String]) {
        guard let colon = line.firstIndex(of: ":") else { return ([line], []) }
        let head = String(line[..<colon])
        var early: [String] = []
        var late: [String] = []
        for value in line[line.index(after: colon)...].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if let moment = moment(of: value, head: head, series: series), moment >= cut { late.append(value) } else { early.append(value) }
        }
        if late.isEmpty { return ([line], []) }
        if early.isEmpty { return ([], [line]) }
        return ([head + ":" + early.joined(separator: ",")], [head + ":" + late.joined(separator: ",")])
    }

    /// When an EXDATE or RDATE value falls in a series (a period by its start), on the series' own clock.
    private static func moment(of value: String, head: String, series: Series) -> Date? {
        let start = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        let plain = head.split(separator: ";").filter { $0.uppercased() != "VALUE=PERIOD" }.joined(separator: ";")
        return parseDates(plain + ":" + start)?.stamps.first.flatMap(series.date(of:))
    }
}
