import Foundation
import MailCore

/// A Messages API request body, as rules send it: text blocks only, structured output, low effort.
///
/// There is deliberately no field for `temperature`, `top_p`, `top_k`, `thinking`, `tool_choice`,
/// tools or an assistant turn: the 5.5 models reject most of them, and an assistant prefill is a 400.
struct MessagesRequest: Encodable, Sendable, Hashable {
    var model: String
    var maxTokens: Int
    var system: [TextBlock]
    var messages: [UserMessage]
    var outputConfig: OutputConfig
    /// "default": a refused request is retried server-side on another model. Needs `fallbackBeta`.
    var fallbacks: String?

    static let effort = "low"

    init(model: String, maxTokens: Int, system: [TextBlock], user: [TextBlock], schema: JSONValue, fallbacks: Bool) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        messages = [UserMessage(content: user)]
        outputConfig = OutputConfig(format: OutputFormat(schema: schema))
        self.fallbacks = fallbacks ? "default" : nil
    }

    enum CodingKeys: String, CodingKey {
        case model, system, messages, fallbacks
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }

    struct TextBlock: Encodable, Sendable, Hashable {
        var type = "text"
        var text: String
        var cacheControl: CacheControl?

        init(_ text: String, cacheTTL: PromptCacheTTL? = nil) {
            self.text = text
            cacheControl = cacheTTL.map { CacheControl(ttl: $0.rawValue) }
        }

        enum CodingKeys: String, CodingKey {
            case type, text
            case cacheControl = "cache_control"
        }
    }

    struct CacheControl: Encodable, Sendable, Hashable {
        var type = "ephemeral"
        var ttl: String
    }

    /// The only turn: rules never send an assistant message.
    struct UserMessage: Encodable, Sendable, Hashable {
        var role = "user"
        var content: [TextBlock]
    }

    struct OutputConfig: Encodable, Sendable, Hashable {
        var effort = MessagesRequest.effort
        var format: OutputFormat
    }

    struct OutputFormat: Encodable, Sendable, Hashable {
        var type = "json_schema"
        var schema: JSONValue
    }

    /// Sorted keys and unescaped slashes, so the same request is always the same bytes.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Strings, integers and booleans only: encoding cannot fail.
        return try! encoder.encode(self)
    }

    /// Characters of prompt text, for the token estimate.
    var characterCount: Int {
        (system + messages.flatMap(\.content)).reduce(0) { $0 + $1.text.count }
    }
}

/// A JSON value, for output schemas.
indirect enum JSONValue: Encodable, Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case bool(Bool)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// An object that allows only `properties`, all of them required in the order given.
    static func strictObject(_ properties: KeyValuePairs<String, JSONValue>) -> JSONValue {
        [
            "type": "object",
            "additionalProperties": false,
            "required": .array(properties.map { .string($0.key) }),
            "properties": .object(Dictionary(uniqueKeysWithValues: properties.map { ($0.key, $0.value) })),
        ]
    }

    static func stringEnum(_ values: [String]) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string))]
    }
}

/// A Messages API response. Content blocks are read by type, never by position.
struct MessagesResponse: Decodable, Sendable, Hashable {
    var id: String
    /// The model that produced the reply: a fallback model when one served it.
    var model: String
    var content: [ContentBlock]
    var stopReason: String?
    var stopDetails: StopDetails?
    var usage: Usage

    enum CodingKeys: String, CodingKey {
        case id, model, content, usage
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
    }

    enum ContentBlock: Decodable, Sendable, Hashable {
        case thinking
        case redactedThinking
        case text(String)
        /// The requested model declined and `to` continued (server-side fallback).
        case fallback(from: String?, to: String?)
        /// A block type rules don't read.
        case other(String)

