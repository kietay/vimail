import AppKit
import MailCore
import SwiftUI

struct ThreadListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var footerHover = false
    @AppStorage("threadListWidth") private var width: Double = ThreadListView.defaultWidth
    @State private var dragStartWidth: Double?

    static let defaultWidth: Double = 370
    static let widthRange: ClosedRange<Double> = 300...760

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            footer
        }
        .frame(width: width)
        .background(theme.list.opacity(0.8))
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border.opacity(0.6)).frame(width: 1) }
        .overlay(alignment: .trailing) { resizeHandle }
    }

    /// Invisible strip over the trailing border: drag to resize, double-click to reset.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: 4)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        dragStartWidth = start
                        width = min(max(start + value.translation.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .onTapGesture(count: 2) { width = Self.defaultWidth }
    }

    // MARK: Header (px-5 pt-6 pb-4)

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.destinationTitle)
                        .font(AppFonts.sans(23, .semibold))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    Text(String(format: "%02d", model.totalCount))
                        .font(AppFonts.mono(11))
                        .foregroundStyle(theme.mutedForeground)
                }
                .cssLine(23)
                Spacer(minLength: 8)
                if let view = model.currentView {
                    IconButton(icon: .views, size: 15, help: "Edit view") { model.overlay = .viewEditor(view) }
                        .padding(.trailing, 8)
                }
                IconButton(icon: model.isSearchOpen ? .close : .search, size: 17, help: model.isSearchOpen ? "Close search" : "Search (/)") {
                    if model.isSearchOpen { model.closeSearch() } else { model.openSearch() }
                }
            }
            if let view = model.currentView {
                Text(viewSummary(view))
                    .font(AppFonts.sans(10))
                    .foregroundStyle(theme.mutedForeground)
                    .cssLine(10)
                    .padding(.top, 8)
            }
            if model.isSearchOpen {
                SearchField()
                    .padding(.top, 16)
            }
            HStack(alignment: .top, spacing: 20) {
                ForEach(ListFilter.allCases, id: \.self) { filter in
                    filterTab(filter)
                }
                Spacer()
                Button { model.markVisibleRead() } label: {
                    Icon(name: .check, size: 14).foregroundStyle(theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .help("Mark all as read")
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private func viewSummary(_ view: SavedView) -> String {
        var parts = [view.mailbox?.title ?? "All mailboxes"]
        if view.status != .any { parts.append(view.status.rawValue) }
        if let label = view.labelID.flatMap({ id in model.labels.first { $0.id == id } }) { parts.append(label.name) }
        if view.starredOnly { parts.append("starred") }
        if !view.sender.isEmpty { parts.append("from “\(view.sender)”") }
        if !view.text.isEmpty { parts.append("“\(view.text)”") }
        return parts.joined(separator: " · ")
    }

    /// Tabs: text-[11px] pb-2 with a 2px green underline when active.
    private func filterTab(_ filter: ListFilter) -> some View {
        let active = model.listFilter == filter
        return Button { model.setFilter(filter) } label: {
            HStack(spacing: 6) {
                Text(filter.rawValue)
                    .font(AppFonts.sans(11, active ? .semibold : .regular))
                    .foregroundStyle(active ? theme.foreground : theme.mutedForeground)
                    .cssLine(11)
                if filter == .unread {
                    Text("\(model.counts["list-unread"] ?? 0)")
                        .font(AppFonts.mono(9))
                        .foregroundStyle(theme.mutedForeground)
                        .cssLine(9)
                        .padding(.horizontal, 6)
                        .background(theme.muted, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                if active { Rectangle().fill(theme.green).frame(height: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: List (px-2 pb-2, rows mb-1)

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach(Array(model.threads.enumerated()), id: \.element.id) { index, thread in
                        ThreadRow(
                            thread: thread,
                            index: index,
                            isCursor: thread.id == model.cursorID,
                            isSelected: model.selection.contains(thread.id),
                            readerFocused: model.focus == .reader
                        )
                        .equatable()
                        .id(thread.id)
                        .contentShape(Rectangle())
                        .onTapGesture { click(thread.id) }
                        .contextMenu { contextMenu(thread) }
                        .onAppear { model.loadMoreIfNeeded(near: thread.id) }
                    }
                    if model.threads.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.cursorID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func click(_ id: String) {
        let flags = NSEvent.modifierFlags
        model.select(id, extend: flags.contains(.shift), toggle: flags.contains(.command))
        if NSApp.currentEvent?.clickCount == 2 { model.openCurrent() }
    }

    @ViewBuilder
    private func contextMenu(_ thread: ThreadSummary) -> some View {
        let targets = model.selection.contains(thread.id) ? model.actionTargets : [thread.id]
        Button(thread.has(label: SystemLabel.inbox) ? "Archive" : "Move to Inbox") {
            model.perform(thread.has(label: SystemLabel.inbox) ? .archive : .moveToInbox, on: targets)
        }
        Button("Move to Trash") { model.perform(.trash, on: targets) }
        Button(thread.isStarred ? "Unstar" : "Star") { model.perform(thread.isStarred ? .unstar : .star, on: targets) }
        Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") { model.perform(thread.isUnread ? .markRead : .markUnread, on: targets) }
        Divider()
        Button("Label…") { model.cursorID = thread.id; model.openPicker(.label) }
        Button("Move to…") { model.cursorID = thread.id; model.openPicker(.move) }
        Button("Snooze…") { model.cursorID = thread.id; model.openPicker(.snooze) }
        Button("Quick Snooze") { model.quickSnooze(on: targets) }
        Divider()
        Button("Create Rule from This…") { model.newRuleFromThread(thread.id) }
        Divider()
        Button("Report Spam") { model.perform(.spam, on: targets) }
    }

    /// px-6 py-20, centered.
    private var emptyState: some View {
        VStack(spacing: 0) {
            Icon(name: .inbox, size: 28).foregroundStyle(theme.green).padding(.bottom, 16)
            Text(model.searchText.isEmpty ? "No messages" : "No results")
                .font(AppFonts.sans(14))
                .foregroundStyle(theme.foreground)
                .cssLine(14, 20 / 14)
            Text(emptyDetail)
                .font(AppFonts.sans(12))
                .foregroundStyle(theme.mutedForeground)
                .multilineTextAlignment(.center)
                .cssLine(12, 16 / 12)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .padding(.horizontal, 24)
    }

    private var emptyDetail: String {
        if !model.searchText.isEmpty { return "Nothing matches “\(model.searchText)” here. Try in:anywhere." }
        if model.syncStatus.initialSyncProgress != nil { return "Downloading your mail…" }
        if model.destination == .mailbox(.inbox) { return "Inbox zero. Nice." }
        return "No messages here."
    }

    // MARK: Footer (h-10 px-5, mono 9)

    private var footer: some View {
        HStack {
            Text("\(model.totalCount) messages · \(model.counts["list-unread"] ?? 0) unread")
            Spacer()
            if !model.selection.isEmpty {
                Text("\(model.selection.count) selected").foregroundStyle(theme.purple)
            } else {
                (Text("j").foregroundColor(theme.green) + Text(" / ") + Text("k").foregroundColor(theme.green) + Text(" to navigate"))
                    .opacity(footerHover || model.settings.alwaysShowKeyHints ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: footerHover)
            }
        }
        .font(AppFonts.mono(9))
        .foregroundStyle(theme.mutedForeground)
        .padding(.horizontal, 20)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
        .onHover { footerHover = $0 }
    }
}

private struct SearchField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Icon(name: .search, size: 15)
                .foregroundStyle(theme.mutedForeground)
                .padding(.leading, 12)
                .padding(.trailing, 9)
            TextField("Search your mail", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(AppFonts.sans(12))
                .foregroundStyle(theme.foreground)
                .focused($focused)
            KeyChip("/", alwaysVisible: !focused)
                .padding(.trailing, 10)
        }
        .frame(height: 36)
        .background(theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border.opacity(0.6), lineWidth: 1))
        .onAppear { focused = model.focusTarget == .search }
        .onChange(of: model.focusTarget) { _, target in focused = target == .search }
        .onChange(of: focused) { _, isFocused in
            if isFocused { model.focusTarget = .search } else if model.focusTarget == .search { model.focusTarget = nil }
        }
        .help("Gmail syntax: from: -from: to: subject: label: -label: in: is:unread is:list has:attachment before: after:")
    }
}

/// One conversation row: px-3 py-4, rounded-xl; the cursor row gets the selected card and a 2px accent.
struct ThreadRow: View, Equatable {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let thread: ThreadSummary
    let index: Int
    let isCursor: Bool
    let isSelected: Bool
    let readerFocused: Bool
    @State private var hovering = false

    static func == (lhs: ThreadRow, rhs: ThreadRow) -> Bool {
        lhs.thread == rhs.thread && lhs.index == rhs.index && lhs.isCursor == rhs.isCursor
            && lhs.isSelected == rhs.isSelected && lhs.readerFocused == rhs.readerFocused
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(AppFonts.mono(10))
                .foregroundStyle(isSelected ? theme.purple : theme.mutedForeground)
                .cssLine(10)
                .fixedSize()
                .frame(width: 12, alignment: .leading)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(thread.participants)
                        .font(AppFonts.sans(12, thread.isUnread ? .semibold : .medium))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)").font(AppFonts.mono(9)).foregroundStyle(theme.mutedForeground)
                    }
                    if thread.isUnread {
                        Circle().fill(theme.primary).frame(width: 6, height: 6)
                    }
                    Spacer(minLength: 4)
                    if thread.hasAttachments {
                        Icon(name: .attach, size: 11).foregroundStyle(theme.mutedForeground)
                    }
                    Text(Formatting.listDate(thread.lastDate))
                        .font(AppFonts.mono(9))
                        .foregroundStyle(theme.mutedForeground)
                        .fixedSize()
                }
                .cssLine(12)
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(AppFonts.sans(12, .medium))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .cssLine(12)
                    .padding(.top, 6)
                Text(thread.snippet)
                    .font(AppFonts.sans(11))
                    .foregroundStyle(theme.mutedForeground)
                    .lineLimit(1)
                    .cssLine(11)
                    .padding(.top, 6)
                chipsRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isCursor ? theme.green.opacity(0.15) : .clear, lineWidth: 1))
        .overlay(alignment: .leading) {
            if isCursor {
                Capsule().fill(readerFocused ? theme.mutedForeground : theme.green).frame(width: 2).padding(.vertical, 20)
            }
        }
        .shadow(color: isCursor ? .black.opacity(0.035) : .clear, radius: 4, y: 2)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if isSelected { return theme.selection.opacity(isCursor ? 0.75 : 0.5) }
        if isCursor { return theme.selected.opacity(0.8) }
        if hovering { return theme.muted.opacity(0.6) }
        return .clear
    }

    /// mt-2.5: chips on the left, star on the right.
    @ViewBuilder
    private var chipsRow: some View {
        let labels = model.labels.filter { $0.kind != .system && thread.labelIDs.contains($0.id) }
        if !labels.isEmpty || thread.isStarred || thread.snoozedUntil != nil || thread.draftID != nil {
            HStack(spacing: 6) {
                if thread.draftID != nil { LabelChip(name: "draft", colorIndex: 1) }
                if let until = thread.snoozedUntil { LabelChip(name: "until \(Formatting.listDate(until))", colorIndex: 3) }
                ForEach(labels.prefix(3)) { label in
                    LabelChip(name: label.name, colorIndex: label.paletteIndex(count: 7))
                }
                Spacer(minLength: 0)
                if thread.isStarred {
                    Icon(name: .star, size: 12, filled: true).foregroundStyle(theme.yellow)
                }
            }
            .frame(minHeight: 18)
            .padding(.top, 10)
        }
    }
}
