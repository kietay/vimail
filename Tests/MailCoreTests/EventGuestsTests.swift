import Foundation
import Testing
@testable import MailCore

private let me: Set<String> = ["sam@hey.com", "sam@work.co"]
private let jamie = EmailAddress(name: "Jamie Chen", email: "jamie@studio.co")
private let alex = EmailAddress(name: "Alex Morgan", email: "alex@studio.co")

/// The contacts the tests look names up in.
private func contacts(_ name: String) -> [EmailAddress] {
    switch name.lowercased() {
    case "jamie": [jamie]
    case "alex": [alex, EmailAddress(name: "Alex Kim", email: "kim@other.io")]
    default: []
    }
}

@Suite("Event guests")
struct EventGuestsTests {
    @Test func pillsLeaveOutYouAndRooms() {
        let attendees = [
            Attendee(email: "sam@hey.com", isSelf: true, isOrganizer: true),
            Attendee(email: "SAM@work.co"),
            Attendee(email: "jamie@studio.co", name: "Jamie Chen"),
            Attendee(email: "c_123@resource.calendar.google.com", name: "Room 4", isResource: true),
            Attendee(email: "Jamie@Studio.co"),
            Attendee(email: "alex@studio.co", name: "Alex Morgan", response: .accepted),
        ]
        #expect(EventGuests.pills(of: attendees, me: me) == [jamie, alex])
    }

    @Test func addingKeepsEachGuestOnceAndNeverYou() {
        let guests = EventGuests.adding([EmailAddress(email: "JAMIE@studio.co"), EmailAddress(email: "sam@hey.com"), alex, alex], to: [jamie], me: me)
        #expect(guests == [jamie, alex])
    }

    @Test func fullAddressesFinishOnACommaAndNamesStayTyped() {
        func split(_ text: String, finishing: Bool = false) -> ([String], String) {
            let result = EventGuests.split(text, finishing: finishing)
            return (result.finished.map(\.formatted), result.typing)
        }
        #expect(split("alex@studio.co, ") == (["alex@studio.co"], ""))
        #expect(split("alex@studio.co, jam") == (["alex@studio.co"], "jam"))
        #expect(split("Jamie Chen <jamie@studio.co>") == (["Jamie Chen <jamie@studio.co>"], ""))
        #expect(split("\"Chen, Jamie\" <jamie@studio.co>, ") == (["\"Chen, Jamie\" <jamie@studio.co>"], ""))
        // A name is not an address: it stays for the suggestions, or for the contacts when saving.
        #expect(split("jamie, ") == ([], "jamie, "))
        #expect(split("jamie, alex@studio.co, bo") == (["alex@studio.co"], "jamie, bo"))
        #expect(split("jamie; Ben Ortiz <ben@x.io>") == (["Ben Ortiz <ben@x.io>"], "jamie, "))
        // Still being typed.
        #expect(split("alex@studio.co") == ([], "alex@studio.co"))
        #expect(split("Jamie Chen <jamie@stu") == ([], "Jamie Chen <jamie@stu"))
        #expect(split("bob@, x") == ([], "bob@, x"))
    }

    @Test func finishingTakesTheLastAddressToo() {
        func finish(_ text: String) -> ([String], String) {
            let result = EventGuests.split(text, finishing: true)
            return (result.finished.map(\.email), result.typing)
        }
        #expect(finish("alex@studio.co") == (["alex@studio.co"], ""))
        #expect(finish("jamie, alex@studio.co") == (["alex@studio.co"], "jamie"))
        #expect(finish("jamie, bob") == ([], "jamie, bob"))
        #expect(finish("  ") == ([], ""))
    }

    @Test func theTokenIsThePartAfterTheLastComma() {
        #expect(EventGuests.token("jamie, al") == "al")
        #expect(EventGuests.token("  al") == "al")
        #expect(EventGuests.token("jamie, ") == "")
        #expect(EventGuests.token("\"Chen, Jam") == "\"Chen, Jam")
        #expect(EventGuests.droppingToken("jamie, al") == "jamie, ")
        #expect(EventGuests.droppingToken("al") == "")
        #expect(EventGuests.droppingToken("jamie,  , bo, al") == "jamie, bo, ")
    }

    @Test func namesAreWhatIsNotAnAddress() {
        #expect(EventGuests.names("jamie, alex@studio.co, \"Chen, Jamie\" <jamie@studio.co>, Alex Morgan") == ["jamie", "Alex Morgan"])
        #expect(EventGuests.names("") == [])
    }

    @Test func savingResolvesWhatIsStillTyped() {
        let pills = [EmailAddress(email: "nina@fastmail.com")]
        let all = EventGuests.resolve(pills, typed: "jamie, ben@x.io, alex, sam@hey.com", me: me, contacts: contacts)
        // Addresses as typed, names as their best contact match, you left out.
        #expect(all.guests.map(\.email) == ["nina@fastmail.com", "jamie@studio.co", "ben@x.io", "alex@studio.co"])
        #expect(all.unknown.isEmpty)
        // A name that matches nobody is reported, never dropped quietly.
        let missing = EventGuests.resolve([jamie], typed: "Jamie, tom", me: me, contacts: contacts)
        #expect(missing.guests == [jamie])
        #expect(missing.unknown == ["tom"])
        // Nothing typed: the pills.
        #expect(EventGuests.resolve([jamie, alex], typed: " ", me: me, contacts: contacts).guests == [jamie, alex])
    }

    @Test func theSameGuestsInAnyOrder() {
        #expect(EventGuests.same([jamie, alex], [EmailAddress(email: "ALEX@studio.co"), jamie]))
        #expect(!EventGuests.same([jamie], [jamie, alex]))
    }
}
