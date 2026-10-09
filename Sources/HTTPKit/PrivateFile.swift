import Foundation

/// Secret files that only the current user can read: credentials and API keys.
///
/// The folder is created with mode 700 and the file is written to a mode-600 temporary file first,
/// then swapped in, so a reader never sees half a secret.
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
            // Replacing keeps the old file's permissions, which may have been wider.
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
    }

    /// The file's contents, or nil when it does not exist or cannot be read.
    public static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}
