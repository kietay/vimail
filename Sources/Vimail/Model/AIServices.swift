import Foundation
import HTTPKit
import MailAI
import MailCore
import MailRules
import Observation
import VimailLog

/// Claude for the whole app: the API key, the client, the rate limiter and the spend guard. Limits
/// and budgets belong to the key, not to an account, so this outlives account switches: `AppModel`
/// owns it and each account's rules engine gets its judge from it.
@MainActor
@Observable
final class AIServices {
    /// What the last check of the key said (`GET /v1/models/{id}`, which costs nothing).
    enum KeyState: Equatable {
        case unknown
        case verifying
        case valid(at: Date)
        /// Anthropic rejected it, or it is blank.
        case badKey
        /// The key works, but not with the selected model.
        case modelUnavailable
        /// Anthropic could not be reached to check it.
        case offline
    }

    static let log = Log("claude")
    /// The offline simulator's model id, offered in debug builds.
    static let simulatorModel = SimulatedJudge.model

    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored let client: AnthropicClient
    @ObservationIgnored let limiter = AILimiter()
    @ObservationIgnored let spend: SpendGuard
    /// The model, consents and budgets in use. `AppModel` passes changed settings to `update`.
    private(set) var settings: AISettings
    private(set) var keyState = KeyState.unknown
    /// A key is saved, or in debug builds set in the environment.
    private(set) var hasKey: Bool
    /// Debug builds: the key comes from `ANTHROPIC_API_KEY` or `VIMAIL_ANTHROPIC_KEY_FILE`, ahead of the saved one.
    let keyFromEnvironment: Bool
    /// Debug builds with `VIMAIL_AI_FAKE=1`: the offline simulator judges, whatever the model.
    let fake: Bool

    init(settings: AISettings) {
        let secrets = FileSecretStore(url: AppPaths.anthropicKey)
        #if DEBUG
        let override = EnvironmentSecret.read(variable: "ANTHROPIC_API_KEY", fileVariable: "VIMAIL_ANTHROPIC_KEY_FILE")
        fake = ProcessInfo.processInfo.environment["VIMAIL_AI_FAKE"] == "1"
        #else
        let override: String? = nil
        fake = false
        #endif
        self.secrets = secrets
        self.settings = settings
        keyFromEnvironment = override != nil
        hasKey = override != nil || secrets.read() != nil
        client = AnthropicClient(apiKey: { override ?? secrets.read() })
        spend = SpendGuard(file: AppPaths.aiUsage, budget: settings.budget)
        Self.log.info("Claude: model \(settings.model), key \(hasKey ? (keyFromEnvironment ? "from the environment" : "saved") : "none")\(fake ? ", offline simulator" : "")")
    }

    /// New settings: budgets go to the spend guard at once. Another model needs its key checked again.
    func update(_ settings: AISettings) {
        let old = self.settings
        self.settings = settings
        if settings.budget != old.budget {
            let spend = spend
            let budget = settings.budget
            Task { await spend.setBudget(budget) }
        }
        if settings.model != old.model { keyState = .unknown }
    }

    // MARK: - Judging

    /// The offline simulator judges instead of Claude: free, and nothing leaves the Mac.
    var usesSimulator: Bool {
        #if DEBUG
        fake || settings.model == Self.simulatorModel
        #else
        false
        #endif
    }

    /// The judge for an account's rules, or nil when the selected model is not in this build's catalog.
    func judge(forAccount account: String) -> (any RuleJudge)? {
        if usesSimulator { return SimulatedJudge() }
        return claudeJudge(forAccount: account)
    }

    private func claudeJudge(forAccount account: String) -> ClaudeJudge? {
        guard let model = settings.claudeModel else { return nil }
        return ClaudeJudge(client: client, model: model, limiter: limiter, spend: spend) { [weak self] in
            await self?.hasConsent(account) ?? false
        }
    }

