import Foundation
import Testing
@testable import MailCore

/// The text with CRLF line endings, as calendars send it.
private func crlf(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\r\n") }

/// An instant written in ISO 8601 (the distant past for a typo, which fails the comparison).
private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text) ?? .distantPast }

private func zone(_ identifier: String) -> TimeZone { TimeZone(identifier: identifier) ?? .gmt }

/// A one-event file: `lines` inside the VEVENT, `before` between BEGIN:VCALENDAR and the event.
private func event(_ lines: String, before: String = "", defaultTimeZone: TimeZone = .gmt) -> Invitation? {
    let text = "BEGIN:VCALENDAR\n\(before)BEGIN:VEVENT\nUID:test@vimail\n\(lines)\nEND:VEVENT\nEND:VCALENDAR\n"
    return ICalendar.invitations(from: text, defaultTimeZone: defaultTimeZone).first
}

@Suite("iCalendar invitations")
struct ICalendarInvitationTests {
    let pacific = "America/Los_Angeles"

    @Test func googleInvitation() throws {
        let invitations = ICalendar.invitations(from: Fixture.googleInvitation, defaultTimeZone: zone("Europe/Berlin"))
        let invitation = try #require(invitations.first)
        let start = utc("2026-10-12T21:00:00Z"), end = utc("2026-10-12T21:45:00Z"), stamp = utc("2026-10-09T17:15:02Z")
        #expect(invitations.count == 1)
        #expect(invitation.method == .request)
        #expect(invitation.uid == "5qv2l8mbd0e4k1h7r3n9s6t2pu@google.com")
        #expect(invitation.sequence == 0)
        #expect(invitation.summary == "Q4 launch review")
        #expect(invitation.start == .timed(start, timeZone: pacific))
        #expect(invitation.end == .timed(end, timeZone: pacific))
        #expect(invitation.status == .confirmed)
        #expect(invitation.stamp == stamp)
        #expect(invitation.location == nil)
        #expect(invitation.recurrence.isEmpty && invitation.recurrenceID == nil)
        #expect(invitation.conferenceURL == "https://meet.google.com/abc-defg-hij")
        // Google's Meet block is gone; the alarm's DESCRIPTION did not leak in.
        #expect(invitation.details == "Agenda: walk through the Q4 launch plan, then open questions.")
        #expect(invitation.organizer == Attendee(email: "jamie.chen@studio.co", name: "Jamie Chen", response: .accepted, isOrganizer: true))
        #expect(invitation.attendees == [
            Attendee(email: "jamie.chen@studio.co", name: "Jamie Chen", response: .accepted, isOrganizer: true),
            Attendee(email: "sam@hey.com"),
            Attendee(email: "nina@fastmail.com", name: "Nina Park", response: .tentative, isOptional: true, comment: "Might be 5 minutes late"),
            Attendee(email: "c_1888a2b4c6d8e0f2@resource.calendar.google.com", name: "Studio-4-Fishbowl (6)", response: .accepted, isResource: true),
        ])
        #expect(!invitation.attendees.contains { $0.isSelf })
        #expect(invitation.attendee(matching: ["sam@hey.com"])?.response == .needsAction)
    }

    @Test func googleSeriesAndException() throws {
        let invitations = ICalendar.invitations(from: Fixture.googleSeries)
        try #require(invitations.count == 2)
        let series = invitations[0], moved = invitations[1]
        #expect(series.uid == "1mt8c4k2v6b9n3q7r5s0w2x4yz@google.com" && moved.uid == series.uid)
        #expect(series.start == .timed(utc("2026-10-12T16:00:00Z"), timeZone: pacific))
        #expect(series.recurrenceID == nil)
        #expect(series.recurrence == [
            "RRULE:FREQ=WEEKLY;BYDAY=MO",
            "EXDATE;TZID=America/Los_Angeles:20261026T090000",
            "EXDATE;TZID=America/Los_Angeles:20261109T090000,20261116T090000",
        ])
        #expect(series.details == "Fifteen minutes, cameras optional.")
        #expect(moved.recurrenceID == .timed(utc("2026-10-19T16:00:00Z"), timeZone: pacific))
        #expect(moved.start == .timed(utc("2026-10-20T17:00:00Z"), timeZone: pacific))
        #expect(moved.sequence == 1)
        #expect(moved.summary == "Weekly standup (Tuesday this week)")
        #expect(moved.recurrence.isEmpty && moved.details == nil)
    }

    @Test func outlookInvitation() throws {
        let invitation = try #require(ICalendar.invitations(from: Fixture.outlookInvitation).first)
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjM4ZTRiYTYtZjU1Ny00%40thread.v2/0"
        #expect(invitation.method == .request)
        #expect(invitation.sequence == 1)
        #expect(invitation.summary == "Vendor contract sync")
        #expect(invitation.start == .timed(utc("2026-10-14T16:00:00Z"), timeZone: pacific))
        #expect(invitation.end == .timed(utc("2026-10-14T16:30:00Z"), timeZone: pacific))
        #expect(invitation.recurrence == [
            "RRULE:FREQ=WEEKLY;UNTIL=20261216T170000Z;INTERVAL=1;BYDAY=WE;WKST=SU",
            "EXDATE;TZID=America/Los_Angeles:20261028T090000",
        ])
        #expect(invitation.organizer == Attendee(email: "jamie.chen@contoso.com", name: "Chen, Jamie", response: .accepted, isOrganizer: true))
        #expect(invitation.attendees.map(\.name) == ["Sam Carter", "Ortiz, Ben", "Conf Room 12 (Seattle)"])
        #expect(invitation.attendees.map(\.isOptional) == [false, true, false])
        #expect(invitation.attendees.map(\.isResource) == [false, false, true])
        #expect(invitation.location == "Microsoft Teams Meeting " + teams)
        #expect(invitation.conferenceURL == teams)
        #expect(invitation.details?.hasPrefix("Weekly vendor sync. Bring the contract redlines.\n\n_____") == true)
        #expect(invitation.details?.contains("Join on your computer, mobile app or room device") == true)
        #expect(invitation.stamp == utc("2026-10-09T16:04:17Z"))
    }

    @Test func appleAllDayInvitation() throws {
        let invitation = try #require(ICalendar.invitations(from: Fixture.appleAllDay).first)
        #expect(invitation.uid == "2D5E8B1C-3F4A-4B6D-9E7F-1A2B3C4D5E6F")
        #expect(invitation.start == .allDay(DayDate(year: 2026, month: 10, day: 12)))
        #expect(invitation.end == .allDay(DayDate(year: 2026, month: 10, day: 13)))
        #expect(invitation.location == "Ferry Building\n1 Ferry Building, San Francisco, CA 94111")
        #expect(invitation.organizer == Attendee(email: "alex@studio.co", name: "Alex Morgan", response: .accepted, isOrganizer: true))
        // Sam's entry is a urn:uuid: address with the email in its EMAIL parameter.
        #expect(invitation.attendees.map(\.email) == ["alex@studio.co", "sam@hey.com"])
        #expect(invitation.attendees.map(\.isOrganizer) == [true, false])
        #expect(invitation.attendees.map(\.response) == [.accepted, .needsAction])
        #expect(invitation.conferenceURL == nil && invitation.details == nil)
    }

    @Test func cancellation() throws {
        let invitation = try #require(ICalendar.invitations(from: Fixture.cancellation).first)
        #expect(invitation.method == .cancel)
        #expect(invitation.status == .cancelled)
        #expect(invitation.sequence == 2)
        #expect(invitation.isCancellation)
        #expect(invitation.start == .timed(utc("2026-10-15T17:00:00Z"), timeZone: nil))
        #expect(invitation.summary == "1:1 Jamie / Sam")
    }

    @Test func replyFromAGuest() throws {
        let invitation = try #require(ICalendar.invitations(from: Fixture.outlookReply).first)
        #expect(invitation.method == .reply)
        #expect(invitation.uid == "5qv2l8mbd0e4k1h7r3n9s6t2pu@google.com")
        #expect(invitation.attendees == [Attendee(email: "ben.ortiz@contoso.com", name: "Ben Ortiz", response: .declined, comment: "Out that week, sorry!")])
        #expect(invitation.organizer == Attendee(email: "jamie.chen@studio.co", response: .accepted, isOrganizer: true))
        #expect(invitation.start == .timed(utc("2026-10-12T21:00:00Z"), timeZone: pacific))
    }
}

