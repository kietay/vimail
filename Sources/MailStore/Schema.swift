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
        // 3: calendar.
        """
        CREATE TABLE calendars (
            id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            position INTEGER NOT NULL DEFAULT 0,
            sync_token TEXT                       -- events.list token for this calendar
        );

        -- Events as the provider stores them: single events, series and changed occurrences (exceptions).
        CREATE TABLE events (
            calendar_id TEXT NOT NULL,
            id TEXT NOT NULL,
            ical_uid TEXT,
            recurring_event_id TEXT,
            status TEXT NOT NULL,
            self_response TEXT,                   -- the account's answer when it is a guest
            payload TEXT NOT NULL,
            PRIMARY KEY (calendar_id, id)
        ) WITHOUT ROWID;
        CREATE INDEX events_uid ON events(ical_uid);
        CREATE INDEX events_series ON events(calendar_id, recurring_event_id);

        -- What the agenda and the day column read: one row per occurrence inside the stored window.
        -- Timed occurrences use start_ms/end_ms; all-day ones also have start_day/end_day (end exclusive).
        CREATE TABLE occurrences (
            calendar_id TEXT NOT NULL,
            event_id TEXT NOT NULL,               -- the events row with the details
            series_id TEXT,                       -- the series this occurrence belongs to, if any
            original_start TEXT NOT NULL DEFAULT '',
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            start_day TEXT,
            end_day TEXT,
            PRIMARY KEY (calendar_id, event_id, original_start)
        ) WITHOUT ROWID;
        CREATE INDEX occurrences_start ON occurrences(start_ms);
        CREATE INDEX occurrences_series ON occurrences(calendar_id, series_id);

        -- Invitations found in mail (parsed text/calendar parts). payload is NULL when the file could not be read.
        CREATE TABLE invitations (
            message_id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            uid TEXT,
            method TEXT,
            sequence INTEGER NOT NULL DEFAULT 0,
            recurrence_id TEXT,                   -- the occurrence key when the file is about one occurrence only
            organizer TEXT,                       -- the event's organizer, lowercased address (organizer:me)
            payload TEXT,
            error TEXT,
            parsed_at INTEGER NOT NULL
        );
        CREATE INDEX invitations_uid ON invitations(uid);
        CREATE INDEX invitations_thread ON invitations(thread_id);
        CREATE INDEX invitations_organizer ON invitations(organizer, thread_id);

        -- Calendar changes waiting to be pushed. Separate from the mail outbox, so a calendar
        -- failure never holds back mail and each sync engine resets only its own in-flight work.
        CREATE TABLE calendar_outbox (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            target TEXT NOT NULL DEFAULT '',          -- calendar|event (a series for its occurrences): one queue per event
            payload TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'pending',   -- pending | inflight
            not_before INTEGER NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at INTEGER NOT NULL
        );
        CREATE INDEX calendar_outbox_target ON calendar_outbox(target, id);

        -- Events the sync removed (the organizer deleted them, or took you off), by iCalendar UID: their
        -- invitation mail stops waiting for an answer, unless a newer invitation (higher SEQUENCE) comes.
        CREATE TABLE removed_events (
            uid TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL DEFAULT 0
        );

        -- Your answers to invitations that are not on Google Calendar, sent to the organizer by email (iMIP). An answer
        -- covers its invitation and older ones (SEQUENCE); a newer invitation waits for an answer again.
        CREATE TABLE invitation_answers (
            uid TEXT NOT NULL,
            recurrence_id TEXT NOT NULL DEFAULT '',   -- the occurrence key when the invitation is for one occurrence
            response TEXT NOT NULL,
            comment TEXT,
            sequence INTEGER NOT NULL DEFAULT 0,
            covered TEXT,                             -- JSON {occurrence key: SEQUENCE}: dates a whole-event answer covers
            answered_at INTEGER NOT NULL,
            outbox_id INTEGER,                        -- the mail outbox entry of the email that carries it
            PRIMARY KEY (uid, recurrence_id)
        ) WITHOUT ROWID;

        -- Local-only event drafts (the event editor).
        CREATE TABLE event_drafts (
            id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """,
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
