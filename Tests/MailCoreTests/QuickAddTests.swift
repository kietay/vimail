import Foundation
import Testing
@testable import MailCore

private let zone = "America/Los_Angeles"

private let pacific: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    pacific.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Friday, October 9 2026, 10:00 in Los Angeles.
private let friday = date(2026, 10, 9, 10)

private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> EventTime {
    .timed(date(year, month, day, hour, minute), timeZone: zone)
}

private func allDay(_ month: Int, _ day: Int, year: Int = 2026) -> EventTime {
    .allDay(DayDate(year: year, month: month, day: day))
}

private let jamie = EmailAddress(name: "Jamie Chen", email: "jamie.chen@studio.co")
private let alex = EmailAddress(name: "Alex Morgan", email: "alex.morgan@studio.co")
private let bob = EmailAddress(email: "bob@example.com")

private func contacts(_ name: String) -> [EmailAddress] {
    switch name.lowercased() {
    case "jamie": [jamie]
    case "alex": [alex]
    default: []
    }
}

private func parse(_ text: String, now: Date = friday, defaultLength: TimeInterval = 1800) -> QuickAdd.Result {
    QuickAdd.parse(text, now: now, calendar: pacific, defaultLength: defaultLength, contacts: contacts)
}

/// Tokens stay inside the text, in order, without overlapping, and there is always a title.
private func expectWellFormed(_ result: QuickAdd.Result, _ text: String) {
    let count = text.count
    #expect(!result.title.isEmpty, "\(text)")
    var previousEnd = 0
    for token in result.tokens {
        #expect(token.start >= previousEnd && token.start < token.end && token.end <= count, "\(text): \(token)")
        previousEnd = token.end
    }
}

@Suite("Quick add: days")
struct QuickAddDayTests {
    @Test func aDayWithoutATimeIsAllDay() {
        let cases: [(String, EventTime)] = [
            ("dentist today", allDay(10, 9)),
            ("dentist tomorrow", allDay(10, 10)),
            ("dentist tom", allDay(10, 10)),
            ("dentist sat", allDay(10, 10)),
            ("dentist sun", allDay(10, 11)),
            ("dentist mon", allDay(10, 12)),
            ("dentist monday", allDay(10, 12)),
            ("dentist tue", allDay(10, 13)),
            ("dentist tues", allDay(10, 13)),
            ("dentist wednesday", allDay(10, 14)),
            ("dentist thurs", allDay(10, 15)),
            ("dentist fri", allDay(10, 16)),
            ("dentist FRIDAY", allDay(10, 16)),
            ("dentist next tue", allDay(10, 20)),
            ("dentist next fri", allDay(10, 23)),
            ("dentist on thu", allDay(10, 15)),
            ("dentist oct 16", allDay(10, 16)),
            ("dentist Oct. 16", allDay(10, 16)),
            ("dentist 16 oct", allDay(10, 16)),
            ("dentist october 16", allDay(10, 16)),
            ("dentist oct 16th", allDay(10, 16)),
            ("dentist 10/16", allDay(10, 16)),
            ("dentist 2026-10-16", allDay(10, 16)),
            ("dentist oct 9", allDay(10, 9)),
            ("dentist oct 1", allDay(10, 1, year: 2027)),
            ("dentist 10/1", allDay(10, 1, year: 2027)),
            ("dentist jan 5", allDay(1, 5, year: 2027)),
            ("dentist oct 16 2027", allDay(10, 16, year: 2027)),
            ("dentist oct 16, 2027", allDay(10, 16, year: 2027)),
            ("dentist 10/16/27", allDay(10, 16, year: 2027)),
            ("dentist 10/16/2027", allDay(10, 16, year: 2027)),
            ("dentist in 3d", allDay(10, 12)),
            ("dentist in 2w", allDay(10, 23)),
            ("dentist in 3 days", allDay(10, 12)),
            ("dentist in 1 week", allDay(10, 16)),
        ]
        for (text, start) in cases {
            let result = parse(text)
            #expect(result.title == "Dentist", "\(text)")
            #expect(result.start == start, "\(text)")
            if case .allDay(let day) = start {
                #expect(result.end == .allDay(day.adding(days: 1, in: pacific)), "\(text)")
            }
            #expect(result.tokens.map(\.role) == [.day], "\(text)")
        }
    }

    @Test func rangesOfDaysAreMultiDayAllDayEvents() {
        let cases: [(String, EventTime, EventTime)] = [
            ("offsite fri-sun", allDay(10, 16), allDay(10, 19)),
            ("offsite fri - sun", allDay(10, 16), allDay(10, 19)),
            ("offsite mon to wed", allDay(10, 12), allDay(10, 15)),
            ("offsite oct 16-18", allDay(10, 16), allDay(10, 19)),
            ("offsite oct 16–18", allDay(10, 16), allDay(10, 19)),
            ("offsite 16-18 oct", allDay(10, 16), allDay(10, 19)),
            ("offsite oct 30-2", allDay(10, 30), allDay(11, 3)),
            ("offsite oct 30 - nov 2", allDay(10, 30), allDay(11, 3)),
            ("offsite dec 30-jan 2", allDay(12, 30), allDay(1, 3, year: 2027)),
        ]
        for (text, start, end) in cases {
            let result = parse(text)
            #expect(result.title == "Offsite", "\(text)")
            #expect(result.start == start, "\(text)")
            #expect(result.end == end, "\(text)")
        }
    }

