import AppKit
import MailCore
import MailStore
import MailSync
import Observation

/// What the editor holds, kept when esc closes it with changes (like a mail draft).
struct EventDraft: Codable, Equatable {
    var title: String
    var when: String
    var guests: String
    var location: String
    var calendarID: String
    var repeats: String
    var addConference: Bool
    var details: String
    var scope: EventEditorModel.Scope
}

/// The event editor's fields (Tab from quick add, or Enter on your own event in the calendar).
@MainActor
@Observable
final class EventEditorModel {
    /// What a change on one day of a series changes: that day, that day and the ones after it, or the whole series.
    enum Scope: String, Codable, Hashable { case thisEvent, thisAndFollowing, allEvents }

    /// The event being changed (the series for a repeating event); nil for a new event.
    let original: CalendarEvent?
    /// One occurrence of a series opened from the calendar, as its own event (`CalendarEvent.instance`).
    let occurrence: CalendarEvent?
    /// Where "this and following" cuts the series on this day. Nil when it cannot be worked out on the Mac (a COUNT
    /// only Google can count), or when the editor is not on one day of a series.
    let split: Recurrence.Split?
    var title: String
    /// Typed like quick add: "fri 12:30-13:30", "oct 16 all day".
    var when: String
    /// Names or addresses, separated by commas.
    var guests: String
    var location: String
    var calendarID: String
    /// "weekly", "every tue", "daily until dec 18"; empty for a single event.
    var repeats: String
    var addConference: Bool
    var details: String
    /// This event, this and following, or all events, for an occurrence of a series. When shows this occurrence's times
    /// in every case: for all events, a new time moves every event by the same change.
    var scope: Scope
    /// The times When showed on opening (this occurrence's, for a series), kept exactly while When is unchanged.
    let shownStart: EventTime?
    let shownEnd: EventTime?
    /// When as it was opened.
    let openedWhen: String
    /// The repeat rule as stored, kept while the Repeat field is unchanged.
    let originalRecurrence: [String]
    let originalRepeats: String
    /// False when Repeats cannot say the stored rule exactly ("monthly on the second Tuesday"): it is shown, not edited.
    let repeatsEditable: Bool
    /// The description as stored (often HTML): kept as it is while Notes is unchanged.
    let originalDetails: String?
    /// The fields as they were opened, to tell whether esc keeps a draft and which fields changed.
    @ObservationIgnored private var opened: EventDraft?

    /// Find a time: guests' busy times by address. People who do not share theirs are missing.
    var guestBusy: [String: [DateInterval]] = [:]
    /// Your own busy times, without this event.
    var ownBusy: [DateInterval] = []
    /// Why guests' busy times are missing.
    var busyNote: String?
    var busyLoading = false
    /// The guests and days the busy times were loaded for.
    @ObservationIgnored var busyKey = ""

    init(original: CalendarEvent?, occurrence: CalendarEvent? = nil, title: String, when: String, shownStart: EventTime? = nil,
         shownEnd: EventTime? = nil, guests: String, location: String, calendarID: String, repeats: String, recurrence: [String],
         repeatsEditable: Bool = true, addConference: Bool, details: String, originalDetails: String? = nil) {
        self.original = original
        self.occurrence = occurrence
        self.title = title
        self.when = when
        self.shownStart = shownStart
        self.shownEnd = shownEnd
        openedWhen = when
        self.guests = guests
        self.location = location
        self.calendarID = calendarID
        self.repeats = repeats
        self.addConference = addConference
        self.details = details
        scope = occurrence == nil ? .allEvents : .thisEvent
        if let occurrence, let original {
            split = Recurrence.split(
                recurrence: original.recurrence, seriesStart: original.start, at: occurrence.originalStart ?? occurrence.start, calendar: .current
            )
        } else {
            split = nil
        }
        originalRecurrence = recurrence
        originalRepeats = repeats
        self.repeatsEditable = repeatsEditable
        self.originalDetails = originalDetails
        opened = draft
    }

    var isNew: Bool { original == nil }
    /// Changes go to one occurrence only.
    var changesOneOccurrence: Bool { occurrence != nil && scope == .thisEvent }
    /// The scope a save or a removal uses: "this and following" on the series' first day is all events.
    var appliedScope: Scope { scope == .thisAndFollowing && split == .wholeSeries ? .allEvents : scope }
    /// The draft key: the occurrence's ID for one day of a series (each day keeps its own), the event's, or "new".
    var draftID: String { occurrence?.id ?? original?.id ?? "new" }

    var draft: EventDraft {
        EventDraft(
            title: title, when: when, guests: guests, location: location, calendarID: calendarID, repeats: repeats,
            addConference: addConference, details: details, scope: scope
        )
    }

