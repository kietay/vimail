import Foundation
import MailCore

/// The cast and the text used by the dummy mailbox. All names and addresses are fictional.
enum DummyContent {
    struct Person {
        enum Group { case colleague, client, personal }
        var address: EmailAddress
        var group: Group
        var title: String
        var company: String
    }

    static let account = EmailAddress(name: "Sam Carter", email: "sam@hey.com")

    static let people: [Person] = [
        Person(address: EmailAddress(name: "Alex Morgan", email: "alex.morgan@studio.co"), group: .colleague, title: "Co-founder", company: "Studio North"),
        Person(address: EmailAddress(name: "Jamie Chen", email: "jamie.chen@studio.co"), group: .colleague, title: "Design Lead", company: "Studio North"),
        Person(address: EmailAddress(name: "Priya Raman", email: "priya@studio.co"), group: .colleague, title: "Engineering", company: "Studio North"),
        Person(address: EmailAddress(name: "Chris Yu", email: "chris.yu@studio.co"), group: .colleague, title: "Operations", company: "Studio North"),
        Person(address: EmailAddress(name: "Maya Brooks", email: "maya@studio.co"), group: .colleague, title: "Producer", company: "Studio North"),
        Person(address: EmailAddress(name: "Oliver Lewis", email: "oliver@northfield.agency"), group: .client, title: "Art Director", company: "Northfield"),
        Person(address: EmailAddress(name: "Marcus Webb", email: "marcus@lumenlabs.io"), group: .client, title: "VP Product", company: "Lumen Labs"),
        Person(address: EmailAddress(name: "Hannah Lee", email: "hannah@lumenlabs.io"), group: .client, title: "Product Manager", company: "Lumen Labs"),
        Person(address: EmailAddress(name: "Elena Rossi", email: "elena@rossiarchitetti.it"), group: .client, title: "Principal", company: "Rossi Architetti"),
        Person(address: EmailAddress(name: "Dana Whitfield", email: "dana@whitfieldlegal.com"), group: .client, title: "Counsel", company: "Whitfield Legal"),
        Person(address: EmailAddress(name: "Tom Becker", email: "tom@kilnaccounting.com"), group: .client, title: "Accountant", company: "Kiln Accounting"),
        Person(address: EmailAddress(name: "Sofia Alvarez", email: "sofia@tidewater.vc"), group: .client, title: "Partner", company: "Tidewater"),
        Person(address: EmailAddress(name: "Nina Park", email: "nina.park@fastmail.com"), group: .personal, title: "", company: ""),
        Person(address: EmailAddress(name: "Ben Ortiz", email: "ben.ortiz@icloud.com"), group: .personal, title: "", company: ""),
        Person(address: EmailAddress(name: "Margaret Carter", email: "margaret.carter@outlook.com"), group: .personal, title: "", company: ""),
        Person(address: EmailAddress(name: "Leo Carter", email: "leo.carter@hey.com"), group: .personal, title: "", company: ""),
        Person(address: EmailAddress(name: "Ines Duarte", email: "ines@duarte.studio"), group: .personal, title: "", company: ""),
    ]

    static func person(_ name: String) -> Person { people.first { $0.address.name == name }! }

    static var colleagues: [Person] { people.filter { $0.group == .colleague } }
    static var clients: [Person] { people.filter { $0.group == .client } }
    static var friends: [Person] { people.filter { $0.group == .personal } }

    // MARK: - Labels

    /// Label IDs follow Gmail's `Label_N` format. Colors map to the theme palette.
    static let userLabels: [MailLabel] = [
        MailLabel(id: "Label_1", name: "work", kind: .user, colorIndex: 0),
        MailLabel(id: "Label_2", name: "personal", kind: .user, colorIndex: 1),
        MailLabel(id: "Label_3", name: "updates", kind: .user, colorIndex: 2),
        MailLabel(id: "Label_4", name: "reading", kind: .user, colorIndex: 3),
        MailLabel(id: "Label_5", name: "receipts", kind: .user, colorIndex: 4),
        MailLabel(id: "Label_6", name: "travel", kind: .user, colorIndex: 5),
    ]
    static let work = "Label_1", personal = "Label_2", updates = "Label_3", reading = "Label_4", receipts = "Label_5", travel = "Label_6"

    static let systemLabels: [MailLabel] = SystemLabel.all.sorted().map { MailLabel(id: $0, name: $0, kind: .system) }

    // MARK: - Work conversations

