import Foundation
import MailCore

/// A label delta plus whether it must be pushed to the provider.
public struct PlannedDelta: Hashable, Sendable {
    public var delta: LabelDelta
    /// False for local-only labels (the provider never sees them).
    public var syncs: Bool

    public init(_ delta: LabelDelta, syncs: Bool) {
        self.delta = delta
        self.syncs = syncs
    }
}

/// A delta that was applied locally, with the outbox entry that pushes it (if any).
public struct AppliedDelta: Hashable, Sendable {
    public var delta: LabelDelta
    public var outboxID: Int64?
}

/// One atomic local change: label deltas, snoozes and permanent deletions.
public struct LocalMutation: Sendable {
    public var deltas: [PlannedDelta] = []
    /// Thread ID -> snooze date. `nil` removes the snooze.
    public var snoozes: [String: Date?] = [:]
    public var deleteMessageIDs: [String] = []

    public init(deltas: [PlannedDelta] = [], snoozes: [String: Date?] = [:], deleteMessageIDs: [String] = []) {
        self.deltas = deltas
        self.snoozes = snoozes
        self.deleteMessageIDs = deleteMessageIDs
    }

    public var isEmpty: Bool { deltas.allSatisfy(\.delta.isEmpty) && snoozes.isEmpty && deleteMessageIDs.isEmpty }
}

/// What `apply` did, so it can be reverted exactly.
public struct AppliedMutation: Sendable {
    public var deltas: [AppliedDelta]
    /// Thread ID -> snooze date before the change.
    public var previousSnoozes: [String: Date?]
    public var deleteOutboxID: Int64?

    public var isUndoable: Bool { deleteOutboxID == nil }
}

extension MailStore {
    /// Applies a change locally and queues the provider side, in one transaction.
    public func apply(_ mutation: LocalMutation) async throws -> AppliedMutation {
        try await write { db, change in
            var applied: [AppliedDelta] = []
            for planned in mutation.deltas where !planned.delta.isEmpty {
                change.threadIDs.formUnion(try Self.applyDelta(planned.delta, db))
                let outboxID = planned.syncs ? try Self.enqueue(.modifyLabels(planned.delta), db) : nil
                applied.append(AppliedDelta(delta: planned.delta, outboxID: outboxID))
            }

            var previous: [String: Date?] = [:]
            for (threadID, until) in mutation.snoozes {
                previous[threadID] = try db.first("SELECT until FROM snoozes WHERE thread_id = ?", [threadID]) { $0.date(0) }
                try Self.setSnooze(threadID, until: until, db)
                change.threadIDs.insert(threadID)
                change.snoozes = true
            }

            var deleteOutboxID: Int64?
            if !mutation.deleteMessageIDs.isEmpty {
                for id in mutation.deleteMessageIDs {
                    if let threadID = try Self.deleteMessage(id, db) { change.threadIDs.insert(threadID) }
                }
                deleteOutboxID = try Self.enqueue(.deleteMessages(ids: mutation.deleteMessageIDs), db)
            }

            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            change.outbox = true
            return AppliedMutation(deltas: applied, previousSnoozes: previous, deleteOutboxID: deleteOutboxID)
        }
    }

    /// Reverts an applied mutation. Queued operations that have not been sent are cancelled;
    /// operations that already reached the provider get an inverse operation.
    public func revert(_ applied: AppliedMutation) async throws {
        try await write { db, change in
            for item in applied.deltas.reversed() {
                change.threadIDs.formUnion(try Self.applyDelta(item.delta.inverse, db))
                guard let outboxID = item.outboxID else { continue }
                try db.run("DELETE FROM outbox WHERE id = ? AND state = 'pending'", [outboxID])
                if db.changes == 0 {
                    _ = try Self.enqueue(.modifyLabels(item.delta.inverse), db)
                }
            }
            for (threadID, until) in applied.previousSnoozes {
                try Self.setSnooze(threadID, until: until, db)
                change.threadIDs.insert(threadID)
                change.snoozes = true
            }
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            change.outbox = true
        }
    }

    // MARK: - Sending

