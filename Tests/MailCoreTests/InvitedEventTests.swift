import Foundation
import Testing
@testable import MailCore

private let laID = "America/Los_Angeles"
private let la: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: laID)!
    return calendar
}()

/// A wall-clock time in Los Angeles.
private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    la.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func time(_ date: Date) -> EventTime { .timed(date, timeZone: laID) }

/// The weekly standup: Mondays 9:00–9:15 since Oct 6, 2025, a year before these tests' October 2026.
private func standup(sequence: Int = 0, hour: Int = 9, rule: String = "RRULE:FREQ=WEEKLY;BYDAY=MO") -> Invitation {
    Invitation(
        method: .request, uid: "standup@google.com", sequence: sequence, summary: "Weekly standup",
        start: time(at(2025, 10, 6, hour)), end: time(at(2025, 10, 6, hour, 15)), recurrence: [rule]
    )
}

/// One date of the standup on its own: `original` is the Monday 9:00 it stands for.
private func day(
    _ original: Date, movedTo start: Date? = nil, sequence: Int = 1, method: Invitation.Method = .request, summary: String = "Weekly standup"
) -> Invitation {
    let begin = start ?? original
    return Invitation(
        method: method, uid: "standup@google.com", sequence: sequence, recurrenceID: time(original), summary: summary,
        start: time(begin), end: time(begin.addingTimeInterval(15 * 60))
    )
}

/// The starts of the dates from Oct 9 to Oct 31, 2026.
private func october(_ invitations: [Invitation]) -> [EventTime] {
    InvitedEvent(invitations).dates(from: at(2026, 10, 9), to: at(2026, 10, 31), calendar: la).map(\.start)
}

@Suite("Events known from invitation mail")
struct InvitedEventTests {
    @Test func aSeriesThatBeganLastYearHasEachDateInTheWindow() {
        let dates = InvitedEvent([standup()]).dates(from: at(2026, 10, 9), to: at(2026, 10, 23), calendar: la)
        #expect(dates.map(\.start) == [time(at(2026, 10, 12, 9)), time(at(2026, 10, 19, 9))])
        #expect(dates.map(\.end) == [time(at(2026, 10, 12, 9, 15)), time(at(2026, 10, 19, 9, 15))])
        #expect(dates.map(\.key) == ["20261012T160000Z", "20261019T160000Z"])
        #expect(dates.allSatisfy { $0.invitation == standup() })
    }

    @Test func theNextDateIsTheFirstThatHasNotEnded() {
        let event = InvitedEvent([standup()])
        // During Monday's standup it is still the next one.
        #expect(event.upcoming(now: at(2026, 10, 12, 9, 10), limit: 1, calendar: la).map(\.start) == [time(at(2026, 10, 12, 9))])
        #expect(event.upcoming(now: at(2026, 10, 12, 9, 15), limit: 1, calendar: la).map(\.start) == [time(at(2026, 10, 19, 9))])
        // A series whose dates have all ended has none.
        let ended = InvitedEvent([standup(rule: "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20260601T000000Z")])
        #expect(ended.upcoming(now: at(2026, 10, 9), limit: 1, calendar: la).isEmpty)
    }

    @Test func aMovedDateShowsAtItsNewTimeAndACancelledDateGoes() {
        let moved = day(at(2026, 10, 12, 9), movedTo: at(2026, 10, 13, 10), summary: "Weekly standup (Tuesday this week)")
        let cancelled = day(at(2026, 10, 19, 9), method: .cancel)
        let dates = InvitedEvent([standup(), moved, cancelled]).dates(from: at(2026, 10, 9), to: at(2026, 10, 31), calendar: la)
        #expect(dates.map(\.start) == [time(at(2026, 10, 13, 10)), time(at(2026, 10, 26, 9))])
        #expect(dates.first?.end == time(at(2026, 10, 13, 10, 15)))
        // The moved date keeps its place in the series, and is told by its own invitation.
        #expect(dates.first?.key == "20261012T160000Z")
        #expect(dates.first?.invitation.summary == "Weekly standup (Tuesday this week)")
        // A date cancelled inside the series' own file (STATUS:CANCELLED) goes too.
        var skipped = day(at(2026, 10, 26, 9))
        skipped.status = .cancelled
        #expect(october([standup(), skipped]) == [time(at(2026, 10, 12, 9)), time(at(2026, 10, 19, 9))])
    }