    @Test func allDayWordsMakeAnAllDayEvent() {
        let cases: [(String, EventTime)] = [
            ("offsite fri all day", allDay(10, 16)),
            ("offsite fri allday", allDay(10, 16)),
            ("offsite all-day fri", allDay(10, 16)),
            ("offsite all day", allDay(10, 9)),
            ("offsite fri all day 3pm", allDay(10, 16)),
        ]
        for (text, start) in cases {
            let result = parse(text)
            #expect(result.title == "Offsite", "\(text)")
            #expect(result.start == start, "\(text)")
            #expect(result.end?.day == start.day?.adding(days: 1, in: pacific), "\(text)")
        }
    }

    @Test func tonightIsAnEveningOnToday() {
        let cases: [(String, EventTime, EventTime)] = [
            ("dinner tonight", at(10, 9, 19), at(10, 9, 19, 30)),
            ("dinner tonight at 8", at(10, 9, 20), at(10, 9, 20, 30)),
            ("dinner at 8 tonight", at(10, 9, 20), at(10, 9, 20, 30)),
            ("dinner tonight 9:30", at(10, 9, 21, 30), at(10, 9, 22)),
            ("dinner tonight 8-10", at(10, 9, 20), at(10, 9, 22)),
        ]
        for (text, start, end) in cases {
            let result = parse(text)
            #expect(result.title == "Dinner", "\(text)")
            #expect(result.start == start, "\(text)")
            #expect(result.end == end, "\(text)")
        }
    }

    @Test func impossibleDatesStayInTheTitle() {
        for (text, title) in [("party feb 30", "Party feb 30"), ("party oct 32", "Party oct 32"), ("party 13/45", "Party 13/45"), ("party 2026-13-45", "Party 2026-13-45")] {
            let result = parse(text)
            #expect(result.start == nil, "\(text)")
            #expect(result.title == title, "\(text)")
        }
    }

    @Test func tomIsTomorrowUnlessItNamesSomeone() {
        #expect(parse("call tom").start == allDay(10, 10))
        let lunch = parse("lunch with tom")
        #expect(lunch.start == nil)
        #expect(lunch.unknownGuests == ["tom"])
        #expect(lunch.title == "Lunch with tom")
        let talk = parse("talk to tom fri")
        #expect(talk.start == allDay(10, 16))
        #expect(talk.title == "Talk to tom")
    }

    @Test func aDayInsideAWordIsNotADay() {
        let result = parse("kickoff-tomorrow")
        #expect(result.start == nil)
        #expect(result.title == "Kickoff-tomorrow")
        #expect(parse("follow-up tomorrow").title == "Follow-up")
    }

    @Test func datesAreGregorianInTheCalendarsZone() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = pacific.timeZone
        #expect(QuickAdd.parse("dentist oct 16", now: friday, calendar: buddhist) { _ in [] }.start == allDay(10, 16))
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let expected = london.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9))!
        #expect(QuickAdd.parse("call fri 9am", now: friday, calendar: london) { _ in [] }.start == .timed(expected, timeZone: "Europe/London"))
    }
}

@Suite("Quick add: times")
struct QuickAddTimeTests {
    @Test func aTimeWithoutADayIsTodayWhenAheadElseTomorrow() {
        let cases: [(String, EventTime)] = [
            ("call 11am", at(10, 9, 11)),
            ("call 9am", at(10, 10, 9)),
            ("call 9:30am", at(10, 10, 9, 30)),
            ("call 4:15pm", at(10, 9, 16, 15)),
            ("call 4:15 PM", at(10, 9, 16, 15)),
            ("call 3 pm", at(10, 9, 15)),
            ("call 9:30", at(10, 10, 9, 30)),
            ("call 3:30", at(10, 9, 15, 30)),
            ("call 03:30", at(10, 10, 3, 30)),
            ("call 14:00", at(10, 9, 14)),
            ("call noon", at(10, 9, 12)),
            ("call midnight", at(10, 10, 0)),
            ("call 12am", at(10, 10, 0)),
            ("call 12pm", at(10, 9, 12)),
            ("call at 3", at(10, 9, 15)),
            ("call at 7", at(10, 9, 19)),
            ("call at 8", at(10, 10, 8)),
            ("call at 11", at(10, 9, 11)),
            ("call at 12", at(10, 9, 12)),
            ("call at 15", at(10, 9, 15)),
            ("call @ 3", at(10, 9, 15)),
            ("call @3pm", at(10, 9, 15)),
        ]
        for (text, start) in cases {
            let result = parse(text)
            #expect(result.title == "Call", "\(text)")
            #expect(result.start == start, "\(text)")
            #expect(result.end == start.date.map { .timed($0.addingTimeInterval(1800), timeZone: zone) }, "\(text)")
            #expect(result.location == nil, "\(text)")
        }
    }