@Suite("iCalendar syntax")
struct ICalendarSyntaxTests {
    @Test func unfoldsCRLFAndLFLinesFoldedWithSpacesOrTabs() {
        let text = "\u{FEFF}BEGIN:VCALENDAR\nBEGIN:VEVENT\r\nUID:fold\r\n s@vimail\nDTSTART:20261012T090000Z\nSUMMARY:A long\n\t title that\r\n  keeps its spaces\r\nEND:VEVENT\nEND:VCALENDAR"
        let invitation = ICalendar.invitations(from: text).first
        #expect(invitation?.uid == "folds@vimail")
        #expect(invitation?.summary == "A long title that keeps its spaces")
    }

    @Test func bytesAreUnfoldedBeforeDecoding() {
        let accent = Array("é".utf8)
        let bytes = Array("BEGIN:VEVENT\r\nUID:utf8\r\nDTSTART:20261012T090000Z\r\nSUMMARY:Caf".utf8) + [accent[0]]
            + Array("\r\n ".utf8) + [accent[1]] + Array(" au lait\r\nEND:VEVENT\r\n".utf8)
        #expect(ICalendar.invitations(from: Data(bytes)).first?.summary == "Café au lait")
        #expect(ICalendar.invitations(from: Data([0xEF, 0xBB, 0xBF] + Array(Fixture.cancellation.utf8))).first?.uid == "0a9b8c7d6e5f4g3h2i1j@google.com")
        #expect(ICalendar.invitations(from: Fixture.cancellation.data(using: .utf16) ?? Data()).first?.uid == "0a9b8c7d6e5f4g3h2i1j@google.com")
    }

    @Test func filesThatAreNotUTF8ReadAsWindows1252() {
        let bytes = Array("BEGIN:VEVENT\r\nUID:latin\r\nDTSTART:20261012T090000Z\r\nSUMMARY:Caf".utf8) + [0xE9] + Array("\r\nEND:VEVENT\r\n".utf8)
        #expect(ICalendar.invitations(from: Data(bytes)).first?.summary == "Café")
    }

    @Test func parametersAreQuotedAndCaseInsensitive() throws {
        let invitation = try #require(event("""
            dtstart;tzid="America/New_York":20261012T090000
            organizer;cn="Chen, Jamie; PM: Ops";sent-by="mailto:assistant@studio.co":MAILTO:Jamie.Chen@Studio.co
            attendee;role=opt-participant;partstat=accepted;cn="Pat ^'PJ^' O'Neil":Mailto:pat@studio.co
            Attendee;CUTYPE=room;CN=Plain, unquoted:mailto:room@studio.co
            ATTENDEE;PARTSTAT=ACCEPTED:mailto:jamie.chen@studio.co
            """))
        #expect(invitation.start == .timed(utc("2026-10-12T13:00:00Z"), timeZone: "America/New_York"))
        #expect(invitation.organizer?.name == "Chen, Jamie; PM: Ops")
        #expect(invitation.organizer?.email == "Jamie.Chen@Studio.co")
        #expect(invitation.attendees.count == 3)
        #expect(invitation.attendees.first == Attendee(email: "pat@studio.co", name: "Pat \"PJ\" O'Neil", response: .accepted, isOptional: true))
        #expect(invitation.attendees.dropFirst().first?.name == "Plain, unquoted")
        #expect(invitation.attendees.dropFirst().first?.isResource == true)
        // The organizer is matched to their guest entry regardless of case, and borrows its name.
        #expect(invitation.attendees.last == Attendee(email: "jamie.chen@studio.co", name: "Chen, Jamie; PM: Ops", response: .accepted, isOrganizer: true))
    }

    @Test func textIsUnescaped() throws {
        let invitation = try #require(event(#"""
            DTSTART:20261012T090000Z
            SUMMARY:Budget\, plan\; and \\ backslash
            DESCRIPTION:Line one\nLine two\NLine three\, done. C:\Users stays.
            LOCATION:Room 4\;5
            """#))
        #expect(invitation.summary == #"Budget, plan; and \ backslash"#)
        #expect(invitation.details == "Line one\nLine two\nLine three, done. C:\\Users stays.")
        #expect(invitation.location == "Room 4;5")
    }

    @Test func methodComesFromEachCalendar() {
        func method(_ line: String) -> Invitation.Method? {
            ICalendar.invitations(from: "BEGIN:VCALENDAR\n\(line)\nBEGIN:VEVENT\nUID:m\nDTSTART:20261012T090000Z\nEND:VEVENT\nEND:VCALENDAR").first?.method
        }
        #expect(method("METHOD:REQUEST") == .request)
        #expect(method("method:counter") == .counter)
        #expect(method("METHOD:DECLINECOUNTER") == .declineCounter)
        #expect(method("METHOD:X-SOMETHING-NEW") == .publish)
        #expect(method("X-WR-CALNAME:Work") == .publish)

        let two = "BEGIN:VCALENDAR\nMETHOD:CANCEL\nBEGIN:VEVENT\nUID:a\nDTSTART:20261012T090000Z\nEND:VEVENT\nEND:VCALENDAR\n"
            + "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:b\nDTSTART:20261012T090000Z\nEND:VEVENT\nEND:VCALENDAR\n"
        #expect(ICalendar.invitations(from: two).map(\.method) == [.cancel, .publish])
    }

    @Test func eventsNeedAUIDAndAStart() {
        let text = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            DTSTART:20261012T090000Z
            SUMMARY:No UID
            END:VEVENT
            BEGIN:VEVENT
            UID:
            DTSTART:20261012T090000Z
            END:VEVENT
            BEGIN:VEVENT
            UID:no-start
            SUMMARY:No start
            END:VEVENT
            BEGIN:VEVENT
            UID:bare
            DTSTART:20261012T090000Z
            END:VEVENT
            END:VCALENDAR
            """
        let invitations = ICalendar.invitations(from: text)
        #expect(invitations.map(\.uid) == ["bare"])
        #expect(invitations.first?.summary == "(no title)")
        #expect(invitations.first?.sequence == 0)
        #expect(invitations.first?.end == nil)
        #expect(invitations.first?.status == nil && invitations.first?.organizer == nil && invitations.first?.stamp == nil)
    }