    var hasChanges: Bool { draft != opened }

    /// A field differs from how the editor opened.
    func changed(_ field: KeyPath<EventDraft, String>) -> Bool {
        opened.map { $0[keyPath: field] != draft[keyPath: field] } ?? true
    }

    /// Something was typed in a field (the scope alone is no change).
    var fieldsChanged: Bool {
        [\EventDraft.title, \.when, \.guests, \.location, \.repeats, \.details].contains { changed($0) }
    }
    /// The times as opened, while When is unchanged: they may say more than When can (seconds, a zone, a long event).
    var keptTimes: (start: EventTime, end: EventTime)? {
        guard let shownStart, let shownEnd, when.trimmingCharacters(in: .whitespaces) == openedWhen.trimmingCharacters(in: .whitespaces) else { return nil }
        return (shownStart, shownEnd)
    }
    /// Esc keeps a draft: a new event with anything typed, or an event with changes.
    var keepsDraft: Bool {
        guard isNew else { return hasChanges }
        return ![title, when, guests, location, details].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// ⌘E: this event, this and following, all events, in turn.
    func cycleScope() {
        scope = switch scope {
        case .thisEvent: .thisAndFollowing
        case .thisAndFollowing: .allEvents
        case .allEvents: .thisEvent
        }
    }

    func restore(_ draft: EventDraft) {
        if occurrence != nil { scope = draft.scope }
        title = draft.title
        when = draft.when
        guests = draft.guests
        location = draft.location
        calendarID = draft.calendarID
        repeats = draft.repeats
        addConference = draft.addConference
        details = draft.details
    }
}

/// Creating and editing events: quick add (C) and the event editor.
extension AppModel {
    // MARK: - Quick add

    /// C: a new event. On a conversation it starts with the subject and the people in it;
    /// in the calendar view, on the selected day.
    func newEvent() {
        guard services.calendarEngine != nil else {
            offerCalendarConnection()
            return
        }
        guard services.calendarCanChange else {
            showToast("Calendar access is read only here, so events cannot be created.", isError: true)
            return
        }
        quickAddContacts = [:]
        quickAddDay = nil
        quickAddDraft = nil
        Task {
            if let saved = await loadDraft(id: "new"), overlay == .quickAdd { quickAddDraft = saved }
        }
        if destination == .calendar, let item = currentAgendaItem, !item.originalStart.hasPrefix("waiting:") {
            quickAddDay = Calendar.current.startOfDay(for: item.start.instant())
            quickAddText = ""
        } else if destination != .calendar, let thread = currentThread, thread.id == cursorID {
            quickAddText = conversationPrefill(thread)
        } else {
            quickAddText = ""
        }
        overlay = .quickAdd
        updateQuickAdd()
    }

