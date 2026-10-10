import Foundation
import Testing
@testable import MailCore

private let pacific: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    pacific.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// From `day` at `start` to `endDay` (default `day`) at `end`, October 2026, "HH:mm" as (hour, minute).
private func span(_ day: Int, _ start: (Int, Int), _ end: (Int, Int), endDay: Int? = nil) -> DateInterval {
    DateInterval(start: date(2026, 10, day, start.0, start.1), end: date(2026, 10, endDay ?? day, end.0, end.1))
}

private let monday = date(2026, 10, 12, 8)
private let tuesday = DayDate(year: 2026, month: 10, day: 13)
private let wednesday = DayDate(year: 2026, month: 10, day: 14)

private func free(
    _ busy: [DateInterval], _ days: [DayDate], from workStart: Int = 9 * 60, to workEnd: Int = 17 * 60, minimum: TimeInterval = 30 * 60,
    now: Date = monday
) -> [(day: DayDate, slots: [DateInterval])] {
    FreeTime.slots(busy: busy, days: days, workStart: workStart, workEnd: workEnd, minimum: minimum, now: now, calendar: pacific)
}

private func markdown(_ days: [(day: DayDate, slots: [DateInterval])]) -> String {
    FreeTime.markdown(days, calendar: pacific, zoneLabel: "PT")
}

@Suite("Free time")
struct FreeTimeTests {
    @Test func mergesOverlappingBusyTimes() {
        let busy = [span(13, (8, 30), (9, 40)), span(14, (8, 0), (9, 45)), span(14, (12, 30), (17, 30)), span(14, (12, 0), (13, 0))]
        let days = free(busy, [tuesday, wednesday])
        #expect(days.map { $0.day } == [tuesday, wednesday])
        #expect(days[0].slots == [span(13, (9, 45), (17, 0))])
        #expect(days[1].slots == [span(14, (9, 45), (12, 0))])
        #expect(markdown(days) == "Free times (PT):\n- Tue Oct 13: 09:45–17:00\n- Wed Oct 14: 09:45–12:00")
    }

    @Test func roundsToQuarterHoursAndDropsShortSlots() {
        let busy = [span(13, (10, 5), (10, 40)), span(13, (14, 50), (15, 10)), span(13, (15, 20), (15, 50))]
        let days = free(busy, [tuesday])
        #expect(days[0].slots == [span(13, (9, 0), (10, 0)), span(13, (10, 45), (14, 45)), span(13, (16, 0), (17, 0))])
        #expect(markdown(days) == "Free times (PT):\n- Tue Oct 13: 09:00–10:00, 10:45–14:45, 16:00–17:00")
        #expect(free(busy, [tuesday], minimum: 61 * 60)[0].slots == [span(13, (10, 45), (14, 45))])
    }

    @Test func neverBeforeNow() {
        let now = date(2026, 10, 13, 10, 7)
        let days = free([], [DayDate(year: 2026, month: 10, day: 12), tuesday], now: now)
        #expect(days[0].slots.isEmpty)
        #expect(days[1].slots == [span(13, (10, 15), (17, 0))])
        #expect(free([], [tuesday], now: date(2026, 10, 13, 16, 50))[0].slots.isEmpty)
        #expect(free([], [tuesday], now: date(2026, 10, 13, 18))[0].slots.isEmpty)
    }

    @Test func fullDaysAreLeftOutOfTheMarkdown() {
        let busy = [span(13, (8, 0), (18, 0))]
        let days = free(busy, [tuesday, wednesday])
        #expect(days[0].slots.isEmpty)
        #expect(days[1].slots == [span(14, (9, 0), (17, 0))])
        #expect(markdown(days) == "Free times (PT):\n- Wed Oct 14: 09:00–17:00")
        #expect(markdown(free(busy, [tuesday])) == "")
        #expect(markdown([]) == "")
        #expect(free(busy, []).isEmpty)
        #expect(free([], [tuesday], from: 17 * 60, to: 9 * 60)[0].slots.isEmpty)
    }

