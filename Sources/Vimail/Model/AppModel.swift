import AppKit
import MailAI
import MailCore
import MailRules
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
    case consentBudget
    case ruleName, ruleWhen, ruleAsk, ruleLabel
    case quickAdd
    /// The event editor's fields.
    case eventTitle, eventWhen, eventGuests, eventWhere, eventRepeats, eventNotes
}

enum PickerKind: Equatable { case label, move, snooze, goToLabel, answerNote }

enum Overlay: Equatable {
    case omnibox
    case help
    case settings
    case views
    case viewEditor(SavedView)
    case picker(PickerKind)
    case confirm(Confirmation)
    /// "Why these labels?" for a conversation (`g?`).
    case explain(threadID: String)
    /// May this account's mail go to Claude?
    case aiConsent
    /// The rules manager and Activity (`gr`).
    case rules
    /// Writing or editing a rule (`ruleEditor`).
    case ruleEditor
    /// How far back a saved rule applies, or its re-check (`backfill`).
    case backfill
    /// C: one line that becomes an event.
    case quickAdd
    /// The event editor (Tab from quick add, Enter on your own event).
    case eventEditor
}

struct Confirmation: Equatable {
    enum Action: Equatable {
        case deleteForever([String]), discardDraft(String), resetDummy, signOut
        /// `=` on these messages, above 5¢.
        case runRules([String])
        case undoRuleRun(Int64)
        case deleteClaudeResults
    }
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
    /// When set, the toast shows the whole seconds left until this time and stays up until it passes.
    var countdownTo: Date?
    /// The words before the seconds: "Sending in 5s.", "Accepted by email · Design review · sends in 5s."
    var countdownLead = "in"
    /// A second sentence, after the countdown.
    var detail: String?
}

enum Mode: String {
    case normal = "NORMAL", insert = "INSERT", visual = "VISUAL", goto = "GOTO", command = "COMMAND", search = "SEARCH", vim = "VIM", compose = "COMPOSE"
}

enum UndoEntry {
    /// With the label edit rules were told about, so undoing it takes back what they learned.
    case action(UndoRecord, LabelEdit?)
    /// `archived` is the archive that archive-on-send did with it, if any.
    case send(outboxID: Int64, draft: Draft, localMessageID: String, archived: UndoRecord?)
    /// Unsubscribes waiting in the outbox, and the archive that went with them.
    case unsubscribe(outboxIDs: [Int64], lists: [String], archive: UndoRecord?)
    /// `=`: undoing takes off the labels the run added. There is no redo: press `=` again.
    case ruleRun(Int64)
    /// `x` or `a` in "why these labels?" when the label was already like that: undoing deletes the
    /// rule's example. There is no redo.
    case teaching(LabelEdit)
    /// Answers to invitations, and the archive that came with them: one u takes back both.
    case answer([CalendarActions.AnswerRecord], archive: UndoRecord?)
    /// Answers sent by email to invitations that are not on Google Calendar, the answers on Google Calendar given by
    /// the same key, and the archive that came with them: one u takes back all of it (an email only until it leaves).
    case answerByEmail([CalendarActions.EmailAnswerRecord], calendar: [CalendarActions.AnswerRecord], archive: UndoRecord?)
    /// A calendar event created, edited or removed.
    case eventChange(CalendarActions.ChangeRecord)
    /// Calendar changes made together, undone last first: "this and following" ends a series and starts the one after it.
    case eventChanges([CalendarActions.ChangeRecord])

    /// Answers to invitations, which `.` repeats on the next one.
    var isAnswer: Bool {
        switch self {
        case .answer, .answerByEmail: true
        case .action, .send, .unsubscribe, .ruleRun, .teaching, .eventChange, .eventChanges: false
        }
    }
}

/// Where the keys go in Settings: its list of sections (j/k, 1…n), or a text field in the section shown (tab).
enum SettingsFocus: Hashable { case sidebar, pane }

/// A ⌘U still checking how to unsubscribe. `u` cancels it then, before it has done anything.
final class UnsubscribeCheck {
    var cancelled = false
}

