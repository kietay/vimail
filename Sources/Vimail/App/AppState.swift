import Foundation
import MailCore

/// Where vimail keeps local state. Everything lives on this Mac:
///
///     ~/Library/Application Support/vimail/
///         settings.json            preferences
///         session.json             window/session state (mailbox, cursors, sidebar)
///         google-oauth-client.json the Google Cloud OAuth client (Gmail only, mode 600)
///         accounts/<key>/mail.sqlite   mail cache, outbox, drafts, snoozes, views, processor results
///         accounts/<key>/drafts/   draft attachments and vim editing buffers
///         accounts/gmail-<email>/google-credential.json   the Gmail refresh token (mode 600)
///         dummy/                   the fake Gmail server (dummy data mode only)
///     ~/Library/Caches/vimail/attachments/   downloaded attachments (safe to delete)
///     ~/Library/Logs/vimail/vimail.log        the log (no mail content)
///
/// Debug builds use `vimail-debug` instead of `vimail`, so test runs never share a mail cache or
/// an outbox with the installed app. `VIMAIL_HOME` overrides the folder.
enum AppPaths {
    #if DEBUG
    static let folderName = "vimail-debug"
    #else
    static let folderName = "vimail"
    #endif

    static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["VIMAIL_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(folderName, isDirectory: true)
    }()

    static let caches: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(folderName, isDirectory: true)
    }()

    static var settings: URL { root.appendingPathComponent("settings.json") }
    static var session: URL { root.appendingPathComponent("session.json") }
    static var dummyServer: URL { root.appendingPathComponent("dummy", isDirectory: true) }
    static var attachmentCache: URL { caches.appendingPathComponent("attachments", isDirectory: true) }

    static func account(_ key: String) -> URL { root.appendingPathComponent("accounts/\(key)", isDirectory: true) }
    static func database(account key: String) -> URL { account(key).appendingPathComponent("mail.sqlite") }
    static func draftFiles(account key: String) -> URL { account(key).appendingPathComponent("drafts", isDirectory: true) }
    static var googleClient: URL { root.appendingPathComponent("google-oauth-client.json") }
    /// `~/Library/Logs/vimail/vimail.log` (Console.app lists it under Log Reports).
    static let logs: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/\(folderName)", isDirectory: true)
    }()
    static func googleCredential(account key: String) -> URL { account(key).appendingPathComponent("google-credential.json") }
    /// Debug builds: what a change or send would have done (log and .eml files).
    static func dryRun(account key: String) -> URL { account(key).appendingPathComponent("dry-run", isDirectory: true) }
}

enum ThemeID: String, Codable, CaseIterable, Identifiable {
    // Raw values of the first two match earlier settings files.
    case gruvbox, tokyoNight, nord
    case papercolor, gruvboxLight, solarizedLight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gruvbox: "Gruvbox Dark"
        case .tokyoNight: "Tokyo Night"
        case .nord: "Nord"
        case .papercolor: "PaperColor Light"
        case .gruvboxLight: "Gruvbox Light"
        case .solarizedLight: "Solarized Light"
        }
    }

    var isDark: Bool { [.gruvbox, .tokyoNight, .nord].contains(self) }
    static var darkThemes: [ThemeID] { allCases.filter(\.isDark) }
    static var lightThemes: [ThemeID] { allCases.filter { !$0.isDark } }
}

/// Light, dark, or follow the system appearance.
enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto (follow system)"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum DataSource: String, Codable, CaseIterable {
    case dummy
    case gmail

    var title: String { self == .dummy ? "Dummy data" : "Gmail" }
}

/// A Markdown signature you wrote, with a name to pick it by.
struct NamedSignature: Identifiable, Codable, Hashable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var markdown: String
}

/// User preferences. Stored as JSON in Application Support.
struct AppSettings: Codable, Equatable {
    /// Dark by default (the design's primary look). Auto follows macOS.
    var appearance: AppearanceMode = .dark
    var lightTheme: ThemeID = .papercolor
    var darkTheme: ThemeID = .gruvbox
    /// Seconds a conversation must stay selected before it is marked read. Negative: only on open.
    var markReadDelay: Double = 1.0
    /// Seconds before a sent message actually leaves (undo window).
    var undoSendSeconds: Double = 5
    var loadRemoteImages = false
    /// Shell command for the Ctrl+G editor. Empty: $VISUAL, then $EDITOR, then nvim, from your login shell.
    var editorCommand = ""
    /// Open the compose body in vim immediately.
    var composeStartsInVim = false
    var showComposePreview = true
    /// Your Markdown signatures. The account's own (Gmail settings) is not in this list.
    var signatures: [NamedSignature] = []
    /// The signature compose starts with.
    var defaultSignature: SignatureChoice = .account
    var alwaysShowKeyHints = false
    var dataSource: DataSource = .dummy
    /// The connected Gmail address. Empty until you sign in.
    var gmailAccount = ""
    var pollSeconds: Double = 30
    var dummySimulateIncomingMail = true
    var dummyLatencyMilliseconds = 120
    var dummyFailureRate = 0.0

    init() {}

