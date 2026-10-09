import Foundation

/// Claude settings for rules, kept with the app's settings. One key and one budget pay for every
/// account; consent is given per account.
///
/// Decodes leniently, like the rest of the settings: a missing or unreadable field takes its default
/// and unknown fields are ignored, so a file from an older or newer build still loads.
public struct AISettings: Codable, Equatable, Sendable {
    /// A `ClaudeModel` raw value, or the offline simulator's id in debug builds.
    public var model: String
    /// Account key → when you allowed that account's mail to go to Claude.
    public var consents: [String: Date]
    public var monthlyBudgetUSD: Double
    public var dailyBudgetUSD: Double
    /// What previews and drafting may spend a day.
    public var previewDailyUSD: Double
    /// Rules stop on every account until you resume them.
    public var pauseAll: Bool

    public init(model: String = ClaudeModel.default.rawValue, consents: [String: Date] = [:], budget: SpendGuard.Budget = .standard, pauseAll: Bool = false) {
        self.model = model
        self.consents = consents
        monthlyBudgetUSD = Self.dollars(budget.month)
        dailyBudgetUSD = Self.dollars(budget.day)
        previewDailyUSD = Self.dollars(budget.previewDay)
        self.pauseAll = pauseAll
    }

    /// Haiku 5.5 with $20 a month, $3 a day and $0.75 a day for previews. Debug builds read real mail
    /// with real spend, so they start at $5 a month and $1 a day (previews a quarter of that), which
    /// `VIMAIL_AI_BUDGET` may raise.
    public static func defaults(debug: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> AISettings {
        debug ? AISettings(budget: .debug).raisingBudgets(environment: environment) : AISettings()
    }

    /// Debug builds: the budgets `VIMAIL_AI_BUDGET` asks for, where they are higher, also over saved
    /// ones. "50" is $50 a month and a tenth of it a day, "50/8" is $8 a day; previews get a quarter
    /// of the day.
    public func raisingBudgets(environment: [String: String] = ProcessInfo.processInfo.environment) -> AISettings {
        let parts = (environment["VIMAIL_AI_BUDGET"] ?? "").split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let month = parts.first ?? nil, month.isFinite, month > 0 else { return self }
        var raised = self
        raised.monthlyBudgetUSD = max(monthlyBudgetUSD, month)
        if let day = parts.count > 1 ? parts[1] : month / 10, day.isFinite { raised.dailyBudgetUSD = max(dailyBudgetUSD, day) }
        raised.previewDailyUSD = max(previewDailyUSD, raised.dailyBudgetUSD / 4)
        return raised
    }

    /// The budgets for `SpendGuard`, in micro-dollars. Negative amounts count as zero.
    public var budget: SpendGuard.Budget {
        SpendGuard.Budget(day: Self.micros(dailyBudgetUSD), month: Self.micros(monthlyBudgetUSD), previewDay: Self.micros(previewDailyUSD))
    }

    /// The selected model, or nil for the offline simulator or a model this build no longer lists.
    public var claudeModel: ClaudeModel? { ClaudeModel(rawValue: model) }

    static func micros(_ dollars: Double) -> Int64 {
        dollars.isFinite ? Int64((max(0, dollars) * 1_000_000).rounded()) : 0
    }

    static func dollars(_ micros: Int64) -> Double {
        Double(micros) / 1_000_000
    }

    // MARK: - Coding

    enum CodingKeys: String, CodingKey {
        case model, consents, monthlyBudgetUSD, dailyBudgetUSD, previewDailyUSD, pauseAll
    }

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, defaults: AISettings())
    }

    /// Decodes what is there and takes the rest from `defaults` (the build's defaults).
    public init(from decoder: any Decoder, defaults: AISettings) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? container.decode(String.self, forKey: .model)) ?? defaults.model
        consents = (try? container.decode([String: Date].self, forKey: .consents)) ?? defaults.consents
        monthlyBudgetUSD = (try? container.decode(Double.self, forKey: .monthlyBudgetUSD)) ?? defaults.monthlyBudgetUSD
        dailyBudgetUSD = (try? container.decode(Double.self, forKey: .dailyBudgetUSD)) ?? defaults.dailyBudgetUSD
        previewDailyUSD = (try? container.decode(Double.self, forKey: .previewDailyUSD)) ?? defaults.previewDailyUSD
        pauseAll = (try? container.decode(Bool.self, forKey: .pauseAll)) ?? defaults.pauseAll
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(consents, forKey: .consents)
        try container.encode(monthlyBudgetUSD, forKey: .monthlyBudgetUSD)
        try container.encode(dailyBudgetUSD, forKey: .dailyBudgetUSD)
        try container.encode(previewDailyUSD, forKey: .previewDailyUSD)
        try container.encode(pauseAll, forKey: .pauseAll)
    }
}
