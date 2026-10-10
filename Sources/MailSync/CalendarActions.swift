import Foundation
import MailCore
import MailStore

/// Calendar changes, applied to the local store at once and queued for the provider, like `MailActions`.
/// Changes that email guests wait for an undo window (the same as undo send) before they leave. Invitations
/// that are not on Google Calendar are answered by email, through the mail outbox.
public final class CalendarActions: Sendable {
    public let store: MailStore
    private let changed: @Sendable () -> Void
    private let mailChanged: @Sendable () -> Void
    private let calendar: Calendar

    /// An answer that can be undone.
    public struct AnswerRecord: Sendable {
        public let outboxID: Int64
        public let calendarID: String
        public let eventID: String
        public let response: ResponseStatus
        public let previous: ResponseStatus?
        public let summary: String
        /// The answers it replaced, on the event and a series' changed occurrences, put back exactly on undo.
        public var saved: [SavedAnswer] = []
        /// The answer was for one occurrence that had no exception yet.
        public var madeException = false
    }

    /// A create, edit or removal that can be undone. `before` is nil after a create, `after` nil after a removal.
    public struct ChangeRecord: Sendable {
        /// The queued operation; nil for a removal that sent nothing (the event's create had not left).
        public let outboxID: Int64?
        public let before: CalendarEvent?
        public let after: CalendarEvent?
        public let sendUpdates: SendUpdates
        /// The change was to one occurrence that had no exception yet.
        public var madeException = false
        /// For a removal, or a series that ended early: what else it removed or dropped, to put back on undo.
        public var removal: LocalRemoval?
        /// For "this and following": the day the series was cut at (its start in the rule).
        public var splitDay: EventTime?
    }

    /// An answer sent by email that can be undone until the email leaves.
    public struct EmailAnswerRecord: Sendable {
        /// The email in the mail outbox.
        public let outboxID: Int64
        public let response: ResponseStatus
        public let summary: String
        /// The invitation's conversation, where the email's copy shows.
        public let threadID: String
        /// The event answered: its UID, the occurrence key ("" for the whole event), and the SEQUENCE of the version
        /// answered (the newest, which may be newer than the conversation's).
        public let uid: String
        public let recurrenceID: String
        public let sequence: Int
    }

    /// Why an invitation was not answered by email.
    public enum EmailAnswerError: Error, LocalizedError, Equatable {
        /// The meeting was cancelled since, or the organizer took you off it (`MailStore.isWithdrawn`).
        case withdrawn(summary: String)

        public var errorDescription: String? {
            switch self {
            case .withdrawn(let summary): "\(summary) was cancelled, or you were taken off it. Nothing was sent."
            }
        }
    }

    /// `changed` is called after a change was queued (it wakes the calendar sync), `mailChanged` after an answer by
    /// email was queued or taken back (it wakes the mail sync).
    public init(
        store: MailStore, calendar: Calendar = .current, changed: @escaping @Sendable () -> Void = {}, mailChanged: @escaping @Sendable () -> Void = {}
    ) {
        self.store = store
        self.calendar = calendar
        self.changed = changed
        self.mailChanged = mailChanged
    }

    var window: CalendarWindow { CalendarWindow.around(Date(), calendar: calendar) }

    // MARK: - Answers

    /// The stored event an invitation is about: the occurrence it names, or the series or single event.
    /// An invitation to one occurrence that has no exception yet gets that occurrence of the series (not stored).
    public func event(for invitation: Invitation) async throws -> CalendarEvent? {
        // Only your own copies: on a colleague's calendar shown beside yours, "self" is that colleague.
        let primary = try await store.calendars().first(where: \.isPrimary)?.id
        let me = store.selfAddresses
        let events = try await store.events(uid: invitation.uid).filter { event in
            event.calendarID == primary || event.selfAttendee.map { me.contains($0.normalized) } == true
        }
        let main = events.first { $0.recurringEventID == nil && $0.selfAttendee != nil } ?? events.first { $0.recurringEventID == nil }
        if let occurrence = invitation.recurrenceID {
            if let exception = events.first(where: { $0.recurringEventID != nil && ($0.originalStart ?? $0.start).occurrenceKey == occurrence.occurrenceKey }) {
                return exception
            }
            if let main, main.isSeries {
                let original: EventTime = switch (occurrence, main.start) {
                case (.timed(let date, _), .timed(_, let zone)): .timed(date, timeZone: zone)
                default: occurrence
                }
                return main.instance(originalStart: original, start: invitation.start, end: invitation.effectiveEnd)
            }
        }
        return main
    }

    /// Answers one event: a stored event, or an occurrence of a series (stored first as an exception).
    public func answer(_ event: CalendarEvent, response: ResponseStatus, comment: String? = nil, undoWindow: TimeInterval) async throws -> AnswerRecord? {
        var madeException = false
        if event.recurringEventID != nil, try await store.event(calendarID: event.calendarID, id: event.id) == nil {
            try await store.storeLocalEvent(event, window: window, calendar: calendar)
            madeException = true
        }
        guard var record = try await answer(calendarID: event.calendarID, eventID: event.id, response: response, comment: comment, undoWindow: undoWindow) else {
            return nil
        }
        record.madeException = madeException
        return record
    }