    @Test func datesMovedAcrossTheWindowsEdge() {
        // Oct 26 moved into Oct 9–23, and Oct 12 out of it.
        let into = day(at(2026, 10, 26, 9), movedTo: at(2026, 10, 22, 9))
        let out = day(at(2026, 10, 12, 9), movedTo: at(2026, 10, 27, 9))
        let dates = InvitedEvent([standup(), into, out]).dates(from: at(2026, 10, 9), to: at(2026, 10, 23), calendar: la)
        #expect(dates.map(\.start) == [time(at(2026, 10, 19, 9)), time(at(2026, 10, 22, 9))])
        #expect(dates.last?.key == "20261026T160000Z")
    }

    @Test func theNewestWordAboutEachDateCounts() {
        let monday = at(2026, 10, 12, 9)
        let eleven = day(monday, movedTo: at(2026, 10, 12, 11))
        let two = day(monday, movedTo: at(2026, 10, 12, 14))
        let four = day(monday, movedTo: at(2026, 10, 12, 16), sequence: 2)
        // Of two with the same SEQUENCE, the later mail; a higher SEQUENCE over later mail.
        #expect(october([standup(), eleven, two]).first == time(at(2026, 10, 12, 14)))
        #expect(october([standup(), four, two]).first == time(at(2026, 10, 12, 16)))
        // A cancellation as new as the move takes the date away; an older one does not.
        #expect(october([standup(), eleven, day(monday, method: .cancel)]).first == time(at(2026, 10, 19, 9)))
        #expect(october([standup(), four, day(monday, method: .cancel)]).first == time(at(2026, 10, 12, 16)))
        // The series changed after the date was moved: that date follows the series again.
        #expect(october([standup(), eleven, standup(sequence: 2, hour: 10)]).first == time(at(2026, 10, 12, 10)))
        // An older invitation to the whole event that arrives later changes nothing.
        #expect(InvitedEvent([standup(sequence: 2, hour: 10), standup()]).main == standup(sequence: 2, hour: 10))
    }

    @Test func aRuleNotWorkedOutHereKeepsItsFirstDate() {
        let close = Invitation(
            method: .request, uid: "close@google.com", summary: "Month-end close", start: time(at(2026, 10, 30, 15)),
            end: time(at(2026, 10, 30, 16)), recurrence: ["RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"]
        )
        let dates = InvitedEvent([close]).dates(from: at(2026, 10, 9), to: at(2026, 12, 31), calendar: la)
        #expect(dates.map(\.start) == [close.start])
        #expect(dates.map(\.key) == [""])
    }

    @Test func singleEventsHaveTheirOwnDate() {
        let lunch = Invitation(method: .request, uid: "lunch", summary: "Lunch", start: time(at(2026, 10, 14, 12)), end: time(at(2026, 10, 14, 13)))
        #expect(InvitedEvent([lunch]).dates(from: at(2026, 10, 9), to: at(2026, 10, 23), calendar: la).map(\.key) == [""])
        #expect(InvitedEvent([lunch]).upcoming(now: at(2026, 10, 14, 13), limit: 1, calendar: la).isEmpty)
    }

    @Test func allDayDatesMatchByDay() {
        let friday = Invitation(
            method: .request, uid: "remote", summary: "Remote Friday", start: .allDay(DayDate("2026-10-02")!),
            end: .allDay(DayDate("2026-10-03")!), recurrence: ["RRULE:FREQ=WEEKLY"]
        )
        let off = Invitation(method: .cancel, uid: "remote", sequence: 1, recurrenceID: .allDay(DayDate("2026-10-16")!), summary: "Remote Friday", start: .allDay(DayDate("2026-10-16")!))
        let days = InvitedEvent([friday, off]).dates(from: at(2026, 10, 9), to: at(2026, 10, 31), calendar: la).compactMap(\.start.day)
        #expect(days == ["2026-10-09", "2026-10-23", "2026-10-30"].compactMap { DayDate($0) })
    }

