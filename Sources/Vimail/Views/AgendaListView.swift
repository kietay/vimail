import AppKit
import MailCore
import MailStore
import SwiftUI

/// The calendar view's list pane: invitations waiting for an answer, then two weeks of days.
struct AgendaListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @AppStorage("threadListWidth") private var width: Double = ThreadListView.defaultWidth

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            footer
        }
        .frame(width: width)
        .background(theme.list.opacity(0.8))
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border.opacity(0.6)).frame(width: 1) }
    }

    private var rangeText: String {
        let end = Calendar.current.date(byAdding: .day, value: 13, to: model.agendaStart) ?? model.agendaStart
        return "\(Formatting.dayTitle(model.agendaStart)) – \(Formatting.dayTitle(end))"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Calendar")
                        .font(AppFonts.sans(23, .semibold))
                        .foregroundStyle(theme.foreground)
                    Text(String(format: "%02d", model.agendaRows.count))
                        .font(AppFonts.mono(11))
                        .foregroundStyle(theme.mutedForeground)
                }
                .cssLine(23)
                Spacer(minLength: 8)
                IconButton(icon: model.isSearchOpen ? .close : .search, size: 17, help: model.isSearchOpen ? "Close search" : "Find events (/)") {
                    if model.isSearchOpen { model.closeSearch(); Task { await model.reloadAgenda() } } else { model.openSearch() }
                }
            }
            HStack(spacing: 8) {
                Text(rangeText).font(AppFonts.mono(10)).foregroundStyle(theme.mutedForeground)
                Spacer()
                navButton("{", help: "Day before ({)") { model.moveAgendaStart(days: -1) }
                navButton("}", help: "Day after (})") { model.moveAgendaStart(days: 1) }
                navButton("t", help: "Today (t)") { model.agendaToday() }
            }
            .padding(.top, 10)
            if model.isSearchOpen {
                AgendaSearchField().padding(.top, 14)
            }
            if let message = statusMessage {
                Text(message)
                    .font(AppFonts.sans(10))
                    .foregroundStyle(theme.yellow)
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var statusMessage: String? {
        if model.services.calendarEngine == nil {
            return model.services.isGmail ? "Calendar not connected. Press : and choose “Connect Google Calendar”." : "No calendar for this account."
        }
        switch model.calendarStatus.phase {
        case .offline: return "Offline. Changes wait and go out when the network is back."
        case .signedOut: return "Signed out. Sign in again to sync the calendar."
        case .notConnected: return "Calendar access was not granted. Connect Google Calendar again."
        case .failed: return model.calendarStatus.message
        default: return nil
        }
    }

    private func navButton(_ key: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { KeyChip(key, alwaysVisible: true) }
            .buttonStyle(.plain)
            .help(help)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.agendaSections) { section in
                        Text(section.title.uppercased())
                            .font(AppFonts.mono(9))
                            .tracking(1.2)
                            .foregroundStyle(section.isWaiting ? theme.yellow : theme.mutedForeground)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                        ForEach(section.items) { item in
                            AgendaRow(item: item, isCursor: item.id == model.agendaCursorID, readerFocused: model.focus == .reader,
                                      overlaps: model.agendaOverlaps.contains(item.id))
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectAgendaItem(item.id)
                                    if NSApp.currentEvent?.clickCount == 2 { model.openAgendaItem() }
                                }
                        }
                    }
                    if model.agendaSections.isEmpty {
                        VStack(spacing: 8) {
                            Icon(name: .calendar, size: 28).foregroundStyle(theme.green).padding(.bottom, 8)
                            Text(model.searchText.isEmpty ? "Nothing scheduled" : "No events match").font(AppFonts.sans(14)).foregroundStyle(theme.foreground)
                            Text(model.searchText.isEmpty ? "Nothing on your calendar in these two weeks." : "Nothing matches “\(model.searchText)”.")
                                .font(AppFonts.sans(12)).foregroundStyle(theme.mutedForeground).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: model.agendaCursorID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private var footer: some View {
        HStack {
            let waiting = model.agendaSections.first(where: \.isWaiting)?.items.count ?? 0
            Text("\(model.agendaRows.count - waiting) events\(waiting > 0 ? " · \(waiting) waiting" : "")")
            Spacer()
            (Text("Y M N").foregroundColor(theme.green) + Text(" answer · ") + Text("gm").foregroundColor(theme.green) + Text(" mail"))
                .opacity(model.settings.alwaysShowKeyHints ? 1 : 0.8)
        }
        .font(AppFonts.mono(9))
        .foregroundStyle(theme.mutedForeground)
        .padding(.horizontal, 20)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

private struct AgendaSearchField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Icon(name: .search, size: 15).foregroundStyle(theme.mutedForeground).padding(.leading, 12).padding(.trailing, 9)
            TextField("Find events: title, place, guest", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(AppFonts.sans(12))
                .foregroundStyle(theme.foreground)
                .focused($focused)
            KeyChip("/", alwaysVisible: !focused).padding(.trailing, 10)
        }
        .frame(height: 36)
        .background(theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border.opacity(0.6), lineWidth: 1))
        .onAppear { focused = model.focusTarget == .search }
        .onChange(of: model.focusTarget) { _, target in focused = target == .search }
        .onChange(of: focused) { _, isFocused in
            if isFocused { model.focusTarget = .search } else if model.focusTarget == .search { model.focusTarget = nil }
        }
    }
}