    @Test func ranges() {
        let cases: [(String, EventTime, EventTime)] = [
            ("sync fri 9-10", at(10, 16, 9), at(10, 16, 10)),
            ("sync fri 9:30-11", at(10, 16, 9, 30), at(10, 16, 11)),
            ("sync fri 10-11:30", at(10, 16, 10), at(10, 16, 11, 30)),
            ("sync fri 2-3pm", at(10, 16, 14), at(10, 16, 15)),
            ("sync fri 2-3", at(10, 16, 14), at(10, 16, 15)),
            ("sync fri 11-1pm", at(10, 16, 11), at(10, 16, 13)),
            ("sync fri 11-1", at(10, 16, 11), at(10, 16, 13)),
            ("sync fri 11am-1pm", at(10, 16, 11), at(10, 16, 13)),
            ("sync fri 14:00-15:30", at(10, 16, 14), at(10, 16, 15, 30)),
            ("sync fri 2pm–3pm", at(10, 16, 14), at(10, 16, 15)),
            ("sync fri 2pm to 3pm", at(10, 16, 14), at(10, 16, 15)),
            ("sync fri 2pm - 3pm", at(10, 16, 14), at(10, 16, 15)),
            ("sync fri 2 to 3pm", at(10, 16, 14), at(10, 16, 15)),
            ("sync fri from 9 to 5", at(10, 16, 9), at(10, 16, 17)),
            ("sync fri 7-8", at(10, 16, 19), at(10, 16, 20)),
            ("sync fri noon-1", at(10, 16, 12), at(10, 16, 13)),
            ("sync fri 9pm-midnight", at(10, 16, 21), at(10, 17, 0)),
            ("sync fri 11pm-1am", at(10, 16, 23), at(10, 17, 1)),
            ("sync fri 9-10 2h", at(10, 16, 9), at(10, 16, 10)),
            ("sync 9-10", at(10, 10, 9), at(10, 10, 10)),
            ("sync oct 16-18 9-5", at(10, 16, 9), at(10, 18, 17)),
        ]
        for (text, start, end) in cases {
            let result = parse(text)
            #expect(result.title == "Sync", "\(text)")
            #expect(result.start == start, "\(text)")
            #expect(result.end == end, "\(text)")
        }
    }

    @Test func aBareNumberIsNotATime() {
        let cases: [(String, String, EventTime?)] = [
            ("lunch for 2", "Lunch for 2", nil),
            ("call 3", "Call 3", nil),
            ("room 101 review", "Room 101 review", nil),
            ("sync 9 to 5", "Sync 9 to 5", nil),
            ("lunch for 2 at noon", "Lunch for 2", at(10, 9, 12)),
        ]
        for (text, title, start) in cases {
            let result = parse(text)
            #expect(result.title == title, "\(text)")
            #expect(result.start == start, "\(text)")
        }
    }

    @Test func inHoursStartsFromNow() {
        let call = parse("call mom in 2h")
        #expect(call.title == "Call mom")
        #expect(call.start == at(10, 9, 12))
        #expect(call.end == at(10, 9, 12, 30))
        #expect(call.tokens == [QuickAdd.Token(role: .time, start: 9, end: 14)])
        #expect(parse("call mom in 90 minutes").start == at(10, 9, 11, 30))
        #expect(parse("call mom in 3 days").start == allDay(10, 12))
    }
}

@Suite("Quick add: lengths")
struct QuickAddLengthTests {
    @Test func lengthsSetTheEnd() {
        let cases: [(String, Int)] = [
            ("review fri 9am", 30),
            ("review fri 9am 30m", 30),
            ("review fri 9am 45min", 45),
            ("review fri 9am 45 mins", 45),
            ("review fri 9am 1h", 60),
            ("review fri 9am 1hr", 60),
            ("review fri 9am 1h30", 90),
            ("review fri 9am 1h30m", 90),
            ("review fri 9am 1h 30m", 90),
            ("review fri 9am 1.5h", 90),
            ("review fri 9am 90m", 90),
            ("review fri 9am 2 hours", 120),
            ("review fri 9am 1.5 hours", 90),
            ("review fri 9am for 1h", 60),
            ("review fri 9am for 20 minutes", 20),
            ("review 45-min fri 9am", 45),
            ("review 2-hour fri 9am", 120),
        ]
        for (text, minutes) in cases {
            let result = parse(text)
            #expect(result.title == "Review", "\(text)")
            #expect(result.start == at(10, 16, 9), "\(text)")
            #expect(result.end == .timed(date(2026, 10, 16, 9).addingTimeInterval(TimeInterval(minutes * 60)), timeZone: zone), "\(text)")
        }
    }

    @Test func defaultLengthWhenNoneIsTyped() {
        #expect(parse("review fri 9am", defaultLength: 3600).end == at(10, 16, 10))
    }

    @Test func lengthIsIgnoredForAllDayEvents() {
        let result = parse("offsite fri 2h")
        #expect(result.title == "Offsite")
        #expect(result.start == allDay(10, 16))
        #expect(result.end == allDay(10, 17))
        #expect(result.tokens.map(\.role) == [.day, .length])
    }

    @Test func forWithoutALengthStaysInTheTitle() {
        #expect(parse("tickets for 2 fri").title == "Tickets for 2")
    }
}

