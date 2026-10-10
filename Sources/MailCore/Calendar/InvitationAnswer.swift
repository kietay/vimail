import Foundation

/// Your answer to an invitation that is not on Google Calendar, sent to its organizer by email (iMIP).
public struct InvitationAnswer: Hashable, Codable, Sendable {
    public var uid: String
    /// The occurrence key when the invitation is for one occurrence of a series; "" for the whole event.
    public var recurrenceID: String
    public var response: ResponseStatus
    public var comment: String?
    /// The SEQUENCE of the invitation answered: a newer invitation (higher) waits for an answer again.
    public var sequence: Int
    public var answeredAt: Date
    /// The mail outbox entry of the email that carries it. The store sets it.
    public var outboxID: Int64?

    public init(
        uid: String, recurrenceID: String = "", response: ResponseStatus, comment: String? = nil, sequence: Int = 0,
        answeredAt: Date = Date(), outboxID: Int64? = nil
    ) {
        self.uid = uid
        self.recurrenceID = recurrenceID
        self.response = response
        self.comment = comment
        self.sequence = sequence
        self.answeredAt = answeredAt
        self.outboxID = outboxID
    }
}

/// Answers by email and the dates they cover. One answer covers the whole event; a date the organizer changed on its
/// own after you answered (its SEQUENCE is newer than your answer) asks again and is answered on its own. When the mail
/// is only about some dates, each is answered on its own.
extension InvitedEvent {
    /// The invitation an answer for one date (by occurrence key, "" for a single event) goes to, given your answers by
    /// recurrence ID ("" for the whole event). Nil when that date or the event is cancelled.
    public func answerTarget(at key: String, answers: [String: InvitationAnswer]) -> Invitation? {
        let own = changedDates[key]
        if own?.isCancellation == true { return nil }
        guard let main else { return own }
        guard !main.isCancellation else { return nil }
        if let own, let whole = answers[""], whole.sequence >= main.sequence, own.sequence > whole.sequence { return own }
        return main
    }

    /// Your answer that covers one date, if any.
    public func answer(at key: String, answers: [String: InvitationAnswer]) -> InvitationAnswer? {
        guard let target = answerTarget(at: key, answers: answers),
              let answer = answers[target.recurrenceID?.occurrenceKey ?? ""], answer.sequence >= target.sequence else { return nil }
        return answer
    }

    /// The SEQUENCE an answer to `target` covers: for the whole event, everything its mail said so far, its changed dates
    /// too (a series' file often carries them), so only a later change asks again.
    public func coveredSequence(by target: Invitation) -> Int {
        guard target.recurrenceID == nil else { return target.sequence }
        return ([target.sequence] + changedDates.values.map(\.sequence)).max() ?? target.sequence
    }

    /// The first date from `now` on that still waits for your answer, if any: where the event waits, and where it shows
    /// in the waiting list.
    public func waitingDate(now: Date, answers: [String: InvitationAnswer], calendar: Calendar = .current) -> InvitedDate? {
        upcoming(now: now, limit: 300, calendar: calendar).first { answer(at: $0.key, answers: answers) == nil }
    }

    /// The newest version of `invitation` the mail tells (same date, or the whole event), so an answer goes to what the
    /// organizer last sent. Mail in Spam is not part of `InvitedEvent`, so it never takes over.
    public func newest(_ invitation: Invitation) -> Invitation {
        let latest: Invitation?
        if let date = invitation.recurrenceID { latest = changedDates[date.occurrenceKey] } else { latest = main }
        guard let latest, latest.sequence > invitation.sequence else { return invitation }
        return latest
    }
}
