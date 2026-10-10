import Foundation
import HTTPKit
@testable import MailAI
import MailCore

/// A scripted Anthropic API. Records every request; `route` answers them.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Call {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data

        var path: String { url.path }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    enum Answer {
        case http(Int, headers: [String: String] = [:], body: String)
        case failure(URLError.Code)

        static func ok(_ body: String, headers: [String: String] = [:]) -> Answer { .http(200, headers: headers, body: body) }

        /// An Anthropic error body.
        static func error(_ status: Int, type: String, message: String, headers: [String: String] = [:], details: String? = nil) -> Answer {
            let extra = details.map { #","details":{"error_code":"\#($0)"}"# } ?? ""
            return .http(status, headers: headers, body: #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"\#(extra)}}"#)
        }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let route: @Sendable (Call, Int) -> Answer

    /// - Parameter route: answers a call, given how many came before it.
    init(route: @escaping @Sendable (Call, Int) -> Answer) {
        self.route = route
    }

    /// Answers in order; the last answer repeats.
    convenience init(_ answers: [Answer]) {
        self.init { _, index in answers[min(index, answers.count - 1)] }
    }

    var calls: [Call] { lock.withLock { recorded } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
        let call = Call(method: request.httpMethod ?? "GET", url: request.url!, headers: headers, body: request.httpBody ?? Data())
        let index = lock.withLock {
            recorded.append(call)
            return recorded.count - 1
        }
        switch route(call, index) {
        case .failure(let code):
            throw URLError(code)
        case .http(let status, let responseHeaders, let body):
            return (Data(body.utf8), HTTPURLResponse(url: call.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: responseHeaders)!)
        }
    }
}

/// Time that moves only when a test says so.
final class TestClock: AIClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = []

    init(_ start: Date = Date(timeIntervalSince1970: 1_791_500_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    /// Deadlines of the tasks sleeping now.
    var deadlines: [Date] { lock.withLock { sleepers.map(\.deadline) } }

    func sleep(until deadline: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let due = lock.withLock {
                if deadline <= current { return true }
                sleepers.append((deadline, continuation))
                return false
            }
            if due { continuation.resume() }
        }
    }

    func advance(by seconds: TimeInterval) {
        let due = lock.withLock {
            current = current.addingTimeInterval(seconds)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits until `count` tasks are sleeping.
    func waitForSleepers(_ count: Int = 1) async {
        while deadlines.count < count { await Task.yield() }
    }
}

/// Counts something across tasks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() {
        lock.withLock { value += 1 }
    }
}

// MARK: - Sample data

enum Sample {
    static let me: Set<String> = ["sam@studio.co"]
    /// 2026-10-08 14:02 UTC.
    static let date = Date(timeIntervalSince1970: 1_791_468_120)

    static let catalog = [
        JudgeRule(key: "r3", labelName: "Needs reply", ask: "A real person is waiting for an answer from me."),
        JudgeRule(key: "r1", labelName: "receipts", ask: "Order confirmations, receipts and invoices for things I bought or\nsubscribe to. Not store marketing, not shipping updates."),
    ]

    static var receipt: MailMessage {
        MailMessage(
            id: "m-receipt", threadID: "m-receipt", labelIDs: [SystemLabel.inbox, SystemLabel.categoryUpdates],
            from: EmailAddress(name: "Figma via Stripe", email: "receipts@stripe.com"), to: [EmailAddress(email: "sam@studio.co")],
            subject: "Your receipt from Figma #4821-3390", snippet: "", date: date,
            htmlBody: "<p>Receipt from Figma</p><p>Professional plan: $15.00, paid Oct 8.</p><p>Questions? Visit https://stripe.com/help</p>",
            attachments: [MailAttachment(id: "a1", filename: "receipt-4821.pdf", mimeType: "application/pdf", size: 40_000)]
        )
    }

    static var newsletter: MailMessage {
        MailMessage(
            id: "m-news", threadID: "m-news", labelIDs: [SystemLabel.inbox, SystemLabel.categoryPromotions],
            from: EmailAddress(name: "The Browser", email: "hello@thebrowser.com"), to: [EmailAddress(email: "sam@studio.co"), EmailAddress(email: "list@thebrowser.com")],
            subject: "Five things worth your time", snippet: "", date: date.addingTimeInterval(600),
            textBody: "A few good reads for a slower morning.\n\nThe quiet power of slow software.", listUnsubscribe: "<https://example.com/unsubscribe>"
        )
    }

    static var examples: [JudgeExample] {
        let stripe = MailMessage(
            id: "e1", threadID: "e1", labelIDs: [], from: EmailAddress(name: "Apple", email: "no_reply@email.apple.com"),
            subject: "Your receipt from Apple", snippet: "", date: date, textBody: "SECRET BODY TEXT never sent"
        )
        let allbirds = MailMessage(
            id: "e2", threadID: "e2", labelIDs: [], from: EmailAddress(name: "Allbirds", email: "hello@allbirds.com"),
            subject: "20% off ends tonight", snippet: "", date: date, textBody: "ANOTHER SECRET BODY"
        )
        return [
            JudgeExample(ruleKey: "r1", verdict: .match, digest: JudgeExample.digest(of: stripe, selfAddresses: me)),
            JudgeExample(ruleKey: "r1", verdict: .noMatch, digest: JudgeExample.digest(of: allbirds, selfAddresses: me)),
        ]
    }

    static func request(_ message: MailMessage = receipt, lane: SpendLane = .live, evaluate: [String] = ["r1", "r3"], thread: [MailMessage] = []) -> JudgeRequest {
        JudgeRequest(lane: lane, catalog: catalog, evaluate: evaluate, examples: examples, email: EmailDigest(message: message, thread: thread, selfAddresses: me))
    }

    /// A Messages API response whose text is `verdicts`.
    static func response(
        _ verdicts: [(String, String, String)], model: String = ClaudeModel.haiku.id, stopReason: String = "end_turn",
        thinking: Bool = false, usage: String = #"{"input_tokens":900,"output_tokens":120,"cache_creation_input_tokens":0,"cache_read_input_tokens":1200}"#
    ) -> String {
        let items = verdicts.map { rule, verdict, reason in ["rule": rule, "reason": reason, "verdict": verdict] }
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["verdicts": items], options: [.sortedKeys]), as: UTF8.self)
        let textBlock = String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "text", "text": text], options: [.sortedKeys]), as: UTF8.self)
        let blocks = (thinking ? [#"{"type":"thinking","thinking":"","signature":"c2ln"}"#] : []) + [textBlock]
        return #"{"id":"msg_1","type":"message","role":"assistant","model":"\#(model)","content":[\#(blocks.joined(separator: ","))],"stop_reason":"\#(stopReason)","stop_details":null,"usage":\#(usage)}"#
    }

    static let bothMatch = response([("r1", "match", "Stripe receipt for a Figma subscription"), ("r3", "no_match", "automated receipt, nobody waiting")])
}

