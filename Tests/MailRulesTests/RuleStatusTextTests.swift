import Foundation
import Testing
@testable import MailCore
@testable import MailRules

@Suite("Rules status text")
struct RuleStatusTextTests {
    func run(_ id: Int64, done: Int, total: Int, cost: Int64 = 0, state: RunState = .running, pause: RunPauseReason? = nil) -> RunProgress {
        RunProgress(id: id, kind: .backfill, rules: [RunRule(id: "r_1", revision: 3)], done: done, total: total, costMicros: cost, state: state, pauseReason: pause)
    }

    func line(_ change: (inout RuleEngineStatus) -> Void, gmailRejected: Int = 0) -> RulesStatusLine? {
        var status = RuleEngineStatus()
        change(&status)
        return status.statusLine(gmailRejected: gmailRejected)
    }

    @Test func idleShowsNothing() {
        #expect(RuleEngineStatus().statusLine() == nil)
        #expect(line { $0.ai = .cooling(until: Date().addingTimeInterval(30)) } == nil)
    }

    @Test func runsShowProgressAndCost() {
        #expect(line { $0.runs = [run(41, done: 84, total: 100, cost: 1_060_000)] } == RulesStatusLine(text: "rules 84/100 · $1.06", tone: .busy))
        // Runs waiting for you do not count as running.
        #expect(line {
            $0.runs = [run(41, done: 84, total: 100, cost: 1_060_000), run(42, done: 10, total: 20, cost: 40_000), run(43, done: 0, total: 9, state: .awaitingConfirm)]
        }?.text == "rules 94/120 · $1.10")
    }

    @Test func arrivedMailShowsWhatIsQueued() {
        #expect(line { $0.liveQueued = 5 } == RulesStatusLine(text: "rules 5 queued", tone: .busy))
        #expect(line { $0.liveQueued = 5; $0.runs = [run(1, done: 1, total: 2)] }?.text == "rules 1/2 · $0.00 · 5 queued")
    }

    @Test func claudePausesSayWhy() {
        let expected: [(PauseReason, String, RulesStatusLine.Tone)] = [
            (.budgetDay, "rules paused · daily budget", .warning), (.budgetMonth, "rules paused · monthly budget", .warning),
            (.badKey, "rules paused · check API key", .error), (.billing, "rules paused · add credit", .error),
            (.modelUnavailable, "rules paused · model unavailable", .error), (.apiIncompatible, "rules paused · API changed", .error),
        ]
        for (reason, text, tone) in expected {
            #expect(line { $0.ai = .paused(reason) } == RulesStatusLine(text: text, tone: tone))
        }
        #expect(line { $0.ai = .paused(.budgetDay); $0.waitingAI = 12 }?.text == "rules paused · daily budget · 12 waiting")
    }

    @Test func aMissingKeyOrConsentOnlyShowsWhileMailWaits() {
        for reason in [PauseReason.noKey, .noConsent] {
            var status = RuleEngineStatus()
            status.ai = .paused(reason)
            #expect(status.isIdle && status.statusLine() == nil)
        }
        #expect(line { $0.ai = .paused(.noKey); $0.waitingAI = 3 } == RulesStatusLine(text: "rules paused · add an API key · 3 waiting", tone: .error))
        #expect(line { $0.ai = .paused(.noConsent); $0.waitingAI = 1 }?.text == "rules paused · allow Claude in Settings · 1 waiting")
    }

    @Test func mailWaitingForClaude() {
        // Claude cools down after a rate limit, or its release is under way.
        #expect(line { $0.waitingAI = 4; $0.ai = .cooling(until: Date().addingTimeInterval(30)) } == RulesStatusLine(text: "rules · 4 waiting for Claude", tone: .normal))
        #expect(line { $0.userPaused = true; $0.waitingAI = 2 }?.text == "rules paused · 2 waiting for Claude")
    }

    @Test func youPausedThem() {
        #expect(line { $0.userPaused = true } == RulesStatusLine(text: "rules paused", tone: .normal))
        // Your pause says it all: Claude's own pause is not repeated.
        #expect(line { $0.userPaused = true; $0.ai = .paused(.budgetDay); $0.liveQueued = 4 }?.text == "rules paused · 4 queued")
    }

    @Test func failuresAndUnsureVerdicts() {
        #expect(line { $0.failed = 2; $0.unsureToReview = 3 } == RulesStatusLine(text: "rules 2 failed · 3 unsure", tone: .warning))
        #expect(line { $0.unsureToReview = 3 } == RulesStatusLine(text: "rules 3 unsure", tone: .normal))
    }

    @Test func notesFollowABareRules() {
        #expect(line { $0.held = 740 } == RulesStatusLine(text: "rules · 740 held", tone: .normal))
        #expect(line { $0.tripped = ["r_1"] } == RulesStatusLine(text: "rules · 1 rule turned off", tone: .warning))
        #expect(line { $0.tripped = ["r_1"]; $0.labelMissing = ["r_1", "r_2"] }?.text == "rules · 2 rules turned off")
        #expect(line({ _ in }, gmailRejected: 1) == RulesStatusLine(text: "rules · 1 Gmail update failed", tone: .warning))
        #expect(line({ _ in }, gmailRejected: 3)?.text == "rules · 3 Gmail updates failed")
    }

    @Test func runsPausedForYouAreNoted() {
        #expect(line { $0.runs = [run(7, done: 50, total: 100, state: .paused, pause: .cap)] }?.text == "rules · 1 run paused")
        #expect(line { $0.runs = [run(7, done: 50, total: 100, state: .paused, pause: .cap), run(8, done: 0, total: 9, state: .paused, pause: .ruleChanged)] }?.text == "rules · 2 runs paused")
        // A budget pause ends by itself; a pause for Claude shows as Claude's.
        #expect(line { $0.runs = [run(7, done: 50, total: 100, state: .paused, pause: .budget)] } == nil)
    }

    @Test func idleIsWhatShowsNothing() {
        var status = RuleEngineStatus()
        status.runs = [run(7, done: 50, total: 100, state: .paused, pause: .budget), run(8, done: 0, total: 9, state: .awaitingConfirm)]
        #expect(status.isIdle && status.statusLine() == nil)
        status.runs.append(run(9, done: 1, total: 2))
        #expect(!status.isIdle)
    }

    @Test func dollars() {
        #expect(Dollars.text(0) == "$0.00" && Dollars.text(3_000) == "< $0.01" && Dollars.text(5_000) == "$0.01" && Dollars.text(1_060_000) == "$1.06")
        #expect(Dollars.monthly(0) == "$0.00/mo" && Dollars.monthly(3_000) == "< $0.01/mo" && Dollars.monthly(230_000) == "≈ $0.23/mo")
        // The status bar reads like Settings and confirmations.
        #expect(line { $0.runs = [run(1, done: 1, total: 2, cost: 3_000)] }?.text == "rules 1/2 · < $0.01")
    }

    @Test func removalToasts() {
        #expect(LabelEditNote().removalToast(labelName: "receipts") == nil)
        #expect(LabelEditNote(stoppedRules: ["Receipts"], taughtRules: ["Receipts"]).removalToast(labelName: "receipts")
            == "receipts removed · rule Receipts won't re-add it and will learn from this")
        #expect(LabelEditNote(stoppedRules: ["Needs reply"]).removalToast(labelName: "Reply") == "Reply removed · rule Needs reply won't re-add it")
        #expect(LabelEditNote(stoppedRules: ["Receipts", "Invoices", "Bills"], taughtRules: ["Invoices"]).removalToast(labelName: "money")
            == "money removed · rules Receipts, Invoices and Bills won't re-add it · Invoices will learn from this")
    }

    @Test func teachingWithoutAChangeToasts() {
        #expect(LabelEditNote().unchangedToast(labelName: "receipts", added: true) == nil)
        #expect(LabelEditNote(taughtRules: ["Receipts"]).unchangedToast(labelName: "receipts", added: true) == "receipts was already there · rule Receipts will learn from this")
        #expect(LabelEditNote(taughtRules: ["Receipts"]).unchangedToast(labelName: "receipts", added: false) == "receipts was already off · rule Receipts will learn from this")
    }
}
