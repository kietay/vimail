import AppKit
import MailCore
import SwiftUI

@main
struct VimailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("vimail", id: "main") {
            switch AppContainer.shared {
            case .success(let model):
                RootView()
                    .environment(model)
                    .onAppear {
                        KeyboardRouter.shared.install(model)
                        #if DEBUG
                        DebugScript.runIfRequested()
                        #endif
                    }
            case .failure(let error):
                VStack(spacing: 12) {
                    Text("vimail could not open its local database.").font(.headline)
                    Text(String(describing: error)).font(.caption).textSelection(.enabled)
                    Button("Show data folder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.root]) }
                }
                .padding(40)
                .frame(minWidth: 600, minHeight: 300)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 920)
        .commands {
            if case .success(let model) = AppContainer.shared {
                AppCommands(model: model)
            }
        }
    }
}

/// The model is created on first use (after the app finishes launching).
@MainActor
enum AppContainer {
    static let shared: Result<AppModel, Error> = Result { try AppModel() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.log.info("Quitting")
        MainActor.assumeIsolated {
            guard case .success(let model) = AppContainer.shared, let compose = model.compose else { return }
            // Keep whatever is being written.
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await compose.finish()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1)
        }
    }
}

/// Menu bar commands. Everything here also has a vim key; the menus make it discoverable.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.overlay = .settings }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Message") { model.openCompose(nil) }.keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Mailbox") {
            Button("Search") { model.openSearch() }.keyboardShortcut("f", modifiers: .command)
            Button("Commands…") { model.overlay = .omnibox }
            Divider()
            Button("Inbox") { model.navigate(to: .mailbox(.inbox)) }.keyboardShortcut("1", modifiers: .command)
            Button("Starred") { model.navigate(to: .mailbox(.starred)) }.keyboardShortcut("2", modifiers: .command)
            Button("Snoozed") { model.navigate(to: .mailbox(.snoozed)) }.keyboardShortcut("3", modifiers: .command)
            Button("Sent") { model.navigate(to: .mailbox(.sent)) }.keyboardShortcut("4", modifiers: .command)
            Button("Drafts") { model.navigate(to: .mailbox(.drafts)) }.keyboardShortcut("5", modifiers: .command)
            Button("Archive") { model.navigate(to: .mailbox(.archive)) }.keyboardShortcut("6", modifiers: .command)
            Button("Trash") { model.navigate(to: .mailbox(.trash)) }.keyboardShortcut("7", modifiers: .command)
            Divider()
            Button("Manage Views…") { model.overlay = .views }
            Button("Sync Now") { model.syncNow() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Simulate Incoming Mail") { model.simulateIncomingMail() }
            Divider()
            Button(model.settings.ai.pauseAll ? "Resume Rules" : "Pause All Rules") { model.setRulesPaused(!model.settings.ai.pauseAll) }
        }
        CommandMenu("Message") {
            Button("Reply") { model.reply(all: false) }.keyboardShortcut("r", modifiers: .command)
            Button("Reply All") { model.reply(all: true) }
            Button("Forward") { model.forward() }
            Divider()
            Button("Archive") { model.archive() }
            Button("Move to Trash") { model.trash() }.keyboardShortcut(.delete, modifiers: .command)
            Button("Star / Unstar") { model.toggleStar() }
            Button("Mark Read / Unread") { model.toggleRead() }
            Button("Snooze…") { model.openPicker(.snooze) }
            Button("Quick Snooze") { model.quickSnooze() }
            Button("Label…") { model.openPicker(.label) }
            Button("Move to…") { model.openPicker(.move) }
            Divider()
            Button("Why These Labels?") { model.openExplain() }
            Button("Run Rules") { model.runRulesOnSelection() }
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { model.session.sidebarCollapsed.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.overlay = .help }.keyboardShortcut("/", modifiers: .command)
            Button("Show Local Data Folder") { model.revealDataFolder() }
            Button("Show Log File") { model.openLogFile() }
        }
    }
}
