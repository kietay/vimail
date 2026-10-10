import Foundation
import Testing
@testable import GmailProvider
import HTTPKit
@testable import MailCore

/// A calendar provider whose pacing never slows tests down.
func makeCalendarProvider(_ transport: any HTTPTransport) -> GoogleCalendarProvider {
    GoogleCalendarProvider(credential: testCredential, transport: transport,
                           pacer: QuotaPacer(unitsPerSecond: 1_000_000, maxRate: 1_000_000, burst: 1_000_000, maxConcurrent: 8))
}

private func reviewJSON() -> [String: Any] { [
    "id": "abc123", "status": "confirmed", "etag": "\"3181\"", "htmlLink": "https://www.google.com/calendar/event?eid=x",
    "summary": "Design review", "description": "Walk through the onboarding screens.", "iCalUID": "abc123@google.com", "sequence": 1,
    "updated": "2026-10-09T16:12:44.123Z",
    "start": ["dateTime": "2026-10-12T14:00:00-07:00", "timeZone": "America/Los_Angeles"],
    "end": ["dateTime": "2026-10-12T14:45:00-07:00", "timeZone": "America/Los_Angeles"],
    "organizer": ["email": "jamie@studio.co", "displayName": "Jamie Chen"],
    "attendees": [
        ["email": "jamie@studio.co", "displayName": "Jamie Chen", "organizer": true, "responseStatus": "accepted"],
        ["email": "me@example.com", "self": true, "responseStatus": "needsAction"],
        ["email": "room-4@resource.calendar.google.com", "resource": true, "responseStatus": "accepted"],
    ],
    "conferenceData": ["entryPoints": [["entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"]]],
] }

@Suite("Google Calendar provider")
struct GoogleCalendarProviderTests {
    @Test func mapsEventsWithGuestsTimesAndConference() async throws {
        let transport = FakeTransport { call in
            #expect(call.path == "/calendar/v3/calendars/me@example.com/events")
            #expect(call.query["singleEvents"] == "false")
            #expect(call.query["showHiddenInvitations"] == nil)
            #expect(call.query["timeMin"] == "2025-10-09T00:00:00Z")
            #expect(call.query["syncToken"] == nil)
            return (200, json(["items": [reviewJSON(), ["id": "ad1", "summary": "Offsite", "start": ["date": "2026-10-20"], "end": ["date": "2026-10-22"], "transparency": "transparent"]], "nextSyncToken": "sync-1"]))
        }
        let page = try await makeCalendarProvider(transport).events(
            calendarID: "me@example.com", syncToken: nil, pageToken: nil, timeMin: Date(timeIntervalSince1970: 1_759_968_000)
        )
        #expect(page.nextSyncToken == "sync-1")
        let review = try #require(page.events.first)
        #expect(review.start == .timed(Date(timeIntervalSince1970: 1_791_838_800), timeZone: "America/Los_Angeles"))
        #expect(review.end.date == Date(timeIntervalSince1970: 1_791_841_500))
        #expect(review.selfResponse == .needsAction)
        #expect(review.organizer?.email == "jamie@studio.co")
        #expect(review.attendees.first?.isOrganizer == true)
        #expect(review.attendees.last?.isResource == true)
        #expect(review.conferenceURL == "https://meet.google.com/abc-defg-hij")
        #expect(review.etag == "\"3181\"" && review.sequence == 1)
        #expect(review.updated != nil)
        let offsite = try #require(page.events.last)
        #expect(offsite.start == .allDay(DayDate("2026-10-20")!) && offsite.end == .allDay(DayDate("2026-10-22")!))
        #expect(!offsite.isBusy)
    }

