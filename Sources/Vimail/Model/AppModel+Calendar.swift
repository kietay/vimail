import AppKit
import MailCore
import MailStore
import MailSync
import VimailKit

/// A group of agenda rows: invitations waiting for an answer, or one day.
struct AgendaSection: Identifiable, Equatable {
    var id: String
    var title: String
    var isWaiting: Bool
    var items: [AgendaItem]
}

/// What an invitation row in the mail list shows next to its labels.
struct InvitationChip: Equatable {
    var text: String
    var colorIndex: Int
}

/// The calendar: invitations in mail (the event page and Y M N R), the calendar view (gc), joining meetings.
extension AppModel {
    // MARK: - Loading

    func listenToCalendar() {
        guard let engine = services.calendarEngine else { return }
        let statusUpdates = engine.statusUpdates
        let events = engine.events
        Task { [weak self] in
            for await status in statusUpdates {
                guard let self, self.services.calendarEngine === engine else { return }
                self.calendarStatus = status
            }
        }
        Task { [weak self] in
            for await event in events {
                guard let self, self.services.calendarEngine === engine else { return }
                switch event {
                case .operationFailed(let reason): self.showToast(reason, isError: true)
                }
            }
        }
    }

    /// Everything that reads the calendar: after a calendar change, a new day, or an account switch.
    func calendarChanged() async {
        calendars = (try? await services.store.calendars()) ?? calendars
        await reloadInvitationChips()
        await reloadNextMeeting()
        await reloadWaitingCount()
        if destination == .calendar { await reloadAgenda() }
        await refreshEventPage()
    }

    var shownCalendarIDs: Set<String> { Set(calendars.filter(\.isSelected).map(\.id)) }

    /// Rows the calendar view lists: shown calendars, and invitations that are only in mail.
    func isShown(_ item: AgendaItem) -> Bool {
        item.calendarID == Self.mailOnlyCalendarID || calendars.isEmpty || shownCalendarIDs.contains(item.calendarID)
    }

    /// Your own time: your shown calendars (a colleague's calendar shown beside yours has their meetings, not yours), and
    /// invitations only in mail that you said yes or maybe to by email. Overlaps, the next meeting, free times and find a
    /// time count only these.
    func isYourTime(_ item: AgendaItem) -> Bool {
        guard item.calendarID != Self.mailOnlyCalendarID else { return [.accepted, .tentative].contains(item.event.selfResponse) }
        guard !calendars.isEmpty else { return true }
        guard calendars.contains(where: { $0.id == item.calendarID && $0.isSelected }) else { return false }
        return isYourCalendar(item.calendarID)
    }

    /// A calendar whose events are your time: your primary calendar, or one you own that is not a colleague's (a
    /// colleague's own calendar, shared with you to manage, has their address as its ID). As `MailStore.yourCalendar`.
    func isYourCalendar(_ id: String) -> Bool {
        guard !calendars.isEmpty else { return true }
        guard let info = calendars.first(where: { $0.id == id }) else { return false }
        return info.isPrimary
            || (info.accessRole == .owner && (id.hasSuffix("calendar.google.com") || services.store.selfAddresses.contains(id.lowercased())))
    }

    /// An event copy that is yours to answer: on your primary calendar, or its "self" guest is one of your addresses. On a
    /// colleague's calendar, even one you manage, "self" is that colleague and an answer would be theirs. As
    /// `CalendarActions.event(for:)`.
    func isYourCopy(_ item: AgendaItem) -> Bool { isYourCopy(item.event) }

    func isYourCopy(_ event: CalendarEvent) -> Bool {
        if calendars.contains(where: { $0.id == event.calendarID && $0.isPrimary }) { return true }
        return event.selfAttendee.map { services.store.selfAddresses.contains($0.normalized) } == true
    }

    /// Invitations waiting for your answer, next first: on your own shown calendars, and those only in mail (each once,
    /// at its first date that waits). The sidebar count and the calendar view's first group are both this list.
    func waitingItems() async -> [AgendaItem] {
        let now = Date()
        // Not connected: the events stored before are out of date, and invitations are answered by email.
        let stored = services.calendarEngine == nil ? []
            : ((try? await services.store.waitingForAnswer()) ?? []).filter { isShown($0) && isYourCopy($0) }
        let mail = await invitationRows(from: now, to: now.addingTimeInterval(400 * 86_400), nextOnly: true)
        return (stored + mail).sorted { $0.start.instant() < $1.start.instant() }
    }

    /// The sidebar's count of invitations waiting for an answer, and the events `invite:pending` finds.
    func reloadWaitingCount() async {
        let items = await waitingItems()
        if items.count != waitingInvitationCount { waitingInvitationCount = items.count }
        let uids = Set(items.compactMap(\.event.iCalUID)).sorted()
        guard uids != waitingInvitationUIDs else { return }
        waitingInvitationUIDs = uids
        // A list or a view searching invite:pending shows the new waiting list.
        if currentQuery.invitation == .pending { await reloadList() }
        if views.contains(where: { $0.pinned && $0.query.invitation == .pending }) { await reloadCounts() }
    }

    /// `query` with what the store needs from the app: for `invite:pending`, the events waiting for your answer; for
    /// `invite:conflict`, those that overlap something else you go to.
    func resolved(_ query: ThreadQuery) -> ThreadQuery {
        var query = query
        switch query.invitation {
        case .pending?: query.waitingInvitationUIDs = waitingInvitationUIDs
        case .conflict?: query.conflictingInvitationUIDs = conflictingInvitationUIDs
        default: break
        }
        return query
    }

    /// The events (UIDs) of invitations with a date in the next 60 days that overlaps something else you go to, for
    /// `invite:conflict`, as the calendar view marks overlaps: your calendars' events and the dates of invitations only in
    /// mail you have not declined, against your time. Worked out when a list or a view searches for it.
    func reloadConflictingInvitations() async {
        let now = Date()
        let end = now.addingTimeInterval(60 * 86_400)
        async let stored = storedAgenda(from: now, to: end)
        let mail = await invitationRows(from: now, to: end)
        let rows = (await stored + mail).filter { row in
            !row.start.isAllDay && row.end.instant() > now && row.event.status != .cancelled && row.event.selfResponse != .declined && row.event.isBusy
        }
        let candidates = rows.filter { $0.calendarID == Self.mailOnlyCalendarID || isYourTime($0) }
        conflictingInvitationUIDs = AgendaItem.overlappingUIDs(candidates, busy: rows.filter(isYourTime)).sorted()
    }

    /// The rows your own time is read from (filter them with `isYourTime`): the stored events, and the dates of
    /// invitations only in mail that you said yes or maybe to by email. In start order.
    func agendaWithMail(from start: Date, to end: Date) async -> [AgendaItem] {
        async let stored = storedAgenda(from: start, to: end)
        let mail = await yesByEmailRows(from: start, to: end)
        let items = await stored
        guard !mail.isEmpty else { return items }
        return (items + mail).sorted { $0.start.instant() < $1.start.instant() }
    }

    /// The stored events from `start` to `end`. None while the calendar is not connected: they are out of date, and every
    /// invitation counts as only in mail.
    func storedAgenda(from start: Date, to end: Date) async -> [AgendaItem] {
        guard services.calendarEngine != nil else { return [] }
        return (try? await services.store.agenda(from: start, to: end)) ?? []
    }

    func reloadNextMeeting() async {
        let now = Date()
        let items = await agendaWithMail(from: now, to: now.addingTimeInterval(30 * 86_400)).filter { item in
            !item.start.isAllDay && item.end.instant() > now && isYourTime(item)
                && item.event.selfResponse != .declined && item.event.status != .cancelled
        }
        // A meeting about to start comes before one still running.
        let starting = items.first { $0.start.instant() >= now && $0.start.instant() < now.addingTimeInterval(5 * 60) }
        let next = starting ?? items.first { $0.start.instant() < now.addingTimeInterval(36 * 3600) }
        if next != nextMeeting { nextMeeting = next }
        // The next meeting with each person, for "Next with" in the reader. Large meetings say little about one person.
        let me = services.store.selfAddresses
        var byPerson: [String: AgendaItem] = [:]
        for item in items where item.event.attendees.count <= 10 {
            let people = item.event.attendees.filter { !$0.isResource }.map(\.normalized) + [item.event.organizer?.normalized].compactMap { $0 }
            for person in people where !me.contains(person) && person != account.normalized && byPerson[person] == nil {
                byPerson[person] = item
            }
        }
        nextMeetingByPerson = byPerson
    }

    /// "Next with Alex Morgan: Mon Oct 12 13:00 · 1:1 with Alex", for the people writing in a conversation, latest first.
    func nextWith(_ thread: MailThread) -> (text: String, item: AgendaItem)? {
        let me = services.store.selfAddresses
        var seen = Set<String>()
        for message in thread.messages.reversed() {
            let person = message.from
            guard !me.contains(person.normalized), seen.insert(person.normalized).inserted else { continue }
            if let item = nextMeetingByPerson[person.normalized], item.end.instant() > Date() {
                return ("Next with \(person.shortName): \(Formatting.eventShort(item.start)) · \(item.event.summary)", item)
            }
        }
        return nil
    }

    /// Clicking "Next with" in the reader: that event in the calendar.
    func openNextWith() {
        guard let thread = currentThread, let item = nextWith(thread)?.item else { return }
        showCalendar(at: Calendar.current.startOfDay(for: item.start.instant()), eventID: item.event.id)
    }

    // MARK: - Invitations in the mail list

    func reloadInvitationChips() async {
        let ids = threads.map(\.id)
        guard !ids.isEmpty, let stored = try? await services.store.latestInvitations(threadIDs: ids) else {
            if !invitationChips.isEmpty { invitationChips = [:] }
            return
        }
        var chips: [String: InvitationChip] = [:]
        for (threadID, file) in stored {
            guard let invitation = file.main else { continue }
            chips[threadID] = await chip(for: invitation, inSpam: file.isSpam)
        }
        if chips != invitationChips { invitationChips = chips }
    }

