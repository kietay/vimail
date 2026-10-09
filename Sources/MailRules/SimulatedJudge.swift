import Foundation
import MailCore

/// A judge that never leaves the Mac, for demos (`VIMAIL_AI_FAKE=1`, the "Offline simulator"
/// model) and tests. It is deterministic and free.
///
/// A rule matches when its ASK and the email's subject or body share a significant word: five
/// letters or more, not a common word, compared after dropping plural and -ing/-ed endings.
/// Sentences of the ASK that start with "Not" describe near-misses and are left out. Everything
/// else is `no_match`.
public struct SimulatedJudge: RuleJudge {
    public static let model = "simulated"

    public init() {}

    public func judge(_ request: JudgeRequest) async throws(JudgeError) -> JudgeResponse {
        let words = Set(Self.words(in: request.email.subject + "\n" + request.email.body).map(Self.stem))
        var decisions: [String: JudgeResponse.Decision] = [:]
        for key in request.evaluate {
            guard let rule = request.catalog.first(where: { $0.key == key }) else { continue }
            if let shared = Self.significantStems(of: rule.ask).first(where: words.contains) {
                decisions[key] = JudgeResponse.Decision(verdict: .match, reason: "simulated: mentions \(shared)")
            } else {
                decisions[key] = JudgeResponse.Decision(verdict: .noMatch, reason: "simulated: no word of the rule")
            }
        }
        return JudgeResponse(decisions: decisions, model: Self.model, servedBy: Self.model, costMicros: 0, usage: TokenUsage())
    }

    /// The ASK's significant words, stemmed, in order.
    static func significantStems(of ask: String) -> [String] {
        let sentences = ask.split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.lowercased().hasPrefix("not ") }
        var seen = Set<String>()
        return sentences.flatMap { words(in: $0) }
            .filter { $0.count >= 5 && !stopWords.contains($0) }
            .map(stem)
            .filter { seen.insert($0).inserted }
    }

    static func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// "receipts" → "receipt", "invoices" → "invoice", "shipping" → "shipp", "deliveries" → "delivery".
    static func stem(_ word: String) -> String {
        var word = word
        if word.hasSuffix("ies"), word.count > 4 {
            word = String(word.dropLast(3)) + "y"
        } else if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 4 {
            word.removeLast()
        }
        for suffix in ["ing", "ed"] where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            word.removeLast(suffix.count)
            break
        }
        return word
    }

    static let stopWords: Set<String> = [
        "about", "above", "after", "again", "against", "almost", "along", "already", "always", "among", "another", "anyone",
        "anything", "around", "because", "before", "being", "below", "between", "could", "doing", "during", "email", "emails",
        "every", "from", "having", "here", "maybe", "message", "messages", "mails", "other", "others", "people", "person",
        "please", "really", "should", "since", "someone", "something", "their", "there", "these", "thing", "things", "those",
        "through", "under", "until", "using", "where", "which", "while", "whose", "within", "without", "would", "anybody",
    ]
}
