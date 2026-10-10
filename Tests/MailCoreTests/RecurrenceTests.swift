import Foundation
import Testing
@testable import MailCore

private let laID = "America/Los_Angeles"
private let la = calendar(laID)

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

/// A wall-clock time in `zone`.
private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, zone: String = laID) -> Date {
    calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// A moment written in UTC, "2026-10-27T16:00:00Z".
private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private func day(_ text: String) -> DayDate { DayDate(text)! }

/// Starts of a timed series' occurrences in [from, to).
private func starts(_ recurrence: [String], first: Date, minutes: Double = 60, zone: String? = laID, from: Date, to: Date) -> [Date]? {
    Recurrence.occurrences(
        start: .timed(first, timeZone: zone), end: .timed(first.addingTimeInterval(minutes * 60), timeZone: zone),
        recurrence: recurrence, from: from, to: to, calendar: la
    )?.compactMap(\.start.date)
}

/// Days of a one-day all-day series' occurrences in [from, to).
private func days(_ recurrence: [String], first: DayDate, from: Date, to: Date) -> [DayDate]? {
    Recurrence.occurrences(
        start: .allDay(first), end: .allDay(first.adding(days: 1, in: calendar("UTC"))),
        recurrence: recurrence, from: from, to: to, calendar: la
    )?.compactMap(\.start.day)
}

@Suite("Recurrence expansion")
struct RecurrenceExpansionTests {
    @Test func weeklyKeepsTheWallClockAcrossTheEndOfDaylightTime() throws {
        let first = at(2026, 10, 27, 9)
        let occurrences = try #require(Recurrence.occurrences(
            start: .timed(first, timeZone: laID), end: .timed(first.addingTimeInterval(3600), timeZone: laID),
            recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=TU"], from: at(2026, 10, 26), to: at(2026, 11, 4), calendar: la
        ))
        #expect(occurrences.map(\.start) == [.timed(utc("2026-10-27T16:00:00Z"), timeZone: laID), .timed(utc("2026-11-03T17:00:00Z"), timeZone: laID)])
        #expect(occurrences.map(\.end) == [.timed(utc("2026-10-27T17:00:00Z"), timeZone: laID), .timed(utc("2026-11-03T18:00:00Z"), timeZone: laID)])
        #expect(occurrences.map(\.originalStart) == occurrences.map(\.start))
    }

    @Test func everyOtherWeekOnTwoDays() {
        let result = starts(["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"], first: at(2026, 11, 2, 10), from: at(2026, 11, 1), to: at(2026, 12, 3))
        let expected = ["2026-11-02", "2026-11-04", "2026-11-16", "2026-11-18", "2026-11-30", "2026-12-02"].map { utc($0 + "T18:00:00Z") }
        #expect(result == expected)
    }

    @Test func weekdayStandupShowsOnlyWeekdaysInTheWindow() {
        let result = starts(["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"], first: at(2026, 1, 5, 9, 30), minutes: 15, from: at(2026, 10, 30), to: at(2026, 11, 3))
        #expect(result == [utc("2026-10-30T16:30:00Z"), utc("2026-11-02T17:30:00Z")])
    }

    @Test(arguments: [nil, "SU", "MO", "WE"])
    func lastFridayOfTheMonth(weekStart: String?) {
        let rule = "RRULE:FREQ=MONTHLY;BYDAY=-1FR" + (weekStart.map { ";WKST=" + $0 } ?? "")
        let result = starts([rule], first: at(2026, 10, 30, 12), from: at(2026, 10, 1), to: at(2027, 4, 1))
        // Foundation alone answers Jan 22 and Feb 19 for 2027 when weeks start on Monday.
        let expected = ["2026-10-30T19", "2026-11-27T20", "2026-12-25T20", "2027-01-29T20", "2027-02-26T20", "2027-03-26T19"].map { utc($0 + ":00:00Z") }
        #expect(result == expected)
    }

    @Test func thanksgivingIsTheFourthThursdayOfNovember() {
        let rule = ["RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH"]
        let expected = ["2026-11-26", "2027-11-25", "2028-11-23", "2029-11-22", "2030-11-28"].map(day)
        #expect(days(rule, first: day("2026-11-26"), from: at(2026, 1, 1), to: at(2031, 1, 1)) == expected)
        let dinners = starts(rule, first: at(2026, 11, 26, 17), from: at(2026, 1, 1), to: at(2031, 1, 1))
        #expect(dinners?.map { DayDate($0, in: la) } == expected)
    }

    @Test func monthDay31SkipsShorterMonths() {
        let expected = ["2026-01-31T17", "2026-03-31T16", "2026-05-31T16", "2026-07-31T16", "2026-08-31T16", "2026-10-31T16", "2026-12-31T17"].map { utc($0 + ":00:00Z") }
        #expect(starts(["RRULE:FREQ=MONTHLY;BYMONTHDAY=31"], first: at(2026, 1, 31, 9), from: at(2026, 1, 1), to: at(2027, 1, 1)) == expected)
        // The day comes from DTSTART; Foundation alone would move it to Mar 1, May 1, Jul 1...
        #expect(starts(["RRULE:FREQ=MONTHLY"], first: at(2026, 1, 31, 9), from: at(2026, 1, 1), to: at(2027, 1, 1)) == expected)
    }

    @Test func lastDayOfTheMonth() {
        let result = starts(["RRULE:FREQ=MONTHLY;BYMONTHDAY=-1"], first: at(2026, 1, 31, 9), from: at(2026, 1, 1), to: at(2026, 7, 1))
        #expect(result?.map { DayDate($0, in: la) } == ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31", "2026-06-30"].map(day))
    }

    @Test func countIsCountedFromTheFirstOccurrenceNotTheWindow() {
        let result = starts(["RRULE:FREQ=DAILY;COUNT=5"], first: at(2026, 10, 1, 9), from: at(2026, 10, 3), to: at(2026, 11, 1))
        #expect(result == [utc("2026-10-03T16:00:00Z"), utc("2026-10-04T16:00:00Z"), utc("2026-10-05T16:00:00Z")])
        // An EXDATE removes one of the five; it does not add a sixth.
        let excluded = starts(["RRULE:FREQ=DAILY;COUNT=5", "EXDATE;TZID=America/Los_Angeles:20261002T090000"], first: at(2026, 10, 1, 9), from: at(2026, 10, 1), to: at(2026, 11, 1))
        #expect(excluded?.map { DayDate($0, in: la) } == ["2026-10-01", "2026-10-03", "2026-10-04", "2026-10-05"].map(day))
    }

    @Test func untilIsInclusive() {
        func tuesdays(until: String) -> [Date]? {
            starts(["RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=" + until], first: at(2026, 10, 27, 9), from: at(2026, 10, 1), to: at(2027, 1, 1))
        }
        let three = [utc("2026-10-27T16:00:00Z"), utc("2026-11-03T17:00:00Z"), utc("2026-11-10T17:00:00Z")]
        #expect(tuesdays(until: "20261110T170000Z") == three)
        #expect(tuesdays(until: "20261110T165959Z") == Array(three.prefix(2)))
        // A date covers its whole day; a floating time is read on the event's clock.
        #expect(tuesdays(until: "20261110") == three)
        #expect(tuesdays(until: "20261110T090000") == three)
        #expect(tuesdays(until: "20261110T085959") == Array(three.prefix(2)))
        func fridays(until: String) -> [DayDate]? {
            days(["RRULE:FREQ=WEEKLY;UNTIL=" + until], first: day("2026-10-30"), from: at(2026, 10, 1), to: at(2027, 1, 1))
        }
        #expect(fridays(until: "20261113") == ["2026-10-30", "2026-11-06", "2026-11-13"].map(day))
        #expect(fridays(until: "20261113T000000Z") == ["2026-10-30", "2026-11-06", "2026-11-13"].map(day))
        #expect(fridays(until: "20261112T235959Z") == ["2026-10-30", "2026-11-06"].map(day))
    }

    @Test func exdatesInEveryForm() {
        let rules = [
            "RRULE:FREQ=WEEKLY;BYDAY=TU",
            "EXDATE;TZID=America/Los_Angeles:20261103T090000,20261110T090000",
            "EXDATE:20261117T170000Z",
            "EXDATE;VALUE=DATE:20261124",
            "EXDATE;TZID=America/New_York:20261208T120000",
            "EXDATE:20261215T090000",
        ]
        let result = starts(rules, first: at(2026, 10, 27, 9), from: at(2026, 10, 26), to: at(2026, 12, 16))
        #expect(result == [utc("2026-10-27T16:00:00Z"), utc("2026-12-01T17:00:00Z")])
        let withoutFirst = starts(["RRULE:FREQ=WEEKLY;BYDAY=TU", "EXDATE;TZID=America/Los_Angeles:20261027T090000"], first: at(2026, 10, 27, 9), from: at(2026, 10, 1), to: at(2026, 11, 4))
        #expect(withoutFirst == [utc("2026-11-03T17:00:00Z")])
        let allDay = days(["RRULE:FREQ=WEEKLY", "EXDATE;VALUE=DATE:20261106", "EXDATE:20261120T000000Z"], first: day("2026-10-30"), from: at(2026, 10, 1), to: at(2026, 12, 1))
        #expect(allDay == ["2026-10-30", "2026-11-13", "2026-11-27"].map(day))
    }

    @Test func rdatesAddOccurrencesOfTheSameLength() throws {
        let rules = [
            "RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=2",
            "RDATE;TZID=America/Los_Angeles:20261105T140000,20261103T090000",
            "RDATE:20261106T170000Z",
            "RDATE;VALUE=DATE:20261108",
        ]
        let first = at(2026, 10, 27, 9)
        let occurrences = try #require(Recurrence.occurrences(
            start: .timed(first, timeZone: laID), end: .timed(first.addingTimeInterval(3600), timeZone: laID),
            recurrence: rules, from: at(2026, 10, 1), to: at(2027, 1, 1), calendar: la
        ))
        let expected = ["2026-10-27T16", "2026-11-03T17", "2026-11-05T22", "2026-11-06T17", "2026-11-08T17"].map { utc($0 + ":00:00Z") }
        #expect(occurrences.compactMap(\.start.date) == expected)
        #expect(occurrences.allSatisfy { ($0.end.date?.timeIntervalSince($0.start.date ?? .distantPast)) == 3600 })
        let allDay = days(["RRULE:FREQ=WEEKLY;COUNT=2", "RDATE;VALUE=DATE:20261107"], first: day("2026-10-30"), from: at(2026, 10, 1), to: at(2026, 12, 1))
        #expect(allDay == ["2026-10-30", "2026-11-06", "2026-11-07"].map(day))
    }

    @Test func firstOccurrenceIsKeptAndCountedEvenWhenTheRuleSkipsIt() {
        let result = starts(["RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=3"], first: at(2026, 10, 28, 9), from: at(2026, 10, 1), to: at(2027, 1, 1))
        #expect(result == [utc("2026-10-28T16:00:00Z"), utc("2026-11-02T17:00:00Z"), utc("2026-11-09T17:00:00Z")])
    }

    @Test func severalRulesMakeAUnion() {
        let rules = ["RRULE:FREQ=WEEKLY;BYDAY=MO", "RRULE:FREQ=WEEKLY;BYDAY=WE;COUNT=2"]
        let result = starts(rules, first: at(2026, 11, 2, 10), from: at(2026, 11, 1), to: at(2026, 11, 17))
        #expect(result?.map { DayDate($0, in: la) } == ["2026-11-02", "2026-11-04", "2026-11-09", "2026-11-16"].map(day))
    }

    /// February 29 repeats only in leap years: RFC 5545 skips dates that do not exist.
    @Test func birthdayOnFebruary29ComesInLeapYearsOnly() throws {
        let occurrences = try #require(Recurrence.occurrences(
            start: .allDay(day("2024-02-29")), end: .allDay(day("2024-03-01")), recurrence: ["RRULE:FREQ=YEARLY"],
            from: at(2024, 1, 1), to: at(2033, 1, 1), calendar: la
        ))
        #expect(occurrences.map(\.start) == ["2024-02-29", "2028-02-29", "2032-02-29"].map { .allDay(day($0)) })
        #expect(occurrences.map(\.end) == ["2024-03-01", "2028-03-01", "2032-03-01"].map { .allDay(day($0)) })
        #expect(occurrences.map(\.originalStart) == occurrences.map(\.start))
        let meeting = starts(["RRULE:FREQ=YEARLY"], first: at(2024, 2, 29, 9), from: at(2024, 1, 1), to: at(2033, 1, 1))
        #expect(meeting?.map { DayDate($0, in: la) } == ["2024-02-29", "2028-02-29", "2032-02-29"].map(day))
        // Who wants it every year writes the last day of February.
        let lastDay = days(["RRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1"], first: day("2024-02-29"), from: at(2025, 1, 1), to: at(2029, 1, 1))
        #expect(lastDay == ["2025-02-28", "2026-02-28", "2027-02-28", "2028-02-29"].map(day))
    }

    @Test func allDayBirthdayFromDecadesAgo() {
        #expect(days(["RRULE:FREQ=YEARLY"], first: day("1958-11-26"), from: at(2026, 1, 1), to: at(2028, 1, 1)) == ["2026-11-26", "2027-11-26"].map(day))
    }

    @Test func allDayEventsOverSeveralDaysRepeatWithTheirLength() throws {
        func weekends(from: Date, to: Date) -> [Occurrence]? {
            Recurrence.occurrences(
                start: .allDay(day("2026-10-30")), end: .allDay(day("2026-11-02")), recurrence: ["RRULE:FREQ=WEEKLY"],
                from: from, to: to, calendar: la
            )
        }
        let sunday = try #require(weekends(from: at(2026, 11, 8), to: at(2026, 11, 9)))
        #expect(sunday == [Occurrence(start: .allDay(day("2026-11-06")), end: .allDay(day("2026-11-09")), originalStart: .allDay(day("2026-11-06")))])
        #expect(weekends(from: at(2026, 11, 9), to: at(2026, 11, 13)) == [])
        #expect(weekends(from: at(2026, 10, 1), to: at(2026, 11, 21))?.map(\.start) == ["2026-10-30", "2026-11-06", "2026-11-13", "2026-11-20"].map { .allDay(day($0)) })
    }

    @Test func seriesFromYearsAgoAreFast() throws {
        func expand(_ line: String, first: Date, from: Date, to: Date, skipsAhead: Bool = true) throws -> Recurrence.Expansion {
            try #require(Recurrence.expansion(
                start: .timed(first, timeZone: laID), end: .timed(first.addingTimeInterval(3600), timeZone: laID),
                recurrence: [line], from: from, to: to, calendar: la, skipsAhead: skipsAhead
            ))
        }
        var results: [Recurrence.Expansion] = []
        let elapsed = try ContinuousClock().measure {
            results.append(try expand("RRULE:FREQ=DAILY", first: at(2015, 1, 5, 9, 30), from: at(2026, 10, 30), to: at(2026, 11, 6)))
            results.append(try expand("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", first: at(2015, 1, 5, 9, 30), from: at(2026, 10, 30), to: at(2026, 11, 6)))
            results.append(try expand("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TH", first: at(2015, 1, 8, 11), from: at(2026, 10, 25), to: at(2026, 11, 15)))
            results.append(try expand("RRULE:FREQ=MONTHLY;BYDAY=2TU", first: at(1995, 5, 9, 18), from: at(2026, 11, 1), to: at(2026, 12, 1)))
        }
        let daily = ["2026-10-30T16", "2026-10-31T16", "2026-11-01T17", "2026-11-02T17", "2026-11-03T17", "2026-11-04T17", "2026-11-05T17"].map { utc($0 + ":30:00Z") }
        #expect(results[0].occurrences.compactMap(\.start.date) == daily)
        #expect(results[1].occurrences.compactMap(\.start.date) == [daily[0]] + daily.suffix(4))
        // 2015-01-08 to 2026-10-29 is 616 weeks, an even number.
        #expect(results[2].occurrences.compactMap(\.start.date) == [utc("2026-10-29T18:00:00Z"), utc("2026-11-12T19:00:00Z")])
        #expect(results[3].occurrences.compactMap(\.start.date) == [utc("2026-11-11T02:00:00Z")])
        // Rules start a period or two before the window, not in 2015 (about 4,300 dates for the daily one).
        #expect(results.allSatisfy { $0.steps < 40 }, "\(results.map(\.steps))")
        #expect(try expand("RRULE:FREQ=DAILY", first: at(2015, 1, 5, 9, 30), from: at(2026, 10, 30), to: at(2026, 11, 6), skipsAhead: false).steps > 4000)
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
    }

    /// RFC 5545's example: changing only WKST changes which weeks count.
    @Test func weekStartDecidesTheWeeksOfAnIntervalRule() {
        let newYork = "America/New_York"
        func august(_ weekStart: String) -> [Date]? {
            starts(["RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=" + weekStart], first: at(1997, 8, 5, 9, zone: newYork), zone: newYork, from: at(1997, 8, 1), to: at(1997, 10, 1))
        }
        #expect(august("MO") == [5, 10, 19, 24].map { utc(String(format: "1997-08-%02dT13:00:00Z", $0)) })
        #expect(august("SU") == [5, 17, 19, 31].map { utc(String(format: "1997-08-%02dT13:00:00Z", $0)) })

        func sundaysAndMondays(_ weekStart: String?) -> [DayDate]? {
            let rule = "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO" + (weekStart.map { ";WKST=" + $0 } ?? "")
            return starts([rule], first: at(2026, 11, 2, 10), from: at(2026, 11, 1), to: at(2026, 12, 7))?.map { DayDate($0, in: la) }
        }
        let mondayWeeks = ["2026-11-02", "2026-11-08", "2026-11-16", "2026-11-22", "2026-11-30", "2026-12-06"].map(day)
        #expect(sundaysAndMondays("MO") == mondayWeeks)
        #expect(sundaysAndMondays(nil) == mondayWeeks)
        #expect(sundaysAndMondays("SU") == ["2026-11-02", "2026-11-15", "2026-11-16", "2026-11-29", "2026-11-30"].map(day))
    }

    @Test func timesSkippedByDaylightTimeMoveForward() {
        // 02:30 does not exist on 2027-03-14 in Los Angeles; that occurrence is at 03:30 PDT, the same instant as 02:30 PST.
        let result = starts(["RRULE:FREQ=DAILY"], first: at(2027, 3, 12, 2, 30), from: at(2027, 3, 12), to: at(2027, 3, 16))
        #expect(result == ["2027-03-12T10:30", "2027-03-13T10:30", "2027-03-14T10:30", "2027-03-15T09:30"].map { utc($0 + ":00Z") })
    }

    @Test func eventsRepeatInTheirOwnZone() throws {
        let london = "Europe/London"
        let result = starts(["RRULE:FREQ=WEEKLY"], first: at(2026, 10, 20, 9, zone: london), zone: london, from: at(2026, 10, 1), to: at(2026, 10, 28))
        #expect(result == [utc("2026-10-20T08:00:00Z"), utc("2026-10-27T09:00:00Z")])
        // Without a zone the series repeats in the caller's.
        let floating = try #require(Recurrence.occurrences(
            start: .timed(utc("2026-10-27T16:00:00Z"), timeZone: nil), end: .timed(utc("2026-10-27T17:00:00Z"), timeZone: nil),
            recurrence: ["RRULE:FREQ=WEEKLY"], from: at(2026, 10, 26), to: at(2026, 11, 4), calendar: la
        ))
        #expect(floating.map(\.start) == [.timed(utc("2026-10-27T16:00:00Z"), timeZone: nil), .timed(utc("2026-11-03T17:00:00Z"), timeZone: nil)])
    }

    /// Each end keeps the zone of the series' end (a flight that lands in another zone).
    @Test func occurrencesKeepTheZonesOfStartAndEnd() throws {
        let newYork = "America/New_York"
        let occurrences = try #require(Recurrence.occurrences(
            start: .timed(at(2026, 10, 27, 9), timeZone: laID), end: .timed(at(2026, 10, 27, 17, 30, zone: newYork), timeZone: newYork),
            recurrence: ["RRULE:FREQ=WEEKLY;COUNT=2"], from: at(2026, 10, 1), to: at(2027, 1, 1), calendar: la
        ))
        #expect(occurrences.map(\.start) == [.timed(utc("2026-10-27T16:00:00Z"), timeZone: laID), .timed(utc("2026-11-03T17:00:00Z"), timeZone: laID)])
        #expect(occurrences.map(\.end) == [.timed(utc("2026-10-27T21:30:00Z"), timeZone: newYork), .timed(utc("2026-11-03T22:30:00Z"), timeZone: newYork)])
    }

    @Test func windowEdges() {
        let first = at(2026, 10, 27, 9)
        // Ends exactly when the window starts, starts exactly when it ends: neither overlaps.
        #expect(starts(["RRULE:FREQ=DAILY"], first: first, from: at(2026, 10, 28, 10), to: at(2026, 10, 29, 9)) == [])
        #expect(starts(["RRULE:FREQ=DAILY"], first: first, from: at(2026, 10, 28, 9, 59), to: at(2026, 10, 28, 10)) == [at(2026, 10, 28, 9)])
        #expect(starts(["RRULE:FREQ=DAILY"], first: first, from: at(2026, 10, 1), to: at(2026, 10, 27, 9)) == [])
        #expect(starts(["RRULE:FREQ=DAILY"], first: first, from: at(2026, 11, 2), to: at(2026, 11, 1)) == [])
        #expect(starts([], first: first, from: at(2026, 10, 1), to: at(2026, 11, 1)) == [first])
    }

    @Test func rulesThatNeverMatchOrWouldTrapFoundationEndQuickly() {
        // February 30, and a 31st in an interval that only lands on February: the first occurrence alone.
        #expect(starts(["RRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30"], first: at(2026, 1, 30, 9), from: at(2026, 1, 1), to: at(2036, 1, 1)) == [at(2026, 1, 30, 9)])
        #expect(starts(["RRULE:FREQ=MONTHLY;INTERVAL=12;BYMONTHDAY=31"], first: at(2026, 2, 1, 9), from: at(2026, 1, 1), to: at(2036, 1, 1)) == [at(2026, 2, 1, 9)])
        // Foundation spins for a minute and traps on "-5MO"; months with five Mondays have one here.
        let fifthLast = starts(["RRULE:FREQ=MONTHLY;BYDAY=-5MO"], first: at(2026, 3, 2, 9), from: at(2026, 1, 1), to: at(2027, 1, 1))
        #expect(fifthLast?.map { DayDate($0, in: la) } == ["2026-03-02", "2026-06-01", "2026-08-03", "2026-11-02"].map(day))
    }

    @Test func tooManyStepsForAWindowIsLeftToTheProvider() {
        func expand(_ line: String, first: Date, from: Date, to: Date) -> Recurrence.Expansion? {
            Recurrence.expansion(
                start: .timed(first, timeZone: laID), end: .timed(first.addingTimeInterval(3600), timeZone: laID),
                recurrence: [line], from: from, to: to, calendar: la, stepLimit: 100
            )
        }
        #expect(Recurrence.stepLimit == 20_000)
        // COUNT is counted from the first occurrence: 150 days to reach the window, past a limit of 100.
        #expect(Recurrence.isExpandableLocally(["RRULE:FREQ=DAILY;COUNT=400"]))
        #expect(expand("RRULE:FREQ=DAILY;COUNT=400", first: at(2026, 1, 1, 9), from: at(2026, 6, 1), to: at(2026, 6, 8)) == nil)
        #expect(expand("RRULE:FREQ=DAILY;COUNT=400", first: at(2026, 1, 1, 9), from: at(2026, 3, 1), to: at(2026, 3, 8))?.occurrences.count == 7)
        // Without COUNT the rule starts near the window, but a window that is too long still stops.
        #expect(expand("RRULE:FREQ=DAILY", first: at(2015, 1, 1, 9), from: at(2026, 6, 1), to: at(2026, 6, 8))?.occurrences.count == 7)
        #expect(expand("RRULE:FREQ=DAILY", first: at(2015, 1, 1, 9), from: at(2026, 1, 1), to: at(2027, 1, 1)) == nil)
    }

    static let unsupported: [[String]] = [
        ["RRULE:FREQ=MONTHLY;BYDAY=TU"],
        ["RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"],
        ["RRULE:FREQ=MONTHLY;BYDAY=2TU;BYSETPOS=1"],
        ["RRULE:FREQ=MONTHLY;BYDAY=6MO"],
        ["RRULE:FREQ=MONTHLY;BYMONTHDAY=13;BYDAY=FR"],
        ["RRULE:FREQ=MONTHLY;BYMONTHDAY=1;BYDAY=1MO"],
        ["RRULE:FREQ=MONTHLY;BYMONTH=1;BYMONTHDAY=1"],
        ["RRULE:FREQ=YEARLY;BYDAY=20MO"],
        ["RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=SU"],
        ["RRULE:FREQ=YEARLY;BYMONTHDAY=12"],
        ["RRULE:FREQ=YEARLY;BYYEARDAY=100"],
        ["RRULE:FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO"],
        ["RRULE:FREQ=WEEKLY;BYDAY=1MO"],
        ["RRULE:FREQ=WEEKLY;BYMONTH=1;BYDAY=MO"],
        ["RRULE:FREQ=DAILY;BYDAY=MO,TU"],
        ["RRULE:FREQ=DAILY;BYHOUR=9,17"],
        ["RRULE:FREQ=WEEKLY;BYMINUTE=0,30"],
        ["RRULE:FREQ=HOURLY"],
        ["RRULE:FREQ=MINUTELY;INTERVAL=15"],
        ["RRULE:FREQ=SECONDLY"],
        ["RRULE:FREQ=DAILY;INTERVAL=5000"],
        ["RRULE:FREQ=FORTNIGHTLY"],
        ["RRULE:FREQ=DAILY", "EXRULE:FREQ=WEEKLY;BYDAY=SA"],
        ["RRULE:FREQ=DAILY", "RDATE;VALUE=PERIOD:20261013T090000Z/20261013T100000Z"],
        ["RRULE:FREQ=DAILY", "EXDATE;TZID=Pacific Standard Time:20261013T090000"],
        ["RRULE:FREQ=DAILY", "EXDATE:2026-10-13"],
        ["RRULE:FREQ=DAILY", "X-GOOGLE-SOMETHING:1"],
        ["not a rule"],
    ]

    @Test(arguments: unsupported)
    func unsupportedShapesAreLeftToTheProvider(recurrence: [String]) {
        #expect(!Recurrence.isExpandableLocally(recurrence))
        #expect(starts(recurrence, first: at(2026, 10, 27, 9), from: at(2026, 10, 1), to: at(2026, 12, 1)) == nil)
    }

    @Test func supportedShapes() {
        let lines = [
            "RRULE:FREQ=DAILY", "RRULE:FREQ=DAILY;INTERVAL=3;COUNT=10", "FREQ=WEEKLY", "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=SU",
            "RRULE:FREQ=MONTHLY", "RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15,-1", "RRULE:FREQ=MONTHLY;INTERVAL=2;BYDAY=2TU,-1FR",
            "RRULE:FREQ=MONTHLY;BYDAY=-5MO", "RRULE:FREQ=YEARLY", "RRULE:FREQ=YEARLY;BYMONTH=1,7", "RRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29",
            "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH;UNTIL=20301231", "RRULE:FREQ=WEEKLY;UNTIL=20261218T075959Z",
            "EXDATE;TZID=America/Los_Angeles:20261013T090000,20261020T090000", "EXDATE:20261013T160000Z", "EXDATE;VALUE=DATE:20261013",
            "RDATE;TZID=\"America/Los_Angeles\":20261013T090000", "RDATE;VALUE=DATE:20261013,20261014",
        ]
        for line in lines { #expect(Recurrence.isExpandableLocally([line]), "\(line)") }
        #expect(Recurrence.isExpandableLocally([]))
    }
}

