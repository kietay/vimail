import Foundation
import MailCore

/// Builds the dummy mailbox: the design's nine sample emails at the top of the inbox, plus
/// about 120 days of realistic history (conversations, notifications, newsletters, receipts,
/// calendar invites, spam) with Gmail-like labels and read states.
struct DummyGenerator {
    private var rng: SeededGenerator
    private let now: Date
    private let calendar = Calendar.current
    private var counter: UInt64 = 0
    private let me = DummyContent.account

    init(seed: UInt64, now: Date) {
        self.rng = SeededGenerator(seed: seed)
        self.now = now
    }

    // MARK: - Mailbox

    mutating func makeState() -> DummyMailProvider.State {
        var messages: [String: MailMessage] = [:]
        for message in showcase() { messages[message.id] = message }

        for day in 1..<120 {
            let weekday = calendar.component(.weekday, from: date(daysAgo: day, hour: 12))
            let weekend = weekday == 1 || weekday == 7
            let count = weekend ? Int.random(in: 2...5, using: &rng) : Int.random(in: 8...13, using: &rng)
            for _ in 0..<count {
                for message in randomThread(daysAgo: day) { messages[message.id] = message }
            }
            if day % 3 == 0 {
                for message in spamThread(daysAgo: day) { messages[message.id] = message }
            }
        }

        return DummyMailProvider.State(
            account: me,
            labels: DummyContent.systemLabels + DummyContent.userLabels,
            messages: messages,
            historyID: 1_000,
            history: [],
            nextID: counter,
            nextLabelNumber: DummyContent.userLabels.count,
            scheduledReplies: [],
            incomingCounter: 0
        )
    }

    // MARK: - Helpers

    private mutating func newID() -> String {
        counter &+= 1
        var mixed = counter &* 0x9E37_79B9_7F4A_7C15
        mixed ^= mixed >> 29
        return String(format: "%016llx", (mixed & 0x0000_FFFF_FFFF_FFFF) | 0x0001_9000_0000_0000)
    }

    private func date(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: start)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private mutating func workTime(daysAgo: Int) -> Date {
        let hour = [8, 9, 9, 10, 10, 11, 11, 13, 14, 14, 15, 16, 17, 19].randomElement(using: &rng)!
        var result = date(daysAgo: daysAgo, hour: hour, minute: Int.random(in: 0...59, using: &rng))
        if result > now { result = now.addingTimeInterval(-Double.random(in: 600...7200, using: &rng)) }
        return result
    }

