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
    /// For an answer to the whole event: the dates its mail had changed on their own when you answered, each with its own
    /// SEQUENCE (a date counts its SEQUENCE apart from the series). The answer covers them as they were then.
    public var covered: [String: Int]
    public var answeredAt: Date
    /// The mail outbox entry of the email that carries it. The store sets it.
    public var outboxID: Int64?

    public init(
        uid: String, recurrenceID: String = "", response: ResponseStatus, comment: String? = nil, sequence: Int = 0,
        covered: [String: Int] = [:], answeredAt: Date = Date(), outboxID: Int64? = nil
    ) {
        self.uid = uid
        self.recurrenceID = recurrenceID
        self.response = response
        self.comment = comment
        self.sequence = sequence
        self.covered = covered
        self.answeredAt = answeredAt
        self.outboxID = outboxID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        recurrenceID = try container.decode(String.self, forKey: .recurrenceID)
        response = try container.decode(ResponseStatus.self, forKey: .response)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        sequence = try container.decode(Int.self, forKey: .sequence)
        // Answers queued before dates were recorded cover none on their own.
        covered = try container.decodeIfPresent([String: Int].self, forKey: .covered) ?? [:]
        answeredAt = try container.decode(Date.self, forKey: .answeredAt)
        outboxID = try container.decodeIfPresent(Int64.self, forKey: .outboxID)
    }
}

/// Answers by email and the dates they cover. One answer covers the whole event and the dates its mail had changed on
/// their own when you answered. A date the organizer changes after that (a newer SEQUENCE for that date, or a date
/// changed for the first time) waits again and is answered on its own; a newer invitation to the whole event waits
/// again as a whole. When the mail is only about some dates, each is answered on its own.
extension InvitedEvent {
    /// Your answer that covers one date (by occurrence key, "" for a single event), given your answers by recurrence ID
    /// ("" for the whole event): the date's own answer, or the answer to the whole event when it covers the date as the
    /// mail tells it now, whichever came later. Nil for a cancelled date or event.
    public func answer(at key: String, answers: [String: InvitationAnswer]) -> InvitationAnswer? {
        let own = changedDates[key]
        if own?.isCancellation == true { return nil }
        let whole = wholeAnswer(answers)
        guard let own else { return whole }
        var covering: [InvitationAnswer] = []
        if let dated = answers[key], dated.sequence >= own.sequence { covering.append(dated) }
        if let whole, (whole.covered[key] ?? .min) >= own.sequence { covering.append(whole) }
        return covering.max { $0.answeredAt < $1.answeredAt }
    }

    /// The invitation an answer for one date goes to. While no answer covers the whole event's newest invitation, the
    /// whole event (its changed dates too); once it is answered, a date changed on its own since is answered on its own.
    /// Nil when that date or the event is cancelled.
    public func answerTarget(at key: String, answers: [String: InvitationAnswer]) -> Invitation? {
        let own = changedDates[key]
        if own?.isCancellation == true { return nil }
        guard let main else { return own }
        guard !main.isCancellation else { return nil }
        guard let own, wholeAnswer(answers) != nil else { return main }
        // Answered as a whole: a date the whole answer still covers is answered with the series again.
        if let current = answer(at: key, answers: answers), current.recurrenceID.isEmpty { return main }
        return own
    }

    /// The dates an answer to `target` covers (`InvitationAnswer.covered`): for the whole event, every date its mail
    /// changed on its own so far, at its own SEQUENCE. None for an answer to one date.
    public func coverage(by target: Invitation) -> [String: Int] {
        guard target.recurrenceID == nil else { return [:] }
        return changedDates.filter { !$0.value.isCancellation }.mapValues(\.sequence)
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

    /// Your answer to the whole event when it covers its newest invitation.
    private func wholeAnswer(_ answers: [String: InvitationAnswer]) -> InvitationAnswer? {
        guard let main, !main.isCancellation, let whole = answers[""], whole.sequence >= main.sequence else { return nil }
        return whole
    }
}
