import Foundation
import MailCore

/// Local-only state. None of this is sent to the provider.
extension MailStore {
    // MARK: - Drafts

    public func drafts() async throws -> [Draft] {
        try await read { db in
            try db.query("SELECT payload FROM drafts ORDER BY updated_at DESC") { row in
                try Self.decoder.decode(Draft.self, from: Data(row.string(0).utf8))
            }
        }
    }

    public func draft(id: String) async throws -> Draft? {
        try await read { db in
            try db.first("SELECT payload FROM drafts WHERE id = ?", [id]) { row in
                try Self.decoder.decode(Draft.self, from: Data(row.string(0).utf8))
            }
        }
    }

    /// The most recent draft that replies within a thread, if any.
    public func draft(forThread threadID: String) async throws -> Draft? {
        try await read { db in
            try db.first("SELECT payload FROM drafts WHERE thread_id = ? ORDER BY updated_at DESC LIMIT 1", [threadID]) { row in
                try Self.decoder.decode(Draft.self, from: Data(row.string(0).utf8))
            }
        }
    }

    public func saveDraft(_ draft: Draft) async throws {
        try await write { db, change in
            try Self.saveDraft(draft, db)
            change.drafts = true
            if let threadID = draft.threadID { change.threadIDs.insert(threadID) }
        }
    }

    static func saveDraft(_ draft: Draft, _ db: SQLiteDatabase) throws {
        let payload = String(decoding: try encoder.encode(draft), as: UTF8.self)
        try db.run(
            """
            INSERT INTO drafts(id, payload, thread_id, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, thread_id = excluded.thread_id, updated_at = excluded.updated_at
            """,
            [draft.id, payload, draft.threadID, draft.updatedAt]
        )
    }

    public func deleteDraft(id: String) async throws {
        try await write { db, change in
            try db.run("DELETE FROM drafts WHERE id = ?", [id])
            change.drafts = true
        }
    }

    /// Drafts as list rows for the Drafts mailbox.
    func draftSummaries() async throws -> [ThreadSummary] {
        try await drafts().map { draft in
            let recipients = draft.recipients
            return ThreadSummary(
                id: "draft:\(draft.id)",
                subject: draft.subject.isEmpty ? "(no subject)" : draft.subject,
                snippet: HTMLText.snippet(from: draft.body, length: 140),
                lastDate: draft.updatedAt,
                participants: recipients.isEmpty ? "Draft" : "To: \(recipients.map(\.displayName).joined(separator: ", "))",
                initials: recipients.first?.initials ?? "D",
                messageCount: 1,
                isUnread: false,
                isStarred: false,
                hasAttachments: !draft.attachments.isEmpty,
                labelIDs: [SystemLabel.draft],
                draftID: draft.id
            )
        }
    }

    // MARK: - Snoozes

    public func snoozes() async throws -> [String: Date] {
        try await read { db in
            Dictionary(try db.query("SELECT thread_id, until FROM snoozes") { ($0.string(0), $0.date(1)) }, uniquingKeysWith: { _, last in last })
        }
    }

    static func setSnooze(_ threadID: String, until: Date?, _ db: SQLiteDatabase) throws {
        if let until {
            try db.run("INSERT INTO snoozes(thread_id, until) VALUES (?, ?) ON CONFLICT(thread_id) DO UPDATE SET until = excluded.until", [threadID, until])
        } else {
            try db.run("DELETE FROM snoozes WHERE thread_id = ?", [threadID])
        }
    }

    public func dueSnoozes(now: Date = Date()) async throws -> [String] {
        try await read { db in try db.query("SELECT thread_id FROM snoozes WHERE until <= ? ORDER BY until", [now]) { $0.string(0) } }
    }

    public func nextSnoozeDate() async throws -> Date? {
        try await read { db in try db.first("SELECT MIN(until) FROM snoozes") { $0.optionalDate(0) } ?? nil }
    }

    // MARK: - Saved views

    public func savedViews() async throws -> [SavedView] {
        try await read { db in try Self.savedViews(db) }
    }

    static func savedViews(_ db: SQLiteDatabase) throws -> [SavedView] {
        try db.query("SELECT payload FROM saved_views ORDER BY position, rowid") { row in
            try decoder.decode(SavedView.self, from: Data(row.string(0).utf8))
        }
    }

