import Foundation

/// Keeps one secret, such as an API key. A private file for now; the Keychain once the app has a
/// stable signing identity.
public protocol SecretStore: Sendable {
    /// The saved secret without surrounding whitespace, or nil when there is none.
    func read() -> String?
    func save(_ secret: String) throws
    /// Forgets the secret. Removing one that is not there is not an error.
    func remove() throws
}

/// A secret in a file only you can read (`PrivateFile`, mode 600).
public struct FileSecretStore: SecretStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() -> String? {
        PrivateFile.read(url).flatMap { Self.trimmed(String(decoding: $0, as: UTF8.self)) }
    }

    public func save(_ secret: String) throws {
        guard let secret = Self.trimmed(secret) else { throw EmptySecret() }
        try PrivateFile.write(Data(secret.utf8), to: url)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func trimmed(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// `save` was given only whitespace.
public struct EmptySecret: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "The secret is empty" }
}

/// A secret from the environment, for debug builds: the variable itself, else the file another
/// variable names (`~` expands). Empty values count as unset.
public enum EnvironmentSecret {
    public static func read(variable: String, fileVariable: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let value = environment[variable].flatMap(FileSecretStore.trimmed) { return value }
        guard let path = environment[fileVariable].flatMap(FileSecretStore.trimmed) else { return nil }
        return FileSecretStore(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)).read()
    }
}
