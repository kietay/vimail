import Foundation

/// A rule's WHEN: search syntax tested against one message as it arrives.
///
/// Allowed: words, `"phrases"`, `-word`, `from:`, `-from:`, `to:`, `subject:`, `label:`, `-label:`,
/// `has:attachment`, `is:list`, `before:` and `after:`. Operators that change after mail arrives
/// (`in:`, `is:read`, `is:unread`, `is:starred`) or with the clock (`newer_than:`, `older_than:`)
/// are rejected, because a rule decides once per message.
public struct RuleFilter: Hashable, Sendable {
    /// Everything except the label terms. The store tests it in SQL.
    public var query: SearchQuery
    /// `label:` and `-label:` terms. The engine tests them in memory, against labels earlier rules add too.
    public var labelTerms: [LabelTerm]

    public struct LabelTerm: Hashable, Sendable {
        public var name: String
        /// `-label:`: the label must be absent.
        public var negated: Bool

        public init(name: String, negated: Bool = false) {
            self.name = name
            self.negated = negated
        }

        /// IDs of the labels this term names (case-insensitive, like search).
        public func labelIDs(in labels: [MailLabel]) -> Set<String> {
            let wanted = name.lowercased()
            return Set(labels.filter { $0.name.lowercased() == wanted }.map(\.id))
        }
    }

    /// Why a WHEN cannot be used, with the offending term.
    public struct Problem: Error, Hashable, Sendable {
        public var term: String
        public var message: String
    }

    /// Parses and checks a WHEN. "" matches everything in the rule's scope.
    public static func parse(_ when: String) throws(Problem) -> RuleFilter {
        for (raw, quoted) in SearchQuery.tokenize(when) where !quoted {
            if let message = problem(with: raw) { throw Problem(term: raw, message: message) }
        }
        var query = SearchQuery.parse(when)
        let labelTerms = query.labelNames.map { LabelTerm(name: $0) } + query.excludedLabelNames.map { LabelTerm(name: $0, negated: true) }
        query.labelNames = []
        query.excludedLabelNames = []
        return RuleFilter(query: query, labelTerms: labelTerms)
    }

    static func problem(with raw: String) -> String? {
        guard let colon = raw.firstIndex(of: ":"), colon != raw.startIndex else { return nil }
        var key = raw[..<colon].lowercased()
        let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
        let negated = key.hasPrefix("-")
        if negated { key.removeFirst() }
        switch key {
        case "from", "label":
            return value.isEmpty ? "\(key): needs a value" : nil
        case "to", "cc", "subject":
            if negated { return "-\(key): is not supported in rules" }
            return value.isEmpty ? "\(key): needs a value" : nil
        case "in":
            return "in: is not available in rules: a message's mailbox changes after it arrives. Choose mailboxes under SCOPE"
        case "is":
            if negated { return "-is: is not supported in rules" }
            switch value {
            case "list": return nil
            case "read", "unread", "starred":
                return "is:\(value) is not available in rules: it changes after a message arrives"
            default:
                return "is:\(value) is not supported. Rules understand is:list"
            }
        case "has":
            if negated { return "-has: is not supported in rules" }
            return value.hasPrefix("attachment") ? nil : "has:\(value) is not supported. Rules understand has:attachment"
        case "before", "after":
            if negated { return "-\(key): is not supported in rules. Use \(key == "before" ? "after:" : "before:") instead" }
            return SearchQuery.parseDate(value) == nil ? "\(key): needs a date such as 2026-10-01" : nil
        case "newer_than", "older_than":
            return "\(key): is not available in rules: it depends on today's date. Use after: or before: with a date"
        default:
            // Not an operator (for example "re:" or a URL): searched as text, as in search.
            return nil
        }
    }
}
