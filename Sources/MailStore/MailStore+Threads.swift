import Foundation
import MailCore

extension MailStore {
    // MARK: - Thread aggregates

    /// Recomputes the denormalized `threads` and `thread_labels` rows from their messages.
    static func refreshThreads(_ ids: Set<String>, _ db: SQLiteDatabase, selfAddresses me: Set<String>) throws {
        struct Row {
            var date: Date
            var fromName: String?
            var fromEmail: String
            var subject: String
            var snippet: String
            var hasAttachments: Bool
            var toJSON: String
            var labels: Set<String>
        }
        for threadID in ids {
            let rows = try db.query(
                """
                SELECT m.date, m.from_name, m.from_email, m.subject, m.snippet,
                       \(hasFileAttachment), m.to_json,
                       (SELECT group_concat(label_id, ' ') FROM message_labels WHERE message_id = m.id)
                FROM messages m WHERE m.thread_id = ? ORDER BY m.date
                """,
                [threadID]
            ) { row in
                Row(
                    date: row.date(0), fromName: row.optionalString(1), fromEmail: row.string(2), subject: row.string(3),
                    snippet: row.string(4), hasAttachments: row.bool(5), toJSON: row.string(6),
                    labels: Set(row.string(7).split(separator: " ").map(String.init))
                )
            }
            try db.run("DELETE FROM thread_labels WHERE thread_id = ?", [threadID])
            guard let latest = rows.last else {
                try db.run("DELETE FROM threads WHERE id = ?", [threadID])
                continue
            }

            let union = rows.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
            let isMe = { (email: String) in me.contains(email.lowercased()) }
            let hasReceived = rows.contains { !isMe($0.fromEmail) && !$0.labels.contains(SystemLabel.sent) }

            // Gmail-style participant line.
            var seen = Set<String>()
            var senders: [EmailAddress] = []
            for row in rows where seen.insert(row.fromEmail.lowercased()).inserted {
                senders.append(EmailAddress(name: row.fromName, email: row.fromEmail))
            }
            let participants: String
            var initials: String
            if senders.allSatisfy({ isMe($0.email) }) {
                let recipients = (try? decoder.decode([EmailAddress].self, from: Data(latest.toJSON.utf8))) ?? []
                participants = recipients.first.map { "To: \($0.displayName)" } ?? "me"
                initials = recipients.first?.initials ?? "ME"
            } else if senders.count == 1, let only = senders.first {
                participants = only.displayName
                initials = only.initials
            } else {
                let names = senders.map { isMe($0.email) ? "me" : $0.shortName }
                participants = names.count > 3 ? "\(names[0]) … \(names[names.count - 2]), \(names[names.count - 1])" : names.joined(separator: ", ")
                let lastOther = rows.last(where: { !isMe($0.fromEmail) })
                initials = lastOther.map { EmailAddress(name: $0.fromName, email: $0.fromEmail).initials } ?? "ME"
            }
            if initials.isEmpty { initials = "?" }

            let subject = rows.first(where: { !$0.subject.isEmpty })?.subject ?? ""
            let labelString = union.sorted().joined(separator: " ")
            try db.run(
                """
                INSERT INTO threads(id, subject, snippet, last_date, participants, initials, message_count, unread, starred,
                                    has_attachments, has_received, label_ids)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    subject = excluded.subject, snippet = excluded.snippet, last_date = excluded.last_date,
                    participants = excluded.participants, initials = excluded.initials,
                    message_count = excluded.message_count, unread = excluded.unread, starred = excluded.starred,
                    has_attachments = excluded.has_attachments, has_received = excluded.has_received,
                    label_ids = excluded.label_ids
                """,
                [
                    threadID, subject, latest.snippet, latest.date, participants, initials, rows.count,
                    union.contains(SystemLabel.unread), union.contains(SystemLabel.starred),
                    rows.contains(where: \.hasAttachments), hasReceived, labelString,
                ]
            )
            for label in union {
                try db.run("INSERT OR IGNORE INTO thread_labels(label_id, last_date, thread_id) VALUES (?, ?, ?)", [label, latest.date, threadID])
            }
        }
    }