    static let workSubjects = [
        "Q4 roadmap draft", "Brand refresh — round 2 feedback", "Hiring: senior product designer", "Studio offsite planning",
        "Website copy review", "Pricing page experiments", "Design crit on Thursday", "New case study for the portfolio",
        "Accessibility audit results", "Moodboard for the spring campaign", "Typeface licensing", "Analytics dashboard v2",
        "Workshop agenda", "Onboarding doc for Maya", "Retainer renewal", "Photo shoot logistics", "Feedback on the deck",
        "Budget for next quarter", "Interview loop for Friday", "Podcast interview request", "Team lunch on Friday",
        "Motion guidelines", "Component library cleanup", "Holiday schedule", "Sprint review notes",
    ]

    static let clientSubjects = [
        "Kickoff notes — Lumen Labs", "Updated SOW", "Contract redlines", "Invoice #2041 question", "Revised timeline",
        "Homepage concepts", "Next steps after the review", "Site launch checklist", "Content migration plan",
        "Quick question about the brand guide", "Thanks for yesterday", "Phase two scope", "Intro: Tidewater portfolio founders",
    ]

    static let openers = [
        "Hope your week is going well.", "Quick one before I forget.", "Thanks for turning this around so fast.",
        "Following up on our chat earlier.", "I had a look this morning.", "Circling back on this.",
        "Sorry for the slow reply — it's been a week.", "Picking this back up.",
    ]

    static let middles = [
        "I think the direction is right, but the second section still feels a bit busy. Could we try removing the sidebar and letting the imagery breathe?",
        "The numbers look healthy overall. The one thing I'd flag is the drop-off on the pricing page, which is worth a closer look before we change anything else.",
        "Can we lock the scope by Friday? If we keep adding to it we will miss the launch window, and I'd rather ship something tight.",
        "I've shared the latest version in the team folder. Most of the changes are in the typography and spacing; the layout is the same.",
        "We have budget for one more round of revisions. After that, any changes should go into phase two.",
        "I spoke to legal and they're fine with the license terms as long as we keep the attribution in the footer.",
        "Let's plan for a 45-minute session. I'll bring the research findings, and it would be great if you could walk us through the prototype.",
        "The client loved the second option. They asked whether we could try it with a warmer palette.",
        "I added comments directly in the doc. Nothing major — mostly wording and a couple of questions about the timeline.",
        "Engineering estimates about two weeks for the first milestone, assuming the API work lands on time.",
        "One thought: if we move the testimonials higher up, the page reads more like a story and less like a brochure.",
        "I'm out on Monday, but happy to pick this up Tuesday morning if that works for everyone.",
    ]

    static let closers = [
        "Let me know what you think.", "No rush on this.", "Happy to jump on a call if easier.",
        "Thanks again!", "Talk soon.", "Shout if anything looks off.", "Appreciate it.",
    ]

    static let replies = [
        "Sounds good — let's do that.", "Agreed. I'll update the doc and share it this afternoon.",
        "Works for me. Thursday at 2pm?", "Great, thanks for the quick turnaround!",
        "I think that's the right call. Let's keep it simple.", "Can you send the latest file? I can't find it in the folder.",
        "Perfect. I'll let the team know.", "Exactly. Let's keep the scope tight and give ourselves room to polish.",
        "Love it. One small note: the headline wraps awkwardly on mobile.", "Yes — and let's loop in Priya for the technical side.",
    ]

    static let personalSubjects = [
        "Dinner Saturday?", "Photos from the weekend", "Happy birthday!!", "That book I mentioned", "Hike this Sunday?",
        "Flight details for the holidays", "Recipe you asked for", "Concert tickets", "Moving day help", "Long time!",
    ]

    static let personalBodies = [
        "Are you around this weekend? We were thinking of trying the new Thai place on 24th. Let me know!",
        "Finally got the photos off my camera. A few of them turned out really nice — sending the best ones over.",
        "I finished it last night and couldn't put it down. You have to read it next, I'll bring it over.",
        "Weather looks good for Sunday. Thinking we start early, around 8, and grab breakfast after?",
        "Here's that recipe. The trick is to toast the spices first — don't skip it.",
        "I have two extra tickets for Friday. Want to come? It should be a fun one.",
        "It's been too long! How are things? Would love to catch up properly soon.",
    ]

    static let personalReplies = [
        "Yes! Count me in.", "Ha, love these. Thanks for sending!", "Sunday works. See you at 8.",
        "Can't wait. I'll bring dessert.", "So good to hear from you!",
    ]

    // MARK: - Notifications

    static let issueTitles = [
        "Navigation collapses on small screens", "Add keyboard shortcuts to the editor", "Update onboarding illustrations",
        "Fix flaky checkout test", "Dark mode contrast issues", "Improve image loading on the homepage",
        "Migrate analytics events", "Search results ignore accents", "Export to PDF cuts off tables",
    ]