@Suite("Recurrence rules")
struct RecurrenceRuleTests {
    @Test func parsesParts() throws {
        let rule = try #require(Recurrence.parseRule("RRULE:FREQ=WEEKLY;WKST=SU;UNTIL=20261218T075959Z;BYDAY=MO,WE"))
        #expect(rule.frequency == .weekly)
        #expect(rule.byDay == [.init(weekday: .monday), .init(weekday: .wednesday)])
        #expect(rule.weekStart == .sunday)
        #expect(rule.until == .timed(utc("2026-12-18T07:59:59Z"), timeZone: "UTC"))
        let monthly = try #require(Recurrence.parseRule("freq=monthly;interval=2;byday=+2tu,-1FR;count=8"))
        #expect(monthly.interval == 2)
        #expect(monthly.count == 8)
        #expect(monthly.byDay == [.init(ordinal: 2, weekday: .tuesday), .init(ordinal: -1, weekday: .friday)])
        #expect(Recurrence.parseRule("RRULE:FREQ=DAILY;UNTIL=20261218")?.until == .allDay(day("2026-12-18")))
        #expect(Recurrence.parseRule("RRULE:FREQ=DAILY;UNTIL=20261218T170000")?.until == .timed(utc("2026-12-18T17:00:00Z"), timeZone: nil))
        #expect(Recurrence.WeekdayNumber("-1fr")?.description == "-1FR")
        #expect(Recurrence.WeekdayNumber("+3WE")?.description == "3WE")
    }

