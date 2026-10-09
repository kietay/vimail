import Foundation
import Testing
@testable import MailCore

@Suite("Rule model")
struct RuleModelTests {
    let receipts = LabelRef(id: "local-1a2b3c4d", lastKnownName: "receipts")

    @Test func roundTripsAndDefaultsToTeachingEdits() throws {
        var rule = Rule(key: "r1", name: "Receipts", when: "-from:@studio.co", ask: "Receipts for things I bought", then: [.addLabel(receipts)])
        rule.promptExampleIDs = ["m1"]
        #expect(rule.id.hasPrefix("r_") && rule.id.count == 10)
        #expect(rule.editsTeach)
        #expect(rule.asksClaude && rule.isSupported)
        let decoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        #expect(decoded == rule)
        #expect(decoded.labelTargets == [receipts])
    }

    @Test func missingFieldsTakeDefaults() throws {
        let json = #"{"id":"r_1","key":"r3","name":"Deploys","enabled":true,"revision":2,"when":"from:vercel","then":[{"type":"addLabel","label":{"id":"L","lastKnownName":"deploys"}}]}"#
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        #expect(rule.editsTeach && !rule.stopAfterMatch && rule.scope == RuleScope() && rule.ask == nil)
        #expect(!rule.asksClaude)
        #expect(rule.isSupported)
    }