    @Test func datesWithoutTheWholeEventStandAlone() {
        // Invited to one date of someone else's series: that date, answered as itself.
        let one = day(at(2026, 10, 19, 9), movedTo: at(2026, 10, 19, 13))
        let event = InvitedEvent([one])
        #expect(event.main == nil)
        #expect(october([one]) == [time(at(2026, 10, 19, 13))])
        #expect(event.answerTarget(at: "20261019T160000Z", answers: [:]) == one)
        #expect(event.invitation(at: "20261019T160000Z") == one)
    }

    @Test func aSeriesIsAnsweredAsAWhole() {
        let moved = day(at(2026, 10, 12, 9), movedTo: at(2026, 10, 13, 10))
        let event = InvitedEvent([standup(), moved])
        #expect(event.answerTarget(at: "20261012T160000Z", answers: [:]) == standup())
        #expect(event.answerTarget(at: "", answers: [:]) == standup())
        // The page for that date tells the date's own invitation.
        #expect(event.invitation(at: "20261012T160000Z") == moved)
        #expect(event.invitation(at: "20261019T160000Z") == standup())
    }

    @Test func cancellationsAndGuestsAnswers() {
        let cancel = Invitation(method: .cancel, uid: "standup@google.com", sequence: 1, summary: "Weekly standup", start: standup().start)
        #expect(october([standup(), cancel]).isEmpty)
        #expect(InvitedEvent([standup(), cancel]).answerTarget(at: "", answers: [:]) == nil)
        // Invited again after the cancellation.
        #expect(october([standup(), cancel, standup(sequence: 2)]).count == 3)
        // A guest's answer about one date moves nothing.
        #expect(InvitedEvent([standup(), day(at(2026, 10, 12, 9), movedTo: at(2026, 10, 12, 17), method: .reply)]).changedDates.isEmpty)
    }

    @Test func limitAndGrouping() {
        let daily = Invitation(
            method: .request, uid: "check-in", summary: "Check-in", start: time(at(2026, 1, 5, 8)), end: time(at(2026, 1, 5, 8, 10)),
            recurrence: ["RRULE:FREQ=DAILY"]
        )
        #expect(InvitedEvent([daily]).dates(from: at(2026, 10, 9), to: at(2027, 10, 9), limit: 5, calendar: la).count == 5)
        let events = InvitedEvent.events(from: [standup(), daily, day(at(2026, 10, 12, 9), method: .cancel)])
        #expect(events.map(\.uid) == ["standup@google.com", "check-in"])
        #expect(events.first?.changedDates.keys.sorted() == ["20261012T160000Z"])
        #expect(events.last?.main == daily)
    }
}

/// Your answer by email to the standup: to the whole series (with the dates it covers), or to one date by its key.
/// `minute`: when you answered, in minutes after the first answer.
private func answer(
    _ response: ResponseStatus, sequence: Int, key: String = "", covered: [String: Int] = [:], minute: Int = 0
) -> InvitationAnswer {
    InvitationAnswer(
        uid: "standup@google.com", recurrenceID: key, response: response, sequence: sequence, covered: covered,
        answeredAt: at(2026, 10, 9, 8).addingTimeInterval(Double(minute) * 60)
    )
}

@Suite("One answer per invited event")
struct InvitationAnswerRuleTests {
    /// The key of the standup on Monday Oct 12, 2026 (9:00 in Los Angeles).
    let october12 = "20261012T160000Z"
    let october19 = "20261019T160000Z"
    let now = at(2026, 10, 9)

