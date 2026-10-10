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
                       instr(m.attachments_json, '"isInline":false') > 0, m.to_json,
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
        var parts: [String] = []
        let words = query.terms + query.containsText.flatMap { $0.split(separator: " ").map(String.init) }
        for word in words where !word.isEmpty { parts.append(ftsQuote(word) + "*") }
        for phrase in query.phrases where !phrase.isEmpty { parts.append(ftsQuote(phrase)) }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    static func likePattern(_ text: String) -> String {
        let escaped = text.lowercased()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    /// SQL for a thread query. `selecting` is either the summary column list or `COUNT(*)`. `me` is the account's own
    /// addresses (lowercased), for `organizer:me`.
    static func threadQuerySQL(_ query: ThreadQuery, selecting: String, paged: Bool, me: Set<String>) -> (String, [SQLBindable]) {
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
        if let invitation = query.invitation {
            let file = "SELECT 1 FROM invitations i WHERE i.thread_id = t.id AND i.payload IS NOT NULL"
            switch invitation {
            case .any: conditions.append("EXISTS (\(file))")
            case .request: conditions.append("EXISTS (\(file) AND i.method = 'REQUEST' AND i.sequence = 0)")
            case .update: conditions.append("EXISTS (\(file) AND i.method = 'REQUEST' AND i.sequence > 0)")
            case .cancel: conditions.append("EXISTS (\(file) AND i.method = 'CANCEL')")
            case .reply: conditions.append("EXISTS (\(file) AND i.method = 'REPLY')")
            case .pending:
                // The waiting list's events (the app works them out by the answer rule), by their invitations' conversations.
                conditions.append("EXISTS (\(file) AND i.method = 'REQUEST' AND i.uid IN (SELECT value FROM json_each(?)))")
                args.append((try? json(query.waitingInvitationUIDs ?? [])) ?? "[]")
            case .conflict:
                // The events the app found overlapping something else you go to (`AgendaItem.overlappingUIDs`), by their
                // invitations' conversations.
                conditions.append("EXISTS (\(file) AND i.method = 'REQUEST' AND i.uid IN (SELECT value FROM json_each(?)))")
                args.append((try? json(query.conflictingInvitationUIDs ?? [])) ?? "[]")
            }
        }
        if query.organizedByMe == true {
            // An invitation file whose event's organizer is one of your addresses.
            let addresses = me.sorted()
            if addresses.isEmpty {
                conditions.append("0")
            } else {
                let placeholders = Array(repeating: "?", count: addresses.count).joined(separator: ", ")
                conditions.append("t.id IN (SELECT i.thread_id FROM invitations i WHERE i.organizer IN (\(placeholders)))")
                args += addresses.map { $0 as SQLBindable }
            }
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
            conditions.append("EXISTS (SELECT 1 FROM thread_labels x JOIN labels l ON l.id = x.label_id WHERE x.thread_id = t.id AND lower(l.name) = ?)")
            args.append(name.lowercased())
        }
        for sender in query.senders {
            conditions.append("EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = t.id AND (lower(m.from_email) LIKE ? ESCAPE '\\' OR lower(m.from_name) LIKE ? ESCAPE '\\'))")
            args.append(likePattern(sender))
            args.append(likePattern(sender))
        }
        for recipient in query.recipients {
            conditions.append("EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = t.id AND (lower(m.to_json) LIKE ? ESCAPE '\\' OR lower(m.cc_json) LIKE ? ESCAPE '\\'))")
            args.append(likePattern(recipient))
            args.append(likePattern(recipient))
        }
        for subject in query.subjects {
            conditions.append("lower(t.subject) LIKE ? ESCAPE '\\'")
            args.append(likePattern(subject))
        }
        if let ids = query.ids {
            if ids.isEmpty {
                conditions.append("0")
            } else {
                conditions.append("t.id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ", ")))")
                args += ids.map { $0 as SQLBindable }
            }
        }
        if let match = ftsExpression(query) {
            conditions.append("t.id IN (SELECT thread_id FROM message_search WHERE message_search MATCH ?)")
            args.append(match)
        }
        let excluded = query.excludedTerms.filter { !$0.isEmpty }
        if !excluded.isEmpty {
            conditions.append("t.id NOT IN (SELECT thread_id FROM message_search WHERE message_search MATCH ?)")
            args.append(excluded.map { ftsQuote($0) + "*" }.joined(separator: " OR "))
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
        let me = selfAddresses
        return try await read { db in try Self.threads(query, db, me: me) }
    }

    static func threads(_ query: ThreadQuery, _ db: SQLiteDatabase, me: Set<String>) throws -> [ThreadSummary] {
        let (sql, args) = threadQuerySQL(query, selecting: summaryColumns, paged: true, me: me)
        return try db.query(sql, args, summary)
    }

    public func count(_ query: ThreadQuery) async throws -> Int {
        if case .mailbox(.drafts) = query.scope { return try await read { db in try db.scalar("SELECT COUNT(*) FROM drafts") } }
        let me = selfAddresses
        return try await read { db in
            let (sql, args) = Self.threadQuerySQL(query, selecting: "COUNT(*)", paged: false, me: me)
            return try db.scalar(sql, args)
        }
    }

    /// Counts for several queries in one read (sidebar and view tabs).
    public func counts(_ queries: [String: ThreadQuery]) async throws -> [String: Int] {
        let me = selfAddresses
        return try await read { db in
            var result: [String: Int] = [:]
            for (key, query) in queries {
                if case .mailbox(.drafts) = query.scope {
                    result[key] = try db.scalar("SELECT COUNT(*) FROM drafts")
                    continue
                }
                let (sql, args) = Self.threadQuerySQL(query, selecting: "COUNT(*)", paged: false, me: me)
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
            listUnsubscribe: row.optionalString(17), oneClickUnsubscribe: row.isNull(19) ? nil : row.bool(19),
            sizeEstimate: row.int(18)
        )
    }

    /// The message's labels come last, at `labelsColumn`.
    static let messageColumns = """
        m.id, m.thread_id, m.date, m.from_name, m.from_email, m.to_json, m.cc_json, m.bcc_json, m.reply_to_json,
        m.subject, m.snippet, m.text_body, m.html_body, m.attachments_json, m.message_id_header, m.in_reply_to,
        m.references_json, m.list_unsubscribe, m.size, m.one_click_unsubscribe,
        (SELECT group_concat(label_id, ' ') FROM message_labels WHERE message_id = m.id)
        """
    static let labelsColumn: Int32 = 20

    public func thread(id: String) async throws -> MailThread? {
        try await read { db in try Self.thread(id: id, db) }
    }

    static func thread(id: String, _ db: SQLiteDatabase) throws -> MailThread? {
        let messages = try db.query("SELECT \(messageColumns) FROM messages m WHERE m.thread_id = ? ORDER BY m.date", [id]) { row in
            try decodeMessage(row, labels: Set(row.string(labelsColumn).split(separator: " ").map(String.init)))
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
                try Self.decodeMessage(row, labels: Set(row.string(Self.labelsColumn).split(separator: " ").map(String.init)))
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
                WHERE email LIKE ? ESCAPE '\\' OR lower(name) LIKE ? ESCAPE '\\' OR lower(name) LIKE ? ESCAPE '\\'
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
