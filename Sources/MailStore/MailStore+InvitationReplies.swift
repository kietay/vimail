import Foundation
import MailCore

/// An answer by email waiting in the mail outbox: the email, its copy in Sent, and the answer it records. The answer it
/// replaced comes back when the email is taken back or refused.
public struct InvitationReply: Hashable, Codable, Sendable {
    public var message: OutgoingMessage
    public var localMessageID: String
    public var answer: InvitationAnswer
    /// The answer by email this one replaced, if any. The store sets it when it queues the reply.
    public var previous: InvitationAnswer?
    /// The event's title, for the message that says the answer did not go out.
    public var summary: String

    public init(message: OutgoingMessage, localMessageID: String, answer: InvitationAnswer, previous: InvitationAnswer? = nil, summary: String) {
        self.message = message
        self.localMessageID = localMessageID
        self.answer = answer
        self.previous = previous
        self.summary = summary
    }
}

/// Answers by email to invitations that are not on Google Calendar: kept here so the invitation stops waiting, and sent
/// through the mail outbox after the undo window, like a send.
extension MailStore {
    /// Queues an answer by email, in one transaction: its copy shows in Sent and in the invitation's conversation, the
    /// answer is kept so the invitation stops waiting, and the email waits in the outbox until `notBefore` (the undo
    /// window). An answer never covers fewer invitations than the one before it. Returns the outbox entry.
    public func queueInvitationReply(_ reply: InvitationReply, localCopy: MailMessage, notBefore: Date) async throws -> Int64 {
        try await write { db, change in
            var reply = reply
            reply.previous = try Self.invitationAnswer(uid: reply.answer.uid, recurrenceID: reply.answer.recurrenceID, db)
            try Self.insertLocalMessage(localCopy, db)
            let outboxID = try Self.enqueue(.invitationReply(reply), notBefore: notBefore, db)
            var answer = reply.answer
            answer.sequence = max(answer.sequence, reply.previous?.sequence ?? 0)
            answer.covered.merge(reply.previous?.covered ?? [:]) { max($0, $1) }
            answer.outboxID = outboxID
            try Self.saveInvitationAnswer(answer, db)
            change.threadIDs.insert(localCopy.threadID)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            change.outbox = true
            change.calendar = true
            return outboxID
        }
    }