    @Test func oneAnswerCoversEveryDateAndTheDatesChangedBeforeIt() {
        // Oct 12 moved to Tuesday 10:00 before you answered; that date counts its SEQUENCE on its own (1).
        let moved = day(at(2026, 10, 12, 9), movedTo: at(2026, 10, 13, 10))
        let event = InvitedEvent([standup(), moved])
        // Not answered yet: the first date waits, the moved one; answering it answers the series.
        #expect(event.waitingDate(now: now, answers: [:], calendar: la)?.key == october12)
        #expect(event.answerTarget(at: october12, answers: [:]) == standup())
        #expect(event.answer(at: october12, answers: [:]) == nil)
        // The answer to the series is at the series' SEQUENCE and covers the change the mail already told.
        #expect(event.coverage(by: standup()) == [october12: 1])
        #expect(event.coverage(by: moved).isEmpty)
        let answers = ["": answer(.accepted, sequence: 0, covered: event.coverage(by: standup()))]
        #expect(event.answer(at: october12, answers: answers)?.response == .accepted)
        #expect(event.answer(at: october19, answers: answers)?.response == .accepted)
        #expect(event.waitingDate(now: now, answers: answers, calendar: la) == nil)
        // Answering again goes to the series.
        #expect(event.answerTarget(at: october12, answers: answers) == standup())
    }

    @Test func aDateChangedAfterYourAnswerAsksAgainOnItsOwn() {
        let answers = ["": answer(.accepted, sequence: 0)]
        let moved = day(at(2026, 10, 12, 9), movedTo: at(2026, 10, 13, 10))
        let event = InvitedEvent([standup(), moved])
        // The moved date waits and is answered as itself; the other dates keep the series' answer.
        #expect(event.answerTarget(at: october12, answers: answers) == moved)
        #expect(event.answer(at: october12, answers: answers) == nil)
        #expect(event.answer(at: october19, answers: answers)?.response == .accepted)
        #expect(event.waitingDate(now: now, answers: answers, calendar: la)?.key == october12)
        var both = answers
        both[october12] = answer(.declined, sequence: 1, key: october12, minute: 5)
        #expect(event.answer(at: october12, answers: both)?.response == .declined)
        #expect(event.answerTarget(at: october12, answers: both) == moved)
        #expect(event.waitingDate(now: now, answers: both, calendar: la) == nil)
        // A later answer to the series covers that date again.
        both[""] = answer(.tentative, sequence: 0, covered: [october12: 1], minute: 10)
        #expect(event.answer(at: october12, answers: both)?.response == .tentative)
        #expect(event.answerTarget(at: october12, answers: both) == standup())
    }

    @Test func dateSequencesAndTheSeriesSequenceAreCountedApart() {
        // Answered with Oct 12 already moved (its SEQUENCE 1); the series is still at 0.
        let moved = day(at(2026, 10, 12, 9), movedTo: at(2026, 10, 13, 10))
        let answers = ["": answer(.accepted, sequence: 0, covered: [october12: 1])]
        // Oct 19 moved for the first time, also at SEQUENCE 1: it was not covered, so it waits on its own.
        let later = day(at(2026, 10, 19, 9), movedTo: at(2026, 10, 20, 10))
        let event = InvitedEvent([standup(), moved, later])
        #expect(event.answer(at: october12, answers: answers)?.response == .accepted)
        #expect(event.answer(at: october19, answers: answers) == nil)
        #expect(event.answerTarget(at: october19, answers: answers) == later)
        #expect(event.waitingDate(now: now, answers: answers, calendar: la)?.key == october19)
        // The whole series moved to 10:00 at SEQUENCE 1: a newer invitation, so every date waits again.
        let updated = InvitedEvent([standup(), moved, standup(sequence: 1, hour: 10)])
        #expect(updated.answer(at: october12, answers: answers) == nil)
        #expect(updated.answerTarget(at: october12, answers: answers) == standup(sequence: 1, hour: 10))
        #expect(updated.waitingDate(now: now, answers: answers, calendar: la) != nil)
    }

    @Test func anUpdateToTheWholeSeriesAsksAgain() {
        let answers = ["": answer(.accepted, sequence: 0)]
        let event = InvitedEvent([standup(), standup(sequence: 2, hour: 10)])
        #expect(event.answer(at: october19, answers: answers) == nil)
        #expect(event.answerTarget(at: october19, answers: answers) == standup(sequence: 2, hour: 10))
        #expect(event.waitingDate(now: now, answers: answers, calendar: la)?.start == time(at(2026, 10, 12, 10)))
    }

