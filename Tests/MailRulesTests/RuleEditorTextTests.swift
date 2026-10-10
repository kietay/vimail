import Foundation
import Testing
@testable import MailCore
@testable import MailRules
@testable import MailStore

@Suite("Making rules: what T suggests")
struct RuleSuggestionTests {
    @Test func consumerDomains() {
        for domain in ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "icloud.com", "me.com", "yahoo.com", "proton.me", "protonmail.com", "hey.com", "fastmail.com", "GMAIL.com"] {
            #expect(RuleSuggestion.isConsumerDomain(domain))
        }
        #expect(!RuleSuggestion.isConsumerDomain("studio.co"))
        #expect(!RuleSuggestion.isConsumerDomain("mail.google.com"))
        #expect(RuleSuggestion.domain(of: "Receipts@Stripe.COM") == "stripe.com")
        #expect(RuleSuggestion.domain(of: "nobody") == "")
    }

    @Test func automatedSenders() {
        #expect(RuleSuggestion.isAutomated(EmailAddress(name: "Ana", email: "ana@studio.co"), isList: true))
        for address in ["no-reply@apple.com", "noreply@github.com", "no_reply@apple.com", "NoReply+bounce@x.com", "donotreply@bank.example",
                        "do-not-reply@shop.example", "notifications@github.com", "receipts@stripe.com", "alerts@bank.example"] {
            #expect(RuleSuggestion.isAutomated(EmailAddress(name: nil, email: address), isList: false), "\(address)")
        }
        for address in ["ana@studio.co", "sam@hey.com", "replies@forum.example", "noreen@studio.co"] {
            #expect(!RuleSuggestion.isAutomated(EmailAddress(name: nil, email: address), isList: false), "\(address)")
        }
    }

    @Test func whenKeepsColleaguesOutOrLimitsToTheSender() throws {
        // Your own domain: mail from colleagues stays out.
        #expect(RuleSuggestion.when(account: "sam@studio.co", sender: stripe, onlySender: false) == "-from:@studio.co")
        // A consumer address says nothing about colleagues.
        #expect(RuleSuggestion.when(account: "sam@hey.com", sender: stripe, onlySender: false) == "")
        #expect(RuleSuggestion.when(account: "sam@Gmail.com", sender: ana, onlySender: false) == "")
        // Mail from your own domain, or a system under it: keeping that domain out would keep this email out.
        #expect(RuleSuggestion.when(account: "sam@studio.co", sender: ana, onlySender: false) == "")
        #expect(RuleSuggestion.when(account: "sam@studio.co", sender: EmailAddress(name: nil, email: "billing@pay.studio.co"), onlySender: false) == "")
        #expect(RuleSuggestion.when(account: "sam@studio.co", sender: EmailAddress(name: nil, email: "jo@notstudio.co"), onlySender: false) == "-from:@studio.co")
        #expect(RuleSuggestion.when(account: "sam@studio.co", sender: EmailAddress(name: nil, email: "billing@pay.studio.co"), onlySender: true) == "from:@pay.studio.co")
        // Limited to an automated sender's domain.
        #expect(RuleSuggestion.when(account: "sam@studio.co", sender: stripe, onlySender: true) == "from:@stripe.com")
        #expect(RuleSuggestion.when(account: "sam@hey.com", sender: apple, onlySender: true) == "from:@apple.com")
        // Every suggestion is a WHEN rules accept.
        for when in ["-from:@studio.co", "from:@stripe.com"] {
            #expect(try RuleFilter.parse(when).query.from.count + RuleFilter.parse(when).query.excludedFrom.count == 1)
        }
    }

    @Test func newLabelNames() {
        #expect(RuleSuggestion.labelName(for: stripe) == "Stripe")
        #expect(RuleSuggestion.labelName(for: EmailAddress(name: nil, email: "receipts@mail.stripe.com")) == "Stripe")
        #expect(RuleSuggestion.labelName(for: EmailAddress(name: nil, email: "news@bbc.co.uk")) == "Bbc")
        // A person writing from a consumer address: their name.
        #expect(RuleSuggestion.labelName(for: EmailAddress(name: "Nina Park", email: "nina@gmail.com")) == "Nina Park")
        #expect(RuleSuggestion.labelName(for: EmailAddress(name: nil, email: "nina@gmail.com")) == "")
        #expect(RuleSuggestion.labelName(for: EmailAddress(name: nil, email: "localhost")) == "")
    }
}