        private enum CodingKeys: String, CodingKey { case type, text, from, to }
        private struct ModelRef: Decodable { var model: String? }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "thinking": self = .thinking
            case "redacted_thinking": self = .redactedThinking
            case "text": self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
            case "fallback":
                self = .fallback(
                    from: try container.decodeIfPresent(ModelRef.self, forKey: .from)?.model,
                    to: try container.decodeIfPresent(ModelRef.self, forKey: .to)?.model
                )
            default: self = .other(type)
            }
        }
    }

    /// Why the model stopped, for refusals: `category` is "cyber", "bio", … or nil.
    struct StopDetails: Decodable, Sendable, Hashable {
        var type: String?
        var category: String?
        var explanation: String?
    }

    struct Usage: Decodable, Sendable, Hashable {
        /// The attempt that produced the reply.
        var counts: TokenCounts
        /// One entry per attempt when a fallback ran ("message", then "fallback_message"). Billing
        /// follows these: the top-level counts cover only the last attempt.
        var iterations: [Iteration]

        private enum CodingKeys: String, CodingKey { case iterations }

        init(counts: TokenCounts, iterations: [Iteration] = []) {
            self.counts = counts
            self.iterations = iterations
        }

        init(from decoder: any Decoder) throws {
            counts = try TokenCounts(from: decoder)
            iterations = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([Iteration].self, forKey: .iterations) ?? []
        }
    }

    struct Iteration: Decodable, Sendable, Hashable {
        var type: String?
        var model: String?
        var counts: TokenCounts

        private enum CodingKeys: String, CodingKey { case type, model }

        init(type: String?, model: String? = nil, counts: TokenCounts) {
            self.type = type
            self.model = model
            self.counts = counts
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            counts = try TokenCounts(from: decoder)
        }
    }

    struct TokenCounts: Decodable, Sendable, Hashable {
        /// Uncached input after the last cache breakpoint.
        var input = 0
        /// Output, thinking included.
        var output = 0
        var cacheWrite = 0
        var cacheRead = 0
        /// Cache writes by TTL, when the API breaks them down.
        var cacheWrite5m: Int?
        var cacheWrite1h: Int?

        private enum CodingKeys: String, CodingKey {
            case input = "input_tokens"
            case output = "output_tokens"
            case cacheWrite = "cache_creation_input_tokens"
            case cacheRead = "cache_read_input_tokens"
            case cacheCreation = "cache_creation"
        }

        private enum CreationKeys: String, CodingKey {
            case fiveMinutes = "ephemeral_5m_input_tokens"
            case oneHour = "ephemeral_1h_input_tokens"
        }

        init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
            self.input = input
            self.output = output
            self.cacheWrite = cacheWrite
            self.cacheRead = cacheRead
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
            output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
            cacheWrite = try container.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
            cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
            if container.contains(.cacheCreation), try !container.decodeNil(forKey: .cacheCreation) {
                let creation = try container.nestedContainer(keyedBy: CreationKeys.self, forKey: .cacheCreation)
                cacheWrite5m = try creation.decodeIfPresent(Int.self, forKey: .fiveMinutes)
                cacheWrite1h = try creation.decodeIfPresent(Int.self, forKey: .oneHour)
            }
        }

        /// Every input token, cached or not.
        var allInput: Int { input + cacheWrite + cacheRead }

        var tokenUsage: TokenUsage {
            TokenUsage(input: input, cacheWrite: cacheWrite, cacheRead: cacheRead, output: output)
        }

        /// Cost in micro-dollars (a dollar per million tokens is a micro-dollar per token). Writes
        /// the API doesn't break down by TTL are priced at `cacheTTL`.
        func cost(_ prices: ModelPrices, cacheTTL: PromptCacheTTL) -> Double {
            let fiveMinutes = cacheWrite5m ?? 0
            let oneHour = cacheWrite1h ?? 0
            let rest = max(0, cacheWrite - fiveMinutes - oneHour)
            let restPrice = cacheTTL == .oneHour ? prices.cacheWrite1h : prices.cacheWrite5m
            return Double(input) * prices.input + Double(output) * prices.output + Double(cacheRead) * prices.cacheRead
                + Double(fiveMinutes) * prices.cacheWrite5m + Double(oneHour) * prices.cacheWrite1h + Double(rest) * restPrice
        }
    }

    /// What the call billed: every attempt, each at the prices of the model that ran it.
    ///
    /// An attempt names its model when the API says so; otherwise the requested model ran first and
    /// each fallback block names the next. A model outside the catalog (a fallback target) is priced
    /// as the dearest catalog model, so the budget never undercounts.
    func bill(requested: ClaudeModel, cacheTTL: PromptCacheTTL) -> (usage: TokenUsage, micros: Int64) {
        guard !usage.iterations.isEmpty else {
            let model = ClaudeModel(rawValue: model) ?? requested
            return (usage.counts.tokenUsage, Int64(usage.counts.cost(model.prices, cacheTTL: cacheTTL).rounded()))
        }
        let chain = [requested.id] + content.compactMap { if case .fallback(_, let to) = $0 { to } else { nil } }
        var total = TokenUsage()
        var micros = 0.0
        for (index, iteration) in usage.iterations.enumerated() {
            let id = iteration.model ?? (index < chain.count ? chain[index] : model)
            micros += iteration.counts.cost(Self.prices(of: id), cacheTTL: cacheTTL)
            total.input += iteration.counts.input
            total.cacheWrite += iteration.counts.cacheWrite
            total.cacheRead += iteration.counts.cacheRead
            total.output += iteration.counts.output
        }
        return (total, Int64(micros.rounded()))
    }

    static func prices(of modelID: String?) -> ModelPrices {
        if let modelID, let model = ClaudeModel(rawValue: modelID) { return model.prices }
        return ClaudeModel.allCases.map(\.prices).max { $0.output < $1.output }!
    }
}

/// An error response: `{"type": "error", "error": {"type": …, "message": …}}`.
struct ErrorResponse: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        struct Extra: Decodable, Sendable {
            var errorCode: String?

            enum CodingKeys: String, CodingKey { case errorCode = "error_code" }
        }

        var type: String?
        var message: String?
        var details: Extra?
    }

    var error: Detail
}