@MainActor
@Observable
final class AppModel {
    // MARK: Services and persisted state

    /// The open account. Replaced when you switch between dummy data and Gmail.
    private(set) var services: AppServices
    /// Claude for every account: key, limiter, spend. Survives account switches.
    let ai: AIServices
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
    var rulesStatus = RuleEngineStatus()
    /// Labels from rules that Gmail refused, since you last looked at the rules status.
    var rulesGmailRejected = 0
    /// Received mail a day over the last 30 days, for Claude estimates. nil until counted.
    var mailVolume: Double?

    // MARK: Calendar

    var calendarStatus = CalendarSyncEngine.Status()
    var calendars: [CalendarInfo] = []
    /// The calendar view's rows: invitations waiting for an answer, then two weeks of days.
    var agendaSections: [AgendaSection] = []
    /// Invitations waiting for your answer, for the sidebar (kept current outside the calendar view too).
    var waitingInvitationCount = 0
    /// The events (iCalendar UIDs) of the waiting list, for `invite:pending`.
    var waitingInvitationUIDs: [String] = []
    /// The events (iCalendar UIDs) of invitations that overlap something else you go to, for `invite:conflict`.
    var conflictingInvitationUIDs: [String] = []
    var agendaCursorID: String?
    /// Agenda rows that overlap another event you go to.
    var agendaOverlaps: Set<String> = []
    /// The first day the calendar view shows.
    var agendaStart = Calendar.current.startOfDay(for: Date())
    /// The day the minute timer last saw, to notice midnight.
    @ObservationIgnored var timerDay = Calendar.current.startOfDay(for: Date())
    /// The next meeting today or tomorrow, for the status bar and gj.
    var nextMeeting: AgendaItem?
    /// Invitation chips for the mail list, by conversation.
    var invitationChips: [String: InvitationChip] = [:]
    /// Event pages of conversations with an invitation, by conversation.
    @ObservationIgnored var eventPages: [String: ReaderPayload.EventPage] = [:]
    /// { and }: days the day column is shifted from the invitation's day.
    @ObservationIgnored var peekDays = 0
    /// The last answer, for . on the next invitation.
    @ObservationIgnored var lastAnswer: ResponseStatus?
    /// gc from an invitation: the event the calendar view should select once loaded.
    @ObservationIgnored var pendingAgendaEventID: String?
    /// The day the calendar view was opened for: of several rows of one series, the one on this day is selected.
    @ObservationIgnored var pendingAgendaDay: Date?
    /// Quick add (C): the typed line and how it reads.
    var quickAddText = "" {
        didSet { if quickAddText != oldValue { updateQuickAdd() } }
    }
    var quickAddResult: QuickAdd.Result?
    var quickAddDayNote: String?
    /// The day quick add starts from (the calendar view's selected day), when not today.
    @ObservationIgnored var quickAddDay: Date?
    /// Contact matches for names typed after "with", by lowercased name.
    @ObservationIgnored var quickAddContacts: [String: [EmailAddress]] = [:]
    var eventEditor: EventEditorModel?
    /// A new event closed with esc, offered again in quick add (tab).
    var quickAddDraft: EventDraft?
    /// The next meeting with each person, by address, for the reader's "Next with" line.
    @ObservationIgnored var nextMeetingByPerson: [String: AgendaItem] = [:]
    @ObservationIgnored var minuteTimer: Timer?

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

    // "Why these labels?", consent and Settings.
    var explainLines: [ExplainLine] = []
    var explainHighlighted = 0
    /// The model and budgets the consent panel offers.
    var consentDraft = AISettings()
    /// The section Settings shows: the last one used this session.
    var settingsSection = SettingsSection.general
    /// Nil while a control tab reached has the keys (full keyboard access), or nothing has.
    var settingsFocus: SettingsFocus?
    /// Tab adds one and ⇧tab takes one away, without full keyboard access. Settings moves the keyboard by the change,
    /// round its list and the section's text fields.
    var settingsTabs = 0

    // Rules: the manager, the rule being written (also while `L` or the omnibox has it put aside),
    // the "how far back" sheet, and the list of a rule's matches.
    var rulesManager: RulesManagerModel?
    var ruleEditor: RuleEditorModel?
    var backfill: BackfillModel?
    var ruleMatches: RuleMatches?

