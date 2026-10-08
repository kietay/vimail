import AppKit
import MailCore
import MailStore
import MailSync
import Observation
import SwiftUI
import VimailKit
import VimailLog

enum Pane { case list, reader }

/// Which text input should have keyboard focus. Mirrors SwiftUI `@FocusState` in the views.
enum FocusTarget: Hashable {
    case search, omnibox, picker
    case composeTo, composeCc, composeBcc, composeSubject, composeBody
    case viewName, viewSender, viewText
    case settingsSignature, settingsEditor
}

enum PickerKind: Equatable { case label, move, snooze, goToLabel }

enum Overlay: Equatable {
    case omnibox
    case help
    case settings
    case views
    case viewEditor(SavedView)
    case picker(PickerKind)
    case confirm(Confirmation)
}

struct Confirmation: Equatable {
    enum Action: Equatable { case deleteForever([String]), discardDraft(String), resetDummy, signOut }
    var title: String
    var message: String
    var confirmTitle: String
    var action: Action
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var undoable = false
    var isError = false
}

enum Mode: String {
    case normal = "NORMAL", insert = "INSERT", visual = "VISUAL", goto = "GOTO", command = "COMMAND", search = "SEARCH", vim = "VIM", compose = "COMPOSE"
}

enum UndoEntry {
    case action(UndoRecord)
    case send(outboxID: Int64, draft: Draft, localMessageID: String)
}

@MainActor
@Observable
final class AppModel {
    // MARK: Services and persisted state

