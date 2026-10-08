import Foundation
import MailCore
import MailStore

/// Runs the message processor pipeline (for example an AI classifier) in the background.
///
/// - New messages from sync are enqueued automatically.
/// - `backfill()` processes stored mail that a processor (or a new processor version) has not seen.
/// - Each (message, processor, version) runs once; results are recorded in `processing_log`.
/// - Effects go through `MailActions`, so labels and flags are stored locally and synced like
///   any other change. Labels default to local-only (`LabelScope.local`).
public actor ProcessingCoordinator {
    public let pipeline: ProcessingPipeline
    private let store: MailStore
    private let actions: MailActions
    private let maxConcurrent: Int
    private var queue: [String] = []
    private var queued = Set<String>()
    private var running = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(pipeline: ProcessingPipeline, store: MailStore, actions: MailActions, maxConcurrent: Int = 4) {
        self.pipeline = pipeline
        self.store = store
        self.actions = actions
        self.maxConcurrent = maxConcurrent
    }

    public func enqueue(_ messageIDs: [String]) {
        guard !pipeline.isEmpty else { return }
        for id in messageIDs where queued.insert(id).inserted { queue.append(id) }
        pump()
    }

    /// Queues stored messages that have not been processed yet, newest first.
    public func backfill(limit: Int = 500) async {
        for processor in pipeline.processors {
            let ids = (try? await store.unprocessedMessageIDs(processorID: processor.id, version: processor.version, limit: limit)) ?? []
            enqueue(ids)
        }
    }

    /// Waits until the queue is empty (for tests).
    public func waitUntilIdle() async {
        if queue.isEmpty && running == 0 { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func pump() {
        while running < maxConcurrent, !queue.isEmpty {
            let id = queue.removeFirst()
            running += 1
            Task {
                await self.process(id)
                self.finished(id)
            }
        }
    }

    private func finished(_ id: String) {
        running -= 1
        queued.remove(id)
        pump()
        if queue.isEmpty && running == 0 {
            idleWaiters.forEach { $0.resume() }
            idleWaiters.removeAll()
        }
    }

    private func process(_ messageID: String) async {
        guard let message = try? await store.message(id: messageID),
              let thread = try? await store.thread(id: message.threadID) else { return }
        let labels = (try? await store.labels()) ?? []
        let input = ProcessorInput(message: message, thread: thread.messages, labels: labels, accountEmail: store.selfAddresses.first ?? "")

        for processor in pipeline.processors where processor.accepts(message) {
            if (try? await store.isProcessed(messageID: messageID, processorID: processor.id, version: processor.version)) == true { continue }
            do {
                let effects = try await processor.process(input)
                try await apply(effects, to: message, source: processor.id)
                try await store.markProcessed(messageID: messageID, processorID: processor.id, version: processor.version, error: nil)
            } catch {
                try? await store.markProcessed(messageID: messageID, processorID: processor.id, version: processor.version, error: String(describing: error))
            }
        }
    }

    private func apply(_ effects: [ProcessorEffect], to message: MailMessage, source: String) async throws {
        for effect in effects {
            switch effect {
            case .addLabel(let name, let scope):
                let label = try await actions.ensureLabel(named: name, kind: scope == .local ? .local : .user)
                try await actions.modify(messageIDs: [message.id], add: [label.id], remove: [])
            case .removeLabel(let name):
                let labels = try await store.labels()
                if let label = labels.first(where: { $0.kind != .system && $0.name.lowercased() == name.lowercased() }) {
                    try await actions.modify(messageIDs: [message.id], add: [], remove: [label.id])
                }
            case .annotate(let key, let value):
                try await store.annotate(messageID: message.id, key: key, value: value, source: source)
            case .markRead:
                try await actions.perform(.markRead, threads: [message.threadID])
            case .archive:
                try await actions.perform(.archive, threads: [message.threadID])
            case .star:
                try await actions.perform(.star, threads: [message.threadID])
            }
        }
    }
}