    // MARK: Internals

    @ObservationIgnored var parser = KeySequenceParser()
    @ObservationIgnored var undoStack: [UndoEntry] = []
    @ObservationIgnored var redoStack: [UndoRecord] = []
    @ObservationIgnored var lastAction: (action: ThreadAction, labelName: String?)?
    /// Unsubscribes that went through in a row, so a batch gets one toast.
    @ObservationIgnored private var unsubscribed: (count: Int, until: Date) = (0, .distantPast)
    /// Conversations a ⌘U is still working on, so a second ⌘U does not queue them again.
    @ObservationIgnored var unsubscribing = Set<String>()
    @ObservationIgnored var unsubscribeChecks: [UnsubscribeCheck] = []
    @ObservationIgnored var pickerTargets: [String] = []
    @ObservationIgnored private var pendingChange = StoreChange()
    @ObservationIgnored private var reloadScheduled = false
    @ObservationIgnored private var listGeneration = 0
    @ObservationIgnored private var threadTask: Task<Void, Never>?
    @ObservationIgnored private var markReadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var omniTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// The account switch under way: the next one waits for it.
    @ObservationIgnored private var accountSwitch: Task<Void, Never>?
    @ObservationIgnored var keyTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var threadCache: [String: MailThread] = [:]
    @ObservationIgnored private var renderedThreadID: String?
    /// Messages that were unread when the conversation on screen was opened. They stay expanded and
    /// marked new while it stays open, so marking it read does not fold away what you are reading.
    @ObservationIgnored private var newMessageIDs = Set<String>()
    @ObservationIgnored private var storeObserver: UUID?
    @ObservationIgnored var signInTask: Task<Void, Never>?
    /// Why each recently shown conversation carries its labels, for the reader's provenance.
    @ObservationIgnored var explanationCache: [String: ThreadExplanation] = [:]
    /// Runs once you allow Claude in the consent panel.
    @ObservationIgnored var afterConsent: (() -> Void)?
    /// The dialog that asked for consent, shown again when the panel closes.
    @ObservationIgnored var consentReturn: Overlay?
    /// The label last ticked in the label picker, for its "Always label mail like this…".
    @ObservationIgnored var lastPickedLabel: MailLabel?
    /// The latest report of a label edit to the rules. Each waits for the one before.
    @ObservationIgnored var ruleReport: Task<LabelEditNote?, Never>?
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
        let ai = AIServices(settings: settings.ai)
        self.ai = ai
        services = try AppServices(settings: settings, ai: ai)
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
        listenToRules()
        listenToCalendar()
        await services.start(ai: ai, paused: settings.ai.pauseAll)
        await refreshMailVolume()
        await calendarChanged()
        startMinuteTimer()
    }

    /// Keeps the next meeting and the calendar view current as time passes.
    private func startMinuteTimer() {
        guard minuteTimer == nil else { return }
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.reloadNextMeeting()
                await self.reloadWaitingCount()
                // A new day: "Today" moves on, in the calendar view and on event pages. Once, not every minute.
                let today = Calendar.current.startOfDay(for: Date())
                if today != self.timerDay {
                    self.timerDay = today
                    await self.calendarChanged()
                }
            }
        }
    }

    private func reloadAccount() async {
        account = (try? await services.store.account()) ?? EmailAddress(name: "", email: "")
        accountSignatureHTML = try? await services.store.accountSignatureHTML()
    }

    /// Closes the current account and opens the one the settings select (dummy data or Gmail).
    /// Local state of the closed account stays on disk; an open compose is saved as a draft first.
    /// Switches go one at a time: a second one waits for the first to finish, then opens what the
    /// settings select then, so no account is opened twice or left running unseen.
    func reopenAccount() async {
        let previous = accountSwitch
        let current = Task { [weak self] in
            await previous?.value
            await self?.switchAccount()
        }
        accountSwitch = current
        await current.value
    }

    private func switchAccount() async {
        Self.log.info("Switching account: \(services.accountKey) → \(settings.dataSource == .gmail ? GmailAccounts.accountKey(email: settings.gmailAccount) : "dummy")")
        if let compose {
            await compose.finish()
            self.compose = nil
        }
        // Opened before the old account stops: when it can't be opened, the old one keeps running
        // (a stopped rules engine can't start again).
        let next: AppServices
        do {
            next = try AppServices(settings: settings, ai: ai)
        } catch {
            Self.log.error("Could not open the account: \(error)")
            showToast("Could not open the account: \(error.localizedDescription)", isError: true)
            return
        }
        ruleEditor?.abandon()
        ruleEditor = nil
        backfill = nil
        rulesManager = nil
        ruleMatches = nil
        if [.rules, .ruleEditor, .backfill].contains(overlay) { overlay = nil }
        let old = services
        await old.stop()
        if let storeObserver { old.store.removeObserver(storeObserver) }
        services = next
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
        explanationCache.removeAll()
        renderedThreadID = nil
        syncStatus = SyncEngine.Status()
        rulesStatus = RuleEngineStatus()
        rulesGmailRejected = 0
        mailVolume = nil
        calendarStatus = CalendarSyncEngine.Status()
        calendars = []
        agendaSections = []
        agendaCursorID = nil
        nextMeeting = nil
        invitationChips = [:]
        waitingInvitationUIDs = []
        conflictingInvitationUIDs = []
        eventPages = [:]
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
            // A reply that did not go out should not stay archived.
            for case .send(_, let pending, _, let archived?) in undoStack where pending.id == draft.id {
                Task { try? await services.actions.undo(archived); await reloadList() }
            }
            undoStack.removeAll { if case .send(_, let pending, _, _) = $0 { return pending.id == draft.id } else { return false } }
        case .operationFailed(let reason):
            showToast(reason, isError: true)
        case .rulesGmailRejected(let count):
            // Not a toast: the rules status reports it.
            rulesGmailRejected += count
        case .unsubscribed(let list):
            let now = Date()
            unsubscribed = (unsubscribed.until > now ? unsubscribed.count + 1 : 1, now.addingTimeInterval(4))
            showToast(unsubscribed.count == 1 ? "Unsubscribed from \(list)." : "Unsubscribed from \(unsubscribed.count) lists.")
        case .unsubscribeFailed(let outboxID, let list, let reason):
            showToast("Could not unsubscribe from \(list): \(reason)", isError: true)
            // u must not claim it went through: it only brings the conversation back.
            undoStack = undoStack.compactMap { entry in
                guard case .unsubscribe(let ids, let lists, let archive) = entry, ids.contains(outboxID) else { return entry }
                let kept = ids.indices.filter { ids[$0] != outboxID }
                if kept.isEmpty { return archive.map { UndoEntry.action($0, nil) } }
                return .unsubscribe(outboxIDs: kept.map { ids[$0] }, lists: kept.map { lists[$0] }, archive: archive)
            }
        case .answerFailed(let outboxID, let summary, let reason, let outcome):
            let state = switch outcome {
            case .answerStands: "Your earlier answer stands."
            case .waitsAgain: "The invitation waits for your answer again."
            case .cancelledSince: "The meeting was cancelled since, so nothing waits."
            }
            showToast("Could not send your answer to \(summary): \(reason). \(state)", isError: true)
            // u has nothing left to take back for it; an answer that did not go out alone should not stay archived.
            undoStack = undoStack.compactMap { entry in
                guard case .answerByEmail(let emailed, let records, let archive) = entry, emailed.contains(where: { $0.outboxID == outboxID }) else { return entry }
                let kept = emailed.filter { $0.outboxID != outboxID }
                if !kept.isEmpty { return .answerByEmail(kept, calendar: records, archive: archive) }
                if !records.isEmpty { return .answer(records, archive: archive) }
                if let archive { Task { try? await services.actions.undo(archive); await reloadList() } }
                return nil
            }
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
        for id in change.threadIDs {
            threadCache[id] = nil
            explanationCache[id] = nil
        }
        if change.reset {
            threadCache.removeAll()
            explanationCache.removeAll()
        }
        await reloadList()
        await reloadCounts()
        if let id = cursorID, change.reset || change.threadIDs.contains(id) || (change.drafts && id.hasPrefix("draft:")) {
            await loadCurrentThread(refresh: true)
        } else if change.rules {
            await refreshProvenance()
        }
        if change.reset { await reloadAccount() }
        if case .explain(let id) = overlay, change.reset || change.rules || change.threadIDs.contains(id) { await loadExplanation(threadID: id) }
        if overlay == .rules, change.reset || change.rules || change.labels { rulesManager?.reload() }
        if change.calendar || change.reset {
            await calendarChanged()
        } else if !change.threadIDs.isEmpty {
            await reloadInvitationChips()
            // Mail moved to or from Trash or Spam changes which invitations wait for an answer.
            await reloadWaitingCount()
        }
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
        if views.contains(where: { $0.pinned && $0.query.invitation == .conflict }) { await reloadConflictingInvitations() }
        for view in views where view.pinned { queries["view:\(view.id)"] = resolved(view.query) }
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

    /// nil while the list shows a rule's matches: they come from any mailbox.
    var currentMailbox: Mailbox? {
        guard ruleMatches == nil else { return nil }
        if case .mailbox(let mailbox) = destination { return mailbox }
        return currentView?.mailbox
    }

    var destinationTitle: String {
        if let ruleMatches { return "\(ruleMatches.title) · matches" }
        return switch destination {
        case .mailbox(.label(let id)): labels.first { $0.id == id }?.name ?? "Label"
        case .mailbox(let mailbox): mailbox.title
        case .view(let id): views.first { $0.id == id }?.name ?? "View"
        case .calendar: "Calendar"
        }
    }

    var baseQuery: ThreadQuery {
        if let ruleMatches {
            var query = ThreadQuery(scope: .anywhere)
            query.ids = ruleMatches.threadIDs
            return query
        }
        return switch destination {
        case .mailbox(let mailbox): .mailbox(mailbox)
        case .view: currentView?.query ?? .mailbox(.inbox)
        case .calendar: .mailbox(.inbox)
        }
    }

    var currentQuery: ThreadQuery {
        var query = baseQuery.applying(listFilter)
        let search = searchText.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { query = query.narrowed(by: SearchQuery.parse(search)) }
        return resolved(query)
    }

    var isDraftsList: Bool {
        if ruleMatches == nil, case .mailbox(.drafts) = destination { return true }
        return false
    }

    func navigate(to destination: Destination) {
        // A rule's matches leave the mailbox's cursor where it was.
        if ruleMatches == nil, let cursorID { session.cursors[self.destination.key] = cursorID }
        ruleMatches = nil
        session.destination = destination
        session.filter = .all
        resetList(preferredCursor: session.cursors[destination.key])
    }

    /// `L` in the rule editor: the list shows every conversation the rule matches, the editor waits
    /// (Esc or `gr` returns to it).
    func showRuleMatches(_ matches: RuleMatches) {
        overlay = nil
        if ruleMatches == nil, let cursorID { session.cursors[destination.key] = cursorID }
        var matches = matches
        // The calendar view lists events, not conversations: the matches show in the mail list until you leave them.
        matches.fromCalendar = destination == .calendar || ruleMatches?.fromCalendar == true
        if destination == .calendar { session.destination = .mailbox(.inbox) }
        ruleMatches = matches
        resetList(preferredCursor: nil)
        let count = matches.threadIDs.count
        showToast("\(count == 1 ? "1 conversation matches" : "\(count) conversations match") · esc or gr: back to the rule")
    }

    /// Esc in a rule's matches: the list goes back to where it was, and the rule editor to the screen.
    func leaveRuleMatches() {
        let backToCalendar = ruleMatches?.fromCalendar == true
        ruleMatches = nil
        if backToCalendar { session.destination = .calendar }
        resetList(preferredCursor: session.cursors[destination.key])
        if ruleEditor != nil { overlay = .ruleEditor }
    }

    /// Empties the list and loads what it shows now from the top, without search or selection.
    private func resetList(preferredCursor: String?) {
        stickyIDs.removeAll()
        searchText = ""
        isSearchOpen = false
        clearSelection()
        focus = .list
        listGeneration += 1
        threads = []
        if destination == .calendar {
            cursorID = nil
            Task {
                await reloadAgenda()
                await reloadCounts()
            }
            return
        }
        Task {
            await reloadList(preferredCursor: preferredCursor)
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
        if destination == .calendar {
            await reloadAgenda()
            return
        }
        let generation = listGeneration
        // invite:conflict lists what overlaps your time now.
        if currentQuery.invitation == .conflict {
            await reloadConflictingInvitations()
            guard generation == listGeneration else { return }
        }
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
        await reloadInvitationChips()
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
        peekDays = 0
        markReadTask?.cancel()
        if ruleMatches == nil, let cursorID { session.cursors[destination.key] = cursorID }
        Task { await loadCurrentThread(refresh: false) }
        scheduleMarkRead()
    }

    /// Shows the conversation under the cursor. `refresh` reloads the one on screen after it
    /// changed: it skips the cache and renders even when the conversation looks the same.
    func loadCurrentThread(refresh: Bool) async {
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
        if !refresh, let cached = threadCache[id] {
            currentThread = cached
            render(cached)
        }
        threadTask = Task {
            let store = services.store
            guard let thread = try? await store.thread(id: id), !Task.isCancelled, cursorID == id else { return }
            let explanation = try? await store.explain(threadID: id)
            guard !Task.isCancelled, cursorID == id else { return }
            threadCache[id] = thread
            if threadCache.count > 60 { threadCache.removeAll() }
            let page = await loadEventPage(for: thread)
            guard !Task.isCancelled, cursorID == id else { return }
            let explained = explanation != explanationCache[id]
            if explanationCache.count > 60 { explanationCache.removeAll() }
            explanationCache[id] = explanation
            let pageChanged = page != eventPages[id]
            eventPages[id] = page
            if eventPages.count > 120 { eventPages = [id: page].compactMapValues { $0 } }
            if thread != currentThread || renderedThreadID != id || refresh || explained || pageChanged {
                currentThread = thread
                render(thread)
            }
            prefetchNeighbors()
        }
    }

    private func prefetchNeighbors() {
        guard let index = cursorIndex else { return }
        for neighbor in [index - 1, index + 1] where threads.indices.contains(neighbor) {
            let id = threads[neighbor].id
            guard threadCache[id] == nil, !id.hasPrefix("draft:") else { continue }
            let store = services.store
            Task {
                if let thread = try? await store.thread(id: id) { threadCache[id] = thread }
                if let explanation = try? await store.explain(threadID: id) { explanationCache[id] = explanation }
            }
        }
    }

    func rerenderReader() {
        if let currentThread { render(currentThread) } else { Task { await loadCurrentThread(refresh: true) } }
    }

    /// Rules changed: shows the conversation's new provenance, if it has any.
    private func refreshProvenance() async {
        guard let thread = currentThread, renderedThreadID == thread.id else { return }
        let explanation = try? await services.store.explain(threadID: thread.id)
        guard currentThread?.id == thread.id, renderedThreadID == thread.id, explanation != explanationCache[thread.id] else { return }
        explanationCache[thread.id] = explanation
        render(thread)
    }

    private func render(_ thread: MailThread) {
        let unread = thread.messages.filter(\.isUnread).map(\.id)
        // Marking read keeps what was new; a message that arrives while the conversation is open is new too.
        if renderedThreadID == thread.id { newMessageIDs.formUnion(unread) } else { newMessageIDs = Set(unread) }
        renderedThreadID = thread.id
        reader.render(readerPayload(for: thread))
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
            snippet: "", isNew: false, expanded: true, focus: true, kind: "html",
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

    private func readerPayload(for thread: MailThread) -> ReaderPayload {
        let me = services.store.selfAddresses
        var payload = ReaderPayload()
        payload.dark = theme.palette.isDark
        payload.threadID = thread.id
        payload.subject = thread.subject
        payload.position = positionText
        payload.hasPrevious = (cursorIndex ?? 0) > 0
        payload.hasNext = (cursorIndex ?? 0) < threads.count - 1
        payload.allowRemote = settings.loadRemoteImages || remoteImagesAllowed.contains(thread.id)
        payload.showHints = settings.alwaysShowKeyHints
        let explanation = explanationCache[thread.id]
        payload.labels = chips(for: thread.labelIDs, explanation: explanation)
        payload.provenance = labels.filter { thread.labelIDs.contains($0.id) }.flatMap { label in
            (explanation?.provenance(ofLabel: label.id) ?? []).map { "◆ \(label.name) · \($0)" }
        }
        if let snoozed = thread.snoozedUntil {
            payload.labels.append(.init(name: "snoozed · \(Formatting.snoozeDate(snoozed))", fg: theme.palette.yellow, soft: theme.palette.yellowSoft))
        }
        let latestReceived = thread.latestReceived(excluding: me)
        payload.canReplyAll = latestReceived.map { ($0.to + $0.cc).filter { !me.contains($0.normalized) }.count + 1 > 1 } ?? false
        payload.menu = readerMenu(for: thread)

        // New messages open, and the reader starts at the first one. The latest message is always open.
        let firstNew = thread.messages.firstIndex { newMessageIDs.contains($0.id) }
        let focusIndex = firstNew ?? (thread.messages.count - 1)
        payload.event = eventPages[thread.id]
        if payload.event == nil { payload.nextWith = nextWith(thread)?.text }
        // With an event page, invitation mail collapses to one line and its calendar files are not listed.
        let showsPage = payload.event != nil
        payload.messages = thread.messages.enumerated().map { index, message in
            let isInvitation = showsPage && message.attachments.contains { $0.mimeType.lowercased() == "text/calendar" || $0.filename.lowercased().hasSuffix(".ics") }
            let kind: String
            if let html = message.htmlBody, !html.isEmpty {
                kind = ReaderPayload.isRich(html) ? "rich" : "html"
            } else {
                kind = "text"
            }
            let fromMe = me.contains(message.from.normalized)
            let isNew = newMessageIDs.contains(message.id)
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
                isNew: isNew,
                expanded: isNew || index == thread.messages.count - 1,
                focus: index == focusIndex,
                kind: kind,
                text: kind == "text" ? message.plainText : nil,
                html: kind == "text" ? nil : Self.resolvingInlineImages(in: message),
                attachments: message.fileAttachments.filter { !(isInvitation && $0.filename.lowercased().hasSuffix(".ics")) }.map {
                    .init(id: $0.id, name: $0.filename, kind: $0.kindLabel, size: Formatting.fileSize($0.size))
                },
                sending: message.id.hasPrefix("local-"),
                invitation: isInvitation
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

    /// Label chips; with an explanation, each says how rules added it (a tooltip).
    func chips(for labelIDs: some Sequence<String>, explanation: ThreadExplanation? = nil) -> [ReaderPayload.LabelChip] {
        let palette = theme.palette.labelColors
        return labels
            .filter { $0.kind != .system && labelIDs.contains($0.id) }
            .map { label in
                let pair = palette[label.paletteIndex(count: palette.count)]
                let source = explanation?.provenance(ofLabel: label.id) ?? []
                return ReaderPayload.LabelChip(name: label.name, fg: pair.fg, soft: pair.soft, source: source.isEmpty ? nil : source.joined(separator: "\n"))
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
            Item(title: "Quick snooze", icon: "clock", key: "b", action: "quickSnooze"),
            Item(title: thread.isUnread ? "Mark as read" : "Mark as unread", icon: "check", key: thread.isUnread ? "I" : "U", action: "toggleRead"),
            Item(title: "Label…", icon: "tag", key: "t", action: "label"),
            Item(title: "Why these labels?", icon: "tag", key: "g?", action: "explain"),
            Item(title: "Create rule from this…", icon: "tag", key: "T", action: "createRule"),
            Item(title: "Run rules", icon: "check", key: "=", action: "runRules"),
            Item(title: "Move to…", icon: "folder", key: "m", action: "move"),
        ] + unsubscribeMenu(for: thread) + [
            Item(title: thread.labelIDs.contains(SystemLabel.spam) ? "Not spam" : "Report spam", icon: "spam", key: "!", action: "spam"),
        ]
    }

    /// Only where ⌘U can do something: not in Spam, and the mail says how to unsubscribe.
    private func unsubscribeMenu(for thread: MailThread) -> [ReaderPayload.MenuItem] {
        guard !thread.labelIDs.contains(SystemLabel.spam), thread.unsubscribeTarget(excluding: services.store.selfAddresses) != nil else { return [] }
        return [ReaderPayload.MenuItem(title: "Unsubscribe", icon: "unsubscribe", key: "⌘U", action: "unsubscribe")]
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
        guard query.count >= 2, Self.ruleSentence(in: query) == nil else {
            omniMessages = []
            return
        }
        omniTask = Task {
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            let parsed = ThreadQuery(scope: .everywhereExceptTrash).narrowed(by: SearchQuery.parse(query))
            if parsed.invitation == .conflict { await reloadConflictingInvitations() }
            guard !Task.isCancelled else { return }
            var search = resolved(parsed)
            search.limit = 6
            let results = (try? await services.store.threads(search)) ?? []
            guard !Task.isCancelled else { return }
            omniMessages = results
        }
    }

    // MARK: - Overlays, focus and toasts

    private func overlayChanged(from old: Overlay?) {
        // Closing the consent panel any way but ↵ drops what waited for it.
        if old == .aiConsent {
            afterConsent = nil
            consentReturn = nil
        }
        // Something took the event editor's place without esc, a save or a removal (⌘K, a menu command): its changes
        // stay as a draft, as with esc, and your editor on its notes stops.
        if old == .eventEditor, let editor = eventEditor {
            eventEditor = nil
            keepDraft(of: editor)
        }
        switch overlay {
        case .omnibox:
            omniQuery = ""
            omniHighlighted = 0
            focusTarget = .omnibox
        case .picker:
            pickerQuery = ""
            pickerHighlighted = 0
            lastPickedLabel = nil
            focusTarget = .picker
        case .viewEditor:
            focusTarget = .viewName
        case .ruleEditor:
            focusTarget = ruleEditor?.field.focusTarget
            if focusTarget == nil { blurTextInput() }
        case .quickAdd:
            focusTarget = .quickAdd
        case .settings:
            // Settings puts the keyboard on its list of sections itself.
            focusTarget = nil
            settingsFocus = .sidebar
            blurTextInput()
        case .eventEditor:
            // The editor puts the cursor in Title or When itself.
            focusTarget = nil
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

    func showToast(_ text: String, undoable: Bool = false, isError: Bool = false, countdownTo: Date? = nil, countdownLead: String = "in", detail: String? = nil) {
        toast = Toast(text: text, undoable: undoable, isError: isError, countdownTo: countdownTo, countdownLead: countdownLead, detail: detail)
        toastTask?.cancel()
        let duration = countdownTo.map { max(0, $0.timeIntervalSinceNow) } ?? (isError ? 6 : 3.5)
        toastTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    var mode: Mode {
        // Settings has the keys even over compose (opened from its signature menu).
        if overlay == .settings { return settingsFocus == .pane ? .insert : .normal }
        if compose?.vimRunning == true { return .vim }
        if let compose {
            if focusTarget == nil { return .compose }
            return focusTarget == .composeBody && compose.bodyMode == .normal ? .normal : .insert
        }
        switch overlay {
        case .omnibox: return .command
        case .eventEditor:
            if eventEditor?.vimRunning == true { return .vim }
            return focusTarget == .eventNotes && eventEditor?.notesMode == .normal ? .normal : .insert
        case .picker, .viewEditor, .quickAdd: return .insert
        case .aiConsent where focusTarget == .consentBudget: return .insert
        case .ruleEditor where ruleEditor?.field.isText == true: return .insert
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
        if settings.ai != old.ai { aiSettingsChanged(from: old.ai) }
        let services = services
        let settings = settings
        Task { await services.apply(settings) }
    }
}
