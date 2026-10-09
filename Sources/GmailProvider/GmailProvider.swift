import Foundation
import MailCore
import VimailLog

/// Gmail through its REST API. The sync engine uses it exactly like the dummy server:
/// threads in, history cursors for changes, label deltas and MIME messages out.
///
/// Drafts saved in Gmail (web or phone) are skipped: vimail drafts are local.
public actor GmailProvider: MailProvider {
    public nonisolated let kind = "gmail"
    /// `gmail.modify` does not include permanent deletion. Gmail empties Trash after 30 days.
    public nonisolated var supportsPermanentDelete: Bool { false }

    private nonisolated let api: GmailAPI
    /// For servers other than Google's (one-click unsubscribe).
    private nonisolated let web: any HTTPTransport
    private let concurrency: Int
    private var knownLabels: [String: String] = [:]
    private var lastLabelCheck = Date.distantPast

    /// - Parameters:
    ///   - credential: nil when signed out. Every call then fails with `ProviderError.unauthorized`.
    ///   - concurrency: parallel requests when downloading conversations.
    public init(credential: GoogleCredential?, transport: any HTTPTransport = URLSessionTransport(), web: any HTTPTransport = WebTransport(), concurrency: Int = 8) {
        self.init(credential: credential, transport: transport, web: web, concurrency: concurrency, pacer: QuotaPacer())
    }

    init(credential: GoogleCredential?, transport: any HTTPTransport, web: any HTTPTransport, concurrency: Int, pacer: QuotaPacer) {
        api = GmailAPI(transport: transport, tokens: GoogleTokenSource(credential: credential, transport: transport), pacer: pacer)
        self.web = web
        self.concurrency = concurrency
    }

    static let base = "gmail/v1/users/me/"
    static let log = Log("gmail")

    // MARK: - Reading

    public func profile() async throws -> AccountProfile {
        async let profileRequest: GmailProfile = api.get(Self.base + "profile", cost: 1)
        async let sendAsRequest: GmailSendAsList = api.get(Self.base + "settings/sendAs", cost: 1)
        let (profile, sendAs) = try await (profileRequest, sendAsRequest)
        let aliases = sendAs.sendAs ?? []
        let primary = aliases.first { $0.isPrimary == true }
            ?? aliases.first { $0.sendAsEmail.caseInsensitiveCompare(profile.emailAddress) == .orderedSame }
        var name = primary?.displayName?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty {
            // Gmail leaves the name empty when it comes from the Google account. Sent mail shows it.
            name = (try? await nameFromSentMail(email: profile.emailAddress)) ?? ""
        }
        let signature = primary?.signature?.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.log.info("Profile: \(profile.emailAddress), history \(profile.historyId), \(profile.threadsTotal ?? 0) conversations on Gmail, \(aliases.count) send-as address(es), name \(name.isEmpty ? "unknown" : "found"), signature \(signature?.isEmpty == false ? "yes" : "no")")
        return AccountProfile(
            email: profile.emailAddress, displayName: name, historyCursor: profile.historyId,
            signatureHTML: signature?.isEmpty == false ? signature : nil
        )
    }

    private func nameFromSentMail(email: String) async throws -> String? {
        let list: GmailMessageList = try await api.get(Self.base + "messages", [
            URLQueryItem(name: "labelIds", value: SystemLabel.sent),
            URLQueryItem(name: "maxResults", value: "5"),
        ], cost: 5)
        for reference in list.messages ?? [] {
            let message: GmailMessage = try await api.get(Self.base + "messages/\(reference.id)", [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
            ], cost: 5)
            if let from = message.payload?.header("From").map(GmailMapping.decodeHeader).flatMap(EmailAddress.parse),
               from.normalized == email.lowercased(), let name = from.name {
                return name
            }
        }
        return nil
    }

    public func labels() async throws -> [MailLabel] {
        let list: GmailLabelList = try await api.get(Self.base + "labels", cost: 1)
        let labels = (list.labels ?? []).map(GmailMapping.label)
        Self.log.debug("Labels: \(labels.count) (\(labels.filter { $0.kind == .user }.count) user labels)")
        knownLabels = labels.reduce(into: [:]) { $0[$1.id] = $1.name }
        lastLabelCheck = Date()
        return labels
    }

    public func listThreadIDs(labelID: String?, pageToken: String?, pageSize: Int) async throws -> ThreadIDPage {
        var query = [
            URLQueryItem(name: "maxResults", value: String(min(max(pageSize, 1), 500))),
            URLQueryItem(name: "fields", value: "threads(id),nextPageToken"),
        ]
        if let labelID { query.append(URLQueryItem(name: "labelIds", value: labelID)) }
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let list: GmailThreadList = try await api.get(Self.base + "threads", query, cost: 10, priority: .bulk)
        return ThreadIDPage(ids: (list.threads ?? []).map(\.id), nextPageToken: list.nextPageToken)
    }

    public func threads(ids: [String]) async throws -> [[MailMessage]] {
        let api = api
        let clock = Stopwatch()
        let threads = try await Self.concurrentMap(ids, limit: concurrency) { id -> [MailMessage]? in
            do {
                return try await Self.fetchThread(id, api: api)
            } catch ProviderError.rejected(let reason) {
                // One conversation Gmail will not serve (or vimail cannot read) must not stop the sync.
                Self.log.error("Skipped conversation \(id): \(reason)")
                return nil
            }
        }
        let found = threads.compactMap { $0 }.filter { !$0.isEmpty }
        Self.log.debug("Fetched \(found.count) of \(ids.count) conversations (\(found.reduce(0) { $0 + $1.count }) messages) in \(clock.text)")
        return found
    }

    public func changes(since cursor: String) async throws -> ChangeSet {
        let clock = Stopwatch()
        var pageToken: String?
        var latest = cursor
        var added: [String] = []
        var addedSet = Set<String>()
        var labelState: [String: Set<String>] = [:]
        var deleted = Set<String>()
        var pages = 0
        repeat {
            var query = [
                URLQueryItem(name: "startHistoryId", value: cursor),
                URLQueryItem(name: "maxResults", value: "500"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GmailHistoryList
            do {
                page = try await api.get(Self.base + "history", query, cost: 2)
            } catch ProviderError.notFound {
                // Gmail keeps about a week of history. Older cursors need a fresh sync.
                Self.log.notice("History from \(cursor) has expired: a full resync is needed")
                throw ProviderError.cursorExpired
            }
            for record in page.history ?? [] {
                for entry in record.messagesAdded ?? [] {
                    let message = entry.message
                    if addedSet.insert(message.id).inserted { added.append(message.id) }
                    deleted.remove(message.id)
                    labelState[message.id] = Set(message.labelIds ?? [])
                }
                // Each entry carries the message's whole label set after the change.
                for entry in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
                    labelState[entry.message.id] = Set(entry.message.labelIds ?? [])
                }
                for entry in record.messagesDeleted ?? [] {
                    deleted.insert(entry.message.id)
                    labelState[entry.message.id] = nil
                }
            }
            if let historyID = page.historyId { latest = historyID }
            pageToken = page.nextPageToken
            pages += 1
            // So much changed that a fresh sync is faster than replaying history.
            if pages > 40 {
                Self.log.notice("More than 40 pages of history since \(cursor): a full resync is faster")
                throw ProviderError.cursorExpired
            }
        } while pageToken != nil

        let isDraft = { (id: String) in labelState[id]?.contains(SystemLabel.draft) ?? false }
        let wanted = added.filter { !deleted.contains($0) && !isDraft($0) }
        let api = api
        let fetched = try await Self.concurrentMap(wanted, limit: concurrency) { id in
            try await Self.fetchMessage(id, api: api)
        }
        var upserted: [MailMessage] = []
        var gone = deleted
        for (id, message) in zip(wanted, fetched) {
            guard let message else {
                gone.insert(id)
                continue
            }
            if !message.labelIDs.contains(SystemLabel.draft) { upserted.append(message) }
        }
        var labelUpdates: [String: Set<String>] = [:]
        for (id, labels) in labelState where !addedSet.contains(id) && !gone.contains(id) && !labels.contains(SystemLabel.draft) {
            labelUpdates[id] = labels
        }

        // A label nobody has seen means the label list changed. Renames show up in the periodic check.
        let referenced = Set(upserted.flatMap(\.labelIDs)).union(labelUpdates.values.flatMap { $0 })
        var labelsChanged = !referenced.isSubset(of: knownLabels.keys)
        if !labelsChanged, Date().timeIntervalSince(lastLabelCheck) > 300 {
            let previous = knownLabels
            _ = try await labels()
            labelsChanged = knownLabels != previous
        }
        let summary = "History \(cursor) → \(latest) (\(pages) page(s), \(clock.text)): \(upserted.count) new, \(labelUpdates.count) label change(s), \(gone.count) deleted\(labelsChanged ? ", label list changed" : "")"
        if upserted.isEmpty, labelUpdates.isEmpty, gone.isEmpty, !labelsChanged { Self.log.debug(summary) } else { Self.log.info(summary) }
        return ChangeSet(cursor: latest, upserted: upserted, labelUpdates: labelUpdates, deleted: Array(gone), labelsChanged: labelsChanged)
    }

    public func attachmentData(messageID: String, attachmentID: String) async throws -> Data {
        try await Self.attachment(messageID: messageID, attachmentID: attachmentID, api: api)
    }

    // MARK: - Changing

    public func modifyLabels(messageIDs: [String], add: Set<String>, remove: Set<String>) async throws {
        let ids = messageIDs.filter { !Self.isLocalID($0) }
        let add = add.filter { !Self.isLocalID($0) }.sorted()
        let remove = remove.filter { !Self.isLocalID($0) }.sorted()
        guard !ids.isEmpty, !(add.isEmpty && remove.isEmpty) else { return }
        Self.log.info("Changing labels on \(ids.count) message(s): +\(add.joined(separator: ",")) -\(remove.joined(separator: ","))")
        for start in stride(from: 0, to: ids.count, by: 1000) {
            let chunk = Array(ids[start..<min(start + 1000, ids.count)])
            try await api.sendWithoutResult(
                "POST", Self.base + "messages/batchModify",
                json: GmailBatchModify(ids: chunk, addLabelIds: add, removeLabelIds: remove), cost: 50
            )
        }
    }

    public func deleteMessages(ids: [String]) async throws {
        Self.log.notice("Refused permanent delete of \(ids.count) message(s): gmail.modify does not allow it")
        throw ProviderError.rejected("vimail's Gmail access cannot delete permanently. Gmail empties Trash after 30 days")
    }

    public func send(_ message: OutgoingMessage, fileData: [String: Data], isRetry: Bool) async throws -> MailMessage {
        let messageID = message.messageID ?? MIMEBuilder.makeMessageID(from: message.from)
        if isRetry {
            if let existing = try await findSent(messageID: messageID) {
                // An earlier attempt arrived; sending again would duplicate it.
                Self.log.notice("Send retry: Gmail already has \(messageID) as \(existing.id). Not sending again")
                return existing
            }
            Self.log.notice("Send retry: \(messageID) is not in Gmail yet. Sending")
        }
        var files: [MIMEBuilder.File] = []
        for attachment in message.attachments {
            switch attachment.source {
            case .file:
                guard let data = fileData[attachment.id] else { throw ProviderError.rejected("Attachment \(attachment.filename) is missing") }
                files.append(MIMEBuilder.File(filename: attachment.filename, mimeType: attachment.mimeType, data: data))
            case .remote(let sourceMessage, let sourceAttachment):
                let data = try await attachmentData(messageID: sourceMessage, attachmentID: sourceAttachment)
                files.append(MIMEBuilder.File(filename: attachment.filename, mimeType: attachment.mimeType, data: data))
            }
        }
        var outgoing = message
        if let threadID = outgoing.threadID, Self.isLocalID(threadID) { outgoing.threadID = nil }
        let mime = MIMEBuilder.build(outgoing, messageID: messageID, files: files)
        guard mime.count < 35_000_000 else { throw ProviderError.rejected("The message is larger than Gmail's 35 MB limit") }

        Self.log.info("Sending \(messageID): \(GmailAPI.bytes(mime.count)) MIME, \(files.count) attachment(s), \(outgoing.threadID.map { "thread \($0)" } ?? "new thread")")
        let clock = Stopwatch()
        let response = try await Self.upload(mime, threadID: outgoing.threadID, api: api)
        // Sent. From here on nothing may throw: a failure would put the draft back and invite a duplicate.
        let sent = try? JSONDecoder().decode(GmailMessageRef.self, from: response)
        Self.log.info("Sent \(messageID) in \(clock.text): Gmail message \(sent?.id ?? "?") in thread \(sent?.threadId ?? "?")")
        if let sent, let full = try? await Self.fetchMessage(sent.id, api: api) { return full }
        Self.log.notice("Sent \(messageID), but could not read the sent copy back. Using a local copy until the next sync")
        let id = sent?.id ?? "local-sent-\(UUID().uuidString.lowercased())"
        return MailMessage(
            id: id, threadID: sent?.threadId ?? outgoing.threadID ?? id, labelIDs: Set(sent?.labelIds ?? [SystemLabel.sent]), from: message.from,
            to: message.to, cc: message.cc, bcc: message.bcc, subject: message.subject,
            snippet: HTMLText.snippet(from: message.textBody), date: Date(), textBody: message.textBody, htmlBody: message.htmlBody,
            messageIDHeader: messageID, inReplyTo: message.inReplyTo, references: message.references
        )
    }

    /// The list's own server, not Gmail: no token, no cookies, no redirects, one attempt. A server error
    /// is `.server`: the outbox tries again later without holding up mail (see `SyncEngine`). Only a
    /// Mac without a network is `.offline`.
    public func unsubscribe(oneClick url: URL) async throws {
        guard url.scheme?.lowercased() == "https" else { throw ProviderError.rejected("One-click unsubscribe needs an https address") }
        // Only the host is logged: the rest of the address identifies you to the list.
        let host = url.host ?? "the list's server"
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        let clock = Stopwatch()
        let status: Int
        do {
            status = try await web.data(for: request).1.statusCode
        } catch let error as URLError {
            Self.log.notice("One-click unsubscribe at \(host): \(GmailAPI.describe(error)) after \(clock.text)")
            if Self.isOffline(error) { throw ProviderError.offline(error.localizedDescription) }
            throw ProviderError.server("\(host) could not be reached")
        }
        switch status {
        case 200..<400:
            // RFC 8058 forbids redirects. A server that sends one anyway still received the request.
            Self.log.info("One-click unsubscribe at \(host): \(status) in \(clock.text)")
        case 408, 429, 500...:
            Self.log.notice("One-click unsubscribe at \(host): \(status) after \(clock.text)")
            throw ProviderError.server("\(host) answered \(status)")
        default:
            Self.log.error("One-click unsubscribe at \(host): \(status) after \(clock.text)")
            throw ProviderError.rejected("\(host) answered \(status)")
        }
    }

    /// This Mac has no network (or sync is stopping), so the list's server is not to blame.
    static func isOffline(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .cancelled].contains(error.code)
    }

    public func createLabel(name: String) async throws -> MailLabel {
        do {
            let label: GmailLabel = try await api.send(
                "POST", Self.base + "labels",
                json: GmailLabelRequest(name: name, labelListVisibility: "labelShow", messageListVisibility: "show"),
                cost: 5, retry: .never
            )
            knownLabels[label.id] = label.name
            Self.log.info("Created label \(label.id)")
            return GmailMapping.label(label)
        } catch ProviderError.rejected(let reason) {
            Self.log.notice("Creating a label was refused (\(reason)). Looking for an existing one with that name")
            // It may exist already (created in Gmail, or by an earlier attempt). Use that one.
            if let existing = try await labels().first(where: { $0.kind == .user && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return existing
            }
            throw ProviderError.rejected(reason)
        }
    }

    public func renameLabel(id: String, to name: String) async throws -> MailLabel {
        let label: GmailLabel = try await api.send("PATCH", Self.base + "labels/\(id)", json: GmailLabelRequest(name: name), cost: 5)
        knownLabels[label.id] = label.name
        return GmailMapping.label(label)
    }

    public func deleteLabel(id: String) async throws {
        do {
            try await api.sendWithoutResult("DELETE", Self.base + "labels/\(id)", cost: 5)
        } catch ProviderError.notFound {
            // Already gone.
        }
        knownLabels[id] = nil
    }

    // MARK: - Helpers

    /// IDs that only exist in the local store (optimistic copies, unsynced labels, dry runs).
    static func isLocalID(_ id: String) -> Bool {
        id.hasPrefix("local-") || id.hasPrefix("pending-") || id.hasPrefix("dryrun-")
    }

    static func fetchThread(_ id: String, api: GmailAPI) async throws -> [MailMessage]? {
        let thread: GmailThread
        do {
            thread = try await api.get(base + "threads/\(id)", [URLQueryItem(name: "format", value: "full")], cost: 10, priority: .bulk)
        } catch ProviderError.notFound {
            return nil
        }
        var messages: [MailMessage] = []
        for message in thread.messages ?? [] where !(message.labelIds ?? []).contains(SystemLabel.draft) {
            messages.append(try await complete(message, api: api))
        }
        return messages.sorted { $0.date < $1.date }
    }

    static func fetchMessage(_ id: String, api: GmailAPI) async throws -> MailMessage? {
        do {
            let message: GmailMessage = try await api.get(base + "messages/\(id)", [URLQueryItem(name: "format", value: "full")], cost: 5)
            return try await complete(message, api: api)
        } catch ProviderError.notFound {
            return nil
        }
    }

    /// Maps a message, first downloading body parts Gmail sent by reference.
    static func complete(_ message: GmailMessage, api: GmailAPI) async throws -> MailMessage {
        var bodies: [String: Data] = [:]
        for attachmentID in GmailMapping.missingBodyAttachmentIDs(message) {
            bodies[attachmentID] = try await attachment(messageID: message.id, attachmentID: attachmentID, api: api)
        }
        return GmailMapping.message(message, fetchedBodies: bodies)
    }

    static func attachment(messageID: String, attachmentID: String, api: GmailAPI) async throws -> Data {
        if attachmentID.hasPrefix("part:") {
            // Small parts arrive inline, without an attachment ID: read them from the message.
            let partID = String(attachmentID.dropFirst(5))
            let message: GmailMessage = try await api.get(base + "messages/\(messageID)", [URLQueryItem(name: "format", value: "full")], cost: 5)
            guard let payload = message.payload, let part = GmailMapping.part(withID: partID, in: payload) else {
                throw ProviderError.notFound("attachment")
            }
            if let inline = part.body?.data, let data = Data(base64URLEncoded: inline) { return data }
            if let id = part.body?.attachmentId { return try await attachment(messageID: messageID, attachmentID: id, api: api) }
            throw ProviderError.notFound("attachment")
        }
        let body: GmailAttachmentBody = try await api.get(base + "messages/\(messageID)/attachments/\(attachmentID)", cost: 5)
        guard let encoded = body.data, let data = Data(base64URLEncoded: encoded) else { throw ProviderError.server("Empty attachment") }
        return data
    }

    /// Sends raw MIME with the media upload endpoint (up to 35 MB), keeping the thread.
    /// Returns Gmail's response (the new message's ID and thread).
    static func upload(_ mime: Data, threadID: String?, api: GmailAPI) async throws -> Data {
        let boundary = "vimail-upload-\(UUID().uuidString.lowercased())"
        let metadata = threadID.map { "{\"threadId\":\"\($0)\"}" } ?? "{}"
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(metadata)\r\n".utf8)
        body.append(Data("--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(mime)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try await api.perform(
            "POST", "upload/" + base + "messages/send", query: [URLQueryItem(name: "uploadType", value: "multipart")],
            body: body, contentType: "multipart/related; boundary=\(boundary)", cost: 100, retry: .never, timeout: 300
        )
    }

    /// The sent copy of a message with this Message-ID, if Gmail has one.
    private func findSent(messageID: String) async throws -> MailMessage? {
        let id = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let list: GmailMessageList = try await api.get(Self.base + "messages", [
            URLQueryItem(name: "q", value: "rfc822msgid:\(id)"),
            URLQueryItem(name: "includeSpamTrash", value: "true"),
            URLQueryItem(name: "maxResults", value: "1"),
        ], cost: 5)
        guard let reference = list.messages?.first else { return nil }
        return try await Self.fetchMessage(reference.id, api: api)
    }

    /// Runs `transform` over `items` with at most `limit` in flight. Results keep the input order.
    static func concurrentMap<Item: Sendable, Result: Sendable>(
        _ items: [Item], limit: Int, _ transform: @escaping @Sendable (Item) async throws -> Result
    ) async throws -> [Result] {
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var results = [Result?](repeating: nil, count: items.count)
            var next = 0
            while next < min(max(limit, 1), items.count) {
                let index = next
                group.addTask { (index, try await transform(items[index])) }
                next += 1
            }
            while let (index, value) = try await group.next() {
                results[index] = value
                if next < items.count {
                    let index = next
                    group.addTask { (index, try await transform(items[index])) }
                    next += 1
                }
            }
            return results.map { $0! }
        }
    }
}
