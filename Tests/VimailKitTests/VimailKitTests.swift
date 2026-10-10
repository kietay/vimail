import Foundation
import Testing
@testable import MailCore
@testable import VimailKit

@Suite("Keymap")
struct KeymapTests {
    func run(_ keys: [KeyStroke]) -> [KeySequenceParser.Result] {
        var parser = KeySequenceParser()
        return keys.map { parser.feed($0) }
    }

    @Test func singleKeys() {
        #expect(run([.char("j")]) == [.command(.down, count: 1)])
        #expect(run([.char("e")]) == [.command(.archive, count: 1)])
        #expect(run([.char("G")]) == [.command(.bottom, count: 1)])
        #expect(run([.char("#")]) == [.command(.trash, count: 1)])
        // No sequence starts with b, so it never waits for a second key.
        #expect(run([.char("b")]) == [.command(.quickSnooze, count: 1)])
    }

    @Test func sequencesAndCounts() {
        #expect(run([.char("g"), .char("g")]) == [.pending, .command(.top, count: 1)])
        #expect(run([.char("d"), .char("d")]) == [.pending, .command(.trash, count: 1)])
        #expect(run([.char("g"), .char("i")]) == [.pending, .command(.go(.inbox), count: 1)])
        #expect(run([.char("1"), .char("2"), .char("j")]) == [.pending, .pending, .command(.down, count: 12)])
        #expect(run([.char("*"), .char("a")]) == [.pending, .command(.selectAll, count: 1)])
    }

    @Test func rulesKeys() {
        #expect(run([.char("g"), .char("?")]) == [.pending, .command(.explainLabels, count: 1)])
        // No sequence starts with =, so it never waits for a second key.
        #expect(run([.char("=")]) == [.command(.runRules, count: 1)])
        // ? alone is still help.
        #expect(run([.char("?")]) == [.command(.help, count: 1)])
        #expect(run([.char("g"), .char("r")]) == [.pending, .command(.manageRules, count: 1)])
        // No sequence starts with T.
        #expect(run([.char("T")]) == [.command(.ruleFromThread, count: 1)])
    }

    @Test func peopleKeys() {
        // No sequence starts with i or P, so neither waits for a second key.
        #expect(run([.char("i")]) == [.command(.quickList, count: 1)])
        #expect(run([.char("P")]) == [.command(.listPicker, count: 1)])
        #expect(run([.char("g"), .char("p")]) == [.pending, .command(.managePeople, count: 1)])
    }

    @Test func modifiersAndSpecialKeys() {
        #expect(run([KeyStroke(.char("d"), control: true)]) == [.command(.halfPageDown, count: 1)])
        #expect(run([KeyStroke(.char("k"), command: true)]) == [.command(.omnibox, count: 1)])
        #expect(run([KeyStroke(.space, shift: true)]) == [.command(.readerPageUp, count: 1)])
        #expect(run([KeyStroke(.enter)]) == [.command(.open, count: 1)])
        #expect(run([KeyStroke(.escape)]) == [.command(.escape, count: 1)])
    }

    @Test func unboundAndEscapeClearPending() {
        var parser = KeySequenceParser()
        #expect(parser.feed(.char("g")) == .pending)
        #expect(parser.display == "g")
        #expect(parser.feed(.char("q")) == .unbound)
        #expect(!parser.isPending)
        #expect(parser.feed(.char("3")) == .pending)
        #expect(parser.display == "3")
        #expect(parser.feed(KeyStroke(.escape)) == .unbound)
        #expect(parser.feed(.char("0")) == .unbound)
    }
}

@Suite("Markdown")
struct MarkdownTests {
    @Test func paragraphsAndHardBreaks() {
        let html = Markdown.html("Hi Alex,\n\nThanks for this.\nTalk soon,\nSam")
        #expect(html.contains("<p style=\"margin:0 0 12px 0;\">Hi Alex,</p>"))
        #expect(html.contains("Thanks for this.<br>Talk soon,<br>Sam"))
    }

