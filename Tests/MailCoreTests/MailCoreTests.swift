import Foundation
import Testing
@testable import MailCore

@Suite("Addresses")
struct AddressTests {
    @Test func parsesNamedAndQuotedAddresses() {
        let list = EmailAddress.parseList("\"Morgan, Alex\" <alex@studio.co>, nina@fastmail.com; Ben Ortiz <ben@icloud.com>")
        #expect(list.map(\.email) == ["alex@studio.co", "nina@fastmail.com", "ben@icloud.com"])
        #expect(list[0].name == "Morgan, Alex")
        #expect(list[0].formatted == "\"Morgan, Alex\" <alex@studio.co>")
        #expect(list[2].formatted == "Ben Ortiz <ben@icloud.com>")
    }

    @Test func initials() {
        #expect(EmailAddress(name: "Alex Morgan", email: "a@b.c").initials == "AM")
        #expect(EmailAddress(name: "Linear", email: "n@linear.app").initials == "L")
        #expect(EmailAddress(name: "The Browser", email: "h@b.com").initials == "B")
        #expect(EmailAddress(email: "jamie@studio.co").initials == "J")
    }
}

@Suite("Search syntax")
struct SearchQueryTests {
    @Test func operators() {
        let query = SearchQuery.parse("from:alex \"next chapter\" budget -spam is:unread has:attachment in:trash label:work")
        #expect(query.from == ["alex"])
        #expect(query.phrases == ["next chapter"])
        #expect(query.terms == ["budget"])
        #expect(query.excluded == ["spam"])
        #expect(query.read == .unread)
        #expect(query.hasAttachment == true)
        #expect(query.scope == .mailbox(.trash))
        #expect(query.labelNames == ["work"])
    }

    @Test func relativeDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let query = SearchQuery.parse("newer_than:2d", now: now)
        #expect(query.after == Calendar.current.date(byAdding: .day, value: -2, to: now))
    }

    @Test func unknownOperatorsAreText() {
        #expect(SearchQuery.parse("re:hello").terms == ["re:hello"])
    }
}

@Suite("Replies")
struct ReplyTests {
    let me: Set<String> = ["sam@hey.com"]
    let alex = EmailAddress(name: "Alex", email: "alex@studio.co")
    let jamie = EmailAddress(name: "Jamie", email: "jamie@studio.co")
    let sam = EmailAddress(name: "Sam", email: "sam@hey.com")

    @Test func replyAllExcludesMeAndDeduplicates() {
        let message = MailMessage(id: "1", threadID: "t", labelIDs: [], from: alex, to: [sam, jamie], cc: [alex, EmailAddress(email: "SAM@hey.com")], subject: "Re: Plan", snippet: "", date: Date())
        let draft = ReplyComposer.reply(to: message, all: true, me: me)
        #expect(draft.to.map(\.email) == ["alex@studio.co", "jamie@studio.co"])
        #expect(draft.cc.isEmpty)
        #expect(draft.subject == "Re: Plan")
    }

    @Test func replyToOwnMessageGoesToOriginalRecipients() {
        let message = MailMessage(id: "1", threadID: "t", labelIDs: ["SENT"], from: sam, to: [jamie], subject: "Plan", snippet: "", date: Date())
        let draft = ReplyComposer.reply(to: message, all: false, me: me)
        #expect(draft.to.map(\.email) == ["jamie@studio.co"])
    }

    @Test func subjectPrefixes() {
        #expect(ReplyComposer.prefixed("Plan", with: "Re") == "Re: Plan")
        #expect(ReplyComposer.prefixed("RE: Plan", with: "Re") == "RE: Plan")
        #expect(ReplyComposer.prefixed("Fw: Plan", with: "Fwd") == "Fw: Plan")
    }
}

@Suite("HTML text")
struct HTMLTextTests {
    @Test func stripsStylesScriptsAndDecodesEntities() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hi &amp; welcome&#39;s</p><script>x()</script><div>Next</div></body></html>"
        #expect(HTMLText.plainText(fromHTML: html) == "Hi & welcome's\n\nNext")
    }

    @Test func snippetsSkipQuotes() {
        #expect(HTMLText.snippet(from: "Thanks!\n> old text\nSam") == "Thanks! Sam")
        #expect(HTMLText.snippet(from: "Sounds good.\nIni\n\nOn Wed, Oct 7, 2026 at 8:01 PM, Sam <s@x.y> wrote:\n> hi") == "Sounds good. Ini")
        #expect(HTMLText.snippet(from: "Hi\n-- \nSam Carter\nStudio") == "Hi")
    }

    @Test func snippetSkipsDividersAndHelpDeskMarkers() {
        let text = "—————— Reply above this line.\n*****************\nAshley changed the status.\nOn Mon, Oct 5, 2026 at 9:00 AM Sam <s@x.co> wrote:\n> old"
        #expect(HTMLText.snippet(from: text) == "Ashley changed the status.")
        #expect(HTMLText.snippet(from: "##- Please type your reply above this line -##\nThanks for waiting") == "Thanks for waiting")
    }
}

@Suite("Drafts")
struct DraftTests {
    @Test func signatureChoiceSurvivesSaving() throws {
        for choice in [SignatureChoice.off, .account, .custom("work")] {
            let saved = try JSONEncoder().encode(Draft(body: "hi", signature: choice))
            #expect(try JSONDecoder().decode(Draft.self, from: saved).signature == choice)
        }
    }

    @Test func draftsSavedBeforeSignaturesStillLoad() throws {
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Draft(body: "old"))) as! [String: Any]
        payload["signature"] = nil
        let old = try JSONSerialization.data(withJSONObject: payload)
        let draft = try JSONDecoder().decode(Draft.self, from: old)
        #expect(draft.body == "old")
        #expect(draft.signature == nil)
    }
}