/// A judge on `transport` with the given model, a roomy budget and consent.
func makeJudge(
    _ transport: FakeTransport, model: ClaudeModel = .haiku, spend: SpendGuard? = nil, limiter: AILimiter? = nil,
    key: String? = "sk-ant-test", consent: Bool = true
) -> ClaudeJudge {
    let client = AnthropicClient(transport: transport) { key }
    return ClaudeJudge(
        client: client, model: model, limiter: limiter ?? AILimiter(),
        spend: spend ?? SpendGuard(file: nil, budget: SpendGuard.Budget(day: 10_000_000, month: 50_000_000, previewDay: 5_000_000)),
        timeZone: .gmt, consent: { consent }
    )
}

/// Reads a file in `Fixtures`.
func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    guard let url else { throw CocoaError(.fileNoSuchFile) }
    return try Data(contentsOf: url)
}

/// Compares `actual` with a golden fixture. On a mismatch the actual bytes are written next to the
/// temporary directory so the fixture can be reviewed and replaced.
func matchesFixture(_ actual: Data, _ name: String) -> Bool {
    let expected = try? fixture(name)
    guard expected != actual else { return true }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("actual-" + name)
    try? actual.write(to: url)
    print("Fixture \(name) differs. Actual output: \(url.path)")
    return false
}

/// JSON with every object's keys in the order they were written: `JSONSerialization` loses it, and
/// output schemas depend on it.
indirect enum OrderedJSON {
    case object(keys: [String], values: [String: OrderedJSON])
    case array([OrderedJSON])
    /// A string, number, boolean or null, as `JSONSerialization` reads it.
    case scalar(Any)

    struct Malformed: Error {}

    init(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        self = try parser.value()
    }

    subscript(key: String) -> OrderedJSON? {
        if case .object(_, let values) = self { values[key] } else { nil }
    }

    var keys: [String] {
        if case .object(let keys, _) = self { keys } else { [] }
    }

    var strings: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap { if case .scalar(let value as String) = $0 { value } else { nil } }
    }

    private struct Parser {
        static let space = Array(" \n\r\t".utf8)
        let bytes: [UInt8]
        var index = 0

        mutating func value() throws -> OrderedJSON {
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var keys: [String] = []
                var values: [String: OrderedJSON] = [:]
                while try !closes("}") {
                    guard case .scalar(let key as String) = try value() else { throw Malformed() }
                    try expect(":")
                    keys.append(key)
                    values[key] = try value()
                }
                return .object(keys: keys, values: values)
            case UInt8(ascii: "["):
                index += 1
                var items: [OrderedJSON] = []
                while try !closes("]") { items.append(try value()) }
                return .array(items)
            default:
                // Find where the scalar ends, then let Foundation read it.
                let start = index
                if bytes[index] == UInt8(ascii: "\"") {
                    index += 1
                    while index < bytes.count, bytes[index] != UInt8(ascii: "\"") { index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1 }
                    index += 1
                } else {
                    while index < bytes.count, !(Self.space + Array(",]}".utf8)).contains(bytes[index]) { index += 1 }
                }
                guard index <= bytes.count else { throw Malformed() }
                return .scalar(try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed))
            }
        }

        /// Steps over the closing bracket (true) or the "," before the next member (false).
        mutating func closes(_ bracket: Unicode.Scalar) throws -> Bool {
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            if bytes[index] == UInt8(ascii: bracket) {
                index += 1
                return true
            }
            if bytes[index] == UInt8(ascii: ",") { index += 1 }
            return false
        }

        mutating func expect(_ character: Unicode.Scalar) throws {
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { throw Malformed() }
            index += 1
        }

        mutating func skipSpace() {
            while index < bytes.count, Self.space.contains(bytes[index]) { index += 1 }
        }
    }
}