    /// For an invitation not on Google Calendar, what you answered by email counts (as the calendar view shows it).
    /// `inSpam`: the mail is in Spam, where an invitation is not answered by email.
    private func chip(for invitation: Invitation, inSpam: Bool = false) async -> InvitationChip {
        let time = Formatting.eventShort(invitation.start)
        switch invitation.method {
        case .cancel: return InvitationChip(text: "\(time) · cancelled", colorIndex: 6)
        case .reply:
            let guest = invitation.attendees.first
            return InvitationChip(text: "\(guest?.address.shortName ?? "guest") said \(guest?.response.word ?? "?")", colorIndex: 5)
        case .request:
            if invitation.isCancellation { return InvitationChip(text: "\(time) · cancelled", colorIndex: 6) }
            let event = await calendarEvent(for: invitation)
            var emailed: InvitationAnswer?
            if event == nil, inSpam { return InvitationChip(text: "\(time) · in Spam", colorIndex: 5) }
            if event == nil {
                let known = await mailOnly(uid: invitation.uid, else: invitation)
                let key = invitation.recurrenceID?.occurrenceKey ?? ""
                // What an answer goes to now (the newest version), as Y M N see it.
                let target = known.event.answerTarget(at: key, answers: known.answers)
                var cancelled = target == nil
                if let target { cancelled = (try? await services.store.isWithdrawn(target)) == true }
                if cancelled { return InvitationChip(text: "\(time) · cancelled", colorIndex: 6) }
                emailed = known.event.answer(at: key, answers: known.answers)
            }
            let how = emailed == nil ? "" : " by email"
            switch event?.selfResponse ?? emailed?.response {
            case .accepted?: return InvitationChip(text: "\(time) · yes\(how)", colorIndex: 0)
            case .tentative?: return InvitationChip(text: "\(time) · maybe\(how)", colorIndex: 3)
            case .declined?: return InvitationChip(text: "\(time) · no\(how)", colorIndex: 6)
            default: return InvitationChip(text: "\(time) · needs answer", colorIndex: 3)
            }
        default:
            // A ticket or a booking (PUBLISH), or a guest's proposal: nothing for you to answer.
            return InvitationChip(text: time, colorIndex: 5)
        }
    }

    // MARK: - The event page

    /// Builds the event page of a conversation with an invitation (nil when it has none).
    func loadEventPage(for thread: MailThread) async -> ReaderPayload.EventPage? {
        guard let files = try? await services.store.invitations(threadID: thread.id), let file = files.last, let invitation = file.main else {
            return nil
        }
        let event = await calendarEvent(for: invitation)
        let message = thread.messages.first { $0.id == file.messageID }
        let earlier = (try? await services.store.invitations(uid: invitation.uid)) ?? []
        let previous = earlier.last { $0.messageID != file.messageID && $0.date < file.date && ($0.main?.sequence ?? 0) <= invitation.sequence }?.main
        guard event == nil else { return await eventPage(event: event, invitation: invitation, previous: previous, mail: message) }
        // In Spam: mail there does not count for the event and is not answered (an answer would tell the sender your
        // address works). The page shows the invitation as it is.
        if file.isSpam {
            return await eventPage(event: nil, invitation: invitation, previous: previous, mail: message, inSpam: true)
        }
        // Not on Google Calendar: the event as all its mail tells it, and what you answered by email.
        let known = await mailOnly(uid: invitation.uid, else: invitation)
        let key = invitation.recurrenceID?.occurrenceKey ?? ""
        let target = known.event.answerTarget(at: key, answers: known.answers)
        // Cancelled in another conversation, or removed from your calendar: nothing to answer. What counts is the version
        // an answer goes to now (a meeting cancelled and then sent out again waits).
        var withdrawn = false
        if invitation.method == .request {
            withdrawn = target == nil
            if let target { withdrawn = (try? await services.store.isWithdrawn(target)) == true }
        }
        // The page shows what Y M N answer now: the whole series while it waits as a whole, else the newest word on this
        // mail's date or event. This mail's version, when older, is what changed since.
        var shown = invitation
        var changedFrom = previous
        if invitation.method == .request, let target {
            let seriesWaits = target.recurrenceID == nil && invitation.recurrenceID != nil && known.event.answer(at: key, answers: known.answers) == nil
            let current = seriesWaits ? target : (known.event.invitation(at: key) ?? invitation)
            if current != invitation {
                shown = current
                changedFrom = current.recurrenceID?.occurrenceKey == invitation.recurrenceID?.occurrenceKey ? invitation : nil
            }
        }
        return await eventPage(
            event: nil, invitation: shown, previous: changedFrom, mail: message, invited: known.event,
            answer: known.event.answer(at: shown.recurrenceID?.occurrenceKey ?? "", answers: known.answers), target: target, withdrawn: withdrawn
        )
    }

    /// The page for an agenda row in the calendar view. Of the invitation mail, only what is about this row counts:
    /// the whole event, or this occurrence (a cancelled Tuesday does not cancel the other days). A row that is only in
    /// mail gets the page of its invitation, with what you answered by email.
    func loadEventPage(for item: AgendaItem) async -> ReaderPayload.EventPage {
        let uid = item.event.iCalUID
        let files = uid == nil ? [] : ((try? await services.store.invitations(uid: uid!)) ?? [])
        let key = Self.occurrenceKey(of: item)
        if item.calendarID == Self.mailOnlyCalendarID, let uid {
            // Only in mail: the page the mail gives, for this date, with what you answered by email.
            let known = await mailOnly(uid: uid)
            return await eventPage(
                event: nil, invitation: known.event.invitation(at: key), previous: nil, mail: nil, occurrence: (item.start, item.end),
                hasMail: !files.isEmpty, invited: known.event, answer: known.event.answer(at: key, answers: known.answers),
                target: known.event.answerTarget(at: key, answers: known.answers)
            )
        }
        let invitation = files.reversed().lazy.compactMap { file in
            file.invitations.first { !key.isEmpty && $0.recurrenceID?.occurrenceKey == key } ?? file.invitations.first { $0.recurrenceID == nil }
        }.first
        return await eventPage(event: item.event, invitation: invitation, previous: nil, mail: nil, occurrence: (item.start, item.end), hasMail: !files.isEmpty)
    }