    @Test func alarmsAndOtherComponentsStayOutOfEvents() {
        let text = """
            BEGIN:VCALENDAR
            BEGIN:VTODO
            UID:todo
            DTSTART:20261011T090000Z
            END:VTODO
            BEGIN:VEVENT
            UID:dentist
            DTSTART:20261012T090000Z
            BEGIN:VALARM
            ACTION:EMAIL
            SUMMARY:Alarm summary
            DESCRIPTION:Alarm text
            ATTENDEE:mailto:alarm@studio.co
            TRIGGER:-PT30M
            END:VALARM
            SUMMARY:Dentist
            DESCRIPTION:Bring the forms.
            END:VEVENT
            BEGIN:VJOURNAL
            UID:journal
            DTSTART:20261012T090000Z
            END:VJOURNAL
            END:VCALENDAR
            """
        let invitations = ICalendar.invitations(from: text)
        #expect(invitations.map(\.uid) == ["dentist"])
        #expect(invitations.first?.summary == "Dentist")
        #expect(invitations.first?.details == "Bring the forms.")
        #expect(invitations.first?.attendees.isEmpty == true)
    }

    @Test func conferenceLinksFromLocationThenDescription() {
        #expect(event("DTSTART:20261012T090000Z\nLOCATION:Zoom (https://us02web.zoom.us/j/8812345678?pwd=abc).")?.conferenceURL == "https://us02web.zoom.us/j/8812345678?pwd=abc")
        #expect(event("DTSTART:20261012T090000Z\nLOCATION:Room 4\nDESCRIPTION:Docs: https://example.com/doc\\nJoin: https://acme.webex.com/meet/jamie")?.conferenceURL == "https://acme.webex.com/meet/jamie")
        #expect(event("DTSTART:20261012T090000Z\nDESCRIPTION:Plain http://meet.google.com/abc and https://notzoom.us/j/1")?.conferenceURL == nil)
    }

    @Test func googleBoilerplateIsRemovedFromDetails() {
        let marker = "-::~:~::~" + String(repeating: ":~", count: 40) + "::~:~::-"
        let block = "\(marker)\\nJoin with Google Meet: https://meet.google.com/abc-defg-hij\\n\\nPlease do not edit this section.\\n\(marker)"
        #expect(event("DTSTART:20261012T090000Z\nDESCRIPTION:\(block)")?.details == nil)
        #expect(event("DTSTART:20261012T090000Z\nDESCRIPTION:\(block)")?.conferenceURL == "https://meet.google.com/abc-defg-hij")
        #expect(event("DTSTART:20261012T090000Z\nDESCRIPTION:Before\\n\\n\(block)\\n\\nAfter")?.details == "Before\n\nAfter")
        // A block that never closes runs to the end.
        #expect(event("DTSTART:20261012T090000Z\nDESCRIPTION:Notes\\n\(marker)\\nJoin with Google Meet")?.details == "Notes")
    }

    @Test func emptyAndGarbageInputGiveNoInvitations() {
        #expect(ICalendar.invitations(from: "").isEmpty)
        #expect(ICalendar.invitations(from: Data()).isEmpty)
        #expect(ICalendar.invitations(from: "Not a calendar.\n\n:::;;;\n;:\nBEGIN:\nEND:\nEND:VEVENT\n\t\n").isEmpty)
        #expect(ICalendar.invitations(from: Data([0xFF, 0x00, 0xC3, 0x28, 0x0D, 0x0A, 0x20, 0x0D])).isEmpty)
    }