    public func saveView(_ view: SavedView) async throws {
        try await write { db, change in
            try Self.saveView(view, db)
            change.views = true
        }
    }

    static func saveView(_ view: SavedView, _ db: SQLiteDatabase) throws {
        let payload = String(decoding: try encoder.encode(view), as: UTF8.self)
        try db.run(
            "INSERT INTO saved_views(id, payload, position) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, position = excluded.position",
            [view.id, payload, view.position]
        )
    }

    public func deleteView(id: String) async throws {
        try await write { db, change in
            try db.run("DELETE FROM saved_views WHERE id = ?", [id])
            change.views = true
        }
    }

    /// Seeds the default views once (Unread and Work pinned, Starred unpinned, as in the design).
    public func seedDefaultViewsIfNeeded(workLabelID: String?) async throws {
        try await write { db, change in
            guard try db.first("SELECT value FROM meta WHERE key = 'views_seeded'", [], { $0.string(0) }) == nil else { return }
            let defaults = [
                SavedView(id: "unread", name: "Unread", pinned: true, status: .unread, position: 0),
                SavedView(id: "work", name: "Work", pinned: workLabelID != nil, labelID: workLabelID, position: 1),
                SavedView(id: "starred", name: "Starred", pinned: false, starredOnly: true, position: 2),
            ]
            for view in defaults where workLabelID != nil || view.id != "work" {
                try Self.saveView(view, db)
            }
            try Self.setMeta("views_seeded", "1", db)
            change.views = true
        }
    }

    /// Applies `transform` to each view; non-nil results are saved.
    static func rewriteViews(_ db: SQLiteDatabase, _ transform: (SavedView) -> SavedView?) throws {
        for view in try savedViews(db) {
            if let updated = transform(view) { try saveView(updated, db) }
        }
    }

    // MARK: - Processor results

    public func annotate(messageID: String, key: String, value: String, source: String) async throws {
        try await write { db, change in
            try db.run(
                "INSERT INTO annotations(message_id, key, value, source) VALUES (?, ?, ?, ?) ON CONFLICT(message_id, key) DO UPDATE SET value = excluded.value, source = excluded.source",
                [messageID, key, value, source]
            )
            if let threadID = try Self.threadID(ofMessage: messageID, db) { change.threadIDs.insert(threadID) }
        }
    }

    public func annotations(messageID: String) async throws -> [String: String] {
        try await read { db in
            Dictionary(try db.query("SELECT key, value FROM annotations WHERE message_id = ?", [messageID]) { ($0.string(0), $0.string(1)) }, uniquingKeysWith: { _, last in last })
        }
    }

    /// True when the processor already handled this message at this version (or newer).
    public func isProcessed(messageID: String, processorID: String, version: Int) async throws -> Bool {
        try await read { db in
            try db.scalar("SELECT COUNT(*) FROM processing_log WHERE message_id = ? AND processor_id = ? AND version >= ?", [messageID, processorID, version]) > 0
        }
    }

    public func markProcessed(messageID: String, processorID: String, version: Int, error: String?) async throws {
        try await write { db, _ in
            try db.run(
                """
                INSERT INTO processing_log(message_id, processor_id, version, processed_at, error) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(message_id, processor_id) DO UPDATE SET version = excluded.version, processed_at = excluded.processed_at, error = excluded.error
                """,
                [messageID, processorID, version, Date(), error]
            )
        }
    }

    /// Received messages not yet handled by a processor version, newest first.
    public func unprocessedMessageIDs(processorID: String, version: Int, limit: Int) async throws -> [String] {
        try await read { db in
            try db.query(
                """
                SELECT m.id FROM messages m
                WHERE m.is_local = 0
                  AND NOT EXISTS (SELECT 1 FROM message_labels ml WHERE ml.message_id = m.id AND ml.label_id IN ('SENT', 'DRAFT'))
                  AND NOT EXISTS (SELECT 1 FROM processing_log p WHERE p.message_id = m.id AND p.processor_id = ? AND p.version >= ?)
                ORDER BY m.date DESC LIMIT ?
                """,
                [processorID, version, limit]
            ) { $0.string(0) }
        }
    }
}