@Suite("Quick add: guests")
struct QuickAddGuestTests {
    @Test func namesAfterWith() {
        let cases: [(String, [EmailAddress], [String], String)] = [
            ("lunch with jamie", [jamie], [], "Lunch with Jamie"),
            ("lunch with Jamie", [jamie], [], "Lunch with Jamie"),
            ("lunch with jamie and alex", [jamie, alex], [], "Lunch with Jamie and Alex"),
            ("lunch with jamie & alex", [jamie, alex], [], "Lunch with Jamie & Alex"),
            ("lunch with jamie, alex", [jamie, alex], [], "Lunch with Jamie, Alex"),
            ("lunch with jamie, alex, and sam", [jamie, alex], ["sam"], "Lunch with Jamie, Alex, and sam"),
            ("lunch with jamie and sam", [jamie], ["sam"], "Lunch with Jamie and sam"),
            ("lunch with jamie about the budget", [jamie], [], "Lunch with Jamie about the budget"),
            ("lunch with jamie: budget", [jamie], [], "Lunch with Jamie: budget"),
            ("lunch with the design team", [], ["the design team"], "Lunch with the design team"),
            ("lunch with jamie fri with alex", [jamie, alex], [], "Lunch with Jamie with Alex"),
            ("lunch with", [], [], "Lunch with"),
        ]
        for (text, guests, unknown, title) in cases {
            let result = parse(text)
            #expect(result.guests == guests, "\(text)")
            #expect(result.unknownGuests == unknown, "\(text)")
            #expect(result.title == title, "\(text)")
        }
    }

    @Test func contactsAreAskedOncePerName() {
        var asked: [String] = []
        let result = QuickAdd.parse("lunch with Jamie and alex and jamie fri", now: friday, calendar: pacific) { name in
            asked.append(name)
            return contacts(name)
        }
        #expect(asked == ["Jamie", "alex"])
        #expect(result.guests == [jamie, alex])

        asked = []
        let unknown = QuickAdd.parse("lunch with sam and Sam", now: friday, calendar: pacific) { name in
            asked.append(name)
            return contacts(name)
        }
        #expect(asked == ["sam"])
        #expect(unknown.unknownGuests == ["sam"])
    }

    @Test func emailAddressesAreGuests() {
        let call = parse("call bob@example.com tomorrow")
        #expect(call.guests == [bob])
        #expect(call.title == "Call")
        #expect(call.location == nil)
        let lunch = parse("lunch with jamie and bob@example.com")
        #expect(lunch.guests == [jamie, bob])
        #expect(lunch.title == "Lunch with Jamie and bob@example.com")
        let sync = parse("sync <ana@x.io>, jamie.chen@studio.co")
        #expect(sync.guests == [EmailAddress(email: "ana@x.io"), EmailAddress(email: "jamie.chen@studio.co")])
        #expect(sync.title == "Sync")
        #expect(parse("1:1 with jamie jamie.chen@studio.co").guests == [jamie])
    }
}

@Suite("Quick add: places, conference, calendar")
struct QuickAddPlaceTests {
    @Test func places() {
        let cases: [(String, String?, String, EventTime?)] = [
            ("lunch @ Tartine", "Tartine", "Lunch", nil),
            ("lunch @Tartine fri", "Tartine", "Lunch", allDay(10, 16)),
            ("drinks @ The Blue Bottle 6pm", "The Blue Bottle", "Drinks", at(10, 9, 18)),
            ("lunch @ Tartine, fri", "Tartine", "Lunch", allDay(10, 16)),
            ("lunch @ Tartine with jamie", "Tartine", "Lunch with Jamie", nil),
            ("brunch @ Sunday Café", "Sunday Café", "Brunch", nil),
            ("lunch @ 1pm", nil, "Lunch", at(10, 9, 13)),
            ("lunch @", nil, "Lunch @", nil),
        ]
        for (text, location, title, start) in cases {
            let result = parse(text)
            #expect(result.location == location, "\(text)")
            #expect(result.title == title, "\(text)")
            #expect(result.start == start, "\(text)")
        }
    }

    @Test func conferenceOnlyAsTheLastWord() {
        let cases: [(String, Bool, String)] = [
            ("sync meet", true, "Sync"),
            ("sync video", true, "Sync"),
            ("sync Meet", true, "Sync"),
            ("sync with jamie tue 3pm meet", true, "Sync with Jamie"),
            ("meet with jamie tue 3pm", false, "Meet with Jamie"),
            ("video call tomorrow", false, "Video call"),
            ("meet", false, "Meet"),
        ]
        for (text, conference, title) in cases {
            let result = parse(text)
            #expect(result.addConference == conference, "\(text)")
            #expect(result.title == title, "\(text)")
        }
    }

    @Test func calendarHint() {
        let review = parse("#work review mon 10-11:30")
        #expect(review.calendarHint == "work")
        #expect(review.title == "Review")
        #expect(review.start == at(10, 12, 10))
        #expect(review.end == at(10, 12, 11, 30))
        #expect(parse("standup #team-sync").calendarHint == "team-sync")
        let bug = parse("fix #1 bug")
        #expect(bug.calendarHint == nil)
        #expect(bug.title == "Fix #1 bug")
    }
}