    @Test func unknownActionsAreKeptAndStopTheRule() throws {
        let json = #"{"id":"r_1","key":"r3","name":"Later","enabled":true,"revision":1,"when":"","then":[{"type":"addLabel","label":{"id":"L","lastKnownName":"x"}},{"type":"forward","to":"a@b.co","options":{"keep":true,"n":3}}]}"#
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        #expect(!rule.isSupported)
        guard case .unsupported(let type, let payload) = rule.then[1] else {
            Issue.record("expected .unsupported")
            return
        }
        #expect(type == "forward")
        #expect(rule.then[1].risk == .outbound && rule.then[0].risk == .annotative)
        // Saving it again writes the action back unchanged, for the newer build.
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as! [String: Any]
        let action = (saved["then"] as! [[String: Any]])[1]
        #expect(action["to"] as? String == "a@b.co")
        #expect((action["options"] as? [String: Any])?["n"] as? Int == 3)
        #expect(payload.contains("\"keep\":true"))
        // A malformed addLabel is unsupported too, not a failure to load the rule.
        let broken = try JSONDecoder().decode(RuleAction.self, from: Data(#"{"type":"addLabel","label":"oops"}"#.utf8))
        #expect(broken == .unsupported(type: "addLabel", json: #"{"label":"oops","type":"addLabel"}"#))
    }

    @Test func unknownScopesAreKeptAndStopTheRule() throws {
        for mailboxes in [#""everything""#, #"{"labels":["L"]}"#] {
            let json = #"{"id":"r_1","key":"r3","name":"Later","enabled":true,"revision":1,"when":"","scope":{"mailboxes":\#(mailboxes),"inheritInThread":true},"then":[]}"#
            let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
            #expect(!rule.isSupported && !rule.scope.isSupported, "\(mailboxes)")
            #expect(rule.scope.inheritInThread)
            // Saving it again writes the scope back unchanged, for the newer build.
            let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as! [String: Any]
            let scope = try #require(saved["scope"] as? [String: Any])
            let original = try JSONSerialization.jsonObject(with: Data("[\(mailboxes)]".utf8)) as! [Any]
            #expect(NSArray(array: [scope["mailboxes"] as Any]).isEqual(to: original), "\(mailboxes)")
        }
        let inbox = try JSONDecoder().decode(RuleScope.self, from: Data(#"{"mailboxes":"inbox"}"#.utf8))
        #expect(inbox == RuleScope(mailboxes: .inbox) && inbox.isSupported)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inbox)) as? [String: Any]
        #expect(encoded?["mailboxes"] as? String == "inbox")
    }

    @Test func newerSchemaVersionsDoNotRun() throws {
        let json = #"{"schemaVersion":2,"id":"r_1","key":"r1","then":[]}"#
        #expect(!(try JSONDecoder().decode(Rule.self, from: Data(json.utf8))).isSupported)
    }

    @Test func semanticChangesNeedANewRevision() {
        let rule = Rule(key: "r1", name: "Receipts", when: "from:stripe", then: [.addLabel(receipts)])
        var renamed = rule
        renamed.name = "Bills"
        renamed.editsTeach = false
        #expect(!renamed.changesSemantics(from: rule))
        for change: (inout Rule) -> Void in [{ $0.when = "" }, { $0.ask = "Bills" }, { $0.then = [] }, { $0.stopAfterMatch = true }, { $0.scope.mailboxes = .inbox }] {
            var edited = rule
            change(&edited)
            #expect(edited.changesSemantics(from: rule))
        }
    }

    @Test func verdictsUseTheSchemaSpelling() throws {
        #expect(try JSONEncoder().encode([Verdict.noMatch]) == Data(#"["no_match"]"#.utf8))
        #expect(Verdict.match.isMatch && !Verdict.unsure.isMatch && !Verdict.declined.isMatch)
        #expect(ActionRisk.annotative < .visibility && ActionRisk.destructive < .outbound)
    }
}

@Suite("WHEN")
struct RuleFilterTests {
    @Test func splitsLabelTermsFromTheRest() throws {
        let filter = try RuleFilter.parse("invoice \"order total\" -newsletter from:stripe -from:@studio.co to:me subject:receipt label:work -label:\"Needs reply\" has:attachment is:list after:2026-01-01 before:2026/12/31")
        #expect(filter.labelTerms == [.init(name: "work"), .init(name: "Needs reply", negated: true)])
        #expect(filter.query.labelNames.isEmpty && filter.query.excludedLabelNames.isEmpty)
        #expect(filter.query.terms == ["invoice"])
        #expect(filter.query.phrases == ["order total"])
        #expect(filter.query.excluded == ["newsletter"])
        #expect(filter.query.from == ["stripe"])
        #expect(filter.query.excludedFrom == ["@studio.co"])
        #expect(filter.query.to == ["me"] && filter.query.subject == ["receipt"])
        #expect(filter.query.hasAttachment == true && filter.query.isList == true)
        #expect(filter.query.after != nil && filter.query.before != nil)
        #expect(try RuleFilter.parse("") == RuleFilter(query: SearchQuery(), labelTerms: []))
    }

    @Test func rejectsOperatorsThatChangeAfterArrival() {
        for when in ["in:inbox", "is:unread", "is:read", "is:starred", "newer_than:2d", "older_than:1y", "from:x IN:trash"] {
            #expect(throws: RuleFilter.Problem.self, "\(when)") { try RuleFilter.parse(when) }
        }
        do {
            _ = try RuleFilter.parse("from:stripe is:unread")
            Issue.record("is:unread was accepted")
        } catch {
            #expect(error.term == "is:unread")
            #expect(error.message.contains("changes after a message arrives"))
        }
    }

    @Test func rejectsUnsupportedOrIncompleteOperators() {
        for when in ["is:important", "has:drive", "-subject:x", "-has:attachment", "-is:list", "before:soon", "from:", "label:\"\""] {
            #expect(throws: RuleFilter.Problem.self, "\(when)") { try RuleFilter.parse(when) }
        }
        // Unknown keys are text, as in search.
        #expect((try? RuleFilter.parse("re:hello"))?.query.terms == ["re:hello"])
    }

    @Test func labelTermsResolveEveryLabelWithTheName() {
        let labels = [
            MailLabel(id: "Label_1", name: "Receipts", kind: .user),
            MailLabel(id: "local-1", name: "receipts", kind: .local),
            MailLabel(id: "Label_2", name: "Travel", kind: .user),
        ]
        #expect(RuleFilter.LabelTerm(name: "RECEIPTS").labelIDs(in: labels) == ["Label_1", "local-1"])
        #expect(RuleFilter.LabelTerm(name: "missing").labelIDs(in: labels).isEmpty)
    }
}

@Suite("Rule planner")
struct RulePlannerTests {
    typealias Input = RulePlanner.Input

    func filter(_ id: String, adds: String, gate: Bool = true, labels: [RulePlanner.LabelCondition] = [], stop: Bool = false, decision: Verdict? = nil) -> Input {
        Input(ruleID: id, asks: false, stopAfterMatch: stop, adds: [adds], gate: gate, labelConditions: labels, decision: decision)
    }

    func claude(_ id: String, adds: String, gate: Bool = true, labels: [RulePlanner.LabelCondition] = [], stop: Bool = false, decision: Verdict? = nil) -> Input {
        Input(ruleID: id, asks: true, stopAfterMatch: stop, adds: [adds], gate: gate, labelConditions: labels, decision: decision)
    }

    func has(_ label: String) -> RulePlanner.LabelCondition { .init(labelIDs: [label]) }
    func lacks(_ label: String) -> RulePlanner.LabelCondition { .init(labelIDs: [label], negated: true) }

    func outcomes(_ plan: RulePlan) -> [RulePlan.Outcome] { plan.steps.map(\.outcome) }

    @Test func rulesFoldInOrderOverTheWorkingLabels() {
        let plan = RulePlanner.plan([filter("a", adds: "A"), filter("b", adds: "B", gate: false), filter("c", adds: "C")], labels: ["INBOX"])
        #expect(plan.matched == ["a", "c"])
        #expect(outcomes(plan) == [.matched, .notMatched, .matched])
        #expect(plan.steps.map(\.labels) == [["INBOX", "A"], ["INBOX", "A"], ["INBOX", "A", "C"]])
        #expect(plan.labelAdds == ["A", "C"])
        #expect(plan.isComplete && plan.needsVerdict.isEmpty && plan.stoppedBy == nil)
    }

    @Test func labelChainingSeesEarlierAdds() {
        // b tests the label a adds: it matches only because a ran first.
        let chained = RulePlanner.plan([filter("a", adds: "A"), filter("b", adds: "B", labels: [has("A")])], labels: [])
        #expect(chained.matched == ["a", "b"])
        let reversed = RulePlanner.plan([filter("b", adds: "B", labels: [has("A")]), filter("a", adds: "A")], labels: [])
        #expect(reversed.matched == ["a"])
        // Present on the message already.
        #expect(RulePlanner.plan([filter("b", adds: "B", labels: [has("A")])], labels: ["A"]).matched == ["b"])
        // A term naming no label at all never holds, and is not worth a Claude call.
        let nameless = RulePlanner.plan([claude("b", adds: "B", labels: [.init(labelIDs: [])])], labels: [])
        #expect(outcomes(nameless) == [.notMatched] && nameless.needsVerdict.isEmpty)
    }

    @Test func negativeLabelTerms() {
        #expect(RulePlanner.plan([filter("a", adds: "A"), filter("b", adds: "B", labels: [lacks("A")])], labels: []).matched == ["a"])
        #expect(RulePlanner.plan([filter("a", adds: "A", gate: false), filter("b", adds: "B", labels: [lacks("A")])], labels: []).matched == ["b"])
        #expect(RulePlanner.plan([filter("b", adds: "B", labels: [lacks("A")])], labels: ["A"]).matched.isEmpty)
        // Both kinds together.
        let both = RulePlanner.plan([filter("b", adds: "B", labels: [has("X"), lacks("Y")])], labels: ["X"])
        #expect(both.matched == ["b"])
    }

    @Test func stopAfterMatchEndsThePass() {
        let stopped = RulePlanner.plan([filter("a", adds: "A", stop: true), claude("b", adds: "B"), filter("c", adds: "C")], labels: [])
        #expect(outcomes(stopped) == [.matched, .skipped, .skipped])
        #expect(stopped.stoppedBy == "a")
        // Skipped rules are not worth a Claude call.
        #expect(stopped.needsVerdict.isEmpty && stopped.isComplete)
        // A stop rule that does not match lets the pass go on.
        let open = RulePlanner.plan([filter("a", adds: "A", gate: false, stop: true), filter("c", adds: "C")], labels: [])
        #expect(open.matched == ["c"] && open.stoppedBy == nil)
    }

    @Test func rulesWithoutAskNeedNoVerdict() {
        let plan = RulePlanner.plan([filter("a", adds: "A")], labels: [])
        #expect(plan.needsVerdict.isEmpty && plan.matched == ["a"])
        // A removal mark decides a filter rule too: it does not re-add the label.
        let marked = RulePlanner.plan([filter("a", adds: "A", decision: .noMatch)], labels: [])
        #expect(outcomes(marked) == [.notMatched])
    }

    @Test func missingVerdictsLeaveOnlyDependentRulesPending() {
        let rules = [
            claude("a", adds: "A"),
            filter("b", adds: "B", labels: [has("A")]),
            filter("c", adds: "C"),
            claude("d", adds: "D", gate: false),
            claude("e", adds: "E", labels: [lacks("A")]),
        ]
        let prepass = RulePlanner.plan(rules, labels: [])
        // a needs Claude; b waits for a; c is independent; d is filtered out; e depends on a and asks.
        #expect(outcomes(prepass) == [.pending, .pending, .matched, .notMatched, .pending])
        #expect(prepass.needsVerdict == ["a", "e"])
        #expect(!prepass.isComplete)
        #expect(prepass.labelAdds == ["C"])
        #expect(prepass.steps[2].labels == ["C"])

        var decided = rules
        decided[0].decision = .match
        decided[4].decision = .match
        let final = RulePlanner.plan(decided, labels: [])
        #expect(final.isComplete && final.needsVerdict.isEmpty)
        #expect(final.matched == ["a", "b", "c"])
        #expect(outcomes(final) == [.matched, .matched, .matched, .notMatched, .notMatched])
    }

    @Test func pendingStopRuleHoldsTheRulesAfterIt() {
        let rules = [claude("a", adds: "A", stop: true), filter("b", adds: "B"), claude("c", adds: "C")]
        let prepass = RulePlanner.plan(rules, labels: [])
        #expect(outcomes(prepass) == [.pending, .pending, .pending])
        // c may still be reached, so it is asked in the same call.
        #expect(prepass.needsVerdict == ["a", "c"])

        var matched = rules
        matched[0].decision = .match
        matched[2].decision = .match
        #expect(outcomes(RulePlanner.plan(matched, labels: [])) == [.matched, .skipped, .skipped])

        var declined = rules
        declined[0].decision = .noMatch
        declined[2].decision = .match
        #expect(RulePlanner.plan(declined, labels: []).matched == ["b", "c"])
    }

    @Test func unsureAndDeclinedCountAsNoMatch() {
        for verdict in [Verdict.noMatch, .unsure, .declined] {
            let plan = RulePlanner.plan([claude("a", adds: "A", decision: verdict), filter("b", adds: "B", labels: [has("A")])], labels: [])
            #expect(outcomes(plan) == [.notMatched, .notMatched], "\(verdict)")
            #expect(plan.isComplete)
        }
    }

    @Test func coOwnersMatchWithoutAddingAgain() {
        let plan = RulePlanner.plan([filter("a", adds: "A"), filter("b", adds: "A")], labels: [])
        #expect(plan.matched == ["a", "b"])
        #expect(plan.steps.map(\.added) == [["A"], []])
        let yours = RulePlanner.plan([filter("a", adds: "A")], labels: ["A"])
        #expect(yours.matched == ["a"] && yours.labelAdds.isEmpty)
    }

    @Test func inputFromARule() {
        var rule = Rule(key: "r1", name: "Receipts", ask: "Receipts", then: [.addLabel(LabelRef(id: "L", lastKnownName: "receipts"))])
        rule.stopAfterMatch = true
        let input = RulePlanner.Input(rule: rule, gate: true)
        #expect(input.ruleID == rule.id && input.asks && input.stopAfterMatch && input.adds == ["L"])
    }
}

@Suite("Judge request")
struct JudgeRequestTests {
    let email = EmailDigest(message: MailMessage(id: "m1", threadID: "m1", labelIDs: [], from: EmailAddress(email: "a@b.co"), subject: "Hi", snippet: "", date: Date()), thread: [], selfAddresses: [])

    @Test func catalogIsSortedAndEvaluateFollowsIt() {
        let catalog = ["r10", "r2", "r1"].map { JudgeRule(key: $0, labelName: "L\($0)", ask: "?") }
        let request = JudgeRequest(lane: .run(4), catalog: catalog, evaluate: ["r10", "r1", "r99"], examples: [], email: email)
        #expect(request.catalog.map(\.key) == ["r1", "r2", "r10"])
        #expect(request.evaluate == ["r1", "r10"])
        #expect(request.cacheTTL == .fiveMinutes)
        #expect(JudgeRequest(lane: .live, catalog: catalog, evaluate: [], examples: [], email: email).cacheTTL == .oneHour)
        #expect(JudgeRequest(lane: .preview, catalog: catalog, evaluate: [], examples: [], email: email).cacheTTL == .fiveMinutes)
    }

    @Test func exampleDigestsCarrySenderNameDomainAndSubjectOnly() {
        let message = MailMessage(
            id: "m1", threadID: "m1", labelIDs: [], from: EmailAddress(name: "Figma via Stripe", email: "Receipts@Stripe.com"),
            subject: "Your receipt from Figma #4821-3390 <script>", snippet: "", date: Date(), textBody: "Amount paid $15"
        )
        #expect(JudgeExample.digest(of: message, selfAddresses: []) == "Figma via Stripe · @stripe.com · Your receipt from Figma #4821-3390 ‹script›")
        var long = message
        long.subject = String(repeating: "x", count: 300)
        long.from = EmailAddress(email: "noreply@shop.example")
        let digest = JudgeExample.digest(of: long, selfAddresses: [])
        #expect(digest.hasPrefix("@shop.example · "))
        #expect(digest.count == "@shop.example · ".count + JudgeExample.subjectLimit)
    }

    @Test func exampleDigestsNeverCarryYourAddresses() {
        var invitation = MailMessage(
            id: "m1", threadID: "m1", labelIDs: [], from: EmailAddress(name: "Calendar", email: "cal@google.com"),
            subject: "Invitation for Sam@Studio.co", snippet: "", date: Date()
        )
        #expect(JudgeExample.digest(of: invitation, selfAddresses: ["sam@studio.co"]) == "Calendar · @google.com · Invitation for me")
        // Replaced before the subject is cut, so no part of an address is left at the end.
        invitation.subject = String(repeating: "x", count: 110) + " sam@studio.co"
        invitation.from = EmailAddress(name: "'sam@studio.co' via Team", email: "team@groups.example")
        #expect(JudgeExample.digest(of: invitation, selfAddresses: ["sam@studio.co"]) == "'me' via Team · @groups.example · " + String(repeating: "x", count: 110) + " me")
    }
}

@Suite("Judge hash")
struct JudgeHashTests {
    let receipts = LabelRef(id: "local-1", lastKnownName: "receipts")

    @Test func keysOnPromptVersionModelEffortAndAsk() throws {
        let rule = Rule(key: "r1", name: "Receipts", ask: "Receipts for things I bought", then: [.addLabel(receipts)])
        let hash = try #require(rule.judgeHash(model: "claude-haiku-5-5", effort: "low", promptVersion: 1))
        // Pinned: a change here re-bills every cached verdict.
        #expect(hash == "49ad2e35e2e385e539691122f2e51e078fbd94ce883ae73b5ab65b53ea56dcde")
        #expect(hash == Rule.judgeHash(ask: "Receipts for things I bought", model: "claude-haiku-5-5", effort: "low", promptVersion: 1))

        // Each input re-keys; whitespace around the ASK does not.
        #expect(rule.judgeHash(model: "claude-opus-5-5", effort: "low", promptVersion: 1) != hash)
        #expect(rule.judgeHash(model: "claude-haiku-5-5", effort: "medium", promptVersion: 1) != hash)
        #expect(rule.judgeHash(model: "claude-haiku-5-5", effort: "low", promptVersion: 2) != hash)
        var edited = rule
        edited.ask = "Receipts for things I bought or subscribe to"
        #expect(edited.judgeHash(model: "claude-haiku-5-5", effort: "low", promptVersion: 1) != hash)
        edited.ask = "  Receipts for things I bought\n"
        #expect(edited.judgeHash(model: "claude-haiku-5-5", effort: "low", promptVersion: 1) == hash)

        // Examples, the label and everything else about the rule are not part of it.
        var other = rule
        other.name = "Bills"
        other.when = "from:stripe"
        other.then = [.addLabel(LabelRef(id: "Label_9", lastKnownName: "bills"))]
        other.promptExampleIDs = ["m1", "m2"]
        #expect(other.judgeHash(model: "claude-haiku-5-5", effort: "low", promptVersion: 1) == hash)

        // A rule without an ASK has none.
        #expect(Rule(key: "r2", name: "Deploys", when: "from:vercel", then: [.addLabel(receipts)]).judgeHash(model: "m", effort: "low", promptVersion: 1) == nil)
        #expect(Rule(key: "r2", name: "Blank", ask: "  ", then: [.addLabel(receipts)]).judgeHash(model: "m", effort: "low", promptVersion: 1) == nil)
    }
}

@Suite("Email digest")
struct EmailDigestTests {
    let me: Set<String> = ["sam@studio.co", "sam@hey.com"]
    let alex = EmailAddress(name: "Alex Morgan", email: "alex@parkhouse.me")

    @Test func describesAFirstMessage() {
        let message = MailMessage(
            id: "m1", threadID: "m1", labelIDs: ["INBOX", "CATEGORY_UPDATES"],
            from: EmailAddress(name: "Figma via Stripe", email: "receipts@stripe.com"),
            to: [EmailAddress(email: "SAM@studio.co"), EmailAddress(email: "team@studio.co")], cc: [EmailAddress(email: "sam@hey.com"), EmailAddress(email: "team@studio.co")],
            subject: "Your receipt", snippet: "", date: Date(timeIntervalSince1970: 1_791_000_000),
            htmlBody: "<p>Paid $15 to Figma. Questions? Write to sam@studio.co or visit https://stripe.com</p>",
            attachments: [
                MailAttachment(id: "a1", filename: "receipt-4821.pdf", mimeType: "application/pdf", size: 1000),
                MailAttachment(id: "a2", filename: "logo.png", mimeType: "image/png", size: 10, isInline: true),
            ],
            listUnsubscribe: "<mailto:unsub@stripe.com>"
        )
        let digest = EmailDigest(message: message, thread: [message], selfAddresses: me)
        #expect(digest.messageID == "m1")
        #expect(digest.from == EmailAddress(name: "Figma via Stripe", email: "receipts@stripe.com"))
        // Only team@: your own addresses are neither counted nor sent.
        #expect(digest.otherRecipients == 1)
        #expect(digest.isList)
        #expect(digest.category == .updates)
        #expect(digest.attachments == [EmailDigest.Attachment(filename: "receipt-4821.pdf", mimeType: "application/pdf")])
        #expect(!digest.isReply && digest.previous == nil)
        #expect(digest.body == "Paid $15 to Figma. Questions? Write to me or visit")
    }

    @Test func repliesCarryThePreviousMessage() throws {
        let first = MailMessage(
            id: "m1", threadID: "m1", labelIDs: ["SENT"], from: EmailAddress(name: "Sam", email: "sam@hey.com"), to: [alex],
            subject: "Plan", snippet: "", date: Date(timeIntervalSince1970: 1_000), textBody: String(repeating: "a", count: 1_000)
        )
        let second = MailMessage(
            id: "m2", threadID: "m1", labelIDs: ["INBOX"], from: alex, to: [EmailAddress(email: "sam@hey.com")],
            subject: "Re: Plan", snippet: "", date: Date(timeIntervalSince1970: 2_000), textBody: "Looks good"
        )
        let draft = MailMessage(
            id: "d1", threadID: "m1", labelIDs: ["DRAFT"], from: EmailAddress(email: "sam@hey.com"),
            subject: "Re: Plan", snippet: "", date: Date(timeIntervalSince1970: 1_500), textBody: "unsent"
        )
        let reply = EmailDigest(message: second, thread: [first, draft, second], selfAddresses: me)
        #expect(reply.isReply)
        // You sent the previous message: no address, and at most 400 characters of it.
        let previous = try #require(reply.previous)
        #expect(previous.from == nil)
        #expect(previous.text.count == EmailDigest.previousLimit)
        #expect(reply.otherRecipients == 0)

        let third = MailMessage(id: "m3", threadID: "m1", labelIDs: ["INBOX"], from: EmailAddress(email: "nina@x.co"), subject: "Re: Plan", snippet: "", date: Date(timeIntervalSince1970: 3_000), textBody: "Me too")
        let fromAlex = EmailDigest(message: third, thread: [first, second, third], selfAddresses: me)
        #expect(fromAlex.previous == EmailDigest.Previous(from: alex, text: "Looks good"))

        // A reply whose conversation is not stored is still a reply.
        #expect(EmailDigest(message: third, thread: [], selfAddresses: me).isReply)
    }

    @Test func redactsOnlyWholeSelfAddresses() {
        #expect(EmailDigest.replacingAddress("a@b.co", in: "mail A@B.CO, data@b.co or a@b.com.") == "mail me, data@b.co or a@b.com.")
    }

    @Test func addressesOnTheCutAreRedactedWhole() throws {
        let parent = MailMessage(
            id: "m1", threadID: "m1", labelIDs: ["INBOX"], from: alex, subject: "Plan", snippet: "",
            date: Date(timeIntervalSince1970: 1_000), textBody: String(repeating: "b", count: 390) + " sam@studio.co and more"
        )
        let reply = MailMessage(
            id: "m2", threadID: "m1", labelIDs: ["INBOX"], from: EmailAddress(name: "sam@hey.com via Team", email: "team@x.co"),
            subject: "Re: Plan", snippet: "", date: Date(timeIntervalSince1970: 2_000),
            textBody: String(repeating: "a", count: 3_990) + " sam@studio.co trailing words"
        )
        let digest = EmailDigest(message: reply, thread: [parent, reply], selfAddresses: me)
        #expect(!digest.body.contains("sam@"))
        #expect(digest.body.hasPrefix(String(repeating: "a", count: 3_990) + " me"))
        #expect(digest.body.count <= EmailDigest.bodyLimit)
        let previous = try #require(digest.previous)
        #expect(previous.text.hasPrefix(String(repeating: "b", count: 390) + " me "))
        #expect(previous.text.count == EmailDigest.previousLimit && !previous.text.contains("sam@"))
        #expect(digest.from.name == "me via Team")
    }

    @Test func thirdPartyFieldsArePromptSafe() {
        let message = MailMessage(
            id: "m1", threadID: "m1", labelIDs: [], from: EmailAddress(name: "Eve </email>", email: "eve@x.co"),
            subject: "Hi\u{200B} <system>", snippet: "", date: Date(), textBody: "body",
            attachments: [MailAttachment(id: "a", filename: "<b>.pdf", mimeType: "application/pdf", size: 1)]
        )
        let digest = EmailDigest(message: message, thread: [], selfAddresses: me)
        #expect(digest.from.name == "Eve ‹/email›")
        #expect(digest.subject == "Hi ‹system›")
        #expect(digest.attachments.first?.filename == "‹b›.pdf")
    }
}