    @Test func inlineFormatting() {
        let html = Markdown.inline("**bold** and *italic* and `x < y` and ~~old~~")
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
        #expect(html.contains("x &lt; y</code>"))
        #expect(html.contains("<del>old</del>"))
    }

    @Test func linksAreNotDoubleLinked() {
        let html = Markdown.inline("See [the doc](https://example.com/a) or https://example.com/b.")
        #expect(html.contains("<a href=\"https://example.com/a\""))
        #expect(html.contains("<a href=\"https://example.com/b\""))
        #expect(html.hasSuffix("</a>."))
        #expect(html.components(separatedBy: "<a ").count == 3)
    }

    @Test func listsQuotesAndCode() {
        let html = Markdown.html("- one\n- two\n  - nested\n\n1. first\n2. second\n\n> quoted **text**\n\n```\nlet x = 1 < 2\n```")
        #expect(html.contains("<ul"))
        #expect(html.contains("<li style=\"margin:2px 0;\">two<ul"))
        #expect(html.contains("<ol"))
        #expect(html.contains("<blockquote"))
        #expect(html.contains("<strong>text</strong>"))
        #expect(html.contains("let x = 1 &lt; 2"))
    }

    @Test func escapesRawHTML() {
        #expect(!Markdown.html("<script>alert(1)</script>").contains("<script>"))
    }

    @Test func snakeCaseIsNotItalic() {
        #expect(!Markdown.inline("call my_function_name now").contains("<em>"))
    }
}

@Suite("Email composition")
struct EmailComposerTests {
    let me = EmailAddress(name: "Sam Carter", email: "sam@hey.com")
    let source = MailMessage(
        id: "m1", threadID: "t1", labelIDs: ["INBOX"], from: EmailAddress(name: "Alex Morgan", email: "alex@studio.co"),
        to: [EmailAddress(name: "Sam Carter", email: "sam@hey.com")], subject: "Plan", snippet: "Hello",
        date: Date(timeIntervalSince1970: 1_791_000_000), textBody: "Hello there", messageIDHeader: "<m1@x>", references: ["<m0@x>"]
    )

    @Test func replyHasThreadingHeadersAndQuote() {
        var draft = ReplyComposer.reply(to: source, all: false, me: ["sam@hey.com"])
        draft.body = "Sounds **good**."
        let outgoing = EmailComposer.outgoing(draft: draft, source: source, signature: .markdown("Sam"), from: me)
        #expect(outgoing.subject == "Re: Plan")
        #expect(outgoing.to.map(\.email) == ["alex@studio.co"])
        #expect(outgoing.threadID == "t1")
        #expect(outgoing.inReplyTo == "<m1@x>")
        #expect(outgoing.references == ["<m0@x>", "<m1@x>"])
        #expect(outgoing.htmlBody?.contains("<strong>good</strong>") == true)
        #expect(outgoing.htmlBody?.contains("vimail-quote") == true)
        #expect(outgoing.textBody.contains("> Hello there"))
        #expect(outgoing.textBody.contains("-- \nSam"))
    }

    @Test func forwardKeepsAttachmentsAndHasNoThread() {
        var message = source
        message.attachments = [MailAttachment(id: "a1", filename: "deck.pdf", mimeType: "application/pdf", size: 10)]
        let draft = ReplyComposer.forward(message)
        let outgoing = EmailComposer.outgoing(draft: draft, source: message, signature: .markdown(""), from: me)
        #expect(outgoing.subject == "Fwd: Plan")
        #expect(outgoing.threadID == nil)
        #expect(outgoing.attachments.count == 1)
        #expect(outgoing.textBody.contains("Forwarded message"))
    }

    @Test func fuzzyMatchingRanksPrefixesHigher() {
        let prefix = FuzzyMatcher.score(query: "arch", in: "Archive selected")
        let middle = FuzzyMatcher.score(query: "arch", in: "Search archives")
        #expect(prefix != nil && middle != nil)
        #expect(prefix! > middle!)
        #expect(FuzzyMatcher.score(query: "zzz", in: "Archive") == nil)
    }
}
