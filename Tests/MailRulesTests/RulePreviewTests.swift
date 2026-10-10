import Foundation
import Testing
@testable import MailCore
@testable import MailRules
@testable import MailStore

@Suite("Rule engine: the editor's preview", .serialized)
struct RulePreviewTests {
    /// A different sender for each message: the sample takes at most 3 from one.
    func person(_ number: Int) -> EmailAddress {
        EmailAddress(name: nil, email: "person\(number)@example.com")
    }

    /// A draft that was never saved, adding the "receipts" label.
    func draft(_ harness: Harness, when: String = "", ask: String? = "Receipts and invoices for things I bought") async throws -> Rule {
        let label = try await harness.store.resolveLabel(name: "receipts")
        return Rule(key: "", name: "Receipts", when: when, ask: ask, then: [.addLabel(LabelRef(id: label.id, lastKnownName: label.name))])
    }

    @Test func sampleComposition() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let rule = try await harness.rule("Receipts")
        let label = try await harness.labelID("receipts")
        // An unsure verdict from live mail, to review.
        judge.set(.unsure, for: "unsure", rule: "r1")
        try await harness.deliver(mail("unsure", subject: "Invoice question", minutesAgo: 600))
        await harness.engine.drain()
        // Mail you marked, mail carrying the label, and recent mail: one busy sender among others.
        try await harness.store.upsertMessages(
            [mail("marked", subject: "Old order", minutesAgo: 900), mail("labeled", subject: "Paid", minutesAgo: 800, labels: ["INBOX", label])]
                + (0..<6).map { mail("busy\($0)", from: shop, subject: "Sale \($0)", minutesAgo: Double($0)) }
                + (0..<30).map { mail("other\($0)", from: person($0), subject: "Note \($0)", minutesAgo: 10 + Double($0)) }
        )
        try await harness.store.setExample(ruleID: rule.id, messageID: "marked", matches: true, origin: .preview)

        let rows = await collect(await harness.engine.preview(rule)).rows
        #expect(Array(rows.prefix(3).map(\.messageID)) == ["marked", "unsure", "labeled"])
        #expect(rows.prefix(3).map(\.section) == [.marked, .unsure, .labeled])
        let recent = rows.filter { $0.section == .recent }
        #expect(recent.count == 20)
        #expect(recent.filter { $0.sender.email == shop.email }.map(\.messageID) == ["busy0", "busy1", "busy2"])
        #expect(recent.map(\.date) == recent.map(\.date).sorted(by: >))
        #expect(rows.first { $0.messageID == "unsure" }?.outcome == .unsure)
        // WHEN previews are free.
        #expect(judge.calls.count == 1)