    /// "Q3 plan with Alex, Jamie ": the subject without Re:/Fwd:, and the people in the conversation.
    private func conversationPrefill(_ thread: MailThread) -> String {
        let me = services.store.selfAddresses
        var people: [EmailAddress] = []
        for message in thread.messages {
            for address in [message.from] + message.to + message.cc where !me.contains(address.normalized) && !people.contains(where: { $0.normalized == address.normalized }) {
                people.append(address)
            }
        }
        // Mailing lists and no-reply senders are not guests.
        people = people.filter { !$0.email.lowercased().contains("noreply") && !$0.email.lowercased().contains("no-reply") }
        for person in people { quickAddContacts[person.shortName.lowercased(), default: []].insert(person, at: 0) }
        var subject = thread.subject
        while let range = subject.range(of: #"^\s*(re|fwd?|aw|sv):\s*"#, options: [.regularExpression, .caseInsensitive]) { subject.removeSubrange(range) }
        let names = people.prefix(4).map(\.shortName)
        return names.isEmpty ? "\(subject) " : "\(subject) with \(names.joined(separator: ", ")) "
    }

    /// Reads the typed line again, looking up names it has not seen in the contacts.
    func updateQuickAdd() {
        let cache = quickAddContacts
        var requested: [String] = []
        let now = quickAddDay.map { max($0, Date()) == $0 ? $0 : Date() } ?? Date()
        let result = QuickAdd.parse(quickAddText, now: now, calendar: .current, defaultLength: 1800) { name in
            if let hit = cache[name.lowercased()] { return hit }
            requested.append(name)
            return []
        }
        quickAddResult = result
        let store = services.store
        if !requested.isEmpty {
            Task {
                for name in requested where quickAddContacts[name.lowercased()] == nil {
                    quickAddContacts[name.lowercased()] = (try? await store.contacts(matching: name, limit: 3)) ?? []
                }
                if overlay == .quickAdd { updateQuickAdd() }
            }
        }
        Task { await updateQuickAddDay(result) }
    }

    private func updateQuickAddDay(_ result: QuickAdd.Result) async {
        guard let start = result.start, let end = result.end else {
            quickAddDayNote = nil
            return
        }
        let note = await freeOrBusyNote(start: start, end: end, excluding: nil)
        if quickAddResult == result { quickAddDayNote = note }
    }

    /// "Free: nothing else from 12:30 to 13:30", or the overlapping events.
    func freeOrBusyNote(start: EventTime, end: EventTime, excluding eventID: String?) async -> String {
        guard !start.isAllDay else { return "All day" }
        let from = start.instant()
        let to = end.instant()
        let items = ((try? await services.store.agenda(from: from, to: to)) ?? []).filter { item in
            isYourTime(item) && !item.start.isAllDay && item.event.selfResponse != .declined && item.event.isBusy
                && item.event.id != eventID && item.seriesID != eventID
        }
        guard !items.isEmpty else { return "Free: nothing else from \(Formatting.time(from)) to \(Formatting.time(to))" }
        return "Overlaps " + items.prefix(2).map { "\($0.event.summary) \(Formatting.time($0.start.instant()))–\(Formatting.time($0.end.instant()))" }.joined(separator: ", ")
            + (items.count > 2 ? " and \(items.count - 2) more" : "")
    }

    /// Enter in quick add: creates the event, or opens the editor when no time was understood.
    func createFromQuickAdd() {
        guard let result = quickAddResult, let start = result.start, let end = result.end else {
            openEditor(from: quickAddResult)
            return
        }
        overlay = nil
        let calendarID = calendarID(hint: result.calendarHint)
        let event = makeEvent(
            id: CalendarActions.newEventID(), calendarID: calendarID, title: result.title, start: start, end: end,
            guests: result.guests, location: result.location, recurrence: result.recurrence, details: nil
        )
        save(new: event, addConference: result.addConference || !result.guests.isEmpty, notify: true)
    }

    /// The calendar for a "#work" hint, else the primary calendar.
    func calendarID(hint: String?) -> String {
        let editable = calendars.filter(\.canEdit)
        if let hint, let match = editable.first(where: { $0.summary.lowercased().contains(hint.lowercased()) }) { return match.id }
        return editable.first(where: \.isPrimary)?.id ?? calendars.first(where: \.isPrimary)?.id ?? account.email
    }

    func makeEvent(
        id: String, calendarID: String, title: String, start: EventTime, end: EventTime, guests: [EmailAddress],
        location: String?, recurrence: [String], details: String?, base: CalendarEvent? = nil
    ) -> CalendarEvent {
        let me = Attendee(email: account.email, name: account.name, response: .accepted, isSelf: true, isOrganizer: true)
        let aliases = services.store.selfAddresses
        // Rooms and your own addresses are not in Guests: they stay. A guest stays while Guests names them.
        var attendees = base?.attendees.filter { attendee in
            attendee.isSelf || attendee.isResource || aliases.contains(attendee.normalized) || guests.contains { $0.normalized == attendee.normalized }
        } ?? []
        for guest in guests where !attendees.contains(where: { $0.normalized == guest.normalized }) && guest.normalized != me.normalized
            && !aliases.contains(guest.normalized) {
            attendees.append(Attendee(email: guest.email, name: guest.name))
        }
        // Your own entry may not be marked self (on a secondary calendar "self" is the calendar): it is still you.
        if !attendees.isEmpty, !attendees.contains(where: { $0.isSelf || $0.normalized == me.normalized || aliases.contains($0.normalized) }) {
            attendees.insert(me, at: 0)
        }
        var event = base ?? CalendarEvent(id: id, calendarID: calendarID, summary: title, start: start, end: end)
        event.calendarID = calendarID
        event.summary = title.isEmpty ? "(no title)" : title
        event.start = start
        event.end = end
        event.location = location.flatMap { $0.isEmpty ? nil : $0 }
        event.details = details.flatMap { $0.isEmpty ? nil : $0 }
        event.recurrence = recurrence
        event.attendees = attendees
        if event.organizer == nil { event.organizer = me }
        if start.timeZone == nil, case .timed(let date, _) = start { event.start = .timed(date, timeZone: TimeZone.current.identifier) }
        if end.timeZone == nil, case .timed(let date, _) = end { event.end = .timed(date, timeZone: TimeZone.current.identifier) }
        return event
    }

    /// Creates an event. With guests it waits for the undo window, like a send.
    func save(new event: CalendarEvent, addConference: Bool, notify: Bool) {
        let invites = event.attendees.filter { !$0.isSelf && !$0.isResource }
        let waits = notify && !invites.isEmpty && settings.undoSendSeconds > 0
        Task {
            do {
                let record = try await services.calendarActions.create(
                    event, sendUpdates: notify && !invites.isEmpty ? .all : .none, addConference: addConference,
                    undoWindow: waits ? settings.undoSendSeconds : 0
                )
                undoStack.append(.eventChange(record))
                redoStack.removeAll()
                if waits {
                    let names = invites.prefix(2).map { $0.name ?? $0.email }.joined(separator: ", ") + (invites.count > 2 ? " +\(invites.count - 2)" : "")
                    showToast("Inviting \(names)", undoable: true, countdownTo: Date().addingTimeInterval(settings.undoSendSeconds))
                } else {
                    showToast("Created · \(event.summary) · \(Formatting.eventRange(event.start, event.end))", undoable: true)
                }
                await showInAgenda(event)
            } catch {
                showToast("Could not create the event: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - The editor

    /// ↑ in quick add: the new event closed with esc, in the editor again.
    func continueDraft() {
        guard let draft = quickAddDraft else { return }
        let editor = EventEditorModel(
            original: nil, title: "", when: "", guests: "", location: "", calendarID: calendarID(hint: nil), repeats: "",
            recurrence: [], addConference: false, details: ""
        )
        editor.restore(draft)
        eventEditor = editor
        overlay = .eventEditor
    }

    /// Tab in quick add: the editor with what the line said so far.
    func openEditor(from result: QuickAdd.Result?) {
        let when = result?.start.map { start in QuickAdd.text(start: start, end: result?.end ?? start, now: Date(), calendar: .current) } ?? ""
        eventEditor = EventEditorModel(
            original: nil, title: result?.title == "(no title)" ? "" : (result?.title ?? ""), when: when,
            shownStart: result?.start, shownEnd: result?.end,
            guests: (result?.guests ?? []).map(\.formatted).joined(separator: ", "), location: result?.location ?? "",
            calendarID: calendarID(hint: result?.calendarHint), repeats: Self.repeatText(result?.recurrence ?? [], start: result?.start ?? .timed(Date(), timeZone: nil)).text,
            // Events with guests get a Meet link, as when ↵ creates them.
            recurrence: result?.recurrence ?? [], addConference: (result?.addConference ?? false) || !(result?.guests.isEmpty ?? true), details: ""
        )
        overlay = .eventEditor
    }

    /// Enter on your own event in the calendar view. For a repeating event, changes go to this occurrence unless the
    /// editor is switched (⌘E) to this and following, or all events. When shows this occurrence's times in every case.
    func editEvent(_ item: AgendaItem) {
        Task {
            let series = (try? await services.store.event(calendarID: item.calendarID, id: item.seriesID ?? item.event.id)) ?? item.event
            let occurrence = item.seriesID == nil ? nil : await occurrenceEvent(for: item)
            let shown = occurrence ?? series
            let me = services.store.selfAddresses
            let rule = Self.repeatText(series.recurrence, start: series.start)
            let editor = EventEditorModel(
                original: series, occurrence: occurrence, title: shown.summary,
                when: QuickAdd.text(start: shown.start, end: shown.end, now: Date(), calendar: .current), shownStart: shown.start, shownEnd: shown.end,
                guests: shown.attendees.filter { !$0.isSelf && !me.contains($0.normalized) && !$0.isResource }.map(\.address.formatted).joined(separator: ", "),
                location: shown.location ?? "", calendarID: series.calendarID, repeats: rule.text,
                recurrence: series.recurrence, repeatsEditable: rule.exact, addConference: false,
                details: Self.notesText(shown.details), originalDetails: shown.details
            )
            if let saved = await loadDraft(id: editor.draftID) {
                editor.restore(saved)
                showToast("Restored your unsaved changes.")
            }
            eventEditor = editor
            overlay = .eventEditor
        }
    }

    /// The Repeats text for a stored rule, and whether it says the rule exactly.
    static func repeatText(_ recurrence: [String], start: EventTime) -> (text: String, exact: Bool) {
        QuickAdd.repeatText(recurrence, start: start, now: Date(), calendar: .current)
    }

    /// The RRULE a Repeats text means for a series starting at `start`.
    static func repeatRule(_ text: String, start: EventTime) -> String? {
        QuickAdd.repeatRule(text, start: start, now: Date(), calendar: .current)
    }

    /// Notes as text: an HTML description loses its tags but keeps link addresses.
    static func notesText(_ details: String?) -> String {
        details.map(HTMLText.editableText) ?? ""
    }

    /// Names in Guests that are not addresses: they are looked up in the contacts. Commas inside quotes
    /// ("Chen, Jamie" <jamie@studio.co>) do not split.
    static func guestNames(_ text: String) -> [String] {
        EmailAddress.parseList(text).filter { !$0.isValid }.map(\.email).filter { !$0.isEmpty }
    }

    /// ⌘↵ (notify guests) or ⌘⇧↵ (no email) in the editor.
    func saveEditor(notify: Bool) {
        guard let editor = eventEditor else { return }
        // Names in Guests are looked up in the contacts first. One that matches nobody stops the save: it is never dropped quietly.
        let names = Self.guestNames(editor.guests)
        let unknown = names.filter { quickAddContacts[$0.lowercased()] == nil }
        if !unknown.isEmpty {
            let store = services.store
            Task {
                for name in unknown { quickAddContacts[name.lowercased()] = (try? await store.contacts(matching: name, limit: 3)) ?? [] }
                guard eventEditor === editor else { return }
                saveEditor(notify: notify)
            }
            return
        }
        if let missing = names.first(where: { quickAddContacts[$0.lowercased()]?.first == nil }) {
            showToast("No contact matches “\(missing)”. Type an address, or take the name out.", isError: true)
            return
        }
        let scope = editor.appliedScope
        // This and following: the series ends the day before, and a new series takes over from this day.
        var cut: (before: [String], after: [String])?
        if editor.occurrence != nil, scope == .thisAndFollowing {
            guard case .split(let before, let after)? = editor.split else {
                showToast(Self.uncountedRepeat, isError: true)
                return
            }
            // Nothing typed: a cut would change nothing, yet send guests a new invitation.
            guard editor.fieldsChanged else {
                overlay = nil
                eventEditor = nil
                forgetDraft(id: editor.draftID)
                showToast("Nothing changed: the series stays as it is.")
                return
            }
            cut = (before, after)
        }
        let calendar = Calendar.current
        var start: EventTime
        var end: EventTime
        if let kept = editor.keptTimes {
            (start, end) = kept
        } else {
            let parsed = QuickAdd.parse(editor.when, now: Date(), calendar: calendar, defaultLength: 1800) { _ in [] }
            guard let parsedStart = parsed.start, let parsedEnd = parsed.end else {
                showToast("Type when it happens, like “tue 14:00-15:00” or “oct 16 all day”.", isError: true)
                return
            }
            (start, end) = (parsedStart, parsedEnd)
        }
        // This and following: the new series' first event, on the old series' clock. Typed times are taken as typed; When
        // left as it was keeps the series' own time that day, as for all events (a day moved on its own moves no other).
        if cut != nil, let series = editor.original, let occurrence = editor.occurrence {
            if editor.keptTimes != nil {
                (start, end) = Recurrence.times(on: occurrence.originalStart ?? occurrence.start, seriesStart: series.start, seriesEnd: series.end, calendar: calendar)
            }
            (start, end) = Recurrence.followingTimes(start: start, end: end, seriesStart: series.start, seriesEnd: series.end)
        }
        // All events, opened on one occurrence: the series moves by the same change, on its own days.
        if let occurrence = editor.occurrence, let series = editor.original, scope == .allEvents {
            if editor.keptTimes != nil {
                (start, end) = (series.start, series.end)
            } else if let moved = Recurrence.seriesTimes(
                seriesStart: series.start, occurrenceStart: occurrence.start, newStart: start, newEnd: end, calendar: calendar
            ) {
                (start, end) = moved
            } else {
                showToast("All events keep their days. Change Repeats to move them, like “every thu”.", isError: true)
                return
            }
        }
        // That day may differ from the series (its own title or place): only what was changed goes to the events after it,
        // or to every event.
        let series = editor.original
        let seriesFromOneDay = editor.occurrence != nil && scope != .thisEvent
        func edited(_ field: KeyPath<EventDraft, String>) -> Bool { !seriesFromOneDay || editor.changed(field) }
        let title = edited(\.title) ? editor.title : (series?.summary ?? editor.title)
        let location = edited(\.location) ? editor.location : (series?.location ?? "")
        let guests = edited(\.guests)
            ? parsedGuests(editor.guests)
            : (series?.attendees ?? []).filter { !$0.isSelf && !$0.isResource }.map(\.address)
        // Notes left alone keep the description exactly as it was: Google's formatting and links stay.
        let details: String?
        if editor.changed(\.details) {
            details = editor.details
        } else {
            details = seriesFromOneDay ? series?.details : editor.originalDetails
        }
        // The series' rules from this day on (its count less the events before, for this and following).
        let rules = cut?.after ?? editor.originalRecurrence
        let recurrence: [String]
        if editor.changesOneOccurrence {
            recurrence = []
        } else if editor.repeats == editor.originalRepeats || !editor.repeatsEditable {
            recurrence = rules
        } else if editor.repeats.trimmingCharacters(in: .whitespaces).isEmpty {
            recurrence = []
        } else {
            guard let rule = Self.repeatRule(editor.repeats, start: start) else {
                showToast("Type how it repeats, like “weekly”, “every tue” or “daily until dec 18”.", isError: true)
                return
            }
            if let until = Recurrence.parseRule(rule)?.until, until.dayDate(in: calendar) < start.dayDate(in: calendar) {
                showToast("That repeat ends before the event starts. Type a later “until”.", isError: true)
                return
            }
            // Days the series already skips or adds stay as they are.
            recurrence = [rule] + rules.filter { !$0.uppercased().hasPrefix("RRULE:") }
        }
        // "every thu" starts on a Thursday.
        if editor.isNew || editor.repeats != editor.originalRepeats {
            (start, end) = Recurrence.aligned(start: start, end: end, recurrence: recurrence, calendar: calendar)
        }
        let base: CalendarEvent? = if cut != nil, let series {
            CalendarActions.followingSeries(of: series)
        } else {
            editor.changesOneOccurrence ? editor.occurrence : editor.original
        }
        let event = makeEvent(
            id: base?.id ?? CalendarActions.newEventID(), calendarID: editor.calendarID, title: title, start: start, end: end,
            guests: guests, location: location, recurrence: recurrence, details: details, base: base
        )
        overlay = nil
        eventEditor = nil
        forgetDraft(id: editor.draftID)
        if let cut, let series, let occurrence = editor.occurrence {
            saveFollowing(event, ending: series, keeping: cut.before, from: occurrence, notify: notify)
            return
        }
        guard let original = base else {
            save(new: event, addConference: editor.addConference, notify: notify)
            return
        }
        // Guests taken off the event are told too: ⌘↵ emails everyone the change concerns.
        let me = services.store.selfAddresses
        let told = (original.attendees + event.attendees).filter { !$0.isSelf && !$0.isResource && !me.contains($0.normalized) }
        let waits = notify && !told.isEmpty && settings.undoSendSeconds > 0
        let name = editor.changesOneOccurrence ? "\(event.summary) on \(Formatting.dayTitle(original.start.instant())) only" : event.summary
        Task {
            do {
                let record = try await services.calendarActions.update(
                    event, from: original, sendUpdates: notify && !told.isEmpty ? .all : .none, undoWindow: waits ? settings.undoSendSeconds : 0
                )
                undoStack.append(.eventChange(record))
                redoStack.removeAll()
                showToast(waits ? "Telling guests about \(name)" : "Saved · \(name)", undoable: true,
                          countdownTo: waits ? Date().addingTimeInterval(settings.undoSendSeconds) : nil)
            } catch {
                showToast("Could not save the event: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Saves "this and following": `series` ends the day before `occurrence`, and `event` takes over from that day as a
    /// new series. ⌘↵ tells the guests of both after the undo window, like a send.
    private func saveFollowing(_ event: CalendarEvent, ending series: CalendarEvent, keeping recurrence: [String], from occurrence: CalendarEvent, notify: Bool) {
        let me = services.store.selfAddresses
        let told = (series.attendees + event.attendees).filter { !$0.isSelf && !$0.isResource && !me.contains($0.normalized) }
        let waits = notify && !told.isEmpty && settings.undoSendSeconds > 0
        let name = "\(event.summary) from \(Formatting.dayTitle(occurrence.start.instant())) on"
        Task {
            do {
                let records = try await services.calendarActions.split(
                    series, at: occurrence.originalStart ?? occurrence.start, keeping: recurrence, following: event,
                    sendUpdates: notify && !told.isEmpty ? .all : .none, undoWindow: waits ? settings.undoSendSeconds : 0
                )
                undoStack.append(.eventChanges(records))
                redoStack.removeAll()
                showToast(waits ? "Telling guests about \(name)" : "Saved · \(name)", undoable: true,
                          countdownTo: waits ? Date().addingTimeInterval(settings.undoSendSeconds) : nil)
                // The row now belongs to the new series: the cursor follows it.
                await showInAgenda(event)
            } catch {
                showToast("Could not save the event: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Why "this and following" cannot be done here.
    static let uncountedRepeat = "vimail cannot count this repeat's events: change this and the following ones in Google Calendar."

    /// In the calendar view: the fortnight with `event`'s first day, with that row selected.
    func showInAgenda(_ event: CalendarEvent) async {
        guard destination == .calendar else { return }
        let day = Calendar.current.startOfDay(for: event.start.instant())
        let lastShown = Calendar.current.date(byAdding: .day, value: 13, to: agendaStart) ?? agendaStart
        if day < agendaStart || day > lastShown { agendaStart = Self.agendaStart(showing: day) }
        pendingAgendaEventID = event.id
        pendingAgendaDay = day
        await reloadAgenda()
    }

    /// Guests typed in the editor: addresses, or names matched in the contacts.
    func parsedGuests(_ text: String) -> [EmailAddress] {
        EmailAddress.parseList(text).compactMap { entry in
            entry.isValid ? entry : quickAddContacts[entry.email.lowercased()]?.first
        }
    }

    /// Esc in the editor: closes it. Unsaved changes stay as a draft: C then tab (a new event), or ↵ on the event.
    func closeEditor() {
        overlay = nil
        guard let editor = eventEditor else { return }
        eventEditor = nil
        guard editor.keepsDraft else {
            forgetDraft(id: editor.draftID)
            return
        }
        let draft = editor.draft
        if editor.isNew { quickAddDraft = draft }
        let store = services.store
        Task {
            if let data = try? JSONEncoder().encode(draft) {
                try? await store.saveEventDraft(id: editor.draftID, payload: String(decoding: data, as: UTF8.self))
            }
        }
        showToast(editor.isNew ? "Kept as a draft. C then ↑ continues it." : "Kept your changes. ↵ on the event continues them.")
    }

    /// ⌘⇧⌫ in the editor: removes the event; on a day of a series, as ⌘E says: that day, the series from that day on
    /// (it ends the day before), or the series. A new event is discarded.
    func removeFromEditor() {
        guard let editor = eventEditor else { return }
        var cut: [String]?
        if editor.occurrence != nil, editor.appliedScope == .thisAndFollowing {
            guard case .split(let before, _)? = editor.split else {
                showToast(Self.uncountedRepeat, isError: true)
                return
            }
            cut = before
        }
        overlay = nil
        eventEditor = nil
        forgetDraft(id: editor.draftID)
        guard let original = editor.original else {
            showToast("Discarded the new event.")
            return
        }
        if let cut, let occurrence = editor.occurrence {
            endSeries(original, keeping: cut, from: occurrence)
            return
        }
        removeEvent(editor.changesOneOccurrence ? (editor.occurrence ?? original) : original)
    }

    func loadDraft(id: String) async -> EventDraft? {
        guard let text = try? await services.store.eventDraft(id: id) else { return nil }
        return try? JSONDecoder().decode(EventDraft.self, from: Data(text.utf8))
    }

    private func forgetDraft(id: String) {
        if id == "new" { quickAddDraft = nil }
        let store = services.store
        Task { try? await store.deleteEventDraft(id: id) }
    }

    // MARK: - Find a time

    /// Loads your busy times and the guests' (Google free/busy) around the editor's day. Cheap when nothing changed.
    func refreshEditorBusy() async {
        guard let editor = eventEditor else { return }
        let calendar = Calendar.current
        let now = Date()
        let parsed = QuickAdd.parse(editor.when, now: now, calendar: calendar, defaultLength: 1800) { _ in [] }
        let day = parsed.start?.instant() ?? now
        // The event's day and three weeks either way (find a time looks that far), never more than needed.
        let eventDay = calendar.startOfDay(for: day)
        let from = max(calendar.startOfDay(for: min(day, now)), calendar.date(byAdding: .day, value: -21, to: eventDay) ?? eventDay)
        let to = calendar.date(byAdding: .day, value: 22, to: calendar.startOfDay(for: max(day, now))) ?? now
        let excluded = Set([editor.original?.id, editor.occurrence?.id].compactMap { $0 })
        let items = (try? await services.store.agenda(from: from, to: to)) ?? []
        // The event's own times are in its guests' busy times too: they are taken out.
        let ownTimes = items.filter { excluded.contains($0.event.id) || excluded.contains($0.seriesID ?? "") }
            .map { DateInterval(start: $0.start.instant(), end: max($0.start.instant(), $0.end.instant())) }
        editor.ownBusy = items.filter { item in
            isYourTime(item) && !item.start.isAllDay && item.event.isBusy && item.event.status != .cancelled && item.event.selfResponse != .declined
                && !excluded.contains(item.event.id) && !excluded.contains(item.seriesID ?? "")
        }.map { DateInterval(start: $0.start.instant(), end: max($0.start.instant(), $0.end.instant())) }

        let me = services.store.selfAddresses
        let emails = Array(Set(parsedGuests(editor.guests).map(\.normalized).filter { !me.contains($0) && $0 != account.normalized })).sorted()
        let key = emails.joined(separator: ",") + "|\(DayDate(from, in: calendar))|\(DayDate(to, in: calendar))"
        guard key != editor.busyKey else { return }
        guard !emails.isEmpty else {
            editor.guestBusy = [:]
            editor.busyNote = nil
            editor.busyKey = key
            return
        }
        guard let provider = services.calendarProvider else {
            editor.busyNote = "Connect Google Calendar to see guests' busy times."
            return
        }
        editor.busyLoading = true
        defer { editor.busyLoading = false }
        do {
            let busy = try await provider.freeBusy(emails: emails, from: from, to: to)
            guard eventEditor === editor else { return }
            // The event's own times are in its guests' busy times; someone just added was not at it.
            let attending = Set(((editor.occurrence ?? editor.original)?.attendees ?? []).map(\.normalized))
            editor.guestBusy = Dictionary(uniqueKeysWithValues: busy.map { key, value in
                (key, attending.contains(key) ? FreeTime.subtracting(ownTimes, from: value) : value)
            })
            editor.busyKey = key
            let hidden = parsedGuests(editor.guests).filter { emails.contains($0.normalized) && busy[$0.normalized] == nil }
            editor.busyNote = hidden.isEmpty ? nil : "\(hidden.map(\.shortName).joined(separator: ", ")) \(hidden.count == 1 ? "does" : "do") not share busy times with you."
        } catch CalendarProviderError.notConnected {
            editor.busyNote = "Guests' busy times need calendar access again: press : and choose “Connect Google Calendar”."
        } catch {
            editor.busyNote = "Could not load guests' busy times: \(error.localizedDescription)"
        }
    }

    /// ⌘] and ⌘[ in the editor: the next or previous time where you and every guest who shares busy times are free.
    func findTime(forward: Bool) {
        guard let editor = eventEditor else { return }
        let now = Date()
        let parsed = QuickAdd.parse(editor.when, now: now, calendar: .current, defaultLength: 1800) { _ in [] }
        if parsed.start?.isAllDay == true {
            showToast("Find a time moves timed events. Type a time first, like “tue 14:00”.")
            return
        }
        let start = parsed.start?.instant() ?? now
        let length = parsed.end.map { $0.instant().timeIntervalSince(start) } ?? 1800
        let busy = editor.ownBusy + editor.guestBusy.values.flatMap { $0 }
        guard let slot = FreeTime.nextSlot(
            from: start, forward: forward, length: length, busy: busy, workStart: settings.workdayStart, workEnd: settings.workdayEnd, now: now, calendar: .current
        ) else {
            showToast(forward ? "No later time in the next three weeks where everyone is free." : "No earlier time where everyone is free.")
            return
        }
        let zone = TimeZone.current.identifier
        editor.when = QuickAdd.text(start: .timed(slot.start, timeZone: zone), end: .timed(slot.end, timeZone: zone), now: now, calendar: .current)
        Task { await refreshEditorBusy() }
    }

    // MARK: - Free times in compose

    func insertFreeTimes(into compose: ComposeModel, textView: NSTextView?) {
        guard services.calendarEngine != nil else {
            offerCalendarConnection()
            return
        }
        Task {
            guard let text = await freeTimesText() else {
                showToast("No free time in your working hours over the next five working days.")
                return
            }
            if let textView, textView.window != nil {
                textView.insertText(text + "\n", replacementRange: textView.selectedRange())
            } else {
                let body = compose.draft.body
                compose.draft.body = body.isEmpty || body.hasSuffix("\n\n") ? body + text + "\n" : body + (body.hasSuffix("\n") ? "\n" : "\n\n") + text + "\n"
            }
            showToast("Inserted your free times.")
        }
    }

    /// ⌘⇧A in compose: your free times for the next five working days, as Markdown at the cursor.
    func freeTimesText() async -> String? {
        guard services.calendarEngine != nil else { return nil }
        let calendar = Calendar.current
        let now = Date()
        let days = FreeTime.workingDays(from: now, count: 5, calendar: calendar)
        guard let first = days.first, let last = days.last else { return nil }
        let from = first.start(in: calendar)
        let to = last.adding(days: 1, in: calendar).start(in: calendar)
        let busy = ((try? await services.store.agenda(from: from, to: to)) ?? []).filter { item in
            isYourTime(item) && !item.start.isAllDay && item.event.isBusy && item.event.selfResponse != .declined && item.event.status != .cancelled
        }.map { DateInterval(start: $0.start.instant(), end: max($0.start.instant(), $0.end.instant())) }
        let slots = FreeTime.slots(busy: busy, days: days, workStart: settings.workdayStart, workEnd: settings.workdayEnd, minimum: 1800, now: now, calendar: calendar)
        let zone = TimeZone.current.abbreviation(for: now) ?? TimeZone.current.identifier
        let text = FreeTime.markdown(slots, calendar: calendar, zoneLabel: zone)
        return text.isEmpty ? nil : text
    }
}