@Suite("Quick add: repeats")
struct QuickAddRepeatTests {
    @Test func rules() {
        let cases: [(String, String, [String], EventTime?)] = [
            ("standup daily 9am", "Standup", ["RRULE:FREQ=DAILY"], at(10, 10, 9)),
            ("standup every day 9am", "Standup", ["RRULE:FREQ=DAILY"], at(10, 10, 9)),
            ("standup every weekday 9:30 15m", "Standup", ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"], at(10, 12, 9, 30)),
            ("1:1 weekly fri 2pm", "1:1", ["RRULE:FREQ=WEEKLY;BYDAY=FR"], at(10, 16, 14)),
            ("1:1 weekly 2pm", "1:1", ["RRULE:FREQ=WEEKLY;BYDAY=FR"], at(10, 9, 14)),
            ("1:1 every week on tue 2pm", "1:1", ["RRULE:FREQ=WEEKLY;BYDAY=TU"], at(10, 13, 14)),
            ("yoga every tue 6pm", "Yoga", ["RRULE:FREQ=WEEKLY;BYDAY=TU"], at(10, 13, 18)),
            ("yoga every tuesday", "Yoga", ["RRULE:FREQ=WEEKLY;BYDAY=TU"], allDay(10, 13)),
            ("yoga fri 6pm every tue", "Yoga", ["RRULE:FREQ=WEEKLY;BYDAY=TU"], at(10, 20, 18)),
            ("offsite oct 16-17 every mon", "Offsite", ["RRULE:FREQ=WEEKLY;BYDAY=MO"], allDay(10, 19)),
            ("gym every mon and wed 7am", "Gym", ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE"], at(10, 12, 7)),
            ("gym every wed, mon 7am", "Gym", ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE"], at(10, 12, 7)),
            ("review every 2 weeks mon 10am", "Review", ["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO"], at(10, 12, 10)),
            ("review every other week mon 10am", "Review", ["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO"], at(10, 12, 10)),
            ("review biweekly mon 10am", "Review", ["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO"], at(10, 12, 10)),
            ("review every other tue 10am", "Review", ["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU"], at(10, 13, 10)),
            ("rent monthly oct 16", "Rent", ["RRULE:FREQ=MONTHLY;BYMONTHDAY=16"], allDay(10, 16)),
            ("rent every month oct 16", "Rent", ["RRULE:FREQ=MONTHLY;BYMONTHDAY=16"], allDay(10, 16)),
            ("water plants every 3 days 8am", "Water plants", ["RRULE:FREQ=DAILY;INTERVAL=3"], at(10, 10, 8)),
            ("birthday yearly oct 16", "Birthday", ["RRULE:FREQ=YEARLY"], allDay(10, 16)),
            ("birthday annually oct 16", "Birthday", ["RRULE:FREQ=YEARLY"], allDay(10, 16)),
            ("standup daily", "Standup", ["RRULE:FREQ=DAILY"], nil),
            ("sync weekly", "Sync", ["RRULE:FREQ=WEEKLY"], nil),
        ]
        for (text, title, recurrence, start) in cases {
            let result = parse(text)
            #expect(result.title == title, "\(text)")
            #expect(result.recurrence == recurrence, "\(text)")
            #expect(result.start == start, "\(text)")
        }
    }

    @Test func untilAndCount() {
        let cases: [(String, [String])] = [
            ("standup daily 9am until oct 30", ["RRULE:FREQ=DAILY;UNTIL=20261031T065959Z"]),
            ("standup daily 9am until 11/20", ["RRULE:FREQ=DAILY;UNTIL=20261121T075959Z"]),
            ("trash every tue until dec 15", ["RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261215"]),
            ("class every tue 6pm x8", ["RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=8"]),
            ("class every tue 6pm 8 times", ["RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=8"]),
        ]
        for (text, recurrence) in cases {
            let result = parse(text)
            #expect(result.recurrence == recurrence, "\(text)")
            #expect(["Standup", "Trash", "Class"].contains(result.title), "\(text)")
        }
    }

    @Test func untilAndCountNeedARepeat() {
        let away = parse("ooo until fri")
        #expect(away.recurrence.isEmpty)
        #expect(away.start == nil)
        #expect(away.title == "Ooo until fri")
        let pushups = parse("pushups x8 fri")
        #expect(pushups.recurrence.isEmpty)
        #expect(pushups.title == "Pushups x8")
    }

    @Test func aNamedWeekdayStartsTodayWhenTheTimeIsStillAhead() {
        let tuesday = date(2026, 10, 13, 10)
        #expect(parse("yoga every tue 6pm", now: tuesday).start == at(10, 13, 18))
        #expect(parse("yoga every tue 9am", now: tuesday).start == at(10, 20, 9))
    }
}

@Suite("Quick add: titles and tokens")
struct QuickAddTitleTests {
    @Test func tokenOffsets() {
        let result = parse("lunch with jamie fri 12:30 1h @ Tartine")
        #expect(result.title == "Lunch with Jamie")
        #expect(result.start == at(10, 16, 12, 30))
        #expect(result.end == at(10, 16, 13, 30))
        #expect(result.guests == [jamie])
        #expect(result.location == "Tartine")
        #expect(result.hasTime)
        #expect(result.tokens == [
            QuickAdd.Token(role: .guest, start: 11, end: 16),
            QuickAdd.Token(role: .day, start: 17, end: 20),
            QuickAdd.Token(role: .time, start: 21, end: 26),
            QuickAdd.Token(role: .length, start: 27, end: 29),
            QuickAdd.Token(role: .place, start: 30, end: 39),
        ])
    }

    @Test func tokensIncludeTheirLeadingWords() {
        let result = parse("call at 3 for 1h on fri")
        #expect(result.title == "Call")
        #expect(result.start == at(10, 16, 15))
        #expect(result.end == at(10, 16, 16))
        #expect(result.tokens == [
            QuickAdd.Token(role: .time, start: 5, end: 9),
            QuickAdd.Token(role: .length, start: 10, end: 16),
            QuickAdd.Token(role: .day, start: 17, end: 23),
        ])
        let repeats = parse("#work standup every weekday until oct 30 meet")
        #expect(repeats.tokens.map(\.role) == [.calendar, .repeats, .repeats, .conference])
    }

    @Test func trickyLines() {
        let lunch = parse("lunch for 2 at noon")
        #expect(lunch.title == "Lunch for 2")
        #expect(lunch.start == at(10, 9, 12))
        #expect(lunch.end == at(10, 9, 12, 30))

        let meet = parse("meet with jamie tue 3pm")
        #expect(meet.title == "Meet with Jamie")
        #expect(meet.start == at(10, 13, 15))
        #expect(meet.guests == [jamie])
        #expect(!meet.addConference)

        let standup = parse("standup every weekday 9:30 15m")
        #expect(standup.title == "Standup")
        #expect(standup.start == at(10, 12, 9, 30))
        #expect(standup.end == at(10, 12, 9, 45))
        #expect(standup.recurrence == ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"])

        let planning = parse("q4 planning oct 16-18")
        #expect(planning.title == "Q4 planning")
        #expect(planning.start == allDay(10, 16))
        #expect(planning.end == allDay(10, 19))

        let call = parse("call bob@example.com tomorrow 4pm meet")
        #expect(call.title == "Call")
        #expect(call.guests == [bob])
        #expect(call.start == at(10, 10, 16))
        #expect(call.end == at(10, 10, 16, 30))
        #expect(call.addConference)

        let review = parse("#work review mon 10-11:30")
        #expect(review.title == "Review")
        #expect(review.calendarHint == "work")
        #expect(review.start == at(10, 12, 10))
        #expect(review.end == at(10, 12, 11, 30))
    }

    @Test func titles() {
        let cases: [(String, String)] = [
            ("", "(no title)"),
            ("   ", "(no title)"),
            ("\n\t", "(no title)"),
            ("fri 3pm", "(no title)"),
            ("  lunch   with  jamie  ", "Lunch with Jamie"),
            ("lunch, fri", "Lunch"),
            ("(fri) planning", "Planning"),
            ("1:1 with alex", "1:1 with Alex"),
            ("🎉 party fri 8pm", "🎉 Party"),
            ("🎉", "🎉"),
            ("über sync", "Über sync"),
        ]
        for (text, title) in cases {
            #expect(parse(text).title == title, "\(text)")
        }
    }

    @Test func emptyLines() {
        for text in ["", "   ", "\n\t"] {
            #expect(parse(text) == QuickAdd.Result(title: "(no title)"), "\(text)")
            #expect(!parse(text).hasTime)
        }
    }

    @Test func longLines() {
        let long = String(repeating: "lunch ", count: 5_000) + "fri 9am"
        let result = parse(long)
        #expect(result.start == at(10, 16, 9))
        #expect(result.title.hasPrefix("Lunch lunch"))
        expectWellFormed(result, long)
        let ons = String(repeating: "on ", count: 10_000) + "fri"
        #expect(parse(ons).start == allDay(10, 16))
        let withs = String(repeating: "with jamie and ", count: 2_000)
        expectWellFormed(parse(withs), withs)
        let crowd = "party with " + (0..<3_000).map { "guest\($0)" }.joined(separator: " and ")
        #expect(parse(crowd).unknownGuests.count == 3_000)
    }

    @Test func noiseNeverBreaks() {
        let noise = [
            "@", "@@", "#", "##", "-", "–", "—", "--", "@ @ @", "with with with", "every", "every other", "every 0 weeks",
            "99999999999999999999h", "x99999999999999999999", "every 99999999999 weeks", "in 99999999999 days", "at 99:99",
            "25:00", "0/0", "1/1/1/1", "2026-02-30", "12am-12am", "11pm-11pm", "for", "for for 1h", "in", "next", "next next tue",
            "until", "until until", "daily until", "daily x0", "all", "all -", "1.2.3h", ".h", "1..5h", "nan h", "inf h", "1e9m",
            "Ω≈ç√∫", "👩‍👩‍👧‍👦 with 🎉 @ 🏠", "\u{0}", "a\u{301} fri", "١٢:٣٠", "١٢pm", "tom tom tom", "with tom and tom", ",,,",
            "@-", "-@", "#-", "with ,", "every mon and", "every mon,", "oct", "oct -", "16-", "-16 oct", "fri-", "-fri",
            "9999-99-99", "0000-01-01", "dec 31 9999 - jan 1", "at 0", "00:00-00:00", "every 999 years until dec 31 9999 x9",
        ]
        for text in noise { expectWellFormed(parse(text), text) }
    }

    @Test func randomLinesNeverBreak() {
        let vocabulary = [
            "lunch", "with", "jamie", "and", "alex", ",", "fri", "tom", "tomorrow", "next", "on", "at", "@", "3", "9-10", "2pm", "to",
            "-", "–", "noon", "midnight", "1h", "for", "30m", "oct", "16", "16-18", "10/16", "2026-10-16", "in", "3d", "every", "tue",
            "other", "2", "weeks", "daily", "until", "x8", "times", "meet", "video", "#work", "bob@example.com", "all", "day",
            "tonight", "🎉", "(", ")", "the", "about", "pm", "am", ":", "1:1",
        ]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for _ in 0..<3_000 {
            let separator = next(4) == 0 ? "" : " "
            let text = (0..<next(12)).map { _ in vocabulary[next(vocabulary.count)] }.joined(separator: separator)
            expectWellFormed(parse(text), text)
        }
    }
}