    init(from decoder: Decoder) throws {
        // Tolerate missing keys so new settings never break an existing file.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        if let mode = try? container.decode(AppearanceMode.self, forKey: .appearance) {
            appearance = mode
            lightTheme = (try? container.decode(ThemeID.self, forKey: .lightTheme)).flatMap { $0.isDark ? nil : $0 } ?? defaults.lightTheme
            darkTheme = (try? container.decode(ThemeID.self, forKey: .darkTheme)).flatMap { $0.isDark ? $0 : nil } ?? defaults.darkTheme
        } else if let legacy = try? container.decode(ThemeID.self, forKey: .legacyTheme) {
            // Settings from before light/dark themes: keep the look the user picked.
            appearance = legacy.isDark ? .dark : .light
            if legacy.isDark { darkTheme = legacy } else { lightTheme = legacy }
        }
        markReadDelay = (try? container.decode(Double.self, forKey: .markReadDelay)) ?? defaults.markReadDelay
        undoSendSeconds = (try? container.decode(Double.self, forKey: .undoSendSeconds)) ?? defaults.undoSendSeconds
        loadRemoteImages = (try? container.decode(Bool.self, forKey: .loadRemoteImages)) ?? defaults.loadRemoteImages
        editorCommand = (try? container.decode(String.self, forKey: .editorCommand)) ?? defaults.editorCommand
        composeStartsInVim = (try? container.decode(Bool.self, forKey: .composeStartsInVim)) ?? defaults.composeStartsInVim
        showComposePreview = (try? container.decode(Bool.self, forKey: .showComposePreview)) ?? defaults.showComposePreview
        if let saved = try? container.decode([NamedSignature].self, forKey: .signatures) {
            signatures = saved
            defaultSignature = (try? container.decode(SignatureChoice.self, forKey: .defaultSignature)) ?? defaults.defaultSignature
        } else {
            // Settings from before named signatures: one Markdown signature and a Gmail switch.
            let legacy = (try? container.decode(String.self, forKey: .legacySignature)) ?? ""
            let useGmail = (try? container.decode(Bool.self, forKey: .legacyUseGmailSignature)) ?? true
            if !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                signatures = [NamedSignature(name: "Main", markdown: legacy)]
            }
            defaultSignature = useGmail ? .account : signatures.first.map { .custom($0.id) } ?? .off
        }
        alwaysShowKeyHints = (try? container.decode(Bool.self, forKey: .alwaysShowKeyHints)) ?? defaults.alwaysShowKeyHints
        dataSource = (try? container.decode(DataSource.self, forKey: .dataSource)) ?? defaults.dataSource
        gmailAccount = (try? container.decode(String.self, forKey: .gmailAccount)) ?? defaults.gmailAccount
        pollSeconds = (try? container.decode(Double.self, forKey: .pollSeconds)) ?? defaults.pollSeconds
        dummySimulateIncomingMail = (try? container.decode(Bool.self, forKey: .dummySimulateIncomingMail)) ?? defaults.dummySimulateIncomingMail
        dummyLatencyMilliseconds = (try? container.decode(Int.self, forKey: .dummyLatencyMilliseconds)) ?? defaults.dummyLatencyMilliseconds
        dummyFailureRate = (try? container.decode(Double.self, forKey: .dummyFailureRate)) ?? defaults.dummyFailureRate
    }

    enum CodingKeys: String, CodingKey {
        case appearance, lightTheme, darkTheme, markReadDelay, undoSendSeconds, loadRemoteImages, editorCommand
        case composeStartsInVim, showComposePreview, signatures, defaultSignature, alwaysShowKeyHints, dataSource, gmailAccount, pollSeconds
        case dummySimulateIncomingMail, dummyLatencyMilliseconds, dummyFailureRate
        case legacyTheme = "theme"
        case legacySignature = "signature"
        case legacyUseGmailSignature = "useGmailSignature"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(lightTheme, forKey: .lightTheme)
        try container.encode(darkTheme, forKey: .darkTheme)
        try container.encode(markReadDelay, forKey: .markReadDelay)
        try container.encode(undoSendSeconds, forKey: .undoSendSeconds)
        try container.encode(loadRemoteImages, forKey: .loadRemoteImages)
        try container.encode(editorCommand, forKey: .editorCommand)
        try container.encode(composeStartsInVim, forKey: .composeStartsInVim)
        try container.encode(showComposePreview, forKey: .showComposePreview)
        try container.encode(signatures, forKey: .signatures)
        try container.encode(defaultSignature, forKey: .defaultSignature)
        try container.encode(alwaysShowKeyHints, forKey: .alwaysShowKeyHints)
        try container.encode(dataSource, forKey: .dataSource)
        try container.encode(gmailAccount, forKey: .gmailAccount)
        try container.encode(pollSeconds, forKey: .pollSeconds)
        try container.encode(dummySimulateIncomingMail, forKey: .dummySimulateIncomingMail)
        try container.encode(dummyLatencyMilliseconds, forKey: .dummyLatencyMilliseconds)
        try container.encode(dummyFailureRate, forKey: .dummyFailureRate)
    }

    /// The theme to show for a system appearance.
    func theme(systemIsDark: Bool) -> ThemeID {
        switch appearance {
        case .light: lightTheme
        case .dark: darkTheme
        case .auto: systemIsDark ? darkTheme : lightTheme
        }
    }
}

/// UI session state restored on launch.
struct SessionState: Codable, Equatable {
    var destination: Destination = .mailbox(.inbox)
    var filter: ListFilter = .all
    var sidebarCollapsed = false
    /// Last selected conversation per destination key, so switching back keeps your place.
    var cursors: [String: String] = [:]
}

/// Reads and writes a Codable value as JSON, with debounced saves.
@MainActor
final class JSONFile<Value: Codable & Equatable> {
    private let url: URL
    private var pending: Task<Void, Never>?

    init(_ url: URL) {
        self.url = url
    }

    func load(default value: Value) -> Value {
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Value.self, from: data) else { return value }
        return decoded
    }

    func save(_ value: Value, debounce: Duration = .milliseconds(400)) {
        pending?.cancel()
        let url = url
        pending = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(value) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