    @Test(arguments: [
        ("RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261218T075959Z", "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261218T075959Z"),
        ("FREQ=MONTHLY;BYDAY=-1FR", "RRULE:FREQ=MONTHLY;BYDAY=-1FR"),
        ("rrule:freq=yearly;bymonth=11;byday=4th", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH"),
        ("RRULE:FREQ=WEEKLY;WKST=SU;INTERVAL=2;COUNT=4;BYDAY=TU,SU", "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=SU;COUNT=4"),
        ("RRULE:FREQ=DAILY;INTERVAL=1;UNTIL=20261218", "RRULE:FREQ=DAILY;UNTIL=20261218"),
        ("RRULE:FREQ=DAILY;UNTIL=20261218T170000", "RRULE:FREQ=DAILY;UNTIL=20261218T170000"),
        ("RRULE:FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1,15,-1", "RRULE:FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1,15,-1"),
        (
            "RRULE:FREQ=YEARLY;BYSETPOS=1;BYSECOND=0;BYMINUTE=30;BYHOUR=9;BYWEEKNO=20;BYYEARDAY=-1;BYMONTHDAY=15;BYMONTH=1,7",
            "RRULE:FREQ=YEARLY;BYMONTH=1,7;BYWEEKNO=20;BYYEARDAY=-1;BYMONTHDAY=15;BYHOUR=9;BYMINUTE=30;BYSECOND=0;BYSETPOS=1"
        ),
    ])
    func lineRoundTrips(input: String, line: String) throws {
        let rule = try #require(Recurrence.parseRule(input))
        #expect(Recurrence.line(for: rule) == line)
        #expect(Recurrence.parseRule(line) == rule)
    }

    @Test func untilInAnotherZoneIsWrittenInUTC() {
        let rule = Recurrence.Rule(frequency: .weekly, until: .timed(at(2026, 12, 17, 23, 59), timeZone: laID), byDay: [.init(weekday: .monday)])
        #expect(Recurrence.line(for: rule) == "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261218T075900Z")
    }

    @Test(arguments: [
        "RRULE:FREQ=WEEKLY;BYDAY=XX", "RRULE:BYDAY=MO", "RRULE:FREQ=DAILY;INTERVAL=0", "RRULE:FREQ=DAILY;FREQ=WEEKLY",
        "RRULE:FREQ=MONTHLY;BYMONTHDAY=32", "RRULE:FREQ=MONTHLY;BYMONTHDAY=0", "RRULE:FREQ=YEARLY;BYMONTH=13",
        "RRULE:FREQ=DAILY;UNTIL=2026-12-18", "RRULE:FREQ=DAILY;UNTIL=20260231", "RRULE:FREQ=DAILY;COUNT=", "RRULE:FREQ=DAILY;COUNT=0",
        "RRULE:FREQ=DAILY;X-NAME=1", "RRULE:FREQ=WEEKLY;BYDAY=MO,,TU", "RRULE:FREQ=MONTHLY;BYDAY=0MO", "EXRULE:FREQ=DAILY", "",
    ])
    func rejectsInvalidRules(line: String) {
        #expect(Recurrence.parseRule(line) == nil)
    }
}

@Suite("Recurrence summaries")
struct RecurrenceSummaryTests {
    let monday = EventTime.timed(at(2026, 11, 2, 10), timeZone: laID)