@Suite("Quick add: When text")
struct QuickAddTextTests {
    private func text(_ start: EventTime, _ end: EventTime, now: Date = friday) -> String {
        QuickAdd.text(start: start, end: end, now: now, calendar: pacific)
    }

    @Test func timedEventsOnOneDay() {
        #expect(text(at(10, 12, 14), at(10, 12, 14, 45)) == "oct 12 14:00-14:45")
        #expect(text(at(10, 9, 9, 5), at(10, 9, 10)) == "oct 9 09:05-10:00")
        #expect(text(at(10, 9, 22), at(10, 10, 2)) == "oct 9 22:00-02:00")
        #expect(text(at(10, 9, 23), at(10, 10, 0)) == "oct 9 23:00-00:00")
        #expect(text(at(10, 9, 3), at(10, 9, 4)) == "oct 9 03:00-04:00")
    }

    @Test func theYearIsAddedWhenTheDateAloneReadsAsAnotherYear() {
        #expect(text(at(10, 1, 9), at(10, 1, 10)) == "oct 1 2026 09:00-10:00")
        #expect(text(at(6, 12, 16), at(6, 12, 16, 30)) == "jun 12 2026 16:00-16:30")
        #expect(text(at(6, 12, 16, year: 2027), at(6, 12, 16, 30, year: 2027)) == "jun 12 16:00-16:30")
        #expect(text(at(10, 12, 9, year: 2027), at(10, 12, 10, year: 2027)) == "oct 12 2027 09:00-10:00")
        #expect(text(allDay(2, 29, year: 2028), allDay(3, 1, year: 2028)) == "feb 29 2028 all day")
        // Today, already started.
        #expect(text(at(10, 9, 8), at(10, 9, 9)) == "oct 9 08:00-09:00")
    }