    @Test func incrementalSyncSendsOnlyTheTokenAndExpiredTokensNeedAFullSync() async throws {
        let transport = FakeTransport { call in
            if call.query["syncToken"] == "old" { return (410, #"{"error":{"code":410,"errors":[{"reason":"fullSyncRequired"}],"message":"Sync token is no longer valid"}}"#) }
            #expect(call.query["timeMin"] == nil)
            return (200, json(["items": [["id": "gone", "status": "cancelled"]], "nextSyncToken": "sync-2"]))
        }
        let provider = makeCalendarProvider(transport)
        await #expect(throws: ProviderError.cursorExpired) {
            _ = try await provider.events(calendarID: "me@example.com", syncToken: "old", pageToken: nil, timeMin: nil)
        }
        let page = try await provider.events(calendarID: "me@example.com", syncToken: "new", pageToken: nil, timeMin: Date())
        // A removed event without times is still reported, so the store can remove it.
        #expect(page.events.map(\.id) == ["gone"])
        #expect(page.events.first?.status == .cancelled)
        #expect(page.nextSyncToken == "sync-2")
    }

    @Test func answerPatchesOnlyYourOwnGuestEntry() async throws {
        let transport = FakeTransport { call in
            switch call.method {
            case "GET": return (200, json(reviewJSON()))
            case "PATCH":
                #expect(call.query["sendUpdates"] == "all")
                #expect(call.json["attendeesOmitted"] as? Bool == true)
                let attendees = call.json["attendees"] as? [[String: Any]] ?? []
                #expect(attendees.count == 1)
                #expect(attendees.first?["email"] as? String == "me@example.com")
                #expect(attendees.first?["responseStatus"] as? String == "accepted")
                #expect(attendees.first?["comment"] as? String == "See you there")
                var answered = reviewJSON()
                answered["attendees"] = [["email": "me@example.com", "self": true, "responseStatus": "accepted", "comment": "See you there"]]
                return (200, json(answered))
            default: return (500, "{}")
            }
        }
        let event = try await makeCalendarProvider(transport).respond(
            calendarID: "me@example.com", eventID: "abc123", response: .accepted, comment: "See you there", sendUpdates: .all
        )
        #expect(event.selfResponse == .accepted)
        #expect(transport.calls.filter { $0.url.host == "www.googleapis.com" }.map(\.method) == ["GET", "PATCH"])
    }

    @Test func insertSendsTheClientIDAndAsksForAMeetLink() async throws {
        let transport = FakeTransport { call in
            #expect(call.method == "POST")
            #expect(call.query["conferenceDataVersion"] == "1")
            #expect(call.query["sendUpdates"] == "all")
            #expect(call.json["id"] as? String == "vm0abc12345")
            let conference = call.json["conferenceData"] as? [String: Any]
            let request = conference?["createRequest"] as? [String: Any]
            #expect((request?["conferenceSolutionKey"] as? [String: Any])?["type"] as? String == "hangoutsMeet")
            #expect((call.json["start"] as? [String: Any])?["timeZone"] as? String == "America/Los_Angeles")
            let attendees = call.json["attendees"] as? [[String: Any]] ?? []
            #expect(attendees.map { $0["email"] as? String } == ["jamie@studio.co"])
            #expect(attendees.first?["responseStatus"] == nil)
            var created = reviewJSON()
            created["id"] = "vm0abc12345"
            return (200, json(created))
        }
        let lunch = CalendarEvent(
            id: "vm0abc12345", calendarID: "me@example.com", summary: "Lunch",
            start: .timed(Date(timeIntervalSince1970: 1_791_838_800), timeZone: "America/Los_Angeles"),
            end: .timed(Date(timeIntervalSince1970: 1_791_842_400), timeZone: "America/Los_Angeles"),
            attendees: [Attendee(email: "jamie@studio.co", name: "Jamie Chen")]
        )
        let created = try await makeCalendarProvider(transport).insert(lunch, sendUpdates: .all, addConference: true)
        #expect(created.id == "vm0abc12345")
    }

    @Test func calendarErrorsMapToTheirMeaning() async throws {
        let transport = FakeTransport { call in
            switch call.path {
            case _ where call.method == "POST":
                return (409, #"{"error":{"code":409,"errors":[{"reason":"duplicate"}],"message":"The requested identifier already exists."}}"#)
            case let path where path.hasSuffix("/stale"):
                #expect(call.method == "PATCH")
                return (412, #"{"error":{"code":412,"errors":[{"reason":"conditionNotMet"}],"message":"Precondition Failed"}}"#)
            case let path where path.hasSuffix("/scope"):
                return (403, #"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}],"status":"PERMISSION_DENIED","message":"Insufficient Permission"}}"#)
            default:
                return (403, #"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}],"message":"Google Calendar API has not been used in project 1 before or it is disabled."}}"#)
            }
        }
        let provider = makeCalendarProvider(transport)
        func event(_ id: String) -> CalendarEvent {
            CalendarEvent(id: id, calendarID: "me@example.com", summary: "x", start: .allDay(DayDate("2026-10-20")!), end: .allDay(DayDate("2026-10-21")!))
        }
        await #expect(throws: CalendarProviderError.duplicate) {
            _ = try await provider.insert(event("dup"), sendUpdates: .none, addConference: false)
        }
        await #expect(throws: CalendarProviderError.changedElsewhere) {
            _ = try await provider.update(event("stale"), previous: nil, etag: "\"1\"", sendUpdates: .none)
        }
        await #expect(throws: CalendarProviderError.notConnected) {
            _ = try await provider.update(event("scope"), previous: nil, etag: nil, sendUpdates: .none)
        }
        do {
            _ = try await provider.update(event("disabled"), previous: nil, etag: nil, sendUpdates: .none)
            Issue.record("Expected an error")
        } catch let error as ProviderError {
            guard case .rejected(let message) = error else { Issue.record("Unexpected \(error)"); return }
            #expect(message.contains("Calendar API is not enabled"))
        }
        let stale = transport.calls.first { $0.path.hasSuffix("/stale") }
        #expect(stale?.url.query?.contains("sendUpdates=none") == true)
    }

    @Test func calendarListAndFreeBusy() async throws {
        let transport = FakeTransport { call in
            if call.path.hasSuffix("/calendarList") {
                return (200, json(["items": [
                    ["id": "me@example.com", "summary": "Me", "primary": true, "selected": true, "accessRole": "owner", "timeZone": "America/Los_Angeles", "backgroundColor": "#9fe1e7"],
                    ["id": "en.usa#holiday@group.v.calendar.google.com", "summary": "Holidays", "selected": true, "hidden": true, "accessRole": "reader"],
                    ["id": "old@group.calendar.google.com", "deleted": true],
                ], "nextSyncToken": "list-1"]))
            }
            #expect(call.path == "/calendar/v3/freeBusy")
            #expect((call.json["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["jamie@studio.co", "oliver@northfield.agency"])
            return (200, json(["calendars": [
                "jamie@studio.co": ["busy": [["start": "2026-10-12T21:00:00Z", "end": "2026-10-12T22:00:00Z"]]],
                "oliver@northfield.agency": ["errors": [["domain": "global", "reason": "notFound"]], "busy": []],
            ]]))
        }
        let provider = makeCalendarProvider(transport)
        let list = try await provider.calendars(syncToken: nil, pageToken: nil)
        #expect(list.calendars.map(\.id) == ["me@example.com", "en.usa#holiday@group.v.calendar.google.com"])
        #expect(list.calendars.first?.isPrimary == true && list.calendars.first?.canEdit == true)
        #expect(list.calendars.last?.isSelected == false)
        #expect(list.removedIDs == ["old@group.calendar.google.com"])
        let busy = try await provider.freeBusy(
            emails: ["jamie@studio.co", "oliver@northfield.agency"], from: Date(timeIntervalSince1970: 1_791_800_000), to: Date(timeIntervalSince1970: 1_791_900_000)
        )
        #expect(busy["jamie@studio.co"]?.first?.duration == 3600)
        // Not shared with you: left out, so it never reads as "free".
        #expect(busy.keys.sorted() == ["jamie@studio.co"])
    }

    @Test func editsPatchOnlyWhatChanged() async throws {
        let transport = FakeTransport { _ in (200, json(reviewJSON())) }
        var bodies: [[String: Any]] { transport.calls.filter { $0.method == "PATCH" }.map(\.json) }
        let provider = makeCalendarProvider(transport)
        let previous = try #require(GoogleCalendarMapping.event(try JSONDecoder().decode(GEvent.self, from: Data(json(reviewJSON()).utf8)), calendarID: "me@example.com"))

        // A new title, and timed to all-day: the old kind of time is cleared, nothing else is sent.
        var edit = previous
        edit.summary = "Design review (v2)"
        edit.start = .allDay(DayDate("2026-10-12")!)
        edit.end = .allDay(DayDate("2026-10-13")!)
        _ = try await provider.update(edit, previous: previous, etag: previous.etag, sendUpdates: .all)
        let first = try #require(bodies.first)
        #expect(Set(first.keys) == ["summary", "start", "end"])
        let start = try #require(first["start"] as? [String: Any])
        #expect(start["date"] as? String == "2026-10-12")
        #expect(start["dateTime"] is NSNull && start["timeZone"] is NSNull)
        #expect(transport.calls.last?.headers["If-Match"] == "\"3181\"")

        // A new guest: the whole list goes, the room and everyone's answers included.
        var invited = previous
        invited.attendees.append(Attendee(email: "priya@studio.co"))
        invited.details = nil
        _ = try await provider.update(invited, previous: previous, etag: previous.etag, sendUpdates: .all)
        let second = try #require(bodies.last)
        #expect(Set(second.keys) == ["attendees", "description"])
        #expect(second["description"] as? String == "")
        let guests = second["attendees"] as? [[String: Any]] ?? []
        #expect(guests.compactMap { $0["email"] as? String } == ["jamie@studio.co", "me@example.com", "room-4@resource.calendar.google.com", "priya@studio.co"])
        #expect(guests[2]["resource"] as? Bool == true)
        #expect(guests[0]["responseStatus"] as? String == "accepted")

        // Nothing changed: no PATCH, so no update email.
        let count = bodies.count
        _ = try await provider.update(previous, previous: previous, etag: previous.etag, sendUpdates: .all)
        #expect(bodies.count == count)
        #expect(transport.calls.last?.method == "GET")
    }

    @Test func hiddenInvitationsAreLookedUpByUID() async throws {
        let transport = FakeTransport { call in
            #expect(call.query["iCalUID"] == "abc123@google.com")
            #expect(call.query["showHiddenInvitations"] == "true")
            #expect(call.query["syncToken"] == nil)
            return (200, json(["items": [reviewJSON()]]))
        }
        let found = try await makeCalendarProvider(transport).events(calendarID: "me@example.com", iCalUID: "abc123@google.com")
        #expect(found.map(\.id) == ["abc123"])
    }

    @Test func freeBusyAsksInChunksGoogleAccepts() async throws {
        let from = Date(timeIntervalSince1970: 1_791_800_000)
        let firstStart = GoogleCalendarMapping.formatDateTime(from)
        let transport = FakeTransport { call in
            let second = call.json["timeMin"] as? String != firstStart
            return (200, json(["calendars": [
                "jamie@studio.co": ["busy": [["start": second ? "2026-12-20T17:00:00Z" : "2026-10-12T21:00:00Z", "end": second ? "2026-12-20T18:00:00Z" : "2026-10-12T22:00:00Z"]]],
                "oliver@northfield.agency": second ? ["errors": [["reason": "notFound"]]] : ["busy": []],
            ]]))
        }
        let busy = try await makeCalendarProvider(transport).freeBusy(
            emails: ["jamie@studio.co", "oliver@northfield.agency"], from: from, to: from.addingTimeInterval(100 * 86_400)
        )
        let ranges = transport.calls.filter { $0.path.hasSuffix("/freeBusy") }.map { ($0.json["timeMin"] as? String ?? "", $0.json["timeMax"] as? String ?? "") }
        #expect(ranges.count == 2)
        #expect(ranges.first?.1 == ranges.last?.0)
        #expect(busy["jamie@studio.co"]?.count == 2)
        // Not shared for part of the range: left out altogether.
        #expect(busy.keys.sorted() == ["jamie@studio.co"])
    }

    @Test func onlyWebLinksAreJoinLinks() throws {
        var resource = try JSONDecoder().decode(GEvent.self, from: Data(json(reviewJSON()).utf8))
        resource.conferenceData = GConferenceData(entryPoints: [GEntryPoint(entryPointType: "video", uri: "javascript:alert(1)")])
        resource.hangoutLink = "smb://meet.google.com.evil.example/abc"
        resource.location = "https://acme.zoom.us/j/123"
        #expect(GoogleCalendarMapping.conferenceURL(resource) == "https://acme.zoom.us/j/123")
        #expect(ICalendar.webLink("file:///etc/passwd") == nil)
        #expect(ICalendar.webLink(" https://meet.google.com/abc-defg-hij ") == "https://meet.google.com/abc-defg-hij")
    }

    @Test func meetingLinksAreFoundInPlacesAndNotes() {
        #expect(GoogleCalendarMapping.firstMeetingURL(in: "Room 4 or https://acme.zoom.us/j/123?pwd=x") == "https://acme.zoom.us/j/123?pwd=x")
        #expect(GoogleCalendarMapping.firstMeetingURL(in: "Agenda: https://docs.google.com/x then https://meet.google.com/abc-defg-hij") == "https://meet.google.com/abc-defg-hij")
        #expect(GoogleCalendarMapping.firstMeetingURL(in: "Café on Valencia") == nil)
    }

    @Test func requestLogsHideCalendarAddresses() {
        #expect(GoogleCalendarAPI.describe("GET", "calendars/jamie@studio.co/events", []) == "GET calendars/…/events")
    }

    @Test func calendarScopes() {
        #expect(CalendarScope.allowsReading([CalendarScope.eventsReadonly, CalendarScope.calendarListReadonly]))
        #expect(!CalendarScope.allowsChanges([CalendarScope.eventsReadonly, CalendarScope.calendarListReadonly]))
        #expect(CalendarScope.allowsChanges([CalendarScope.events]))
        #expect(!CalendarScope.allowsReading([GmailScope.modify]))
    }
}
