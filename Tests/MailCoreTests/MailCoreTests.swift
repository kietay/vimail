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

    @Test func typedRecipientsFinishOnSeparatorsAndClosingBracket() {
        func split(_ text: String) -> ([String], String) {
            let result = EmailAddress.splitTyped(text)
            return (result.finished.map(\.formatted), result.typing)
        }
        #expect(split("a@b.co, ") == (["a@b.co"], ""))
        #expect(split("a@b.co, ben@") == (["a@b.co"], "ben@"))
        #expect(split("a@b.co; Ben Ortiz <ben@x.io>, c") == (["a@b.co", "Ben Ortiz <ben@x.io>"], "c"))
        #expect(split("Aahel Iyer <aahel@x.com>") == (["Aahel Iyer <aahel@x.com>"], ""))
        #expect(split("Aahel Iyer <aahel.iye") == ([], "Aahel Iyer <aahel.iye"))
        #expect(split("\"Morgan, Alex\" <al") == ([], "\"Morgan, Alex\" <al"))
        #expect(split("nina") == ([], "nina"))
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

@Suite("Unsubscribe")
struct UnsubscribeTests {
    let news = EmailAddress(name: "The Browser", email: "hello@thebrowser.com")
    let sam = EmailAddress(name: "Sam", email: "sam@hey.com")

    func mail(_ id: String = "1", from: EmailAddress? = nil, header: String?, oneClick: Bool? = false, html: String? = nil, text: String? = nil) -> MailMessage {
        MailMessage(id: id, threadID: "t", labelIDs: ["INBOX"], from: from ?? news, to: [sam], subject: "Issue 12", snippet: "",
                    date: Date(timeIntervalSince1970: Double(id) ?? 0), textBody: text, htmlBody: html, listUnsubscribe: header, oneClickUnsubscribe: oneClick)
    }

    @Test func readsTheHeaderInTheSendersOrder() {
        let uris = Unsubscribe.uris(in: "<mailto:unsub@list.co?subject=unsubscribe>,\r\n <https://list.co/u?id=1&t=a b>, <javascript:alert(1)>, (comment)")
        #expect(uris.map(\.absoluteString) == ["mailto:unsub@list.co?subject=unsubscribe", "https://list.co/u?id=1&t=ab"])
        // Without angle brackets, as some senders write it.
        #expect(Unsubscribe.uris(in: "https://list.co/u, mailto:x@list.co").map(\.absoluteString) == ["https://list.co/u", "mailto:x@list.co"])
        #expect(Unsubscribe.uris(in: "<https://>, <ftp://list.co/u>").isEmpty)
    }

    @Test func prefersOneClickThenEmailThenThePage() {
        let both = "<https://list.co/u>, <mailto:unsub@list.co>"
        #expect(mail(header: both, oneClick: true).listUnsubscribeMethod == .oneClick(URL(string: "https://list.co/u")!))
        #expect(mail(header: both, oneClick: false).listUnsubscribeMethod == .email(to: EmailAddress(email: "unsub@list.co"), subject: "Unsubscribe", body: "Unsubscribe"))
        #expect(mail(header: "<http://list.co/u>, <https://list.co/v>").listUnsubscribeMethod == .website(URL(string: "https://list.co/v")!))
        // One-click needs HTTPS.
        #expect(mail(header: "<http://list.co/u>", oneClick: true).listUnsubscribeMethod == .website(URL(string: "http://list.co/u")!))
        #expect(mail(header: nil).listUnsubscribeMethod == nil)
    }

    @Test func emailKeepsTheListsCommandButNotExtraRecipients() throws {
        let url = try #require(URL(string: "mailto:list-request@lists.org?subject=unsubscribe%0D%0ABcc:%20x@evil.co&body=SIGNOFF%20LIST&cc=boss@work.co"))
        #expect(Unsubscribe.email(url) == .email(to: EmailAddress(email: "list-request@lists.org"), subject: "unsubscribe Bcc: x@evil.co", body: "SIGNOFF LIST"))
        #expect(Unsubscribe.email(URL(string: "mailto:?to=leave@lists.org")!) == .email(to: EmailAddress(email: "leave@lists.org"), subject: "Unsubscribe", body: "Unsubscribe"))
        #expect(Unsubscribe.email(URL(string: "mailto:not-an-address")!) == nil)
        #expect(Unsubscribe.email(URL(string: "https://list.co/u")!) == nil)
    }

    @Test func findsTheFootersUnsubscribeLink() {
        let html = """
        <p>Read <a href="https://news.co/post/unsubscribe-from-noise">this essay</a>.</p>
        <a href='https://news.co/prefs'>Manage preferences</a>
        <A class="x" HREF="https://news.co/u?a=1&amp;b=2"><span>Unsubscribe</span></A> · <a href="mailto:x@news.co">unsubscribe by email</a>
        """
        #expect(Unsubscribe.link(inHTML: html) == URL(string: "https://news.co/u?a=1&b=2"))
        // Only the address mentions it.
        #expect(Unsubscribe.link(inHTML: #"<a href="https://news.co/optout?id=4">Click here</a>"#) == URL(string: "https://news.co/optout?id=4"))
        #expect(Unsubscribe.link(inHTML: #"<a href="https://news.co">Home</a> <abbr>unsubscribe</abbr>"#) == nil)

        #expect(Unsubscribe.link(inText: "Thanks!\n\nTo unsubscribe, visit:\nhttps://list.co/leave?u=9.\nSite: https://list.co") == URL(string: "https://list.co/leave?u=9"))
        #expect(Unsubscribe.link(inText: "Unsubscribe: https://list.co/u\nOur site: https://list.co") == URL(string: "https://list.co/u"))
        #expect(Unsubscribe.link(inText: "See https://list.co/docs for details.") == nil)
    }

    @Test func aConversationUsesItsNewestListMessage() {
        let older = mail("1", header: "<https://list.co/old>", oneClick: true)
        let newer = mail("2", header: "<https://list.co/new>", oneClick: true)
        let reply = mail("3", from: sam, header: nil, text: "Unsubscribe me: https://list.co/me")
        let thread = MailThread(id: "t", subject: "Issue 12", messages: [older, newer, reply], labelIDs: ["INBOX"])
        let target = thread.unsubscribeTarget(excluding: ["sam@hey.com"])
        #expect(target?.message.id == "2")
        #expect(target?.method == .oneClick(URL(string: "https://list.co/new")!))

        // No header anywhere: the newest received message's link.
        let plain = MailThread(id: "t", subject: "Hi", messages: [mail("1", header: nil, html: #"<a href="https://a.co/unsubscribe">Unsubscribe</a>"#), reply], labelIDs: [])
        #expect(plain.unsubscribeTarget(excluding: ["sam@hey.com"])?.method == .website(URL(string: "https://a.co/unsubscribe")!))
        #expect(MailThread(id: "t", subject: "", messages: [reply], labelIDs: []).unsubscribeTarget(excluding: ["sam@hey.com"]) == nil)
    }

    @Test func onlyMailCachedBeforeTheCheckNeedsOne() {
        #expect(mail(header: "<https://list.co/u>", oneClick: nil).needsOneClickCheck)
        #expect(!mail(header: "<https://list.co/u>", oneClick: false).needsOneClickCheck)
        #expect(!mail(header: "<mailto:u@list.co>", oneClick: nil).needsOneClickCheck)
        #expect(!mail(header: nil, oneClick: nil).needsOneClickCheck)
    }

    @Test func queuedEmailComesFromTheAccount() throws {
        let method = UnsubscribeMethod.email(to: EmailAddress(email: "unsub@list.co"), subject: "unsubscribe", body: "Unsubscribe")
        let request = try #require(UnsubscribeRequest(method, list: "The Browser", from: sam))
        guard case .email(let message) = request.method else {
            Issue.record("Expected an email")
            return
        }
        #expect(message.from == sam && message.to == [EmailAddress(email: "unsub@list.co")] && message.subject == "unsubscribe")
        #expect(message.messageID?.hasSuffix("@hey.com>") == true)
        #expect(UnsubscribeRequest(.website(URL(string: "https://list.co")!), list: "x", from: sam) == nil)
        // Survives the outbox's JSON.
        #expect(try JSONDecoder().decode(UnsubscribeRequest.self, from: JSONEncoder().encode(request)) == request)
    }
}