/// One event: time, title, who, and its state.
private struct AgendaRow: View {
    @Environment(\.theme) private var theme
    let item: AgendaItem
    let isCursor: Bool
    let readerFocused: Bool
    let overlaps: Bool
    @State private var hovering = false

    private var isWaiting: Bool { item.originalStart.hasPrefix("waiting:") }
    private var fromMail: Bool { item.calendarID == AppModel.mailOnlyCalendarID }
    private var response: ResponseStatus? { item.event.selfResponse }

    private var timeText: String {
        if isWaiting { return Formatting.eventShort(item.start) }
        if item.start.isAllDay { return "all day" }
        return "\(Formatting.time(item.start.instant()))–\(Formatting.time(item.end.instant()))"
    }

    private var who: String {
        let others = item.event.attendees.filter { !$0.isSelf && !$0.isResource && !$0.isOrganizer }
        var parts: [String] = []
        if let organizer = item.event.organizer, !organizer.isSelf { parts.append(organizer.name ?? organizer.email) }
        parts += others.prefix(2).map { $0.name ?? $0.email }
        if others.count > 2 { parts.append("+\(others.count - 2)") }
        if fromMail { parts.append("from mail, not on Google Calendar") }
        if parts.isEmpty, item.event.conferenceURL != nil { parts.append("video call") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timeText)
                .font(AppFonts.mono(10))
                .foregroundStyle(theme.mutedForeground)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.event.summary)
                        .font(AppFonts.sans(12, .medium))
                        .foregroundStyle(response == .declined ? theme.mutedForeground : theme.foreground)
                        .strikethrough(response == .declined)
                        .lineLimit(1)
                    if item.seriesID != nil {
                        Text("repeats").font(AppFonts.mono(9)).foregroundStyle(theme.mutedForeground)
                    }
                }
                if !who.isEmpty {
                    Text(who).font(AppFonts.sans(10)).foregroundStyle(theme.mutedForeground).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            stateChip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCursor ? theme.selected.opacity(0.8) : (hovering ? theme.muted.opacity(0.6) : .clear), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if isCursor {
                Capsule().fill(readerFocused ? theme.mutedForeground : theme.green).frame(width: 2).padding(.vertical, 12)
            } else if fromMail {
                Rectangle().fill(theme.blue).frame(width: 2).padding(.vertical, 8).opacity(0.6)
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var stateChip: some View {
        if item.event.status == .cancelled {
            LabelChip(name: "cancelled", colorIndex: 6)
        } else if response == .needsAction || fromMail {
            LabelChip(name: "needs answer", colorIndex: 3)
        } else if response == .tentative {
            LabelChip(name: "maybe", colorIndex: 3)
        } else if overlaps, response != .declined {
            LabelChip(name: "overlaps", colorIndex: 6)
        }
    }
}