    /// `invited`: the event as all its mail tells it, when it is on no calendar (its dates, moved and cancelled ones too).
    /// `answer`: what you answered by email, which counts while the event is not on Google Calendar; `target`: what Y M N
    /// answer then (`InvitedEvent.answerTarget`). `withdrawn`: the meeting is off since the invitation
    /// (`MailStore.isWithdrawn`), so it shows as cancelled. `inSpam`: the mail is in Spam, so it is not answered.
    func eventPage(
        event: CalendarEvent?, invitation: Invitation?, previous: Invitation?, mail: MailMessage?,
        occurrence: (start: EventTime, end: EventTime)? = nil, hasMail: Bool = false, invited: InvitedEvent? = nil,
        answer: InvitationAnswer? = nil, target: Invitation? = nil, withdrawn: Bool = false, inSpam: Bool = false
    ) async -> ReaderPayload.EventPage {
        let now = Date()
        let me = services.store.selfAddresses
        let emailed = event == nil ? answer : nil
        // A series only in mail: its rule and next dates as all its mail tells them (this mail may be older, or about one
        // of its dates).
        var mailSeries: Invitation?
        var mailDates: [InvitedDate] = []
        if event == nil, let invitation {
            let known = invited ?? InvitedEvent([invitation])
            if let series = known.main, !series.isCancellation, !series.recurrence.isEmpty {
                mailSeries = series
                mailDates = await upcomingDates(of: known, now: now, limit: 8)
            } else if known.main == nil, !invitation.recurrence.isEmpty {
                mailSeries = invitation
                mailDates = await upcomingDates(of: InvitedEvent([invitation]), now: now, limit: 8)
            }
        }
        // Times: the occurrence shown, else the next one of a series, else the invitation's.
        var start = occurrence?.start ?? invitation?.start ?? event?.start ?? .timed(now, timeZone: nil)
        var end = occurrence?.end ?? invitation?.effectiveEnd ?? event?.end ?? start
        if occurrence == nil, let event, event.isSeries || invitation?.recurrence.isEmpty == false,
           let next = try? await services.store.nextOccurrence(calendarID: event.calendarID, eventID: event.recurringEventID ?? event.id, now: now) {
            start = next.start
            end = next.end
        } else if occurrence == nil, invitation?.recurrenceID == nil, let next = mailDates.first {
            // The series' next date; mail about one date shows that date.
            start = next.start
            end = next.end
        }
        let cancelled = withdrawn || invitation?.isCancellation == true || event?.status == .cancelled
        let past = end.instant() < now
        let title = event?.summary ?? invitation?.summary ?? "(no title)"
        let organizer = event?.organizer ?? invitation?.organizer
        let guests = (event?.attendees.isEmpty == false ? event?.attendees : invitation?.attendees) ?? []
        // A colleague's copy (shown beside yours) has their answer, not yours. Not on Google Calendar: only an answer by email
        // counts; the file's own PARTSTAT may be from before a newer invitation.
        let yourCopy = event.map(isYourCopy) ?? false
        // "self" on a colleague's copy is that colleague; in mail, you are your addresses.
        func isYou(_ person: Attendee) -> Bool { me.contains(person.normalized) || (person.isSelf && (event == nil || yourCopy)) }
        // An event shown as free takes nobody's time: it overlaps nothing.
        let busy = event?.isBusy ?? (invitation?.showsAsFree != true)
        let selfResponse = (yourCopy ? event?.selfResponse : nil)
            ?? (event == nil && invitation?.method == .request ? (emailed?.response ?? .needsAction) : invitation?.attendee(matching: me)?.response)

        var page = ReaderPayload.EventPage(kicker: kicker(invitation: invitation, previous: previous, mail: mail), title: title, when: Formatting.eventRange(start, end))
        page.relative = past ? nil : Formatting.relativeDay(start.instant(), now: now)
        page.zone = Formatting.organizerZone(start, end)
        // Described from the series' first date: its next date may have been moved.
        let recurrence = event?.recurrence.isEmpty == false ? event!.recurrence : ((mailSeries ?? invitation)?.recurrence ?? [])
        page.repeats = Recurrence.summary(recurrence, start: event?.start ?? mailSeries?.start ?? start, calendar: .current)
        page.agenda = (event?.details ?? invitation?.details).map { HTMLText.plainText(fromHTML: $0.contains("<") ? $0 : $0.replacingOccurrences(of: "\n", with: "<br>")) }.flatMap { $0.isEmpty ? nil : $0 }
        if let previous, let invitation { page.changes = Self.changes(from: previous, to: invitation) }

        // Only web links: the event's author chooses this text.
        if let url = ICalendar.webLink(event?.conferenceURL) ?? ICalendar.webLink(invitation?.conferenceURL) {
            page.facts.append(.init(label: "Join", value: Formatting.shortLink(url), key: "gj", link: url))
        }
        if let place = event?.location ?? invitation?.location, !place.isEmpty, place != event?.conferenceURL {
            page.facts.append(.init(label: "Where", value: place))
        }
        if let organizer {
            page.facts.append(.init(label: "Organizer", value: isYou(organizer) ? "you" : (organizer.name ?? organizer.email)))
        }
        let people = guests.filter { !$0.isResource }.map { guest in
            // Not on Google Calendar, your entry in the invitation is from before your answer by email, or before a newer
            // invitation: what counts is the answer by email.
            guard event == nil, invitation?.method == .request, guest.isSelf || me.contains(guest.normalized) else { return guest }
            var answered = guest
            answered.response = emailed?.response ?? .needsAction
            return answered
        }
        page.guests = people.map { guest in
            let isMe = isYou(guest)
            let kind = guest.isOrganizer ? "organizer" : guest.response.word
            return .init(name: isMe ? "you" : (guest.name ?? guest.email), answer: guest.isOrganizer ? "organizer" : guest.response.word, kind: kind == "organizer" ? "yes" : kind)
        }
        if people.count > 1 {
            let counts = Dictionary(grouping: people.filter { !$0.isOrganizer }, by: \.response).mapValues(\.count)
            let parts = [ResponseStatus.accepted, .tentative, .declined, .needsAction].compactMap { response in counts[response].map { "\($0) \(response.word)" } }
            page.guestSummary = "\(people.count) guests · " + parts.joined(separator: ", ")
        }

        // State chips and the answer keys. Your own events have nothing to answer.
        let isOrganizer = (yourCopy && event?.organizerIsSelf == true) || organizer.map(isYou) == true
        // An invitation not on the calendar here can still be answered: on Google Calendar when it names you (Google may be
        // keeping it hidden), else by email to its organizer.
        let invitedByMail = event == nil && invitation?.method == .request && services.calendarEngine != nil && invitation?.attendee(matching: me) != nil
        let byEmail = event == nil && invitation?.canBeAnsweredByEmail(by: me) == true
        let answerable = ((yourCopy && event?.selfAttendee != nil) || invitedByMail || byEmail) && !isOrganizer && !past && !cancelled
            && invitation?.method != .reply && !inSpam
        if cancelled {
            page.chips.append(.init(text: "cancelled", kind: "clash"))
        } else if past {
            page.chips.append(.init(text: "past", kind: "muted"))
        } else if isOrganizer {
            page.chips.append(.init(text: "you organize", kind: "ok"))
        } else if let selfResponse, selfResponse != .needsAction {
            page.chips.append(.init(text: "you said \(selfResponse.word)\(emailed == nil ? "" : " by email")", kind: selfResponse == .declined ? "muted" : "ok"))
        } else if inSpam {
            page.chips.append(.init(text: "in Spam", kind: "muted"))
        } else if (yourCopy && event?.selfAttendee != nil) || (event == nil && invitation?.method == .request) {
            page.chips.append(.init(text: "needs your answer", kind: "needs"))
        }
        // A series only in mail is answered as a whole until you have; then a date changed since is answered on its own.
        if answerable, event == nil, mailSeries != nil, let target {
            page.facts.append(.init(label: "Answers", value: target.recurrenceID == nil ? "the whole series" : "this date only"))
        }
        if answerable {
            page.answers = [
                .init(title: "Yes", key: "Y", action: "answerYes", selected: selfResponse == .accepted),
                .init(title: "Maybe", key: "M", action: "answerMaybe", selected: selfResponse == .tentative),
                .init(title: "No", key: "N", action: "answerNo", selected: selfResponse == .declined),
                .init(title: "With a note", key: "R", action: "answerNote", selected: false),
            ]
        }

        // Your day.
        if services.calendarEngine == nil {
            page.dayMessage = services.isGmail ? "Connect Google Calendar to see your day here. Press : and choose “Connect Google Calendar”." : nil
        } else if event == nil, invitation != nil, !cancelled, !past {
            page.dayMessage = emailed == nil ? "This invitation is not on your Google Calendar yet." : "You answered by email. This event is not on your Google Calendar."
            page.day = await dayColumn(for: start, end: end, excluding: nil, uid: invitation?.uid, ghost: true, busy: busy, title: title)
        } else {
            page.day = await dayColumn(
                for: start, end: end, excluding: event, uid: event?.iCalUID ?? invitation?.uid, ghost: !isOrganizer && selfResponse == .needsAction,
                busy: busy, title: title
            )
        }
        if let day = page.day, let clash = day.blocks.first(where: { $0.kind == "clash" }), !cancelled, !past, page.day?.peeking == false {
            page.chips.append(.init(text: "overlaps \(clash.title)", kind: "clash"))
        }
        // A repeating invitation: which of its next 8 dates overlap something you go to.
        if !recurrence.isEmpty, !cancelled, !past, busy, services.calendarEngine != nil, answerable || event == nil {
            let clashes = await seriesClashes(event: event, invitation: invitation, mailDates: mailDates, now: now)
            if !clashes.isEmpty {
                page.chips.append(.init(text: "\(clashes.count) of the next 8 overlap", kind: "clash"))
                page.facts.append(.init(label: "Overlaps", value: clashes.prefix(3).joined(separator: " · ") + (clashes.count > 3 ? " · \(clashes.count - 3) more" : "")))
            }
        }

        if mail != nil, inSpam {
            page.footer = "In Spam, so it is not answered by email. Move it out of Spam first (! in the Spam list)."
            page.original = "Original email from \(mail!.from.displayName)"
        } else if mail != nil {
            page.footer = answerable ? "Archive after answering: \(settings.archiveInvitationsAfterAnswer ? "on" : "off") · gc this event in the calendar" : "gc this event in the calendar"
            page.original = "Original email from \(mail!.from.displayName)\(mail!.attachments.contains { $0.filename.lowercased().hasSuffix(".ics") } ? " · invite.ics" : "")"
        } else if hasMail {
            page.footer = "gm the invitation mail"
        }
        return page
    }

    /// The next 8 dates of a series (from the calendar, or `mailDates` when it is only in mail)
    /// that overlap a busy event you have not declined: "Tue Oct 13 with Design sync".
    private func seriesClashes(event: CalendarEvent?, invitation: Invitation?, mailDates: [InvitedDate], now: Date) async -> [String] {
        var dates: [(start: Date, end: Date)] = []
        if let event {
            let seriesID = event.recurringEventID ?? event.id
            let items = (try? await services.store.occurrences(calendarID: event.calendarID, seriesID: seriesID, from: now, limit: 8)) ?? []
            dates = items.filter { !$0.start.isAllDay }.map { ($0.start.instant(), $0.end.instant()) }
        } else {
            dates = mailDates.filter { !$0.start.isAllDay }.map { ($0.start.instant(), $0.end.instant()) }
        }
        let seriesID = event.map { $0.recurringEventID ?? $0.id }
        let uid = event?.iCalUID ?? invitation?.uid
        guard let first = dates.map(\.start).min(), let last = dates.map(\.end).max() else { return [] }
        // Your yes-by-email dates in one read; your calendars date by date (a monthly series spans months).
        let mail = await yesByEmailRows(from: first, to: last)
        func busy(_ item: AgendaItem) -> Bool {
            isYourTime(item) && !item.start.isAllDay && item.event.isBusy && item.event.status != .cancelled && item.event.selfResponse != .declined
                && (seriesID == nil || (item.seriesID != seriesID && item.event.id != seriesID)) && (uid == nil || item.event.iCalUID != uid)
        }
        var clashes: [String] = []
        for date in dates {
            let mailRows = mail.filter { $0.start.instant() < date.end && $0.end.instant() > date.start }
            if let other = (await storedAgenda(from: date.start, to: date.end) + mailRows).first(where: busy) {
                clashes.append("\(Formatting.dayTitle(date.start)) with \(other.event.summary)")
            }
        }
        return clashes
    }

    private func kicker(invitation: Invitation?, previous: Invitation?, mail: MailMessage?) -> String {
        let from = mail.map { " · \($0.from.displayName) · \(Formatting.readerTime($0.date))" } ?? ""
        guard let invitation else { return "Event" }
        switch invitation.method {
        case .cancel: return "Cancelled" + from
        case .reply:
            let guest = invitation.attendees.first
            return "\(guest?.name ?? guest?.email ?? "A guest") said \(guest?.response.word ?? "?")" + (mail.map { " · \(Formatting.readerTime($0.date))" } ?? "")
        default:
            return (previous != nil || invitation.sequence > 0 ? "Updated invitation" : "Invitation") + from
        }
    }

    /// What an updated invitation changed, in words.
    static func changes(from old: Invitation, to new: Invitation) -> [String] {
        var result: [String] = []
        if old.start != new.start || old.effectiveEnd != new.effectiveEnd {
            result.append("Time: \(Formatting.eventRange(old.start, old.effectiveEnd)) → \(Formatting.eventRange(new.start, new.effectiveEnd))")
        }
        if (old.location ?? "") != (new.location ?? "") { result.append("Place: \(old.location ?? "none") → \(new.location ?? "none")") }
        if old.summary != new.summary { result.append("Title: \(old.summary) → \(new.summary)") }
        let added = Set(new.attendees.map(\.normalized)).subtracting(old.attendees.map(\.normalized))
        if !added.isEmpty { result.append("Added: \(new.attendees.filter { added.contains($0.normalized) }.map { $0.name ?? $0.email }.joined(separator: ", "))") }
        return result
    }

