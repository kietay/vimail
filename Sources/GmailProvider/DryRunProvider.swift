import Foundation
import MailCore
import VimailLog

/// Wraps a provider so a real mailbox can be used for testing without changing it.
/// Reads go to the real provider. Changes and sends never leave this Mac: they succeed locally,
/// and each one is logged to `changes.log` in `directory`. Sent messages are saved there as `.eml` files.
public actor DryRunProvider: MailProvider {
    private let base: any MailProvider
    public let directory: URL

    public nonisolated var kind: String { base.kind }
    public nonisolated var supportsPermanentDelete: Bool { base.supportsPermanentDelete }

    public init(wrapping base: any MailProvider, directory: URL) {
        self.base = base
        self.directory = directory
    }

    public func profile() async throws -> AccountProfile { try await base.profile() }
    public func labels() async throws -> [MailLabel] { try await base.labels() }

    public func listThreadIDs(labelID: String?, pageToken: String?, pageSize: Int) async throws -> ThreadIDPage {
        try await base.listThreadIDs(labelID: labelID, pageToken: pageToken, pageSize: pageSize)
    }

    public func threads(ids: [String]) async throws -> [[MailMessage]] { try await base.threads(ids: ids) }
    public func changes(since cursor: String) async throws -> ChangeSet { try await base.changes(since: cursor) }

    public func attachmentData(messageID: String, attachmentID: String) async throws -> Data {
        try await base.attachmentData(messageID: messageID, attachmentID: attachmentID)
    }

    public nonisolated func changeSignals() -> AsyncStream<Void> { base.changeSignals() }

    public func modifyLabels(messageIDs: [String], add: Set<String>, remove: Set<String>) async throws {
        log("modifyLabels messages=\(messageIDs.joined(separator: ",")) add=\(add.sorted().joined(separator: ",")) remove=\(remove.sorted().joined(separator: ","))")
    }

    public func deleteMessages(ids: [String]) async throws {
        log("deleteMessages \(ids.joined(separator: ","))")
    }

    public func send(_ message: OutgoingMessage, fileData: [String: Data], isRetry: Bool) async throws -> MailMessage {
        var files: [MIMEBuilder.File] = []
        for attachment in message.attachments {
            let data: Data
            switch attachment.source {
            case .file: data = fileData[attachment.id] ?? Data()
            case .remote(let messageID, let attachmentID): data = try await base.attachmentData(messageID: messageID, attachmentID: attachmentID)
            }
            files.append(MIMEBuilder.File(filename: attachment.filename, mimeType: attachment.mimeType, data: data))
        }
        let messageID = message.messageID ?? MIMEBuilder.makeMessageID(from: message.from)
        let mime = MIMEBuilder.build(message, messageID: messageID, files: files)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = directory.appendingPathComponent("sent-\(stamp).eml")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? mime.write(to: file)
        let calendar = message.calendar.map { " calendar=\($0.method)" } ?? ""
        log("send \(file.lastPathComponent) thread=\(message.threadID ?? "new") to=\(message.to.map(\.email).joined(separator: ",")) retry=\(isRetry)\(calendar)")

        let id = "dryrun-\(UUID().uuidString.lowercased())"
        return MailMessage(
            id: id, threadID: message.threadID ?? id, labelIDs: [SystemLabel.sent], from: message.from,
            to: message.to, cc: message.cc, bcc: message.bcc, subject: message.subject,
            snippet: HTMLText.snippet(from: message.textBody), date: Date(), textBody: message.textBody, htmlBody: message.htmlBody,
            messageIDHeader: messageID, inReplyTo: message.inReplyTo, references: message.references
        )
    }

    public func unsubscribe(oneClick url: URL) async throws {
        log("unsubscribe one-click host=\(url.host ?? "?")")
    }

    public func createLabel(name: String) async throws -> MailLabel {
        log("createLabel \(name)")
        return MailLabel(id: "dryrun-label-\(UUID().uuidString.prefix(8).lowercased())", name: name, kind: .user)
    }

    public func renameLabel(id: String, to name: String) async throws -> MailLabel {
        log("renameLabel \(id) \(name)")
        return MailLabel(id: id, name: name, kind: .user)
    }

    public func deleteLabel(id: String) async throws {
        log("deleteLabel \(id)")
    }

    private func log(_ line: String) {
        Log("dry-run").info("Not sent to Gmail: \(line.replacingOccurrences(of: #"to=\S+"#, with: "to=…", options: .regularExpression))")
        let url = directory.appendingPathComponent("changes.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: url)
        }
    }
}