    @Test func allDayEvents() {
        #expect(text(allDay(10, 16), allDay(10, 17)) == "oct 16 all day")
        #expect(text(allDay(10, 16), allDay(10, 19)) == "oct 16-18")
        #expect(text(allDay(10, 30), allDay(11, 3)) == "oct 30 - nov 2")
        #expect(text(allDay(12, 30), allDay(1, 3, year: 2027)) == "dec 30 - jan 2")
        #expect(text(allDay(10, 16, year: 2027), allDay(10, 19, year: 2027)) == "oct 16-18 2027")
        #expect(text(allDay(10, 1), allDay(10, 4)) == "oct 1-3 2026")
        #expect(text(allDay(9, 30), allDay(10, 12)) == "sep 30 2026 - oct 11 2026")
    }

    @Test func eventsOverSeveralDays() {
        #expect(text(at(10, 12, 9), at(10, 14, 17)) == "oct 12-14 09:00-17:00")
        #expect(text(at(10, 30, 9), at(11, 2, 17)) == "oct 30 - nov 2 09:00-17:00")
        #expect(text(at(10, 12, 10), at(10, 14, 10)) == "oct 12 10:00 48h")
        #expect(text(at(10, 12, 22), at(10, 14, 2)) == "oct 12 22:00 28h")
        #expect(text(at(10, 12, 10), at(10, 13, 10)) == "oct 12 10:00 24h")
        #expect(text(at(10, 12, 10), at(10, 13, 11, 30)) == "oct 12-13 10:00-11:30")
    }

    @Test func theYearAfterARangeOfDays() {
        #expect(parse("trip oct 16-18 2027").start == allDay(10, 16, year: 2027))
        #expect(parse("trip oct 16-18 2027").end == allDay(10, 19, year: 2027))
        #expect(parse("trip oct 16-18 2027").title == "Trip")
        #expect(parse("trip oct 16 2027-18").end == allDay(10, 19, year: 2027))
    }

    @Test func everyTextReadsBackAsTheSameTimes() {
        let calendar = pacific
        /// A wall time that happens twice (when clocks go back) reads as the first: those are skipped.
        func unambiguous(_ date: Date) -> Bool {
            calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)) == date
        }
        var start = date(2026, 1, 1)
        let stop = date(2027, 9, 1)
        let lengths = [15, 60, 95, 24 * 60, 26 * 60 + 30, 3 * 24 * 60 - 60, 7 * 24 * 60]
        while start < stop {
            for (index, minutes) in lengths.enumerated() {
                let begin = start.addingTimeInterval(TimeInterval(index * 17 * 60))
                let finish = begin.addingTimeInterval(TimeInterval(minutes * 60))
                guard unambiguous(begin), unambiguous(finish) else { continue }
                let written = text(.timed(begin, timeZone: zone), .timed(finish, timeZone: zone))
                let read = parse(written)
                #expect(read.start == .timed(begin, timeZone: zone) && read.end == .timed(finish, timeZone: zone) && read.title == "(no title)",
                        "\(written) for \(begin)-\(finish)")
            }
            start = start.addingTimeInterval(13 * 3600 + 17 * 60)
        }
        var day = DayDate(year: 2026, month: 1, day: 1)
        while day < DayDate(year: 2027, month: 12, day: 31) {
            for span in [1, 2, 5, 40] {
                let after = day.adding(days: span, in: calendar)
                let written = text(.allDay(day), .allDay(after))
                let read = parse(written)
                #expect(read.start == .allDay(day) && read.end == .allDay(after) && read.title == "(no title)", "\(written) for \(day)")
            }
            day = day.adding(days: 3, in: calendar)
        }
    }
}