        // `+` adds 20 more.
        let more = await collect(await harness.engine.preview(rule, sample: PreviewSample(extra: 1))).rows
        #expect(more.filter { $0.section == .recent }.count == 33)
    }

    @Test func flagsShowDisagreementStaleVerdictsAndYourMarks() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let label = try await harness.labelID("receipts")
        try await harness.store.upsertMessages([
            mail("yours", subject: "Receipt", minutesAgo: 3, labels: ["INBOX", label]),
            mail("judged", subject: "Receipt", minutesAgo: 2),
            mail("mine", subject: "Receipt", minutesAgo: 1),
        ])
        // Claude said no to a message you had labeled.
        _ = try await harness.engine.runRules(on: ["yours", "judged"])
        await harness.engine.drain()
        let rule = try await harness.rule("Receipts")
        // A newer mark: verdicts made before it are dimmed.
        try await harness.store.setExample(ruleID: rule.id, messageID: "mine", matches: true, origin: .preview)

        let rows = latest(await collect(await harness.engine.preview(rule)).rows)
        let yours = try #require(rows.first { $0.messageID == "yours" })
        #expect(yours.disagrees && yours.outcome == .noMatch && yours.source == .cache && yours.reason == "fake: no_match")
        #expect(yours.judgedBeforeNewestMarks)
        let judged = try #require(rows.first { $0.messageID == "judged" })
        #expect(!judged.disagrees && judged.judgedBeforeNewestMarks)
        let mine = try #require(rows.first { $0.messageID == "mine" })
        #expect(mine.markedByYou && mine.outcome == .match && mine.source == .example && !mine.judgedBeforeNewestMarks)
    }

    @Test func streamsVerdictsAsTheyArrive() async throws {
        let judge = FakeJudge(matching: ["r0": ["receipt"]])
        let harness = try await Harness(judge: judge)
        let draft = try await draft(harness, when: "-from:studio.co")
        let label = try await harness.labelID("receipts")
        try await harness.store.upsertMessages([
            mail("a", from: stripe, subject: "Your receipt", minutesAgo: 2), mail("b", from: shop, subject: "Sale", minutesAgo: 1),
            mail("c", from: ana, subject: "Lunch receipt", minutesAgo: 3, labels: ["INBOX", label]),
        ])
        let rows = await collect(await harness.engine.preview(draft, test: .atIssue(limit: 12))).rows
        // Every row first, the tested ones marked; then each again with its verdict.
        #expect(rows.prefix(3).map(\.messageID) == ["c", "b", "a"])
        #expect(rows.prefix(3).map(\.testing) == [false, true, true])
        // Labeled, but WHEN leaves it out: the recall check flags it.
        #expect(rows[0].outcome == .filteredOut && rows[0].section == .labeled && rows[0].disagrees)
        let updates = rows.dropFirst(3)
        #expect(Set(updates.map(\.messageID)) == ["a", "b"])
        #expect(updates.allSatisfy { !$0.testing && $0.source == .claude })
        #expect(updates.first { $0.messageID == "a" }?.outcome == .match)
        #expect(updates.first { $0.messageID == "b" }?.outcome == .noMatch)
        // One rule in the prompt, under the draft key, in the preview lane.
        #expect(judge.calls.count == 2)
        #expect(judge.calls.allSatisfy { $0.lane == .preview && $0.catalog.map(\.key) == ["r0"] && $0.evaluate == ["r0"] })
        // Nothing is committed.
        #expect(try await !harness.hasLabel("a", "receipts"))
        #expect(try harness.queue().isEmpty)
    }

    @Test func atIssueOrdering() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        let label = try await harness.labelID("receipts")
        try await harness.store.upsertMessages([
            mail("plain", subject: "One", minutesAgo: 1), mail("unsure", subject: "Two", minutesAgo: 2),
            mail("disagree", subject: "Three", minutesAgo: 3, labels: ["INBOX", label]), mail("fresh", subject: "Four", minutesAgo: 4),
        ])
        judge.set(.unsure, for: "unsure", rule: "r1")
        _ = try await harness.engine.runRules(on: ["plain", "unsure", "disagree"])
        await harness.engine.drain()
        let rule = try await harness.rule("Receipts")
        let entries = try await harness.engine.previewEntries(rule, sample: PreviewSample())
        let picked = RuleEngine.picked(entries, for: .atIssue(limit: 12)).map { entries[$0].row.messageID }
        // Not judged first, then ≠, then unsure; a settled verdict is not at issue.
        #expect(picked == ["fresh", "disagree", "unsure"])
        #expect(RuleEngine.picked(entries, for: .atIssue(limit: 2)).map { entries[$0].row.messageID } == ["fresh", "disagree"])
        #expect(Set(RuleEngine.picked(entries, for: .all).map { entries[$0].row.messageID }) == ["fresh", "disagree", "unsure", "plain"])

        // A newer mark makes settled verdicts at issue too, last.
        try await harness.store.upsertMessages([mail("marked", subject: "Five", minutesAgo: 5)])
        try await harness.store.setExample(ruleID: rule.id, messageID: "marked", matches: false, origin: .preview)
        let after = try await harness.engine.previewEntries(rule, sample: PreviewSample())
        #expect(RuleEngine.picked(after, for: .atIssue(limit: 12)).map { after[$0].row.messageID } == ["fresh", "disagree", "unsure", "plain"])

        let cost = try await harness.engine.previewCost(rule, test: .atIssue(limit: 12))
        #expect(cost.calls == 4 && cost.micros == 4_000)
    }

    @Test func cancellingTheStreamCancelsCalls() async throws {
        let judge = FakeJudge()
        judge.hold()
        let harness = try await Harness(judge: judge)
        try await harness.store.upsertMessages((0..<6).map { mail("m\($0)", from: person($0), subject: "Message \($0)", minutesAgo: Double($0)) })
        let draft = try await draft(harness)
        let stream = await harness.engine.preview(draft, test: .all)
        let reader = Task { await collect(stream) }
        try await eventually("calls in flight") { judge.waiting == RuleEngine.judgeConcurrency }
        reader.cancel()
        try await eventually("calls cancelled") { judge.waiting == 0 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(judge.calls.count == RuleEngine.judgeConcurrency)
        let hash = try #require(draft.judgeHash(model: testConfig.model, effort: testConfig.effort, promptVersion: testConfig.promptVersion))
        #expect(try await harness.store.verdicts(messageIDs: (0..<6).map { "m\($0)" }, judgeHashes: [hash]).isEmpty)
        judge.release()
    }

    @Test func previewAllowanceStops() async throws {
        let judge = FakeJudge()
        judge.fail(after: 1, with: .budget(.previewRoom))
        let harness = try await Harness(judge: judge)
        try await harness.store.upsertMessages((0..<5).map { mail("m\($0)", from: person($0), subject: "Message \($0)", minutesAgo: Double($0)) })
        let draft = try await draft(harness)
        let (rows, error) = await collect(await harness.engine.preview(draft, test: .all))
        #expect(error as? PreviewError == .budget(.previewRoom))
        let final = latest(rows)
        #expect(final.count == 5)
        #expect(final.allSatisfy { !$0.testing })
        #expect(final.filter { $0.source == .claude }.count == 1)
        #expect(final.filter { $0.outcome == .notJudged }.count == 4)
        // Live rules are not affected.
        #expect(await harness.engine.ai == .ready)
    }

    @Test func previewWithoutClaude() async throws {
        let harness = try await Harness(judge: nil)
        try await harness.store.upsertMessages([mail("a", from: stripe, subject: "Your receipt"), mail("b", from: ana, subject: "Lunch")])
        // A filter-only draft needs no judge.
        let filter = try await draft(harness, when: "from:stripe.com", ask: nil)
        let (rows, error) = await collect(await harness.engine.preview(filter, test: .all))
        #expect(error == nil)
        #expect(rows.map(\.messageID) == ["a"] && rows.map(\.outcome) == [.match])
        // Testing a Claude draft says why it can't.
        let claude = try await draft(harness)
        let (claudeRows, claudeError) = await collect(await harness.engine.preview(claude, test: .all))
        #expect(claudeError as? PreviewError == .paused(.noKey))
        #expect(latest(claudeRows).allSatisfy { $0.outcome == .notJudged && !$0.testing })
        // A WHEN that rules can't use fails the stream.
        let (_, invalid) = await collect(await harness.engine.preview(try await draft(harness, when: "is:unread", ask: nil)))
        #expect(invalid is RuleFilter.Problem)
    }

    @Test func saveAsTestedReusesPreview() async throws {
        let judge = FakeJudge(matching: ["r0": ["receipt"], "r1": ["receipt"]])
        let harness = try await Harness(judge: judge)
        try await harness.store.upsertMessages([
            mail("a", from: stripe, subject: "Your receipt", minutesAgo: 1), mail("b", from: apple, subject: "Your receipt from Apple", minutesAgo: 2),
            mail("c", from: shop, subject: "Sale", minutesAgo: 3),
        ])
        let draft = try await draft(harness)
        let rows = latest(await collect(await harness.engine.preview(draft, test: .all)).rows)
        #expect(judge.calls.count == 3)
        #expect(rows.filter { $0.outcome == .match }.count == 2)

        // Save, then apply to stored mail: every verdict comes from the preview.
        let saved = try await harness.store.createRule(draft)
        try await harness.engine.rulesChanged(.created(ruleID: saved.id))
        let estimate = try await harness.engine.estimate(RunPlan(ruleID: saved.id, window: .allCached))
        #expect(estimate.needClaude == 0 && estimate.counts?.cachedVerdicts == 3)
        _ = try await harness.engine.startRun(RunPlan(ruleID: saved.id, window: .allCached))
        await harness.engine.drain()
        #expect(judge.calls.count == 3)
        #expect(try await harness.hasLabel("a", "receipts"))
        #expect(try await harness.hasLabel("b", "receipts"))
        #expect(try await !harness.hasLabel("c", "receipts"))
    }

    /// `T`: the email is the unsaved rule's ✔ seed, preview marks join it, `⌃r` tests with them, and
    /// saving keeps all of it, so the run asks Claude about nothing the preview decided.
    @Test func marksOnAnUnsavedDraftCarryIntoTheSavedRule() async throws {
        let judge = FakeJudge(matching: ["r0": ["receipt"], "r1": ["receipt"]])
        let harness = try await Harness(judge: judge)
        try await harness.store.upsertMessages([
            mail("seed", from: stripe, subject: "Your receipt from Figma", minutesAgo: 1), mail("sale", from: shop, subject: "Receipt-worthy sale", minutesAgo: 2),
            mail("apple", from: apple, subject: "Your receipt from Apple", minutesAgo: 3), mail("note", from: ana, subject: "Lunch", minutesAgo: 4),
        ])
        var draft = try await draft(harness)
        try await harness.store.setExample(ruleID: draft.id, messageID: "seed", matches: true, origin: .seed, draft: true)
        try await harness.store.setExample(ruleID: draft.id, messageID: "sale", matches: false, origin: .preview, draft: true)
        let marked = latest(await collect(await harness.engine.preview(draft)).rows)
        #expect(marked.prefix(2).map(\.messageID).sorted() == ["sale", "seed"] && marked.prefix(2).allSatisfy(\.markedByYou))
        #expect(marked.first { $0.messageID == "sale" }?.outcome == .noMatch)

        // ⌃r snapshots the marks into the draft; marked rows are never sent.
        draft.promptExampleIDs = ["seed", "sale"]
        let tested = latest(await collect(await harness.engine.preview(draft, test: .atIssue(limit: 12))).rows)
        #expect(Set(judge.calls.map(\.messageID)) == ["apple", "note"])
        #expect(Set(judge.calls.flatMap(\.examples).map(\.verdict)) == [.match, .noMatch])
        #expect(tested.first { $0.messageID == "apple" }?.outcome == .match && tested.allSatisfy { !$0.judgedBeforeNewestMarks })

        let saved = try await harness.store.createRule(draft)
        try await harness.engine.rulesChanged(.created(ruleID: saved.id))
        #expect(saved.id == draft.id && saved.rule.promptExampleIDs == ["seed", "sale"])
        let estimate = try await harness.engine.estimate(RunPlan(ruleID: saved.id, window: .allCached))
        #expect(estimate.needClaude == 0 && estimate.counts?.decidedByYou == 2 && estimate.counts?.cachedVerdicts == 2)
        _ = try await harness.engine.startRun(RunPlan(ruleID: saved.id, window: .allCached))
        await harness.engine.drain()
        #expect(judge.calls.count == 2)
        #expect(try await harness.hasLabel("seed", "receipts"))
        #expect(try await harness.hasLabel("apple", "receipts"))
        #expect(try await !harness.hasLabel("sale", "receipts"))
    }

    @Test func savedRulesUseTheirKeyAndTestedExamples() async throws {
        let judge = FakeJudge()
        let harness = try await Harness(rules: [receiptsRule], judge: judge)
        try await harness.store.upsertMessages([mail("a", subject: "One", minutesAgo: 1), mail("x", from: shop, subject: "Sale", minutesAgo: 5)])
        var rule = try await harness.rule("Receipts")
        try await harness.store.setExample(ruleID: rule.id, messageID: "x", matches: false, origin: .preview)
        rule.promptExampleIDs = ["x"]
        _ = await collect(await harness.engine.preview(rule, test: .atIssue(limit: 12)))
        #expect(judge.calls.map(\.evaluate) == [["r1"]])
        #expect(judge.calls.first?.examples.map(\.ruleKey) == ["r1"])
        #expect(judge.calls.first?.examples.first?.digest.hasPrefix("Allbirds · @allbirds.com") == true)
    }
}
