import Foundation

/// Gmail-style search syntax, parsed for the local full-text index.
///
/// Supported: free words (prefix match), `"exact phrase"`, `-excluded`, `from:`, `to:`, `subject:`,
/// `label:`, `in:inbox|sent|trash|spam|starred|snoozed|drafts|archive|anywhere`,
/// `is:unread|read|starred`, `has:attachment`, `before:YYYY-MM-DD`, `after:YYYY-MM-DD`,
/// `older_than:3d|2w|1m|1y`, `newer_than:...`, and for calendar mail `has:invite` and
/// `invite:request|update|cancel|reply|pending|conflict`.
public struct SearchQuery: Hashable, Sendable {
    /// Which calendar mail to find: any invitation file, or one kind of it.
    public enum InvitationFilter: String, Hashable, Sendable {
        case any, request, update, cancel, reply
        /// Invitations you have not answered yet.
        case pending
        /// Invitations whose time overlaps an event you go to (in the next 60 days).
        case conflict
    }

    public var terms: [String] = []
    public var phrases: [String] = []
    public var excluded: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    public var subject: [String] = []
    public var labelNames: [String] = []
    public var scope: ThreadQuery.Scope?
    public var read: ReadFilter?
    public var starred: Bool?
    public var hasAttachment: Bool?
    public var invitation: InvitationFilter?
    public var before: Date?
    public var after: Date?

    public init() {}

    public var isEmpty: Bool { self == SearchQuery() }

    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> SearchQuery {
        var query = SearchQuery()
        for token in tokenize(input) {
            let (raw, quoted) = token
            if quoted {
                if !raw.isEmpty { query.phrases.append(raw) }
                continue
            }
            if raw.hasPrefix("-"), raw.count > 1, !raw.contains(":") {
                query.excluded.append(String(raw.dropFirst()))
                continue
            }
            guard let colon = raw.firstIndex(of: ":"), colon != raw.startIndex else {
                query.terms.append(raw)
                continue
            }
            let key = raw[..<colon].lowercased()
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !value.isEmpty else { continue }
            switch key {
            case "from": query.from.append(value)
            case "to", "cc": query.to.append(value)
            case "subject": query.subject.append(value)
            case "label": query.labelNames.append(value)
            case "in":
                switch value.lowercased() {
                case "inbox": query.scope = .mailbox(.inbox)
                case "sent": query.scope = .mailbox(.sent)
                case "trash": query.scope = .mailbox(.trash)
                case "spam": query.scope = .mailbox(.spam)
                case "starred": query.scope = .mailbox(.starred)
                case "snoozed": query.scope = .mailbox(.snoozed)
                case "archive", "archived": query.scope = .mailbox(.archive)
                case "all", "allmail", "all-mail": query.scope = .everywhereExceptTrash
                case "anywhere": query.scope = .anywhere
                default: query.labelNames.append(value)
                }
            case "is":
                switch value.lowercased() {
                case "unread": query.read = .unread
                case "read": query.read = .read
                case "starred": query.starred = true
                default: query.terms.append(raw)
                }
            case "has":
                if value.lowercased().hasPrefix("attachment") {
                    query.hasAttachment = true
                } else if value.lowercased().hasPrefix("invit") {
                    query.invitation = .any
                } else {
                    query.terms.append(raw)
                }
            case "invite", "invitation":
                switch value.lowercased() {
                case "request", "new": query.invitation = .request
                case "update", "updated": query.invitation = .update
                case "cancel", "cancelled", "canceled": query.invitation = .cancel
                case "reply", "replies": query.invitation = .reply
                case "pending", "unanswered": query.invitation = .pending
                case "conflict", "conflicts", "overlap", "overlaps": query.invitation = .conflict
                default: query.terms.append(raw)
                }
            case "before": query.before = parseDate(value)
            case "after": query.after = parseDate(value)
            case "older_than": query.before = relativeDate(value, now: now, calendar: calendar)
            case "newer_than": query.after = relativeDate(value, now: now, calendar: calendar)
            default:
                // Not an operator (for example a URL or "re:"): search it as text.
                query.terms.append(raw)
            }
        }
        return query
    }

    /// Splits on whitespace, keeping `"quoted phrases"` and `key:"quoted values"` together.
    static func tokenize(_ input: String) -> [(String, Bool)] {
        var tokens: [(String, Bool)] = []
        var current = ""
        var inQuotes = false
        var currentIsPhrase = false
        for char in input {
            if char == "\"" {
                if inQuotes {
                    inQuotes = false
                    if currentIsPhrase {
                        tokens.append((current, true))
                        current = ""
                        currentIsPhrase = false
                    } else {
                        current.append(char)
                    }
                } else {
                    inQuotes = true
                    if current.isEmpty { currentIsPhrase = true } else { current.append(char) }
                }
                continue
            }
            if char.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append((current, false)) }
                current = ""
                continue
            }
            current.append(char)
        }
        if !current.isEmpty { tokens.append((current, currentIsPhrase)) }
        return tokens
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    static func relativeDate(_ value: String, now: Date, calendar: Calendar) -> Date? {
        guard let unit = value.last, let amount = Int(value.dropLast()) else { return nil }
        let component: Calendar.Component
        switch unit {
        case "d": component = .day
        case "w": return calendar.date(byAdding: .day, value: -7 * amount, to: now)
        case "m": component = .month
        case "y": component = .year
        case "h": component = .hour
        default: return nil
        }
        return calendar.date(byAdding: component, value: -amount, to: now)
    }
}