    /// The day column: your day around an event, with the event dashed when you have not answered,
    /// and overlaps in red. `peekDays` shifts the day ({ and }). `uid`: the event's UID: its dates from mail that you said
    /// yes to by email are this event (at the time its newest mail says, which may not be this page's).
    func dayColumn(
        for start: EventTime, end: EventTime, excluding event: CalendarEvent?, uid: String? = nil, ghost: Bool, busy: Bool = true, title: String
    ) async -> ReaderPayload.EventPage.Day {
        let calendar = Calendar.current
        let eventDay = calendar.startOfDay(for: start.instant())
        let day = calendar.date(byAdding: .day, value: peekDays, to: eventDay) ?? eventDay
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let items = await agendaWithMail(from: day, to: dayEnd).filter(isYourTime)
        func minutes(_ date: Date) -> Int { max(0, min(1440, Int(date.timeIntervalSince(day) / 60))) }

        let isSameEvent = { (item: AgendaItem) -> Bool in
            if let uid, item.calendarID == Self.mailOnlyCalendarID, item.event.iCalUID == uid { return true }
            guard let event else { return false }
            let target = event.recurringEventID ?? event.id
            return (item.event.id == event.id || item.seriesID == target || item.event.id == target)
                && item.start.instant() == start.instant()
        }
        var allDay: [String] = []
        var spans: [(title: String, time: String, start: Int, end: Int, kind: String, busy: Bool)] = []
        for item in items where item.event.status != .cancelled {
            if item.start.isAllDay {
                allDay.append(item.event.summary)
                continue
            }
            if isSameEvent(item) && ghost { continue }
            let response = item.event.selfResponse
            let kind = isSameEvent(item) ? "this" : response == .declined ? "declined" : response == .tentative ? "maybe" : response == .needsAction ? "pending" : "mine"
            spans.append((
                item.event.summary, Formatting.time(item.start.instant()), minutes(item.start.instant()),
                max(minutes(item.end.instant()), minutes(item.start.instant()) + 15), kind, item.event.isBusy
            ))
        }
        let showsEvent = peekDays == 0 && !start.isAllDay
        let eventStart = minutes(start.instant())
        let eventEnd = max(minutes(end.instant()), eventStart + 15)
        if showsEvent && ghost {
            spans.append((title, Formatting.time(start.instant()), eventStart, eventEnd, "invite", true))
        }
        // Overlaps with the event (not counting your declined events, or anything shown as free).
        var overlaps: [(title: String, from: Int, to: Int)] = []
        if showsEvent, busy {
            for index in spans.indices where spans[index].busy && ["mine", "maybe", "pending"].contains(spans[index].kind) {
                let from = max(spans[index].start, eventStart)
                let to = min(spans[index].end, eventEnd)
                if from < to {
                    spans[index].kind = "clash"
                    overlaps.append((spans[index].title, from, to))
                }
            }
        }
        let blocks = Self.layout(spans.map { ($0.title, $0.time, $0.start, $0.end, $0.kind) })
        let workStart = settings.workdayStart
        let workEnd = max(settings.workdayEnd, workStart + 60)
        var first = min(workStart, spans.map(\.start).min() ?? workStart)
        var last = max(workEnd, spans.map(\.end).max() ?? workEnd)
        if showsEvent {
            first = min(first, eventStart - 60)
            last = max(last, eventEnd + 60)
        }
        first = max(0, first / 60 * 60)
        last = min(1440, (last + 59) / 60 * 60)

        var note: String?
        var noteKind: String?
        if let overlap = overlaps.first {
            note = "Overlap \(Formatting.minuteTime(overlap.from))–\(Formatting.minuteTime(overlap.to)) with \(overlap.title)" + (overlaps.count > 1 ? " and \(overlaps.count - 1) more" : "")
            noteKind = "clash"
        } else if showsEvent {
            note = "Nothing else at \(Formatting.minuteTime(eventStart))–\(Formatting.minuteTime(eventEnd))"
            noteKind = "ok"
        }
        let today = calendar.isDate(day, inSameDayAs: Date())
        return .init(
            title: Formatting.dayTitle(day), startMinute: first, endMinute: last, allDay: allDay, blocks: blocks, note: note, noteKind: noteKind,
            nowMinute: today ? minutes(Date()) : nil, focusMinute: showsEvent ? eventStart : first, peeking: peekDays != 0
        )
    }

    /// Side-by-side columns for overlapping events.
    static func layout(_ spans: [(title: String, time: String, start: Int, end: Int, kind: String)]) -> [ReaderPayload.EventPage.Block] {
        let sorted = spans.sorted { ($0.start, -$0.end) < ($1.start, -$1.end) }
        var blocks: [ReaderPayload.EventPage.Block] = []
        var cluster: [Int] = []
        var clusterEnd = -1
        var columnEnds: [Int] = []
        func closeCluster() {
            let columns = max(1, columnEnds.count)
            for index in cluster { blocks[index].columns = columns }
            cluster = []
            columnEnds = []
        }
        for span in sorted {
            if span.start >= clusterEnd { closeCluster() }
            let column = columnEnds.firstIndex { $0 <= span.start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(span.end) } else { columnEnds[column] = span.end }
            blocks.append(.init(title: span.title, time: span.time, start: span.start, end: span.end, column: column, columns: 1, kind: span.kind))
            cluster.append(blocks.count - 1)
            clusterEnd = max(clusterEnd, span.end)
        }
        closeCluster()
        return blocks
    }

    /// Rebuilds the page on screen after a calendar change, a peek or a setting change.
    func refreshEventPage() async {
        if destination == .calendar {
            await renderAgendaEvent()
            return
        }
        guard let thread = currentThread, thread.id == cursorID else { return }
        let page = await loadEventPage(for: thread)
        guard thread.id == cursorID else { return }
        if page != eventPages[thread.id] {
            eventPages[thread.id] = page
            rerenderReader()
        }
    }

    // MARK: - Answering

    /// Y, M, N (and R with a note): answers the invitation of the selected conversations, or the agenda row. An invitation
    /// that is not on your Google Calendar, or any while the calendar is not connected, is answered by email.
    func answer(_ response: ResponseStatus, comment: String? = nil) {
        if destination == .calendar {
            answerAgendaItem(response, comment: comment)
            return
        }
        let targets = actionTargets.filter { !$0.hasPrefix("draft:") }
        guard !targets.isEmpty else {
            showToast("Select an invitation first.")
            return
        }
        lastAnswer = response
        Task {
            var records: [CalendarActions.AnswerRecord] = []
            var emailed: [CalendarActions.EmailAnswerRecord] = []
            var answeredThreads: [String] = []
            var notOnCalendar = 0
            var failure: String?
            // A meeting that is off since its invitation: nothing to answer.
            var withdrawn: String?
            // Invitations in Spam are not answered by email.
            var inSpam = 0
            // The version emailed per event (UID and occurrence): two of its mails selected get one email.
            var emailedSequences: [String: Int] = [:]
            for threadID in targets {
                guard let file = try? await services.store.invitations(threadID: threadID).last, let invitation = file.main,
                      invitation.method != .reply, !invitation.isCancellation else { continue }
                // Not on your calendar here: the answer goes where the one-answer rule says (the whole series until it is
                // answered), also when Google has the event hidden and answers it there.
                var target = invitation
                if invitation.method == .request, await calendarEvent(for: invitation) == nil {
                    if file.isSpam {
                        inSpam += 1
                        continue
                    }
                    let known = await mailOnly(uid: invitation.uid, else: invitation)
                    guard let rule = known.event.answerTarget(at: invitation.recurrenceID?.occurrenceKey ?? "", answers: known.answers) else {
                        withdrawn = "\(invitation.summary) was cancelled, so there is nothing to answer."
                        continue
                    }
                    target = rule
                }
                switch await lookUpEvent(for: target) {
                case .found(let event):
                    if let record = try? await services.calendarActions.answer(event, response: response, comment: comment, undoWindow: settings.undoSendSeconds) {
                        records.append(record)
                        answeredThreads.append(threadID)
                    }
                case .missing:
                    // A published event (a ticket, say) has nobody to answer.
                    guard invitation.method == .request else { continue }
                    let key = target.uid + "|" + (target.recurrenceID?.occurrenceKey ?? "")
                    if let sequence = emailedSequences[key], sequence >= target.sequence {
                        answeredThreads.append(threadID)
                        continue
                    }
                    do {
                        guard let record = try await answerByEmail(file, invitation: target, response: response, comment: comment) else {
                            notOnCalendar += 1
                            continue
                        }
                        emailed.append(record)
                        // The newest version was answered, which may be newer than this conversation's.
                        emailedSequences[key] = record.sequence
                        answeredThreads.append(threadID)
                    } catch let error as CalendarActions.EmailAnswerError {
                        withdrawn = error.localizedDescription
                    } catch {
                        AppModel.log.error("Could not queue an answer by email: \(error)")
                        failure = "Could not answer by email: \(error.localizedDescription)"
                    }
                case .failed(let reason):
                    failure = reason
                }
            }
            guard !records.isEmpty || !emailed.isEmpty else {
                if let failure {
                    showToast(failure, isError: true)
                } else if let withdrawn {
                    showToast(withdrawn)
                } else if inSpam > 0 {
                    showToast("This invitation is in Spam, so it is not answered by email. Move it out of Spam first (! in the Spam list).")
                } else if notOnCalendar > 0, services.calendarEngine == nil {
                    offerCalendarConnection()
                } else if notOnCalendar > 0 {
                    showToast("This invitation is not on your Google Calendar and has no organizer to answer by email. Press r to reply to its sender.")
                } else {
                    showToast(targets.count == 1 ? "This conversation has no invitation you can answer here." : "None of these has an invitation you can answer here.")
                }
                return
            }
            var archive: UndoRecord?
            if settings.archiveInvitationsAfterAnswer {
                let inInbox = answeredThreads.filter { id in threads.first { $0.id == id }?.labelIDs.contains(SystemLabel.inbox) ?? false }
                if !inInbox.isEmpty {
                    applyOptimistically(.archive, to: inInbox)
                    clearSelection()
                    archive = try? await services.actions.perform(.archive, threads: inInbox)
                }
            }
            undoStack.append(emailed.isEmpty ? .answer(records, archive: archive) : .answerByEmail(emailed, calendar: records, archive: archive))
            redoStack.removeAll()
            let verb = Self.answerVerb(response)
            let count = records.count + emailed.count
            let how = emailed.isEmpty ? "" : emailed.count == count ? " by email" : ", \(emailed.count) by email"
            let text = count == 1 ? "\(verb)\(how) · \(records.first?.summary ?? emailed[0].summary)" : "\(verb) \(count) invitations\(how)"
            showAnswerToast(text + (archive == nil ? "" : " · archived"), emailed: !emailed.isEmpty)
            await reloadInvitationChips()
            await refreshEventPage()
        }
    }