    func summary(_ line: String, _ start: EventTime) -> String? {
        Recurrence.summary([line], start: start, calendar: la)
    }

    @Test func describesCommonRules() {
        let twelfth = EventTime.timed(at(2026, 10, 12, 9), timeZone: laID)
        #expect(summary("RRULE:FREQ=DAILY", monday) == "Daily")
        #expect(summary("RRULE:FREQ=DAILY;INTERVAL=2", monday) == "Every 2 days")
        #expect(summary("RRULE:FREQ=WEEKLY", monday) == "Weekly on Mon")
        #expect(summary("RRULE:FREQ=WEEKLY;BYDAY=WE,MO", monday) == "Weekly on Mon, Wed")
        #expect(summary("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", monday) == "Every weekday")
        #expect(summary("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU", monday) == "Every 2 weeks on Tue")
        #expect(summary("RRULE:FREQ=MONTHLY", twelfth) == "Monthly on day 12")
        #expect(summary("RRULE:FREQ=MONTHLY;BYMONTHDAY=12", twelfth) == "Monthly on day 12")
        #expect(summary("RRULE:FREQ=MONTHLY;BYDAY=2TU", twelfth) == "Monthly on the 2nd Tue")
        #expect(summary("RRULE:FREQ=MONTHLY;BYDAY=-1FR", twelfth) == "Monthly on the last Fri")
        #expect(summary("RRULE:FREQ=YEARLY", .allDay(day("2026-11-26"))) == "Yearly on Nov 26")
        #expect(summary("RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH", .allDay(day("2026-11-26"))) == "Yearly on the 4th Thu of Nov")
        #expect(summary("RRULE:FREQ=MONTHLY;BYMONTHDAY=-1", twelfth) == "Monthly on the last day")
        #expect(summary("RRULE:FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=15,1", twelfth) == "Every 3 months on days 1, 15")
        #expect(summary("RRULE:FREQ=YEARLY;INTERVAL=2", twelfth) == "Every 2 years on Oct 12")
    }

    @Test func endings() {
        let tuesday = EventTime.timed(at(2026, 10, 27, 9), timeZone: laID)
        #expect(summary("RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261219T075959Z", tuesday) == "Weekly on Tue, until Dec 18")
        // Google ends a series on Dec 17 in Los Angeles with the last second of that day in UTC.
        #expect(summary("RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261218T075959Z", tuesday) == "Weekly on Tue, until Dec 17")
        #expect(summary("RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20271218", tuesday) == "Weekly on Tue, until Dec 18, 2027")
        #expect(summary("RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261218T170000", tuesday) == "Weekly on Tue, until Dec 18")
        #expect(summary("RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=8", tuesday) == "Weekly on Tue, 8 times")
        #expect(summary("RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=1", tuesday) == "Weekly on Tue, once")
    }

    @Test func describesTheExpansionExamples() {
        #expect(summary("RRULE:FREQ=WEEKLY;BYDAY=TU", .timed(at(2026, 10, 27, 9), timeZone: laID)) == "Weekly on Tue")
        #expect(summary("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE", monday) == "Every 2 weeks on Mon, Wed")
        #expect(summary("RRULE:FREQ=MONTHLY;BYDAY=-1FR", .timed(at(2026, 10, 30, 12), timeZone: laID)) == "Monthly on the last Fri")
        #expect(summary("RRULE:FREQ=MONTHLY;BYMONTHDAY=31", .timed(at(2026, 1, 31, 9), timeZone: laID)) == "Monthly on day 31")
        #expect(summary("RRULE:FREQ=DAILY;COUNT=5", .timed(at(2026, 10, 1, 9), timeZone: laID)) == "Daily, 5 times")
        #expect(summary("RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261110T170000Z", .timed(at(2026, 10, 27, 9), timeZone: laID)) == "Weekly on Tue, until Nov 10")
        #expect(summary("RRULE:FREQ=YEARLY", .allDay(day("2024-02-29"))) == "Yearly on Feb 29")
        #expect(summary("RRULE:FREQ=WEEKLY", .allDay(day("2026-10-30"))) == "Weekly on Fri")
        #expect(summary("RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU", .timed(at(1997, 8, 5, 9), timeZone: "America/New_York")) == "Every 2 weeks on Tue, Sun, 4 times")
        #expect(summary("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO", monday) == "Every 2 weeks on Mon, Sun")
    }