    private mutating func pick<T>(_ items: [T]) -> T { items.randomElement(using: &rng)! }
    private mutating func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < probability }

    private func signOff(_ address: EmailAddress) -> String { address.shortName }

    private func quoted(_ message: MailMessage) -> String {
        "\n\n\(ReplyComposer.attribution(for: message))\n\(ReplyComposer.quotedText(of: message))"
    }

    private mutating func message(
        thread: String?, from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], subject: String,
        text: String?, html: String? = nil, date: Date, labels: Set<String>, attachments: [MailAttachment] = [],
        inReplyTo: MailMessage? = nil, listUnsubscribe: String? = nil
    ) -> MailMessage {
        let id = newID()
        let plain = text ?? html.map(HTMLText.plainText(fromHTML:)) ?? ""
        var references = inReplyTo?.references ?? []
        if let header = inReplyTo?.messageIDHeader { references.append(header) }
        return MailMessage(
            id: id, threadID: thread ?? id, labelIDs: labels, from: from, to: to, cc: cc, subject: subject,
            snippet: HTMLText.snippet(from: plain), date: date, textBody: text, htmlBody: html, attachments: attachments,
            messageIDHeader: "<\(id)@vimail.dummy>", inReplyTo: inReplyTo?.messageIDHeader, references: references,
            listUnsubscribe: listUnsubscribe, sizeEstimate: (text?.utf8.count ?? 0) + (html?.utf8.count ?? 0) + attachments.reduce(0) { $0 + $1.size }
        )
    }

    private mutating func attachment(_ filename: String, _ mime: String, size: ClosedRange<Int>) -> MailAttachment {
        MailAttachment(id: "att-\(newID())", filename: filename, mimeType: mime, size: Int.random(in: size, using: &rng))
    }

    /// Inbox, unread, starred and trash state by age, Gmail style.
    private mutating func finalize(_ messages: [MailMessage], daysAgo: Int, important: Bool, noisy: Bool) -> [MailMessage] {
        var result = messages
        let inboxChance: Double = switch daysAgo {
        case 0...1: 0.85
        case 2...6: noisy ? 0.2 : 0.35
        case 7...30: important ? 0.08 : 0.03
        default: 0.01
        }
        let inInbox = chance(inboxChance)
        let unread = inInbox && chance(daysAgo <= 1 ? (noisy ? 0.7 : 0.5) : 0.25)
        let starred = important && chance(0.08)
        let trashed = noisy && daysAgo > 7 && !inInbox && chance(0.05)

        for index in result.indices {
            let fromMe = result[index].from.normalized == me.normalized
            if fromMe {
                result[index].labelIDs.insert(SystemLabel.sent)
            } else if inInbox {
                result[index].labelIDs.insert(SystemLabel.inbox)
            }
            if trashed {
                result[index].labelIDs.insert(SystemLabel.trash)
                result[index].labelIDs.remove(SystemLabel.inbox)
            }
        }
        if unread, let last = result.lastIndex(where: { $0.from.normalized != me.normalized }) {
            result[last].labelIDs.insert(SystemLabel.unread)
        }
        if starred, !result.isEmpty { result[result.count - 1].labelIDs.insert(SystemLabel.starred) }
        return result
    }

    // MARK: - Thread kinds

    private mutating func randomThread(daysAgo: Int) -> [MailMessage] {
        let roll = Double.random(in: 0..<1, using: &rng)
        switch roll {
        case ..<0.22: return finalize(conversation(daysAgo: daysAgo, people: DummyContent.colleagues, subjects: DummyContent.workSubjects, label: DummyContent.work), daysAgo: daysAgo, important: true, noisy: false)
        case ..<0.31: return finalize(conversation(daysAgo: daysAgo, people: DummyContent.clients, subjects: DummyContent.clientSubjects, label: DummyContent.work), daysAgo: daysAgo, important: true, noisy: false)
        case ..<0.38: return finalize(personalConversation(daysAgo: daysAgo), daysAgo: daysAgo, important: true, noisy: false)
        case ..<0.66: return finalize([notification(daysAgo: daysAgo)], daysAgo: daysAgo, important: false, noisy: true)
        case ..<0.72: return finalize([calendarInvite(daysAgo: daysAgo)], daysAgo: daysAgo, important: true, noisy: false)
        case ..<0.84: return finalize([newsletter(daysAgo: daysAgo)], daysAgo: daysAgo, important: false, noisy: true)
        case ..<0.90: return finalize([receipt(daysAgo: daysAgo)], daysAgo: daysAgo, important: false, noisy: true)
        case ..<0.92: return finalize([itinerary(daysAgo: daysAgo)], daysAgo: daysAgo, important: true, noisy: false)
        default: return finalize([sentOnly(daysAgo: daysAgo)], daysAgo: daysAgo, important: false, noisy: false)
        }
    }

    private mutating func workBody(to recipient: EmailAddress, from sender: EmailAddress) -> String {
        "Hi \(recipient.shortName),\n\n\(pick(DummyContent.openers)) \(pick(DummyContent.middles))\n\n\(pick(DummyContent.closers))\n\n\(signOff(sender))"
    }

    private mutating func conversation(daysAgo: Int, people: [DummyContent.Person], subjects: [String], label: String) -> [MailMessage] {
        let other = pick(people)
        let cc = chance(0.3) ? [pick(DummyContent.colleagues.filter { $0.address != other.address }).address] : []
        let subject = pick(subjects)
        let count = [1, 1, 2, 2, 2, 3, 3, 4, 5].randomElement(using: &rng)!
        var time = workTime(daysAgo: daysAgo)
        var messages: [MailMessage] = []
        var sender = chance(0.7) ? other.address : me
        let category: Set<String> = [label, SystemLabel.categoryPersonal]

        for index in 0..<count {
            let recipient = sender == me ? other.address : me
            let isFirst = index == 0
            var attachments: [MailAttachment] = []
            if isFirst && chance(0.18) {
                attachments.append(chance(0.5)
                    ? attachment("\(subject.lowercased().split(separator: " ").prefix(2).joined(separator: "-"))-v\(Int.random(in: 1...4, using: &rng)).pdf", "application/pdf", size: 80_000...2_400_000)
                    : attachment("mockup-\(Int.random(in: 1...9, using: &rng)).png", "image/png", size: 120_000...3_000_000))
            }
            var text = isFirst ? workBody(to: recipient, from: sender) : "\(pick(DummyContent.replies))\n\n\(signOff(sender))"
            if let previous = messages.last { text += quoted(previous) }
            let next = message(
                thread: messages.first?.threadID, from: sender, to: [recipient], cc: cc,
                subject: isFirst ? subject : ReplyComposer.prefixed(subject, with: "Re"), text: text,
                date: time, labels: category, attachments: attachments, inReplyTo: messages.last
            )
            messages.append(next)
            time = min(time.addingTimeInterval(Double.random(in: 600...14_400, using: &rng)), now.addingTimeInterval(-60))
            sender = sender == me ? other.address : me
        }
        return messages
    }

    private mutating func personalConversation(daysAgo: Int) -> [MailMessage] {
        let friend = pick(DummyContent.friends)
        let subject = pick(DummyContent.personalSubjects)
        var time = date(daysAgo: daysAgo, hour: Int.random(in: 7...22, using: &rng), minute: Int.random(in: 0...59, using: &rng))
        if time > now { time = now.addingTimeInterval(-3600) }
        let labels: Set<String> = [DummyContent.personal, SystemLabel.categoryPersonal]
        let first = message(
            thread: nil, from: friend.address, to: [me], subject: subject,
            text: "Hey \(me.shortName),\n\n\(pick(DummyContent.personalBodies))\n\n\(friend.address.shortName)",
            date: time, labels: labels,
            attachments: subject.contains("Photos") ? [attachment("IMG_\(Int.random(in: 1000...9999, using: &rng)).png", "image/png", size: 900_000...4_000_000)] : []
        )
        guard chance(0.5) else { return [first] }
        let reply = message(
            thread: first.threadID, from: me, to: [friend.address], subject: ReplyComposer.prefixed(subject, with: "Re"),
            text: "\(pick(DummyContent.personalReplies))\n\n\(me.shortName)\(quoted(first))",
            date: min(time.addingTimeInterval(Double.random(in: 900...20_000, using: &rng)), now.addingTimeInterval(-60)),
            labels: labels, inReplyTo: first
        )
        return [first, reply]
    }

    private mutating func notification(daysAgo: Int) -> MailMessage {
        let time = workTime(daysAgo: daysAgo)
        let person = pick(DummyContent.colleagues).address
        switch Int.random(in: 0...5, using: &rng) {
        case 0:
            let issue = "STU-\(Int.random(in: 100...999, using: &rng))"
            let title = pick(DummyContent.issueTitles)
            let action = pick(["moved this to In Progress", "commented: “Looks good, merging after review.”", "assigned this issue to you", "marked this as Done"])
            return message(thread: nil, from: DummyContent.linear.address, to: [me], subject: "[\(issue)] \(title)", text: nil,
                           html: DummyContent.notificationHTML(brand: "Linear", accent: "#5e6ad2", title: "\(issue) \(title)", body: "\(person.displayName) \(action)", button: "View issue", footer: "Linear · Studio North workspace"),
                           date: time, labels: DummyContent.linear.labels)
        case 1:
            let repo = pick(DummyContent.repoNames)
            let number = Int.random(in: 40...480, using: &rng)
            let title = pick(DummyContent.issueTitles)
            let verb = pick(["requested your review on", "approved", "commented on", "merged"])
            return message(thread: nil, from: DummyContent.github.address, to: [me], subject: "[\(repo)] \(title) (#\(number))", text: nil,
                           html: DummyContent.notificationHTML(brand: "GitHub", accent: "#1f883d", title: "\(person.shortName) \(verb) #\(number)", body: "\(title)<br><span style=\"color:#8a8f98;\">\(repo)</span>", button: "View pull request", footer: "You are receiving this because you were mentioned."),
                           date: time, labels: DummyContent.github.labels)
        case 2:
            let ok = chance(0.85)
            let project = pick(["studio-site", "design-system-docs", "lumen-web"])
            return message(thread: nil, from: DummyContent.vercel.address, to: [me], subject: ok ? "Deployment successful: \(project)" : "Failed deployment: \(project)", text: nil,
                           html: DummyContent.notificationHTML(brand: "▲ Vercel", accent: ok ? "#000000" : "#e5484d", title: ok ? "Your deployment is live" : "Your deployment failed", body: ok ? "The latest changes to <b>\(project)</b> are now live in production." : "The build for <b>\(project)</b> failed. Check the logs for details.", button: ok ? "Visit deployment" : "View logs", footer: "Vercel Inc."),
                           date: time, labels: DummyContent.vercel.labels)
        case 3:
            let file = pick(DummyContent.figmaFiles)
            return message(thread: nil, from: DummyContent.figma.address, to: [me], subject: "\(person.displayName) commented on \(file)", text: nil,
                           html: DummyContent.notificationHTML(brand: "Figma", accent: "#a259ff", title: "New comment in \(file)", body: "“\(pick(DummyContent.replies))” — \(person.displayName)", button: "Open in Figma", footer: "Figma · Notification settings"),
                           date: time, labels: DummyContent.figma.labels)
        case 4:
            let page = pick(DummyContent.notionPages)
            return message(thread: nil, from: DummyContent.notion.address, to: [me], subject: "\(person.displayName) mentioned you in \(page)", text: nil,
                           html: DummyContent.notificationHTML(brand: "Notion", accent: "#2f2f2f", title: "You were mentioned in \(page)", body: "@\(me.shortName) \(pick(DummyContent.middles))", button: "Open page", footer: "Notion Labs"),
                           date: time, labels: DummyContent.notion.labels)
        default:
            let channel = pick(DummyContent.slackChannels)
            return message(thread: nil, from: DummyContent.slack.address, to: [me], subject: "New messages from \(person.displayName) in #\(channel)", text: nil,
                           html: DummyContent.notificationHTML(brand: "Slack", accent: "#4a154b", title: "\(person.displayName) in #\(channel)", body: pick(DummyContent.replies), button: "Reply in Slack", footer: "Studio North Slack workspace"),
                           date: time, labels: DummyContent.slack.labels)
        }
    }

    private mutating func calendarInvite(daysAgo: Int) -> MailMessage {
        let organizer = pick(DummyContent.colleagues + DummyContent.clients).address
        let meeting = pick(DummyContent.meetings)
        let sent = workTime(daysAgo: daysAgo)
        let start = sent.addingTimeInterval(Double(Int.random(in: 1...6, using: &rng)) * 86_400)
        let when = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        let html = DummyContent.notificationHTML(
            brand: "Google Calendar", accent: "#1a73e8", title: "Invitation: \(meeting)",
            body: "<b>When</b>: \(when)<br><b>Organizer</b>: \(organizer.displayName)<br><b>Join</b>: meet.example.com/\(Int.random(in: 100...999, using: &rng))-studio",
            button: "Yes, I'll attend", footer: "Invitation from Google Calendar"
        )
        return message(
            thread: nil, from: EmailAddress(name: "\(organizer.displayName) (Google Calendar)", email: DummyContent.calendar.address.email),
            to: [me], subject: "Invitation: \(meeting) @ \(when)", text: "\(organizer.displayName) has invited you to \(meeting).\nWhen: \(when)",
            html: html, date: sent, labels: DummyContent.calendar.labels,
            attachments: [attachment("invite.ics", "application/ics", size: 2_000...7_000)]
        )
    }

    private mutating func newsletter(daysAgo: Int) -> MailMessage {
        let service = pick([DummyContent.theBrowser, DummyContent.arena, DummyContent.margins])
        let topics = [
            ("The quiet power of slow software", "Why the best tools disappear when you use them."),
            ("A field guide to good defaults", "Most people never change a setting. Design for them."),
            ("What gardeners know about product strategy", "Pruning is a feature, not a failure."),
            ("The case for fewer meetings", "A team that writes things down thinks more clearly."),
            ("Notes on typography for screens", "Line length, rhythm, and the comfort of white space."),
            ("Small tools, sharp edges", "On building things that do one thing well."),
        ]
        var items: [(String, String)] = []
        for _ in 0..<Int.random(in: 3...5, using: &rng) { items.append(pick(topics)) }
        let issue = "Issue \(Int.random(in: 120...480, using: &rng)) · \(date(daysAgo: daysAgo, hour: 7).formatted(date: .long, time: .omitted))"
        let subject = service.address.name == "The Browser" ? "Five things worth your time" : service.address.name == "Are.na" ? "New connections in your channels" : "Margins Weekly: \(items[0].0)"
        return message(
            thread: nil, from: service.address, to: [me], subject: subject, text: nil,
            html: DummyContent.newsletterHTML(name: service.address.name ?? "", issue: issue, intro: "A few good reads for a slower morning.", items: items),
            date: date(daysAgo: daysAgo, hour: 7, minute: Int.random(in: 0...50, using: &rng)), labels: service.labels,
            listUnsubscribe: "<https://example.com/unsubscribe>"
        )
    }

    private mutating func receipt(daysAgo: Int) -> MailMessage {
        let (vendor, plan) = pick(DummyContent.vendors)
        let amount = String(format: "$%.2f", Double(Int.random(in: 8...79, using: &rng)) + 0.99)
        let number = "\(Int.random(in: 1000...9999, using: &rng))-\(Int.random(in: 1000...9999, using: &rng))"
        let time = workTime(daysAgo: daysAgo)
        return message(
            thread: nil, from: EmailAddress(name: "\(vendor) via Stripe", email: DummyContent.stripe.address.email), to: [me],
            subject: "Your receipt from \(vendor) #\(number)", text: nil,
            html: DummyContent.receiptHTML(vendor: vendor, plan: plan, amount: amount, number: number, date: time.formatted(date: .abbreviated, time: .omitted)),
            date: time, labels: DummyContent.stripe.labels,
            attachments: chance(0.5) ? [attachment("receipt-\(number).pdf", "application/pdf", size: 30_000...90_000)] : []
        )
    }

    private mutating func itinerary(daysAgo: Int) -> MailMessage {
        let city = pick(DummyContent.cities)
        let code = String((0..<6).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement(using: &rng)! })
        return message(
            thread: nil, from: DummyContent.airline.address, to: [me], subject: "Your trip to \(city) — confirmation \(code)", text: nil,
            html: DummyContent.notificationHTML(brand: "Northwind Air", accent: "#0b6e4f", title: "You're going to \(city)", body: "Confirmation code <b>\(code)</b>. Your itinerary and receipt are attached. Check-in opens 24 hours before departure.", button: "Manage booking", footer: "Northwind Air · Have a great trip"),
            date: workTime(daysAgo: daysAgo), labels: DummyContent.airline.labels,
            attachments: [attachment("itinerary-\(code).pdf", "application/pdf", size: 60_000...200_000)]
        )
    }

    private mutating func sentOnly(daysAgo: Int) -> MailMessage {
        let to = pick(DummyContent.clients + DummyContent.colleagues).address
        return message(
            thread: nil, from: me, to: [to], subject: pick(DummyContent.clientSubjects + DummyContent.workSubjects),
            text: workBody(to: to, from: me), date: workTime(daysAgo: daysAgo), labels: [DummyContent.work]
        )
    }

    private mutating func spamThread(daysAgo: Int) -> [MailMessage] {
        let (from, subject, body) = pick(DummyContent.spam)
        return [message(thread: nil, from: from, to: [me], subject: subject, text: nil,
                        html: DummyContent.notificationHTML(brand: "Special offer", accent: "#d62d20", title: subject, body: body, button: "Claim now", footer: "Unsubscribe"),
                        date: workTime(daysAgo: daysAgo), labels: [SystemLabel.spam])]
    }

    // MARK: - The design's sample inbox

    private mutating func showcase() -> [MailMessage] {
        let anchor = now.addingTimeInterval(-12 * 60)
        func minutesBefore(_ minutes: Double) -> Date { anchor.addingTimeInterval(-minutes * 60) }
        let startOfYesterday = date(daysAgo: 1, hour: 0)
        func yesterday(_ hour: Int, _ minute: Int) -> Date { startOfYesterday.addingTimeInterval(Double(hour * 3600 + minute * 60)) }
        let alex = DummyContent.person("Alex Morgan").address
        let nina = DummyContent.person("Nina Park").address
        let jamie = DummyContent.person("Jamie Chen").address
        let oliver = DummyContent.person("Oliver Lewis").address
        var result: [MailMessage] = []

        result.append(message(
            thread: nil, from: alex, to: [me], subject: "A little direction for the next chapter",
            text: """
            Hey Sam,

            I've been thinking about where we take the studio next, and I keep coming back to one thing: making more room for the work that matters.

            Fewer projects, deeper focus. Less noise, more intention. I think there's something really good on the other side of that.

            I put a few thoughts together in the attached doc. Nothing set in stone — more of a starting point for a conversation.

            Would love your take when you have a quiet moment. No rush.

            Talk soon,
            Alex

            --
            Alex Morgan
            Co-founder, Studio North
            studionorth.co
            """,
            html: """
            <p>Hey Sam,</p>
            <p>I’ve been thinking about where we take the studio next, and I keep coming back to one thing: <strong>making more room for the work that matters.</strong></p>
            <p>Fewer projects, deeper focus. Less noise, more intention. I think there’s something really good on the other side of that.</p>
            <p>I put a few thoughts together in the attached doc. Nothing set in stone — more of a starting point for a conversation.</p>
            <p>Would love your take when you have a quiet moment. No rush.</p>
            <p>Talk soon,<br><strong>Alex</strong></p>
            <div class="signature">Alex Morgan<br>Co-founder, Studio North<br><a href="https://studionorth.co">studionorth.co</a></div>
            """,
            date: anchor, labels: [SystemLabel.inbox, SystemLabel.unread, SystemLabel.starred, DummyContent.work, SystemLabel.categoryPersonal],
            attachments: [MailAttachment(id: "att-studio-next-chapter", filename: "studio-next-chapter.txt", mimeType: "text/plain", size: 163)]
        ))

        result.append(message(
            thread: nil, from: DummyContent.linear.address, to: [me], subject: "Your workspace, this week", text: nil,
            html: DummyContent.notificationHTML(brand: "Linear", accent: "#5e6ad2", title: "Your workspace, this week", body: "12 issues completed. One good week of progress.<br><br>Most active: <b>Studio site</b> · 7 issues closed<br>Cycle 14 ends Friday.", button: "Open Linear", footer: "Linear · Weekly digest"),
            date: minutesBefore(24), labels: [SystemLabel.inbox, SystemLabel.unread, DummyContent.updates, SystemLabel.categoryUpdates]
        ))

        result.append(message(
            thread: nil, from: nina, to: [me], subject: "Coffee on Thursday?",
            text: "Hey Sam,\n\nThere’s a new spot on the corner of Valencia… Would Thursday morning work for you? It would be lovely to catch up over a coffee.\n\nThanks,\nNina Park",
            date: minutesBefore(46), labels: [SystemLabel.inbox, SystemLabel.unread, DummyContent.personal, SystemLabel.categoryPersonal]
        ))

        result.append(message(
            thread: nil, from: DummyContent.vercel.address, to: [me], subject: "Deployment successful: studio-site", text: nil,
            html: DummyContent.notificationHTML(brand: "▲ Vercel", accent: "#000000", title: "Your deployment is live", body: "Your latest changes are now live in production.<br><b>studio-site</b> · main · 4f2c9e1", button: "Visit deployment", footer: "Vercel Inc."),
            date: minutesBefore(71), labels: [SystemLabel.inbox, DummyContent.updates, SystemLabel.categoryUpdates]
        ))

        let lessFirst = message(
            thread: nil, from: me, to: [jamie], subject: "Less, but better",
            text: "Hi Jamie,\n\nI keep coming back to Dieter Rams for the new site: less, but better. What if we cut the homepage down to three sections and let the work carry it?\n\nSam",
            date: minutesBefore(150), labels: [SystemLabel.sent, DummyContent.work]
        )
        let lessReply = message(
            thread: lessFirst.threadID, from: jamie, to: [me], subject: "Re: Less, but better",
            text: "Exactly. Let’s keep the scope tight and give ourselves room to polish the details. I’ll mock up the three-section version tomorrow morning.\n\nJamie\(quoted(lessFirst))",
            date: minutesBefore(90), labels: [SystemLabel.inbox, SystemLabel.starred, DummyContent.work, SystemLabel.categoryPersonal], inReplyTo: lessFirst
        )
        result += [lessFirst, lessReply]

        result.append(message(
            thread: nil, from: DummyContent.theBrowser.address, to: [me], subject: "Five things worth your time", text: nil,
            html: DummyContent.newsletterHTML(name: "The Browser", issue: "Issue 412 · \(now.formatted(date: .long, time: .omitted))", intro: "A few good reads for a slower morning.", items: [
                ("The quiet power of slow software", "Why the best tools disappear when you use them."),
                ("A field guide to good defaults", "Most people never change a setting. Design for them."),
                ("What gardeners know about product strategy", "Pruning is a feature, not a failure."),
                ("Notes on typography for screens", "Line length, rhythm, and the comfort of white space."),
                ("Small tools, sharp edges", "On building things that do one thing well."),
            ]),
            date: minutesBefore(122), labels: [SystemLabel.inbox, DummyContent.reading, SystemLabel.categoryPromotions],
            listUnsubscribe: "<https://example.com/unsubscribe>"
        ))

        result.append(message(
            thread: nil, from: DummyContent.figma.address, to: [me], subject: "A few updates to your workflow", text: nil,
            html: DummyContent.notificationHTML(brand: "Figma", accent: "#a259ff", title: "A few updates to your workflow", body: "Small improvements. A smoother canvas.<br><br>Faster multiplayer cursors, better auto layout wrapping, and a new way to compare versions.", button: "See what's new", footer: "Figma · Product updates"),
            date: yesterday(17, 20), labels: [SystemLabel.inbox, DummyContent.updates, SystemLabel.categoryUpdates]
        ))

        result.append(message(
            thread: nil, from: oliver, to: [me], subject: "The files you asked for",
            text: "Hey! Attaching the final assets here. Let me know if you need anything else, or other formats for the banner.\n\nCheers,\nOliver",
            date: yesterday(15, 5), labels: [SystemLabel.inbox, DummyContent.work, SystemLabel.categoryPersonal],
            attachments: [
                MailAttachment(id: "att-final-assets", filename: "final-assets.pdf", mimeType: "application/pdf", size: 1_843_200),
                MailAttachment(id: "att-hero-banner", filename: "hero-banner.png", mimeType: "image/png", size: 2_516_582),
            ]
        ))

        result.append(message(
            thread: nil, from: DummyContent.arena.address, to: [me], subject: "New connections in your channels", text: nil,
            html: DummyContent.newsletterHTML(name: "Are.na", issue: "Your weekly digest", intro: "A collection of ideas, slowly coming together.", items: [
                ("“Studio references” gained 14 blocks", "Including three from people you follow."),
                ("“Type in use” was connected to 2 channels", "Your channel is being referenced elsewhere."),
            ]),
            date: yesterday(11, 30), labels: [SystemLabel.inbox, DummyContent.reading, SystemLabel.categoryUpdates],
            listUnsubscribe: "<https://example.com/unsubscribe>"
        ))

        return result
    }

    // MARK: - Live simulation

    /// New mail for the "incoming mail" simulation: a reply in a recent thread, or a notification, a new
    /// conversation, personal mail, a receipt, a newsletter or a calendar invite, so rules see every kind.
    mutating func incomingMessages(account: EmailAddress, existing: [MailMessage], labels: [MailLabel], newID: () -> String) -> [MailMessage] {
        let fresh: MailMessage
        let peopleAddresses = Set(DummyContent.people.map(\.address.normalized))
        let recent = existing.filter { message in
            message.date > now.addingTimeInterval(-14 * 86_400) && message.from.normalized != account.normalized
                && peopleAddresses.contains(message.from.normalized)
        }
        if chance(0.35), let previous = recent.randomElement(using: &rng) {
            fresh = reply(to: previous, from: previous.from, account: account, id: newID())
        } else {
            var generated: MailMessage
            switch Int.random(in: 0...6, using: &rng) {
            case 0, 1: generated = notification(daysAgo: 0)
            case 2:
                // A new conversation that someone else started.
                let starters = conversation(daysAgo: 0, people: DummyContent.colleagues + DummyContent.clients, subjects: DummyContent.workSubjects + DummyContent.clientSubjects, label: DummyContent.work)
                generated = starters.first { $0.from.normalized != account.normalized } ?? notification(daysAgo: 0)
                if generated.inReplyTo != nil { generated = notification(daysAgo: 0) }
            case 3: generated = personalConversation(daysAgo: 0)[0]
            case 4: generated = receipt(daysAgo: 0)
            case 5: generated = newsletter(daysAgo: 0)
            default: generated = calendarInvite(daysAgo: 0)
            }
            let id = newID()
            generated.id = id
            generated.threadID = id
            generated.date = now
            generated.messageIDHeader = "<\(id)@vimail.dummy>"
            generated.attachments = generated.attachments.map { MailAttachment(id: "att-\(id)-\($0.filename)", filename: $0.filename, mimeType: $0.mimeType, size: $0.size) }
            fresh = generated
        }
        var message = fresh
        message.labelIDs.formUnion([SystemLabel.inbox, SystemLabel.unread])
        message.labelIDs.remove(SystemLabel.sent)
        return [message]
    }

    /// A reply from a contact in an existing thread.
    mutating func reply(to original: MailMessage, from sender: EmailAddress, account: EmailAddress, id: String) -> MailMessage {
        let isPersonal = DummyContent.friends.contains { $0.address.normalized == sender.normalized }
        let text = "\(pick(isPersonal ? DummyContent.personalReplies : DummyContent.replies))\n\n\(sender.shortName)\(quoted(original))"
        var references = original.references
        if let header = original.messageIDHeader { references.append(header) }
        return MailMessage(
            id: id, threadID: original.threadID,
            labelIDs: [SystemLabel.inbox, SystemLabel.unread, isPersonal ? DummyContent.personal : DummyContent.work, SystemLabel.categoryPersonal],
            from: sender, to: [account], subject: ReplyComposer.prefixed(original.subject, with: "Re"),
            snippet: HTMLText.snippet(from: text), date: now, textBody: text,
            messageIDHeader: "<\(id)@vimail.dummy>", inReplyTo: original.messageIDHeader, references: references,
            sizeEstimate: text.utf8.count
        )
    }
}