    /// The open account. Replaced when you switch between dummy data and Gmail.
    private(set) var services: AppServices
    let reader = ReaderController()
    @ObservationIgnored private let settingsFile = JSONFile<AppSettings>(AppPaths.settings)
    @ObservationIgnored private let sessionFile = JSONFile<SessionState>(AppPaths.session)

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsFile.save(settings)
            settingsChanged(from: oldValue)
        }
    }

    var session: SessionState {
        didSet { if session != oldValue { sessionFile.save(session) } }
    }

    /// Tracks macOS light/dark for the Auto appearance mode.
    var systemIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
        didSet { if systemIsDark != oldValue { themeMayHaveChanged(from: settings, systemWasDark: oldValue) } }
    }
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    var themeID: ThemeID { settings.theme(systemIsDark: systemIsDark) }
    var theme: Theme { Theme(palette: .of(themeID)) }

    // MARK: Data

    var account = EmailAddress(name: "", email: "")
    var labels: [MailLabel] = []
    var unreadCounts: [String: Int] = [:]
    var counts: [String: Int] = [:]
    var views: [SavedView] = []
    var threads: [ThreadSummary] = []
    var totalCount = 0
    var hasMore = false
    var currentThread: MailThread?
    var syncStatus = SyncEngine.Status()
    /// The account's own signature from Gmail settings (HTML), when it has one.
    var accountSignatureHTML: String?
    /// True while Google sign-in is open in the browser.
    var signingIn = false

    // MARK: UI state

    var cursorID: String? {
        didSet { if cursorID != oldValue { cursorDidChange() } }
    }
    var selection: Set<String> = []
    var visualAnchorID: String?
    var focus: Pane = .list
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    var isSearchOpen = false
    var overlay: Overlay? {
        didSet { if overlay != oldValue { overlayChanged(from: oldValue) } }
    }
    var compose: ComposeModel?
    var toast: Toast?
    var pendingKeys = ""
    var focusTarget: FocusTarget?
    var hoveringHints = false

    // Omnibox and picker state.
    var omniQuery = "" {
        didSet { if omniQuery != oldValue { omniHighlighted = 0; scheduleOmniSearch() } }
    }
    var omniHighlighted = 0
    var omniMessages: [ThreadSummary] = []
    var pickerQuery = "" {
        didSet { if pickerQuery != oldValue { pickerHighlighted = 0 } }
    }
    var pickerHighlighted = 0

    // MARK: Internals

    @ObservationIgnored var parser = KeySequenceParser()
    @ObservationIgnored var undoStack: [UndoEntry] = []
    @ObservationIgnored var redoStack: [UndoRecord] = []
    @ObservationIgnored var lastAction: (action: ThreadAction, labelName: String?)?
    @ObservationIgnored var pickerTargets: [String] = []
    @ObservationIgnored private var pendingChange = StoreChange()
    @ObservationIgnored private var reloadScheduled = false
    @ObservationIgnored private var listGeneration = 0
    @ObservationIgnored private var threadTask: Task<Void, Never>?
    @ObservationIgnored private var markReadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var omniTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored var keyTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var threadCache: [String: MailThread] = [:]
    @ObservationIgnored private var renderedThreadID: String?
    @ObservationIgnored private var storeObserver: UUID?
    @ObservationIgnored var signInTask: Task<Void, Never>?
    static let pageSize = 400

    static let log = Log("app")

    init() throws {
        LogFile.shared.start(directory: AppPaths.logs)
        let info = Bundle.main.infoDictionary
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        Self.log.info("vimail \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(build), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)) started. Data: \(AppPaths.root.path)")
        AppFonts.register()
        let settings = settingsFile.load(default: AppSettings())
        self.settings = settings
        self.session = sessionFile.load(default: SessionState())
        services = try AppServices(settings: settings)
        reader.setTheme(.of(settings.theme(systemIsDark: systemIsDark)))
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
        }
        reader.onAction = { [weak self] name in self?.readerAction(name) }
        reader.onAttachment = { [weak self] messageID, attachmentID in self?.openAttachment(messageID: messageID, attachmentID: attachmentID) }
        reader.onMailto = { [weak self] url in self?.composeMailto(url) }
        reader.onInlineImage = { [weak self] messageID, contentID in await self?.inlineImage(messageID: messageID, contentID: contentID) }

        observeStore()
        Task { await self.bootstrap() }
    }

    private func observeStore() {
        storeObserver = services.store.observe { [weak self] change in
            Task { @MainActor in self?.storeDidChange(change) }
        }
    }

    private func bootstrap() async {
        await reloadLabels()
        await reloadViews()
        await reloadAccount()
        cursorID = session.cursors[session.destination.key]
        await reloadList()
        await reloadCounts()
        listenToSync()
        await services.start()
    }

    private func reloadAccount() async {
        account = (try? await services.store.account()) ?? EmailAddress(name: "", email: "")
        accountSignatureHTML = try? await services.store.accountSignatureHTML()
    }

    /// Closes the current account and opens the one the settings select (dummy data or Gmail).
    /// Local state of the closed account stays on disk; an open compose is saved as a draft first.
    func reopenAccount() async {
        Self.log.info("Switching account: \(services.accountKey) → \(settings.dataSource == .gmail ? GmailAccounts.accountKey(email: settings.gmailAccount) : "dummy")")
        if let compose {
            await compose.finish()
            self.compose = nil
        }
        let old = services
        await old.stop()
        if let storeObserver { old.store.removeObserver(storeObserver) }
        do {
            services = try AppServices(settings: settings)
        } catch {
            Self.log.error("Could not open the account: \(error)")
            showToast("Could not open the account: \(error.localizedDescription)", isError: true)
            services = old
            observeStore()
            await old.start()
            return
        }
        threads = []
        totalCount = 0
        hasMore = false
        currentThread = nil
        labels = []
        views = []
        counts = [:]
        unreadCounts = [:]
        selection = []
        visualAnchorID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        lastAction = nil
        threadCache.removeAll()
        renderedThreadID = nil
        syncStatus = SyncEngine.Status()
        // Saved views belong to an account; another account may not have the one that was open.
        if case .view = session.destination { session.destination = .mailbox(.inbox) }
        cursorID = nil
        reader.render(.empty("Loading…", dark: theme.palette.isDark))
        observeStore()
        await bootstrap()
    }

    private func listenToSync() {
        let engine = services.engine
        let statusUpdates = engine.statusUpdates
        let events = engine.events
        Task { [weak self] in
            for await status in statusUpdates {
                guard let self, self.services.engine === engine else { return }
                self.syncStatus = status
                if status.initialSyncProgress == nil, self.account.email.isEmpty || self.accountSignatureHTML == nil {
                    await self.reloadAccount()
                }
            }
        }
        Task { [weak self] in
            for await event in events {
                guard let self, self.services.engine === engine else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: SyncEngine.Event) {
        switch event {
        case .newMail(let ids):
            showToast(ids.count == 1 ? "New message." : "\(ids.count) new messages.")
            NSApp.dockTile.badgeLabel = (unreadCounts[SystemLabel.inbox] ?? 0) > 0 ? "\(unreadCounts[SystemLabel.inbox] ?? 0)" : nil
        case .sent:
            showToast("Message sent.")
        case .sendFailed(let draft, let reason):
            showToast("Send failed: \(reason). Saved to Drafts.", isError: true)
            undoStack.removeAll { if case .send(_, let pending, _) = $0 { return pending.id == draft.id } else { return false } }
        case .operationFailed(let reason):
            showToast(reason, isError: true)
        }
    }

    // MARK: - Store changes

    private func storeDidChange(_ change: StoreChange) {
        pendingChange.formUnion(change)
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(12))
            reloadScheduled = false
            let change = pendingChange
            pendingChange = StoreChange()
            await apply(change)
        }
    }

    private func apply(_ change: StoreChange) async {
        if change.labels || change.reset { await reloadLabels() }
        if change.views || change.reset { await reloadViews() }
        for id in change.threadIDs { threadCache[id] = nil }
        if change.reset { threadCache.removeAll() }
        await reloadList()
        await reloadCounts()
        if let id = cursorID, change.reset || change.threadIDs.contains(id) || (change.drafts && id.hasPrefix("draft:")) {
            await loadCurrentThread(preserveScroll: true)
        }
        if change.reset { await reloadAccount() }
        let inboxUnread = unreadCounts[SystemLabel.inbox] ?? 0
        NSApp.dockTile.badgeLabel = inboxUnread > 0 ? "\(inboxUnread)" : nil
    }

    func reloadLabels() async {
        labels = (try? await services.store.labels()) ?? labels
        // Seed the design's default views once the account's labels are known.
        if labels.contains(where: { $0.kind == .system }) {
            let work = labels.first { $0.name.lowercased() == "work" && $0.kind != .system }
            try? await services.store.seedDefaultViewsIfNeeded(workLabelID: work?.id)
        }
    }

    func reloadViews() async {
        views = (try? await services.store.savedViews()) ?? views
        if case .view(let id) = destination, !views.contains(where: { $0.id == id }) {
            navigate(to: .mailbox(.inbox))
        }
    }

    func reloadCounts() async {
        var queries: [String: ThreadQuery] = [
            "drafts": .mailbox(.drafts),
            "snoozed": .mailbox(.snoozed),
            "list-unread": baseQuery.applying(.unread),
        ]
        for view in views where view.pinned { queries["view:\(view.id)"] = view.query }
        let store = services.store
        let allQueries = queries
        async let unread = store.unreadCounts()
        async let all = store.counts(allQueries)
        unreadCounts = (try? await unread) ?? unreadCounts
        counts = (try? await all) ?? counts
    }

    // MARK: - Destination and queries

    var destination: Destination { session.destination }
    var listFilter: ListFilter { session.filter }

    var currentView: SavedView? {
        if case .view(let id) = destination { return views.first { $0.id == id } }
        return nil
    }

    var currentMailbox: Mailbox? {
        if case .mailbox(let mailbox) = destination { return mailbox }
        return currentView?.mailbox
    }

    var destinationTitle: String {
        switch destination {
        case .mailbox(.label(let id)): labels.first { $0.id == id }?.name ?? "Label"
        case .mailbox(let mailbox): mailbox.title
        case .view(let id): views.first { $0.id == id }?.name ?? "View"
        }
    }

    var baseQuery: ThreadQuery {
        switch destination {
        case .mailbox(let mailbox): .mailbox(mailbox)
        case .view: currentView?.query ?? .mailbox(.inbox)
        }
    }

    var currentQuery: ThreadQuery {
        var query = baseQuery.applying(listFilter)
        let search = searchText.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { query = query.narrowed(by: SearchQuery.parse(search)) }
        return query
    }

    var isDraftsList: Bool {
        if case .mailbox(.drafts) = destination { return true }
        return false
    }

    func navigate(to destination: Destination) {
        if let cursorID { session.cursors[self.destination.key] = cursorID }
        session.destination = destination
        session.filter = .all
        stickyIDs.removeAll()
        searchText = ""
        isSearchOpen = false
        clearSelection()
        focus = .list
        listGeneration += 1
        threads = []
        let remembered = session.cursors[destination.key]
        Task {
            await reloadList(preferredCursor: remembered)
            await reloadCounts()
        }
    }

    func setFilter(_ filter: ListFilter) {
        session.filter = filter
        refreshList()
    }

    /// Cycles Inbox → pinned views → Inbox.
    func cycleViews(_ direction: Int) {
        let ring: [Destination] = [.mailbox(.inbox)] + views.filter(\.pinned).map { .view($0.id) }
        let index = ring.firstIndex(of: destination) ?? -1
        let next = index < 0 ? (direction > 0 && ring.count > 1 ? 1 : ring.count - 1) : (index + direction + ring.count) % ring.count
        navigate(to: ring[next])
    }

    func reloadList(preferredCursor: String? = nil) async {
        let generation = listGeneration
        var pagedQuery = currentQuery
        pagedQuery.limit = max(Self.pageSize, threads.count)
        let query = pagedQuery
        let store = services.store
        let previousIndex = cursorID.flatMap { id in threads.firstIndex { $0.id == id } }
        async let rows = store.threads(query)
        async let total = store.count(query)
        guard var loaded = try? await rows else { return }
        var count = (try? await total) ?? loaded.count
        guard generation == listGeneration else { return }
        // Keep sticky rows that only left the list because their read state changed.
        let loadedIDs = Set(loaded.map(\.id))
        let missing = stickyIDs.subtracting(loadedIDs)
        if !missing.isEmpty, query.read != .any {
            var stickyQuery = query
            stickyQuery.read = .any
            stickyQuery.ids = Array(missing)
            stickyQuery.offset = 0
            let kept = (try? await store.threads(stickyQuery)) ?? []
            guard generation == listGeneration else { return }
            stickyIDs = Set(kept.map(\.id)).union(stickyIDs.intersection(loadedIDs))
            if !kept.isEmpty {
                loaded = Self.merge(loaded, kept, snoozedOrder: query.scope == .mailbox(.snoozed))
                count += kept.count
            }
        }
        if loaded != threads { threads = loaded }
        totalCount = count
        hasMore = loaded.count < count && !isDraftsList
        selection.formIntersection(Set(loaded.map(\.id)))
        reconcileCursor(preferred: preferredCursor, previousIndex: previousIndex)
    }

    /// Merges two lists in the list's sort order.
    static func merge(_ a: [ThreadSummary], _ b: [ThreadSummary], snoozedOrder: Bool) -> [ThreadSummary] {
        (a + b).sorted { lhs, rhs in
            if snoozedOrder, let l = lhs.snoozedUntil, let r = rhs.snoozedUntil, l != r { return l < r }
            return lhs.lastDate > rhs.lastDate
        }
    }

    /// Drops sticky rows and reloads (^l, or selecting the active tab again).
    func refreshList() {
        stickyIDs.removeAll()
        listGeneration += 1
        Task {
            await reloadList()
            await reloadCounts()
        }
    }

    func loadMoreIfNeeded(near id: String) {
        guard hasMore, let index = threads.firstIndex(where: { $0.id == id }), index > threads.count - 40 else { return }
        loadMore()
    }

    func loadMore() {
        guard hasMore else { return }
        let generation = listGeneration
        var query = currentQuery
        query.offset = threads.count
        query.limit = Self.pageSize
        Task {
            guard let more = try? await services.store.threads(query), generation == listGeneration else { return }
            let existing = Set(threads.map(\.id))
            threads += more.filter { !existing.contains($0.id) }
            hasMore = threads.count < totalCount
        }
    }

    private func reconcileCursor(preferred: String?, previousIndex: Int?) {
        if let preferred, threads.contains(where: { $0.id == preferred }) {
            cursorID = preferred
            return
        }
        if let cursorID, threads.contains(where: { $0.id == cursorID }) {
            if renderedThreadID != cursorID { cursorDidChange() }
            return
        }
        if threads.isEmpty {
            cursorID = nil
        } else if let previousIndex {
            cursorID = threads[min(previousIndex, threads.count - 1)].id
        } else {
            cursorID = threads.first?.id
        }
    }

    // MARK: - Cursor, selection and the reader

    var cursorIndex: Int? { cursorID.flatMap { id in threads.firstIndex { $0.id == id } } }
    var currentSummary: ThreadSummary? { cursorIndex.map { threads[$0] } }

    /// The conversations an action applies to: the selection, or the cursor.
    var actionTargets: [String] {
        if !selection.isEmpty { return threads.map(\.id).filter(selection.contains) }
        return cursorID.map { [$0] } ?? []
    }

    func moveCursor(by delta: Int) {
        guard !threads.isEmpty else { return }
        let index = cursorIndex ?? 0
        let target = min(max(index + delta, 0), threads.count - 1)
        cursorID = threads[target].id
        if visualAnchorID != nil { updateVisualSelection() }
        loadMoreIfNeeded(near: threads[target].id)
    }

    func moveCursor(to index: Int) {
        guard !threads.isEmpty else { return }
        cursorID = threads[min(max(index, 0), threads.count - 1)].id
        if visualAnchorID != nil { updateVisualSelection() }
    }

    func select(_ id: String, extend: Bool = false, toggle: Bool = false) {
        if toggle {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            if let cursorID, selection.isEmpty == false, !selection.contains(cursorID), cursorID != id { selection.insert(cursorID) }
        } else if extend, let anchor = cursorID, let from = threads.firstIndex(where: { $0.id == anchor }), let to = threads.firstIndex(where: { $0.id == id }) {
            selection.formUnion(threads[min(from, to)...max(from, to)].map(\.id))
        } else {
            clearSelection()
        }
        cursorID = id
        focus = .list
    }

    func clearSelection() {
        selection.removeAll()
        visualAnchorID = nil
    }

    func toggleVisual() {
        if visualAnchorID != nil {
            clearSelection()
        } else if let cursorID {
            visualAnchorID = cursorID
            selection = [cursorID]
        }
    }

    func updateVisualSelection() {
        guard let anchor = visualAnchorID, let cursorID,
              let from = threads.firstIndex(where: { $0.id == anchor }),
              let to = threads.firstIndex(where: { $0.id == cursorID }) else { return }
        selection = Set(threads[min(from, to)...max(from, to)].map(\.id))
    }

    private func cursorDidChange() {
        markReadTask?.cancel()
        if let cursorID { session.cursors[destination.key] = cursorID }
        Task { await loadCurrentThread(preserveScroll: false) }
        scheduleMarkRead()
    }

    func loadCurrentThread(preserveScroll: Bool) async {
        threadTask?.cancel()
        guard let id = cursorID else {
            currentThread = nil
            renderedThreadID = nil
            reader.render(.empty(threads.isEmpty ? "No messages here." : "Select a message", dark: theme.palette.isDark))
            return
        }
        if id.hasPrefix("draft:") {
            await renderDraftPreview(String(id.dropFirst(6)))
            return
        }
        if !preserveScroll, let cached = threadCache[id] {
            currentThread = cached
            render(cached, preserveScroll: false)
        }
        let scroll = preserveScroll && renderedThreadID == id ? await reader.scrollPosition() : nil
        threadTask = Task {
            guard let thread = try? await services.store.thread(id: id), !Task.isCancelled, cursorID == id else { return }
            threadCache[id] = thread
            if threadCache.count > 60 { threadCache.removeAll() }
            if thread != currentThread || renderedThreadID != id || preserveScroll {
                currentThread = thread
                render(thread, preserveScroll: scroll != nil, scroll: scroll)
            }
            prefetchNeighbors()
        }
    }

    private func prefetchNeighbors() {
        guard let index = cursorIndex else { return }
        for neighbor in [index - 1, index + 1] where threads.indices.contains(neighbor) {
            let id = threads[neighbor].id
            guard threadCache[id] == nil, !id.hasPrefix("draft:") else { continue }
            Task {
                if let thread = try? await services.store.thread(id: id) { threadCache[id] = thread }
            }
        }
    }

    func rerenderReader() {
        if let currentThread { render(currentThread, preserveScroll: true) } else { Task { await loadCurrentThread(preserveScroll: true) } }
    }

    private func render(_ thread: MailThread, preserveScroll: Bool, scroll: Double? = nil) {
        renderedThreadID = thread.id
        reader.render(readerPayload(for: thread, scroll: preserveScroll ? scroll : nil))
    }

    private func renderDraftPreview(_ draftID: String) async {
        guard let draft = try? await services.store.draft(id: draftID) else { return }
        renderedThreadID = "draft:\(draftID)"
        var payload = ReaderPayload()
        payload.dark = theme.palette.isDark
        payload.subject = draft.subject.isEmpty ? "(no subject)" : draft.subject
        payload.position = positionText
        payload.hasPrevious = (cursorIndex ?? 0) > 0
        payload.hasNext = (cursorIndex ?? 0) < threads.count - 1
        payload.showHints = settings.alwaysShowKeyHints
        payload.labels = [ReaderPayload.LabelChip(name: "draft", fg: theme.palette.orange, soft: theme.palette.orangeSoft)]
        payload.menu = [ReaderPayload.MenuItem(title: "Edit draft", icon: "file", key: "↵", action: "open"),
                        ReaderPayload.MenuItem(title: "Discard draft", icon: "trash", key: "#", action: "trash")]
        payload.messages = [ReaderPayload.Message(
            id: draft.id, fromName: account.displayName, fromFull: account.formatted, initials: account.initials,
            toShort: draft.to.isEmpty ? "no recipients" : "to \(draft.to.map(\.shortName).joined(separator: ", "))",
            toFull: draft.to.formattedList, ccFull: draft.cc.isEmpty ? nil : draft.cc.formattedList,
            time: Formatting.readerTime(draft.updatedAt), dateLong: "Edited \(Formatting.longDate(draft.updatedAt))",
            snippet: "", unread: false, expanded: true, focus: true, kind: "html",
            text: nil, html: Markdown.html(draft.body.isEmpty ? "*Empty draft. Press Enter to edit.*" : draft.body),
            attachments: draft.attachments.map { .init(id: $0.id, name: $0.filename, kind: ($0.filename as NSString).pathExtension.uppercased(), size: Formatting.fileSize($0.size)) },
            sending: false
        )]
        reader.render(payload)
    }

    /// True when replying to everyone reaches more than one person.
    var canReplyAll: Bool {
        guard let thread = currentThread, thread.id == cursorID else { return false }
        let me = services.store.selfAddresses
        guard let message = thread.latestReceived(excluding: me) else { return false }
        let others = (message.to + message.cc + [message.from]).filter { !me.contains($0.normalized) }
        return Set(others.map(\.normalized)).count > 1
    }

    var positionText: String {
        guard let index = cursorIndex else { return "0/\(totalCount)" }
        return "\(index + 1)/\(totalCount)"
    }

    private func readerPayload(for thread: MailThread, scroll: Double?) -> ReaderPayload {
        let me = services.store.selfAddresses
        var payload = ReaderPayload()
        payload.dark = theme.palette.isDark
        payload.subject = thread.subject
        payload.position = positionText
        payload.hasPrevious = (cursorIndex ?? 0) > 0
        payload.hasNext = (cursorIndex ?? 0) < threads.count - 1
        payload.allowRemote = settings.loadRemoteImages || remoteImagesAllowed.contains(thread.id)
        payload.showHints = settings.alwaysShowKeyHints
        payload.preserveScroll = scroll
        payload.labels = chips(for: thread.labelIDs)
        if let snoozed = thread.snoozedUntil {
            payload.labels.append(.init(name: "snoozed · \(Formatting.snoozeDate(snoozed))", fg: theme.palette.yellow, soft: theme.palette.yellowSoft))
        }
        let latestReceived = thread.latestReceived(excluding: me)
        payload.canReplyAll = latestReceived.map { ($0.to + $0.cc).filter { !me.contains($0.normalized) }.count + 1 > 1 } ?? false
        payload.menu = readerMenu(for: thread)

        let firstUnread = thread.messages.firstIndex(where: \.isUnread)
        let focusIndex = firstUnread ?? (thread.messages.count - 1)
        payload.messages = thread.messages.enumerated().map { index, message in
            let kind: String
            if let html = message.htmlBody, !html.isEmpty {
                kind = ReaderPayload.isRich(html) ? "rich" : "html"
            } else {
                kind = "text"
            }
            let fromMe = me.contains(message.from.normalized)
            return ReaderPayload.Message(
                id: message.id,
                fromName: fromMe ? "me" : message.from.displayName,
                fromFull: message.from.formatted,
                initials: message.from.initials,
                toShort: Formatting.recipientsShort(message, me: me),
                toFull: message.to.formattedList,
                ccFull: message.cc.isEmpty ? nil : message.cc.formattedList,
                time: Formatting.readerTime(message.date),
                dateLong: Formatting.longDate(message.date),
                snippet: message.snippet,
                unread: message.isUnread,
                expanded: message.isUnread || index == thread.messages.count - 1 || index == focusIndex,
                focus: index == focusIndex,
                kind: kind,
                text: kind == "text" ? message.plainText : nil,
                html: kind == "text" ? nil : Self.resolvingInlineImages(in: message),
                attachments: message.fileAttachments.map {
                    .init(id: $0.id, name: $0.filename, kind: $0.kindLabel, size: Formatting.fileSize($0.size))
                },
                sending: message.id.hasPrefix("local-")
            )
        }
        return payload
    }

    @ObservationIgnored var remoteImagesAllowed = Set<String>()

    /// Points `cid:` image references at the reader's inline image scheme.
    static func resolvingInlineImages(in message: MailMessage) -> String? {
        guard var html = message.htmlBody, html.range(of: "cid:", options: .caseInsensitive) != nil else { return message.htmlBody }
        for attachment in message.attachments {
            guard let contentID = attachment.contentID, !contentID.isEmpty else { continue }
            html = html.replacingOccurrences(of: "cid:\(contentID)", with: InlineImageSchemeHandler.url(messageID: message.id, contentID: contentID), options: .caseInsensitive)
        }
        return html
    }

    /// The bytes of an image a message embeds, from the disk cache or the provider.
    func inlineImage(messageID: String, contentID: String) async -> (Data, String)? {
        var message = currentThread?.messages.first { $0.id == messageID }
        if message == nil { message = try? await services.store.message(id: messageID) }
        guard let attachment = message?.attachments.first(where: { $0.contentID == contentID }) else { return nil }
        let file = AppPaths.caches
            .appendingPathComponent("inline", isDirectory: true)
            .appendingPathComponent(Self.safeFilename(messageID), isDirectory: true)
            .appendingPathComponent(Self.safeFilename(contentID))
        if let data = try? Data(contentsOf: file) { return (data, attachment.mimeType) }
        guard let data = try? await services.provider.attachmentData(messageID: messageID, attachmentID: attachment.id) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return (data, attachment.mimeType)
    }

    /// Conversations kept visible in a read-filtered list (Unread tab, unread views) after their
    /// read state changed, so reading does not make them vanish under the cursor. Cleared on
    /// navigation, filter or search changes, and on refresh (^l).
    @ObservationIgnored var stickyIDs = Set<String>()

    func chips(for labelIDs: some Sequence<String>) -> [ReaderPayload.LabelChip] {
        let palette = theme.palette.labelColors
        return labels
            .filter { $0.kind != .system && labelIDs.contains($0.id) }
            .map { label in
                let pair = palette[label.paletteIndex(count: palette.count)]
                return ReaderPayload.LabelChip(name: label.name, fg: pair.fg, soft: pair.soft)
            }
    }

    private func readerMenu(for thread: MailThread) -> [ReaderPayload.MenuItem] {
        typealias Item = ReaderPayload.MenuItem
        let inInbox = thread.labelIDs.contains(SystemLabel.inbox)
        return [
            Item(title: "Reply", icon: "reply", key: "r", action: "reply"),
            Item(title: "Reply all", icon: "reply", key: "a", action: "replyAll"),
            Item(title: "Forward", icon: "arrow", key: "f", action: "forward"),
            Item(separator: true),
            inInbox ? Item(title: "Archive", icon: "archive", key: "e", action: "archive") : Item(title: "Move to Inbox", icon: "inbox", key: "m", action: "moveToInbox"),
            Item(title: thread.labelIDs.contains(SystemLabel.trash) ? "Delete forever" : "Move to trash", icon: "trash", key: "#", action: "trash"),
            Item(title: thread.isStarred ? "Unstar" : "Star", icon: "star", key: "s", action: "star"),
            Item(title: thread.snoozedUntil == nil ? "Snooze…" : "Change snooze…", icon: "clock", key: "z", action: "snooze"),
            Item(title: thread.isUnread ? "Mark as read" : "Mark as unread", icon: "check", key: thread.isUnread ? "I" : "U", action: "toggleRead"),
            Item(title: "Label…", icon: "tag", key: "t", action: "label"),
            Item(title: "Move to…", icon: "folder", key: "m", action: "move"),
            Item(title: thread.labelIDs.contains(SystemLabel.spam) ? "Not spam" : "Report spam", icon: "spam", key: "!", action: "spam"),
        ]
    }

    private func scheduleMarkRead() {
        guard let summary = currentSummary, summary.isUnread, settings.markReadDelay >= 0 else { return }
        let id = summary.id
        let delay = settings.markReadDelay
        markReadTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, cursorID == id else { return }
            perform(.markRead, on: [id], recordUndo: false, silent: true)
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            stickyIDs.removeAll()
            listGeneration += 1
            await reloadList()
            await reloadCounts()
        }
    }

    func openSearch() {
        isSearchOpen = true
        focusTarget = .search
    }

    func closeSearch() {
        isSearchOpen = false
        searchText = ""
        focusTarget = nil
        blurTextInput()
    }

    // MARK: - Omnibox message search

    private func scheduleOmniSearch() {
        omniTask?.cancel()
        let query = omniQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            omniMessages = []
            return
        }
        omniTask = Task {
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            var search = ThreadQuery(scope: .everywhereExceptTrash).narrowed(by: SearchQuery.parse(query))
            search.limit = 6
            let results = (try? await services.store.threads(search)) ?? []
            guard !Task.isCancelled else { return }
            omniMessages = results
        }
    }

    // MARK: - Overlays, focus and toasts

    private func overlayChanged(from old: Overlay?) {
        switch overlay {
        case .omnibox:
            omniQuery = ""
            omniHighlighted = 0
            focusTarget = .omnibox
        case .picker:
            pickerQuery = ""
            pickerHighlighted = 0
            focusTarget = .picker
        case .viewEditor:
            focusTarget = .viewName
        case nil:
            if compose != nil { focusTarget = compose?.lastFocus ?? .composeBody } else { focusTarget = nil; blurTextInput() }
        default:
            focusTarget = nil
            blurTextInput()
        }
        reader.closeMenu()
    }

    func blurTextInput() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func showToast(_ text: String, undoable: Bool = false, isError: Bool = false) {
        toast = Toast(text: text, undoable: undoable, isError: isError)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 3.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    var mode: Mode {
        if compose?.vimRunning == true { return .vim }
        if let compose {
            if focusTarget == nil { return .compose }
            return focusTarget == .composeBody && compose.bodyMode == .normal ? .normal : .insert
        }
        switch overlay {
        case .omnibox: return .command
        case .picker, .viewEditor: return .insert
        default: break
        }
        if focusTarget == .search { return .search }
        if !pendingKeys.isEmpty && pendingKeys.last == "g" { return .goto }
        if visualAnchorID != nil || !selection.isEmpty { return .visual }
        return .normal
    }

    var showKeyHints: Bool { settings.alwaysShowKeyHints }

    // MARK: - Settings

    private func themeMayHaveChanged(from old: AppSettings, systemWasDark: Bool) {
        if old.theme(systemIsDark: systemWasDark) != themeID {
            reader.setTheme(.of(themeID))
            rerenderReader()
        }
    }

    private func settingsChanged(from old: AppSettings) {
        themeMayHaveChanged(from: old, systemWasDark: systemIsDark)
        if settings.signatures != old.signatures { compose?.refreshPreview() }
        if settings.loadRemoteImages != old.loadRemoteImages || settings.alwaysShowKeyHints != old.alwaysShowKeyHints {
            rerenderReader()
        }
        let services = services
        let settings = settings
        Task { await services.apply(settings) }
    }
}
