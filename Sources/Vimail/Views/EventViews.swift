import AppKit
import MailCore
import SwiftUI

/// Quick add (C): one typed line, read as you type, with the event it will create.
struct QuickAddView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        DialogShell(
            title: "New event", width: 560,
            footer: model.quickAddDraft == nil ? "↵ create · tab more details · esc cancel" : "↵ create · tab more details · ↑ the draft · esc cancel",
            onClose: { model.overlay = nil }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("lunch with jamie fri 12:30 1h @ Tartine", text: $model.quickAddText)
                    .textFieldStyle(.plain)
                    .font(AppFonts.mono(14))
                    .foregroundStyle(theme.foreground)
                    .focused($focused)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                if !model.quickAddText.isEmpty {
                    highlighted
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
                Rectangle().fill(theme.border).frame(height: 1)
                preview
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
        }
        .onAppear {
            DispatchQueue.main.async { focused = true }
            keepPrefilledLine()
        }
    }

    /// A focused text field selects all its text, so typing would replace the line from a conversation. Once the field
    /// has focus with its line selected, the cursor goes to the end instead. Stops when the line changes.
    private func keepPrefilledLine() {
        let line = model.quickAddText
        guard !line.isEmpty else { return }
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(20))
                guard model.overlay == .quickAdd, model.quickAddText == line else { return }
                guard let editor = (MainWindow.shared ?? NSApp.keyWindow)?.firstResponder as? NSTextView, editor.isFieldEditor,
                      editor.string == line else { continue }
                let length = (editor.string as NSString).length
                if editor.selectedRange() == NSRange(location: 0, length: length) {
                    editor.setSelectedRange(NSRange(location: length, length: 0))
                    return
                }
            }
        }
    }

    /// The typed line again, with each part underlined in the color of what it was read as.
    private var highlighted: some View {
        let text = model.quickAddText
        var attributed = AttributedString(text)
        attributed.foregroundColor = theme.mutedForeground
        for token in model.quickAddResult?.tokens ?? [] {
            guard token.start >= 0, token.end <= text.count, token.start < token.end else { continue }
            let lower = attributed.index(attributed.startIndex, offsetByCharacters: token.start)
            let upper = attributed.index(attributed.startIndex, offsetByCharacters: token.end)
            attributed[lower..<upper].foregroundColor = color(token.role)
            attributed[lower..<upper].underlineStyle = .single
        }
        return Text(attributed).font(AppFonts.mono(11))
    }

    private func color(_ role: QuickAdd.Role) -> Color {
        switch role {
        case .day, .time, .length: theme.blue
        case .guest: theme.green
        case .place: theme.orange
        case .repeats, .calendar, .conference: theme.purple
        }
    }

    @ViewBuilder
    private var preview: some View {
        let result = model.quickAddResult
        VStack(alignment: .leading, spacing: 7) {
            if let draft = model.quickAddDraft {
                line("Draft", (draft.title.isEmpty ? "(no title)" : draft.title) + (draft.when.isEmpty ? "" : " · \(draft.when)") + " — ↑ continues it", color: theme.yellow)
            }
            line("Title", result?.title ?? "(no title)")
            if let start = result?.start, let end = result?.end {
                line("When", Formatting.eventRange(start, end), color: theme.blue)
            } else {
                line("When", "Type a day or time, like fri 12:30 or tomorrow 9-10", color: theme.yellow)
            }
            if let result, !result.guests.isEmpty || !result.unknownGuests.isEmpty {
                line("Guests", (result.guests.map { "\($0.displayName) · \($0.email)" } + result.unknownGuests.map { "\($0)? not in your contacts" }).joined(separator: ", "),
                     color: result.unknownGuests.isEmpty ? theme.green : theme.yellow)
            }
            if let place = result?.location { line("Where", place, color: theme.orange) }
            if let result, !result.recurrence.isEmpty, let start = result.start {
                line("Repeats", Recurrence.summary(result.recurrence, start: start, calendar: .current) ?? result.recurrence.joined(separator: " "))
            }
            if let result, result.addConference || !result.guests.isEmpty { line("Video", "Google Meet link") }
            line("Calendar", model.calendars.first { $0.id == model.calendarID(hint: result?.calendarHint) }?.summary ?? model.account.email)
            if let note = model.quickAddDayNote {
                line("Your day", note, color: note.hasPrefix("Overlaps") ? theme.red : theme.green)
            }
        }
    }

    private func line(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label.uppercased())
                .font(AppFonts.mono(9))
                .tracking(1)
                .foregroundStyle(theme.mutedForeground)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(AppFonts.sans(12))
                .foregroundStyle(color ?? theme.body)
                .lineLimit(2)
        }
    }
}

