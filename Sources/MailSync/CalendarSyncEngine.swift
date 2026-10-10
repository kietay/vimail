import Foundation
import MailCore
import MailStore
import VimailLog

/// Keeps the local calendar and the provider in step, next to (and independent of) the mail `SyncEngine`.
///
/// Each cycle: push the calendar outbox, sync the calendar list, pull each shown calendar's changes
/// with its sync token (the first download goes one year back), and keep the expanded occurrences
/// current for the window from one year back to 400 days ahead. Series that Foundation cannot expand
/// get their occurrences from the provider. A calendar failure never touches the mail outbox.
public actor CalendarSyncEngine {
    static let log = Log("calendar-sync")

    public struct Status: Equatable, Sendable {
        public enum Phase: Equatable, Sendable { case idle, syncing, offline, rateLimited, failed, signedOut, notConnected }
        public var phase: Phase = .idle
        public var message: String?
        public var lastSuccess: Date?
        public var pendingOperations = 0
        public init() {}
    }

    public enum Event: Sendable {
        /// The provider refused a change. It was undone locally.
        case operationFailed(String)
    }

    public let provider: any CalendarProvider
    public let store: MailStore
    public nonisolated let statusUpdates: AsyncStream<Status>
    public nonisolated let events: AsyncStream<Event>
    private let statusContinuation: AsyncStream<Status>.Continuation
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var pollInterval: Duration
    private let calendar: Calendar
    private var status = Status()
    private var loop: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var wakeRequested = false
    private var sleepGeneration = 0
    private var failureStreak = 0
    private var running: Task<Bool, Never>?

    public init(provider: any CalendarProvider, store: MailStore, pollInterval: Duration = .seconds(60), calendar: Calendar = .current) {
        self.provider = provider
        self.store = store
        self.pollInterval = pollInterval
        self.calendar = calendar
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public var window: CalendarWindow { CalendarWindow.around(Date(), calendar: calendar) }

    public func start() {
        guard loop == nil else { return }
        Self.log.info("Calendar sync started (provider \(provider.kind), poll every \(pollInterval))")
        loop = Task { [weak self] in await self?.run() }
        let signals = provider.changeSignals()
        signalTask = Task { [weak self] in
            for await _ in signals { self?.wake() }
        }
    }

    public func stop() {
        Self.log.info("Calendar sync stopped")
        loop?.cancel()
        signalTask?.cancel()
        loop = nil
        signalTask = nil
        waiter?.resume()
        waiter = nil
        statusContinuation.finish()
        eventContinuation.finish()
    }

    /// Requests a cycle soon: after local changes, a new invitation, or the app coming to the front.
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
        try? await store.resetInflightCalendarOperations()
        while !Task.isCancelled {
            let succeeded = await cycle()
            failureStreak = succeeded ? 0 : failureStreak + 1
            var delay = succeeded ? pollInterval : min(.seconds(2 << min(failureStreak, 6)), .seconds(300))
            if let due = try? await store.nextCalendarOperationDueDate() {
                let seconds = max(0.05, due.timeIntervalSinceNow + 0.05)
                delay = min(delay, .milliseconds(Int(seconds * 1000)))
            }
            await sleep(for: delay)
        }
    }

    private func sleep(for delay: Duration) async {
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

    /// One sync cycle. Returns false on failure. Overlapping calls share one cycle.
    @discardableResult
    public func cycle() async -> Bool {
        if let running { return await running.value }
        let task = Task { await self.runCycle() }
        running = task
        let result = await task.value
        running = nil
        return result
    }

    private func runCycle() async -> Bool {
        let clock = Stopwatch()
        publish { $0.phase = .syncing; $0.message = nil }
        do {
            try await flushOutbox()
            try await syncCalendarList()
            let window = self.window
            for info in try await store.calendars() where info.isSelected {
                try await syncEvents(info.id, window: window)
            }
            try await keepWindowCurrent(window)
            try await expandPending(window)
            let pending = (try? await store.calendarOutboxCount()) ?? 0
            publish {
                $0.phase = .idle
                $0.lastSuccess = Date()
                $0.pendingOperations = pending
            }
            Self.log.debug("Calendar cycle finished in \(clock.text)")
            return true
        } catch {
            let pending = (try? await store.calendarOutboxCount()) ?? 0
            let phase: Status.Phase
            let message: String
            switch error {
            case ProviderError.unauthorized:
                phase = .signedOut
                message = "Signed out. Sign in again to sync the calendar."
            case CalendarProviderError.notConnected:
                phase = .notConnected
                message = "Google Calendar is not connected."
            case ProviderError.rateLimited:
                phase = .rateLimited
                message = "Google Calendar asked vimail to slow down."
            case let providerError as ProviderError where providerError.isTransient:
                phase = .offline
                message = providerError.localizedDescription
            default:
                phase = .failed
                message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            Self.log.notice("Calendar cycle stopped after \(clock.text): \(message)")
            publish {
                $0.phase = phase
                $0.message = message
                $0.pendingOperations = pending
            }
            return false
        }
    }

    // MARK: - Pull

    private func syncCalendarList() async throws {
        let saved = try await store.meta("calendar_list_token")
        do {
            try await pullCalendarList(syncToken: saved)
        } catch ProviderError.cursorExpired {
            Self.log.notice("Calendar list token expired: downloading the list again")
            try await pullCalendarList(syncToken: nil)
        }
    }

    private func pullCalendarList(syncToken: String?) async throws {
        var calendars: [CalendarInfo] = []
        var removed: [String] = []
        var pageToken: String?
        var nextSyncToken: String?
        repeat {
            let page = try await provider.calendars(syncToken: syncToken, pageToken: pageToken)
            calendars += page.calendars
            removed += page.removedIDs
            pageToken = page.nextPageToken
            nextSyncToken = page.nextSyncToken ?? nextSyncToken
        } while pageToken != nil
        if syncToken == nil || !calendars.isEmpty || !removed.isEmpty {
            // An incremental page lists only changed calendars: merge them into the stored list.
            var merged = calendars
            if syncToken != nil {
                let changed = Set(calendars.map(\.id))
                merged = try await store.calendars().filter { !changed.contains($0.id) && !removed.contains($0.id) } + calendars
            }
            try await store.applyCalendarList(merged, removed: removed, replaceAll: syncToken == nil)
            Self.log.info("Calendar list: \(merged.count) calendar(s), \(merged.filter(\.isSelected).count) shown")
        }
        try await store.setMeta("calendar_list_token", nextSyncToken)
    }

    /// Pulls one calendar's changes. Series whose occurrences must come from the provider wait in `expandPending`.
    private func syncEvents(_ calendarID: String, window: CalendarWindow) async throws {
        let saved = try await store.calendarSyncToken(calendarID)
        do {
            try await pullEvents(calendarID, syncToken: saved, window: window)
        } catch ProviderError.cursorExpired where saved != nil {
            Self.log.notice("Calendar sync token expired: downloading the calendar again")
            try await store.clearCalendarEvents(calendarID)
            try await pullEvents(calendarID, syncToken: nil, window: window)
        }
    }

    private func pullEvents(_ calendarID: String, syncToken: String?, window: CalendarWindow) async throws {
        let clock = Stopwatch()
        var pageToken: String?
        var nextSyncToken: String?
        var needsProvider = Set<String>()
        var count = 0
        repeat {
            let page = try await provider.events(calendarID: calendarID, syncToken: syncToken, pageToken: pageToken, timeMin: syncToken == nil ? window.from : nil)
            count += page.events.count
            needsProvider.formUnion(try await store.applyEvents(page.events, calendarID: calendarID, window: window, calendar: calendar))
            pageToken = page.nextPageToken
            nextSyncToken = page.nextSyncToken ?? nextSyncToken
        } while pageToken != nil
        // Saved before the token, so a failed expansion is tried again even though these events will not come back.
        try await addPendingExpansions(needsProvider.sorted().map { (calendarID, $0) })
        if let nextSyncToken { try await store.setCalendarSyncToken(calendarID, nextSyncToken) }
        if syncToken == nil || count > 0 {
            Self.log.info("\(syncToken == nil ? "Downloaded" : "Updated") \(count) event(s) of a calendar in \(clock.text)")
        }
    }

    /// Expands everything again when the window moved to a new day or the time zone changed.
    private func keepWindowCurrent(_ window: CalendarWindow) async throws {
        let key = window.key(in: calendar)
        guard try await store.meta("calendar_window") != key else { return }
        let series = try await store.rematerializeOccurrences(window: window, calendar: calendar)
        try await addPendingExpansions(series)
        try await store.setMeta("calendar_window", key)
        Self.log.info("Calendar window now \(key)")
    }

    // MARK: - Expansion by the provider

    private static let expansionsKey = "calendar_expansions"

    /// Series waiting for the provider's expansion. They stay in the store until it arrives, so a failed request is
    /// tried again on a later cycle, after a relaunch too.
    private func pendingExpansions() async throws -> [(calendarID: String, seriesID: String)] {
        guard let text = try await store.meta(Self.expansionsKey),
              let pairs = try? JSONDecoder().decode([[String]].self, from: Data(text.utf8)) else { return [] }
        return pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    private func savePendingExpansions(_ series: [(calendarID: String, seriesID: String)]) async throws {
        var seen = Set<[String]>()
        let pairs = series.map { [$0.calendarID, $0.seriesID] }.filter { seen.insert($0).inserted }
        try await store.setMeta(Self.expansionsKey, pairs.isEmpty ? nil : String(decoding: try JSONEncoder().encode(pairs), as: UTF8.self))
    }

    private func addPendingExpansions(_ series: [(calendarID: String, seriesID: String)]) async throws {
        guard !series.isEmpty else { return }
        try await savePendingExpansions(try await pendingExpansions() + series)
    }

    /// Asks the provider for the occurrences of every waiting series. One that fails for a reason that may pass
    /// (offline, signed out) stays waiting and the cycle reports the failure; one the provider refuses is dropped.
    private func expandPending(_ window: CalendarWindow) async throws {
        var remaining = try await pendingExpansions()
        guard !remaining.isEmpty else { return }
        let shown = Set(try await store.calendars().filter(\.isSelected).map(\.id))
        var failure: Error?
        for item in remaining {
            if shown.contains(item.calendarID) {
                do {
                    let instances = try await provider.instances(calendarID: item.calendarID, eventID: item.seriesID, from: window.from, to: window.to)
                    try await store.applyInstances(instances, calendarID: item.calendarID, seriesID: item.seriesID, calendar: calendar)
                } catch let error where Self.mayPass(error) {
                    failure = failure ?? error
                    continue
                } catch {
                    Self.log.notice("Could not expand a series on the provider: \(String(describing: error)). Not trying again")
                }
            }
            remaining.removeAll { $0 == item }
            try await savePendingExpansions(remaining)
        }
        if let failure { throw failure }
    }

    /// An error that may pass on its own: worth trying again later.
    static func mayPass(_ error: Error) -> Bool {
        if let error = error as? ProviderError {
            if case .unauthorized = error { return true }
            return error.isTransient
        }
        if let error = error as? CalendarProviderError, case .notConnected = error { return true }
        return false
    }

    // MARK: - Invitations Google keeps hidden

    /// The stored events for an invitation, looked up on the provider when none is stored: Google hides invitations
    /// from unknown senders until they are answered, so the sync never lists them. What it finds is stored.
    /// Throws when the provider cannot be reached, so a failed lookup is not taken for "not there".
    public func fetchEvents(uid: String) async throws -> [CalendarEvent] {
        guard let primary = try await store.calendars().first(where: \.isPrimary) else { throw CalendarProviderError.notConnected }
        let stored = try await store.events(uid: uid)
        guard !stored.contains(where: { $0.calendarID == primary.id }) else { return stored }
        let found = try await provider.events(calendarID: primary.id, iCalUID: uid)
        guard !found.isEmpty else { return [] }
        try await store.applyEvents(found, calendarID: primary.id, window: window, calendar: calendar)
        Self.log.info("Found \(found.count) hidden event(s) for an invitation")
        return try await store.events(uid: uid)
    }

    // MARK: - Push

    private func flushOutbox() async throws {
        while let item = try await store.claimNextCalendarOperation() {
            let clock = Stopwatch()
            let name = "Calendar outbox #\(item.id) \(item.operation.logDescription)\(item.attempts > 0 ? " (attempt \(item.attempts + 1))" : "")"
            do {
                let result = try await execute(item.operation)
                try await store.completeCalendarOperation(item.id)
                if let result { try await store.storeProviderEvent(result, window: window, calendar: calendar) }
                Self.log.info("\(name): done in \(clock.text)")
            } catch let error as ProviderError where error.isTransient {
                let backoff = min(pow(2, Double(item.attempts + 1)), 300)
                Self.log.notice("\(name): \(error.localizedDescription) after \(clock.text). Retry in \(Int(backoff))s")
                try await store.retryCalendarOperation(item.id, error: error.localizedDescription, retryAt: Date().addingTimeInterval(backoff))
                throw error
            } catch ProviderError.unauthorized {
                try await store.retryCalendarOperation(item.id, error: "signed out", retryAt: Date().addingTimeInterval(60))
                throw ProviderError.unauthorized
            } catch CalendarProviderError.notConnected {
                try await store.retryCalendarOperation(item.id, error: "not connected", retryAt: Date().addingTimeInterval(300))
                throw CalendarProviderError.notConnected
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                Self.log.error("\(name): refused after \(clock.text): \(reason). Undoing it locally")
                try await store.completeCalendarOperation(item.id)
                try await handleRefused(item.operation, reason: reason)
            }
        }
    }

    /// Sends one operation. Returns the provider's version of the event, when there is one.
    private func execute(_ operation: CalendarOperation) async throws -> CalendarEvent? {
        switch operation {
        case .respond(let calendarID, let eventID, let response, let comment, _, let updates):
            return try await provider.respond(calendarID: calendarID, eventID: eventID, response: response, comment: comment, sendUpdates: updates)
        case .insert(let event, let updates, let conference):
            do {
                return try await provider.insert(event, sendUpdates: updates, addConference: conference)
            } catch CalendarProviderError.duplicate {
                // An earlier attempt arrived, or the event was removed and is coming back (undo): it keeps its ID.
                guard var existing = try await provider.event(calendarID: event.calendarID, eventID: event.id) else {
                    var restored = event
                    restored.status = .confirmed
                    return try await provider.update(restored, previous: nil, etag: nil, sendUpdates: updates)
                }
                if existing.status == .cancelled {
                    existing = event
                    existing.status = .confirmed
                    return try await provider.update(existing, previous: nil, etag: nil, sendUpdates: updates)
                }
                Self.log.notice("Create retry: the event exists already. Not creating it again")
                return existing
            }
        case .update(let event, let previous, let updates):
            do {
                return try await provider.update(event, previous: previous, etag: previous.etag, sendUpdates: updates)
            } catch CalendarProviderError.changedElsewhere {
                // Re-apply the edit when Google changed the event in ways the edit did not touch.
                guard let current = try await provider.event(calendarID: event.calendarID, eventID: event.id) else { throw ProviderError.notFound("event") }
                guard let merged = Self.merge(edit: event, base: previous, current: current) else { throw CalendarProviderError.changedElsewhere }
                return try await provider.update(merged, previous: current, etag: current.etag, sendUpdates: updates)
            }
        case .delete(let event, let updates):
            try await provider.delete(calendarID: event.calendarID, eventID: event.id, sendUpdates: updates)
            return nil
        }
    }

    /// Restores the provider's version after a refused change.
    private func handleRefused(_ operation: CalendarOperation, reason: String) async throws {
        let target = operation.target
        let current = try? await provider.event(calendarID: target.calendarID, eventID: target.eventID)
        switch operation {
        case .respond:
            if let current {
                // A series' changed occurrences took the refused answer too: the provider's copies of them all come back.
                if current.isSeries, let uid = current.iCalUID,
                   let copies = try? await provider.events(calendarID: target.calendarID, iCalUID: uid), !copies.isEmpty {
                    try await store.replaceEvents(copies, calendarID: target.calendarID, eventID: current.id, window: window, calendar: calendar)
                } else {
                    try await store.storeProviderEvent(current, window: window, calendar: calendar)
                }
            }
            eventContinuation.yield(.operationFailed("Could not answer the invitation: \(reason)"))
        case .insert(let event, _, _):
            // Changes queued behind the create cannot succeed: they go, so nothing keeps the event on the Mac.
            try await store.dropCalendarOperations(queueKey: operation.queueKey)
            try await store.applyEvents([Self.cancelled(event)], calendarID: event.calendarID, window: window, calendar: calendar)
            eventContinuation.yield(.operationFailed("Could not create “\(event.summary)”: \(reason)"))
        case .update(let event, _, _):
            if let current { try await store.storeProviderEvent(current, window: window, calendar: calendar) }
            eventContinuation.yield(.operationFailed(reason == CalendarProviderError.changedElsewhere.errorDescription
                ? "“\(event.summary)” changed in Google Calendar, so your edit was not applied."
                : "Could not change “\(event.summary)”: \(reason)"))
        case .delete(let event, _):
            // A removed series took its changed occurrences with it: the provider's copies of them all come back.
            if event.isSeries, let uid = event.iCalUID ?? current?.iCalUID,
               let copies = try? await provider.events(calendarID: target.calendarID, iCalUID: uid), !copies.isEmpty {
                try await store.replaceEvents(copies, calendarID: target.calendarID, eventID: event.id, window: window, calendar: calendar)
            } else if let current {
                try await store.storeProviderEvent(current, window: window, calendar: calendar)
            }
            eventContinuation.yield(.operationFailed("Could not remove “\(event.summary)”: \(reason)"))
        }
    }

    static func cancelled(_ event: CalendarEvent) -> CalendarEvent {
        var copy = event
        copy.status = .cancelled
        return copy
    }

    /// Your edit on top of the provider's newer version, when the two changed different fields. Nil on a real conflict.
    static func merge(edit: CalendarEvent, base: CalendarEvent, current: CalendarEvent) -> CalendarEvent? {
        var merged = current
        func apply<Value: Equatable>(_ path: WritableKeyPath<CalendarEvent, Value>) -> Bool {
            let mine = edit[keyPath: path] != base[keyPath: path]
            let theirs = current[keyPath: path] != base[keyPath: path]
            if mine && theirs && edit[keyPath: path] != current[keyPath: path] { return false }
            if mine { merged[keyPath: path] = edit[keyPath: path] }
            return true
        }
        guard apply(\.summary), apply(\.details), apply(\.location), apply(\.start), apply(\.end), apply(\.recurrence),
              apply(\.isBusy), apply(\.conferenceURL) else { return nil }
        if edit.attendees != base.attendees {
            merged.attendees = mergeGuests(edit: edit.attendees, base: base.attendees, current: current.attendees)
        }
        return merged
    }

    /// Your guest changes (added, removed, made optional or required) applied to the provider's newer list, which
    /// keeps everyone's answers and notes and any guest added elsewhere.
    static func mergeGuests(edit: [Attendee], base: [Attendee], current: [Attendee]) -> [Attendee] {
        let before = Dictionary(base.map { ($0.normalized, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(edit.map { ($0.normalized, $0) }, uniquingKeysWith: { first, _ in first })
        var guests = current.filter { before[$0.normalized] == nil || after[$0.normalized] != nil }
        for index in guests.indices {
            let key = guests[index].normalized
            if let mine = after[key], let old = before[key], mine.isOptional != old.isOptional { guests[index].isOptional = mine.isOptional }
        }
        for guest in edit where before[guest.normalized] == nil && !guests.contains(where: { $0.normalized == guest.normalized }) {
            guests.append(guest)
        }
        return guests
    }
}
