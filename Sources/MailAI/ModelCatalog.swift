import Foundation
import MailCore

/// The Claude models rules can use, with their list prices. The catalog ships with each release;
/// a saved model that is no longer listed pauses Claude rules until another is picked.
public enum ClaudeModel: String, CaseIterable, Codable, Sendable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"

    /// Preselected: about 40× cheaper than Opus. Opus and Sonnet judge subtle rules better.
    public static let `default` = ClaudeModel.haiku

    /// When the prices below were checked.
    public static let pricesAsOf = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: 2026, month: 10, day: 9).date!

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .haiku: "Haiku 5.5"
        case .sonnet: "Sonnet 5.5"
        case .opus: "Opus 5.5"
        }
    }

    /// Dollars per million tokens. Rule prompts stay far below Haiku's 100K-token price step.
    public var prices: ModelPrices {
        switch self {
        case .haiku: ModelPrices(input: 0.10, cacheWrite5m: 0.125, cacheWrite1h: 0.20, cacheRead: 0.01, output: 0.50)
        case .sonnet: ModelPrices(input: 2, cacheWrite5m: 2.50, cacheWrite1h: 4, cacheRead: 0.10, output: 10)
        case .opus: ModelPrices(input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.20, output: 20)
        }
    }

    /// Server-side fallback for refusals (`fallbacks: "default"` plus its beta header). Haiku has none,
    /// so a refusal there stays declined.
    public var supportsFallbacks: Bool { self != .haiku }

    /// Output cap per call. Thinking counts toward it.
    public var maxTokens: Int { self == .haiku ? 2048 : 4096 }

    /// What a call with this usage costs, in millionths of a dollar.
    /// A dollar per million tokens is one micro-dollar per token.
    public func costMicros(_ usage: TokenUsage, cacheTTL: PromptCacheTTL) -> Int64 {
        let prices = prices
        let write = cacheTTL == .oneHour ? prices.cacheWrite1h : prices.cacheWrite5m
        let total = Double(usage.input) * prices.input + Double(usage.cacheWrite) * write
            + Double(usage.cacheRead) * prices.cacheRead + Double(usage.output) * prices.output
        return Int64(total.rounded())
    }
}

/// List prices in dollars per million tokens.
public struct ModelPrices: Sendable, Hashable {
    public var input: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double
    public var output: Double

    public init(input: Double, cacheWrite5m: Double, cacheWrite1h: Double, cacheRead: Double, output: Double) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }
}
