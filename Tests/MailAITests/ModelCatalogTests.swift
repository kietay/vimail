import Foundation
import Testing
@testable import MailAI
import MailCore

/// The catalog against `Fixtures/model-catalog.json`, the price table the design and the UI quote.
@Suite("Model catalog")
struct ModelCatalogTests {
    struct Fixture: Decodable {
        struct Model: Decodable {
            var id: String
            var name: String
            var input, cacheWrite5m, cacheWrite1h, cacheRead, output: Double
            var maxTokens: Int
            var fallbacks: Bool
            var runOf1000: Double
        }

        var pricesAsOf: String
        var `default`: String
        var models: [Model]
    }

    func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "model-catalog", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func matchesThePriceTable() throws {
        let fixture = try fixture()
        #expect(Set(fixture.models.map(\.id)) == Set(ClaudeModel.allCases.map(\.id)))
        #expect(ClaudeModel.default.id == fixture.default)
        for expected in fixture.models {
            let model = try #require(ClaudeModel(rawValue: expected.id))
            #expect(model.displayName == expected.name)
            #expect(model.prices == ModelPrices(input: expected.input, cacheWrite5m: expected.cacheWrite5m, cacheWrite1h: expected.cacheWrite1h, cacheRead: expected.cacheRead, output: expected.output))
            #expect(model.maxTokens == expected.maxTokens)
            #expect(model.supportsFallbacks == expected.fallbacks)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        #expect(formatter.string(from: ClaudeModel.pricesAsOf) == fixture.pricesAsOf)
    }

    @Test func reproducesTheRunCostTable() throws {
        for expected in try fixture().models {
            let model = try #require(ClaudeModel(rawValue: expected.id))
            let first = model.costMicros(TokenUsage(input: 1_500, cacheWrite: 1_200, output: 320), cacheTTL: .fiveMinutes)
            let next = model.costMicros(TokenUsage(input: 1_500, cacheRead: 1_200, output: 320), cacheTTL: .fiveMinutes)
            let total = first + 999 * next
            #expect((Double(total) / 10_000).rounded() / 100 == expected.runOf1000, "\(expected.id)")
        }
    }

    @Test func cacheWritesCostMoreForAnHour() {
        let usage = TokenUsage(cacheWrite: 1_000_000)
        #expect(ClaudeModel.haiku.costMicros(usage, cacheTTL: .fiveMinutes) == 125_000)
        #expect(ClaudeModel.haiku.costMicros(usage, cacheTTL: .oneHour) == 200_000)
        #expect(ClaudeModel.opus.costMicros(TokenUsage(input: 1, output: 1), cacheTTL: .oneHour) == 24)
    }
}
