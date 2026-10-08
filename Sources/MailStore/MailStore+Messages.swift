import Foundation
import MailCore

extension MailStore {
    // MARK: - Labels

    /// Replaces provider labels (system and user). Local labels are kept.
    /// Messages lose labels that no longer exist on the provider.
    public func replaceProviderLabels(_ labels: [MailLabel]) async throws {
        try await write { db, change in
            let existing = try db.query("SELECT id, color_index FROM labels WHERE kind != 'local'") { ($0.string(0), $0.isNull(1) ? nil : $0.int(1)) }
            let colors = Dictionary(existing, uniquingKeysWith: { first, _ in first })
            let incoming = Set(labels.map(\.id))
            for (id, _) in existing where !incoming.contains(id) {
                change.threadIDs.formUnion(try Self.removeLabelEverywhere(id, db))
                try db.run("DELETE FROM labels WHERE id = ?", [id])
            }
            for label in labels {
                let color = label.colorIndex ?? (colors[label.id] ?? nil)
                try Self.upsertLabel(MailLabel(id: label.id, name: label.name, kind: label.kind, colorIndex: color), db)
            }
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            change.labels = true
        }
    }

    static func upsertLabel(_ label: MailLabel, _ db: SQLiteDatabase) throws {
        try db.run(
            """
            INSERT INTO labels(id, name, kind, color_index) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, kind = excluded.kind, color_index = excluded.color_index
            """,
            [label.id, label.name, label.kind.rawValue, label.colorIndex]
        )
    }

    public func upsertLabel(_ label: MailLabel) async throws {
        try await write { db, change in
            try Self.upsertLabel(label, db)
            change.labels = true
        }
    }

    /// Removes a label from every message. Returns the affected thread IDs.
    static func removeLabelEverywhere(_ labelID: String, _ db: SQLiteDatabase) throws -> Set<String> {
        let threads = try db.query(
            "SELECT DISTINCT m.thread_id FROM message_labels ml JOIN messages m ON m.id = ml.message_id WHERE ml.label_id = ?",
            [labelID]
        ) { $0.string(0) }
        try db.run("DELETE FROM message_labels WHERE label_id = ?", [labelID])
        return Set(threads)
    }

    public func deleteLabel(id: String) async throws {
        try await write { db, change in
            change.threadIDs = try Self.removeLabelEverywhere(id, db)
            try db.run("DELETE FROM labels WHERE id = ?", [id])
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            // Saved views that filter on the label now match nothing; clear the filter instead.
            try Self.rewriteViews(db) { view in
                guard view.labelID == id else { return nil }
                var copy = view
                copy.labelID = nil
                return copy
            }
            change.labels = true
            change.views = true
        }
    }

    /// Replaces a temporary local label ID with the provider's ID everywhere, including queued operations.
    public func remapLabel(from localID: String, to label: MailLabel) async throws {
        try await write { db, change in
            let color = try db.first("SELECT color_index FROM labels WHERE id = ?", [localID]) { $0.isNull(0) ? nil : $0.int(0) } ?? nil
            try Self.upsertLabel(MailLabel(id: label.id, name: label.name, kind: label.kind, colorIndex: label.colorIndex ?? color), db)
            try db.run("UPDATE OR IGNORE message_labels SET label_id = ? WHERE label_id = ?", [label.id, localID])
            try db.run("DELETE FROM message_labels WHERE label_id = ?", [localID])
            let threads = try db.query("SELECT DISTINCT thread_id FROM thread_labels WHERE label_id = ?", [localID]) { $0.string(0) }
            try db.run("DELETE FROM labels WHERE id = ?", [localID])
            try Self.replaceInOutbox(localID, with: label.id, db)
            try Self.rewriteViews(db) { view in
                guard view.labelID == localID else { return nil }
                var copy = view
                copy.labelID = label.id
                return copy
            }
            change.threadIDs = Set(threads)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            change.labels = true
            change.views = true
        }
    }