    /// Drafts rules from a sentence with the account's judge, under its consent and budget. nil while
    /// Claude can't be used for the account (`aiPause`), and while the offline simulator judges, which
    /// sends nothing: your sentence is the ASK as written.
    func drafter(forAccount account: String) -> RuleDrafter? {
        guard !usesSimulator, aiPause(forAccount: account) == nil else { return nil }
        return claudeJudge(forAccount: account).map(RuleDrafter.init)
    }

    /// Why Claude can't judge this account's mail now, or nil when it can. Filter rules run anyway.
    func aiPause(forAccount account: String) -> PauseReason? {
        if usesSimulator { return nil }
        guard settings.claudeModel != nil else { return .modelUnavailable }
        guard hasKey else { return .noKey }
        guard hasConsent(account) else { return .noConsent }
        return nil
    }

    func hasConsent(_ account: String) -> Bool {
        settings.consents[account] != nil
    }

    /// What verdicts are cached under and estimates priced with.
    var judgeConfig: RuleEngine.JudgeConfig {
        if usesSimulator { return .simulated }
        let prices = settings.claudeModel.map(Self.tokenPrices) ?? TokenPrices(input: 0, cacheRead: 0, output: 0)
        return RuleEngine.JudgeConfig(model: settings.model, effort: JudgePrompt.effort, promptVersion: JudgePrompt.versionNumber, prices: prices)
    }

    static func tokenPrices(_ model: ClaudeModel) -> TokenPrices {
        TokenPrices(input: model.prices.input, cacheRead: model.prices.cacheRead, output: model.prices.output)
    }

    /// Spend and budgets for the rules status and run estimates.
    var spendFigures: @Sendable () async -> SpendFigures? {
        let spend = spend
        return {
            let snapshot = await spend.snapshot()
            return SpendFigures(
                spendToday: snapshot.spendToday, spendMonth: snapshot.spendMonth, budgetDay: snapshot.budgetDay, budgetMonth: snapshot.budgetMonth,
                runRoomToday: snapshot.runRoomToday, previewLeft: snapshot.previewLeft
            )
        }
    }

    /// What `model` would cost a month if it judged all the mail you receive (`messagesPerDay`).
    static func monthlyEstimate(_ model: ClaudeModel, messagesPerDay: Double) -> Int64 {
        RuleEngine.projectedLiveMicros(messagesPerDay: messagesPerDay, days: 30, prices: tokenPrices(model))
    }

    /// Live mail's daily reserve, until there is real live spend: the volume priced with the selected model.
    func setVolume(messagesPerDay: Double) {
        let daily = settings.claudeModel.map { RuleEngine.projectedLiveMicros(messagesPerDay: messagesPerDay, prices: Self.tokenPrices($0)) }
        let spend = spend
        Task { await spend.setLiveProjection(daily) }
    }

    // MARK: - The key

    /// Checks the key in use against the selected model.
    func verifyKey() async {
        keyState = .verifying
        let check = await client.verifyKey(nil, model: settings.claudeModel ?? .default)
        keyState = Self.keyState(check)
        Self.log.info("Key check: \(String(describing: check))")
    }

    /// Checks a new key, then saves it if Anthropic accepts it (also when the selected model is not
    /// available to it). Returns what the check said. `keyState` stays about the key in use until
    /// the new one is saved.
    func replaceKey(_ key: String) async throws -> AnthropicClient.KeyCheck {
        let check = await client.verifyKey(key, model: settings.claudeModel ?? .default)
        Self.log.info("New key check: \(String(describing: check))")
        guard check == .valid || check == .modelUnavailable else { return check }
        try secrets.save(key)
        hasKey = true
        // A key from the environment stays in use.
        if !keyFromEnvironment { keyState = Self.keyState(check) }
        Self.log.info("Key saved")
        return check
    }

    static func keyState(_ check: AnthropicClient.KeyCheck) -> KeyState {
        switch check {
        case .valid: .valid(at: Date())
        case .badKey: .badKey
        case .modelUnavailable: .modelUnavailable
        case .offline: .offline
        }
    }

    func removeKey() throws {
        try secrets.remove()
        hasKey = keyFromEnvironment
        keyState = .unknown
        Self.log.info("Key removed")
    }
}
