import Foundation
import MailCore
import MailStore
import VimailLog

/// Reads the invitation files (`text/calendar` parts) of mail in the background, so an invitation's
/// event page is ready before you open it. New mail is read as it arrives; mail already cached is
/// read once, newest first. Each file costs one attachment download from the mail provider.
public actor InvitationIndexer {
    static let log = Log("invitations")

    private let store: MailStore
    private let provider: any MailProvider
    private let found: @Sendable () -> Void
    private var observer: UUID?
    private var running = false
    private var again = false
    private var pausedUntil: Date?

    /// - Parameter found: called after new invitations were stored (wakes calendar sync).
    public init(store: MailStore, provider: any MailProvider, found: @escaping @Sendable () -> Void = {}) {
        self.store = store
        self.provider = provider
        self.found = found
    }

    public func start() {
        guard observer == nil else { return }
        observer = store.observe { [weak self] change in
            guard !change.threadIDs.isEmpty || change.reset else { return }
            Task { await self?.schedule() }
        }
        schedule()
    }

    public func stop() {
        if let observer { store.removeObserver(observer) }
        observer = nil
    }

    func schedule() {
        if running {
            again = true
            return
        }
        running = true
        Task { await self.drain() }
    }

    /// Reads waiting files until none are left (or the provider is unreachable).
    public func drain() async {
        defer { running = false }
        var seen = Set<String>()
        repeat {
            again = false
            if let pausedUntil, pausedUntil > Date() { return }
            // A message that could not even be marked as read once is not tried again in this pass.
            guard let candidates = try? await store.invitationCandidates(limit: 20).filter({ seen.insert($0.messageID).inserted }), !candidates.isEmpty else { continue }
            var stored = 0
            for candidate in candidates {
                do {
                    let data = try await provider.attachmentData(messageID: candidate.messageID, attachmentID: candidate.attachmentID)
                    let invitations = ICalendar.invitations(from: data)
                    try await store.saveInvitations(invitations, messageID: candidate.messageID, threadID: candidate.threadID)
                    if !invitations.isEmpty { stored += 1 }
                } catch let error as ProviderError where error.isTransient || error == .unauthorized {
                    Self.log.notice("Stopped reading invitation files: \(error.localizedDescription). Trying again later")
                    pausedUntil = Date().addingTimeInterval(60)
                    Task {
                        try? await Task.sleep(for: .seconds(61))
                        self.schedule()
                    }
                    if stored > 0 { found() }
                    return
                } catch {
                    let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    try? await store.saveInvitations([], messageID: candidate.messageID, threadID: candidate.threadID, error: reason)
                }
            }
            Self.log.info("Read \(candidates.count) invitation file(s): \(stored) with events")
            if stored > 0 { found() }
            again = true
        } while again
    }
}