    @Test func missingEndLinesStillCloseEvents() {
        let text = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            BEGIN:VEVENT
            UID:first
            DTSTART:20261012T090000Z
            BEGIN:VALARM
            TRIGGER:-PT5M
            BEGIN:VEVENT
            UID:second
            DTSTART:20261013T090000Z
            SUMMARY:Second
            """
        let invitations = ICalendar.invitations(from: text)
        #expect(invitations.map(\.uid) == ["first", "second"])
        #expect(invitations.map(\.method) == [.request, .request])
        #expect(invitations.map(\.summary) == ["(no title)", "Second"])
    }

    @Test func malformedLinesAreSkipped() throws {
        let invitation = try #require(event("""
            this line has no colon
            ;also:nothing
            DTSTART:20261012T090000Z
            DTEND:20261012
            SEQUENCE:many
            STATUS:MAYBE
            DURATION:PT99999999999999999999H
            ATTENDEE;CN="Unclosed quote:mailto:quote@studio.co
            ATTENDEE:mailto:
            ATTENDEE:urn:uuid:no-address
            ATTENDEE;PARTSTAT=SOMETHING-NEW:mailto:new@studio.co
            """))
        #expect(invitation.end == nil)
        #expect(invitation.sequence == 0)
        #expect(invitation.status == nil)
        #expect(invitation.attendees.map(\.email) == ["quote@studio.co", "new@studio.co"])
        #expect(invitation.attendees.last?.response == .needsAction)
    }

    @Test func truncatedFilesNeverCrash() throws {
        let data = Data(Fixture.googleInvitation.utf8)
        for length in 0...data.count {
            #expect(ICalendar.invitations(from: data.prefix(length)).count <= 1)
        }
        // Cut before the guests: the event is read with what it has.
        let cut = try #require(Fixture.googleInvitation.range(of: "ATTENDEE"))
        let partial = try #require(ICalendar.invitations(from: String(Fixture.googleInvitation[..<cut.lowerBound])).first)
        #expect(partial.uid == "5qv2l8mbd0e4k1h7r3n9s6t2pu@google.com")
        #expect(partial.start == .timed(utc("2026-10-12T21:00:00Z"), timeZone: "America/Los_Angeles"))
        #expect(partial.organizer?.email == "jamie.chen@studio.co" && partial.attendees.isEmpty)
    }

    @Test func deepNestingIsBounded() {
        let text = "BEGIN:VCALENDAR\n" + String(repeating: "BEGIN:X-DEEP\n", count: 20_000)
            + "BEGIN:VEVENT\nUID:deep\nDTSTART:20261012T090000Z\nEND:VEVENT\n" + String(repeating: "END:X-NOPE\n", count: 20_000)
        #expect(ICalendar.invitations(from: text).map(\.uid) == ["deep"])
    }
}

@Suite("iCalendar time zones")
struct ICalendarTimeZoneTests {
    @Test func floatingTimesUseTheDefaultZone() {
        let berlin = zone("Europe/Berlin")
        #expect(event("DTSTART:20261012T090000", defaultTimeZone: berlin)?.start == .timed(utc("2026-10-12T07:00:00Z"), timeZone: "Europe/Berlin"))
    }

    @Test func utcTimesHaveNoZone() {
        #expect(event("DTSTART:20261012T090000Z", defaultTimeZone: zone("Asia/Tokyo"))?.start == .timed(utc("2026-10-12T09:00:00Z"), timeZone: nil))
    }

    @Test func prefixedIdentifiers() {
        let lunch = utc("2026-10-12T10:30:00Z")
        #expect(event("DTSTART;TZID=/mozilla.org/20050126_1/Europe/Berlin:20261012T123000")?.start == .timed(lunch, timeZone: "Europe/Berlin"))
        #expect(event("DTSTART;TZID=/softwarestudio.org/Olson_20011030_5/Europe/Berlin:20261012T123000")?.start == .timed(lunch, timeZone: "Europe/Berlin"))
        #expect(event("DTSTART;TZID=/Europe/Berlin:20261012T123000")?.start == .timed(lunch, timeZone: "Europe/Berlin"))
        #expect(event("DTSTART;TZID=tzone://Microsoft/Utc:20261012T103000")?.start == .timed(lunch, timeZone: "Etc/UTC"))
    }

    @Test func windowsAndOutlookDisplayNames() {
        #expect(event("DTSTART;TZID=US/Pacific:20261012T090000")?.start == .timed(utc("2026-10-12T16:00:00Z"), timeZone: "US/Pacific"))
        // Windows names win over the offsets Foundation also accepts as identifiers.
        #expect(event("DTSTART;TZID=UTC:20261012T090000")?.start == .timed(utc("2026-10-12T09:00:00Z"), timeZone: "Etc/UTC"))
        #expect(event("DTSTART;TZID=UTC-08:20261012T090000")?.start == .timed(utc("2026-10-12T17:00:00Z"), timeZone: "Etc/GMT+8"))
        #expect(event("DTSTART;TZID=W. Europe Standard Time:20261012T090000")?.start == .timed(utc("2026-10-12T07:00:00Z"), timeZone: "Europe/Berlin"))
        #expect(event("DTSTART;TZID=\"(UTC-05:00) Eastern Time (US & Canada)\":20261012T090000")?.start == .timed(utc("2026-10-12T13:00:00Z"), timeZone: "America/New_York"))
        #expect(event("DTSTART;TZID=\"(GMT+01.00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna\":20260115T090000")?.start == .timed(utc("2026-01-15T08:00:00Z"), timeZone: "Europe/Berlin"))
        #expect(event("DTSTART;TZID=\"(GMT-08.00) Pacific Time (US & Canada); Tijuana\":20260115T090000")?.start == .timed(utc("2026-01-15T17:00:00Z"), timeZone: "America/Los_Angeles"))
    }

    @Test func windowsTable() {
        let expected = [
            "Pacific Standard Time": "America/Los_Angeles", "Mountain Standard Time": "America/Denver",
            "US Mountain Standard Time": "America/Phoenix", "Central Standard Time": "America/Chicago",
            "Eastern Standard Time": "America/New_York", "GMT Standard Time": "Europe/London",
            "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
            "Central Europe Standard Time": "Europe/Budapest", "India Standard Time": "Asia/Kolkata",
            "China Standard Time": "Asia/Shanghai", "Tokyo Standard Time": "Asia/Tokyo",
            "AUS Eastern Standard Time": "Australia/Sydney", "UTC": "Etc/UTC",
            "Atlantic Standard Time": "America/Halifax", "Newfoundland Standard Time": "America/St_Johns",
            "Korea Standard Time": "Asia/Seoul", "New Zealand Standard Time": "Pacific/Auckland",
            "E. South America Standard Time": "America/Sao_Paulo", "Central Standard Time (Mexico)": "America/Mexico_City",
            "South Africa Standard Time": "Africa/Johannesburg", "Israel Standard Time": "Asia/Jerusalem",
            "Arabian Standard Time": "Asia/Dubai", "Singapore Standard Time": "Asia/Singapore",
        ]
        for (windows, iana) in expected {
            #expect(ICalendar.ianaZone(forWindowsName: windows) == iana, "\(windows)")
        }
        #expect(ICalendar.ianaZone(forWindowsName: "  pacific standard TIME ") == "America/Los_Angeles")
        #expect(ICalendar.ianaZone(forWindowsName: "Narnia Standard Time") == nil)
        #expect(ICalendar.windowsZoneTable.count > 140)
        for entry in ICalendar.windowsZoneTable {
            #expect(TimeZone(identifier: entry.iana) != nil, "\(entry.windows)")
        }
        for identifier in ICalendar.outlookDisplayNames.values {
            #expect(TimeZone(identifier: identifier) != nil, "\(identifier)")
        }
    }

    @Test func unknownZoneUsesItsVTIMEZONEOffset() throws {
        let island = "BEGIN:VTIMEZONE\nTZID:Island Time\nBEGIN:STANDARD\nDTSTART:19700101T000000\nTZOFFSETFROM:+0415\nTZOFFSETTO:+0415\nEND:STANDARD\nEND:VTIMEZONE\n"
        let invitation = try #require(event("DTSTART;TZID=\"Island Time\":20261012T090000\nEXDATE;TZID=Island Time:20261019T090000,20261026T090000", before: island))
        #expect(invitation.start == .timed(utc("2026-10-12T04:45:00Z"), timeZone: nil))
        // With no zone name to keep, removed dates are written in UTC.
        #expect(invitation.recurrence == ["EXDATE:20261019T044500Z,20261026T044500Z"])
    }

    @Test func customizedOutlookZonesMatchAnIANAZone() {
        func customized(_ id: String, standard: String, daylight: String, standardMonth: Int, daylightMonth: Int) -> String {
            """
            BEGIN:VTIMEZONE
            TZID:\(id)
            BEGIN:STANDARD
            DTSTART:16010101T020000
            TZOFFSETFROM:\(daylight)
            TZOFFSETTO:\(standard)
            RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=\(standardMonth)
            END:STANDARD
            BEGIN:DAYLIGHT
            DTSTART:16010101T020000
            TZOFFSETFROM:\(standard)
            TZOFFSETTO:\(daylight)
            RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=\(daylightMonth)
            END:DAYLIGHT
            END:VTIMEZONE

            """
        }
        let pacific = customized("Customized Time Zone", standard: "-0800", daylight: "-0700", standardMonth: 11, daylightMonth: 3)
        #expect(event("DTSTART;TZID=Customized Time Zone:20260715T100000", before: pacific)?.start == .timed(utc("2026-07-15T17:00:00Z"), timeZone: "America/Los_Angeles"))
        let sydney = customized("Customized Time Zone 1", standard: "+1000", daylight: "+1100", standardMonth: 4, daylightMonth: 10)
        #expect(event("DTSTART;TZID=Customized Time Zone 1:20270115T100000", before: sydney)?.start == .timed(utc("2027-01-14T23:00:00Z"), timeZone: "Australia/Sydney"))
    }

    @Test func unknownZoneWithoutDefinitionUsesTheDefaultZone() throws {
        let berlin = zone("Europe/Berlin")
        let invitation = try #require(event("DTSTART;TZID=Narnia Standard Time:20261012T090000\nEXDATE;TZID=Narnia Standard Time:20261019T090000", defaultTimeZone: berlin))
        #expect(invitation.start == .timed(utc("2026-10-12T07:00:00Z"), timeZone: "Europe/Berlin"))
        #expect(invitation.recurrence == ["EXDATE;TZID=Europe/Berlin:20261019T090000"])
    }

    @Test func recurrenceLinesKeepTheirForm() throws {
        let invitation = try #require(event("""
            DTSTART;VALUE=DATE:20261012
            RRULE:FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=12
            EXDATE;VALUE=DATE:20271012
            RDATE;VALUE=DATE:20261224,20261231
            EXDATE:20281012T090000Z
            """))
        #expect(invitation.recurrence == [
            "RRULE:FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=12", "EXDATE;VALUE=DATE:20271012",
            "RDATE;VALUE=DATE:20261224,20261231", "EXDATE:20281012T090000Z",
        ])
    }

    @Test func durationsSetTheEnd() {
        func end(_ start: String, _ duration: String) -> EventTime? { event("\(start)\nDURATION:\(duration)")?.end }
        let day = DayDate(year: 2026, month: 10, day: 12)
        #expect(end("DTSTART;VALUE=DATE:20261012", "P1D") == .allDay(day.adding(days: 1)))
        #expect(end("DTSTART;VALUE=DATE:20261012", "P2W") == .allDay(day.adding(days: 14)))
        #expect(end("DTSTART:20261012T090000Z", "PT1H30M") == .timed(utc("2026-10-12T10:30:00Z"), timeZone: nil))
        #expect(end("DTSTART:20261012T090000Z", "P1DT2H") == .timed(utc("2026-10-13T11:00:00Z"), timeZone: nil))
        // A day is a calendar day: 9:00 the next morning, across the end of daylight saving time.
        #expect(end("DTSTART;TZID=America/Los_Angeles:20261031T090000", "P1D") == .timed(utc("2026-11-01T17:00:00Z"), timeZone: "America/Los_Angeles"))
        #expect(end("DTSTART:20261012T090000Z", "-PT15M") == nil)
        #expect(end("DTSTART:20261012T090000Z", "PT") == nil)
        #expect(end("DTSTART:20261012T090000Z", "soon") == nil)
        #expect(event("DTSTART:20261012T090000Z\nDTEND:20261012T093000Z\nDURATION:PT2H")?.end == .timed(utc("2026-10-12T09:30:00Z"), timeZone: nil))
        // An end before the start, or an all-day end on the start day, is no end.
        #expect(event("DTSTART:20261012T090000Z\nDTEND:20261012T080000Z")?.end == nil)
        #expect(event("DTSTART;VALUE=DATE:20261012\nDTEND;VALUE=DATE:20261012")?.end == nil)
    }
}

@Suite("iCalendar replies")
struct ICalendarReplyTests {
    @Test func replyAnswersTheOrganizer() throws {
        let invitation = try #require(ICalendar.invitations(from: Fixture.googleInvitation).first)
        let reply = ICalendar.reply(
            to: invitation, as: Attendee(email: "sam@hey.com", name: "Carter, Sam"), response: .accepted,
            comment: "See you there; bringing notes, slides\nand coffee.", stamp: utc("2026-10-10T17:00:00Z")
        )
        let lines = reply.components(separatedBy: "\r\n")
        #expect(Array(lines.prefix(5)) == ["BEGIN:VCALENDAR", "PRODID:-//vimail//EN", "VERSION:2.0", "METHOD:REPLY", "BEGIN:VEVENT"])
        #expect(reply.hasSuffix("END:VEVENT\r\nEND:VCALENDAR\r\n"))
        #expect(!reply.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        for expected in [
            "UID:5qv2l8mbd0e4k1h7r3n9s6t2pu@google.com", "SEQUENCE:0", "DTSTAMP:20261010T170000Z", "DTSTART:20261012T210000Z",
            "DTEND:20261012T214500Z", "SUMMARY:Q4 launch review", "ORGANIZER;CN=Jamie Chen:mailto:jamie.chen@studio.co",
            "ATTENDEE;PARTSTAT=ACCEPTED;CN=\"Carter, Sam\":mailto:sam@hey.com",
            #"COMMENT:See you there\; bringing notes\, slides\nand coffee."#,
        ] {
            #expect(lines.contains(expected), "\(expected)")
        }
        #expect(!lines.contains { $0.hasPrefix("RECURRENCE-ID") })
    }

    @Test func repliesRoundTrip() throws {
        let moved = try #require(ICalendar.invitations(from: Fixture.googleSeries).last)
        let me = Attendee(email: "sam@hey.com", name: "Sam \"SC\" Carter")
        let reply = ICalendar.reply(to: moved, as: me, response: .tentative, comment: "Might be late", stamp: utc("2026-10-10T17:00:00Z"))
        #expect(reply.contains("\r\nRECURRENCE-ID:20261019T160000Z\r\n"))
        let parsed = try #require(ICalendar.invitations(from: reply).first)
        #expect(parsed.method == .reply)
        #expect(parsed.uid == moved.uid && parsed.sequence == moved.sequence && parsed.summary == moved.summary)
        #expect(parsed.recurrenceID?.date == moved.recurrenceID?.date)
        #expect(parsed.start.date == moved.start.date && parsed.end?.date == moved.end?.date)
        #expect(parsed.organizer?.email == "jamie.chen@studio.co")
        #expect(parsed.attendees == [Attendee(email: "sam@hey.com", name: "Sam \"SC\" Carter", response: .tentative, comment: "Might be late")])
    }

    @Test func allDayRepliesKeepDates() throws {
        let invitation = try #require(ICalendar.invitations(from: Fixture.appleAllDay).first)
        let reply = ICalendar.reply(to: invitation, as: Attendee(email: "sam@hey.com"), response: .declined, comment: nil, stamp: utc("2026-10-02T08:00:00Z"))
        #expect(reply.contains("\r\nDTSTART;VALUE=DATE:20261012\r\nDTEND;VALUE=DATE:20261013\r\n"))
        #expect(reply.contains("\r\nATTENDEE;PARTSTAT=DECLINED:mailto:sam@hey.com\r\n"))
        #expect(!reply.contains("COMMENT"))
        let parsed = try #require(ICalendar.invitations(from: reply).first)
        #expect(parsed.start == invitation.start && parsed.end == invitation.end)
        #expect(parsed.attendees.first?.response == .declined)
    }

    @Test func quotedTextCannotAddLines() throws {
        let invitation = Invitation(
            method: .request, uid: "uid\r\nATTENDEE:mailto:evil@x.co", summary: "Hi\u{0}\r\nMETHOD:CANCEL",
            start: .timed(utc("2026-10-12T09:00:00Z"), timeZone: nil),
            organizer: Attendee(email: "jamie@studio.co\r\nX-EVIL:1", name: "Jamie\r\nX-EVIL:2")
        )
        let reply = ICalendar.reply(to: invitation, as: Attendee(email: "sam@hey.com", name: "Sam\nCarter"), response: .accepted, comment: "Ok\r\nMETHOD:CANCEL", stamp: utc("2026-10-10T17:00:00Z"))
        let lines = reply.components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.hasPrefix("METHOD:CANCEL") || $0.hasPrefix("X-EVIL") || $0.hasPrefix("ATTENDEE:") })
        let parsed = try #require(ICalendar.invitations(from: reply).first)
        #expect(parsed.method == .reply)
        #expect(parsed.uid == "uid\nATTENDEE:mailto:evil@x.co")
        #expect(parsed.summary == "Hi\nMETHOD:CANCEL")
        #expect(parsed.attendees == [Attendee(email: "sam@hey.com", name: "Sam\nCarter", response: .accepted, comment: "Ok\nMETHOD:CANCEL")])
    }

    @Test func longLinesFoldAt75OctetsBetweenCharacters() throws {
        // "SUMMARY:" and 66 letters make 74 octets, so the two-octet "é" starts the next line.
        let summary = String(repeating: "a", count: 66) + "é" + String(repeating: "Größenwachstum 🚀, ", count: 6) + "Ende"
        let comment = String(repeating: "Désolé; ", count: 30) + "à bientôt"
        let invitation = Invitation(
            method: .request, uid: "fold@vimail", summary: summary, start: .timed(utc("2026-10-12T09:00:00Z"), timeZone: nil),
            organizer: Attendee(email: "jamie@studio.co", name: String(repeating: "Ünïcödé ", count: 12) + "Name")
        )
        let reply = ICalendar.reply(to: invitation, as: Attendee(email: "sam@hey.com"), response: .accepted, comment: comment, stamp: utc("2026-10-10T17:00:00Z"))
        let lines = reply.components(separatedBy: "\r\n").dropLast()
        #expect(lines.allSatisfy { $0.utf8.count <= 75 })
        #expect(lines.contains("SUMMARY:" + String(repeating: "a", count: 66)))
        #expect(lines.contains { $0.hasPrefix(" é") })
        let parsed = try #require(ICalendar.invitations(from: Data(reply.utf8)).first)
        #expect(parsed.summary == summary)
        #expect(parsed.organizer?.name == invitation.organizer?.name)
        #expect(parsed.attendees.first?.comment == comment)
    }
}

/// Files as Google Calendar, Exchange and Apple Calendar send them.
enum Fixture {
    /// A Google Calendar invitation, folded at 75 octets as Google writes it.
    static let googleInvitation = crlf(#"""
        BEGIN:VCALENDAR
        PRODID:-//Google Inc//Google Calendar 70.9054//EN
        VERSION:2.0
        CALSCALE:GREGORIAN
        METHOD:REQUEST
        BEGIN:VTIMEZONE
        TZID:America/Los_Angeles
        X-LIC-LOCATION:America/Los_Angeles
        BEGIN:DAYLIGHT
        TZOFFSETFROM:-0800
        TZOFFSETTO:-0700
        TZNAME:PDT
        DTSTART:19700308T020000
        RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
        END:DAYLIGHT
        BEGIN:STANDARD
        TZOFFSETFROM:-0700
        TZOFFSETTO:-0800
        TZNAME:PST
        DTSTART:19701101T020000
        RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        DTSTART;TZID=America/Los_Angeles:20261012T140000
        DTEND;TZID=America/Los_Angeles:20261012T144500
        DTSTAMP:20261009T171502Z
        ORGANIZER;CN=Jamie Chen:mailto:jamie.chen@studio.co
        UID:5qv2l8mbd0e4k1h7r3n9s6t2pu@google.com
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE
         ;CN=Jamie Chen;X-NUM-GUESTS=0:mailto:jamie.chen@studio.co
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=
         TRUE;CN=sam@hey.com;X-NUM-GUESTS=0:mailto:sam@hey.com
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=OPT-PARTICIPANT;PARTSTAT=TENTATIVE;RSVP=TRU
         E;CN=Nina Park;X-NUM-GUESTS=0;X-RESPONSE-COMMENT="Might be 5 minutes late"
         :mailto:nina@fastmail.com
        ATTENDEE;CUTYPE=RESOURCE;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=FALSE;
         CN=Studio-4-Fishbowl (6);X-NUM-GUESTS=0:mailto:c_1888a2b4c6d8e0f2@resource
         .calendar.google.com
        X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij
        CREATED:20261009T171500Z
        DESCRIPTION:Agenda: walk through the Q4 launch plan\, then open questions.\
         n\n-::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~
         :~:~:~:~:~:~:~:~:~::~:~::-\nJoin with Google Meet: https://meet.google.com
         /abc-defg-hij\nOr dial: (US) +1 650-555-0100 PIN: 123456789#\nMore phone n
         umbers: https://tel.meet/abc-defg-hij?pin=123456789\n\nLearn more about Me
         et at: https://support.google.com/a/users/answer/9282720\n\nPlease do not
          edit this section.\n-::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~
         :~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        LAST-MODIFIED:20261009T171502Z
        LOCATION:
        SEQUENCE:0
        STATUS:CONFIRMED
        SUMMARY:Q4 launch review
        TRANSP:OPAQUE
        BEGIN:VALARM
        ACTION:DISPLAY
        DESCRIPTION:This is an event reminder
        TRIGGER:-P0DT0H10M0S
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """#)

    /// A weekly Google series with removed dates, and one occurrence moved (an exception with RECURRENCE-ID).
    static let googleSeries = crlf(#"""
        BEGIN:VCALENDAR
        PRODID:-//Google Inc//Google Calendar 70.9054//EN
        VERSION:2.0
        CALSCALE:GREGORIAN
        METHOD:REQUEST
        BEGIN:VTIMEZONE
        TZID:America/Los_Angeles
        X-LIC-LOCATION:America/Los_Angeles
        BEGIN:DAYLIGHT
        TZOFFSETFROM:-0800
        TZOFFSETTO:-0700
        TZNAME:PDT
        DTSTART:19700308T020000
        RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
        END:DAYLIGHT
        BEGIN:STANDARD
        TZOFFSETFROM:-0700
        TZOFFSETTO:-0800
        TZNAME:PST
        DTSTART:19701101T020000
        RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        DTSTART;TZID=America/Los_Angeles:20261012T090000
        DTEND;TZID=America/Los_Angeles:20261012T091500
        RRULE:FREQ=WEEKLY;BYDAY=MO
        EXDATE;TZID=America/Los_Angeles:20261026T090000
        EXDATE;TZID=America/Los_Angeles:20261109T090000,20261116T090000
        DTSTAMP:20261009T180000Z
        ORGANIZER;CN=Jamie Chen:mailto:jamie.chen@studio.co
        UID:1mt8c4k2v6b9n3q7r5s0w2x4yz@google.com
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE
         ;CN=Jamie Chen;X-NUM-GUESTS=0:mailto:jamie.chen@studio.co
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=
         TRUE;CN=Sam Carter;X-NUM-GUESTS=0:mailto:sam@hey.com
        X-GOOGLE-CONFERENCE:https://meet.google.com/xyz-wvut-srq
        CREATED:20261009T175900Z
        DESCRIPTION:Fifteen minutes\, cameras optional.
        LAST-MODIFIED:20261009T180000Z
        SEQUENCE:0
        STATUS:CONFIRMED
        SUMMARY:Weekly standup
        TRANSP:OPAQUE
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;TZID=America/Los_Angeles:20261020T100000
        DTEND;TZID=America/Los_Angeles:20261020T101500
        DTSTAMP:20261009T180000Z
        ORGANIZER;CN=Jamie Chen:mailto:jamie.chen@studio.co
        UID:1mt8c4k2v6b9n3q7r5s0w2x4yz@google.com
        RECURRENCE-ID;TZID=America/Los_Angeles:20261019T090000
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE
         ;CN=Jamie Chen;X-NUM-GUESTS=0:mailto:jamie.chen@studio.co
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=
         TRUE;CN=Sam Carter;X-NUM-GUESTS=0:mailto:sam@hey.com
        X-GOOGLE-CONFERENCE:https://meet.google.com/xyz-wvut-srq
        CREATED:20261009T175900Z
        LAST-MODIFIED:20261009T180000Z
        SEQUENCE:1
        STATUS:CONFIRMED
        SUMMARY:Weekly standup (Tuesday this week)
        TRANSP:OPAQUE
        END:VEVENT
        END:VCALENDAR
        """#)

    /// An Exchange invitation: a Windows zone name, a duration instead of DTEND, and a Teams link in the location.
    static let outlookInvitation = crlf(#"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        PRODID:Microsoft Exchange Server 2010
        VERSION:2.0
        BEGIN:VTIMEZONE
        TZID:Pacific Standard Time
        BEGIN:STANDARD
        DTSTART:16010101T020000
        TZOFFSETFROM:-0700
        TZOFFSETTO:-0800
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11
        END:STANDARD
        BEGIN:DAYLIGHT
        DTSTART:16010101T020000
        TZOFFSETFROM:-0800
        TZOFFSETTO:-0700
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3
        END:DAYLIGHT
        END:VTIMEZONE
        BEGIN:VEVENT
        ORGANIZER;CN="Chen, Jamie":mailto:jamie.chen@contoso.com
        ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Sam Carter
         :mailto:sam@hey.com
        ATTENDEE;ROLE=OPT-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN="Ortiz, Be
         n":mailto:ben.ortiz@contoso.com
        ATTENDEE;CUTYPE=ROOM;ROLE=NON-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;C
         N="Conf Room 12 (Seattle)":mailto:conf12.seattle@contoso.com
        DESCRIPTION;LANGUAGE=en-US:Weekly vendor sync. Bring the contract redlines.
         \n\n______________________________________________________________________
         __________\nMicrosoft Teams meeting\nJoin on your computer\, mobile app or
          room device\nClick here to join the meeting<https://teams.microsoft.com/l
         /meetup-join/19%3ameeting_NjM4ZTRiYTYtZjU1Ny00%40thread.v2/0?context=%7b%2
         2Tid%22%3a%2272f988bf%22%7d>\nMeeting ID: 254 120 335 78\nPasscode: 4tBzGN
         \n________________________________________________________________________
         ________\n
        RRULE:FREQ=WEEKLY;UNTIL=20261216T170000Z;INTERVAL=1;BYDAY=WE;WKST=SU
        EXDATE;TZID=Pacific Standard Time:20261028T090000
        UID:040000008200E00074C5B7101A82E00800000000F0B6A2F1A15BDB01000000000000000
         010000000C7E2E0A8F0E54F4A9C1C1C1A6B9D8E2F
        SUMMARY;LANGUAGE=en-US:Vendor contract sync
        DTSTART;TZID="Pacific Standard Time":20261014T090000
        DURATION:PT30M
        CLASS:PUBLIC
        PRIORITY:5
        DTSTAMP:20261009T160417Z
        TRANSP:OPAQUE
        STATUS:CONFIRMED
        SEQUENCE:1
        LOCATION;LANGUAGE=en-US:Microsoft Teams Meeting https://teams.microsoft.com
         /l/meetup-join/19%3ameeting_NjM4ZTRiYTYtZjU1Ny00%40thread.v2/0
        X-MICROSOFT-CDO-APPT-SEQUENCE:1
        X-MICROSOFT-CDO-OWNERAPPTID:2120868542
        X-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE
        X-MICROSOFT-CDO-INTENDEDSTATUS:BUSY
        X-MICROSOFT-CDO-ALLDAYEVENT:FALSE
        X-MICROSOFT-CDO-IMPORTANCE:1
        X-MICROSOFT-CDO-INSTTYPE:1
        X-MICROSOFT-DONOTFORWARDMEETING:FALSE
        X-MICROSOFT-DISALLOW-COUNTER:FALSE
        X-MICROSOFT-LOCATIONS:[ { "DisplayName" : "Microsoft Teams Meeting"\, "Loca
         tionAnnotation" : ""\, "LocationSource" : 0\, "Unresolved" : false\, "Loca
         tionUri" : "" } ]
        BEGIN:VALARM
        DESCRIPTION:REMINDER
        TRIGGER;RELATED=START:-PT15M
        ACTION:DISPLAY
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """#)

    /// An Apple Calendar all-day invitation: dates, an `urn:uuid:` guest with an EMAIL parameter, quoted parameters.
    static let appleAllDay = crlf(#"""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Apple Inc.//macOS 15.0//EN
        CALSCALE:GREGORIAN
        METHOD:REQUEST
        BEGIN:VEVENT
        CREATED:20261001T120000Z
        UID:2D5E8B1C-3F4A-4B6D-9E7F-1A2B3C4D5E6F
        DTEND;VALUE=DATE:20261013
        TRANSP:TRANSPARENT
        X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC
        SUMMARY:Studio offsite
        LAST-MODIFIED:20261001T120000Z
        DTSTAMP:20261001T120005Z
        DTSTART;VALUE=DATE:20261012
        SEQUENCE:0
        ORGANIZER;CN="Alex Morgan";EMAIL="alex@studio.co":mailto:alex@studio.co
        ATTENDEE;CN="Alex Morgan";CUTYPE=INDIVIDUAL;EMAIL="alex@studio.co";PARTSTAT
         =ACCEPTED;ROLE=CHAIR:mailto:alex@studio.co
        ATTENDEE;CN="Sam Carter";CUTYPE=INDIVIDUAL;EMAIL="sam@hey.com";PARTSTAT=NEE
         DS-ACTION;ROLE=REQ-PARTICIPANT;RSVP=TRUE:urn:uuid:5B1C2D3E-4F5A-6B7C-8D9E-
         0F1A2B3C4D5E
        X-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-ADDRESS="1 Ferry Building, San Fran
         cisco, CA 94111, United States";X-APPLE-RADIUS=70;X-TITLE="Ferry Building"
         :geo:37.795470,-122.393420
        LOCATION:Ferry Building\n1 Ferry Building\, San Francisco\, CA 94111
        END:VEVENT
        END:VCALENDAR
        """#)

    /// Google's cancellation of one event.
    static let cancellation = crlf(#"""
        BEGIN:VCALENDAR
        PRODID:-//Google Inc//Google Calendar 70.9054//EN
        VERSION:2.0
        CALSCALE:GREGORIAN
        METHOD:CANCEL
        BEGIN:VEVENT
        DTSTART:20261015T170000Z
        DTEND:20261015T173000Z
        DTSTAMP:20261010T090000Z
        ORGANIZER;CN=Jamie Chen:mailto:jamie.chen@studio.co
        UID:0a9b8c7d6e5f4g3h2i1j@google.com
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;CN=Sa
         m Carter;X-NUM-GUESTS=0:mailto:sam@hey.com
        CREATED:20261008T100000Z
        LAST-MODIFIED:20261010T090000Z
        SEQUENCE:2
        STATUS:CANCELLED
        SUMMARY:1:1 Jamie / Sam
        TRANSP:OPAQUE
        END:VEVENT
        END:VCALENDAR
        """#)

    /// An Outlook guest's reply declining, with a note.
    static let outlookReply = crlf(#"""
        BEGIN:VCALENDAR
        METHOD:REPLY
        PRODID:Microsoft Exchange Server 2010
        VERSION:2.0
        BEGIN:VEVENT
        ATTENDEE;PARTSTAT=DECLINED;CN=Ben Ortiz:mailto:ben.ortiz@contoso.com
        COMMENT;LANGUAGE=en-US:Out that week\, sorry!\n
        SUMMARY;LANGUAGE=en-US:Declined: Q4 launch review
        DTSTART;TZID=America/Los_Angeles:20261012T140000
        DTEND;TZID=America/Los_Angeles:20261012T144500
        UID:5qv2l8mbd0e4k1h7r3n9s6t2pu@google.com
        CLASS:PUBLIC
        PRIORITY:5
        DTSTAMP:20261010T080000Z
        TRANSP:OPAQUE
        STATUS:CONFIRMED
        SEQUENCE:0
        ORGANIZER:mailto:jamie.chen@studio.co
        END:VEVENT
        END:VCALENDAR
        """#)
}

@Suite("iCalendar hostile zones")
struct ICalendarHostileZoneTests {
    @Test func aVeryLongZoneNameIsUnknownAndCheap() {
        let tzid = Array(repeating: "a", count: 50_000).joined(separator: "/")
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(ICalendar.ianaIdentifier(forTZID: tzid) == nil)
        }
        #expect(elapsed < .milliseconds(200))
        // Nothing but slashes is no name either, and no crash.
        #expect(ICalendar.ianaIdentifier(forTZID: "/") == nil)
        #expect(ICalendar.ianaIdentifier(forTZID: "//") == nil)
        #expect(ICalendar.ianaIdentifier(forTZID: " / ") == nil)
        #expect(ICalendar.ianaIdentifier(forTZID: "/mozilla.org/20050126_1/America/Argentina/Buenos_Aires") == "America/Argentina/Buenos_Aires")
        #expect(ICalendar.ianaIdentifier(forTZID: "/softwarestudio.org/Olson_20011030_5/America/New_York") == "America/New_York")
    }
}