    /// Answers an invitation. Nil when the account is not a guest of the event.
    public func answer(calendarID: String, eventID: String, response: ResponseStatus, comment: String? = nil, undoWindow: TimeInterval) async throws -> AnswerRecord? {
        let summary = try await store.event(calendarID: calendarID, id: eventID)?.summary ?? ""
        guard let result = try await store.respond(
            calendarID: calendarID, eventID: eventID, response: response, comment: comment, sendUpdates: .all,
            notBefore: undoWindow > 0 ? Date().addingTimeInterval(undoWindow) : .distantPast
        ) else { return nil }
        changed()
        return AnswerRecord(
            outboxID: result.outboxID, calendarID: calendarID, eventID: eventID, response: response, previous: result.previous, summary: summary,
            saved: result.saved
        )
    }

    /// Takes an answer back: before it left nothing is sent, after it the previous answer is sent.
    public func undo(_ record: AnswerRecord) async throws {
        try await store.revertResponse(
            outboxID: record.outboxID, calendarID: record.calendarID, eventID: record.eventID, previous: record.previous, saved: record.saved,
            dropException: record.madeException, window: window, calendar: calendar
        )
        changed()
    }

    // MARK: - Answers by email

    /// Answers an invitation that is not on Google Calendar by email (iMIP): a reply to the organizer, in the conversation
    /// of the invitation's `mail`, that leaves through the mail outbox after the undo window, like a send. It answers the
    /// newest version of the invitation, which may have come in another conversation (never one from Spam). The answer
    /// is kept here, covering `covering` (the SEQUENCE it answers; for a whole event, `InvitedEvent.coveredSequence`), so
    /// the invitation stops waiting and its pages say what you answered. Nil when the invitation cannot be answered by
    /// email (no organizer to write to, or you organize it) or the account is not known yet. Throws
    /// `EmailAnswerError.withdrawn` when the meeting is off since (cancelled, or you were taken off it): nothing is sent then.
    public func answerByEmail(
        _ invitation: Invitation, mail: MailMessage, response: ResponseStatus, comment: String? = nil, covering: Int? = nil, undoWindow: TimeInterval
    ) async throws -> EmailAnswerRecord? {
        guard let account = try await store.account() else { return nil }
        let invited = try await store.invitedEvent(uid: invitation.uid)
        let invitation = invited.newest(invitation)
        // Cancelled since, as the mail tells it (a cancellation can also be a REQUEST marked cancelled).
        let key = invitation.recurrenceID?.occurrenceKey
        if invited.main?.isCancellation == true || key.flatMap({ invited.changedDates[$0]?.isCancellation }) == true {
            throw EmailAnswerError.withdrawn(summary: invitation.summary)
        }
        if try await store.isWithdrawn(invitation) { throw EmailAnswerError.withdrawn(summary: invitation.summary) }
        let now = Date()
        guard let message = ICalendar.replyMail(
            to: invitation, mail: mail, account: account, selfAddresses: store.selfAddresses, response: response, comment: comment,
            now: now, timeZone: calendar.timeZone
        ) else { return nil }
        let note = comment.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let answer = InvitationAnswer(
            uid: invitation.uid, recurrenceID: invitation.recurrenceID?.occurrenceKey ?? "", response: response, comment: note,
            sequence: max(invitation.sequence, covering ?? invitation.sequence), answeredAt: now
        )
        let copy = MailMessage(
            id: "local-\(UUID().uuidString.lowercased())", threadID: mail.threadID, labelIDs: [SystemLabel.sent], from: message.from,
            to: message.to, subject: message.subject, snippet: HTMLText.snippet(from: message.textBody), date: now, textBody: message.textBody
        )
        let outboxID = try await store.queueInvitationReply(
            InvitationReply(message: message, localMessageID: copy.id, answer: answer, summary: invitation.summary), localCopy: copy,
            notBefore: undoWindow > 0 ? now.addingTimeInterval(undoWindow) : .distantPast
        )
        mailChanged()
        return EmailAnswerRecord(
            outboxID: outboxID, response: response, summary: invitation.summary, threadID: mail.threadID, uid: answer.uid,
            recurrenceID: answer.recurrenceID, sequence: answer.sequence
        )
    }

    /// Takes back an answer by email. Before the email left, nothing is sent and the answer before it is back. After,
    /// the email cannot be unsent and the answer stays, as the organizer has it. Returns true when nothing had left.
    @discardableResult
    public func undo(_ record: EmailAnswerRecord) async throws -> Bool {
        let cancelled = try await store.cancelInvitationReply(outboxID: record.outboxID)
        mailChanged()
        return cancelled
    }

    // MARK: - Events

    /// Creates an event with an ID made here, so a retried create can never make a second event.
    public func create(_ event: CalendarEvent, sendUpdates: SendUpdates, addConference: Bool, undoWindow: TimeInterval) async throws -> ChangeRecord {
        let id = try await store.insertLocalEvent(
            event, sendUpdates: sendUpdates, addConference: addConference,
            notBefore: undoWindow > 0 ? Date().addingTimeInterval(undoWindow) : .distantPast, window: window, calendar: calendar
        )
        changed()
        return ChangeRecord(outboxID: id, before: nil, after: event, sendUpdates: sendUpdates)
    }