    @Test func nilWhenThereIsNothingSimpleToSay() {
        #expect(Recurrence.summary([], start: monday, calendar: la) == nil)
        #expect(Recurrence.summary(["EXDATE:20261013T160000Z"], start: monday, calendar: la) == nil)
        #expect(Recurrence.summary(["RRULE:FREQ=DAILY", "RRULE:FREQ=WEEKLY"], start: monday, calendar: la) == nil)
        #expect(summary("RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", monday) == nil)
        #expect(summary("RRULE:FREQ=HOURLY", monday) == nil)
        #expect(summary("RRULE:FREQ=YEARLY;BYMONTH=1,7", monday) == nil)
    }
}

// MARK: - Against a day-by-day reference

private let weekdayOrder: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]

/// RFC 5545 by brute force: walks every day after the first occurrence and checks it against the rule as the RFC words
/// it. Shares nothing with the library or Foundation's RecurrenceRule. The first occurrence always counts; no UNTIL.
/// `end` is a midnight in `zone`.
private func referenceStarts(_ rule: Recurrence.Rule, first: Date, zone: String, before end: Date) -> [Date] {
    let calendar = calendar(zone)
    let start = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: first)
    let last = calendar.dateComponents([.year, .month, .day], from: end)
    func number(_ weekday: Locale.Weekday) -> Int { weekdayOrder.firstIndex(of: weekday)! + 1 }
    func lengthOf(_ year: Int, _ month: Int) -> Int {
        calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month))!)!.count
    }
    let weekStart = number(rule.weekStart ?? .monday)
    var (year, month, day, weekday) = (start.year!, start.month!, start.day!, start.weekday!)
    var length = lengthOf(year, month)
    func onRequestedDay() -> Bool {
        if rule.byDay.isEmpty {
            let wanted = rule.byMonthDay.isEmpty ? [start.day!] : rule.byMonthDay
            return wanted.contains { $0 > 0 ? $0 == day : length + 1 + $0 == day }
        }
        return rule.byDay.contains { item in
            guard number(item.weekday) == weekday, let ordinal = item.ordinal else { return false }
            let sameWeekday = Array(stride(from: (day - 1) % 7 + 1, through: length, by: 7))
            let index = ordinal > 0 ? ordinal - 1 : sameWeekday.count + ordinal
            return sameWeekday.indices.contains(index) && sameWeekday[index] == day
        }
    }
    var results = [first]
    var offset = 0
    while rule.count.map({ results.count < $0 }) ?? true {
        offset += 1
        day += 1
        weekday = weekday % 7 + 1
        if day > length {
            (day, month) = (1, month + 1)
            if month > 12 { (month, year) = (1, year + 1) }
            length = lengthOf(year, month)
        }
        if (year, month, day) >= (last.year!, last.month!, last.day!) { break }
        let matches: Bool
        switch rule.frequency {
        case .daily:
            matches = offset % rule.interval == 0
        case .weekly:
            let wanted = rule.byDay.isEmpty ? [start.weekday!] : rule.byDay.map { number($0.weekday) }
            let week = (offset - (weekday - weekStart + 7) % 7 + (start.weekday! - weekStart + 7) % 7) / 7
            matches = wanted.contains(weekday) && week % rule.interval == 0
        case .monthly:
            matches = ((year - start.year!) * 12 + month - start.month!) % rule.interval == 0 && onRequestedDay()
        case .yearly:
            let months = rule.byMonth.isEmpty ? [start.month!] : rule.byMonth
            matches = (year - start.year!) % rule.interval == 0 && months.contains(month) && onRequestedDay()
        default:
            matches = false
        }
        if matches {
            results.append(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: start.hour, minute: start.minute))!)
        }
    }
    return results
}

/// Serialized: Foundation's Calendar takes a lock, so parallel cases mostly wait on each other.
@Suite("Recurrence against a day-by-day reference", .serialized)
struct RecurrenceReferenceTests {
    /// Expands `line` from `first` through `end` both ways, timed in Los Angeles and (from the same date) all-day.
    func check(_ line: String, first: Date, through end: Date, allDay: Bool = true) {
        guard let rule = Recurrence.parseRule(line) else {
            Issue.record("\(line) does not parse")
            return
        }
        let expected = referenceStarts(rule, first: first, zone: laID, before: end)
        #expect(starts([line], first: first, from: first, to: end) == expected, "\(line) from \(first)")
        guard allDay else { return }
        let firstDay = DayDate(first, in: la)
        let utcFirst = firstDay.start(in: calendar("UTC"))
        let expectedDays = referenceStarts(rule, first: utcFirst, zone: "UTC", before: DayDate(end, in: la).start(in: calendar("UTC"))).map { DayDate($0, in: calendar("UTC")) }
        #expect(days([line], first: firstDay, from: firstDay.start(in: la), to: end) == expectedDays, "all-day \(line) from \(firstDay)")
    }

    @Test(arguments: weekdayOrder)
    func numberedWeekdaysInMonths(weekday: Locale.Weekday) {
        let code = Recurrence.code(of: weekday)
        // 30 months meet every weekday on the 1st of 30- and 31-day months, and a leap February.
        for ordinal in [1, 2, 3, 4, 5, -1, -2, -3, -4, -5] {
            check("RRULE:FREQ=MONTHLY;BYDAY=\(ordinal)\(code)", first: at(2026, 1, 1, 9), through: at(2028, 7, 1), allDay: [1, 5, -1, -5].contains(ordinal))
        }
        check("RRULE:FREQ=MONTHLY;INTERVAL=2;BYDAY=2\(code),-1\(code)", first: at(2026, 1, 13, 9), through: at(2029, 1, 1), allDay: false)
        check("RRULE:FREQ=MONTHLY;BYDAY=1\(code),3\(code);WKST=TH", first: at(2026, 1, 1, 9), through: at(2028, 7, 1))
    }

    @Test(arguments: weekdayOrder)
    func numberedWeekdaysInMonthsOfTheYear(weekday: Locale.Weekday) {
        let code = Recurrence.code(of: weekday)
        for ordinal in [1, 2, 4, 5, -1, -5] {
            for months in ["2", "1,5,9"] {
                check("RRULE:FREQ=YEARLY;BYMONTH=\(months);BYDAY=\(ordinal)\(code)", first: at(2026, 1, 1, 9), through: at(2034, 1, 1), allDay: months == "2")
            }
            check("RRULE:FREQ=YEARLY;INTERVAL=3;BYMONTH=2;BYDAY=\(ordinal)\(code)", first: at(2024, 2, 29, 9), through: at(2040, 1, 1), allDay: false)
        }
    }

    @Test(arguments: Array(1...31) + Array(-31 ... -1))
    func dayOfTheMonth(day: Int) {
        check("RRULE:FREQ=MONTHLY;BYMONTHDAY=\(day)", first: at(2026, 1, 1, 9), through: at(2029, 1, 1))
        check("RRULE:FREQ=MONTHLY;INTERVAL=5;BYMONTHDAY=\(day),15", first: at(2026, 2, 15, 9), through: at(2030, 1, 1), allDay: false)
    }

    @Test(arguments: [at(2026, 1, 1, 9), at(2026, 1, 29, 9), at(2026, 1, 30, 9), at(2026, 1, 31, 9), at(2026, 2, 28, 9), at(2024, 2, 29, 9), at(2026, 12, 31, 23, 30)])
    func monthlyAndYearlyOnTheirStartDate(first: Date) {
        check("RRULE:FREQ=MONTHLY", first: first, through: at(2030, 1, 1))
        check("RRULE:FREQ=MONTHLY;INTERVAL=7", first: first, through: at(2036, 1, 1))
        check("RRULE:FREQ=YEARLY", first: first, through: at(2041, 1, 1))
        check("RRULE:FREQ=YEARLY;INTERVAL=4", first: first, through: at(2050, 1, 1), allDay: false)
        check("RRULE:FREQ=YEARLY;BYMONTH=1,3,8", first: first, through: at(2036, 1, 1))
    }

    @Test(arguments: ["2", "4", "1,7", "2,4,6,9,11", "12"])
    func daysOfMonthsOfTheYear(months: String) {
        for days in ["29", "30", "31", "-1", "-29", "-31", "1,15", "28,29"] {
            for interval in [1, 4] {
                check("RRULE:FREQ=YEARLY;INTERVAL=\(interval);BYMONTH=\(months);BYMONTHDAY=\(days)", first: at(2024, 1, 1, 9), through: at(2033, 1, 1))
            }
        }
    }