@Suite("Quick add: Repeats text")
struct QuickAddRepeatTextTests {
    private func text(_ recurrence: [String], start: EventTime = at(10, 12, 10)) -> (text: String, exact: Bool) {
        QuickAdd.repeatText(recurrence, start: start, now: friday, calendar: pacific)
    }

    @Test func rulesTheWordsCanSayReadBackExactly() {
        #expect(text(["RRULE:FREQ=WEEKLY;BYDAY=MO,WE"]) == ("every mon and wed", true))
        #expect(text(["RRULE:FREQ=WEEKLY"]) == ("weekly", true))
        #expect(text(["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"]) == ("every weekday", true))
        #expect(text(["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU"], start: at(10, 13, 10)) == ("every other tue", true))
        #expect(text(["RRULE:FREQ=DAILY;INTERVAL=3"]) == ("every 3 days", true))
        #expect(text(["RRULE:FREQ=DAILY;COUNT=5"]) == ("daily x5", true))
        #expect(text(["RRULE:FREQ=MONTHLY"]) == ("monthly", true))
        #expect(text(["RRULE:FREQ=MONTHLY;BYMONTHDAY=12"]) == ("monthly", true))
        #expect(text(["RRULE:FREQ=YEARLY"]) == ("yearly", true))
        #expect(text(["RRULE:FREQ=WEEKLY;BYDAY=MO", "EXDATE;TZID=America/Los_Angeles:20261019T100000"]) == ("every mon", true))
        #expect(text([]) == ("", true))
    }

    @Test func anEndIsKeptWhateverFormItWasWrittenIn() {
        #expect(text(["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261219T075959Z"]) == ("every mon until dec 18 2026", true))
        // Google's own form: the end of that day in UTC.
        #expect(text(["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261218T235959Z"]) == ("every mon until dec 18 2026", true))
    }

    @Test func rulesTheWordsCannotSayAreNotEdited() {
        let second = text(["RRULE:FREQ=MONTHLY;BYDAY=2TU"], start: at(10, 13, 10))
        #expect(second.exact == false)
        #expect(!second.text.isEmpty)
        #expect(text(["RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"]).exact == false)
        #expect(text(["RRULE:FREQ=WEEKLY;BYDAY=MO", "RRULE:FREQ=WEEKLY;BYDAY=FR"]).exact == false)
        // A Sunday week start moves "every other sun and mon": the words cannot keep it.
        #expect(text(["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=SU"], start: at(10, 11, 10)).exact == false)
        #expect(text(["RRULE:FREQ=WEEKLY;BYDAY=SU,MO;WKST=SU"], start: at(10, 11, 10)).exact == true)
    }

    @Test func untilCountsFromTodayNotFromTheSeriesFirstDay() {
        // A series that began in November 2025, edited on Friday Oct 9 2026: "until dec 18" is this December.
        let rule = QuickAdd.repeatRule("every mon until dec 18", start: at(11, 3, 9, year: 2025), now: friday, calendar: pacific)
        #expect(rule == "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261219T075959Z")
        #expect(QuickAdd.repeatRule("weekly", start: at(11, 3, 9, year: 2025), now: friday, calendar: pacific) == "RRULE:FREQ=WEEKLY;BYDAY=MO")
        #expect(QuickAdd.repeatRule("monthly", start: allDay(10, 16), now: friday, calendar: pacific) == "RRULE:FREQ=MONTHLY;BYMONTHDAY=16")
        #expect(QuickAdd.repeatRule("not a repeat", start: allDay(10, 16), now: friday, calendar: pacific) == nil)
    }

    @Test func descriptionsBecomeEditableTextWithTheirLinks() {
        let html = #"Agenda in <a href="https://docs.example.com/abc">the doc</a><br>Bring notes"#
        #expect(HTMLText.editableText(html).contains("the doc (https://docs.example.com/abc)"))
        #expect(HTMLText.editableText(html).contains("Bring notes"))
        #expect(HTMLText.editableText("Budget < 5k, bring laptop") == "Budget < 5k, bring laptop")
        #expect(HTMLText.editableText("call Alex <alex@example.com> first") == "call Alex <alex@example.com> first")
        // In HTML too: addresses in angle brackets, a bare "<", single-quoted links.
        let mixed = "<b>Agenda</b><br>Contact <b.smith@corp.com><br>Budget < 5k<br><a href='https://docs.example.com/x'>notes</a>"
        let text = HTMLText.editableText(mixed)
        #expect(text.contains("Contact <b.smith@corp.com>"))
        #expect(text.contains("Budget < 5k"))
        #expect(text.contains("notes (https://docs.example.com/x)"))
    }
}