@Suite("Rule editor text")
struct RuleEditorTextTests {
    func row(
        _ id: String, _ outcome: PreviewRow.Outcome, source: DecisionSource? = nil, section: PreviewRow.Section = .recent, reason: String? = nil,
        disagrees: Bool = false, older: Bool = false, mine: Bool = false, testing: Bool = false
    ) -> PreviewRow {
        var row = PreviewRow(messageID: id, threadID: id, sender: stripe, subject: "Your receipt", date: Date(), section: section)
        row.outcome = outcome
        row.source = source
        row.reason = reason
        row.disagrees = disagrees
        row.judgedBeforeNewestMarks = older
        row.markedByYou = mine
        row.testing = testing
        return row
    }

    @Test func glyphsFollowTheLegend() {
        #expect(row("a", .match, source: .claude).glyph == "✔")
        #expect(row("b", .noMatch, source: .cache).glyph == "✖")
        #expect(row("c", .filteredOut, source: .gate).glyph == "✖")
        #expect(row("d", .unsure, source: .claude).glyph == "~")
        #expect(row("e", .noMatch, source: .cache, disagrees: true).glyph == "≠")
        #expect(row("f", .match, source: .cache, older: true).glyph == "◐")
        #expect(row("g", .declined, source: .claude).glyph == "!")
        #expect(row("h", .notJudged).glyph == "◌")
        // On its way to Claude.
        #expect(row("i", .match, source: .cache, testing: true).glyph == "◌")
    }

    @Test func detailsSayWhatDecided() {
        #expect(row("a", .match, source: .claude, reason: "payment receipt for Figma").detail == "payment receipt for Figma")
        #expect(row("b", .noMatch, source: .cache, reason: "store promotion", disagrees: true).detail == "you labeled this; Claude: no match · store promotion")
        #expect(row("c", .filteredOut, source: .gate, disagrees: true).detail == "it has the label, but WHEN does not pass")
        #expect(row("d", .match, source: .cache, reason: "linear ticket", older: true).detail == "judged before your newest mark · linear ticket")
        #expect(row("e", .declined, source: .claude).detail == "Claude declined to classify this email (often phishing)")
        #expect(row("f", .unsure, source: .claude).detail == "Claude: unsure")
        #expect(row("g", .match, source: .example, mine: true).detail == "your ✔")
        #expect(row("h", .noMatch, source: .example, mine: true).detail == "your ✖")
        #expect(row("i", .noMatch, source: .mark, mine: true).detail == "you removed the label")
        #expect(row("j", .match, source: .override).detail == "your sender rule: always")
        #expect(row("k", .match, source: .thread).detail == "matched earlier in the conversation")
        #expect(row("l", .match, source: .gate).detail == "passes WHEN")
        #expect(row("m", .filteredOut, source: .gate).detail == "WHEN does not pass here")
        #expect(row("n", .notJudged).detail == "not judged yet · ⌃r tests it")
        #expect(row("o", .match, source: .cache, testing: true).detail == "testing…")
    }

    @Test func headerCountsEachRowOnceUnderItsGlyph() {
        let rows = [row("a", .match, source: .claude), row("b", .match, source: .example, mine: true), row("c", .noMatch, source: .claude),
                    row("d", .unsure, source: .claude), row("e", .noMatch, source: .cache, disagrees: true), row("f", .notJudged),
                    row("g", .notJudged), row("h", .declined, source: .claude), row("i", .match, source: .cache, older: true)]
        #expect(RuleEditorText.header(rows, decidedBy: "Haiku 5.5") == "PREVIEW 9 · 2✔ 1✖ 1~ 1≠ 1◐ 1! 2◌ · Haiku 5.5")
        #expect(RuleEditorText.header([], decidedBy: "filter · free") == "PREVIEW 0 · filter · free")
    }

