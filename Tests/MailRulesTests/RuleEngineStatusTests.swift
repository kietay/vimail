import Foundation
import Testing
import MailCore
@testable import MailRules

@Suite("Rule engine status")
struct RuleEngineStatusTests {
    @Test func startsIdleAndNotConfigured() {
        let status = RuleEngineStatus()
        #expect(status.ai == .notConfigured)
        #expect(status.isIdle)
    }

    @Test func workAndProblemsAreNotIdle() {
        var changes: [(inout RuleEngineStatus) -> Void] = [
            { $0.liveQueued = 1 }, { $0.waitingAI = 2 }, { $0.held = 740 }, { $0.failed = 1 }, { $0.unsureToReview = 3 },
            { $0.userPaused = true }, { $0.tripped = ["r_1"] }, { $0.labelMissing = ["r_2"] }, { $0.ai = .paused(.badKey) },
        ]
        changes.append {
            $0.runs = [RunProgress(id: 41, kind: .backfill, rules: [RunRule(id: "r_1", revision: 3)], done: 84, total: 100, costMicros: 1_060_000, state: .running)]
        }
        for change in changes {
            var status = RuleEngineStatus()
            change(&status)
            #expect(!status.isIdle)
        }
    }

    @Test func coolingDownAloneIsIdle() {
        var status = RuleEngineStatus()
        status.ai = .cooling(until: Date().addingTimeInterval(60))
        #expect(status.isIdle)
    }

    @Test func runRulesUseTheStoredShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode([RunRule(id: "r_8f2a1c3d", revision: 3)]), as: UTF8.self)
        #expect(json == #"[{"id":"r_8f2a1c3d","rev":3}]"#)
        #expect(RunState.awaitingConfirm.rawValue == "awaiting_confirm" && RunPauseReason.ruleChanged.rawValue == "rule_changed")
    }
}
