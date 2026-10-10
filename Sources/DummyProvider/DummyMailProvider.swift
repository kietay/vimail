import Foundation
import MailCore

/// A fake Gmail server. It behaves like the real API (labels, threads, history cursors,
/// latency, failures) so the whole app — sync engine included — runs without touching real mail.
///
/// State persists to a JSON file, so changes survive relaunches like a real server's would.
public actor DummyMailProvider: MailProvider {
    public struct Configuration: Sendable {
        /// Simulated network latency per call, in milliseconds.
        public var latency: ClosedRange<Int> = 40...160
        /// Fraction of calls that fail with `ProviderError.offline` (0 = never).
        public var failureRate: Double = 0
        /// Deliver new mail from time to time.
        public var simulateIncomingMail = true
        /// Seconds between simulated incoming messages.
        public var incomingInterval: ClosedRange<Double> = 90...240
        /// Contacts sometimes reply to mail you send them.
        public var simulateReplies = true
        public var seed: UInt64 = 2026

        public init() {}
    }

    struct HistoryRecord: Codable {
        enum Kind: String, Codable { case added, labels, deleted, labelList }
        var id: Int
        var kind: Kind
        var messageIDs: [String]
    }

    struct ScheduledReply: Codable {
        var due: Date
        var threadID: String
        var from: EmailAddress
        var inReplyTo: String
    }

    struct State: Codable {
        var account: EmailAddress
        var labels: [MailLabel]
        var messages: [String: MailMessage]
        var historyID: Int
        var history: [HistoryRecord]
        var nextID: UInt64
        var nextLabelNumber: Int
        var scheduledReplies: [ScheduledReply]
        var incomingCounter: Int
    }

    public nonisolated let kind = "dummy"
    private let storageURL: URL
    private let attachmentsDirectory: URL
    private var configuration: Configuration
    private var state: State?
    private var saveTask: Task<Void, Never>?
    private var simulationTask: Task<Void, Never>?
    private var generator: SeededGenerator
    private nonisolated let signalStream: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation
    private static let historyRetention = 5_000

    /// - Parameter directory: where the fake server keeps its state.
    public init(directory: URL, configuration: Configuration = Configuration()) {
        self.storageURL = directory.appendingPathComponent("server.json")
        self.attachmentsDirectory = directory.appendingPathComponent("attachments", isDirectory: true)
        self.configuration = configuration
        self.generator = SeededGenerator(seed: configuration.seed &+ UInt64(Date().timeIntervalSince1970))
        (signalStream, signalContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public nonisolated func changeSignals() -> AsyncStream<Void> { signalStream }

    // MARK: - Configuration and simulation

    public func configure(_ configuration: Configuration) {
        let restart = configuration.simulateIncomingMail != self.configuration.simulateIncomingMail
            || configuration.incomingInterval != self.configuration.incomingInterval
        self.configuration = configuration
        if restart { startSimulation() }
    }

    /// Starts delivering simulated incoming mail and replies (when enabled).
    public func startSimulation() {
        simulationTask?.cancel()
        simulationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.nextSimulationDelay()
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                await self.simulationTick()
            }
        }
    }

    public func stopSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
    }

    private func nextSimulationDelay() -> Double {
        var delay = configuration.simulateIncomingMail ? Double.random(in: configuration.incomingInterval, using: &generator) : 3600
        if let due = state?.scheduledReplies.map(\.due).min() {
            delay = min(delay, max(1, due.timeIntervalSinceNow))
        }
        return delay
    }

    private func simulationTick() {
        guard state != nil else { return }
        var delivered = deliverDueReplies()
        if configuration.simulateIncomingMail, delivered == 0 || Bool.random(using: &generator) {
            deliverIncoming(count: 1)
            delivered += 1
        }
        if delivered > 0 { signalContinuation.yield() }
    }

    /// Delivers simulated new mail now (for the "Simulate incoming mail" command).
    public func deliverIncomingMail(count: Int = 1) throws {
        try ensureLoaded()
        deliverIncoming(count: count)
        signalContinuation.yield()
    }

    /// Wipes the fake server and regenerates it.
    public func reset() throws {
        state = nil
        try? FileManager.default.removeItem(at: storageURL)
        try? FileManager.default.removeItem(at: attachmentsDirectory)
        try ensureLoaded()
    }

    // MARK: - Persistence

    private func ensureLoaded() throws {
        guard state == nil else { return }
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? Self.decoder.decode(State.self, from: data) {
            state = decoded
            return
        }
        var builder = DummyGenerator(seed: configuration.seed, now: Date())
        state = builder.makeState()
        scheduleSave(immediately: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private func scheduleSave(immediately: Bool = false) {
        saveTask?.cancel()
        let url = storageURL
        saveTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled, let snapshot = await self?.state else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? Self.encoder.encode(snapshot) else { return }
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    /// Waits for pending writes (for tests).
    public func flush() async {
        await saveTask?.value
    }

    // MARK: - Simulated network

    private func network() async throws {
        let delay = Int.random(in: configuration.latency, using: &generator)
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        if configuration.failureRate > 0, Double.random(in: 0..<1, using: &generator) < configuration.failureRate {
            throw ProviderError.offline("Simulated network failure")
        }
        try ensureLoaded()
    }

    private func record(_ kind: HistoryRecord.Kind, _ messageIDs: [String]) {
        guard state != nil else { return }
        state!.historyID += 1
        state!.history.append(HistoryRecord(id: state!.historyID, kind: kind, messageIDs: messageIDs))
        if state!.history.count > Self.historyRetention {
            state!.history.removeFirst(state!.history.count - Self.historyRetention)
        }
        scheduleSave()
    }

    private func newID() -> String {
        state!.nextID &+= 1
        var mixed = state!.nextID &* 0x9E37_79B9_7F4A_7C15
        mixed ^= mixed >> 29
        return String(format: "%016llx", (mixed & 0x0000_FFFF_FFFF_FFFF) | 0x0001_9000_0000_0000)
    }

    // MARK: - MailProvider

    public func profile() async throws -> AccountProfile {
        try await network()
        return AccountProfile(email: state!.account.email, displayName: state!.account.name ?? "", historyCursor: String(state!.historyID), aliases: [])
    }

    public func labels() async throws -> [MailLabel] {
        try await network()
        return state!.labels
    }

    public func listThreadIDs(labelID: String?, pageToken: String?, pageSize: Int) async throws -> ThreadIDPage {
        try await network()
        var latest: [String: Date] = [:]
        var matching = Set<String>()
        for message in state!.messages.values where !message.labelIDs.contains(SystemLabel.draft) {
            latest[message.threadID] = max(latest[message.threadID] ?? .distantPast, message.date)
            let hidden = message.labelIDs.contains(SystemLabel.spam) || message.labelIDs.contains(SystemLabel.trash)
            if labelID.map(message.labelIDs.contains) ?? !hidden { matching.insert(message.threadID) }
        }
        let ordered = latest.filter { matching.contains($0.key) }.sorted { $0.value > $1.value }.map(\.key)
        let start = Int(pageToken ?? "0") ?? 0
        let end = min(start + pageSize, ordered.count)
        guard start < end else { return ThreadIDPage(ids: [], nextPageToken: nil) }
        return ThreadIDPage(ids: Array(ordered[start..<end]), nextPageToken: end < ordered.count ? String(end) : nil)
    }

    public func threads(ids: [String]) async throws -> [[MailMessage]] {
        try await network()
        let wanted = Set(ids)
        let grouped = Dictionary(grouping: state!.messages.values.filter { wanted.contains($0.threadID) }, by: \.threadID)
        return ids.compactMap { id in grouped[id]?.sorted { $0.date < $1.date } }
    }

    public func changes(since cursor: String) async throws -> ChangeSet {
        try await network()
        guard let since = Int(cursor) else { throw ProviderError.cursorExpired }
        if let first = state!.history.first, since < first.id - 1 { throw ProviderError.cursorExpired }

        var added = Set<String>()
        var labelChanged = Set<String>()
        var deleted = Set<String>()
        var labelsChanged = false
        for record in state!.history where record.id > since {
            switch record.kind {
            case .added: added.formUnion(record.messageIDs)
            case .labels: labelChanged.formUnion(record.messageIDs)
            case .deleted: deleted.formUnion(record.messageIDs)
            case .labelList: labelsChanged = true
            }
        }
        let messages = state!.messages
        let upserted = added.subtracting(deleted).compactMap { messages[$0] }
        var labelUpdates: [String: Set<String>] = [:]
        for id in labelChanged.subtracting(added).subtracting(deleted) {
            if let message = messages[id] { labelUpdates[id] = message.labelIDs }
        }
        return ChangeSet(cursor: String(state!.historyID), upserted: upserted, labelUpdates: labelUpdates, deleted: Array(deleted), labelsChanged: labelsChanged)
    }

    public func modifyLabels(messageIDs: [String], add: Set<String>, remove: Set<String>) async throws {
        try await network()
        let known = Set(state!.labels.map(\.id))
        if let unknown = add.subtracting(known).first {
            throw ProviderError.rejected("Unknown label \(unknown)")
        }
        var changed: [String] = []
        for id in messageIDs {
            guard var message = state!.messages[id] else { continue }
            let before = message.labelIDs
            message.labelIDs.subtract(remove)
            message.labelIDs.formUnion(add)
            if message.labelIDs != before {
                state!.messages[id] = message
                changed.append(id)
            }
        }
        if !changed.isEmpty { record(.labels, changed) }
    }

    public func deleteMessages(ids: [String]) async throws {
        try await network()
        let existing = ids.filter { state!.messages[$0] != nil }
        for id in existing { state!.messages[id] = nil }
        if !existing.isEmpty { record(.deleted, existing) }
    }

    public func send(_ outgoing: OutgoingMessage, fileData: [String: Data], isRetry: Bool) async throws -> MailMessage {
        try await network()
        guard !(outgoing.to + outgoing.cc + outgoing.bcc).isEmpty else { throw ProviderError.rejected("No recipients") }
        if let invalid = (outgoing.to + outgoing.cc + outgoing.bcc).first(where: { !$0.isValid }) {
            throw ProviderError.rejected("Invalid address: \(invalid.email)")
        }

        let id = newID()
        let threadID = outgoing.threadID.flatMap { thread in state!.messages.values.contains { $0.threadID == thread } ? thread : nil } ?? id
        var attachments: [MailAttachment] = []
        for attachment in outgoing.attachments {
            let attachmentID = "att-\(newID())"
            switch attachment.source {
            case .file:
                if let data = fileData[attachment.id] {
                    try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
                    try? data.write(to: attachmentsDirectory.appendingPathComponent(attachmentID))
                }
            case .remote(let messageID, let sourceID):
                let data = try attachmentBytes(messageID: messageID, attachmentID: sourceID)
                try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
                try? data.write(to: attachmentsDirectory.appendingPathComponent(attachmentID))
            }
            attachments.append(MailAttachment(id: attachmentID, filename: attachment.filename, mimeType: attachment.mimeType, size: attachment.size))
        }

        var labels: Set<String> = [SystemLabel.sent]
        let me = state!.account.normalized
        if (outgoing.to + outgoing.cc + outgoing.bcc).contains(where: { $0.normalized == me }) {
            labels.formUnion([SystemLabel.inbox, SystemLabel.unread])
        }
        let message = MailMessage(
            id: id, threadID: threadID, labelIDs: labels, from: state!.account,
            to: outgoing.to, cc: outgoing.cc, bcc: outgoing.bcc, subject: outgoing.subject,
            snippet: HTMLText.snippet(from: outgoing.textBody), date: Date(),
            textBody: outgoing.textBody, htmlBody: outgoing.htmlBody, attachments: attachments,
            messageIDHeader: "<\(id)@vimail.dummy>", inReplyTo: outgoing.inReplyTo, references: outgoing.references,
            sizeEstimate: outgoing.textBody.utf8.count + (outgoing.htmlBody?.utf8.count ?? 0)
        )
        state!.messages[id] = message
        record(.added, [id])
        scheduleReply(to: message)
        return message
    }

    /// What the lists' servers received, for tests. Not saved: the lists are not part of the server.
    public private(set) var oneClickUnsubscribes: [URL] = []

    /// A list at a `gone.…` host refuses one-click unsubscribes, and one at `down.…` never answers,
    /// to try the failure paths.
    public func unsubscribe(oneClick url: URL) async throws {
        try await network()
        let host = url.host ?? ""
        if host.hasPrefix("gone.") { throw ProviderError.rejected("\(host) answered 404") }
        if host.hasPrefix("down.") { throw ProviderError.server("\(host) answered 503") }
        oneClickUnsubscribes.append(url)
    }

    public func attachmentData(messageID: String, attachmentID: String) async throws -> Data {
        try await network()
        return try attachmentBytes(messageID: messageID, attachmentID: attachmentID)
    }

    private func attachmentBytes(messageID: String, attachmentID: String) throws -> Data {
        guard let message = state!.messages[messageID], let attachment = message.attachments.first(where: { $0.id == attachmentID }) else {
            throw ProviderError.notFound("attachment \(attachmentID)")
        }
        if let stored = try? Data(contentsOf: attachmentsDirectory.appendingPathComponent(attachmentID)) { return stored }
        return DummyAttachments.data(for: attachment, in: message)
    }

    public func createLabel(name: String) async throws -> MailLabel {
        try await network()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ProviderError.rejected("Empty label name") }
        if state!.labels.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            throw ProviderError.rejected("Label “\(trimmed)” already exists")
        }
        state!.nextLabelNumber += 1
        let label = MailLabel(id: "Label_\(state!.nextLabelNumber)", name: trimmed, kind: .user)
        state!.labels.append(label)
        record(.labelList, [])
        return label
    }

    public func renameLabel(id: String, to name: String) async throws -> MailLabel {
        try await network()
        guard let index = state!.labels.firstIndex(where: { $0.id == id && $0.kind == .user }) else { throw ProviderError.notFound("label \(id)") }
        state!.labels[index].name = name
        record(.labelList, [])
        return state!.labels[index]
    }

    public func deleteLabel(id: String) async throws {
        try await network()
        guard state!.labels.contains(where: { $0.id == id && $0.kind == .user }) else { throw ProviderError.notFound("label \(id)") }
        state!.labels.removeAll { $0.id == id }
        var changed: [String] = []
        for (messageID, var message) in state!.messages where message.labelIDs.contains(id) {
            message.labelIDs.remove(id)
            state!.messages[messageID] = message
            changed.append(messageID)
        }
        record(.labelList, [])
        if !changed.isEmpty { record(.labels, changed) }
    }

    // MARK: - Simulated incoming mail

    private func deliverIncoming(count: Int) {
        guard state != nil else { return }
        var content = DummyGenerator(seed: generator.next(), now: Date())
        for _ in 0..<count {
            state!.incomingCounter += 1
            let existing = Array(state!.messages.values)
            let messages = content.incomingMessages(account: state!.account, existing: existing, labels: state!.labels, newID: { self.newID() })
            for message in messages { state!.messages[message.id] = message }
            record(.added, messages.map(\.id))
        }
    }

    private func scheduleReply(to sent: MailMessage) {
        guard configuration.simulateReplies,
              let recipient = sent.to.first,
              DummyContent.people.contains(where: { $0.address.normalized == recipient.normalized }),
              Double.random(in: 0..<1, using: &generator) < 0.4 else { return }
        let due = Date().addingTimeInterval(Double.random(in: 30...120, using: &generator))
        state!.scheduledReplies.append(ScheduledReply(due: due, threadID: sent.threadID, from: recipient, inReplyTo: sent.id))
        scheduleSave()
        startSimulation()
    }

    private func deliverDueReplies() -> Int {
        guard state != nil else { return 0 }
        let now = Date()
        let due = state!.scheduledReplies.filter { $0.due <= now }
        guard !due.isEmpty else { return 0 }
        state!.scheduledReplies.removeAll { $0.due <= now }
        var content = DummyGenerator(seed: generator.next(), now: now)
        var delivered = 0
        for reply in due {
            guard let original = state!.messages[reply.inReplyTo] else { continue }
            let message = content.reply(to: original, from: reply.from, account: state!.account, id: newID())
            state!.messages[message.id] = message
            record(.added, [message.id])
            delivered += 1
        }
        return delivered
    }
}

/// Deterministic random numbers (SplitMix64), so the dummy mailbox is the same on every machine.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
