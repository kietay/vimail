import Foundation
import Testing
@testable import MailCore
@testable import MailRules
@testable import MailStore

@Suite("Simulated judge", .serialized)
struct SimulatedJudgeTests {
    func ask(_ ask: String, subject: String, body: String = "") async throws -> JudgeResponse.Decision? {
        let message = MailMessage(id: "m1", threadID: "m1", labelIDs: ["INBOX"], from: stripe, to: [me], subject: subject, snippet: "", date: Date(), textBody: body)
        let request = JudgeRequest(
            lane: .live, catalog: [JudgeRule(key: "r1", labelName: "receipts", ask: ask)], evaluate: ["r1"], examples: [],
            email: EmailDigest(message: message, thread: [message], selfAddresses: [me.email])
        )
        let response = try await SimulatedJudge().judge(request)
        #expect(response.costMicros == 0 && response.model == SimulatedJudge.model)
        return response.decisions["r1"]
    }

    @Test func matchesASharedSignificantWord() async throws {
        let receipt = try await ask("Receipts and invoices for things I bought", subject: "Your receipt from Figma #4821")
        #expect(receipt?.verdict == .match && receipt?.reason == "simulated: mentions receipt")
        let invoice = try await ask("Receipts and invoices for things I bought", subject: "Hello", body: "Your invoice is attached.")
        #expect(invoice?.verdict == .match && invoice?.reason == "simulated: mentions invoice")
        // Short and common words do not count; "Not …" sentences name near-misses.
        #expect(try await ask("Things I bought. Not store marketing.", subject: "Marketing things for you")?.verdict == .noMatch)
        #expect(try await ask("Trip bookings", subject: "Your trip")?.verdict == .noMatch)
        #expect(try await ask("Trip bookings", subject: "Booking confirmed")?.verdict == .match)
    }

    @Test func stemming() {
        #expect(SimulatedJudge.stem("receipts") == "receipt")
        #expect(SimulatedJudge.stem("invoices") == "invoice")
        #expect(SimulatedJudge.stem("deliveries") == "delivery")
        #expect(SimulatedJudge.stem("bookings") == "book")
        #expect(SimulatedJudge.stem("address") == "address")
        #expect(SimulatedJudge.significantStems(of: "Order confirmations and receipts. Not shipping updates.") == ["order", "confirmation", "receipt"])
    }

    @Test func labelsTheDummyCorpusEndToEnd() async throws {
        let harness = try await Harness(
            rules: [RuleSpec(name: "Receipts", label: "receipts", ask: "Receipts")], judge: nil, config: .simulated, account: false
        )
        await harness.engine.configure(judge: SimulatedJudge(), aiPause: nil, config: .simulated)
        repeat {
            #expect(await harness.sync.cycle())
        } while try await harness.store.meta("backfill_done") == nil

        let rule = try await harness.rule("Receipts")
        let estimate = try await harness.engine.estimate(RunPlan(ruleID: rule.id, window: .allCached))
        #expect(estimate.needClaude > 0 && estimate.micros == 0)
        let id = try await harness.engine.startRun(RunPlan(ruleID: rule.id, window: .allCached))
        await harness.engine.drain()
        let run = try #require(try await harness.store.run(id: id))
        #expect(run.state == .done && run.judged == estimate.needClaude && run.costMicros == 0)

        // Every receipt in the corpus is labeled, and everything labeled mentions a receipt.
        let receipts = Set(try await harness.store.ruleMatches(RuleFilter.parse("subject:\"Your receipt from\""), scope: .received))
        let labeled = Set(try await harness.store.ruleMatches(RuleFilter.parse("label:receipts"), scope: .received))
        #expect(!receipts.isEmpty)
        #expect(receipts.isSubset(of: labeled))
        for id in labeled {
            let inputs = try #require(try await harness.store.judgeInputs(messageID: id))
            let digest = EmailDigest(message: inputs.message, thread: inputs.thread, selfAddresses: harness.store.selfAddresses)
            #expect((digest.subject + " " + digest.body).lowercased().contains("receipt"))
            #expect(try await harness.decision(id, rule)?.source == .claude)
        }
    }
}