    /// Answers the invitation of a mail file by email (it is not on Google Calendar), in that mail's conversation. Nil
    /// when it cannot be answered by email: it names no organizer to write to, or you organize it.
    /// `invitation`: the one to answer (`InvitedEvent.answerTarget`), else the file's main one.
    private func answerByEmail(
        _ file: StoredInvitation, invitation: Invitation? = nil, response: ResponseStatus, comment: String?
    ) async throws -> CalendarActions.EmailAnswerRecord? {
        guard let invitation = invitation ?? file.main, let mail = try await services.store.message(id: file.messageID) else { return nil }
        let record = try await services.calendarActions.answerByEmail(
            invitation, mail: mail, response: response, comment: comment, undoWindow: settings.undoSendSeconds
        )
        if let record { AppModel.log.info("Queued an answer by email as outbox #\(record.outboxID) (leaves in \(Int(max(0, settings.undoSendSeconds)))s)") }
        return record
    }

    /// The toast after answering. With answers by email it counts down to when they leave, as after a send.
    private func showAnswerToast(_ text: String, emailed: Bool) {
        let delay = max(0, settings.undoSendSeconds)
        if emailed, delay > 0 {
            showToast(text, undoable: true, countdownTo: Date().addingTimeInterval(delay), countdownLead: "· sends in")
        } else {
            showToast(text, undoable: true)
        }
    }

    enum InvitationLookup {
        case found(CalendarEvent)
        /// Not on your Google Calendar, or the calendar is not connected: the answer goes by email.
        case missing
        /// Google Calendar could not be asked: why, for a toast.
        case failed(String)
    }

    /// The stored event of an invitation. Without the calendar connected, the events stored before are out of date and
    /// cannot be answered there: the invitation counts as not on the calendar.
    func calendarEvent(for invitation: Invitation) async -> CalendarEvent? {
        guard services.calendarEngine != nil else { return nil }
        return try? await services.calendarActions.event(for: invitation)
    }

    /// The calendar's event for an invitation. When none of yours is stored, Google may be keeping it hidden (an
    /// invitation from an unknown sender stays off the calendar until it is answered): it is looked up there.
    /// Without the calendar connected there is none to find.
    func lookUpEvent(for invitation: Invitation) async -> InvitationLookup {
        guard let engine = services.calendarEngine else { return .missing }
        if let event = await calendarEvent(for: invitation) { return .found(event) }
        do {
            _ = try await engine.fetchEvents(uid: invitation.uid)
            guard let event = try await services.calendarActions.event(for: invitation) else { return .missing }
            return .found(event)
        } catch ProviderError.unauthorized {
            return .failed("Signed out of Google Calendar. Sign in again to answer.")
        } catch CalendarProviderError.notConnected {
            return .failed("Google Calendar has not synced yet. Try again in a moment.")
        } catch {
            return .failed("Could not reach Google Calendar to find this invitation. Try again.")
        }
    }

    static func answerVerb(_ response: ResponseStatus) -> String {
        switch response {
        case .accepted: "Accepted"
        case .tentative: "Maybe"
        case .declined: "Declined"
        case .needsAction: "Answer removed"
        }
    }