    @Test func breadthWarnsWhenMostMailWouldBeLabeled() throws {
        // A filter rule labels all that passes: 1,940 of 2,310.
        let filter = try #require(RuleEditorText.breadth(passing: 1_940, inScope: 2_310, rows: [], asksClaude: false))
        #expect(filter > RuleEditorText.broadShare)
        #expect(RuleEditorText.breadth(passing: 10, inScope: 0, rows: [], asksClaude: false) == nil)
        // A Claude rule: of the newest passing mail decided, how much matches. Marked and unsure-review
        // rows are not a fair sample; rows not judged yet don't count.
        let rows = [row("a", .match, source: .claude), row("b", .noMatch, source: .claude), row("c", .noMatch, source: .cache),
                    row("d", .unsure, source: .claude), row("e", .notJudged), row("f", .match, source: .example, section: .marked)]
        #expect(RuleEditorText.breadth(passing: 100, inScope: 100, rows: rows, asksClaude: true) == 0.25)
        #expect(RuleEditorText.breadth(passing: 100, inScope: 100, rows: [row("e", .notJudged)], asksClaude: true) == nil)
        let verdicts: [PreviewRow.Outcome] = [.match, .noMatch, .unsure, .declined]
        let undecided: [PreviewRow.Outcome] = [.notJudged, .filteredOut]
        #expect(verdicts.filter { $0.isVerdict } == verdicts)
        #expect(undecided.filter { $0.isVerdict }.isEmpty)
        let broad = [row("a", .match, source: .claude), row("b", .match, source: .claude), row("c", .noMatch, source: .claude)]
        #expect(try #require(RuleEditorText.breadth(passing: 90, inScope: 100, rows: broad, asksClaude: true)) > RuleEditorText.broadShare)
    }

    @Test func teachLineTellsTestedMarksFromNewOnes() {
        func example(_ id: String, _ matches: Bool) -> RuleExample {
            RuleExample(ruleID: "r_1", messageID: id, matches: matches, origin: .preview, digest: "", undoKey: nil, createdAt: Date())
        }
        let examples = [example("m1", true), example("m2", true), example("m3", false), example("m4", true)]
        #expect(RuleEditorText.teach(examples, tested: ["m1", "m2", "m3"]) == "✔2 ✖1 tested · 1 untested mark")
        #expect(RuleEditorText.teach(examples, tested: []) == "4 untested marks")
        #expect(RuleEditorText.untested(examples, tested: ["m1", "m9"]) == 3)
        #expect(RuleEditorText.teach([], tested: ["m1"]) == "no marks yet · y ✔ and n ✖ in the preview")
        // A filter rule sends nothing: its marks need no test.
        #expect(RuleEditorText.teach(examples, tested: [], asksClaude: false) == "✔3 ✖1 marked")
    }

    @Test func figuresLines() {
        #expect(RuleEditorText.freeCount(passing: 1_940, inScope: 2_310, days: 90) == "1,940 of 2,310 (90 d) pass · free")
        #expect(RuleEditorText.testPrices(atIssue: PreviewCost(calls: 12, micros: 150_000), all: PreviewCost(calls: 27, micros: 340_000))
            == "⌃r test 12 ≈ $0.15 · ⌃R all 27 ≈ $0.34")
        #expect(RuleEditorText.testPrices(atIssue: PreviewCost(calls: 0, micros: 0), all: PreviewCost(calls: 3, micros: 400)) == "⌃R all 3 < $0.01")
        #expect(RuleEditorText.testPrices(atIssue: PreviewCost(calls: 0, micros: 0), all: PreviewCost(calls: 0, micros: 0))
            == "nothing to test: your marks and Claude decide every row")
        #expect(RuleEditorText.previewSpend(today: 220_000, allowance: 1_000_000) == "preview today $0.22 of $1.00")
        #expect(RuleEditorText.stopped(.budget(.previewRoom)).hasPrefix("Today's preview allowance is spent."))
        #expect(RuleEditorText.stopped(.paused(.noKey)) == "Claude can't test now: add an API key in Settings. WHEN previews keep working.")
    }

    @Test func dayRanges() throws {
        let calendar = Calendar.current
        let october9 = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 10)))
        let october14 = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 18)))
        let september28 = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 8)))
        #expect(RuleText.day(october9) == "9 Oct")
        #expect(RuleText.days(DateInterval(start: october9, end: october14)) == "9–14 Oct")
        #expect(RuleText.days(DateInterval(start: september28, end: october9)) == "28 Sep–9 Oct")
        #expect(RuleText.days(DateInterval(start: october9, end: october9.addingTimeInterval(3_600))) == "9 Oct")
        #expect(RuleText.count(2_310) == "2,310")
    }
}