    static let repoNames = ["studionorth/site", "studionorth/design-system", "lumenlabs/web"]
    static let figmaFiles = ["Brand refresh 2026", "Website — Homepage", "Lumen app — v2", "Pitch deck"]
    static let slackChannels = ["design", "general", "lumen-project", "random"]
    static let notionPages = ["Q4 Planning", "Hiring Pipeline", "Studio Handbook", "Client Directory"]
    static let meetings = ["Design review", "Weekly sync", "Lumen check-in", "1:1 with Alex", "Studio all-hands", "Portfolio planning"]
    static let vendors = [("Figma", "Professional plan"), ("Notion", "Plus plan"), ("Linear", "Standard plan"), ("Adobe", "Creative Cloud"), ("GitHub", "Team plan"), ("Vercel", "Pro plan")]
    static let cities = ["Lisbon", "Copenhagen", "Tokyo", "New York", "Mexico City"]

    struct Service {
        var address: EmailAddress
        var labels: Set<String>
        /// The `List-Unsubscribe` header of its mail, and whether it is RFC 8058 one-click.
        var listUnsubscribe: String?
        var oneClickUnsubscribe = false
    }

    static let linear = Service(address: EmailAddress(name: "Linear", email: "notifications@linear.app"), labels: [updates, SystemLabel.categoryUpdates])
    static let github = Service(address: EmailAddress(name: "GitHub", email: "notifications@github.com"), labels: [updates, SystemLabel.categoryUpdates],
                                listUnsubscribe: "<mailto:unsub@reply.github.example>, <https://github.example/notifications/unsubscribe?u=sam>", oneClickUnsubscribe: true)
    static let vercel = Service(address: EmailAddress(name: "Vercel", email: "notifications@vercel.com"), labels: [updates, SystemLabel.categoryUpdates])
    static let figma = Service(address: EmailAddress(name: "Figma", email: "comments-noreply@figma.com"), labels: [updates, SystemLabel.categoryUpdates])
    static let notion = Service(address: EmailAddress(name: "Notion", email: "notify@mail.notion.so"), labels: [updates, SystemLabel.categoryUpdates])
    static let slack = Service(address: EmailAddress(name: "Slack", email: "notification@slack.com"), labels: [updates, SystemLabel.categoryUpdates])
    static let calendar = Service(address: EmailAddress(name: "Google Calendar", email: "calendar-notification@google.com"), labels: [work, SystemLabel.categoryPersonal])
    static let stripe = Service(address: EmailAddress(name: "Stripe", email: "receipts@stripe.com"), labels: [receipts, SystemLabel.categoryUpdates])
    static let airline = Service(address: EmailAddress(name: "Northwind Air", email: "itinerary@northwindair.com"), labels: [travel, SystemLabel.categoryUpdates])
    // One newsletter per way to unsubscribe: one-click, email only, web page only.
    static let theBrowser = Service(address: EmailAddress(name: "The Browser", email: "hello@thebrowser.com"), labels: [reading, SystemLabel.categoryPromotions],
                                    listUnsubscribe: "<https://thebrowser.example/unsubscribe?u=sam>, <mailto:unsubscribe@thebrowser.example?subject=unsubscribe>", oneClickUnsubscribe: true)
    static let arena = Service(address: EmailAddress(name: "Are.na", email: "hello@are.na"), labels: [reading, SystemLabel.categoryUpdates],
                               listUnsubscribe: "<mailto:leave@are.na.example>")
    static let margins = Service(address: EmailAddress(name: "Margins Weekly", email: "letters@marginsweekly.com"), labels: [reading, SystemLabel.categoryPromotions],
                                 listUnsubscribe: "<https://marginsweekly.example/unsubscribe?u=sam>")

    static let spam: [(EmailAddress, String, String)] = [
        (EmailAddress(name: "Prize Center", email: "winner@prize-center.biz"), "You've been selected for an exclusive reward", "Claim your $500 gift card today. Offer ends at midnight."),
        (EmailAddress(name: "Account Security", email: "secure@acc0unt-verify.net"), "Final notice: verify your account", "Your account will be suspended unless you verify your details within 24 hours."),
        (EmailAddress(name: "Crypto Alerts", email: "alerts@moonshot-coins.io"), "This coin is up 4,000% this week", "Don't miss the next big thing. Early investors are already seeing returns."),
    ]

    // MARK: - HTML building blocks