    func undoAnswer(_ records: [CalendarActions.AnswerRecord], archive: UndoRecord?) {
        Task {
            do {
                // Last first: two answers to one event (two invitation mails) end on the answer before both.
                for record in records.reversed() { try await services.calendarActions.undo(record) }
                if let archive { try await services.actions.undo(archive) }
                showToast("Undone: \(Self.answerVerb(records.first?.response ?? .accepted).lowercased())\(records.count == 1 ? " · \(records[0].summary)" : "")")
                if let first = archive?.threadIDs.first {
                    await reloadList()
                    if threads.contains(where: { $0.id == first }) { cursorID = first }
                }
                await calendarChanged()
            } catch {
                showToast("Could not undo: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Takes back answers by email (each email only before it leaves: once sent it cannot be unsent), the answers on
    /// Google Calendar given with them, and the archive.
    func undoAnswerByEmail(_ emailed: [CalendarActions.EmailAnswerRecord], calendar records: [CalendarActions.AnswerRecord], archive: UndoRecord?) {
        Task {
            do {
                var sent: [CalendarActions.EmailAnswerRecord] = []
                for record in emailed.reversed() {
                    let cancelled = try await services.calendarActions.undo(record)
                    if !cancelled { sent.append(record) }
                }
                for record in records.reversed() { try await services.calendarActions.undo(record) }
                if let archive { try await services.actions.undo(archive) }
                AppModel.log.info("Undo answers by email: \(emailed.count - sent.count) of \(emailed.count) cancelled before they left")
                let answers = emailed.count + records.count
                if sent.isEmpty {
                    let verb = Self.answerVerb(emailed.first?.response ?? .accepted).lowercased()
                    showToast("Undone: \(verb)\(answers == 1 ? " · \(emailed[0].summary)" : ""). No email was sent.")
                } else {
                    let what = sent.count == 1 ? "your answer to \(sent[0].summary) was"
                        : sent.count == emailed.count ? "your \(sent.count) answers by email were" : "\(sent.count) of your answers by email were"
                    let rest = answers > sent.count ? "The others are undone." : "Press Y, M or N to change \(sent.count == 1 ? "it" : "them")."
                    showToast("Too late: \(what) already sent. \(rest)")
                }
                if let first = archive?.threadIDs.first {
                    await reloadList()
                    if threads.contains(where: { $0.id == first }) { cursorID = first }
                }
                await calendarChanged()
            } catch {
                showToast("Could not undo: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// R: asks for a note, then answers with it.
    func answerWithNote() {
        overlay = .picker(.answerNote)
    }

    func offerCalendarConnection() {
        if services.isGmail {
            showToast("Google Calendar is not connected. Press : and choose “Connect Google Calendar”.", isError: true)
        } else {
            showToast("The calendar is not available for this account.", isError: true)
        }
    }

    // MARK: - Peeking at other days

    /// { and }: the day before or after in the day column (mail), or the agenda (calendar).
    func moveDay(_ delta: Int) {
        if destination == .calendar {
            moveAgendaStart(days: delta)
            return
        }
        guard let id = cursorID, eventPages[id] != nil else { return }
        peekDays += delta
        Task { await refreshEventPage() }
    }

    // MARK: - Joining and jumping

    /// gj: the selected meeting's link, or the next meeting's.
    func joinMeeting() {
        var link: String?
        if destination == .calendar {
            link = currentAgendaItem?.event.conferenceURL
        } else if let id = cursorID, let page = eventPages[id] {
            link = page.facts.first { $0.key == "gj" }?.link
        }
        // The next meeting, unless it has ended since the status bar last looked.
        link = link ?? nextMeeting.flatMap { $0.end.instant() > Date() ? $0.event.conferenceURL : nil }
        // Only web links: the event's author chooses this text, and other schemes open other apps.
        guard let link = ICalendar.webLink(link), let url = URL(string: link) else {
            showToast("No meeting link here or in your next meeting.")
            return
        }
        NSWorkspace.shared.open(url)
        showToast("Opening the meeting link…")
    }

    /// gc: the calendar view; from an invitation, at that event.
    func openCalendar() {
        var target: (day: Date, eventID: String?)?
        if destination != .calendar, let thread = currentThread, thread.id == cursorID {
            Task {
                if let file = try? await services.store.invitations(threadID: thread.id).last, let invitation = file.main {
                    let event = await calendarEvent(for: invitation)
                    // A series opens at its next occurrence, not its first; one changed occurrence at its own date.
                    var start = invitation.start.instant()
                    if let event, event.recurringEventID != nil {
                        start = event.start.instant()
                    } else if let event, event.isSeries,
                              let next = try? await services.store.nextOccurrence(calendarID: event.calendarID, eventID: event.id) {
                        start = next.start.instant()
                    } else if event == nil, !invitation.recurrence.isEmpty {
                        // Only in mail: its next date, as the event page shows it.
                        let known = await mailOnly(uid: invitation.uid, else: invitation)
                        if let next = await upcomingDates(of: known.event, now: Date(), limit: 1).first { start = next.start.instant() }
                    }
                    // Rows carry the series' ID for an occurrence not changed yet; a mail-only row is found by its UID.
                    let wanted = event.map { $0.recurringEventID ?? $0.id } ?? "uid:\(invitation.uid)"
                    target = (Calendar.current.startOfDay(for: start), wanted)
                }
                showCalendar(at: target?.day, eventID: target?.eventID)
            }
            return
        }
        showCalendar(at: nil, eventID: nil)
    }

    private func showCalendar(at day: Date?, eventID: String?) {
        let start = Self.agendaStart(showing: day ?? Date())
        // Another fortnight: the old cursor's place means nothing there.
        if start != agendaStart { agendaCursorID = nil }
        agendaStart = start
        pendingAgendaEventID = eventID
        pendingAgendaDay = day
        navigate(to: .calendar)
    }

    /// The first day of a fortnight that shows `day`: today when `day` is in the next two weeks, else that day.
    static func agendaStart(showing day: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: day)
        let lastShown = calendar.date(byAdding: .day, value: 13, to: today) ?? today
        return target >= today && target <= lastShown ? today : target
    }

    /// gm: the invitation mail of the selected event: a row's own mail, else the newest invitation, else any mail about it.
    func openInvitationMail() {
        guard destination == .calendar, let item = currentAgendaItem, let uid = item.event.iCalUID else {
            showToast("Select an event in the calendar (gc) first.")
            return
        }
        Task {
            let files = (try? await services.store.invitations(uid: uid)) ?? []
            // A row only in mail: the mail of the invitation it answers (the series, or a date mailed on its own).
            var invitation: Invitation?
            if item.calendarID == Self.mailOnlyCalendarID {
                let known = await mailOnly(uid: uid)
                invitation = known.event.answerTarget(at: Self.occurrenceKey(of: item), answers: known.answers)
            }
            guard let file = Self.mailFile(of: invitation, in: files) ?? files.last else {
                showToast("No invitation mail for this event.")
                return
            }
            reveal(threadID: file.threadID)
        }
    }

    // MARK: - The calendar view

    var currentAgendaItem: AgendaItem? {
        guard let id = agendaCursorID else { return nil }
        for section in agendaSections {
            if let item = section.items.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    /// Rows in display order, for moving the cursor.
    var agendaRows: [AgendaItem] { agendaSections.flatMap(\.items) }

    /// The calendar ID of agenda rows that come from an invitation in mail, not from a calendar.
    static let mailOnlyCalendarID = "mail"

    /// The dates of invitations only in mail that you said yes or maybe to by email in [start, end), ended ones too: your time.
    func yesByEmailRows(from start: Date, to end: Date) async -> [AgendaItem] {
        await invitationRows(from: start, to: end, endedToo: true).filter { [.accepted, .tentative].contains($0.event.selfResponse) }
    }

    /// Invitations in mail that are on no calendar, as agenda rows ("from mail"): each of their dates in [start, end)
    /// that has not ended (with `endedToo`, also those that have), every date of a repeating one, with you among the
    /// guests and what you answered by email. Those you said yes or maybe to stay after their mail is binned. With
    /// `nextOnly`, the waiting list's rows: one each for those still waiting, at the first date that waits.
    private func invitationRows(from start: Date, to end: Date, nextOnly: Bool = false, endedToo: Bool = false) async -> [AgendaItem] {
        // Not connected: the events stored before are out of date, so every invitation counts as only in mail.
        let ignoring = services.calendarEngine == nil
        guard let events = try? await services.store.mailOnlyEvents(ignoringStoredEvents: ignoring, includingAccepted: !nextOnly),
              !events.isEmpty else { return [] }
        let now = Date()
        let from = endedToo ? start : max(start, now)
        // Repeating invitations are worked out away from the main thread, a few hundred dates at most.
        let dates = await Task.detached(priority: .userInitiated) {
            events.map { known -> [InvitedDate] in
                if nextOnly { return known.event.waitingDate(now: now, answers: known.answers).map { [$0] } ?? [] }
                return known.event.dates(from: from, to: end, limit: 300, calendar: .current)
            }
        }.value
        let me = services.store.selfAddresses
        return zip(events, dates).flatMap { known, dates in
            dates.map { Self.mailOnlyRow($0, uid: known.uid, answer: known.event.answer(at: $0.key, answers: known.answers), me: me, account: account) }
        }
    }

    /// One date of an invitation only in mail, as an agenda row. A series' rows share its ID and carry their date's key,
    /// so each date is a row of its own. You are among the guests, with what you answered by email.
    private static func mailOnlyRow(_ date: InvitedDate, uid: String, answer: InvitationAnswer?, me: Set<String>, account: EmailAddress) -> AgendaItem {
        let invitation = date.invitation
        let id = "mail-\(uid)"
        var attendees = invitation.attendees
        if let index = attendees.firstIndex(where: { me.contains($0.normalized) }) {
            attendees[index].isSelf = true
            attendees[index].response = answer?.response ?? .needsAction
        } else if let answer {
            // Invited through a list: the answer went from your address.
            attendees.append(Attendee(email: account.email, name: account.name, response: answer.response, isSelf: true))
        }
        let event = CalendarEvent(
            id: id, calendarID: mailOnlyCalendarID, iCalUID: uid, summary: invitation.summary, details: invitation.details,
            location: invitation.location, start: date.start, end: date.end, organizer: invitation.organizer,
            attendees: attendees, conferenceURL: invitation.conferenceURL, isBusy: invitation.showsAsFree != true
        )
        return AgendaItem(
            calendarID: mailOnlyCalendarID, event: event, seriesID: date.key.isEmpty ? nil : id, originalStart: date.key, start: date.start, end: date.end
        )
    }

    /// An invitation only in mail, as all its mail tells it (as the calendar view lists it), with your answers by email.
    /// `invitation`, read from one mail, stands in when no mail tells anything of the event (the store has none of it).
    private func mailOnly(uid: String, else invitation: Invitation? = nil) async -> MailOnlyEvent {
        var known = (try? await services.store.mailOnlyEvent(uid: uid)) ?? MailOnlyEvent(event: InvitedEvent([]))
        if known.event.main == nil, known.event.changedDates.isEmpty, let invitation, invitation.uid == uid {
            known.event = InvitedEvent([invitation])
        }
        return known
    }

    /// The next dates of an invitation only in mail, worked out away from the main thread.
    private func upcomingDates(of event: InvitedEvent, now: Date, limit: Int) async -> [InvitedDate] {
        await Task.detached(priority: .userInitiated) { event.upcoming(now: now, limit: limit) }.value
    }

    func reloadAgenda() async {
        let calendar = Calendar.current
        let start = agendaStart
        let end = calendar.date(byAdding: .day, value: 14, to: start) ?? start
        async let dayRows = storedAgenda(from: start, to: end)
        async let mailRows = invitationRows(from: start, to: end)
        let waitingRows = await waitingItems()
        let filter = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ item: AgendaItem) -> Bool {
            guard isShown(item) else { return false }
            guard !filter.isEmpty else { return true }
            let text = ([item.event.summary, item.event.location ?? ""] + item.event.attendees.map { "\($0.name ?? "") \($0.email)" }).joined(separator: " ").lowercased()
            return text.contains(filter)
        }
        let fromMail = await mailRows
        let waiting = waitingRows.filter(matches)
        let items = (await dayRows + fromMail).filter(matches).sorted { $0.start.instant() < $1.start.instant() }
        var sections: [AgendaSection] = []
        if !waiting.isEmpty {
            sections.append(AgendaSection(id: "waiting", title: "Waiting for your answer · \(waiting.count)", isWaiting: true, items: waiting.map { item in
                var copy = item
                copy.originalStart = "waiting:" + item.originalStart
                return copy
            }))
        }
        var day = start
        while day < end {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? end
            let dayItems = items.filter { $0.start.instant() < next && $0.end.instant() > day && !($0.start.isAllDay && $0.end.instant() <= day) }
            if !dayItems.isEmpty {
                let title = (calendar.isDateInToday(day) ? "Today · " : calendar.isDateInTomorrow(day) ? "Tomorrow · " : "") + Formatting.dayTitle(day)
                sections.append(AgendaSection(id: "day-\(DayDate(day, in: calendar))", title: title, isWaiting: false, items: dayItems.map { item in
                    var copy = item
                    copy.originalStart = "\(DayDate(day, in: calendar))|" + item.originalStart
                    return copy
                }))
            }
            day = next
        }
        let previousRows = agendaRows
        if sections != agendaSections { agendaSections = sections }
        let overlaps = Self.overlaps(in: sections.filter { !$0.isWaiting }, yours: isYourTime)
        if overlaps != agendaOverlaps { agendaOverlaps = overlaps }
        reconcileAgendaCursor(previousRows: previousRows)
        await renderAgendaEvent()
    }

    /// Rows whose time overlaps another timed event you have not declined, per day. Only your own calendars count.
    static func overlaps(in sections: [AgendaSection], yours: (AgendaItem) -> Bool = { _ in true }) -> Set<String> {
        var result = Set<String>()
        for section in sections {
            let timed = section.items.filter { !$0.start.isAllDay && $0.event.selfResponse != .declined && $0.event.isBusy && yours($0) }
            for (index, item) in timed.enumerated() {
                for other in timed[(index + 1)...] where other.start.instant() < item.end.instant() && item.start.instant() < other.end.instant() {
                    result.insert(item.id)
                    result.insert(other.id)
                }
            }
        }
        return result
    }

    /// Keeps the cursor on its row after a reload. A row that changed ID (one day of a series that became its own
    /// event) is found again; a row that left (answered, removed) gives its place to the row that took it, as in mail,
    /// so the next key acts on the neighbour and never on an unrelated event.
    private func reconcileAgendaCursor(previousRows: [AgendaItem] = []) {
        let rows = agendaRows
        if let wanted = pendingAgendaEventID {
            let calendar = Calendar.current
            var matching = rows.filter { row in
                !row.originalStart.hasPrefix("waiting:")
                    && (row.event.id == wanted || row.seriesID == wanted || (wanted.hasPrefix("uid:") && row.event.iCalUID == String(wanted.dropFirst(4))))
            }
            // An invitation only in mail is its row from mail, not a colleague's copy of the same meeting.
            if wanted.hasPrefix("uid:"), matching.contains(where: { $0.calendarID == Self.mailOnlyCalendarID }) {
                matching = matching.filter { $0.calendarID == Self.mailOnlyCalendarID }
            }
            // Of a series' rows, the one on the day asked for.
            let onDay = pendingAgendaDay.flatMap { day in matching.first { calendar.isDate($0.start.instant(), inSameDayAs: day) } }
            if let row = onDay ?? matching.first {
                pendingAgendaEventID = nil
                pendingAgendaDay = nil
                agendaCursorID = row.id
                return
            }
        }
        if let id = agendaCursorID, rows.contains(where: { $0.id == id }) { return }
        if let id = agendaCursorID, let index = previousRows.firstIndex(where: { $0.id == id }) {
            let old = previousRows[index]
            let event = old.seriesID ?? old.event.id
            let key = Self.occurrenceKey(of: old)
            let waiting = old.originalStart.hasPrefix("waiting:")
            // The same row, or the same occurrence moved to another day (a day of a series edited on its own).
            if let same = rows.first(where: { $0.calendarID == old.calendarID && $0.originalStart == old.originalStart && ($0.seriesID ?? $0.event.id) == event })
                ?? rows.first(where: {
                    $0.calendarID == old.calendarID && ($0.seriesID ?? $0.event.id) == event && Self.occurrenceKey(of: $0) == key
                        && $0.originalStart.hasPrefix("waiting:") == waiting
                }) {
                agendaCursorID = same.id
                return
            }
            if !rows.isEmpty {
                agendaCursorID = rows[min(index, rows.count - 1)].id
                return
            }
        }
        let now = Date()
        agendaCursorID = rows.first { !$0.originalStart.hasPrefix("waiting:") && $0.end.instant() > now }?.id ?? rows.first?.id
    }

    func moveAgendaCursor(by delta: Int) {
        let rows = agendaRows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == agendaCursorID } ?? 0
        agendaCursorID = rows[min(max(index + delta, 0), rows.count - 1)].id
        Task { await renderAgendaEvent() }
    }

    func moveAgendaCursor(to index: Int) {
        let rows = agendaRows
        guard !rows.isEmpty else { return }
        agendaCursorID = rows[min(max(index, 0), rows.count - 1)].id
        Task { await renderAgendaEvent() }
    }

    func selectAgendaItem(_ id: String) {
        agendaCursorID = id
        focus = .list
        Task { await renderAgendaEvent() }
    }

    /// { } [ ] t: the agenda's first day.
    func moveAgendaStart(days: Int) {
        let calendar = Calendar.current
        agendaStart = calendar.date(byAdding: .day, value: days, to: agendaStart) ?? agendaStart
        agendaCursorID = nil
        Task { await reloadAgenda() }
    }

    func agendaToday() {
        agendaStart = Calendar.current.startOfDay(for: Date())
        agendaCursorID = nil
        Task { await reloadAgenda() }
    }

    func renderAgendaEvent() async {
        guard destination == .calendar else { return }
        guard let item = currentAgendaItem else {
            reader.render(.empty(agendaSections.isEmpty ? "Nothing on your calendar in these two weeks." : "Select an event", dark: theme.palette.isDark))
            return
        }
        let page = await loadEventPage(for: item)
        guard item.id == agendaCursorID, destination == .calendar else { return }
        var payload = ReaderPayload()
        payload.dark = theme.palette.isDark
        // A render of the row already on screen keeps its scroll position.
        payload.threadID = "event:\(item.id)"
        payload.subject = item.event.summary
        payload.showHints = settings.alwaysShowKeyHints
        payload.event = page
        reader.render(payload)
    }

    /// Y M N R in the calendar view. A repeating invitation not answered yet is answered as a whole (that is the
    /// invitation); once answered, a day's row answers only that day ("can't make Tuesday's standup").
    /// `thisDayOnly`: answer only this row's day of a series, answered or not (# declines one day).
    /// An invitation that is only in mail, and not on Google Calendar either, is answered by email.
    private func answerAgendaItem(_ response: ResponseStatus, comment: String?, thisDayOnly: Bool = false) {
        guard let item = currentAgendaItem else { return }
        lastAnswer = response
        let isWaiting = item.originalStart.hasPrefix("waiting:")
        Task {
            // The event to answer on its own: a changed day of a series, one day of a series, or the event behind an
            // invitation that is only in mail (Google may keep it hidden until it is answered). Nil: the row's event.
            var target: CalendarEvent?
            var oneDay = false
            if item.calendarID == Self.mailOnlyCalendarID {
                // Any date of a series answers the series (that is the invitation); a date the mail names on its own, that date.
                guard let uid = item.event.iCalUID else { return }
                let known = await mailOnly(uid: uid)
                let key = Self.occurrenceKey(of: item)
                guard let invitation = known.event.answerTarget(at: key, answers: known.answers) else {
                    // The mail changed since the list was drawn.
                    showToast((known.event.main ?? known.event.changedDates[key]) == nil ? "No invitation mail for this event." : "The organizer cancelled this event.")
                    return
                }
                switch await lookUpEvent(for: invitation) {
                case .found(let event):
                    target = event
                    oneDay = invitation.recurrenceID != nil
                case .missing:
                    let files = (try? await services.store.invitations(uid: uid)) ?? []
                    guard let file = Self.mailFile(of: invitation, in: files) else {
                        showToast("No invitation mail for this event.")
                        return
                    }
                    await answerAgendaItemByEmail(file, invitation: invitation, response: response, comment: comment)
                    return
                case .failed(let reason):
                    showToast(reason, isError: true)
                    return
                }
            } else if services.calendarEngine == nil {
                offerCalendarConnection()
                return
            } else if !isYourCopy(item) {
                // There "self" is the calendar's owner, even on a calendar you manage: an answer would be theirs.
                showToast("This event is on someone else's calendar. Answer it on yours.")
                return
            } else if let seriesID = item.event.recurringEventID {
                // A changed day of a series. While the series itself waits for an answer, the answer is for the series
                // (that is the invitation); once it is answered, or for # on one day, only this day.
                let series = try? await services.store.event(calendarID: item.calendarID, id: seriesID)
                if thisDayOnly || series?.selfAttendee == nil || series?.selfResponse != .needsAction {
                    target = item.event
                    oneDay = true
                }
            } else if item.seriesID != nil, thisDayOnly || (!isWaiting && item.event.selfResponse.map { $0 != .needsAction } == true) {
                target = await occurrenceEvent(for: item)
                oneDay = target != nil
            }
            let answer: CalendarActions.AnswerRecord?
            if let target {
                answer = try? await services.calendarActions.answer(target, response: response, comment: comment, undoWindow: settings.undoSendSeconds)
            } else {
                answer = try? await services.calendarActions.answer(
                    calendarID: item.calendarID, eventID: item.answerTargetID, response: response, comment: comment, undoWindow: settings.undoSendSeconds
                )
            }
            guard let record = answer else {
                showToast("You are not a guest of this event.")
                return
            }
            var archive: UndoRecord?
            if !oneDay, settings.archiveInvitationsAfterAnswer, let uid = item.event.iCalUID,
               let files = try? await services.store.invitations(uid: uid) {
                let inbox = Array(Set(files.map(\.threadID)))
                archive = try? await services.actions.perform(.archive, threads: inbox)
            }
            undoStack.append(.answer([record], archive: archive))
            redoStack.removeAll()
            let what = oneDay ? "\(record.summary) on \(Formatting.dayTitle(item.start.instant())) only" : record.summary
            showToast("\(Self.answerVerb(response)) · \(what)" + (archive == nil ? "" : " · invitation archived"), undoable: true)
        }
    }

    /// The calendar view's answer to an invitation that is only in mail and not on Google Calendar: by email, in the
    /// conversation of `file`, the mail that brought `invitation`.
    private func answerAgendaItemByEmail(_ file: StoredInvitation, invitation: Invitation, response: ResponseStatus, comment: String?) async {
        let record: CalendarActions.EmailAnswerRecord
        do {
            guard let queued = try await answerByEmail(file, invitation: invitation, response: response, comment: comment) else {
                showToast("This invitation is not on your Google Calendar and has no organizer to answer by email. Press gm to reply to its mail.")
                return
            }
            record = queued
        } catch let error as CalendarActions.EmailAnswerError {
            showToast(error.localizedDescription)
            return
        } catch {
            AppModel.log.error("Could not queue an answer by email: \(error)")
            showToast("Could not answer by email: \(error.localizedDescription)", isError: true)
            return
        }
        var archive: UndoRecord?
        // An answer to one date leaves the event's mail in place: its other dates may still wait.
        if settings.archiveInvitationsAfterAnswer, invitation.recurrenceID == nil, let uid = file.main?.uid,
           let files = try? await services.store.invitations(uid: uid) {
            archive = try? await services.actions.perform(.archive, threads: Array(Set(files.map(\.threadID))))
        }
        undoStack.append(.answerByEmail([record], calendar: [], archive: archive))
        redoStack.removeAll()
        showAnswerToast("\(Self.answerVerb(response)) by email · \(record.summary)" + (archive == nil ? "" : " · invitation archived"), emailed: true)
    }

    /// The mail of `invitation` (the one a row only in mail answers), else the newest invitation (REQUEST) of its event.
    /// Not a later cancellation of one day, or someone's answer.
    /// Mail you kept comes before mail in Trash (an update you binned still counts for the dates); never mail in Spam.
    static func mailFile(of invitation: Invitation?, in files: [StoredInvitation]) -> StoredInvitation? {
        func exact(_ pool: [StoredInvitation]) -> StoredInvitation? {
            guard let invitation else { return nil }
            let key = invitation.recurrenceID?.occurrenceKey
            return pool.last { file in
                file.invitations.contains { $0.uid == invitation.uid && $0.recurrenceID?.occurrenceKey == key && $0.sequence == invitation.sequence }
            }
        }
        func request(_ pool: [StoredInvitation]) -> StoredInvitation? { pool.last { $0.main?.method == .request } }
        // Never mail in Spam: it does not count, and an answer there would tell the sender your address works.
        let usable = files.filter { !$0.isSpam }
        let kept = usable.filter { !$0.isBinned }
        return exact(kept) ?? request(kept) ?? exact(usable) ?? request(usable)
    }

    /// An agenda row's place in its series ("20261012T163000Z"), without the row's section prefix; "" for single events.
    static func occurrenceKey(of item: AgendaItem) -> String {
        var key = item.originalStart
        if key.hasPrefix("waiting:") { key.removeFirst("waiting:".count) }
        if let bar = key.lastIndex(of: "|") { key = String(key[key.index(after: bar)...]) }
        return key
    }

    /// The row's occurrence of its series as its own event, to change or answer that day alone. Nil for single events.
    func occurrenceEvent(for item: AgendaItem) async -> CalendarEvent? {
        guard let seriesID = item.seriesID else { return nil }
        if item.event.recurringEventID != nil { return item.event }
        guard let series = (try? await services.store.event(calendarID: item.calendarID, id: seriesID)) ?? (item.event.id == seriesID ? item.event : nil),
              let original = EventTime(occurrenceKey: Self.occurrenceKey(of: item), timeZone: series.start.timeZone) else { return nil }
        return series.instance(originalStart: original, start: item.start, end: item.end)
    }

    /// r and a in the calendar: email the organizer, or everyone invited.
    func emailGuests(all: Bool) {
        guard let event = currentAgendaItem?.event else { return }
        let me = services.store.selfAddresses
        var recipients: [EmailAddress] = []
        if all {
            recipients = event.attendees.filter { !$0.isResource && !me.contains($0.normalized) && !$0.isSelf }.map(\.address)
        } else if let organizer = event.organizer, !organizer.isSelf, !me.contains(organizer.normalized) {
            recipients = [organizer.address]
        }
        guard !recipients.isEmpty else {
            showToast(all ? "No other guests." : "You organize this event. Press a to email the guests.")
            return
        }
        openCompose(Draft(to: recipients, subject: event.summary))
    }

    /// Enter in the calendar: your own events open in the editor; others, and invitations only in mail, focus the reader.
    func openAgendaItem() {
        guard let item = currentAgendaItem else { return }
        if item.calendarID != Self.mailOnlyCalendarID, item.event.organizerIsSelf,
           calendars.first(where: { $0.id == item.calendarID })?.canEdit ?? true, services.calendarCanChange {
            editEvent(item)
        } else {
            focus = .reader
        }
    }

    /// # in the calendar: cancels your own event (guests are told after the undo window), or declines an invitation.
    /// On a repeating event, only this occurrence; the editor (↵, then ⌘E and ⌘⇧⌫) removes the series, or this day
    /// and the ones after it.
    func removeAgendaEvent() {
        guard let item = currentAgendaItem else { return }
        // An invitation only in mail: # declines it (it is looked up on Google Calendar first, else declined by email).
        if item.calendarID == Self.mailOnlyCalendarID {
            answerAgendaItem(.declined, comment: nil)
            return
        }
        guard services.calendarCanChange else {
            showToast("This calendar is read-only here.", isError: true)
            return
        }
        if item.event.selfAttendee != nil, !item.event.organizerIsSelf {
            // On a day of a series, only that day is declined.
            answerAgendaItem(.declined, comment: nil, thisDayOnly: !item.originalStart.hasPrefix("waiting:"))
            return
        }
        guard calendars.first(where: { $0.id == item.calendarID })?.canEdit ?? true else {
            showToast("You cannot change events on this calendar.")
            return
        }
        Task {
            if item.seriesID != nil, let occurrence = await occurrenceEvent(for: item) {
                removeEvent(occurrence)
            } else {
                removeEvent((try? await services.store.event(calendarID: item.calendarID, id: item.event.id)) ?? item.event)
            }
        }
    }

    /// Removes an event, or one occurrence of a series (`CalendarEvent.instance`). Guests are told after the undo window.
    func removeEvent(_ event: CalendarEvent) {
        let hasGuests = event.attendees.contains { !$0.isSelf && !$0.isResource }
        let name = event.recurringEventID == nil ? "“\(event.summary)”" : "“\(event.summary)” on \(Formatting.dayTitle(event.start.instant()))"
        Task {
            do {
                let record = try await services.calendarActions.remove(event, sendUpdates: hasGuests ? .all : .none, undoWindow: hasGuests ? settings.undoSendSeconds : 0)
                undoStack.append(.eventChange(record))
                redoStack.removeAll()
                showToast(hasGuests ? "Cancelling \(name)" : "Removed \(name).", undoable: true,
                          countdownTo: hasGuests ? Date().addingTimeInterval(settings.undoSendSeconds) : nil)
            } catch {
                showToast("Could not remove the event: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Ends a series the day before `occurrence` ("this and following", then ⌘⇧⌫ in the editor): that day and the ones
    /// after it go. Guests are told after the undo window.
    func endSeries(_ series: CalendarEvent, keeping recurrence: [String], from occurrence: CalendarEvent) {
        let hasGuests = series.attendees.contains { !$0.isSelf && !$0.isResource }
        let name = "“\(series.summary)” from \(Formatting.dayTitle(occurrence.start.instant())) on"
        Task {
            do {
                let records = try await services.calendarActions.split(
                    series, at: occurrence.originalStart ?? occurrence.start, keeping: recurrence, following: nil,
                    sendUpdates: hasGuests ? .all : .none, undoWindow: hasGuests ? settings.undoSendSeconds : 0
                )
                undoStack.append(.eventChanges(records))
                redoStack.removeAll()
                showToast(hasGuests ? "Cancelling \(name)" : "Removed \(name).", undoable: true,
                          countdownTo: hasGuests ? Date().addingTimeInterval(settings.undoSendSeconds) : nil)
            } catch {
                showToast("Could not remove the events: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Undoes calendar changes made together, last first: "this and following" ended a series, and started the one
    /// that took over unless it was a removal.
    func undoEventChanges(_ records: [CalendarActions.ChangeRecord]) {
        Task {
            do {
                for record in records.reversed() { try await services.calendarActions.undo(record) }
                let series = records.first?.before ?? records.first?.after
                let day = records.first?.splitDay.map { " from \(Formatting.dayTitle($0.instant())) on" } ?? ""
                let name = "“\(series?.summary ?? "event")”\(day)"
                showToast(records.contains { $0.before == nil } ? "Undone: the change to \(name)." : "Undone: \(name) is back.")
            } catch {
                showToast("Could not undo: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func undoEventChange(_ record: CalendarActions.ChangeRecord) {
        Task {
            do {
                let cancelled = try await services.calendarActions.undo(record)
                let event = record.before ?? record.after
                let day = event?.recurringEventID == nil ? "" : " on \(Formatting.dayTitle((event?.originalStart ?? event?.start)?.instant() ?? Date()))"
                let name = "“\(event?.summary ?? "event")”\(day)"
                switch (record.before, record.after) {
                case (nil, _?): showToast(cancelled ? "Undone: \(name) was not created." : "Undone: \(name) removed again.")
                case (_?, nil): showToast("Undone: \(name) is back.")
                default: showToast("Undone: the change to \(name).")
                }
            } catch {
                showToast("Could not undo: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Connecting the calendar

    /// Signs in again with calendar access (same account, same local mail).
    func connectCalendar() {
        guard services.isGmail else {
            showToast("The dummy account has its calendar already. Press gc.")
            return
        }
        connectGmail()
    }
}

extension Formatting {
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE MMM d"
        return formatter
    }()

    private static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func dayTitle(_ date: Date) -> String { dayFormat.string(from: date) }
    static func time(_ date: Date) -> String { hourMinute.string(from: date) }
    static func minuteTime(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60 % 24, minutes % 60) }

    /// "Mon Oct 12 · 14:00–14:45", "Mon Oct 12 · all day", "Fri Oct 16 – Sun Oct 18".
    static func eventRange(_ start: EventTime, _ end: EventTime) -> String {
        let calendar = Calendar.current
        switch (start, end) {
        case (.allDay(let first), .allDay(let after)):
            let last = after.adding(days: -1, in: calendar)
            return last <= first ? "\(dayTitle(first.start(in: calendar))) · all day" : "\(dayTitle(first.start(in: calendar))) – \(dayTitle(last.start(in: calendar)))"
        default:
            let from = start.instant(in: calendar)
            let to = end.instant(in: calendar)
            if calendar.isDate(from, inSameDayAs: to) || to.timeIntervalSince(from) < 86_400 && calendar.dateComponents([.hour, .minute], from: to) == DateComponents(hour: 0, minute: 0) {
                return "\(dayTitle(from)) · \(time(from))–\(time(to))"
            }
            return "\(dayTitle(from)) \(time(from)) – \(dayTitle(to)) \(time(to))"
        }
    }

    /// "Mon 14:00", or "Oct 12" for an all-day event, for list chips.
    static func eventShort(_ start: EventTime) -> String {
        switch start {
        case .allDay(let day): return dayTitle(day.start()).split(separator: " ").dropFirst().joined(separator: " ")
        case .timed(let date, _):
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
            let day = days == 0 ? "today" : days == 1 ? "tomorrow" : (0..<7).contains(days) ? String(dayTitle(date).prefix(3)) : String(dayTitle(date).dropFirst(4))
            return "\(day) \(time(date))"
        }
    }

    /// "in 3 days", "tomorrow", "today", "in 2 hours", "now".
    static func relativeDay(_ date: Date, now: Date = Date()) -> String? {
        let calendar = Calendar.current
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes <= 0 && minutes > -60 { return "now" }
        if minutes < 0 { return nil }
        if minutes < 60 { return "in \(minutes) min" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days == 0 { return minutes < 180 ? "in \(minutes / 60) h \(minutes % 60) min" : "today" }
        if days == 1 { return "tomorrow" }
        if days < 14 { return "in \(days) days" }
        return "in \(days / 7) weeks"
    }

    /// "11:00–11:45 Europe/London" when the event's zone shows other times than yours.
    static func organizerZone(_ start: EventTime, _ end: EventTime) -> String? {
        guard case .timed(let from, let zoneID?) = start, let zone = TimeZone(identifier: zoneID),
              zone.secondsFromGMT(for: from) != TimeZone.current.secondsFromGMT(for: from) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: from))–\(formatter.string(from: end.instant())) \(zoneID.replacingOccurrences(of: "_", with: " "))"
    }

    /// "meet.google.com/abc-defg-hij": a link without its scheme and query.
    static func shortLink(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host else { return link }
        return host + url.path
    }

    /// "in 12 min", "in 1 h 5 min", "now".
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        return "in \(minutes / 60) h \(minutes % 60) min"
    }
}