    /// Changes an event. For one occurrence of a series, `event` and `previous` are that occurrence
    /// (`CalendarEvent.instance`), and only it changes.
    public func update(_ event: CalendarEvent, from previous: CalendarEvent, sendUpdates: SendUpdates, undoWindow: TimeInterval) async throws -> ChangeRecord {
        let madeException = try await isNewException(previous)
        let id = try await store.updateLocalEvent(
            event, previous: previous, sendUpdates: sendUpdates,
            notBefore: undoWindow > 0 ? Date().addingTimeInterval(undoWindow) : .distantPast, window: window, calendar: calendar
        )
        changed()
        return ChangeRecord(outboxID: id, before: previous, after: event, sendUpdates: sendUpdates, madeException: madeException)
    }

    /// Removes an event; for one occurrence of a series (`CalendarEvent.instance`), only that occurrence.
    /// An event whose create has not left yet is dropped instead, and nothing is sent.
    public func remove(_ event: CalendarEvent, sendUpdates: SendUpdates, undoWindow: TimeInterval) async throws -> ChangeRecord {
        let madeException = try await isNewException(event)
        let removal = try await store.deleteLocalEvent(
            event, sendUpdates: sendUpdates, notBefore: undoWindow > 0 ? Date().addingTimeInterval(undoWindow) : .distantPast, window: window, calendar: calendar
        )
        changed()
        return ChangeRecord(outboxID: removal.outboxID, before: event, after: nil, sendUpdates: sendUpdates, madeException: madeException, removal: removal)
    }

    /// "This and following": ends `series` before one of its days (`day`, its start in the rule) with `recurrence` as its
    /// lines (`Recurrence.split`), and starts `following` on that day as a new series; nil only ends the series. The
    /// series' changed occurrences from that day on go with the days it no longer has, with their changes that had not
    /// left. Both changes wait for the undo window together. Undo the records last first: that takes back the new
    /// series, then the end of the old one.
    public func split(
        _ series: CalendarEvent, at day: EventTime, keeping recurrence: [String], following: CalendarEvent?, sendUpdates: SendUpdates,
        undoWindow: TimeInterval
    ) async throws -> [ChangeRecord] {
        var ended = series
        ended.recurrence = recurrence
        let result = try await store.splitLocalSeries(
            ended, previous: series, at: day, following: following, sendUpdates: sendUpdates,
            addConference: following.map(Self.asksForConference) ?? false,
            notBefore: undoWindow > 0 ? Date().addingTimeInterval(undoWindow) : .distantPast, window: window, calendar: calendar
        )
        changed()
        var end = ChangeRecord(outboxID: result.outboxID, before: series, after: ended, sendUpdates: sendUpdates)
        end.removal = LocalRemoval(exceptions: result.exceptions, waiting: result.waiting)
        end.splitDay = day
        guard let following, let insertID = result.insertOutboxID else { return [end] }
        var start = ChangeRecord(outboxID: insertID, before: nil, after: following, sendUpdates: sendUpdates)
        start.splitDay = day
        return [end, start]
    }

    /// The series that takes over from one day of `series` ("this and following"): the same event under a new ID, new to
    /// the provider (no UID, link or version of its own yet).
    public static func followingSeries(of series: CalendarEvent, id: String = newEventID()) -> CalendarEvent {
        var copy = series
        copy.id = id
        copy.iCalUID = nil
        copy.status = .confirmed
        copy.recurringEventID = nil
        copy.originalStart = nil
        copy.htmlLink = nil
        copy.etag = nil
        copy.updated = nil
        copy.sequence = 0
        return copy
    }

    /// Whether a new series asks the provider for a join link of its own: vimail keeps a link, not the conference behind
    /// it, so a link the provider made cannot be copied. One written in the place or the notes goes along with them.
    static func asksForConference(_ event: CalendarEvent) -> Bool {
        guard let link = event.conferenceURL else { return false }
        return !(event.location ?? "").contains(link) && !(event.details ?? "").contains(link)
    }

    private func isNewException(_ event: CalendarEvent) async throws -> Bool {
        guard event.recurringEventID != nil else { return false }
        return try await store.event(calendarID: event.calendarID, id: event.id) == nil
    }

    /// Undoes a create, edit or removal. Returns true when nothing had reached the provider yet.
    @discardableResult
    public func undo(_ record: ChangeRecord) async throws -> Bool {
        let cancelled = try await store.revertEventChange(
            outboxID: record.outboxID, current: record.after, restore: record.before, sendUpdates: record.sendUpdates,
            dropException: record.madeException, removal: record.removal, window: window, calendar: calendar
        )
        changed()
        return cancelled
    }

    /// A new event ID in Google's alphabet (base32hex: 0-9 and a-v), 26 characters.
    public static func newEventID() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuv")
        var generator = SystemRandomNumberGenerator()
        return String((0..<26).map { _ in alphabet[Int(generator.next() % 32)] })
    }
}