    // MARK: - Thread list queries

    static let summaryColumns = """
        t.id, t.subject, t.snippet, t.last_date, t.participants, t.initials, t.message_count,
        t.unread, t.starred, t.has_attachments, t.label_ids, s.until
        """

    static func summary(_ row: SQLRow) -> ThreadSummary {
        ThreadSummary(
            id: row.string(0), subject: row.string(1), snippet: row.string(2), lastDate: row.date(3),
            participants: row.string(4), initials: row.string(5), messageCount: row.int(6),
            isUnread: row.bool(7), isStarred: row.bool(8), hasAttachments: row.bool(9),
            labelIDs: row.string(10).split(separator: " ").map(String.init), snoozedUntil: row.optionalDate(11)
        )
    }

    static func ftsQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Builds the FTS5 MATCH expression for the positive terms, or nil when there are none.
    static func ftsExpression(_ query: ThreadQuery) -> String? {
        ftsExpression(words: query.terms + query.containsText.flatMap { $0.split(separator: " ").map(String.init) }, phrases: query.phrases)
    }

    /// Prefix-matched words and exact phrases, all required.
    static func ftsExpression(words: [String], phrases: [String]) -> String? {
        var parts: [String] = []
        for word in words where !word.isEmpty { parts.append(ftsQuote(word) + "*") }
        for phrase in phrases where !phrase.isEmpty { parts.append(ftsQuote(phrase)) }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    /// Matches any of the excluded words (`-word`), or nil when there are none.
    static func ftsExcludedExpression(_ words: [String]) -> String? {
        let words = words.filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.map { ftsQuote($0) + "*" }.joined(separator: " OR ")
    }

    /// A `LIKE` pattern for `text` anywhere, lowercased: compare it with `unicode_lower(column)`.
    static func likePattern(_ text: String) -> String {
        let escaped = text.lowercased()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    /// The message `m` is from `sender` (a substring of its address or name).
    static func senderMatches(_ sender: String) -> (String, [SQLBindable]) {
        ("(unicode_lower(m.from_email) LIKE ? ESCAPE '\\' OR ifnull(unicode_lower(m.from_name), '') LIKE ? ESCAPE '\\')", [likePattern(sender), likePattern(sender)])
    }

    /// The message `m` has an attachment listed as a file (not an inline image).
    static let hasFileAttachment = "instr(m.attachments_json, '\"isInline\":false') > 0"

    /// The message `m` came from a mailing list (it has a List-Unsubscribe header).
    static let isListMessage = "(m.list_unsubscribe IS NOT NULL AND m.list_unsubscribe != '')"

    /// SQL for a thread query. `selecting` is either the summary column list or `COUNT(*)`.
    static func threadQuerySQL(_ query: ThreadQuery, selecting: String, paged: Bool) -> (String, [SQLBindable]) {
        var joins: [String] = []
        var conditions: [String] = []
        var args: [SQLBindable] = []
        var order = "t.last_date DESC"
        var snoozeJoin = "LEFT JOIN snoozes s ON s.thread_id = t.id"
        let excludeTrashAndSpam = "NOT EXISTS (SELECT 1 FROM thread_labels x WHERE x.thread_id = t.id AND x.label_id IN ('TRASH', 'SPAM'))"

        switch query.scope {
        case .mailbox(let mailbox):
            switch mailbox {
            case .inbox, .sent, .trash, .spam, .starred, .label:
                joins.append("JOIN thread_labels tl ON tl.thread_id = t.id AND tl.label_id = ?")
                args.append(mailbox.labelID ?? "")
                order = "tl.last_date DESC"
                switch mailbox {
                case .trash, .spam: break
                default: conditions.append(excludeTrashAndSpam)
                }
            case .snoozed:
                snoozeJoin = "JOIN snoozes s ON s.thread_id = t.id"
                order = "s.until ASC"
            case .archive:
                conditions.append("t.has_received = 1")
                conditions.append("NOT EXISTS (SELECT 1 FROM thread_labels x WHERE x.thread_id = t.id AND x.label_id IN ('INBOX', 'TRASH', 'SPAM'))")
                conditions.append("s.thread_id IS NULL")
            case .allMail:
                conditions.append(excludeTrashAndSpam)
            case .drafts:
                conditions.append("0")
            }
        case .everywhereExceptTrash:
            conditions.append(excludeTrashAndSpam)
        case .anywhere:
            break
        }

        switch query.read {
        case .any: break
        case .unread: conditions.append("t.unread = 1")
        case .read: conditions.append("t.unread = 0")
        }
        if query.starredOnly { conditions.append("t.starred = 1") }
        if query.hasAttachment == true { conditions.append("t.has_attachments = 1") }
        if query.isList == true {
            conditions.append("EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = t.id AND \(isListMessage))")
        }
        if let before = query.before {
            conditions.append("t.last_date < ?")
            args.append(before)
        }
        if let after = query.after {
            conditions.append("t.last_date >= ?")
            args.append(after)
        }
        for labelID in query.labelIDs {
            conditions.append("EXISTS (SELECT 1 FROM thread_labels x WHERE x.thread_id = t.id AND x.label_id = ?)")
            args.append(labelID)
        }
        for name in query.labelNames {
            conditions.append("EXISTS (SELECT 1 FROM thread_labels x JOIN labels l ON l.id = x.label_id WHERE x.thread_id = t.id AND unicode_lower(l.name) = ?)")
            args.append(name.lowercased())
        }
        for name in query.excludedLabelNames {
            conditions.append("NOT EXISTS (SELECT 1 FROM thread_labels x JOIN labels l ON l.id = x.label_id WHERE x.thread_id = t.id AND unicode_lower(l.name) = ?)")
            args.append(name.lowercased())
        }
        for sender in query.senders {
            let (match, values) = senderMatches(sender)
            conditions.append("EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = t.id AND \(match))")
            args += values
        }
        // Like `-word`: the conversation goes when any of its messages is from the sender.
        for sender in query.excludedSenders {
            let (match, values) = senderMatches(sender)
            conditions.append("NOT EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = t.id AND \(match))")
            args += values
        }
        for recipient in query.recipients {
            conditions.append("EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = t.id AND (unicode_lower(m.to_json) LIKE ? ESCAPE '\\' OR unicode_lower(m.cc_json) LIKE ? ESCAPE '\\'))")
            args.append(likePattern(recipient))
            args.append(likePattern(recipient))
        }
        for subject in query.subjects {
            conditions.append("unicode_lower(t.subject) LIKE ? ESCAPE '\\'")
            args.append(likePattern(subject))
        }
        if let ids = query.ids {
            // One argument however many IDs, so a long list (every conversation a rule matches) stays
            // under SQLite's parameter limit.
            conditions.append("t.id IN (SELECT value FROM json_each(?))")
            args.append((try? json(ids)) ?? "[]")
        }
        if let match = ftsExpression(query) {
            conditions.append("t.id IN (SELECT thread_id FROM message_search WHERE message_search MATCH ?)")
            args.append(match)
        }
        if let excluded = ftsExcludedExpression(query.excludedTerms) {
            conditions.append("t.id NOT IN (SELECT thread_id FROM message_search WHERE message_search MATCH ?)")
            args.append(excluded)
        }

        var sql = "SELECT \(selecting) FROM threads t \(joins.joined(separator: " ")) \(snoozeJoin)"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if paged {
            sql += " ORDER BY \(order) LIMIT ? OFFSET ?"
            args.append(query.limit)
            args.append(query.offset)
        }
        return (sql, args)
    }

    public func threads(_ query: ThreadQuery) async throws -> [ThreadSummary] {
        if case .mailbox(.drafts) = query.scope { return try await draftSummaries() }
        return try await read { db in try Self.threads(query, db) }
    }

    static func threads(_ query: ThreadQuery, _ db: SQLiteDatabase) throws -> [ThreadSummary] {
        let (sql, args) = threadQuerySQL(query, selecting: summaryColumns, paged: true)
        return try db.query(sql, args, summary)
    }

    public func count(_ query: ThreadQuery) async throws -> Int {
        if case .mailbox(.drafts) = query.scope { return try await read { db in try db.scalar("SELECT COUNT(*) FROM drafts") } }
        return try await read { db in
            let (sql, args) = Self.threadQuerySQL(query, selecting: "COUNT(*)", paged: false)
            return try db.scalar(sql, args)
        }
    }

    /// Counts for several queries in one read (sidebar and view tabs).
    public func counts(_ queries: [String: ThreadQuery]) async throws -> [String: Int] {
        try await read { db in
            var result: [String: Int] = [:]
            for (key, query) in queries {
                if case .mailbox(.drafts) = query.scope {
                    result[key] = try db.scalar("SELECT COUNT(*) FROM drafts")
                    continue
                }
                let (sql, args) = Self.threadQuerySQL(query, selecting: "COUNT(*)", paged: false)
                result[key] = try db.scalar(sql, args)
            }
            return result
        }
    }

    public func threadSummary(id: String) async throws -> ThreadSummary? {
        try await read { db in
            try db.first("SELECT \(Self.summaryColumns) FROM threads t LEFT JOIN snoozes s ON s.thread_id = t.id WHERE t.id = ?", [id], Self.summary)
        }
    }

    // MARK: - Message queries (rules)

    /// Which messages a rules query looks at.
    struct MessageQuery {
        var search: SearchQuery
        /// A rule's scope, or nil for every stored message.
        var mailboxes: RuleScope.Mailboxes?
        /// Only these messages.
        var ids: [String]?
        /// Only messages dated inside it.
        var window: ClosedRange<Date>?
        /// The newest `limit` (ordered queries only).
        var limit: Int?
    }

    /// SQL for messages that pass a search one message at a time, as a rule's WHEN does. `selecting`
    /// is a column list or `COUNT(*)`; `ordered` lists the newest first.
    ///
    /// Unlike conversation search, each operator tests the message itself: `from:` its sender, `to:`
    /// the addresses and names in its To and Cc, `subject:` its own subject, `label:` its own labels,
    /// `before:`/`after:` its date. A negation drops only the matching message, not its conversation.
    /// `in:` and `is:read|unread|starred` are ignored; `newer_than:`/`older_than:` arrive as `after`/
    /// `before`, fixed when parsed. None of them are rule operators: `RuleFilter` rejects them.
    /// - Parameter me: the account's addresses. Mail from them is outside every scope.
    static func messageQuerySQL(_ query: MessageQuery, me: Set<String>, selecting: String, ordered: Bool) throws -> (String, [SQLBindable]) {
        var conditions: [String] = []
        var args: [SQLBindable] = []
        let search = query.search

        if let mailboxes = query.mailboxes {
            let (scope, values) = scopeCondition(mailboxes, me: me)
            conditions.append(scope)
            args += values
        }
        if let ids = query.ids {
            // One argument however many IDs, so long lists stay under SQLite's parameter limit.
            conditions.append("m.id IN (SELECT value FROM json_each(?))")
            args.append(try json(ids))
        }
        if let window = query.window {
            conditions.append("m.date >= ? AND m.date <= ?")
            args += [window.lowerBound, window.upperBound]
        }
        for sender in search.from {
            let (match, values) = senderMatches(sender)
            conditions.append(match)
            args += values
        }
        for sender in search.excludedFrom {
            let (match, values) = senderMatches(sender)
            conditions.append("NOT \(match)")
            args += values
        }
        for recipient in search.to {
            let address = "unicode_lower(json_extract(a.value, '$.email')) LIKE ? ESCAPE '\\' OR ifnull(unicode_lower(json_extract(a.value, '$.name')), '') LIKE ? ESCAPE '\\'"
            conditions.append("(EXISTS (SELECT 1 FROM json_each(m.to_json) a WHERE \(address)) OR EXISTS (SELECT 1 FROM json_each(m.cc_json) a WHERE \(address)))")
            args += Array(repeating: likePattern(recipient), count: 4)
        }
        for subject in search.subject {
            conditions.append("unicode_lower(m.subject) LIKE ? ESCAPE '\\'")
            args.append(likePattern(subject))
        }
        for name in search.labelNames {
            conditions.append("EXISTS (SELECT 1 FROM message_labels x JOIN labels l ON l.id = x.label_id WHERE x.message_id = m.id AND unicode_lower(l.name) = ?)")
            args.append(name.lowercased())
        }
        for name in search.excludedLabelNames {
            conditions.append("NOT EXISTS (SELECT 1 FROM message_labels x JOIN labels l ON l.id = x.label_id WHERE x.message_id = m.id AND unicode_lower(l.name) = ?)")
            args.append(name.lowercased())
        }
        if search.hasAttachment == true { conditions.append(hasFileAttachment) }
        if search.isList == true { conditions.append(isListMessage) }
        if let before = search.before {
            conditions.append("m.date < ?")
            args.append(before)
        }
        if let after = search.after {
            conditions.append("m.date >= ?")
            args.append(after)
        }
        if let match = ftsExpression(words: search.terms, phrases: search.phrases) {
            conditions.append("m.rowid IN (SELECT rowid FROM message_search WHERE message_search MATCH ?)")
            args.append(match)
        }
        if let excluded = ftsExcludedExpression(search.excluded) {
            conditions.append("m.rowid NOT IN (SELECT rowid FROM message_search WHERE message_search MATCH ?)")
            args.append(excluded)
        }

        var sql = "SELECT \(selecting) FROM messages m"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if ordered {
            sql += " ORDER BY m.date DESC"
            if let limit = query.limit {
                sql += " LIMIT ?"
                args.append(limit)
            }
        }
        return (sql, args)
    }

    /// The message `m` is in a rule's scope. Received: not in Sent, Drafts, Spam or Trash, not a copy
    /// still being sent, and not from you. Inbox: received and in the Inbox.
    static func scopeCondition(_ mailboxes: RuleScope.Mailboxes, me: Set<String>) -> (String, [SQLBindable]) {
        var conditions = [
            "m.is_local = 0",
            "NOT EXISTS (SELECT 1 FROM message_labels x WHERE x.message_id = m.id AND x.label_id IN ('SENT', 'DRAFT', 'SPAM', 'TRASH'))",
        ]
        var args: [SQLBindable] = []
        if !me.isEmpty {
            conditions.append("unicode_lower(m.from_email) NOT IN (\(Array(repeating: "?", count: me.count).joined(separator: ", ")))")
            args += me.sorted().map { $0 as SQLBindable }
        }
        switch mailboxes {
        case .received: break
        case .inbox: conditions.append("EXISTS (SELECT 1 FROM message_labels x WHERE x.message_id = m.id AND x.label_id = 'INBOX')")
        // A scope from a newer build: nothing is in it here.
        case .unsupported: conditions.append("0")
        }
        return ("(" + conditions.joined(separator: " AND ") + ")", args)
    }

    // MARK: - Thread detail

    static func decodeMessage(_ row: SQLRow, labels: Set<String>) throws -> MailMessage {
        func addresses(_ index: Int32) throws -> [EmailAddress] {
            try decoder.decode([EmailAddress].self, from: Data(row.string(index).utf8))
        }
        return MailMessage(
            id: row.string(0), threadID: row.string(1), labelIDs: labels,
            from: EmailAddress(name: row.optionalString(3), email: row.string(4)),
            to: try addresses(5), cc: try addresses(6), bcc: try addresses(7), replyTo: try addresses(8),
            subject: row.string(9), snippet: row.string(10), date: row.date(2),
            textBody: row.optionalString(11), htmlBody: row.optionalString(12),
            attachments: try decoder.decode([MailAttachment].self, from: Data(row.string(13).utf8)),
            messageIDHeader: row.optionalString(14), inReplyTo: row.optionalString(15),
            references: try decoder.decode([String].self, from: Data(row.string(16).utf8)),
            listUnsubscribe: row.optionalString(17), sizeEstimate: row.int(18)
        )
    }

    static let messageColumns = """
        m.id, m.thread_id, m.date, m.from_name, m.from_email, m.to_json, m.cc_json, m.bcc_json, m.reply_to_json,
        m.subject, m.snippet, m.text_body, m.html_body, m.attachments_json, m.message_id_header, m.in_reply_to,
        m.references_json, m.list_unsubscribe, m.size,
        (SELECT group_concat(label_id, ' ') FROM message_labels WHERE message_id = m.id)
        """

    public func thread(id: String) async throws -> MailThread? {
        try await read { db in try Self.thread(id: id, db) }
    }

    static func thread(id: String, _ db: SQLiteDatabase) throws -> MailThread? {
        let messages = try db.query("SELECT \(messageColumns) FROM messages m WHERE m.thread_id = ? ORDER BY m.date", [id]) { row in
            try decodeMessage(row, labels: Set(row.string(19).split(separator: " ").map(String.init)))
        }
        guard !messages.isEmpty else { return nil }
        let snoozed = try db.first("SELECT until FROM snoozes WHERE thread_id = ?", [id]) { $0.date(0) }
        var annotations: [String: [String: String]] = [:]
        for message in messages {
            let pairs = try db.query("SELECT key, value FROM annotations WHERE message_id = ?", [message.id]) { ($0.string(0), $0.string(1)) }
            if !pairs.isEmpty { annotations[message.id] = Dictionary(pairs, uniquingKeysWith: { _, last in last }) }
        }
        return MailThread(
            id: id,
            subject: messages.first(where: { !$0.subject.isEmpty })?.subject ?? "",
            messages: messages,
            labelIDs: messages.reduce(into: Set<String>()) { $0.formUnion($1.labelIDs) },
            snoozedUntil: snoozed,
            annotations: annotations
        )
    }

    public func message(id: String) async throws -> MailMessage? {
        try await read { db in
            try db.first("SELECT \(Self.messageColumns) FROM messages m WHERE m.id = ?", [id]) { row in
                try Self.decodeMessage(row, labels: Set(row.string(19).split(separator: " ").map(String.init)))
            }
        }
    }

    // MARK: - Labels, counts and contacts

    public func labels() async throws -> [MailLabel] {
        try await read { db in try Self.labels(db) }
    }

    static func labels(_ db: SQLiteDatabase) throws -> [MailLabel] {
        try db.query("SELECT id, name, kind, color_index FROM labels ORDER BY lower(name)") { row in
            MailLabel(id: row.string(0), name: row.string(1), kind: MailLabel.Kind(rawValue: row.string(2)) ?? .user, colorIndex: row.isNull(3) ? nil : row.int(3))
        }
    }

    /// Unread conversation counts per label.
    public func unreadCounts() async throws -> [String: Int] {
        try await read { db in
            let rows = try db.query(
                "SELECT tl.label_id, COUNT(*) FROM thread_labels tl JOIN threads t ON t.id = tl.thread_id WHERE t.unread = 1 GROUP BY tl.label_id"
            ) { ($0.string(0), $0.int(1)) }
            return Dictionary(rows, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Address suggestions for the compose fields, best first.
    public func contacts(matching text: String, limit: Int = 6) async throws -> [EmailAddress] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return try await read { db in
            let prefix = Self.likePattern(needle).dropFirst()  // "needle%"
            let wordPrefix = "% " + prefix
            return try db.query(
                """
                SELECT email, name FROM contacts
                WHERE email LIKE ? ESCAPE '\\' OR unicode_lower(name) LIKE ? ESCAPE '\\' OR unicode_lower(name) LIKE ? ESCAPE '\\'
                ORDER BY score DESC, last_seen DESC LIMIT ?
                """,
                [String(prefix), String(prefix), String(wordPrefix), limit]
            ) { EmailAddress(name: $0.optionalString(1), email: $0.string(0)) }
        }
    }

    /// Message IDs in the given threads, for actions on conversations.
    public func messageIDs(inThreads threadIDs: [String]) async throws -> [String] {
        try await read { db in
            var ids: [String] = []
            for threadID in threadIDs {
                ids += try db.query("SELECT id FROM messages WHERE thread_id = ? ORDER BY date", [threadID]) { $0.string(0) }
            }
            return ids
        }
    }
}