    @Test func busyTimeAcrossMidnight() {
        let days = free([span(13, (16, 0), (10, 0), endDay: 14)], [tuesday, wednesday])
        #expect(days[0].slots == [span(13, (9, 0), (16, 0))])
        #expect(days[1].slots == [span(14, (10, 0), (17, 0))])
    }

    @Test func eveningUntilMidnight() {
        let days = free([], [tuesday], from: 22 * 60, to: 24 * 60, minimum: 0)
        #expect(days[0].slots == [DateInterval(start: date(2026, 10, 13, 22), end: date(2026, 10, 14, 0))])
        #expect(markdown(days) == "Free times (PT):\n- Tue Oct 13: 22:00–24:00")
    }

    @Test func workingHoursFollowTheWallClockWhenClocksChange() {
        let sunday = DayDate(year: 2026, month: 11, day: 1)
        let days = free([], [sunday], minimum: 0)
        #expect(days[0].slots == [DateInterval(start: date(2026, 11, 1, 9), end: date(2026, 11, 1, 17))])
        #expect(days[0].slots.first?.duration == TimeInterval(8 * 3600))
    }

    @Test func findATimeJumpsPastBusyTimes() {
        let busy = [span(13, (9, 0), (12, 0)), span(13, (12, 30), (17, 0))]
        func next(_ from: Date, forward: Bool = true, minutes: Double = 30, now: Date = monday) -> Date? {
            FreeTime.nextSlot(from: from, forward: forward, length: minutes * 60, busy: busy, workStart: 9 * 60, workEnd: 17 * 60, now: now, calendar: pacific)?.start
        }
        #expect(next(date(2026, 10, 13, 10)) == date(2026, 10, 13, 12))
        #expect(next(date(2026, 10, 13, 12)) == date(2026, 10, 14, 9))
        #expect(next(date(2026, 10, 13, 10), minutes: 60) == date(2026, 10, 14, 9))
        #expect(next(date(2026, 10, 13, 12), forward: false) == date(2026, 10, 12, 9))
        // Never before now: on Monday at 09:40 the first start is 09:45.
        #expect(next(date(2026, 10, 12, 10), forward: false, now: date(2026, 10, 12, 9, 40)) == date(2026, 10, 12, 9, 45))
        #expect(next(date(2026, 10, 12, 9, 45), forward: false, now: date(2026, 10, 12, 9, 40)) == nil)
        // Friday afternoon goes on to Monday.
        #expect(next(date(2026, 10, 16, 16, 45)) == date(2026, 10, 19, 9))
        let slot = FreeTime.nextSlot(from: date(2026, 10, 13, 10), forward: true, length: 1800, busy: busy, workStart: 540, workEnd: 1020, now: monday, calendar: pacific)
        #expect(slot?.duration == 1800)
    }

    @Test func subtractingCutsHolesOutOfBusyTimes() {
        let busy = [span(13, (9, 0), (12, 0)), span(13, (14, 0), (15, 0))]
        let left = FreeTime.subtracting([span(13, (10, 0), (11, 0)), span(13, (14, 0), (15, 0))], from: busy)
        #expect(left == [span(13, (9, 0), (10, 0)), span(13, (11, 0), (12, 0))])
        #expect(FreeTime.subtracting([], from: busy) == busy)
    }

    @Test func workingDaysSkipWeekends() {
        let friday = date(2026, 10, 9, 10)
        let days = [9, 12, 13].map { DayDate(year: 2026, month: 10, day: $0) }
        #expect(FreeTime.workingDays(from: friday, count: 3, calendar: pacific) == days)
        #expect(FreeTime.workingDays(from: date(2026, 10, 10, 12), count: 2, calendar: pacific) == Array(days.dropFirst()))
        #expect(FreeTime.workingDays(from: date(2026, 10, 9, 22), count: 1, calendar: pacific) == [days[0]])
        #expect(FreeTime.workingDays(from: friday, count: 0, calendar: pacific).isEmpty)
        #expect(FreeTime.workingDays(from: friday, count: -4, calendar: pacific).isEmpty)
        #expect(FreeTime.workingDays(from: friday, count: 10, calendar: pacific).count == 10)
    }
}
