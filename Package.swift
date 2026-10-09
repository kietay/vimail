// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "vimail",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "vimail", targets: ["Vimail"]),
    ],
    dependencies: [
        // Vendored so the app builds offline. MIT licensed. See Vendor/README.md.
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        // Domain models, the provider protocol, search parsing, and the rule model and planner. No I/O.
        .target(name: "MailCore"),
        // The log: unified log (Console.app) plus ~/Library/Logs/vimail/vimail.log. No mail content.
        .target(name: "VimailLog"),
        // Local-first SQLite store: mail cache, outbox, drafts, snoozes, views, annotations, rules.
        .target(name: "MailStore", dependencies: ["MailCore"]),
        // Optimistic actions, the outbox, and the sync engine that talks to a MailProvider.
        .target(name: "MailSync", dependencies: ["MailCore", "MailStore", "VimailLog"]),
        // A fake Gmail server with realistic, persistent dummy data.
        .target(name: "DummyProvider", dependencies: ["MailCore"]),
        // Shared HTTP plumbing: the transport, private files, priority slots and backoff.
        .target(name: "HTTPKit"),
        // Gmail over its REST API: OAuth (loopback + PKCE), sync, MIME sending, and a dry-run wrapper.
        .target(name: "GmailProvider", dependencies: ["MailCore", "HTTPKit", "VimailLog"]),
        // The rules engine. It reaches Claude only through MailCore's `RuleJudge`.
        .target(name: "MailRules", dependencies: ["MailCore", "MailStore", "VimailLog"]),
        // Claude for rules: the model catalog with prices, and the API client.
        .target(name: "MailAI", dependencies: ["MailCore", "HTTPKit", "VimailLog"]),
        // UI-free app logic: vim keymap parser, Markdown -> email HTML, fuzzy matching.
        .target(name: "VimailKit", dependencies: ["MailCore"]),
        .executableTarget(
            name: "Vimail",
            dependencies: [
                "MailCore", "MailStore", "MailSync", "MailRules", "MailAI", "HTTPKit", "DummyProvider", "GmailProvider",
                "VimailKit", "VimailLog",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"]),
        .testTarget(name: "MailStoreTests", dependencies: ["MailStore", "MailCore"]),
        .testTarget(name: "MailSyncTests", dependencies: ["MailSync", "MailStore", "DummyProvider", "MailCore"]),
        .testTarget(name: "VimailKitTests", dependencies: ["VimailKit", "MailCore"]),
        .testTarget(name: "GmailProviderTests", dependencies: ["GmailProvider", "HTTPKit", "MailCore"]),
        .testTarget(name: "HTTPKitTests", dependencies: ["HTTPKit"]),
        .testTarget(name: "MailRulesTests", dependencies: ["MailRules", "MailStore", "MailSync", "MailCore", "DummyProvider"]),
        .testTarget(name: "MailAITests", dependencies: ["MailAI", "MailCore", "HTTPKit", "DummyProvider"], resources: [.copy("Fixtures")]),
    ]
)