    @Test(arguments: ["", ";WKST=SU", ";WKST=WE"])
    func weeklyDaysAndIntervals(weekStart: String) {
        let codes = Recurrence.weekdayCodes
        let sets = codes.map { [$0] } + [["MO", "WE"], ["SU", "MO"], ["SA", "SU"], ["TU", "SU"], ["MO", "TU", "WE", "TH", "FR"], ["SU", "TU", "TH", "SA"], codes]
        for days in sets {
            for interval in [1, 2, 3] {
                for start in [at(2026, 10, 5, 9), at(2026, 10, 11, 9)] {
                    check("RRULE:FREQ=WEEKLY;INTERVAL=\(interval);BYDAY=\(days.joined(separator: ","))" + weekStart, first: start, through: at(2027, 3, 1), allDay: interval == 2)
                }
            }
        }
        check("RRULE:FREQ=WEEKLY;INTERVAL=2" + weekStart, first: at(2026, 10, 8, 9), through: at(2027, 5, 1))
    }

    @Test func dailyIntervalsAndCounts() {
        for interval in 1...9 {
            check("RRULE:FREQ=DAILY;INTERVAL=\(interval)", first: at(2026, 10, 5, 9), through: at(2027, 6, 1))
            check("RRULE:FREQ=DAILY;INTERVAL=\(interval);COUNT=\(interval * 3)", first: at(2026, 10, 5, 23, 45), through: at(2027, 6, 1))
        }
        check("RRULE:FREQ=WEEKLY;BYDAY=MO,TH;COUNT=13", first: at(2026, 10, 7, 9), through: at(2027, 6, 1))
        check("RRULE:FREQ=MONTHLY;BYDAY=-1SU;COUNT=7", first: at(2026, 10, 1, 9), through: at(2028, 6, 1))
    }
}

@Suite("Recurrence skipping ahead", .serialized)
struct RecurrenceSkipAheadTests {
    static let rules = [
        "RRULE:FREQ=DAILY", "RRULE:FREQ=DAILY;INTERVAL=3", "RRULE:FREQ=WEEKLY", "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO,FR",
        "RRULE:FREQ=WEEKLY;INTERVAL=3;BYDAY=TU,SA;WKST=SU", "RRULE:FREQ=MONTHLY", "RRULE:FREQ=MONTHLY;BYMONTHDAY=31",
        "RRULE:FREQ=MONTHLY;INTERVAL=5;BYMONTHDAY=-1,1", "RRULE:FREQ=MONTHLY;BYDAY=2TU,-1FR", "RRULE:FREQ=MONTHLY;INTERVAL=2;BYDAY=5FR",
        "RRULE:FREQ=YEARLY", "RRULE:FREQ=YEARLY;INTERVAL=2;BYMONTH=2;BYMONTHDAY=29", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH",
        "RRULE:FREQ=YEARLY;INTERVAL=3;BYMONTH=3,10;BYDAY=-1SU", "RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261115T000000Z",
    ]

    /// Rules without COUNT start near the window; that must give exactly what walking from the first occurrence gives.
    @Test(arguments: rules)
    func skippingAheadMatchesWalkingFromTheStart(line: String) {
        let sydney = "Australia/Sydney"
        let series: [(EventTime, EventTime)] = [
            (.timed(at(2025, 3, 9, 9), timeZone: laID), .timed(at(2025, 3, 9, 10), timeZone: laID)),
            (.timed(at(2025, 3, 8, 2, 30), timeZone: laID), .timed(at(2025, 3, 8, 3), timeZone: laID)),
            (.timed(at(2024, 2, 29, 23, 30), timeZone: laID), .timed(at(2024, 3, 1, 1, 30), timeZone: laID)),
            (.timed(at(2025, 1, 31, 18, zone: sydney), timeZone: sydney), .timed(at(2025, 1, 31, 19, zone: sydney), timeZone: sydney)),
            (.allDay(day("2024-02-29")), .allDay(day("2024-03-03"))),
        ]
        // Across the end of daylight time, a year, and the start of daylight time (02:30 does not exist on 2027-03-14).
        let windows = [(at(2026, 10, 28), at(2026, 11, 4)), (at(2026, 1, 1), at(2027, 1, 1)), (at(2027, 3, 16), at(2027, 3, 20))]
        let recurrence = [line, "EXDATE;VALUE=DATE:20261103"]
        for (start, end) in series {
            for (from, to) in windows {
                let fast = Recurrence.expansion(start: start, end: end, recurrence: recurrence, from: from, to: to, calendar: la, skipsAhead: true)
                let slow = Recurrence.expansion(start: start, end: end, recurrence: recurrence, from: from, to: to, calendar: la, skipsAhead: false)
                #expect(fast != nil)
                #expect(fast?.occurrences == slow?.occurrences, "\(line) \(start) \(from)..<\(to)")
            }
        }
    }
}

@Suite("Recurrence limits")
struct RecurrenceLimitTests {
    @Test func manyRulesAreLeftToTheProvider() {
        let rule = "RRULE:FREQ=MONTHLY;BYDAY=1MO,2MO,3MO,4MO,-1MO,1TU,2TU,3TU,4TU,-1TU"
        let lines = Array(repeating: rule, count: 400)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(Recurrence.occurrences(
                start: .timed(at(2026, 10, 12, 10), timeZone: laID), end: .timed(at(2026, 10, 12, 11), timeZone: laID), recurrence: lines,
                from: at(2026, 10, 1), to: at(2027, 11, 1), calendar: la
            ) == nil)
        }
        #expect(elapsed < .seconds(1))
        #expect(!Recurrence.isExpandableLocally(lines))
        #expect(Recurrence.isExpandableLocally([rule, "RRULE:FREQ=WEEKLY;BYDAY=FR"]))
    }
}

@Suite("Recurrence edits")
struct RecurrenceEditTests {
    @Test func allEventsTakeTheOccurrencesNewTimeOnTheirOwnDays() {
        // Tuesdays from Jan 12 2027 10:00 (winter time); the Oct 12 occurrence (summer time) moves to 11:30-12:15.
        let moved = Recurrence.seriesTimes(
            seriesStart: .timed(at(2027, 1, 12, 10), timeZone: laID), occurrenceStart: .timed(at(2027, 10, 12, 10), timeZone: laID),
            newStart: .timed(at(2027, 10, 12, 11, 30), timeZone: laID), newEnd: .timed(at(2027, 10, 12, 12, 15), timeZone: laID), calendar: la
        )
        #expect(moved?.start == .timed(at(2027, 1, 12, 11, 30), timeZone: laID))
        #expect(moved?.end == .timed(at(2027, 1, 12, 12, 15), timeZone: laID))
    }

    @Test func allEventsKeepTheirDays() {
        let moved = Recurrence.seriesTimes(
            seriesStart: .timed(at(2027, 1, 12, 10), timeZone: laID), occurrenceStart: .timed(at(2027, 10, 12, 10), timeZone: laID),
            newStart: .timed(at(2027, 10, 13, 10), timeZone: laID), newEnd: .timed(at(2027, 10, 13, 11), timeZone: laID), calendar: la
        )
        #expect(moved == nil)
    }

    @Test func aSeriesKeepsItsTimeZone() {
        // A New York series seen from Los Angeles: 07:00 here moves to 08:00 here, which is 11:00 in New York.
        let moved = Recurrence.seriesTimes(
            seriesStart: .timed(at(2027, 1, 12, 10, zone: "America/New_York"), timeZone: "America/New_York"),
            occurrenceStart: .timed(at(2027, 3, 2, 10, zone: "America/New_York"), timeZone: "America/New_York"),
            newStart: .timed(at(2027, 3, 2, 8), timeZone: laID), newEnd: .timed(at(2027, 3, 2, 9), timeZone: laID), calendar: la
        )
        #expect(moved?.start == .timed(at(2027, 1, 12, 11, zone: "America/New_York"), timeZone: "America/New_York"))
        #expect(moved?.end == .timed(at(2027, 1, 12, 12, zone: "America/New_York"), timeZone: "America/New_York"))
    }

    @Test func aSeriesInAnotherZoneMovesByWhatWasTyped() {
        // Seen from Los Angeles, a Phoenix series (no daylight saving) at 09:00: one hour later on its Jun 7 occurrence
        // is 10:00 in Phoenix every week, not 11:00.
        let phoenix = "America/Phoenix"
        let moved = Recurrence.seriesTimes(
            seriesStart: .timed(at(2027, 1, 4, 9, zone: phoenix), timeZone: phoenix), occurrenceStart: .timed(at(2027, 6, 7, 9, zone: phoenix), timeZone: phoenix),
            newStart: .timed(at(2027, 6, 7, 10), timeZone: laID), newEnd: .timed(at(2027, 6, 7, 11), timeZone: laID), calendar: la
        )
        #expect(moved?.start == .timed(at(2027, 1, 4, 10, zone: phoenix), timeZone: phoenix))
        #expect(moved?.end == .timed(at(2027, 1, 4, 11, zone: phoenix), timeZone: phoenix))
        // From London in March, when Los Angeles has changed its clocks and London has not: 18:00 there is 11:00 here.
        let london = calendar("Europe/London")
        let later = Recurrence.seriesTimes(
            seriesStart: .timed(at(2027, 1, 5, 10), timeZone: laID), occurrenceStart: .timed(at(2027, 3, 16, 10), timeZone: laID),
            newStart: .timed(at(2027, 3, 16, 18, zone: "Europe/London"), timeZone: "Europe/London"),
            newEnd: .timed(at(2027, 3, 16, 19, zone: "Europe/London"), timeZone: "Europe/London"), calendar: london
        )
        #expect(later?.start == .timed(at(2027, 1, 5, 11), timeZone: laID))
    }

