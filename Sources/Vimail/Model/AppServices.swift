import Foundation
import DummyProvider
import GmailProvider
import MailCore
import MailStore
import MailSync
import VimailLog

/// Wires the local store, the provider and the sync engine for one account.
@MainActor
final class AppServices {
    let accountKey: String
    let store: MailStore
    let provider: any MailProvider
    let dummy: DummyMailProvider?
    let engine: SyncEngine
    let actions: MailActions
    /// Debug builds with Gmail: where changes and sends are logged instead of reaching Gmail.
    let dryRunDirectory: URL?

    init(settings: AppSettings) throws {
        switch settings.dataSource {
        case .dummy:
            accountKey = "dummy"
            let dummy = DummyMailProvider(directory: AppPaths.dummyServer, configuration: Self.dummyConfiguration(settings))
            self.dummy = dummy
            provider = dummy
            dryRunDirectory = nil
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
            #if DEBUG
            // Test builds read real mail but never change it: every change and send stays on this Mac.
            let directory = AppPaths.dryRun(account: key)
            provider = DryRunProvider(wrapping: gmail, directory: directory)
            dryRunDirectory = directory
            #else
            provider = gmail
            dryRunDirectory = nil
            #endif
        }
        Log("app").info("Opening account \(accountKey) (\(provider.kind)\(dryRunDirectory == nil ? "" : ", dry run: changes stay on this Mac"))")
        store = try MailStore(url: AppPaths.database(account: accountKey))
        let engine = SyncEngine(
            provider: provider, store: store, pollInterval: .seconds(max(5, settings.pollSeconds)),
            // Gmail: the inbox plus the newest 1,000 conversations stay offline. More is fetched on demand later.
            initialSyncLimit: dummy == nil ? 1_000 : 2_000, draftFilesDirectory: AppPaths.draftFiles(account: accountKey)
        )
        self.engine = engine
        actions = MailActions(store: store, outboxChanged: { engine.wake() })
    }

    var isGmail: Bool { dummy == nil }

    func start() async {
        await engine.attach(actions: actions, rules: nil)
        await engine.start()
        await dummy?.startSimulation()
    }

    /// Stops syncing before another account takes over. Returns once no sync cycle is writing.
    func stop() async {
        await engine.stop()
        await dummy?.stopSimulation()
    }

    func apply(_ settings: AppSettings) async {
        await dummy?.configure(Self.dummyConfiguration(settings))
        await engine.setPollInterval(.seconds(max(5, settings.pollSeconds)))
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