    /// Takes back an answer by email that has not left: the email and its copy go, and the answer before it comes back.
    /// Returns false when the email already left (or is leaving): it cannot be unsent, so the answer stays.
    public func cancelInvitationReply(outboxID: Int64) async throws -> Bool {
        try await write { db, change in
            guard let item = try db.first(
                "SELECT id, payload, attempts, not_before, last_error FROM outbox WHERE id = ? AND state = 'pending'", [outboxID], Self.decodeOutbox
            ), case .invitationReply(let reply) = item.operation else { return false }
            try db.run("DELETE FROM outbox WHERE id = ?", [outboxID])
            try Self.takeBack(reply, outboxID: outboxID, db, &change)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: self.selfAddresses)
            change.outbox = true
            return true
        }
    }

    /// After the provider refused the email: its copy leaves Sent and the answer before it comes back. Returns true when
    /// an answer still covers what this one answered (the one before, or a later one, by the answer rule); else the
    /// invitation waits for an answer again.
    @discardableResult
    public func restoreFailedInvitationReply(_ reply: InvitationReply, outboxID: Int64) async throws -> Bool {
        let me = selfAddresses
        return try await write { db, change in
            try Self.takeBack(reply, outboxID: outboxID, db, &change)
            try Self.refreshThreads(change.threadIDs, db, selfAddresses: me)
            let answer = reply.answer
            if let known = try Self.mailOnlyEvents(uids: [answer.uid], me: me, db).first {
                return known.event.answer(at: answer.recurrenceID, answers: known.answers) != nil
            }
            // No mail tells the event here: the answer kept must be for this version or a newer one.
            return try Self.invitationAnswer(uid: answer.uid, recurrenceID: answer.recurrenceID, db).map { $0.sequence >= answer.sequence } ?? false
        }
    }

    /// Your answer by email to an invitation, whatever its SEQUENCE. `recurrenceID`: the occurrence key, "" for the event.
    public func invitationAnswer(uid: String, recurrenceID: String = "") async throws -> InvitationAnswer? {
        try await read { db in try Self.invitationAnswer(uid: uid, recurrenceID: recurrenceID, db) }
    }

    // MARK: - Helpers

    static func invitationAnswer(uid: String, recurrenceID: String, _ db: SQLiteDatabase) throws -> InvitationAnswer? {
        try db.first(
            "SELECT \(answerColumns) FROM invitation_answers WHERE uid = ? AND recurrence_id = ?",
            [uid, recurrenceID]
        ) { decodeInvitationAnswer($0) } ?? nil
    }

    /// The columns `decodeInvitationAnswer` reads, in its order.
    static let answerColumns = "uid, recurrence_id, response, comment, sequence, answered_at, outbox_id, covered"

    /// An answer from the eight columns from `first` on (`answerColumns`). Nil when they are NULL, as a LEFT JOIN without
    /// an answer leaves them.
    static func decodeInvitationAnswer(_ row: SQLRow, at first: Int32 = 0) -> InvitationAnswer? {
        guard !row.isNull(first), let response = ResponseStatus(rawValue: row.string(first + 2)) else { return nil }
        let covered = row.optionalString(first + 7).flatMap { try? JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) } ?? [:]
        return InvitationAnswer(
            uid: row.string(first), recurrenceID: row.string(first + 1), response: response, comment: row.optionalString(first + 3),
            sequence: row.int(first + 4), covered: covered, answeredAt: row.date(first + 5),
            outboxID: row.isNull(first + 6) ? nil : row.int64(first + 6)
        )
    }

    static func saveInvitationAnswer(_ answer: InvitationAnswer, _ db: SQLiteDatabase) throws {
        try db.run(
            """
            INSERT INTO invitation_answers(uid, recurrence_id, response, comment, sequence, answered_at, outbox_id, covered)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uid, recurrence_id) DO UPDATE SET response = excluded.response, comment = excluded.comment,
                sequence = excluded.sequence, answered_at = excluded.answered_at, outbox_id = excluded.outbox_id, covered = excluded.covered
            """,
            [
                answer.uid, answer.recurrenceID, answer.response.rawValue, answer.comment, answer.sequence, answer.answeredAt, answer.outboxID,
                answer.covered.isEmpty ? nil : String(decoding: try JSONEncoder().encode(answer.covered), as: UTF8.self),
            ]
        )
    }

    /// Undoes what queueing an answer by email did locally: its copy in Sent goes, and the answer before it comes back.
    /// When a later answer replaced this one meanwhile, that one stays, and taking it back later brings back the answer
    /// before this one: this one never went out.
    static func takeBack(_ reply: InvitationReply, outboxID: Int64, _ db: SQLiteDatabase, _ change: inout StoreChange) throws {
        if let threadID = try deleteMessage(reply.localMessageID, db) { change.threadIDs.insert(threadID) }
        let answer = reply.answer
        if try invitationAnswer(uid: answer.uid, recurrenceID: answer.recurrenceID, db)?.outboxID == outboxID {
            if let previous = reply.previous {
                try saveInvitationAnswer(previous, db)
            } else {
                try db.run("DELETE FROM invitation_answers WHERE uid = ? AND recurrence_id = ?", [answer.uid, answer.recurrenceID])
            }
        } else {
            for item in try outboxItems(db) {
                guard case .invitationReply(var later) = item.operation, later.previous?.outboxID == outboxID else { continue }
                later.previous = reply.previous
                try db.run("UPDATE outbox SET payload = ? WHERE id = ?", [try json(OutboxOperation.invitationReply(later)), item.id])
            }
        }
        change.calendar = true
    }
}