@Suite("How far back: the sheet's lines")
struct BackfillTextTests {
    func estimate(
        inScope: Int = 402, passing: Int = 338, needClaude: Int = 309, micros: Int64 = 3_910_000, cap: Int64 = 5_865_000,
        cached: Int = 0, yours: Int = 0, span: ClosedRange<Date>? = nil, messages: Int? = nil, counts: Bool = true
    ) -> RunEstimate {
        let figures = RuleEstimate(
            window: nil, inScope: inScope, passing: passing, decidedFree: passing - needClaude, decidedByYou: yours, cachedVerdicts: cached,
            decidedEarlier: 0, needClaude: needClaude, claudeSpan: span
        )
        return RunEstimate(
            plan: nil, counts: counts ? figures : nil, window: nil, messages: messages ?? passing, needClaude: needClaude, perCallMicros: 12_650,
            fromHistory: false, micros: micros, capMicros: cap, fitsToday: true
        )
    }

    @Test func choicesAndTheirWindows() {
        #expect(BackfillChoice.backfill(asksClaude: true) == [.newMailOnly, .newest(100), .lastDays(14), .lastDays(30), .lastDays(90), .allCached])
        // Filter rules need no Claude, so there is no "newest for Claude".
        #expect(BackfillChoice.backfill(asksClaude: false) == [.newMailOnly, .lastDays(14), .lastDays(30), .lastDays(90), .allCached])
        #expect(BackfillChoice.recheck == [.newMailOnly, .labeled, .lastDays(14)])
        #expect(BackfillChoice.newMailOnly.window == nil)
        for choice in [BackfillChoice.newest(100), .lastDays(14), .allCached, .labeled] {
            #expect(choice.window.flatMap(BackfillChoice.init) == choice)
        }
        #expect(BackfillChoice(.dates(DateInterval(start: Date(), duration: 60))) == nil)
    }

