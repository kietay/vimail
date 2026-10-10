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
    /// Calendars, events, occurrences or invitations changed.
    public var calendar = false
    /// Large or unspecific change (initial sync, reset): reload everything.
    public var reset = false

    public init() {}

    public var isEmpty: Bool {
        threadIDs.isEmpty && !labels && !drafts && !outbox && !views && !snoozes && !calendar && !reset
    }

    public mutating func formUnion(_ other: StoreChange) {
        threadIDs.formUnion(other.threadIDs)
        labels = labels || other.labels
        drafts = drafts || other.drafts
        outbox = outbox || other.outbox
        views = views || other.views
        snoozes = snoozes || other.snoozes
        calendar = calendar || other.calendar
        reset = reset || other.reset
    }
}

/// The local-first database. The UI reads only from here; the sync engine writes provider
/// data here and pushes the outbox to the provider.
///
/// Two SQLite connections in WAL mode: one writer and one reader, each on its own serial
/// queue, so list queries never wait for a sync batch to commit.
public final class MailStore: @unchecked Sendable {
    public let url: URL
    private let writer: SQLiteDatabase
    private let reader: SQLiteDatabase
    private let writeQueue = DispatchQueue(label: "vimail.store.write", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "vimail.store.read", qos: .userInitiated)
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
        reader = try SQLiteDatabase(path: url.path)
        try reader.execute("""
            PRAGMA query_only = 1;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -32000;
            PRAGMA mmap_size = 268435456;
            """)
        let addresses = try writer.first("SELECT value FROM meta WHERE key = 'account_email'") { $0.string(0) }
        cachedSelfAddresses = Set([addresses].compactMap { $0?.lowercased() })
    }

    /// The account's own addresses (lowercased). Used for "me" in participant lines.
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
        }
        setSelfAddresses([profile.email])
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

    /// Deletes all mail data and sync state. Local-only state (drafts, views) is kept unless `everything`.
    public func resetMailData(everything: Bool = false) async throws {
        try await write { db, change in
            try db.execute("""
                DELETE FROM threads; DELETE FROM messages; DELETE FROM message_labels;
                DELETE FROM thread_labels; DELETE FROM message_search; DELETE FROM outbox;
                DELETE FROM labels; DELETE FROM annotations; DELETE FROM processing_log;
                DELETE FROM contacts; DELETE FROM snoozes;
                DELETE FROM meta WHERE key IN ('cursor', 'initial_sync_done', 'initial_cursor', 'resync', 'backfill_done',
                    'backfill_token', 'backfill_count', 'account_email', 'account_name', 'account_signature_html');
                DELETE FROM calendars; DELETE FROM events; DELETE FROM occurrences; DELETE FROM invitations;
                DELETE FROM calendar_outbox; DELETE FROM meta WHERE key LIKE 'calendar_%';
                """)
            if everything {
                try db.execute("DELETE FROM drafts; DELETE FROM saved_views; DELETE FROM event_drafts; DELETE FROM meta;")
            }
            change.reset = true
        }
        setSelfAddresses([])
    }
}
