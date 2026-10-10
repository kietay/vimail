import Foundation
import DummyProvider
import GmailProvider
import MailCore
import MailStore
import MailSync
import VimailLog

/// The incoming-mail processor pipeline. Empty in the first, non-AI version.
///
/// To add the AI classifier, implement `MessageProcessor` and register it here, for example
/// `ProcessingPipeline([ClassifierProcessor(model: ...)])`. Its effects (labels, annotations,
/// archive, ...) are applied through `MailActions`, stored locally, and labels default to
/// local-only so classification never touches Gmail unless a processor asks for `.synced`.
enum AppPipeline {
    static func make() -> ProcessingPipeline {
        ProcessingPipeline([])
    }
}

/// Wires the local store, the provider and the sync engine for one account.
@MainActor
final class AppServices {
    let accountKey: String
    let store: MailStore
    let provider: any MailProvider
    let dummy: DummyMailProvider?
    let engine: SyncEngine
    let actions: MailActions
    let processing: ProcessingCoordinator
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

    init(settings: AppSettings) throws {
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
        processing = ProcessingCoordinator(pipeline: AppPipeline.make(), store: store, actions: actions)
        let calendarEngine: CalendarSyncEngine?
        if let calendarProvider { calendarEngine = CalendarSyncEngine(provider: calendarProvider, store: store) } else { calendarEngine = nil }
        self.calendarEngine = calendarEngine
        calendarActions = CalendarActions(store: store, changed: { calendarEngine?.wake() })
        invitations = InvitationIndexer(store: store, provider: provider, found: { calendarEngine?.wake() })
    }

    var isGmail: Bool { dummy == nil }

    func start() async {
        await engine.attach(actions: actions, processing: processing)
        await engine.start()
        await dummy?.startSimulation()
        await calendarEngine?.start()
        await invitations.start()
    }

    /// Stops syncing before another account takes over.
    func stop() async {
        await engine.stop()
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
