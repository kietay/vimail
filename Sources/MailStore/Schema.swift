import Foundation

/// Database migrations, applied in order by `PRAGMA user_version`.
enum Schema {
    static let migrations: [String] = [
        // 1: initial schema.
        """
        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE labels (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,           -- system | user | local
            color_index INTEGER
        );

        -- One row per conversation. Denormalized so the list pane reads a single table.
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            subject TEXT NOT NULL DEFAULT '',
            snippet TEXT NOT NULL DEFAULT '',
            last_date INTEGER NOT NULL DEFAULT 0,
            participants TEXT NOT NULL DEFAULT '',
            initials TEXT NOT NULL DEFAULT '',
            message_count INTEGER NOT NULL DEFAULT 0,
            unread INTEGER NOT NULL DEFAULT 0,
            starred INTEGER NOT NULL DEFAULT 0,
            has_attachments INTEGER NOT NULL DEFAULT 0,
            has_received INTEGER NOT NULL DEFAULT 0,
            label_ids TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX threads_last_date ON threads(last_date DESC);

        CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            date INTEGER NOT NULL,
            from_name TEXT,
            from_email TEXT NOT NULL DEFAULT '',
            to_json TEXT NOT NULL DEFAULT '[]',
            cc_json TEXT NOT NULL DEFAULT '[]',
            bcc_json TEXT NOT NULL DEFAULT '[]',
            reply_to_json TEXT NOT NULL DEFAULT '[]',
            subject TEXT NOT NULL DEFAULT '',
            snippet TEXT NOT NULL DEFAULT '',
            text_body TEXT,
            html_body TEXT,
            attachments_json TEXT NOT NULL DEFAULT '[]',
            message_id_header TEXT,
            in_reply_to TEXT,
            references_json TEXT NOT NULL DEFAULT '[]',
            list_unsubscribe TEXT,
            size INTEGER NOT NULL DEFAULT 0,
            is_local INTEGER NOT NULL DEFAULT 0   -- optimistic copy of a message still being sent
        );
        CREATE INDEX messages_thread ON messages(thread_id, date);

        CREATE TABLE message_labels (
            message_id TEXT NOT NULL,
            label_id TEXT NOT NULL,
            PRIMARY KEY (message_id, label_id)
        ) WITHOUT ROWID;
        CREATE INDEX message_labels_label ON message_labels(label_id);

        -- Union of message labels per thread, ordered for index-only mailbox listing.
        CREATE TABLE thread_labels (
            label_id TEXT NOT NULL,
            last_date INTEGER NOT NULL,
            thread_id TEXT NOT NULL,
            PRIMARY KEY (label_id, last_date, thread_id)
        ) WITHOUT ROWID;
        CREATE INDEX thread_labels_thread ON thread_labels(thread_id);

        CREATE VIRTUAL TABLE message_search USING fts5(
            message_id UNINDEXED,
            thread_id UNINDEXED,
            subject,
            sender,
            recipients,
            body,
            attachments,
            tokenize = 'unicode61 remove_diacritics 2',
            prefix = '2 3'
        );

        -- Local changes waiting to be pushed to the provider.
        CREATE TABLE outbox (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            payload TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'pending',   -- pending | inflight
            not_before INTEGER NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at INTEGER NOT NULL
        );

        -- Local-only state.
        CREATE TABLE drafts (
            id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            thread_id TEXT,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE snoozes (
            thread_id TEXT PRIMARY KEY,
            until INTEGER NOT NULL
        );

        CREATE TABLE saved_views (
            id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            position INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE annotations (
            message_id TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            source TEXT NOT NULL,
            PRIMARY KEY (message_id, key)
        ) WITHOUT ROWID;

        CREATE TABLE processing_log (
            message_id TEXT NOT NULL,
            processor_id TEXT NOT NULL,
            version INTEGER NOT NULL,
            processed_at INTEGER NOT NULL,
            error TEXT,
            PRIMARY KEY (message_id, processor_id)
        ) WITHOUT ROWID;

        CREATE TABLE contacts (
            email TEXT PRIMARY KEY,
            name TEXT,
            score REAL NOT NULL DEFAULT 0,
            last_seen INTEGER NOT NULL DEFAULT 0
        );
        """,
        // 2: RFC 8058 one-click unsubscribe. NULL: cached before vimail checked.
        "ALTER TABLE messages ADD COLUMN one_click_unsubscribe INTEGER;",
    ]

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = try db.scalar("PRAGMA user_version")
        guard current < migrations.count else { return }
        for version in current..<migrations.count {
            try db.transaction {
                try db.execute(migrations[version])
                try db.execute("PRAGMA user_version = \(version + 1)")
            }
        }
    }
}