    /// Rewrites queued operations that reference a temporary ID.
    static func replaceInOutbox(_ oldID: String, with newID: String, _ db: SQLiteDatabase) throws {
        let quotedOld = "\"\(oldID)\""
        let quotedNew = "\"\(newID)\""
        try db.run("UPDATE outbox SET payload = replace(payload, ?, ?) WHERE instr(payload, ?) > 0", [quotedOld, quotedNew, quotedOld])
    }

    // MARK: - Messages from the provider

    /// Inserts or updates messages (content and provider labels). Local labels on existing messages
    /// are kept. Returns the IDs of messages that were not stored before.
    @discardableResult
    public func upsertMessages(_ messages: [MailMessage]) async throws -> [String] {
        guard !messages.isEmpty else { return [] }
        return try await write { db, change in
            let localLabels = try Self.localLabelIDs(db)
            let me = self.selfAddresses
            var inserted: [String] = []
            for message in messages {
                if try Self.upsertMessage(message, localLabels: localLabels, me: me, db) { inserted.append(message.id) }
                change.threadIDs.insert(message.threadID)
            }
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: me)
            return inserted
        }
    }

    /// Applies a provider change set, then re-applies queued local label changes on top so
    /// optimistic state is not reverted by older provider state. Returns new message IDs.
    public func applyRemoteChanges(_ changes: ChangeSet) async throws -> [String] {
        try await write { db, change in
            let localLabels = try Self.localLabelIDs(db)
            let me = self.selfAddresses
            var inserted: [String] = []
            var touched = Set<String>()

            for message in changes.upserted {
                if try Self.upsertMessage(message, localLabels: localLabels, me: me, db) { inserted.append(message.id) }
                change.threadIDs.insert(message.threadID)
                touched.insert(message.id)
            }
            for (messageID, labels) in changes.labelUpdates {
                guard let threadID = try Self.threadID(ofMessage: messageID, db) else { continue }
                try Self.setProviderLabels(messageID, labels, localLabels: localLabels, db)
                change.threadIDs.insert(threadID)
                touched.insert(messageID)
            }
            for messageID in changes.deleted {
                if let threadID = try Self.deleteMessage(messageID, db) { change.threadIDs.insert(threadID) }
            }

            change.threadIDs.formUnion(try Self.rebasePendingOperations(onto: touched, db))
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: me)
            return inserted
        }
    }

    static func localLabelIDs(_ db: SQLiteDatabase) throws -> Set<String> {
        Set(try db.query("SELECT id FROM labels WHERE kind = 'local'") { $0.string(0) })
    }

    static func threadID(ofMessage id: String, _ db: SQLiteDatabase) throws -> String? {
        try db.first("SELECT thread_id FROM messages WHERE id = ?", [id]) { $0.string(0) }
    }

    /// Returns true when the message is new.
    static func upsertMessage(_ message: MailMessage, localLabels: Set<String>, me: Set<String>, recordsContacts: Bool = true, _ db: SQLiteDatabase) throws -> Bool {
        let existed = try db.first("SELECT 1 FROM messages WHERE id = ?", [message.id]) { _ in true } ?? false
        try db.run(
            """
            INSERT INTO messages(id, thread_id, date, from_name, from_email, to_json, cc_json, bcc_json, reply_to_json,
                subject, snippet, text_body, html_body, attachments_json, message_id_header, in_reply_to,
                references_json, list_unsubscribe, size, is_local)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET
                thread_id = excluded.thread_id, date = excluded.date, from_name = excluded.from_name,
                from_email = excluded.from_email, to_json = excluded.to_json, cc_json = excluded.cc_json,
                bcc_json = excluded.bcc_json, reply_to_json = excluded.reply_to_json, subject = excluded.subject,
                snippet = excluded.snippet, text_body = excluded.text_body, html_body = excluded.html_body,
                attachments_json = excluded.attachments_json, message_id_header = excluded.message_id_header,
                in_reply_to = excluded.in_reply_to, references_json = excluded.references_json,
                list_unsubscribe = excluded.list_unsubscribe, size = excluded.size, is_local = 0
            """,
            [
                message.id, message.threadID, message.date, message.from.name, message.from.email,
                try json(message.to), try json(message.cc), try json(message.bcc), try json(message.replyTo),
                message.subject, message.snippet, message.textBody, message.htmlBody, try json(message.attachments),
                message.messageIDHeader, message.inReplyTo, try json(message.references), message.listUnsubscribe,
                message.sizeEstimate,
            ]
        )
        try setProviderLabels(message.id, message.labelIDs, localLabels: localLabels, db)
        try index(message, db)
        if !existed && recordsContacts { try recordContacts(message, me: me, db) }
        return !existed
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Sets the provider labels of a message, keeping its local-only labels.
    static func setProviderLabels(_ messageID: String, _ labels: Set<String>, localLabels: Set<String>, _ db: SQLiteDatabase) throws {
        let current = Set(try db.query("SELECT label_id FROM message_labels WHERE message_id = ?", [messageID]) { $0.string(0) })
        let target = labels.union(current.intersection(localLabels))
        for label in current.subtracting(target) {
            try db.run("DELETE FROM message_labels WHERE message_id = ? AND label_id = ?", [messageID, label])
        }
        for label in target.subtracting(current) {
            try db.run("INSERT OR IGNORE INTO message_labels(message_id, label_id) VALUES (?, ?)", [messageID, label])
        }
    }

    /// Re-applies label changes from queued (not yet acknowledged) operations to the given messages.
    /// Returns affected thread IDs.
    static func rebasePendingOperations(onto messageIDs: Set<String>, _ db: SQLiteDatabase) throws -> Set<String> {
        guard !messageIDs.isEmpty else { return [] }
        var threads = Set<String>()
        for item in try outboxItems(db) {
            switch item.operation {
            case .modifyLabels(let delta):
                let affected = delta.messageIDs.filter(messageIDs.contains)
                guard !affected.isEmpty else { continue }
                threads.formUnion(try applyDelta(LabelDelta(messageIDs: affected, add: delta.add, remove: delta.remove), db))
            case .deleteMessages(let ids):
                for id in ids where messageIDs.contains(id) {
                    if let threadID = try deleteMessage(id, db) { threads.insert(threadID) }
                }
            default:
                continue
            }
        }
        return threads
    }

    // MARK: - Local label changes

    /// Applies a label delta locally. Returns the affected thread IDs.
    @discardableResult
    static func applyDelta(_ delta: LabelDelta, _ db: SQLiteDatabase) throws -> Set<String> {
        var threads = Set<String>()
        for messageID in delta.messageIDs {
            guard let threadID = try threadID(ofMessage: messageID, db) else { continue }
            threads.insert(threadID)
            for label in delta.remove {
                try db.run("DELETE FROM message_labels WHERE message_id = ? AND label_id = ?", [messageID, label])
            }
            for label in delta.add {
                try db.run("INSERT OR IGNORE INTO message_labels(message_id, label_id) VALUES (?, ?)", [messageID, label])
            }
        }
        return threads
    }

    /// Labels of every message in the given threads.
    static func messageLabels(inThreads threadIDs: [String], _ db: SQLiteDatabase) throws -> [MessageLabelState] {
        var states: [MessageLabelState] = []
        for threadID in threadIDs {
            let rows = try db.query(
                """
                SELECT m.id, m.date, m.from_email, m.is_local,
                       (SELECT group_concat(label_id, ' ') FROM message_labels WHERE message_id = m.id)
                FROM messages m WHERE m.thread_id = ? ORDER BY m.date
                """,
                [threadID]
            ) { row in
                MessageLabelState(
                    messageID: row.string(0), threadID: threadID, date: row.date(1), fromEmail: row.string(2),
                    isLocal: row.bool(3), labels: Set(row.string(4).split(separator: " ").map(String.init))
                )
            }
            states += rows
        }
        return states
    }

    public func messageLabels(inThreads threadIDs: [String]) async throws -> [MessageLabelState] {
        try await read { db in try Self.messageLabels(inThreads: threadIDs, db) }
    }

    // MARK: - Deletion and local messages

    /// Deletes a message and its index entries. Returns its thread ID.
    @discardableResult
    static func deleteMessage(_ id: String, _ db: SQLiteDatabase) throws -> String? {
        guard let threadID = try threadID(ofMessage: id, db) else { return nil }
        try db.run("DELETE FROM message_search WHERE rowid = (SELECT rowid FROM messages WHERE id = ?)", [id])
        try db.run("DELETE FROM message_labels WHERE message_id = ?", [id])
        try db.run("DELETE FROM annotations WHERE message_id = ?", [id])
        try db.run("DELETE FROM processing_log WHERE message_id = ?", [id])
        try db.run("DELETE FROM messages WHERE id = ?", [id])
        return threadID
    }

    /// Stores an optimistic copy of a message being sent (shown in Sent and in its thread).
    static func insertLocalMessage(_ message: MailMessage, _ db: SQLiteDatabase) throws {
        let localLabels = try localLabelIDs(db)
        _ = try upsertMessage(message, localLabels: localLabels, me: [], recordsContacts: false, db)
        try db.run("UPDATE messages SET is_local = 1 WHERE id = ?", [message.id])
    }

    /// Replaces the optimistic copy with the provider's message after a successful send.
    public func replaceLocalMessage(localID: String, with message: MailMessage) async throws {
        try await write { db, change in
            if let oldThread = try Self.deleteMessage(localID, db) { change.threadIDs.insert(oldThread) }
            _ = try Self.upsertMessage(message, localLabels: try Self.localLabelIDs(db), me: self.selfAddresses, db)
            change.threadIDs.insert(message.threadID)
            // Snoozes or drafts that pointed at a temporary thread follow the real one.
            if let oldThread = change.threadIDs.first(where: { $0 != message.threadID }) {
                try db.run("UPDATE OR IGNORE snoozes SET thread_id = ? WHERE thread_id = ?", [message.threadID, oldThread])
            }
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
        }
    }

    public func deleteMessages(_ ids: [String]) async throws {
        try await write { db, change in
            for id in ids {
                if let threadID = try Self.deleteMessage(id, db) { change.threadIDs.insert(threadID) }
            }
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
        }
    }

    // MARK: - Search index and contacts

    static func index(_ message: MailMessage, _ db: SQLiteDatabase) throws {
        try db.run("DELETE FROM message_search WHERE rowid = (SELECT rowid FROM messages WHERE id = ?)", [message.id])
        let recipients = (message.to + message.cc + message.bcc).map { "\($0.name ?? "") \($0.email)" }.joined(separator: " ")
        let body = String(message.plainText.prefix(20_000))
        try db.run(
            """
            INSERT INTO message_search(rowid, message_id, thread_id, subject, sender, recipients, body, attachments)
            VALUES ((SELECT rowid FROM messages WHERE id = ?), ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                message.id, message.id, message.threadID, message.subject,
                "\(message.from.name ?? "") \(message.from.email)", recipients, body,
                message.fileAttachments.map(\.filename).joined(separator: " "),
            ]
        )
    }

    static func recordContacts(_ message: MailMessage, me: Set<String>, _ db: SQLiteDatabase) throws {
        let sql = """
            INSERT INTO contacts(email, name, score, last_seen) VALUES (?, ?, ?, ?)
            ON CONFLICT(email) DO UPDATE SET
                name = COALESCE(excluded.name, contacts.name),
                score = contacts.score + excluded.score,
                last_seen = MAX(contacts.last_seen, excluded.last_seen)
            """
        if me.contains(message.from.normalized) || message.labelIDs.contains(SystemLabel.sent) {
            // People you write to rank higher than people who write to you.
            for address in message.to + message.cc where !me.contains(address.normalized) {
                try db.run(sql, [address.normalized, address.name, 3.0, message.date])
            }
        } else if message.listUnsubscribe == nil {
            try db.run(sql, [message.from.normalized, message.from.name, 1.0, message.date])
        }
    }
}

/// The labels of one message, used to compute actions and their undo.
public struct MessageLabelState: Hashable, Sendable {
    public var messageID: String
    public var threadID: String
    public var date: Date
    public var fromEmail: String
    public var isLocal: Bool
    public var labels: Set<String>
}
