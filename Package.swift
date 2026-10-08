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
        // Domain models, the provider protocol, search parsing and the processor pipeline API. No I/O.
        .target(name: "MailCore"),
        // The log: unified log (Console.app) plus ~/Library/Logs/vimail/vimail.log. No mail content.
        .target(name: "VimailLog"),
        // Local-first SQLite store: mail cache, outbox, drafts, snoozes, views, processor results.
        .target(name: "MailStore", dependencies: ["MailCore"]),
        // Optimistic actions, the outbox, and the sync engine that talks to a MailProvider.
        .target(name: "MailSync", dependencies: ["MailCore", "MailStore", "VimailLog"]),
        // A fake Gmail server with realistic, persistent dummy data.
        .target(name: "DummyProvider", dependencies: ["MailCore"]),
        // Gmail over its REST API: OAuth (loopback + PKCE), sync, MIME sending, and a dry-run wrapper.
        .target(name: "GmailProvider", dependencies: ["MailCore", "VimailLog"]),
        // UI-free app logic: vim keymap parser, Markdown -> email HTML, fuzzy matching.
        .target(name: "VimailKit", dependencies: ["MailCore"]),
        .executableTarget(
            name: "Vimail",
            dependencies: [
                "MailCore", "MailStore", "MailSync", "DummyProvider", "GmailProvider", "VimailKit", "VimailLog",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"]),
        .testTarget(name: "MailStoreTests", dependencies: ["MailStore", "MailCore"]),
        .testTarget(name: "MailSyncTests", dependencies: ["MailSync", "MailStore", "DummyProvider", "MailCore"]),
        .testTarget(name: "VimailKitTests", dependencies: ["VimailKit", "MailCore"]),
        .testTarget(name: "GmailProviderTests", dependencies: ["GmailProvider", "MailCore"]),
    ]
)
