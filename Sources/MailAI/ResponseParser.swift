import Foundation
import MailCore

/// Reads Claude's answer (design §4.3): the stop reason first, then the blocks by type, then the JSON.
enum ResponseParser {
    /// Why an answer has no usable verdicts.
    enum Failure: Error, Sendable, Hashable {
        /// Claude declined to answer (`stop_reason: "refusal"`), with the policy category when given.
        case refused(category: String?)
        /// Cut off at `max_tokens`: a retry with more room can finish it.
        case maxTokens
        /// The prompt filled the context window.
        case contextWindow
        /// No text at all.
        case empty
        /// Text that is not the schema's JSON.
        case unreadable

        var judgeError: JudgeError {
            switch self {
            case .refused(let category): .refused(category: category)
            case .maxTokens, .contextWindow, .empty: .truncated
            case .unreadable: .invalid(code: "bad_output")
            }
        }
    }

    struct Verdicts: Sendable, Hashable {
        var decisions: [String: JudgeResponse.Decision]
        /// Requested keys with no verdict, in request order.
        var missing: [String]
        var servedBy: String
    }

    static let reasonLimit = 160

    /// The decisions for `requested`: each key once, extras and unrequested keys dropped.
    static func verdicts(in response: MessagesResponse, requested: [String]) throws(Failure) -> Verdicts {
        let text = try text(of: response)
        guard let output = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else { throw .unreadable }
        let wanted = Set(requested)
        var decisions: [String: JudgeResponse.Decision] = [:]
        for item in output.verdicts {
            guard let key = item.rule, wanted.contains(key), decisions[key] == nil,
                  let verdict = item.verdict.flatMap(Verdict.init(rawValue:)), verdict != .declined else { continue }
            decisions[key] = JudgeResponse.Decision(verdict: verdict, reason: plainText(item.reason ?? "", limit: reasonLimit))
        }
        return Verdicts(decisions: decisions, missing: requested.filter { decisions[$0] == nil }, servedBy: servedBy(response))
    }

    /// The answer's text, after checking why Claude stopped. Thinking blocks are skipped; after a
    /// fallback only the text that follows it counts.
    static func text(of response: MessagesResponse) throws(Failure) -> String {
        switch response.stopReason {
        case "refusal": throw .refused(category: response.stopDetails?.category)
        case "max_tokens": throw .maxTokens
        case "model_context_window_exceeded": throw .contextWindow
        default: break
        }
        let lastFallback = response.content.lastIndex { if case .fallback = $0 { true } else { false } }
        let blocks = lastFallback.map { response.content[($0 + 1)...] } ?? response.content[...]
        let text = blocks.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
        guard text.contains(where: { !$0.isWhitespace }) else { throw .empty }
        return text
    }

    /// The model that answered: the last fallback's target, else the one the response names.
    static func servedBy(_ response: MessagesResponse) -> String {
        for block in response.content.reversed() {
            if case .fallback(_, let to?) = block { return to }
        }
        return response.model
    }

    /// One line of plain text: links and email addresses removed, delimiters neutralized, at most `limit` characters.
    static func plainText(_ text: String, limit: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).filter { !isLinkOrAddress($0) }
        return capped(HTMLText.promptLine(words.joined(separator: " ")), to: limit)
    }

    /// "https://…", "www.…", "mailto:…", "stripe.com/receipts", "a@b.co".
    static func isLinkOrAddress(_ word: Substring) -> Bool {
        let lower = word.lowercased()
        let core = lower.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>‹›\"'`.,;:!?"))
        if lower.contains("://") || core.hasPrefix("www.") || core.hasPrefix("mailto:") { return true }
        if let at = core.firstIndex(of: "@"), at != core.startIndex, core[core.index(after: at)...].contains(".") { return true }
        if let slash = core.firstIndex(of: "/") {
            let host = core[..<slash].split(separator: ".")
            if host.count >= 2, let top = host.last, top.count >= 2, top.allSatisfy(\.isLetter) { return true }
        }
        return false
    }

    static func capped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The schema's JSON, read leniently: entries that don't fit are skipped.
    private struct Output: Decodable {
        struct Item: Decodable {
            var rule: String?
            var reason: String?
            var verdict: String?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                rule = try? container.decodeIfPresent(String.self, forKey: .rule)
                reason = try? container.decodeIfPresent(String.self, forKey: .reason)
                verdict = try? container.decodeIfPresent(String.self, forKey: .verdict)
            }

            enum CodingKeys: String, CodingKey { case rule, reason, verdict }
        }

        var verdicts: [Item]
    }
}