    @Test func cancelledDatesAndEventsHaveNothingToAnswer() {
        let off = day(at(2026, 10, 12, 9), method: .cancel)
        let event = InvitedEvent([standup(), off])
        #expect(event.answerTarget(at: october12, answers: [:]) == nil)
        #expect(event.answerTarget(at: october19, answers: [:]) == standup())
        // The first waiting date skips the cancelled one, and a cancelled date is not part of an answer.
        #expect(event.waitingDate(now: now, answers: [:], calendar: la)?.key == october19)
        #expect(event.coverage(by: standup()).isEmpty)
        let cancel = Invitation(method: .cancel, uid: "standup@google.com", sequence: 1, summary: "Weekly standup", start: standup().start)
        #expect(InvitedEvent([standup(), cancel]).answerTarget(at: october19, answers: [:]) == nil)
        #expect(InvitedEvent([standup(), cancel]).waitingDate(now: now, answers: [:], calendar: la) == nil)
        // An update marked STATUS:CANCELLED cancels as well.
        var calledOff = standup(sequence: 1)
        calledOff.status = .cancelled
        #expect(InvitedEvent([standup(), calledOff]).answerTarget(at: october19, answers: [:]) == nil)
        #expect(InvitedEvent([standup(), calledOff]).answer(at: october19, answers: ["": answer(.accepted, sequence: 1)]) == nil)
    }

    @Test func datesWithoutTheWholeEventAreAnsweredOneByOne() {
        let one = day(at(2026, 10, 19, 9), movedTo: at(2026, 10, 19, 13))
        let event = InvitedEvent([one])
        // An answer to the whole series does not answer a date the mail names on its own.
        let whole = ["": answer(.accepted, sequence: 1, covered: [october19: 1])]
        #expect(event.answerTarget(at: october19, answers: whole) == one)
        #expect(event.answer(at: october19, answers: whole) == nil)
        #expect(event.answerTarget(at: october12, answers: whole) == nil)
        #expect(event.coverage(by: one).isEmpty)
        let own = [october19: answer(.declined, sequence: 1, key: october19)]
        #expect(event.answer(at: october19, answers: own)?.response == .declined)
        #expect(event.waitingDate(now: now, answers: own, calendar: la) == nil)
        // Moved again: it waits again.
        let again = day(at(2026, 10, 19, 9), movedTo: at(2026, 10, 19, 15), sequence: 2)
        #expect(InvitedEvent([one, again]).answer(at: october19, answers: own) == nil)
    }

    @Test func anAnswerGoesToTheNewestWordTheMailTells() {
        let moved = day(at(2026, 10, 12, 9), movedTo: at(2026, 10, 13, 10), sequence: 2)
        let event = InvitedEvent([standup(), standup(sequence: 1, hour: 10), moved])
        // From an older mail: the series as it is now, and the date as it is now.
        #expect(event.newest(standup()) == standup(sequence: 1, hour: 10))
        #expect(event.newest(day(at(2026, 10, 12, 9))) == moved)
        // Nothing newer: the invitation itself.
        #expect(event.newest(moved) == moved)
        #expect(event.newest(day(at(2026, 10, 19, 9))) == day(at(2026, 10, 19, 9)))
    }

    @Test func pastDatesDoNotWait() {
        let lunch = Invitation(
            method: .request, uid: "lunch", summary: "Lunch", start: time(at(2026, 10, 14, 12)), end: time(at(2026, 10, 14, 13))
        )
        #expect(InvitedEvent([lunch]).waitingDate(now: now, answers: [:], calendar: la)?.key == "")
        #expect(InvitedEvent([lunch]).waitingDate(now: at(2026, 10, 15), answers: [:], calendar: la) == nil)
    }

    @Test func answersQueuedBeforeDatesWereRecordedStillDecode() throws {
        let json = #"{"uid":"standup@google.com","recurrenceID":"","response":"accepted","sequence":0,"answeredAt":0}"#
        let decoded = try JSONDecoder().decode(InvitationAnswer.self, from: Data(json.utf8))
        #expect(decoded.covered.isEmpty && decoded.response == .accepted)
        let round = try JSONDecoder().decode(InvitationAnswer.self, from: JSONEncoder().encode(answer(.declined, sequence: 2, covered: [october12: 3])))
        #expect(round.covered == [october12: 3] && round.sequence == 2)
    }
}
