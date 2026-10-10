import Foundation
import MailCore
import MailStore
import VimailLog

/// Keeps the local store and the provider in step.
///
/// Each cycle: push the outbox (oldest first), pull provider changes, wake due snoozes, then
/// cache one more page of older mail until the cache holds the newest `initialSyncLimit` conversations.
/// Cycles run on a poll interval, when the provider signals changes, and right after local actions.
/// Transient failures (offline, rate limits) back off and retry; the app keeps working locally.
///
/// The first sync downloads the inbox only, so it is usable quickly on slow networks. It can be
/// interrupted at any point: it resumes from the same history cursor and skips what it already has.
public actor SyncEngine {
    /// Each phase with counts and timings, outbox results and status changes.
    static let log = Log("sync")

    public struct Status: Equatable, Sendable {
        public enum Phase: Equatable, Sendable { case idle, syncing, offline, rateLimited, failed, signedOut }
        public var phase: Phase = .idle
        public var message: String?
        public var lastSuccess: Date?
        public var pendingOperations = 0
        /// Inbox conversations fetched so far during the first sync, or nil.
        public var initialSyncProgress: Int?
        /// Older conversations cached so far in the background, or nil when the cache is complete.
        public var backfillProgress: Int?
        public init() {}
    }

    public enum Event: Sendable {
        /// New messages arrived in the inbox.
        case newMail(messageIDs: [String])
        case sent(draftID: String)
        /// The provider rejected a send. The draft was restored.
        case sendFailed(draft: Draft, reason: String)
        /// The provider rejected another queued change. The affected mail was refetched.
        case operationFailed(String)
        /// Gmail refused labels that rules added. They came off here; the rules status reports them, not a toast.
        case rulesGmailRejected(count: Int)
        /// A queued unsubscribe went through.
        case unsubscribed(list: String)
        /// A queued unsubscribe failed for good: the list refused it, or its server never answered.
        case unsubscribeFailed(outboxID: Int64, list: String, reason: String)
        /// The provider refused an answer by email. The answer before it is back; `outcome` says what stands now.
        case answerFailed(outboxID: Int64, summary: String, reason: String, outcome: RefusedAnswerOutcome)
    }

    public let provider: any MailProvider
    public let store: MailStore
    public nonisolated let statusUpdates: AsyncStream<Status>
    public nonisolated let events: AsyncStream<Event>
    private let statusContinuation: AsyncStream<Status>.Continuation
    private let eventContinuation: AsyncStream<Event>.Continuation

    private var rules: (any RuleWaking)?
    private var actions: MailActions?
    private var pollInterval: Duration
    private let initialSyncLimit: Int
    private let draftFilesDirectory: URL?
    private var status = Status()
    private var loop: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    /// The first `stop()`: later calls wait for it.
    private var stopping: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var wakeRequested = false
    private var sleepGeneration = 0
    private var failureStreak = 0
    private var cycleNumber = 0
    private var lastFailureWasRateLimit = false
    /// Held while mail downloads or changes wait to be sent, so macOS does not throttle the app
    /// (App Nap) when its window is hidden or the screen is locked.
    private var activity: (any NSObjectProtocol)?
    private(set) var activityReason: String?

    /// - Parameters:
    ///   - initialSyncLimit: how many of the newest conversations are cached (the inbox is always cached).
    ///   - draftFilesDirectory: where draft attachments live; cleaned up after sending.
    public init(provider: any MailProvider, store: MailStore, pollInterval: Duration = .seconds(30), initialSyncLimit: Int = 2_000, draftFilesDirectory: URL? = nil) {
        self.provider = provider
        self.store = store
        self.pollInterval = pollInterval
        self.initialSyncLimit = initialSyncLimit
        self.draftFilesDirectory = draftFilesDirectory
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    /// - Parameter rules: woken after newly arrived mail is stored, or nil when no rules run.
    public func attach(actions: MailActions, rules: (any RuleWaking)?) {
        self.actions = actions
        self.rules = rules
    }

    public func setPollInterval(_ interval: Duration) {
        pollInterval = interval
        wakeNow()
    }

    public func start() {
        guard loop == nil, stopping == nil else { return }
        Self.log.info("Sync started (provider \(provider.kind), poll every \(pollInterval), cache limit \(initialSyncLimit) conversations)")
        loop = Task { [weak self] in await self?.run() }
        let signals = provider.changeSignals()
        signalTask = Task { [weak self] in
            for await _ in signals { self?.wake() }
        }
    }

    /// Stops syncing for good (the account is closing). Returns once the running cycle has finished,
    /// so nothing writes to the store afterwards. Ends the status and event streams.
    public func stop() async {
        // A second stop returns once the first is done.
        if let stopping { return await stopping.value }
        let running = loop
        running?.cancel()
        signalTask?.cancel()
        loop = nil
        signalTask = nil
        waiter?.resume()
        waiter = nil
        let task = Task {
            await running?.value
            await self.stopped()
        }
        stopping = task
        await task.value
    }

    private func stopped() {
        // Only now: the cycle it waited for may have kept the app awake again.
        keepAwake(nil)
        statusContinuation.finish()
        eventContinuation.finish()
        Self.log.info("Sync stopped")
    }

    /// Requests a cycle as soon as possible (after local actions, or "sync now").
    public nonisolated func wake() {
        Task { await self.wakeNow() }
    }

    private func wakeNow() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            wakeRequested = true
        }
    }

    // MARK: - Loop

    private func run() async {
        try? await store.resetInflightOutboxItems()
        while !Task.isCancelled {
            let succeeded = await cycle()
            failureStreak = succeeded ? 0 : failureStreak + 1
            let delay = await nextDelay(afterFailure: !succeeded)
            if !succeeded { Self.log.notice("Next attempt in \(delay) (failure \(failureStreak) in a row)") }
            await sleep(for: delay)
        }
    }

    private func nextDelay(afterFailure failed: Bool) async -> Duration {
        // Rate limits clear within seconds; offline can last longer.
        let failureDelay: Duration = lastFailureWasRateLimit ? .seconds(min(5 * failureStreak, 30)) : min(.seconds(2 << min(failureStreak, 6)), .seconds(120))
        var delay = failed ? failureDelay : pollInterval
        let now = Date()
        for date in [try? await store.nextOutboxDueDate(), try? await store.nextSnoozeDate()] {
            guard let date = date ?? nil else { continue }
            let seconds = max(0.05, date.timeIntervalSince(now) + 0.05)
            if !failed || seconds > 1 { delay = min(delay, .milliseconds(Int(seconds * 1000))) }
        }
        return delay
    }

    private func sleep(for delay: Duration) async {
        // Stopped during the cycle: `stop()` is waiting for the loop to end.
        guard !Task.isCancelled else { return }
        if wakeRequested {
            wakeRequested = false
            return
        }
        sleepGeneration += 1
        let generation = sleepGeneration
        let timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.timerFired(generation)
        }
        await withCheckedContinuation { waiter = $0 }
        timer.cancel()
    }

    private func timerFired(_ generation: Int) {
        guard generation == sleepGeneration, let waiter else { return }
        self.waiter = nil
        waiter.resume()
    }

    private func publish(_ update: (inout Status) -> Void) {
        let previous = status
        update(&status)
        if status.phase != previous.phase {
            Self.log.info("Status \(previous.phase) → \(status.phase)\(status.message.map { ": \($0)" } ?? "")")
        }
        statusContinuation.yield(status)
    }

    /// Keeps the app out of App Nap while `reason` applies; nil allows it again.
    private func keepAwake(_ reason: String?) {
        guard reason != activityReason else { return }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        activityReason = reason
        if let reason {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: reason)
            Self.log.info("App Nap off: \(reason)")
        } else {
            Self.log.info("App Nap allowed again")
        }
    }

    /// Downloads and queued changes should not wait for the app to come to the front.
    private func updateKeepAwake() async {
        let inboxDone = (try? await store.meta("initial_sync_done")) != nil
        let backfillDone = (try? await store.meta("backfill_done")) != nil
        let downloading = !inboxDone || !backfillDone
        let pending = ((try? await store.outboxCount()) ?? 0) > 0
        keepAwake(downloading ? "downloading mail" : pending ? "sending queued changes" : nil)
    }

    /// One sync cycle. Returns false on failure.
    @discardableResult
    public func cycle() async -> Bool {
        cycleNumber += 1
        let number = cycleNumber
        let clock = Stopwatch()
        Self.log.debug("Cycle \(number) started")
        lastFailureWasRateLimit = false
        publish { $0.phase = .syncing; $0.message = nil }
        await updateKeepAwake()
        do {
            if try await store.meta("initial_sync_done") == nil {
                try await initialSync()
            } else if try await store.meta("account_aliases") == nil {
                // Synced before send-as aliases were kept: fetch them once, so rules skip mail sent from them.
                try await store.setAccount(try await provider.profile())
            }
            try await flushOutbox()
            try await pullChanges()
            try await wakeDueSnoozes()
            // More older mail to cache: continue right away. Each cycle still pushes and pulls first.
            if try await backfill() { wakeRequested = true }
            let pending = (try? await store.outboxCount()) ?? 0
            publish {
                $0.phase = .idle
                $0.lastSuccess = Date()
                $0.pendingOperations = pending
                $0.initialSyncProgress = nil
            }
            await updateKeepAwake()
            Self.log.debug("Cycle \(number) finished in \(clock.text)\(pending > 0 ? ", \(pending) change(s) still queued" : "")")
            return true
        } catch ProviderError.unauthorized {
            Self.log.error("Cycle \(number): signed out (the provider rejected the credentials) after \(clock.text)")
            let pending = (try? await store.outboxCount()) ?? 0
            publish {
                $0.phase = .signedOut
                $0.message = "Signed out. Sign in again to sync."
                $0.pendingOperations = pending
            }
            return false
        } catch ProviderError.rateLimited {
            Self.log.notice("Cycle \(number) paused after \(clock.text): Gmail rate limit. Progress so far is saved")
            lastFailureWasRateLimit = true
            let pending = (try? await store.outboxCount()) ?? 0
            publish {
                $0.phase = .rateLimited
                $0.message = "Gmail asked vimail to slow down. Continuing shortly."
                $0.pendingOperations = pending
            }
            return false
        } catch let error as ProviderError where error.isTransient {
            Self.log.notice("Cycle \(number) stopped after \(clock.text): \(error.localizedDescription)")
            let pending = (try? await store.outboxCount()) ?? 0
            publish {
                $0.phase = .offline
                $0.message = error.localizedDescription
                $0.pendingOperations = pending
            }
            return false
        } catch {
            Self.log.error("Cycle \(number) failed after \(clock.text): \(String(describing: error))")
            let pending = (try? await store.outboxCount()) ?? 0
            publish {
                $0.phase = .failed
                $0.message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                $0.pendingOperations = pending
            }
            return false
        }
    }

    // MARK: - Initial sync

    /// Downloads the inbox. Changes made meanwhile are replayed from the cursor taken at the start.
    private func initialSync() async throws {
        let clock = Stopwatch()
        let profile = try await provider.profile()
        try await store.setAccount(profile)
        let labels = try await provider.labels()
        try await store.replaceProviderLabels(labels)
        Self.log.info("Initial sync: profile and \(labels.count) labels in \(clock.text)")

        // Resuming an interrupted sync: keep its cursor, and skip conversations it already stored
        // (history replays any change to them). A full resync refetches everything.
        let savedCursor = try await store.meta("initial_cursor")
        let resync = try await store.meta("resync") != nil
        let skipExisting = savedCursor != nil && !resync
        let cursor = savedCursor ?? profile.historyCursor
        if savedCursor == nil { try await store.setMeta("initial_cursor", cursor) }
        Self.log.info("Initial sync: \(savedCursor == nil ? "starting" : "resuming") at history \(cursor)\(resync ? " (full resync)" : "")")
        publish { $0.initialSyncProgress = 0 }

        var token: String?
        var fetched = 0
        // A small first page shows the newest mail quickly.
        var pageSize = 25
        repeat {
            let listed = Stopwatch()
            let page = try await provider.listThreadIDs(labelID: SystemLabel.inbox, pageToken: token, pageSize: pageSize)
            Self.log.info("Inbox page: \(page.ids.count) conversations listed in \(listed.text)\(page.nextPageToken == nil ? " (last page)" : "")")
            let base = fetched
            try await download(page.ids, skipExisting: skipExisting, intake: resync ? .resync : .none) { done in
                self.publish { $0.initialSyncProgress = base + done }
            }
            fetched += page.ids.count
            token = page.nextPageToken
            pageSize = 100
            let progress = fetched
            publish { $0.initialSyncProgress = progress }
        } while token != nil && fetched < initialSyncLimit

        try await store.setMeta("cursor", cursor)
        try await store.setMeta("initial_sync_done", "1")
        try await store.setMeta("initial_cursor", nil)
        Self.log.info("Initial sync done: \(fetched) inbox conversations in \(clock.text)")
    }

    /// Caches one page of older conversations (all mail, newest first). Returns true while more remain.
    private func backfill() async throws -> Bool {
        guard try await store.meta("backfill_done") == nil else { return false }
        let resync = try await store.meta("resync") != nil
        var count = Int(try await store.meta("backfill_count") ?? "") ?? 0
        var token = try await store.meta("backfill_token")
        let clock = Stopwatch()
        let page: ThreadIDPage
        do {
            page = try await provider.listThreadIDs(labelID: nil, pageToken: token, pageSize: 100)
        } catch let error as ProviderError where token != nil && !error.isTransient {
            // The saved page token expired. Start again from the newest; cached conversations are skipped.
            Self.log.notice("Background download: saved page token refused (\(error.localizedDescription)). Starting from the newest again")
            count = 0
            token = nil
            page = try await provider.listThreadIDs(labelID: nil, pageToken: nil, pageSize: 100)
        }
        let inserted = try await download(page.ids, skipExisting: !resync, intake: resync ? .resync : .none)
        count += page.ids.count
        Self.log.info("Background download: \(count) of \(initialSyncLimit) newest conversations checked, \(inserted.count) new messages stored, page took \(clock.text)")

        if let next = page.nextPageToken, count < initialSyncLimit {
            try await store.setMeta("backfill_token", next)
            try await store.setMeta("backfill_count", String(count))
            let progress = count
            publish { $0.backfillProgress = progress }
            return true
        }
        try await store.setMeta("backfill_done", "1")
        try await store.setMeta("backfill_token", nil)
        try await store.setMeta("backfill_count", nil)
        try await store.endResync()
        publish { $0.backfillProgress = nil }
        Self.log.info("Background download complete: the newest \(count) conversations are on this Mac")
        return false
    }

    /// Fetches and stores conversations, in small chunks: each chunk is saved as soon as it arrives,
    /// so a slow or dropped connection loses little. Local changes waiting in the outbox stay applied.
    /// Old mail reaches rules only during a resync (`intake`), for what arrived while history expired.
    @discardableResult
    private func download(_ ids: [String], skipExisting: Bool, intake: RuleIntake, progress: (Int) -> Void = { _ in }) async throws -> [String] {
        var wanted = ids
        if skipExisting {
            let existing = try await store.existingThreadIDs(ids)
            wanted = ids.filter { !existing.contains($0) }
        }
        var inserted: [String] = []
        let skipped = ids.count - wanted.count
        if skipped > 0 { Self.log.debug("Skipping \(skipped) of \(ids.count) conversations already on this Mac") }
        for start in stride(from: 0, to: wanted.count, by: 16) {
            let chunk = Array(wanted[start..<min(start + 16, wanted.count)])
            let fetchClock = Stopwatch()
            let threads = try await provider.threads(ids: chunk)
            let fetched = fetchClock.text
            let storeClock = Stopwatch()
            let messages = threads.flatMap { $0 }
            let stored = try await store.applyRemoteChanges(ChangeSet(cursor: "", upserted: messages), intake: intake)
            if intake == .resync && !stored.isEmpty { rules?.wake() }
            inserted += stored
            Self.log.debug("Stored \(threads.count) conversations (\(messages.count) messages): fetched in \(fetched), saved in \(storeClock.text)")
            progress(skipped + start + chunk.count)
        }
        return inserted
    }

    // MARK: - Pull

    private func pullChanges() async throws {
        guard let cursor = try await store.meta("cursor") else { return }
        var changes: ChangeSet
        do {
            changes = try await provider.changes(since: cursor)
        } catch ProviderError.cursorExpired {
            // Too long offline: download again, without trusting what is cached.
            Self.log.notice("History \(cursor) expired: downloading the inbox again")
            for key in ["initial_sync_done", "initial_cursor", "backfill_done", "backfill_token", "backfill_count"] {
                try await store.setMeta(key, nil)
            }
            try await store.setMeta("resync", "1")
            try await initialSync()
            return
        }
        if changes.labelsChanged {
            try await store.replaceProviderLabels(try await provider.labels())
        }
        let arrived = Set(changes.upserted.map(\.id))
        // A reply in a conversation that is not cached: fetch the whole conversation for context.
        // (A thread's ID is its first message's ID, so a message with another thread ID is a reply.)
        let replyThreads = Set(changes.upserted.filter { $0.threadID != $0.id }.map(\.threadID))
        if !replyThreads.isEmpty {
            let missing = replyThreads.subtracting(try await store.existingThreadIDs(Array(replyThreads)))
            if !missing.isEmpty {
                Self.log.info("Fetching \(missing.count) whole conversation(s) for replies to uncached mail")
                let complete = try await provider.threads(ids: Array(missing)).flatMap { $0 }
                let completeIDs = Set(complete.map(\.id))
                changes.upserted = changes.upserted.filter { !completeIDs.contains($0.id) } + complete
            }
        }
        // Messages, the new cursor and rules' queue rows are stored together. Conversations fetched
        // only as context for a reply did not arrive now, so they are not queued and do not wake rules.
        let inserted = try await store.applyRemoteChanges(changes, cursor: changes.cursor, intake: .live(arrived: arrived))

        guard !inserted.isEmpty else { return }
        if inserted.contains(where: arrived.contains) { rules?.wake() }
        let me = store.selfAddresses
        let insertedSet = Set(inserted)
        let incoming = changes.upserted
            .filter { arrived.contains($0.id) && insertedSet.contains($0.id) && $0.labelIDs.contains(SystemLabel.inbox) && !me.contains($0.from.normalized) }
            .map(\.id)
        if !incoming.isEmpty {
            Self.log.info("\(incoming.count) new message(s) in the inbox")
            eventContinuation.yield(.newMail(messageIDs: incoming))
        }
    }

    // MARK: - Push

    private func flushOutbox() async throws {
        while let item = try await store.claimNextOutboxItem() {
            let clock = Stopwatch()
            let name = "Outbox #\(item.id) \(item.operation.logDescription)\(item.attempts > 0 ? " (attempt \(item.attempts + 1))" : "")"
            do {
                try await execute(item.operation, isRetry: item.attempts > 0)
                try await store.completeOutboxItem(item.id)
                Self.log.info("\(name): done in \(clock.text)")
            } catch ProviderError.unauthorized {
                // Signed out: the change waits for sign-in instead of being dropped as refused.
                Self.log.notice("\(name): signed out after \(clock.text). Kept for after sign-in")
                try await store.retryOutboxItem(item.id, error: ProviderError.unauthorized.localizedDescription, retryAt: Date())
                throw ProviderError.unauthorized
            } catch let error as ProviderError where error.isTransient && Self.isListServerFailure(item.operation, error) {
                // Not Gmail: mail keeps syncing while the list's server gets more tries, then the unsubscribe is given up.
                if item.attempts + 1 >= Self.unsubscribeAttempts {
                    Self.log.error("\(name): \(error.localizedDescription) after \(clock.text). Giving up")
                    try await store.completeOutboxItem(item.id)
                    try await handleRejected(item, error: error)
                } else {
                    let backoff = min(pow(2, Double(item.attempts + 1)), 300)
                    Self.log.notice("\(name): \(error.localizedDescription) after \(clock.text). Retry in \(Int(backoff))s")
                    try await store.retryOutboxItem(item.id, error: error.localizedDescription, retryAt: Date().addingTimeInterval(backoff))
                }
            } catch let error as ProviderError where error.isTransient {
                let backoff = min(pow(2, Double(item.attempts + 1)), 300)
                Self.log.notice("\(name): \(error.localizedDescription) after \(clock.text). Retry in \(Int(backoff))s")
                try await store.retryOutboxItem(item.id, error: error.localizedDescription, retryAt: Date().addingTimeInterval(backoff))
                throw error
            } catch {
                // The provider refused it. Drop the operation and restore the provider's truth.
                Self.log.error("\(name): refused after \(clock.text): \((error as? LocalizedError)?.errorDescription ?? String(describing: error)). Undoing it locally")
                try await store.completeOutboxItem(item.id)
                try await handleRejected(item, error: error)
            }
        }
    }

    /// Attempts at a list's one-click address before the unsubscribe is given up (about 8 minutes).
    static let unsubscribeAttempts = 8

    /// Trouble at a list's one-click address. A Mac without a network (`.offline`) waits like everything else.
    static func isListServerFailure(_ operation: OutboxOperation, _ error: ProviderError) -> Bool {
        guard case .unsubscribe(let request) = operation, case .oneClick = request.method else { return false }
        if case .offline = error { return false }
        return true
    }

    private func execute(_ operation: OutboxOperation, isRetry: Bool) async throws {
        switch operation {
        case .modifyLabels(let delta):
            try await provider.modifyLabels(messageIDs: delta.messageIDs, add: delta.add, remove: delta.remove)
        case .deleteMessages(let ids):
            try await provider.deleteMessages(ids: ids)
        case .send(let draft, let message, let localMessageID, _):
            var fileData: [String: Data] = [:]
            for attachment in message.attachments {
                if case .file(let path) = attachment.source {
                    guard let data = FileManager.default.contents(atPath: path) else {
                        throw ProviderError.rejected("Attachment \(attachment.filename) is missing")
                    }
                    fileData[attachment.id] = data
                }
            }
            let sent = try await provider.send(message, fileData: fileData, isRetry: isRetry)
            try await store.replaceLocalMessage(localID: localMessageID, with: sent)
            if let draftFilesDirectory {
                try? FileManager.default.removeItem(at: draftFilesDirectory.appendingPathComponent(draft.id))
            }
            eventContinuation.yield(.sent(draftID: draft.id))
        case .createLabel(let localID, let name):
            let label = try await provider.createLabel(name: name)
            try await store.remapLabel(from: localID, to: label)
        case .renameLabel(let id, let name):
            _ = try await provider.renameLabel(id: id, to: name)
        case .deleteLabel(let id):
            try await provider.deleteLabel(id: id)
        case .unsubscribe(let request):
            switch request.method {
            case .oneClick(let url):
                try await provider.unsubscribe(oneClick: url)
            case .email(let message):
                let sent = try await provider.send(message, fileData: [:], isRetry: isRetry)
                // It went out, so nothing may throw from here. Stored now, the sync does not record the
                // list's address as a contact to suggest in compose.
                _ = try? await store.upsertMessages([sent], recordsContacts: false)
            }
            eventContinuation.yield(.unsubscribed(list: request.list))
        case .invitationReply(let reply):
            let sent = try await provider.send(reply.message, fileData: [:], isRetry: isRetry)
            // It went out, so nothing may throw from here: a refusal would take back an answer the organizer has.
            try? await store.replaceLocalMessage(localID: reply.localMessageID, with: sent)
        }
    }

    private func handleRejected(_ item: OutboxItem, error: Error) async throws {
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        switch item.operation {
        case .send(let draft, _, let localMessageID, _):
            try await store.restoreFailedSend(draft: draft, localMessageID: localMessageID)
            eventContinuation.yield(.sendFailed(draft: draft, reason: reason))
        case .modifyLabels(let delta):
            // Labels rules added stop being theirs and come off; the refetch then restores Gmail's truth.
            let ruleLabels = try await store.ruleOutboxRejected(item.id)
            try await refetch(messageIDs: delta.messageIDs)
            if ruleLabels > 0 {
                Self.log.notice("Outbox #\(item.id): Gmail refused \(ruleLabels) label(s) added by rules")
                eventContinuation.yield(.rulesGmailRejected(count: ruleLabels))
            } else {
                eventContinuation.yield(.operationFailed("Could not update mail: \(reason)"))
            }
        case .deleteMessages(let ids):
            try await refetch(messageIDs: ids)
            eventContinuation.yield(.operationFailed("Could not delete mail: \(reason)"))
        case .createLabel(let localID, let name):
            try await store.deleteLabel(id: localID)
            eventContinuation.yield(.operationFailed("Could not create label “\(name)”: \(reason)"))
        case .renameLabel, .deleteLabel:
            try await store.replaceProviderLabels(try await provider.labels())
            eventContinuation.yield(.operationFailed("Could not change label: \(reason)"))
        case .unsubscribe(let request):
            eventContinuation.yield(.unsubscribeFailed(outboxID: item.id, list: request.list, reason: reason))
        case .invitationReply(let reply):
            let outcome = try await store.restoreFailedInvitationReply(reply, outboxID: item.id)
            eventContinuation.yield(.answerFailed(outboxID: item.id, summary: reply.summary, reason: reason, outcome: outcome))
        }
    }

    /// Reloads the threads that contain these messages from the provider.
    private func refetch(messageIDs: [String]) async throws {
        var threadIDs: [String] = []
        for id in messageIDs {
            if let message = try await store.message(id: id), !threadIDs.contains(message.threadID) { threadIDs.append(message.threadID) }
        }
        try await refresh(threadIDs: threadIDs)
    }

    /// Downloads conversations again, for example to read headers an older vimail did not store.
    public func refresh(threadIDs: [String]) async throws {
        guard !threadIDs.isEmpty else { return }
        let threads = try await provider.threads(ids: threadIDs)
        _ = try await store.applyRemoteChanges(ChangeSet(cursor: "", upserted: threads.flatMap { $0 }))
    }

    // MARK: - Snoozes

    private func wakeDueSnoozes() async throws {
        let due = try await store.dueSnoozes()
        guard !due.isEmpty, let actions else { return }
        Self.log.info("Waking \(due.count) snoozed conversation(s)")
        try await actions.perform(.wakeFromSnooze, threads: due)
    }
}