    @Test func titles() throws {
        let now = Date()
        let newest = estimate(span: now.addingTimeInterval(-5 * 86_400)...now)
        #expect(BackfillText.title(.newest(100), estimate: newest, oldest: nil, now: now) == "Newest 100 for Claude (≈ 5 days)")
        #expect(BackfillText.title(.newest(100), estimate: nil, oldest: nil, now: now) == "Newest 100 for Claude")
        #expect(BackfillText.title(.newMailOnly, estimate: nil, oldest: nil) == "New mail only")
        #expect(BackfillText.title(.lastDays(14), estimate: newest, oldest: nil) == "Last 14 days")
        let june2 = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 9)))
        #expect(BackfillText.title(.allCached, estimate: nil, oldest: june2) == "All cached (since 2 Jun)")
        #expect(BackfillText.title(.labeled, estimate: estimate(messages: 212, counts: false), oldest: nil) == "The 212 it labeled")
        #expect(BackfillText.title(.labeled, estimate: estimate(messages: 1, counts: false), oldest: nil) == "The 1 message it labeled")
    }

    @Test func countsAndCost() {
        let room = RunRoom(today: 1_880_000, month: 13_180_000, reserve: 1_700_000)
        #expect(BackfillText.counts(estimate(), asksClaude: true) == "402 msgs · 64 filtered · 309 Claude")
        #expect(BackfillText.counts(estimate(), asksClaude: false) == "338 of 402 msgs")
        #expect(BackfillText.counts(estimate(messages: 212, counts: false), asksClaude: true) == "212 msgs · 309 Claude")
        #expect(BackfillText.cost(estimate(), asksClaude: true, room: room) == "≈ $3.91 · over today's room")
        #expect(BackfillText.cost(estimate(needClaude: 1_911, micros: 24_170_000), asksClaude: true, room: room) == "≈ $24.17 · over month room")
        #expect(BackfillText.cost(estimate(needClaude: 100, micros: 1_270_000), asksClaude: true, room: room) == "≈ $1.27 · ≈ 2 min")
        #expect(BackfillText.cost(estimate(needClaude: 100, micros: 1_270_000), asksClaude: true, room: nil) == "≈ $1.27 · ≈ 2 min")
        #expect(BackfillText.cost(estimate(), asksClaude: false, room: room) == "free")
        #expect(BackfillText.cost(estimate(needClaude: 0, micros: 0), asksClaude: true, room: room) == "free")
    }

    @Test func durationsAtAboutOneMessageASecond() {
        #expect(BackfillText.duration(calls: 0) == nil)
        #expect(BackfillText.duration(calls: 30) == "< 1 min")
        #expect(BackfillText.duration(calls: 360) == "≈ 6 min")
        #expect(BackfillText.duration(calls: 361) == "≈ 7 min")
        #expect(BackfillText.duration(calls: 7_200) == "≈ 2 h")
    }

    @Test func notesUnderTheChoices() {
        #expect(BackfillText.reuse(estimate(cap: 1_900_000, cached: 25, yours: 4)) == "25 verdicts and 4 of your marks reused · stops at 1.5× ($1.90)")
        #expect(BackfillText.reuse(estimate(cap: 1_900_000, cached: 1)) == "1 verdict reused · stops at 1.5× ($1.90)")
        #expect(BackfillText.reuse(estimate(needClaude: 0, micros: 0, yours: 2)) == "2 of your marks reused")
        #expect(BackfillText.reuse(estimate(needClaude: 0, micros: 0)) == "")
        #expect(BackfillText.room(RunRoom(today: 1_880_000, month: 13_180_000, reserve: 1_700_000))
            == "Runs may use $1.88 today, $13.18 this month; $1.70 stays for new mail")
        #expect(BackfillText.otherModels([(name: "Sonnet 5.5", micros: 630_000), (name: "Opus 5.5", micros: 1_270_000)])
            == "Selected on Sonnet 5.5 ≈ $0.63 · Opus 5.5 ≈ $1.27 (change in Settings)")
        #expect(BackfillText.otherModels([]) == nil)
    }

    @Test func gapOffer() throws {
        let calendar = Calendar.current
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 17)))
        let gap = DateInterval(start: start, end: end)
        #expect(BackfillText.gap(gap, estimate: estimate(passing: 37, needClaude: 37, micros: 470_000), asksClaude: true) == "off 9–14 Oct · 37 messages · ≈ $0.47")
        #expect(BackfillText.gap(gap, estimate: estimate(passing: 1, needClaude: 0, micros: 0), asksClaude: false) == "off 9–14 Oct · 1 message · free")
    }

    @Test func otherModelsAtListPrices() {
        // Haiku 5.5: 2,400 characters at 4 a token × $0.10, 1,000 cached tokens × $0.01, 120 out × $0.50.
        let haiku = TokenPrices(input: 0.10, cacheRead: 0.01, output: 0.50)
        #expect(RuleEngine.listPriceMicros(calls: 1, prices: haiku) == 130)
        #expect(RuleEngine.listPriceMicros(calls: 309, prices: haiku) == 309 * 130)
        #expect(RuleEngine.listPriceMicros(calls: -3, prices: haiku) == 0)
    }
}

@Suite("Rules manager text")
struct RulesManagerTextTests {
    let created = Date(timeIntervalSince1970: 1_791_000_000)