    /// Queues a send: shows an optimistic copy in Sent, removes the draft, and enqueues the send
    /// with a `notBefore` delay that gives time to undo.
    public func queueSend(draft: Draft, message: OutgoingMessage, localCopy: MailMessage, notBefore: Date) async throws -> Int64 {
        try await write { db, change in
            try Self.insertLocalMessage(localCopy, db)
            try db.run("DELETE FROM drafts WHERE id = ?", [draft.id])
            let id = try Self.enqueue(
                .send(draft: draft, message: message, localMessageID: localCopy.id, localThreadID: localCopy.threadID),
                notBefore: notBefore, db
            )
            change.threadIDs.insert(localCopy.threadID)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            change.drafts = true
            change.outbox = true
            return id
        }
    }

    /// Undo send. Returns false when the message already left.
    public func cancelSend(outboxID: Int64, draft: Draft, localMessageID: String) async throws -> Bool {
        try await write { db, change in
            try db.run("DELETE FROM outbox WHERE id = ? AND state = 'pending'", [outboxID])
            guard db.changes > 0 else { return false }
            if let threadID = try Self.deleteMessage(localMessageID, db) { change.threadIDs.insert(threadID) }
            try Self.saveDraft(draft, db)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            change.drafts = true
            change.outbox = true
            return true
        }
    }

    /// After a permanent send failure: remove the optimistic copy and restore the draft.
    public func restoreFailedSend(draft: Draft, localMessageID: String) async throws {
        try await write { db, change in
            if let threadID = try Self.deleteMessage(localMessageID, db) { change.threadIDs.insert(threadID) }
            try Self.saveDraft(draft, db)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            change.drafts = true
        }
    }

    // MARK: - Labels created locally

    /// Creates a label. Provider labels get a temporary ID until the provider assigns one.
    public func createLabel(name: String, kind: MailLabel.Kind, colorIndex: Int?) async throws -> MailLabel {
        try await write { db, change in try Self.createLabel(name: name, kind: kind, colorIndex: colorIndex, db, &change) }
    }

    static func createLabel(name: String, kind: MailLabel.Kind, colorIndex: Int?, _ db: SQLiteDatabase, _ change: inout StoreChange) throws -> MailLabel {
        let prefix = kind == .local ? "local" : "pending"
        let label = MailLabel(id: "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())", name: name, kind: kind, colorIndex: colorIndex)
        try upsertLabel(label, db)
        if kind == .user {
            _ = try enqueue(.createLabel(localID: label.id, name: name), db)
            change.outbox = true
        }
        change.labels = true
        return label
    }

    /// Finds a label by name (case-insensitive) or creates one of `kind`. Lookup and creation share
    /// one transaction, so concurrent calls make one label. A label of `kind` is preferred, but one of
    /// the other kind is reused rather than duplicated, as the label picker always did.
    public func ensureLabel(named name: String, kind: MailLabel.Kind) async throws -> (label: MailLabel, created: Bool) {
        try await write { db, change in try Self.findOrCreateLabel(named: name, preferring: kind, creating: kind, db, &change) }
    }

    /// The label a rule adds, picked by name when the rule is saved: an existing label of that name
    /// (Gmail's before a local one), else a new local label. One transaction.
    public func resolveLabel(name: String) async throws -> MailLabel {
        try await write { db, change in try Self.findOrCreateLabel(named: name, preferring: .user, creating: .local, db, &change).label }
    }

    static func findOrCreateLabel(
        named name: String, preferring preferred: MailLabel.Kind, creating kind: MailLabel.Kind, _ db: SQLiteDatabase, _ change: inout StoreChange
    ) throws -> (label: MailLabel, created: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let named = try labels(db).filter { $0.kind != .system && $0.name.lowercased() == trimmed.lowercased() }
        if let existing = named.first(where: { $0.kind == preferred }) ?? named.first { return (existing, false) }
        return (try createLabel(name: trimmed, kind: kind, colorIndex: nil, db, &change), true)
    }

    public func renameLabel(id: String, to name: String, syncs: Bool) async throws {
        try await write { db, change in
            try db.run("UPDATE labels SET name = ? WHERE id = ?", [name, id])
            if syncs {
                _ = try Self.enqueue(.renameLabel(id: id, name: name), db)
                change.outbox = true
            }
            change.labels = true
        }
    }

    public func removeLabel(id: String, syncs: Bool) async throws {
        try await deleteLabel(id: id)
        if syncs { _ = try await enqueue(.deleteLabel(id: id)) }
    }

    public func setLabelColor(id: String, colorIndex: Int?) async throws {
        try await write { db, change in
            try db.run("UPDATE labels SET color_index = ? WHERE id = ?", [colorIndex, id])
            change.labels = true
        }
    }
}