/// The event editor: every field of an event, with the When and Repeat fields typed like quick add.
/// On the right, your day and each guest's busy times; ⌘[ and ⌘] find the previous or next time everyone is free.
struct EventEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var field: FocusTarget?
    @State private var note: String?

    var body: some View {
        if let editor = model.eventEditor {
            DialogShell(title: editor.isNew ? "New event" : "Edit event", width: 900, footer: footer(editor), onClose: { model.closeEditor() }) {
                HStack(alignment: .top, spacing: 0) {
                    Group {
                        if let vim = editor.vim { notesInVim(editor, vim: vim) } else { form(editor) }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(theme.border).frame(width: 1)
                    AvailabilityView(editor: editor)
                        .padding(18)
                        .frame(width: 300, alignment: .topLeading)
                }
            }
            .onAppear {
                DispatchQueue.main.async { field = editor.title.isEmpty ? .eventTitle : .eventWhen }
                updateNote(editor)
            }
            .onChange(of: editor.when) { _, _ in updateNote(editor) }
            // The model routes keys by the field the cursor is in (Guests' suggestions), as compose does.
            .onChange(of: field) { _, value in
                if model.focusTarget != value { model.focusTarget = value }
                editor.focusChanged(to: value)
            }
            .onChange(of: model.focusTarget) { _, target in if field != target { field = target } }
            .task(id: editor.guests.map(\.normalized).joined(separator: ",") + "|" + editor.when) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.refreshEditorBusy()
            }
        }
    }

    /// The keys for where the cursor is, as compose's footer.
    private func footer(_ editor: EventEditorModel) -> String {
        if editor.vimRunning { return ":w updates the notes · :wq returns to the event" }
        if model.focusTarget == .eventNotes {
            return editor.notesMode == .normal
                ? "vim keys · i insert · esc close, keeping a draft · ^g your editor · ⌘↵ save and email guests"
                : "esc vim keys · ^g your editor · ⌘↵ save and email guests · ⌘⇧↵ save without email"
        }
        return "⌘↵ save and email guests · ⌘⇧↵ save without email · ⌘[ ⌘] find a time · ^g notes in your editor · "
            + "⌘⇧⌫ \(editor.isNew ? "discard" : "remove") · esc keep as draft"
    }

    @ViewBuilder
    private func form(_ editor: EventEditorModel) -> some View {
        @Bindable var editor = editor
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $editor.title)
                .textFieldStyle(.plain)
                .font(AppFonts.sans(18, .semibold))
                .foregroundStyle(theme.foreground)
                .focused($field, equals: .eventTitle)
            if editor.occurrence != nil {
                row("Change") {
                    Picker("", selection: $editor.scope) {
                        Text("This event").tag(EventEditorModel.Scope.thisEvent)
                        Text("This and following").tag(EventEditorModel.Scope.thisAndFollowing)
                        Text("All events").tag(EventEditorModel.Scope.allEvents)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("This event, this event and the ones after it, or every event in the series (⌘E)")
                    KeyChip("⌘E", alwaysVisible: true)
                }
            }
            row("When") {
                TextField("tue 14:00-15:00, oct 16 all day", text: $editor.when).fieldStyle().focused($field, equals: .eventWhen)
            }
            if let note {
                Text(note).font(AppFonts.mono(10)).foregroundStyle(note.hasPrefix("Overlaps") || note.hasPrefix("Type") ? theme.yellow : theme.green)
                    .padding(.leading, 86)
            }
            guestsRow(editor)
            row("Where") {
                TextField("a place or a link", text: $editor.location).fieldStyle().focused($field, equals: .eventWhere)
            }
            row("Repeats") {
                TextField("daily, every tue, every weekday, monthly…", text: $editor.repeats).fieldStyle().focused($field, equals: .eventRepeats)
                    .disabled(editor.changesOneOccurrence || !editor.repeatsEditable)
                    .opacity(editor.changesOneOccurrence || !editor.repeatsEditable ? 0.5 : 1)
            }
            if !editor.repeatsEditable, !editor.changesOneOccurrence {
                Text("This repeat can only be changed in Google Calendar. The rest of the event can be changed here.")
                    .font(AppFonts.sans(10)).foregroundStyle(theme.mutedForeground).padding(.leading, 86)
            }
            if let note = scopeNote(editor) {
                Text(note).font(AppFonts.sans(10))
                    .foregroundStyle(editor.scope == .thisAndFollowing && editor.split == nil ? theme.yellow : theme.mutedForeground)
                    .padding(.leading, 86)
            }
            row("Calendar") {
                Picker("", selection: $editor.calendarID) {
                    ForEach(model.calendars.filter(\.canEdit)) { Text($0.summary).tag($0.id) }
                    if !model.calendars.contains(where: { $0.id == editor.calendarID }) { Text(editor.calendarID).tag(editor.calendarID) }
                }
                .labelsHidden()
                .disabled(!editor.isNew)
            }
            if editor.isNew {
                row("Video") {
                    Toggle("Add a Google Meet link", isOn: $editor.addConference).toggleStyle(.checkbox)
                }
            }
            notesLabel(vim: false)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $editor.details)
                    .font(AppFonts.mono(12))
                    .foregroundStyle(theme.foreground)
                    .scrollContentBackground(.hidden)
                    .focused($field, equals: .eventNotes)
                    .onAppear {
                        // Back from your editor (:wq): the cursor goes to the notes again.
                        guard editor.focusNotesOnAppear else { return }
                        editor.focusNotesOnAppear = false
                        Task { await MainWindow.focusTextView() }
                    }
                if editor.details.isEmpty {
                    Text("Notes for guests, in Markdown")
                        .font(AppFonts.mono(12))
                        .foregroundStyle(theme.mutedForeground.opacity(0.6))
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .frame(height: 110)
            .background(theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border.opacity(0.6), lineWidth: 1))
        }
    }

    /// "NOTES" and what writes them: Markdown in the field, or your editor (^g).
    private func notesLabel(vim: Bool) -> some View {
        HStack(spacing: 8) {
            Text("NOTES").font(AppFonts.mono(9)).tracking(1).foregroundStyle(theme.mutedForeground)
            Text(vim ? "VIM" : "MARKDOWN")
                .font(AppFonts.mono(8, .semibold))
                .tracking(1)
                .foregroundStyle(vim ? theme.green : theme.mutedForeground)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(vim ? theme.greenSoft : theme.muted, in: RoundedRectangle(cornerRadius: 3))
            Spacer()
            if !vim { KeyChip("^g", alwaysVisible: true).help("Write the notes in your own editor") }
        }
    }

    /// ^g: your editor on the notes, in place of the fields until :wq.
    private func notesInVim(_ editor: EventEditorModel, vim: VimSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.title.isEmpty ? "(no title)" : editor.title)
                .font(AppFonts.sans(18, .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
            notesLabel(vim: true)
            VimTerminalView(session: vim, palette: theme.palette)
                .frame(height: 380)
                .background(theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border.opacity(0.6), lineWidth: 1))
        }
    }

    /// Guests as compose's To: pills, the one being typed, and the contacts matching it under the row.
    private func guestsRow(_ editor: EventEditorModel) -> some View {
        @Bindable var editor = editor
        return row("Guests", alignment: .top) {
            RecipientInput(addresses: editor.guests, text: $editor.guestInput, prompt: "names or addresses", field: .eventGuests,
                           focus: $field, fontSize: 12) { editor.removeGuest($0) }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
        }
        .overlay(alignment: .bottomLeading) {
            if field == .eventGuests, !editor.suggestions.isEmpty {
                // Hangs from the row's bottom edge over the rows below, as in compose.
                RecipientSuggestions(suggestions: editor.suggestions.items, highlighted: editor.suggestions.index) { index in
                    editor.acceptSuggestion(at: index)
                }
                .padding(.top, 4)
                .frame(height: 0, alignment: .top)
                .offset(x: 86)
            }
        }
        .zIndex(field == .eventGuests ? 3 : 1)
    }

    /// The line under Repeats: what saving changes.
    private func scopeNote(_ editor: EventEditorModel) -> String? {
        guard let occurrence = editor.occurrence else {
            return editor.original?.isSeries == true ? "Changes apply to all events in this series." : nil
        }
        let day = Formatting.dayTitle(occurrence.start.instant())
        switch editor.scope {
        case .thisEvent:
            return "Only \(day) changes. ⌘E: this and following, or all events."
        case .thisAndFollowing:
            switch editor.split {
            case .wholeSeries?: return "\(day) is the first event, so every event in the series changes."
            case .split?: return "\(day) and the events after it change, as a new series. Earlier events stay."
            case nil: return AppModel.uncountedRepeat
            }
        case .allEvents:
            return "Every event in the series changes. A new time moves them all; Repeats changes their days."
        }
    }

    private func updateNote(_ editor: EventEditorModel) {
        let parsed = QuickAdd.parse(editor.when, now: Date(), calendar: .current, contacts: { _ in [] })
        guard let start = parsed.start, let end = parsed.end else {
            note = editor.when.isEmpty ? nil : "Type when it happens, like “tue 14:00-15:00”"
            return
        }
        let range = Formatting.eventRange(start, end)
        Task {
            let day = await model.freeOrBusyNote(start: start, end: end, excluding: editor.original?.id)
            note = "\(range) · \(day)"
        }
    }

    private func row<Content: View>(_ label: String, alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignment, spacing: 14) {
            Text(label.uppercased())
                .font(AppFonts.mono(9))
                .tracking(1)
                .foregroundStyle(theme.mutedForeground)
                .frame(width: 72, alignment: .leading)
                // Level with the first line of a field that wraps (Guests).
                .padding(.top, alignment == .top ? 12 : 0)
            content()
        }
    }
}