    func record(_ name: String, when: String = "", ask: String? = nil, enabled: Bool = true, state: RuleRecord.State = .ok, revision: Int = 3, since: Date? = nil) -> RuleRecord {
        var rule = Rule(id: "r_\(name.lowercased())", key: "r1", name: name, enabled: enabled, revision: revision, when: when, ask: ask,
                        then: [.addLabel(LabelRef(id: "Label_1", lastKnownName: name.lowercased()))])
        rule.enabled = enabled
        return RuleRecord(rule: rule, position: 0, state: state, liveFrom: since, coveredSince: since, disabledAt: nil, createdAt: created, updatedAt: created)
    }

    func run(
        _ id: Int64, kind: RunKind = .backfill, rules: [RunRule] = [RunRule(id: "r_receipts", revision: 3)], state: RunState = .done,
        pause: RunPauseReason? = nil, total: Int = 129, done: Int = 129, judged: Int = 100, labeled: Int = 31, cost: Int64 = 1_240_000,
        plus: Int? = nil, minus: Int? = nil, estimate: Int64? = nil, cap: Int64? = nil, window: ClosedRange<Date>? = nil, confirmed: Date? = nil
    ) -> RunRecord {
        RunRecord(
            id: id, kind: kind, day: nil, rules: rules, window: window, state: state, pauseReason: pause, model: "claude-haiku-5-5", total: total, done: done,
            judged: judged, labeled: labeled, failed: 0, plus: plus, minus: minus, estimateMicros: estimate, capMicros: cap, costMicros: cost,
            createdAt: created, confirmedAt: confirmed, finishedAt: nil
        )
    }

    func priced(_ micros: Int64, needClaude: Int = 30) -> RunEstimate {
        RunEstimate(plan: nil, counts: nil, window: nil, messages: needClaude, needClaude: needClaude, perCallMicros: 130, fromHistory: true,
                    micros: micros, capMicros: micros * 3 / 2, fitsToday: true)
    }

