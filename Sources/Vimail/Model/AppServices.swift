import Foundation
import DummyProvider
import GmailProvider
import MailCore
import MailRules
import MailStore
import MailSync
import VimailLog

/// Wires the local store, the provider, the sync engine and the rules engine for one account.
@MainActor
final class AppServices {
    let accountKey: String
    let store: MailStore
    let provider: any MailProvider
    let dummy: DummyMailProvider?
    let engine: SyncEngine
    let actions: MailActions
    let rules: RuleEngine
    /// Debug builds with Gmail: where changes and sends are logged instead of reaching Gmail.
    let dryRunDirectory: URL?
    /// Nil when the account has not granted calendar access (Gmail without calendar scopes).
    let calendarProvider: (any CalendarProvider)?
    let dummyCalendar: DummyCalendarProvider?
    let calendarEngine: CalendarSyncEngine?
    let calendarActions: CalendarActions
    /// Reads invitation files from mail, with or without calendar access.
    let invitations: InvitationIndexer
    /// True when the account can change its calendar (answers, creates); false for read-only access.
    let calendarCanChange: Bool

    /// Debug builds read real mail with real spend: each run over stored mail takes at most this many messages.
    static var runMessageLimit: Int? {
        #if DEBUG
        200
        #else
        nil
        #endif
    }

    init(settings: AppSettings, ai: AIServices) throws {
        var calendarProvider: (any CalendarProvider)?
        var dummyCalendar: DummyCalendarProvider?
        var calendarCanChange = false
        switch settings.dataSource {
        case .dummy:
            accountKey = "dummy"
            let dummy = DummyMailProvider(directory: AppPaths.dummyServer, configuration: Self.dummyConfiguration(settings))
            self.dummy = dummy
            provider = dummy
            dryRunDirectory = nil
            let calendar = DummyCalendarProvider(directory: AppPaths.dummyServer, configuration: Self.dummyCalendarConfiguration(settings)) {
                (try? await dummy.invites()) ?? []
            }
            dummyCalendar = calendar
            calendarProvider = calendar
            calendarCanChange = true
        case .gmail:
            var credential = GmailAccounts.credential(email: settings.gmailAccount)
            var key = GmailAccounts.accountKey(email: settings.gmailAccount)
            #if DEBUG
            if let development = GmailAccounts.developmentCredential() {
                credential = development
                key = "gmail-dev"
            }
            #endif
            accountKey = key
            dummy = nil
            let gmail = GmailProvider(credential: credential)
            let calendar = credential.flatMap { CalendarScope.allowsReading($0.scopes) ? GoogleCalendarProvider(credential: $0) : nil }
            #if DEBUG
            // Test builds read real mail but never change it: every change and send stays on this Mac.
            let directory = AppPaths.dryRun(account: key)
            provider = DryRunProvider(wrapping: gmail, directory: directory)
            dryRunDirectory = directory
            calendarProvider = calendar.map { DryRunCalendarProvider(wrapping: $0, directory: directory) }
            calendarCanChange = calendar != nil
            #else
            provider = gmail
            dryRunDirectory = nil
            calendarProvider = calendar
            calendarCanChange = credential.map { CalendarScope.allowsChanges($0.scopes) } ?? false
            #endif
        }
        self.calendarProvider = calendarProvider
        self.dummyCalendar = dummyCalendar
        self.calendarCanChange = calendarCanChange
        Log("app").info("Opening account \(accountKey) (\(provider.kind)\(dryRunDirectory == nil ? "" : ", dry run: changes stay on this Mac"))")
        store = try MailStore(url: AppPaths.database(account: accountKey))
        let engine = SyncEngine(
            provider: provider, store: store, pollInterval: .seconds(max(5, settings.pollSeconds)),
            // Gmail: the inbox plus the newest 1,000 conversations stay offline. More is fetched on demand later.
            initialSyncLimit: dummy == nil ? 1_000 : 2_000, draftFilesDirectory: AppPaths.draftFiles(account: accountKey)
        )
        self.engine = engine
        actions = MailActions(store: store, outboxChanged: { engine.wake() })
        rules = RuleEngine(
            store: store, judge: ai.judge(forAccount: accountKey), config: ai.judgeConfig, simulatedSync: dryRunDirectory != nil,
            runMessageLimit: Self.runMessageLimit, spend: ai.spendFigures, outboxChanged: { engine.wake() }
        )
        let calendarEngine: CalendarSyncEngine?
        if let calendarProvider { calendarEngine = CalendarSyncEngine(provider: calendarProvider, store: store) } else { calendarEngine = nil }
        self.calendarEngine = calendarEngine
        calendarActions = CalendarActions(store: store, changed: { calendarEngine?.wake() }, mailChanged: { engine.wake() })
        invitations = InvitationIndexer(store: store, provider: provider, found: { calendarEngine?.wake() })
    }

    var isGmail: Bool { dummy == nil }

    /// Starts syncing, then the rules, with Claude as `ai` allows and all rules paused when `paused`.
    func start(ai: AIServices, paused: Bool) async {
        await engine.attach(actions: actions, rules: rules)
        await engine.start()
        await configureRules(ai)
        await setRulesPaused(paused)
        await rules.start()
        await dummy?.startSimulation()
        await calendarEngine?.start()
        await invitations.start()
    }

    /// The key, the model, consent or a budget changed: the rules get the judge and Claude's state.
    func configureRules(_ ai: AIServices) async {
        await rules.configure(judge: ai.judge(forAccount: accountKey), aiPause: ai.aiPause(forAccount: accountKey), config: ai.judgeConfig)
    }

    /// Pauses or resumes all rules (Settings' "Pause all rules"). Failures are logged.
    func setRulesPaused(_ paused: Bool) async {
        do {
            try await rules.setPaused(paused)
        } catch {
            Log("app").error("Could not \(paused ? "pause" : "resume") rules: \(String(describing: type(of: error)))")
        }
    }

    /// Stops syncing, then the rules, before another account takes over. Returns once neither writes.
    func stop() async {
        await engine.stop()
        await rules.stop()
        await dummy?.stopSimulation()
        await calendarEngine?.stop()
        await invitations.stop()
    }

    func apply(_ settings: AppSettings) async {
        await dummy?.configure(Self.dummyConfiguration(settings))
        await dummyCalendar?.configure(Self.dummyCalendarConfiguration(settings))
        await engine.setPollInterval(.seconds(max(5, settings.pollSeconds)))
    }

    static func dummyCalendarConfiguration(_ settings: AppSettings) -> DummyCalendarProvider.Configuration {
        var configuration = DummyCalendarProvider.Configuration()
        let latency = max(0, settings.dummyLatencyMilliseconds)
        configuration.latency = (latency / 3)...max(latency / 3, latency)
        configuration.failureRate = min(max(settings.dummyFailureRate, 0), 1)
        return configuration
    }

    static func dummyConfiguration(_ settings: AppSettings) -> DummyMailProvider.Configuration {
        var configuration = DummyMailProvider.Configuration()
        let latency = max(0, settings.dummyLatencyMilliseconds)
        configuration.latency = (latency / 3)...max(latency / 3, latency)
        configuration.failureRate = min(max(settings.dummyFailureRate, 0), 1)
        configuration.simulateIncomingMail = settings.dummySimulateIncomingMail
        return configuration
    }

    var draftFilesDirectory: URL { AppPaths.draftFiles(account: accountKey) }
}
