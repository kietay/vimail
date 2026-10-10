import Foundation
import MailCore

/// What a write transaction touched. Observers use it to refresh only what is visible.
public struct StoreChange: Hashable, Sendable {
    public var threadIDs: Set<String> = []
    public var labels = false
    public var drafts = false
    public var outbox = false
    public var views = false
    public var snoozes = false
    public var rules = false
    /// Calendars, events, occurrences or invitations changed.
    public var calendar = false
    /// Large or unspecific change (initial sync, reset): reload everything.
    public var reset = false

    public init() {}

    public var isEmpty: Bool {
        threadIDs.isEmpty && !labels && !drafts && !outbox && !views && !snoozes && !rules && !calendar && !reset
    }

    public mutating func formUnion(_ other: StoreChange) {
        threadIDs.formUnion(other.threadIDs)
        labels = labels || other.labels
        drafts = drafts || other.drafts
        outbox = outbox || other.outbox
        views = views || other.views
        snoozes = snoozes || other.snoozes
        rules = rules || other.rules
        calendar = calendar || other.calendar
        reset = reset || other.reset
    }
}

/// The local-first database. The UI reads only from here; the sync engine writes provider
/// data here and pushes the outbox to the provider.
///
/// Three SQLite connections in WAL mode, each on its own serial queue: one writer, one reader for
/// the UI, and one reader for long background work (rules), so list queries never wait for a sync
/// batch to commit or for a rules pass to finish reading.
public final class MailStore: @unchecked Sendable {
    public let url: URL
    private let writer: SQLiteDatabase
    private let reader: SQLiteDatabase
    private let backgroundReader: SQLiteDatabase
    private let writeQueue = DispatchQueue(label: "vimail.store.write", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "vimail.store.read", qos: .userInitiated)
    private let backgroundReadQueue = DispatchQueue(label: "vimail.store.read-background", qos: .utility)
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (StoreChange) -> Void] = [:]
    private var cachedSelfAddresses: Set<String> = []

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try SQLiteDatabase(path: url.path)
        try writer.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -32000;
            """)
        try Schema.migrate(writer)
        reader = try Self.openReader(path: url.path)
        backgroundReader = try Self.openReader(path: url.path)
        cachedSelfAddresses = try Self.accountAddresses(writer)
    }

    private static func openReader(path: String) throws -> SQLiteDatabase {
        let reader = try SQLiteDatabase(path: path)
        try reader.execute("""
            PRAGMA query_only = 1;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -32000;
            PRAGMA mmap_size = 268435456;
            """)
        return reader
    }

    /// The account's address and its send-as aliases, lowercased.
    static func accountAddresses(_ db: SQLiteDatabase) throws -> Set<String> {
        let email = try db.first("SELECT value FROM meta WHERE key = 'account_email'") { $0.string(0) }
        let aliases = try db.first("SELECT value FROM meta WHERE key = 'account_aliases'") { row in
            (try? decoder.decode([String].self, from: Data(row.string(0).utf8))) ?? []
        } ?? []
        return Set(([email].compactMap { $0 } + aliases).map { $0.lowercased() })
    }

    /// The account's own addresses (lowercased): its address and send-as aliases. Used for "me" in
    /// participant lines, and to keep your own mail away from rules.
    public var selfAddresses: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return cachedSelfAddresses
    }

    func setSelfAddresses(_ addresses: Set<String>) {
        lock.lock()
        cachedSelfAddresses = Set(addresses.map { $0.lowercased() })
        lock.unlock()
    }

    // MARK: - Observation

    /// Registers a handler called (on a background queue) after every committed write.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (StoreChange) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    private func notify(_ change: StoreChange) {
        guard !change.isEmpty else { return }
        lock.lock()
        let handlers = Array(observers.values)
        lock.unlock()
        for handler in handlers { handler(change) }
    }

    // MARK: - Primitives

    public func read<T: Sendable>(_ body: @escaping @Sendable (SQLiteDatabase) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
                continuation.resume(with: Result { try body(self.reader) })
            }
        }
    }

    /// Like `read`, on the background connection: for long reads (rules work) that must not hold up the UI.
    public func readBackground<T: Sendable>(_ body: @escaping @Sendable (SQLiteDatabase) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            backgroundReadQueue.async {
                continuation.resume(with: Result { try body(self.backgroundReader) })
            }
        }
    }

    /// Runs `body` in one transaction on the writer connection, then notifies observers.
    public func write<T: Sendable>(_ body: @escaping @Sendable (SQLiteDatabase, inout StoreChange) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                var change = StoreChange()
                let result = Result { try self.writer.transaction { try body(self.writer, &change) } }
                // Notify before resuming so callers observe a consistent order.
                if case .success = result { self.notify(change) }
                continuation.resume(with: result)
            }
        }
    }

    /// Like `write`, for work too large for one transaction: `body` runs once per chunk of `elements`
    /// (at most `size` each), each chunk in its own transaction. Observers hear once, at the end, about
    /// every chunk that committed. A failing chunk rolls back alone and stops the rest.
    func writeChunks<Element: Sendable, T: Sendable>(
        _ elements: [Element], size: Int, _ body: @escaping @Sendable (ArraySlice<Element>, SQLiteDatabase, inout StoreChange) throws -> T
    ) async throws -> [T] {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                var committed = StoreChange()
                var results: [T] = []
                var failure: (any Error)?
                for start in stride(from: 0, to: elements.count, by: size) {
                    var change = StoreChange()
                    do {
                        results.append(try self.writer.transaction { try body(elements[start..<min(start + size, elements.count)], self.writer, &change) })
                        committed.formUnion(change)
                    } catch {
                        failure = error
                        break
                    }
                }
                self.notify(committed)
                if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume(returning: results)
                }
            }
        }
    }

    /// Synchronous read, for tests and app startup.
    public func readNow<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        try readQueue.sync { try body(reader) }
    }

    /// Synchronous write, for tests and app startup.
    @discardableResult
    public func writeNow<T>(_ body: (SQLiteDatabase, inout StoreChange) throws -> T) throws -> T {
        var change = StoreChange()
        let value = try writeQueue.sync { try writer.transaction { try body(writer, &change) } }
        notify(change)
        return value
    }

    // MARK: - Meta

    public func meta(_ key: String) async throws -> String? {
        try await read { db in try db.first("SELECT value FROM meta WHERE key = ?", [key]) { $0.string(0) } }
    }

    public func setMeta(_ key: String, _ value: String?) async throws {
        try await write { db, _ in try Self.setMeta(key, value, db) }
    }

    static func setMeta(_ key: String, _ value: String?, _ db: SQLiteDatabase) throws {
        if let value {
            try db.run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
        } else {
            try db.run("DELETE FROM meta WHERE key = ?", [key])
        }
    }

    public func setAccount(_ profile: AccountProfile) async throws {
        try await write { db, _ in
            try Self.setMeta("account_email", profile.email, db)
            try Self.setMeta("account_name", profile.displayName, db)
            try Self.setMeta("account_signature_html", profile.signatureHTML, db)
            try Self.setMeta("account_aliases", try Self.json(profile.aliases), db)
        }
        setSelfAddresses(Set([profile.email] + profile.aliases))
    }

    /// The provider account's own signature (Gmail settings), as HTML.
    public func accountSignatureHTML() async throws -> String? {
        try await meta("account_signature_html")
    }

    /// The subset of `ids` that are stored conversations.
    public func existingThreadIDs(_ ids: [String]) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try await read { db in
            var found = Set<String>()
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try db.query("SELECT id FROM threads WHERE id IN (\(placeholders))", chunk) { $0.string(0) }
                found.formUnion(rows)
            }
            return found
        }
    }

    public func account() async throws -> EmailAddress? {
        try await read { db in
            let email = try db.first("SELECT value FROM meta WHERE key = 'account_email'") { $0.string(0) }
            let name = try db.first("SELECT value FROM meta WHERE key = 'account_name'") { $0.string(0) }
            return email.map { EmailAddress(name: name, email: $0) }
        }
    }

    /// Deletes all mail data and sync state. Local-only state (drafts, views, rules, answers sent by email) is kept
    /// unless `everything`; answers whose email had not left go with the outbox.
    ///
    /// Rules keep what they learned (examples, sender overrides, Claude's verdicts) but lose their
    /// work on the deleted mail: decisions, ledger, queue, runs and your label marks. Labels that
    /// rules target come back with the same ID, name and colour; for Gmail labels, the next sync
    /// then tells whether Gmail still has them.
    public func resetMailData(everything: Bool = false) async throws {
        try await write { db, change in
            let targeted = try Self.labels(targetedByRules: db)
            try db.execute("""
                DELETE FROM invitation_answers WHERE outbox_id IN (SELECT id FROM outbox);
                DELETE FROM threads; DELETE FROM messages; DELETE FROM message_labels;
                DELETE FROM thread_labels; DELETE FROM message_search; DELETE FROM outbox;
                DELETE FROM labels; DELETE FROM annotations; DELETE FROM processing_log;
                DELETE FROM contacts; DELETE FROM snoozes;
                DELETE FROM rule_decisions; DELETE FROM rule_ledger; DELETE FROM rule_queue; DELETE FROM rule_runs;
                DELETE FROM label_marks;
                DELETE FROM meta WHERE key IN ('cursor', 'initial_sync_done', 'initial_cursor', 'resync', 'backfill_done',
                    'backfill_token', 'backfill_count', 'account_email', 'account_name', 'account_signature_html',
                    'account_aliases', 'rules_resync');
                DELETE FROM calendars; DELETE FROM events; DELETE FROM occurrences; DELETE FROM invitations;
                DELETE FROM calendar_outbox; DELETE FROM meta WHERE key LIKE 'calendar_%';
                """)
            if everything {
                try db.execute("""
                    DELETE FROM drafts; DELETE FROM saved_views; DELETE FROM event_drafts; DELETE FROM invitation_answers; DELETE FROM meta;
                    DELETE FROM rules; DELETE FROM rule_revisions; DELETE FROM rule_examples;
                    DELETE FROM rule_overrides; DELETE FROM verdicts; DELETE FROM rule_call_costs;
                    """)
            } else {
                for label in targeted { try Self.upsertLabel(label, db) }
            }
            change.reset = true
        }
        setSelfAddresses([])
    }
}