    @Test func ruleRows() throws {
        let since = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 12)))
        #expect(record("Deploys", when: "from:@ci.example").kindText == "filter")
        #expect(record("Receipts", when: "-from:@studio.co", ask: "Receipts").kindText == "filter+Claude")
        #expect(record("Needs reply", ask: "A person waits for me").kindText == "Claude")
        #expect(record("Spaces", ask: "   ").kindText == "filter")
        #expect(record("Receipts", since: since).countsText(RuleStats(labeled: 212, unsure: 3)) == "212 labeled · 3 unsure · since 9 Jul")
        #expect(record("Receipts").countsText(nil) == "0 labeled")
        #expect(record("Receipts").warning == nil)
        #expect(record("Reply", state: .tripped).warning == "tripped: it matched most new mail · x turns it back on")
        #expect(record("Reply", state: .labelMissing).warning == "label missing · ↵ pick another")
        #expect(record("Reply", state: .needsUpgrade).warning == "needs a newer vimail")
    }

    @Test func managerSummary() {
        var status = RuleEngineStatus()
        status.spendMonth = 3_120_000
        status.budgetMonth = 20_000_000
        status.spendToday = 420_000
        status.budgetDay = 3_000_000
        status.waitingAI = 2
        status.failed = 1
        #expect(status.managerSummary(month: "October", model: "Haiku 5.5") == "October $3.12/$20.00 · today $0.42/$3.00 · Haiku 5.5 · 2 waiting · 1 failed")
        status.userPaused = true
        status.held = 740
        status.unsureToReview = 3
        #expect(status.managerSummary(month: "October", model: "Haiku 5.5")
            == "October $3.12/$20.00 · today $0.42/$3.00 · Haiku 5.5 · paused · 2 waiting · 740 held · 1 failed · 3 unsure")
    }

    @Test func finishedRuns() throws {
        let rules = [record("Receipts")]
        let start = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12)))
        let done = run(41, window: start...Date.distantFuture).activityLine(rules: rules, estimate: nil)
        #expect(done == ActivityLine(id: 41, kind: "backfill from 4 Oct", rules: "Receipts v3", detail: "129 · 100 judged · 31 labeled · $1.24", key: "u", needsYou: false))
        #expect(run(42).activityLine(rules: rules, estimate: nil).kind == "backfill, all")
        #expect(run(43, labeled: 0).activityLine(rules: rules, estimate: nil).key == nil)
        #expect(run(44, state: .cancelled).activityLine(rules: rules, estimate: nil).detail == "129 · 100 judged · 31 labeled · $1.24 · cancelled")
        let undone = run(45, state: .undone).activityLine(rules: rules, estimate: nil)
        #expect(undone.detail.hasSuffix("· undone") && undone.key == nil)
        // A deleted rule, and runs of several rules.
        #expect(run(46, rules: [RunRule(id: "r_gone", revision: 2)]).activityLine(rules: rules, estimate: nil).rules == "deleted rule v2")
        #expect(run(47, kind: .manual, rules: [RunRule(id: "a", revision: 1), RunRule(id: "b", revision: 1)]).activityLine(rules: rules, estimate: nil).rules == "2 rules")
        let live = run(48, kind: .live, state: .running, total: 58, judged: 21, labeled: 9, cost: 300_000).activityLine(rules: rules, estimate: nil)
        #expect(live.rules == "all rules" && live.detail == "58 · 21 judged · 9 labeled · $0.30" && live.key == "u")
        #expect(live.kind == "live " + RuleText.day(created))
    }

    @Test func runningRuns() {
        let rules = [record("Receipts")]
        let running = run(41, state: .running, done: 84, cost: 1_060_000).activityLine(rules: rules, estimate: nil)
        #expect(running.detail == "84/129 · 31 labeled · $1.06 · running" && running.key == "c" && !running.needsYou)
        // A re-check counts first.
        let counting = run(42, kind: .recheck, state: .running, total: 212, done: 40, cost: 50_000).activityLine(rules: rules, estimate: nil)
        #expect(counting.detail == "counting 40/212 · $0.05" && counting.kind == "re-check")
    }

    @Test func runsWaitingForYou() throws {
        let rules = [record("Receipts", revision: 4)]
        // Paused because the rule changed: continue with the new revision, priced now.
        let changed = run(41, state: .paused, pause: .ruleChanged, done: 40, cost: 500_000).activityLine(rules: rules, estimate: priced(400_000))
        #expect(changed.detail == "40/129 · $0.50 · paused: Receipts changed · ↵ continue with v4 ≈ $0.40")
        #expect(changed.key == "↵" && changed.needsYou && changed.rules == "Receipts v3")
        let capped = run(42, state: .paused, pause: .cap, done: 90, cap: 1_900_000).activityLine(rules: rules, estimate: priced(200_000))
        #expect(capped.detail == "90/129 · $1.24 · paused: reached its cap ($1.90) · ↵ continue ≈ $0.20")
        let budget = run(43, state: .paused, pause: .budget, done: 90).activityLine(rules: rules, estimate: priced(0, needClaude: 0))
        #expect(budget.detail == "90/129 · $1.24 · paused: run budget spent; continues tomorrow · ↵ continue")
        // A counted re-check, and a gap waiting for confirmation.
        let recheck = run(44, kind: .recheck, state: .awaitingConfirm, plus: 5, minus: 3).activityLine(rules: rules, estimate: nil)
        #expect(recheck.detail == "+5 −3 · ↵ apply" && recheck.key == "↵")
        let start = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9)))
        let end = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9)))
        let gap = run(45, kind: .gap, state: .awaitingConfirm, total: 37, done: 0, estimate: 470_000, window: start...end)
        #expect(gap.activityLine(rules: rules, estimate: nil).detail == "37 messages · ≈ $0.47 · ↵ confirm")
        #expect(gap.activityLine(rules: rules, estimate: priced(520_000)).detail == "37 messages · ≈ $0.52 · ↵ confirm")
        #expect(gap.activityLine(rules: rules, estimate: priced(0, needClaude: 0)).detail == "37 messages · free · ↵ confirm")
        #expect(gap.activityLine(rules: rules, estimate: nil).kind == "gap 9–14 Oct")
        let backlog = run(46, kind: .backlog, rules: [], state: .awaitingConfirm, total: 740, done: 0).activityLine(rules: rules, estimate: nil)
        #expect(backlog.detail == "740 messages · ↵ confirm" && backlog.rules == "no rules")
    }
}