    /// A notification card that looks like a typical product email (light background).
    static func notificationHTML(brand: String, accent: String, title: String, body: String, button: String, footer: String) -> String {
        """
        <!doctype html><html><body style="margin:0;padding:0;background:#f4f4f2;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f2;padding:32px 0;">
        <tr><td align="center">
        <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:12px;border:1px solid #e6e6e1;font-family:-apple-system,'Helvetica Neue',Arial,sans-serif;color:#1f2328;">
        <tr><td style="padding:28px 32px 0 32px;font-size:15px;font-weight:600;color:\(accent);">\(brand)</td></tr>
        <tr><td style="padding:16px 32px 0 32px;font-size:20px;font-weight:600;line-height:1.35;">\(title)</td></tr>
        <tr><td style="padding:12px 32px 0 32px;font-size:14px;line-height:1.6;color:#4b5058;">\(body)</td></tr>
        <tr><td style="padding:24px 32px 32px 32px;"><a href="https://example.com/open" style="display:inline-block;background:\(accent);color:#ffffff;text-decoration:none;font-size:14px;font-weight:600;padding:10px 18px;border-radius:8px;">\(button)</a></td></tr>
        </table>
        <p style="font-family:-apple-system,Arial,sans-serif;font-size:12px;color:#8a8f98;margin:18px 0 0 0;">\(footer)</p>
        </td></tr></table></body></html>
        """
    }

    static func newsletterHTML(name: String, issue: String, intro: String, items: [(String, String)]) -> String {
        let rows = items.enumerated().map { index, item in
            """
            <tr><td style="padding:18px 0;border-top:1px solid #ece7dc;">
            <div style="font-size:12px;letter-spacing:1px;color:#9a8f7a;text-transform:uppercase;">\(String(format: "%02d", index + 1))</div>
            <a href="https://example.com/read/\(index + 1)" style="display:block;margin-top:6px;font-size:18px;font-weight:600;color:#2b2722;text-decoration:none;">\(item.0)</a>
            <p style="margin:6px 0 0 0;font-size:15px;line-height:1.6;color:#5b544a;">\(item.1)</p>
            </td></tr>
            """
        }.joined()
        return """
        <!doctype html><html><body style="margin:0;background:#fbf8f2;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fbf8f2;"><tr><td align="center" style="padding:36px 16px;">
        <table role="presentation" width="580" cellpadding="0" cellspacing="0" style="font-family:Georgia,'Times New Roman',serif;color:#2b2722;">
        <tr><td style="font-size:28px;font-weight:700;padding-bottom:4px;">\(name)</td></tr>
        <tr><td style="font-size:13px;color:#9a8f7a;padding-bottom:20px;">\(issue)</td></tr>
        <tr><td style="font-size:16px;line-height:1.7;padding-bottom:12px;">\(intro)</td></tr>
        \(rows)
        <tr><td style="padding-top:28px;font-size:12px;color:#9a8f7a;">You're receiving this because you subscribed. <a href="https://example.com/unsubscribe" style="color:#9a8f7a;">Unsubscribe</a></td></tr>
        </table></td></tr></table></body></html>
        """
    }

    static func receiptHTML(vendor: String, plan: String, amount: String, number: String, date: String) -> String {
        """
        <!doctype html><html><body style="margin:0;background:#f6f9fc;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f6f9fc;padding:32px 0;"><tr><td align="center">
        <table role="presentation" width="520" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:10px;font-family:-apple-system,'Helvetica Neue',Arial,sans-serif;color:#32325d;">
        <tr><td style="padding:32px 32px 8px 32px;font-size:13px;color:#8898aa;text-transform:uppercase;letter-spacing:1px;">Receipt from \(vendor)</td></tr>
        <tr><td style="padding:0 32px;font-size:30px;font-weight:600;">\(amount)</td></tr>
        <tr><td style="padding:4px 32px 24px 32px;font-size:14px;color:#8898aa;">Paid \(date)</td></tr>
        <tr><td style="padding:0 32px 24px 32px;">
        <table width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;border-top:1px solid #e6ebf1;">
        <tr><td style="padding:12px 0;color:#525f7f;">Receipt number</td><td align="right" style="padding:12px 0;">\(number)</td></tr>
        <tr><td style="padding:12px 0;color:#525f7f;border-top:1px solid #e6ebf1;">\(plan)</td><td align="right" style="padding:12px 0;border-top:1px solid #e6ebf1;">\(amount)</td></tr>
        <tr><td style="padding:12px 0;font-weight:600;border-top:1px solid #e6ebf1;">Total</td><td align="right" style="padding:12px 0;font-weight:600;border-top:1px solid #e6ebf1;">\(amount)</td></tr>
        </table></td></tr>
        <tr><td style="padding:0 32px 32px 32px;font-size:12px;color:#8898aa;">Questions? Reply to this email or contact billing support.</td></tr>
        </table></td></tr></table></body></html>
        """
    }

    static func simpleHTML(_ paragraphs: [String]) -> String {
        paragraphs.map { "<p>\(HTMLText.escape($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }.joined(separator: "\n")
    }
}