    @Test func otherCalendarSystemsStillCountGregorianDays() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        #expect(DayDate(year: 2026, month: 10, day: 16).adding(days: 1, in: buddhist) == DayDate(year: 2026, month: 10, day: 17))
        #expect(DayDate(year: 2027, month: 2, day: 28).adding(days: 1, in: buddhist) == DayDate(year: 2027, month: 3, day: 1))
        #expect(DayDate(DayDate(year: 2026, month: 10, day: 16).start(in: buddhist), in: buddhist) == DayDate(year: 2026, month: 10, day: 16))
        let tuesday = Recurrence.aligned(
            start: .allDay(day("2026-10-16")), end: .allDay(day("2026-10-17")), recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=TU"], calendar: buddhist
        )
        #expect(tuesday.start == .allDay(day("2026-10-20")))
        let days = Recurrence.occurrences(
            start: .allDay(day("2026-10-20")), end: .allDay(day("2026-10-21")), recurrence: ["RRULE:FREQ=WEEKLY"],
            from: DayDate(year: 2026, month: 10, day: 19).start(in: buddhist), to: DayDate(year: 2026, month: 11, day: 1).start(in: buddhist), calendar: buddhist
        )?.map(\.start)
        #expect(days == [.allDay(day("2026-10-20")), .allDay(day("2026-10-27"))])
    }

    @Test func anAllDaySeriesCanBecomeTimed() {
        let moved = Recurrence.seriesTimes(
            seriesStart: .allDay(day("2027-01-12")), occurrenceStart: .allDay(day("2027-03-02")),
            newStart: .timed(at(2027, 3, 2, 9), timeZone: laID), newEnd: .timed(at(2027, 3, 2, 9, 30), timeZone: laID), calendar: la
        )
        #expect(moved?.start == .timed(at(2027, 1, 12, 9), timeZone: laID))
        #expect(moved?.end == .timed(at(2027, 1, 12, 9, 30), timeZone: laID))
        let allDay = Recurrence.seriesTimes(
            seriesStart: .timed(at(2027, 1, 12, 9), timeZone: laID), occurrenceStart: .timed(at(2027, 3, 2, 9), timeZone: laID),
            newStart: .allDay(day("2027-03-02")), newEnd: .allDay(day("2027-03-03")), calendar: la
        )
        #expect(allDay?.start == .allDay(day("2027-01-12")))
        #expect(allDay?.end == .allDay(day("2027-01-13")))
    }

    @Test func weeklyRulesStartOnADayTheyName() {
        // Friday Oct 16 2026, "every thu": the first event is Thursday Oct 22.
        let friday = (EventTime.timed(at(2026, 10, 16, 10), timeZone: laID), EventTime.timed(at(2026, 10, 16, 11), timeZone: laID))
        let thursday = Recurrence.aligned(start: friday.0, end: friday.1, recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=TH"], calendar: la)
        #expect(thursday.start == .timed(at(2026, 10, 22, 10), timeZone: laID))
        #expect(thursday.end == .timed(at(2026, 10, 22, 11), timeZone: laID))
        let named = Recurrence.aligned(start: friday.0, end: friday.1, recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO,FR"], calendar: la)
        #expect(named.start == friday.0)
        let daily = Recurrence.aligned(start: friday.0, end: friday.1, recurrence: ["RRULE:FREQ=DAILY"], calendar: la)
        #expect(daily.start == friday.0)
        let plain = Recurrence.aligned(start: friday.0, end: friday.1, recurrence: ["RRULE:FREQ=WEEKLY"], calendar: la)
        #expect(plain.start == friday.0)
        let allDay = Recurrence.aligned(
            start: .allDay(day("2026-10-16")), end: .allDay(day("2026-10-17")), recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO"], calendar: la
        )
        #expect(allDay.start == .allDay(day("2026-10-19")) && allDay.end == .allDay(day("2026-10-20")))
        // Weekdays count in the event's zone: 23:00 Thursday in Los Angeles is Friday in London.
        let london = Recurrence.aligned(
            start: .timed(at(2026, 10, 15, 23), timeZone: "Europe/London"), end: .timed(at(2026, 10, 16, 0), timeZone: "Europe/London"),
            recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=FR"], calendar: la
        )
        #expect(london.start == .timed(at(2026, 10, 15, 23), timeZone: "Europe/London"))
    }
}

@Suite("Recurrence splits")
struct RecurrenceSplitTests {
    /// The old series' lines and the new one's, when the series is cut in two.
    func split(_ recurrence: [String], first: EventTime, at: EventTime) -> (before: [String], after: [String])? {
        guard case .split(let before, let after)? = Recurrence.split(recurrence: recurrence, seriesStart: first, at: at, calendar: la) else { return nil }
        return (before, after)
    }

    @Test func aTimedSeriesEndsTheSecondBeforeTheDay() throws {
        // Tuesdays at 09:00 from Oct 6, cut at Oct 20: 09:00 is 16:00 UTC in daylight time.
        let first = at(2026, 10, 6, 9)
        let parts = try #require(split(["RRULE:FREQ=WEEKLY;BYDAY=TU"], first: .timed(first, timeZone: laID), at: .timed(at(2026, 10, 20, 9), timeZone: laID)))
        #expect(parts.before == ["RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261020T155959Z"])
        #expect(parts.after == ["RRULE:FREQ=WEEKLY;BYDAY=TU"])
        #expect(starts(parts.before, first: first, from: at(2026, 10, 1), to: at(2027, 1, 1)) == [utc("2026-10-06T16:00:00Z"), utc("2026-10-13T16:00:00Z")])
        #expect(starts(parts.after, first: at(2026, 10, 20, 9), from: at(2026, 10, 1), to: at(2026, 11, 1)) == [utc("2026-10-20T16:00:00Z"), utc("2026-10-27T16:00:00Z")])
    }

    @Test func anAllDaySeriesEndsTheDayBefore() throws {
        let parts = try #require(split(["RRULE:FREQ=WEEKLY"], first: .allDay(day("2026-10-02")), at: .allDay(day("2026-10-23"))))
        #expect(parts.before == ["RRULE:FREQ=WEEKLY;UNTIL=20261022"])
        #expect(parts.after == ["RRULE:FREQ=WEEKLY"])
        #expect(days(parts.before, first: day("2026-10-02"), from: at(2026, 10, 1), to: at(2027, 1, 1)) == ["2026-10-02", "2026-10-09", "2026-10-16"].map(day))
        #expect(days(parts.after, first: day("2026-10-23"), from: at(2026, 10, 1), to: at(2026, 11, 7)) == ["2026-10-23", "2026-10-30", "2026-11-06"].map(day))
        // A whole-day exception list moves by date.
        let skipped = try #require(split(
            ["RRULE:FREQ=DAILY;COUNT=10", "EXDATE;VALUE=DATE:20261003,20261008"], first: .allDay(day("2026-10-01")), at: .allDay(day("2026-10-05"))
        ))
        #expect(skipped.before == ["RRULE:FREQ=DAILY;UNTIL=20261004", "EXDATE;VALUE=DATE:20261003"])
        #expect(skipped.after == ["RRULE:FREQ=DAILY;COUNT=6", "EXDATE;VALUE=DATE:20261008"])
    }

    @Test func countIsSharedBetweenTheTwoSeries() throws {
        // Ten days from Oct 1; Oct 2 is skipped but still counts. Cut at Oct 4: three before, seven from then on.
        let rules = ["RRULE:FREQ=DAILY;COUNT=10", "EXDATE;TZID=America/Los_Angeles:20261002T090000"]
        let first = at(2026, 10, 1, 9)
        let parts = try #require(split(rules, first: .timed(first, timeZone: laID), at: .timed(at(2026, 10, 4, 9), timeZone: laID)))
        #expect(parts.before == ["RRULE:FREQ=DAILY;UNTIL=20261004T155959Z", "EXDATE;TZID=America/Los_Angeles:20261002T090000"])
        #expect(parts.after == ["RRULE:FREQ=DAILY;COUNT=7"])
        let old = starts(parts.before, first: first, from: at(2026, 9, 1), to: at(2027, 1, 1))?.map { DayDate($0, in: la) }
        let new = starts(parts.after, first: at(2026, 10, 4, 9), from: at(2026, 9, 1), to: at(2027, 1, 1))?.map { DayDate($0, in: la) }
        #expect(old == ["2026-10-01", "2026-10-03"].map(day))
        #expect(new == (4...10).map { day(String(format: "2026-10-%02d", $0)) })
        #expect(old.map { $0 + (new ?? []) } == starts(rules, first: first, from: at(2026, 9, 1), to: at(2027, 1, 1))?.map { DayDate($0, in: la) })
    }

    @Test func untilStaysAsItWas() throws {
        let line = "RRULE:FREQ=WEEKLY;WKST=SU;BYDAY=MO,WE;UNTIL=20261218T075959Z"
        let parts = try #require(split([line], first: .timed(at(2026, 10, 5, 10), timeZone: laID), at: .timed(at(2026, 11, 4, 10), timeZone: laID)))
        #expect(parts.after == [line])
        // Nov 4 is after the clocks went back: 10:00 is 18:00 UTC.
        #expect(parts.before == ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;WKST=SU;UNTIL=20261104T175959Z"])
    }

    @Test func skippedAndAddedDaysGoWithTheirSide() throws {
        let rules = [
            "RRULE:FREQ=WEEKLY;BYDAY=TU",
            "EXDATE;TZID=America/Los_Angeles:20261013T090000,20261027T090000",
            "EXDATE;VALUE=DATE:20261103",
            "RDATE:20261015T160000Z",
            "RDATE;TZID=America/Los_Angeles:20261029T090000,20261105T090000",
        ]
        let first = at(2026, 10, 6, 9)
        let parts = try #require(split(rules, first: .timed(first, timeZone: laID), at: .timed(at(2026, 10, 20, 9), timeZone: laID)))
        #expect(parts.before == [
            "RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261020T155959Z",
            "EXDATE;TZID=America/Los_Angeles:20261013T090000",
            "RDATE:20261015T160000Z",
        ])
        #expect(parts.after == [
            "RRULE:FREQ=WEEKLY;BYDAY=TU",
            "EXDATE;TZID=America/Los_Angeles:20261027T090000",
            "EXDATE;VALUE=DATE:20261103",
            "RDATE;TZID=America/Los_Angeles:20261029T090000,20261105T090000",
        ])
        let old = starts(parts.before, first: first, from: at(2026, 10, 1), to: at(2026, 12, 1)) ?? []
        let new = starts(parts.after, first: at(2026, 10, 20, 9), from: at(2026, 10, 1), to: at(2026, 12, 1)) ?? []
        #expect(old.map { DayDate($0, in: la) } == ["2026-10-06", "2026-10-15"].map(day))
        #expect(old + new == starts(rules, first: first, from: at(2026, 10, 1), to: at(2026, 12, 1)))
    }

    @Test func aDateAtTheCutGoesWithTheNewSeries() throws {
        // Oct 20 09:00 is 16:00 UTC: a second earlier stays with the old series.
        let rules = ["RRULE:FREQ=WEEKLY;BYDAY=TU", "RDATE:20261020T155959Z,20261020T160000Z"]
        let parts = try #require(split(rules, first: .timed(at(2026, 10, 6, 9), timeZone: laID), at: .timed(at(2026, 10, 20, 9), timeZone: laID)))
        #expect(parts.before.last == "RDATE:20261020T155959Z")
        #expect(parts.after.last == "RDATE:20261020T160000Z")
    }

    @Test func theFirstDayIsTheWholeSeries() {
        let first = EventTime.timed(at(2026, 10, 6, 9), timeZone: laID)
        #expect(Recurrence.split(recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=TU"], seriesStart: first, at: first, calendar: la) == .wholeSeries)
        // With the first day skipped, the second is the first event.
        let skipped = ["RRULE:FREQ=WEEKLY;BYDAY=TU", "EXDATE;TZID=America/Los_Angeles:20261006T090000"]
        #expect(Recurrence.split(recurrence: skipped, seriesStart: first, at: .timed(at(2026, 10, 13, 9), timeZone: laID), calendar: la) == .wholeSeries)
        #expect(split(skipped, first: first, at: .timed(at(2026, 10, 20, 9), timeZone: laID))?.before.first == "RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261020T155959Z")
        let allDay = EventTime.allDay(day("2026-10-02"))
        #expect(Recurrence.split(recurrence: ["RRULE:FREQ=WEEKLY"], seriesStart: allDay, at: allDay, calendar: la) == .wholeSeries)
    }

    /// A 09:00 Los Angeles series cut after the clocks went back on Nov 1: 09:00 is 17:00 UTC there, not 16:00.
    @Test func aSeriesCutAfterTheEndOfDaylightTime() throws {
        let first = at(2026, 10, 26, 9)
        let parts = try #require(split(["RRULE:FREQ=DAILY;COUNT=20"], first: .timed(first, timeZone: laID), at: .timed(at(2026, 11, 5, 9), timeZone: laID)))
        #expect(parts.before == ["RRULE:FREQ=DAILY;UNTIL=20261105T165959Z"])
        #expect(parts.after == ["RRULE:FREQ=DAILY;COUNT=10"])
        let old = try #require(starts(parts.before, first: first, from: at(2026, 10, 1), to: at(2027, 1, 1)))
        #expect(old.count == 10)
        #expect(old.first == utc("2026-10-26T16:00:00Z"))
        #expect(old.last == utc("2026-11-04T17:00:00Z"))
        let new = try #require(starts(parts.after, first: at(2026, 11, 5, 9), from: at(2026, 10, 1), to: at(2027, 1, 1)))
        #expect(new.count == 10)
        #expect(new.first == utc("2026-11-05T17:00:00Z"))
        #expect(new.allSatisfy { la.component(.hour, from: $0) == 9 })
        // Mondays from before the change: the last Monday before the cut stays, at 09:00 in winter time.
        let mondays = try #require(split(["RRULE:FREQ=WEEKLY;BYDAY=MO"], first: .timed(at(2026, 10, 5, 9), timeZone: laID), at: .timed(at(2026, 11, 9, 9), timeZone: laID)))
        #expect(mondays.before == ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261109T165959Z"])
        #expect(starts(mondays.before, first: at(2026, 10, 5, 9), from: at(2026, 10, 1), to: at(2027, 1, 1))?.last == utc("2026-11-02T17:00:00Z"))
    }

    @Test func aCountThatCannotBeCountedHereIsRefused() {
        // The last weekday of each month: only Google expands it.
        let lastWeekday = "RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"
        let first = EventTime.timed(at(2026, 10, 30, 9), timeZone: laID)
        let cut = EventTime.timed(at(2026, 12, 31, 9), timeZone: laID)
        #expect(Recurrence.split(recurrence: [lastWeekday + ";COUNT=6"], seriesStart: first, at: cut, calendar: la) == nil)
        // Without COUNT only its end moves, which needs no counting.
        let parts = split([lastWeekday], first: first, at: cut)
        #expect(parts?.before == [lastWeekday + ";UNTIL=20261231T165959Z"])
        #expect(parts?.after == [lastWeekday])
    }

    @Test func aRuleThatEndedBeforeTheDayStaysWithTheOldSeries() throws {
        // Mondays, two Wednesdays (the first day counts as one) and Fridays until Nov 7, cut at Monday Nov 16.
        let rules = ["RRULE:FREQ=WEEKLY;BYDAY=MO", "RRULE:FREQ=WEEKLY;BYDAY=WE;COUNT=2", "RRULE:FREQ=WEEKLY;BYDAY=FR;UNTIL=20261107T000000Z"]
        let parts = try #require(split(rules, first: .timed(at(2026, 11, 2, 10), timeZone: laID), at: .timed(at(2026, 11, 16, 10), timeZone: laID)))
        #expect(parts.before == ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261116T175959Z", rules[1], rules[2]])
        #expect(parts.after == ["RRULE:FREQ=WEEKLY;BYDAY=MO"])
    }

    /// Cut anywhere, the two series together have the days the series had, at the same times.
    @Test(arguments: [
        (["RRULE:FREQ=DAILY;COUNT=30"], "2026-10-06", 12),
        (["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR"], "2026-10-05", 5),
        (["RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=8"], "2026-10-30", 3),
        (["RRULE:FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20270301T000000Z", "EXDATE;TZID=America/Los_Angeles:20261124T090000,20270105T090000"], "2026-10-06", 9),
        (["RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH"], "2026-11-26", 2),
        (["RRULE:FREQ=MONTHLY;BYMONTHDAY=31;COUNT=6", "RDATE;TZID=America/Los_Angeles:20261130T090000"], "2026-10-31", 2),
    ])
    func theTwoSeriesTogetherAreTheOldOne(rules: [String], firstDay: String, index: Int) throws {
        let first = day(firstDay)
        let start = at(first.year, first.month, first.day, 9)
        func occurrences(_ lines: [String], from start: Date) -> [Occurrence]? {
            Recurrence.occurrences(
                start: .timed(start, timeZone: laID), end: .timed(start.addingTimeInterval(3600), timeZone: laID), recurrence: lines,
                from: at(2026, 1, 1), to: at(2031, 1, 1), calendar: la
            )
        }
        let whole = try #require(occurrences(rules, from: start))
        let cut = try #require(whole[index].originalStart)
        let cutStart = try #require(whole[index].start.date)
        let parts = try #require(split(rules, first: .timed(start, timeZone: laID), at: cut))
        let old = try #require(occurrences(parts.before, from: start))
        let new = try #require(occurrences(parts.after, from: cutStart))
        #expect(old + new == whole)
        #expect(old.count == index)
    }
}
