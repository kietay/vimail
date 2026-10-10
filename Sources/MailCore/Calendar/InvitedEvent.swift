import Foundation

/// One date of an event known from invitation mail.
public struct InvitedDate: Hashable, Sendable {
    public var start: EventTime
    public var end: EventTime
    /// The date's place in its series: `EventTime.occurrenceKey` of its start in the rule. "" for a single event.
    public var key: String
    /// What the mail says about this date: the date's own invitation when it was changed, else the whole event's.
    public var invitation: Invitation

    public init(start: EventTime, end: EventTime, key: String, invitation: Invitation) {
        self.start = start
        self.end = end
        self.key = key
        self.invitation = invitation
    }
}

/// An event as its invitation mail tells it, for invitations that are on no calendar: the newest invitation to the
/// whole event, and the dates that later mail changed or cancelled on their own (RECURRENCE-ID).
///
/// For the whole event and for each date, the newest word counts: the highest SEQUENCE, and of two with the same,
/// the later mail. A date's own word counts over the whole event's unless the event's SEQUENCE is higher (the event
/// changed since). Guests' answers (REPLY) and proposals (COUNTER) are not the organizer's word and change nothing.
public struct InvitedEvent: Hashable, Sendable {
    public var uid: String
    /// The newest invitation to the whole event: a series, a single event, or its cancellation. Nil when the mail is
    /// only about some of its dates.
    public var main: Invitation?
    /// The newest word about each date changed or cancelled on its own, by occurrence key.
    public var changedDates: [String: Invitation]

    /// One event's invitations (those with the first one's UID), oldest mail first.
    public init(_ invitations: [Invitation]) {
        let uid = invitations.first?.uid ?? ""
        var main: Invitation?
        var dates: [String: Invitation] = [:]
        for invitation in invitations where invitation.uid == uid && Self.isOrganizersWord(invitation) {
            if let date = invitation.recurrenceID {
                let key = date.occurrenceKey
                if let known = dates[key], known.sequence > invitation.sequence { continue }
                dates[key] = invitation
            } else if main.map({ $0.sequence <= invitation.sequence }) ?? true {
                main = invitation
            }
        }
        self.uid = uid
        self.main = main
        let floor = main?.sequence ?? .min
        changedDates = dates.filter { $0.value.sequence >= floor }
    }

    /// Invitations grouped by event (UID), in the order the events first appear. Each keeps its invitations' order.
    public static func events(from invitations: [Invitation]) -> [InvitedEvent] {
        var order: [String] = []
        var byUID: [String: [Invitation]] = [:]
        for invitation in invitations {
            if byUID[invitation.uid] == nil { order.append(invitation.uid) }
            byUID[invitation.uid, default: []].append(invitation)
        }
        return order.map { InvitedEvent(byUID[$0] ?? []) }
    }

    /// The dates that overlap [from, to), in order, at most `limit`. A series' dates come from its rule, with the dates
    /// changed on their own at their new times (also those moved in from outside the window) and the cancelled ones left
    /// out. A single event has its own date, as has a series whose rule `Recurrence.occurrences` cannot work out.
    public func dates(from: Date, to: Date, limit: Int = 300, calendar: Calendar = .current) -> [InvitedDate] {
        var dates: [InvitedDate] = []
        var changed = changedDates
        if let main {
            guard !main.isCancellation else { return [] }
            let occurrences = main.recurrence.isEmpty ? nil : Recurrence.occurrences(
                start: main.start, end: main.effectiveEnd, recurrence: main.recurrence, from: from, to: to, calendar: calendar
            )
            if let occurrences {
                for occurrence in occurrences {
                    let key = (occurrence.originalStart ?? occurrence.start).occurrenceKey
                    if let word = changed.removeValue(forKey: key) {
                        if !word.isCancellation { dates.append(InvitedDate(start: word.start, end: word.effectiveEnd, key: key, invitation: word)) }
                    } else {
                        dates.append(InvitedDate(start: occurrence.start, end: occurrence.end, key: key, invitation: main))
                    }
                }
            } else {
                dates.append(InvitedDate(start: main.start, end: main.effectiveEnd, key: "", invitation: main))
                changed = [:]
            }
        }
        // Dates moved in from outside the window, and dates the mail names without the whole event.
        for (key, word) in changed where !word.isCancellation {
            dates.append(InvitedDate(start: word.start, end: word.effectiveEnd, key: key, invitation: word))
        }
        let shown = dates
            .filter { Self.overlaps($0, from: from, to: to, calendar: calendar) }
            .sorted { ($0.start.instant(in: calendar), $0.key) < ($1.start.instant(in: calendar), $1.key) }
        return Array(shown.prefix(max(0, limit)))
    }

    /// The next dates that have not ended at `now`, at most `limit`, looking as far ahead as the calendar keeps
    /// events (400 days). The first is the one to show and to wait for an answer at.
    public func upcoming(now: Date, limit: Int, calendar: Calendar = .current) -> [InvitedDate] {
        dates(from: now, to: now.addingTimeInterval(400 * 86_400), limit: limit, calendar: calendar)
    }

    /// What the mail says about one date (by key): the date's own word when it changed on its own, else the whole event's.
    public func invitation(at key: String) -> Invitation? {
        changedDates[key] ?? main
    }

    /// The invitation an answer is for: the whole event's, so a series is answered as a whole from any of its dates;
    /// the date's own when the mail is only about some dates. Nil when that was cancelled.
    public func invitationToAnswer(at key: String) -> Invitation? {
        guard let invitation = main ?? changedDates[key], !invitation.isCancellation else { return nil }
        return invitation
    }

    /// Invitations, updates and cancellations. Not guests' answers and proposals, nor ADD (its extra dates would read
    /// as the whole event).
    private static func isOrganizersWord(_ invitation: Invitation) -> Bool {
        switch invitation.method {
        case .request, .publish, .cancel: true
        case .reply, .counter, .declineCounter, .refresh, .add: false
        }
    }

    private static func overlaps(_ date: InvitedDate, from: Date, to: Date, calendar: Calendar) -> Bool {
        let start = date.start.instant(in: calendar)
        let end = date.end.instant(in: calendar)
        return start < to && (end > from || (end <= start && start >= from))
    }
}
