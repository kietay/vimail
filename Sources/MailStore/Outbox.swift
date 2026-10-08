import Foundation
import MailCore

/// A label change for a set of messages.
public struct LabelDelta: Hashable, Codable, Sendable {
    public var messageIDs: [String]
    public var add: Set<String>
    public var remove: Set<String>

    public init(messageIDs: [String], add: Set<String> = [], remove: Set<String> = []) {
        self.messageIDs = messageIDs
        self.add = add
        self.remove = remove
    }

    public var inverse: LabelDelta { LabelDelta(messageIDs: messageIDs, add: remove, remove: add) }
    public var isEmpty: Bool { messageIDs.isEmpty || (add.isEmpty && remove.isEmpty) }
}

/// A local change waiting to be pushed to the provider.
public enum OutboxOperation: Hashable, Codable, Sendable {
    case modifyLabels(LabelDelta)
    case deleteMessages(ids: [String])
    /// `localMessageID`/`localThreadID` identify the optimistic copy shown in Sent until the
    /// provider returns the real message. The draft is kept so a failed send can be restored.
    case send(draft: Draft, message: OutgoingMessage, localMessageID: String, localThreadID: String)
    case createLabel(localID: String, name: String)
    case renameLabel(id: String, name: String)
    case deleteLabel(id: String)

    /// For logs: the kind and size, never subjects or addresses.
    public var logDescription: String {
        switch self {
        case .modifyLabels(let delta): "label change on \(delta.messageIDs.count) message(s) +\(delta.add.sorted().joined(separator: ",")) -\(delta.remove.sorted().joined(separator: ","))"
        case .deleteMessages(let ids): "delete \(ids.count) message(s)"
        case .send(_, let message, _, _): "send \(message.messageID ?? "message") (\(message.attachments.count) attachment(s), \(message.threadID == nil ? "new thread" : "reply"))"
        case .createLabel(let localID, _): "create label \(localID)"
        case .renameLabel(let id, _): "rename label \(id)"
        case .deleteLabel(let id): "delete label \(id)"
        }
    }

    public var summary: String {
        switch self {
        case .modifyLabels(let delta): "modify \(delta.messageIDs.count) message(s)"
        case .deleteMessages(let ids): "delete \(ids.count) message(s)"
        case .send(_, let message, _, _): "send \"\(message.subject)\""
        case .createLabel(_, let name): "create label \(name)"
        case .renameLabel(_, let name): "rename label to \(name)"
        case .deleteLabel: "delete label"
        }
    }
}

public struct OutboxItem: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var operation: OutboxOperation
    public var attempts: Int
    public var notBefore: Date
    public var lastError: String?
}

extension MailStore {
    static func enqueue(_ operation: OutboxOperation, notBefore: Date = .distantPast, _ db: SQLiteDatabase) throws -> Int64 {
        let payload = String(decoding: try encoder.encode(operation), as: UTF8.self)
        try db.run(
            "INSERT INTO outbox(payload, not_before, created_at) VALUES (?, ?, ?)",
            [payload, notBefore == .distantPast ? 0 : notBefore.sqlValue, Date()]
        )
        return db.lastInsertRowID
    }

    static func decodeOutbox(_ row: SQLRow) throws -> OutboxItem {
        OutboxItem(
            id: row.int64(0),
            operation: try decoder.decode(OutboxOperation.self, from: Data(row.string(1).utf8)),
            attempts: row.int(2),
            notBefore: row.date(3),
            lastError: row.optionalString(4)
        )
    }

    /// Pending and in-flight operations, oldest first.
    static func outboxItems(_ db: SQLiteDatabase) throws -> [OutboxItem] {
        try db.query("SELECT id, payload, attempts, not_before, last_error FROM outbox ORDER BY id", [], decodeOutbox)
    }

    public func enqueue(_ operation: OutboxOperation, notBefore: Date = .distantPast) async throws -> Int64 {
        try await write { db, change in
            change.outbox = true
            return try Self.enqueue(operation, notBefore: notBefore, db)
        }
    }

    /// Claims the oldest due operation by marking it in flight.
    public func claimNextOutboxItem(now: Date = Date()) async throws -> OutboxItem? {
        try await write { db, _ in
            guard let item = try db.first(
                "SELECT id, payload, attempts, not_before, last_error FROM outbox WHERE state = 'pending' AND not_before <= ? ORDER BY id LIMIT 1",
                [now], Self.decodeOutbox
            ) else { return nil }
            try db.run("UPDATE outbox SET state = 'inflight' WHERE id = ?", [item.id])
            return item
        }
    }

    /// Earliest `not_before` among pending operations, so the sync engine can wake up for it.
    public func nextOutboxDueDate() async throws -> Date? {
        try await read { db in
            try db.first("SELECT MIN(not_before) FROM outbox WHERE state = 'pending'") { $0.optionalDate(0) } ?? nil
        }
    }

    public func completeOutboxItem(_ id: Int64) async throws {
        try await write { db, change in
            try db.run("DELETE FROM outbox WHERE id = ?", [id])
            change.outbox = true
        }
    }

    /// Returns an operation to the queue after a transient failure.
    public func retryOutboxItem(_ id: Int64, error: String, retryAt: Date) async throws {
        try await write { db, change in
            try db.run(
                "UPDATE outbox SET state = 'pending', attempts = attempts + 1, last_error = ?, not_before = ? WHERE id = ?",
                [error, retryAt, id]
            )
            change.outbox = true
        }
    }

    /// On launch, operations left in flight by a crash go back to pending. They count as an
    /// attempt: a send may have reached the provider before the crash.
    public func resetInflightOutboxItems() async throws {
        try await write { db, _ in try db.run("UPDATE outbox SET state = 'pending', attempts = attempts + 1 WHERE state = 'inflight'") }
    }

    public func outboxCount() async throws -> Int {
        try await read { db in try db.scalar("SELECT COUNT(*) FROM outbox") }
    }

    public func outboxItems() async throws -> [OutboxItem] {
        try await read { db in try Self.outboxItems(db) }
    }

    /// Removes the given operations if they have not been picked up yet.
    /// Returns the IDs that were removed (still pending).
    public func cancelOutboxItems(_ ids: [Int64]) async throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        return try await write { db, change in
            var removed = Set<Int64>()
            for id in ids {
                try db.run("DELETE FROM outbox WHERE id = ? AND state = 'pending'", [id])
                if db.changes > 0 { removed.insert(id) }
            }
            if !removed.isEmpty { change.outbox = true }
            return removed
        }
    }
}