/// Find a time: the event's day across working hours, one strip for you and one per guest, with busy times in grey
/// and the event in green where that person is free, red where they are busy.
private struct AvailabilityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let editor: EventEditorModel

    private struct Strip: Identifiable {
        var id: String
        var name: String
        /// Nil when the person's busy times are not known.
        var busy: [DateInterval]?
    }

    private let hourHeight: CGFloat = 21

    var body: some View {
        let calendar = Calendar.current
        let parsed = QuickAdd.parse(editor.when, now: Date(), calendar: calendar, defaultLength: 1800) { _ in [] }
        let event: DateInterval? = {
            guard let start = parsed.start, !start.isAllDay, let end = parsed.end else { return nil }
            return DateInterval(start: start.instant(), end: max(start.instant(), end.instant()))
        }()
        let day = calendar.startOfDay(for: event?.start ?? parsed.start?.instant() ?? Date())
        let strips = self.strips()
        let range = hours(day: day, event: event)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("FIND A TIME").font(AppFonts.mono(9)).tracking(1).foregroundStyle(theme.mutedForeground)
                Spacer()
                KeyChip("⌘[", alwaysVisible: true)
                KeyChip("⌘]", alwaysVisible: true)
            }
            Text(Formatting.dayTitle(day)).font(AppFonts.sans(13, .semibold)).foregroundStyle(theme.foreground)
            HStack(alignment: .top, spacing: 4) {
                axis(range)
                ForEach(strips) { strip in
                    column(strip, day: day, range: range, event: event)
                }
            }
            summary(strips, event: event)
            if let note = editor.busyNote {
                Text(note).font(AppFonts.sans(10)).foregroundStyle(theme.yellow).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func strips() -> [Strip] {
        var result = [Strip(id: "you", name: "you", busy: editor.ownBusy)]
        var seen = Set<String>()
        for guest in editor.guests where !editor.me.contains(guest.normalized) && seen.insert(guest.normalized).inserted {
            result.append(Strip(id: guest.normalized, name: guest.shortName, busy: editor.guestBusy[guest.normalized]))
        }
        return Array(result.prefix(6))
    }

    /// Working hours, stretched to show the event with half an hour around it.
    private func hours(day: Date, event: DateInterval?) -> ClosedRange<Int> {
        var first = model.settings.workdayStart
        var last = max(model.settings.workdayEnd, first + 60)
        if let event {
            first = min(first, minutes(event.start, day) - 30)
            last = max(last, minutes(event.end, day) + 30)
        }
        return max(0, first / 60 * 60)...min(1440, (last + 59) / 60 * 60)
    }

    private func minutes(_ date: Date, _ day: Date) -> Int { Int(date.timeIntervalSince(day) / 60) }

    private func y(_ minute: Int, _ range: ClosedRange<Int>) -> CGFloat {
        CGFloat(min(max(minute, range.lowerBound), range.upperBound) - range.lowerBound) / 60 * hourHeight
    }

    private func axis(_ range: ClosedRange<Int>) -> some View {
        VStack(spacing: 4) {
            Text(" ").font(AppFonts.mono(9))
            ZStack(alignment: .topLeading) {
                ForEach(Array(stride(from: range.lowerBound, to: range.upperBound, by: 60)), id: \.self) { minute in
                    Text(String(format: "%02d", minute / 60))
                        .font(AppFonts.mono(8))
                        .foregroundStyle(theme.mutedForeground)
                        .offset(y: y(minute, range) - 5)
                }
            }
            .frame(width: 16, height: y(range.upperBound, range), alignment: .topLeading)
        }
    }

    private func column(_ strip: Strip, day: Date, range: ClosedRange<Int>, event: DateInterval?) -> some View {
        let clash = event.map { event in strip.busy?.contains { $0.start < event.end && event.start < $0.end } ?? false } ?? false
        let color = strip.busy == nil ? theme.mutedForeground : (clash ? theme.red : theme.green)
        return VStack(spacing: 4) {
            Text(strip.name).font(AppFonts.mono(9)).foregroundStyle(clash ? theme.red : theme.mutedForeground).lineLimit(1)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 4).fill(theme.muted.opacity(0.45))
                if let busy = strip.busy {
                    ForEach(Array(busy.enumerated()), id: \.offset) { _, span in
                        let top = y(minutes(span.start, day), range)
                        let bottom = y(minutes(span.end, day), range)
                        if bottom > top {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(theme.mutedForeground.opacity(0.4))
                                .frame(height: bottom - top)
                                .padding(.horizontal, 2)
                                .offset(y: top)
                        }
                    }
                } else {
                    Text(editor.busyLoading ? "…" : "not\nshared")
                        .font(AppFonts.mono(8))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.mutedForeground)
                        .padding(.top, 10)
                }
                if let event {
                    let top = y(minutes(event.start, day), range)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.2))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1.2))
                        .frame(height: max(4, y(minutes(event.end, day), range) - top))
                        .offset(y: top)
                }
            }
            .frame(height: y(range.upperBound, range))
            .clipped()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func summary(_ strips: [Strip], event: DateInterval?) -> some View {
        if let event {
            let busy = strips.filter { strip in strip.busy?.contains { $0.start < event.end && event.start < $0.end } ?? false }.map(\.name)
            if busy.isEmpty {
                Text(strips.count > 1 ? "Everyone who shares busy times is free." : "You are free.")
                    .font(AppFonts.sans(11)).foregroundStyle(theme.green)
            } else {
                Text("Busy: \(busy.joined(separator: ", ")). ⌘] finds the next free time.")
                    .font(AppFonts.sans(11)).foregroundStyle(theme.red)
            }
        } else {
            Text("Type a time to see who is free.").font(AppFonts.sans(11)).foregroundStyle(theme.mutedForeground)
        }
    }
}
