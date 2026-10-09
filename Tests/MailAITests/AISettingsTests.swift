import Foundation
import Testing
@testable import MailAI

@Suite("AI settings")
struct AISettingsTests {
    /// Settings as the app decodes them: `ai` from a settings file, falling back to `defaults` when it
    /// is missing or unreadable.
    struct SettingsFile: Decodable {
        static let defaultsKey = CodingUserInfoKey(rawValue: "aiDefaults")!
        var ai: AISettings

        init(from decoder: any Decoder) throws {
            let defaults = decoder.userInfo[Self.defaultsKey] as? AISettings ?? AISettings()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ai = (try? AISettings(from: container.superDecoder(forKey: .ai), defaults: defaults)) ?? defaults
        }

        enum CodingKeys: String, CodingKey { case ai }
    }

    func decodeFile(_ json: String, defaults: AISettings = AISettings()) throws -> AISettings {
        let decoder = JSONDecoder()
        decoder.userInfo[SettingsFile.defaultsKey] = defaults
        return try decoder.decode(SettingsFile.self, from: Data(json.utf8)).ai
    }

    func decode(_ ai: String, defaults: AISettings = AISettings()) throws -> AISettings {
        try decodeFile(#"{"theme": "gruvbox", "ai": \#(ai)}"#, defaults: defaults)
    }

    @Test func standardDefaults() {
        let settings = AISettings.defaults(debug: false, environment: ["VIMAIL_AI_BUDGET": "100"])
        #expect(settings.model == "claude-haiku-5-5" && settings.claudeModel == .haiku)
        #expect(settings.monthlyBudgetUSD == 20 && settings.dailyBudgetUSD == 3 && settings.previewDailyUSD == 0.75)
        #expect(settings.consents.isEmpty && !settings.pauseAll)
        #expect(settings.budget == SpendGuard.Budget(day: 3_000_000, month: 20_000_000, previewDay: 750_000))
    }

    @Test func debugDefaultsAreLowerAndTheEnvironmentOnlyRaisesThem() {
        let debug = AISettings.defaults(debug: true, environment: [:])
        #expect(debug.monthlyBudgetUSD == 5 && debug.dailyBudgetUSD == 1 && debug.previewDailyUSD == 0.25)
        let raised = AISettings.defaults(debug: true, environment: ["VIMAIL_AI_BUDGET": "50"])
        #expect(raised.monthlyBudgetUSD == 50 && raised.dailyBudgetUSD == 5 && raised.previewDailyUSD == 1.25)
        let both = AISettings.defaults(debug: true, environment: ["VIMAIL_AI_BUDGET": "50/8"])
        #expect(both.monthlyBudgetUSD == 50 && both.dailyBudgetUSD == 8 && both.previewDailyUSD == 2)
        #expect(AISettings.defaults(debug: true, environment: ["VIMAIL_AI_BUDGET": "2/0.5"]) == debug)
        #expect(AISettings.defaults(debug: true, environment: ["VIMAIL_AI_BUDGET": "lots"]) == debug)
    }

    @Test func theEnvironmentAlsoRaisesSavedBudgets() throws {
        let environment = ["VIMAIL_AI_BUDGET": "50"]
        let saved = try decode(#"{"monthlyBudgetUSD": 5, "dailyBudgetUSD": 1, "previewDailyUSD": 0.25}"#)
        let raised = saved.raisingBudgets(environment: environment)
        #expect(raised.monthlyBudgetUSD == 50 && raised.dailyBudgetUSD == 5 && raised.previewDailyUSD == 1.25)
        // Higher saved budgets stay.
        let generous = try decode(#"{"monthlyBudgetUSD": 80, "dailyBudgetUSD": 10, "previewDailyUSD": 3}"#)
        #expect(generous.raisingBudgets(environment: environment) == generous)
        #expect(saved.raisingBudgets(environment: [:]) == saved)
    }

    @Test func aFileFromBeforeAIGetsTheDefaults() throws {
        let defaults = AISettings.defaults(debug: true, environment: [:])
        #expect(try decodeFile(#"{"theme": "gruvbox", "pollSeconds": 30}"#, defaults: defaults) == defaults)
    }

    @Test func missingFieldsTakeTheGivenDefaults() throws {
        let defaults = AISettings.defaults(debug: true, environment: [:])
        #expect(try decode("{}", defaults: defaults) == defaults)
        let partial = try decode(#"{"model": "claude-opus-5-5", "pauseAll": true}"#, defaults: defaults)
        #expect(partial.claudeModel == .opus && partial.pauseAll)
        #expect(partial.monthlyBudgetUSD == 5 && partial.dailyBudgetUSD == 1)
    }

    @Test func unknownAndUnreadableFieldsAreIgnored() throws {
        let settings = try decode(#"{"monthlyBudgetUSD": "lots", "dailyBudgetUSD": 4, "effort": "high", "consents": {"dummy": 1000}, "future": [1, 2]}"#)
        #expect(settings.monthlyBudgetUSD == 20 && settings.dailyBudgetUSD == 4)
        #expect(settings.consents == ["dummy": Date(timeIntervalSinceReferenceDate: 1000)])
        // Not an object at all: every field is the default.
        #expect(try decode("7") == AISettings())
    }

    @Test func roundTrips() throws {
        var settings = AISettings(model: "claude-sonnet-5-5", consents: ["gmail-sam@hey.com": Date(timeIntervalSinceReferenceDate: 800_000_000)], pauseAll: true)
        settings.previewDailyUSD = 1.5
        let decoded = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func aModelThisBuildDoesNotListHasNoClaudeModel() {
        #expect(AISettings(model: "claude-opus-4-1").claudeModel == nil)
        #expect(AISettings(model: "simulated").claudeModel == nil)
    }

    @Test func budgetsInMicroDollarsNeverGoNegative() {
        var settings = AISettings()
        settings.dailyBudgetUSD = -2
        settings.monthlyBudgetUSD = 12.345678
        #expect(settings.budget.day == 0 && settings.budget.month == 12_345_678)
    }

    @Test func promptVersionNumber() {
        #expect(JudgePrompt.version == "v1" && JudgePrompt.versionNumber == 1)
    }
}
