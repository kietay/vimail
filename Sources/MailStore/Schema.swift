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
        // 3: rules, their work queue, runs, decisions and ledger.
        """
        CREATE INDEX messages_date ON messages(date DESC);
        CREATE TABLE rules (id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, position INTEGER NOT NULL,
          enabled INTEGER NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'ok',          -- ok | tripped | label_missing | needs_upgrade
          live_from INTEGER, covered_since INTEGER, disabled_at INTEGER,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
        CREATE TABLE rule_revisions (rule_id TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL,
          created_at INTEGER NOT NULL, PRIMARY KEY (rule_id, revision)) WITHOUT ROWID;
        CREATE TABLE rule_examples (                 -- explicit ✔/✖ for one rule; each decides its message
          rule_id TEXT NOT NULL, message_id TEXT NOT NULL, verdict INTEGER NOT NULL,
          origin TEXT NOT NULL,                      -- seed | preview | explain | edit (editsTeach only)
          digest TEXT NOT NULL,                      -- "sender name · @domain · subject ≤ 120 chars"
          undo_key TEXT, created_at INTEGER NOT NULL, PRIMARY KEY (rule_id, message_id)) WITHOUT ROWID;
        CREATE TABLE label_marks (                   -- your own label edits; bind every rule
          message_id TEXT NOT NULL, label_id TEXT NOT NULL,
          present INTEGER NOT NULL,                  -- 1 you added it, 0 you removed it
          undo_key TEXT, created_at INTEGER NOT NULL, PRIMARY KEY (message_id, label_id)) WITHOUT ROWID;
        CREATE TABLE rule_overrides (rule_id TEXT NOT NULL, subject TEXT NOT NULL,   -- "a@b.com" | "@b.com"
          verdict INTEGER NOT NULL, origin TEXT NOT NULL, evidence INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL, PRIMARY KEY (rule_id, subject)) WITHOUT ROWID;
        CREATE TABLE verdicts (message_id TEXT NOT NULL, judge_hash TEXT NOT NULL,
          verdict TEXT NOT NULL,                     -- match | no_match | unsure | declined
          reason TEXT NOT NULL, examples_digest TEXT NOT NULL, model TEXT NOT NULL, served_by TEXT NOT NULL,
          created_at INTEGER NOT NULL, PRIMARY KEY (message_id, judge_hash)) WITHOUT ROWID;
        CREATE TABLE rule_decisions (message_id TEXT NOT NULL, rule_id TEXT NOT NULL, revision INTEGER NOT NULL,
          outcome TEXT NOT NULL, source TEXT NOT NULL,   -- gate | mark | example | override | thread | cache | claude
          judge_hash TEXT, run_id INTEGER NOT NULL, decided_at INTEGER NOT NULL,
          PRIMARY KEY (message_id, rule_id)) WITHOUT ROWID;
        CREATE INDEX rule_decisions_rule ON rule_decisions(rule_id, outcome);
        CREATE TABLE rule_runs (id INTEGER PRIMARY KEY AUTOINCREMENT,
          kind TEXT NOT NULL,                        -- live | backfill | recheck | manual | gap | backlog
          day TEXT,                                  -- live only: one row per local 'YYYY-MM-DD'
          rules TEXT NOT NULL,                       -- JSON [{"id":"r_…","rev":3}]
          window_start INTEGER, window_end INTEGER,
          state TEXT NOT NULL,                       -- running | paused | awaiting_confirm | done | cancelled | undone
          pause_reason TEXT,                         -- budget | cap | user | ai | rule_changed | model_changed
          model TEXT, total INTEGER NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0,
          judged INTEGER NOT NULL DEFAULT 0, labeled INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0,
          plus INTEGER, minus INTEGER, est_micros INTEGER, cap_micros INTEGER,
          cost_micros INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, finished_at INTEGER);
        CREATE UNIQUE INDEX rule_runs_live_day ON rule_runs(day) WHERE kind = 'live';
        CREATE TABLE rule_queue (message_id TEXT NOT NULL, run_id INTEGER NOT NULL,
          priority INTEGER NOT NULL,                 -- 0 live, 1 manual, 2 runs
          state TEXT NOT NULL DEFAULT 'queued',      -- queued | waiting_ai | held | failed
          attempts INTEGER NOT NULL DEFAULT 0, not_before INTEGER NOT NULL DEFAULT 0,
          error_code TEXT, PRIMARY KEY (message_id, run_id)) WITHOUT ROWID;
        CREATE INDEX rule_queue_due ON rule_queue(state, priority, not_before);
        CREATE TABLE rule_ledger (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER NOT NULL,
          rule_id TEXT NOT NULL, revision INTEGER NOT NULL, message_id TEXT NOT NULL, thread_id TEXT NOT NULL,
          effect TEXT NOT NULL, target TEXT NOT NULL, inverse TEXT,  -- 'add_label', label id, future inverse JSON
          changed INTEGER NOT NULL,                  -- 1 this commit added it, 0 co-owner of a rule-added label
          outbox_id INTEGER, simulated INTEGER NOT NULL DEFAULT 0, applied_at INTEGER NOT NULL,
          reverted_at INTEGER, reverted_by TEXT);    -- undo | user | recheck | rule_deleted | label_deleted | gmail_rejected
        CREATE INDEX rule_ledger_message ON rule_ledger(message_id);
        CREATE INDEX rule_ledger_run ON rule_ledger(run_id) WHERE reverted_at IS NULL;
        CREATE INDEX rule_ledger_outbox ON rule_ledger(outbox_id) WHERE outbox_id IS NOT NULL;
        CREATE UNIQUE INDEX rule_ledger_active ON rule_ledger(message_id, rule_id, target) WHERE reverted_at IS NULL;
        """,
        // 4: when a run was confirmed (a re-check applies only after it), recent Claude call costs for
        // estimates, and a new live run for the day after you undo one.
        """
        ALTER TABLE rule_runs ADD COLUMN confirmed_at INTEGER;
        CREATE TABLE rule_call_costs (model TEXT NOT NULL, cost_micros INTEGER NOT NULL, created_at INTEGER NOT NULL);
        CREATE INDEX rule_call_costs_model ON rule_call_costs(model);
        DROP INDEX rule_runs_live_day;
        CREATE UNIQUE INDEX rule_runs_live_day ON rule_runs(day) WHERE kind = 'live' AND state != 'undone';
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
