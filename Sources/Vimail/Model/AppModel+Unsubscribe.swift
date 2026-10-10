import AppKit
import MailCore
import MailStore
import MailSync

extension AppModel {
    /// Web pages one ⌘U opens at most. More conversations stay selected for the next ⌘U.
    static let unsubscribePageLimit = 5
    /// Conversations cached before vimail checked for one-click that one ⌘U downloads again at most.
    static let unsubscribeCheckLimit = 10

    /// ⌘U: leaves the mailing list of each selected conversation, the fastest way its sender offers,
    /// and archives it. One-click (RFC 8058) and email unsubscribes leave after the undo window, like a
    /// send, so `u` takes back an accidental ⌘U. A list that only offers a web page opens it in the browser.
    func unsubscribe() {
        // The menu bar's ⌘U also arrives while compose or an overlay has the keyboard.
        guard compose == nil, overlay == nil else { return }
        let all = actionTargets.filter { !$0.hasPrefix("draft:") }
        guard !all.isEmpty else {
            showToast("Select a conversation first.")
            return
        }
        // A quick second ⌘U arrives before the first has archived anything.
        let targets = all.filter { !unsubscribing.contains($0) }
        guard !targets.isEmpty else { return }
        unsubscribing.formUnion(targets)
        let selected = selection
        Task {
            await unsubscribe(from: targets, selected: selected)
            unsubscribing.subtract(targets)
        }
    }

    private func unsubscribe(from targets: [String], selected: Set<String>) async {
        let me = services.store.selfAddresses
        var threads = await storedThreads(targets)
        // Mail cached before vimail checked for one-click: download it again while Gmail is reachable.
        let unchecked = threads.filter { $0.unsubscribeTarget(excluding: me)?.message.needsOneClickCheck == true }.map(\.id)
        var deferred = Set<String>()
        if !unchecked.isEmpty, [.idle, .syncing].contains(syncStatus.phase) {
            let batch = Array(unchecked.prefix(Self.unsubscribeCheckLimit))
            deferred = Set(unchecked.dropFirst(Self.unsubscribeCheckLimit))
            let check = UnsubscribeCheck()
            unsubscribeChecks.append(check)
            showToast("Checking how to unsubscribe…", undoable: true)
            do {
                try await services.engine.refresh(threadIDs: batch)
                let fresh = await storedThreads(batch)
                threads = threads.map { thread in fresh.first { $0.id == thread.id } ?? thread }
            } catch {
                AppModel.log.notice("Unsubscribe: could not download \(batch.count) conversation(s) again: \(error.localizedDescription)")
            }
            unsubscribeChecks.removeAll { $0 === check }
            // u while checking: nothing has happened yet.
            guard !check.cancelled else { return }
        }

        let from = account.email.isEmpty ? EmailAddress(name: "Me", email: "me@localhost") : account
        var requests: [UnsubscribeRequest] = []
        var pages: [(url: URL, list: String)] = []
        var seen = Set<UnsubscribeMethod>()
        var done: [String] = []
        var later: [String] = []
        var noLink = 0
        var inSpam = 0
        for thread in threads {
            // Unsubscribing from spam only tells the sender the address works.
            if thread.labelIDs.contains(SystemLabel.spam) {
                inSpam += 1
                continue
            }
            guard let target = thread.unsubscribeTarget(excluding: me) else {
                noLink += 1
                continue
            }
            if deferred.contains(thread.id) {
                later.append(thread.id)
                continue
            }
            let list = target.message.from.displayName
            if case .website(let url) = target.method {
                if !seen.contains(target.method) {
                    guard pages.count < Self.unsubscribePageLimit else {
                        later.append(thread.id)
                        continue
                    }
                    seen.insert(target.method)
                    pages.append((url, list))
                }
            } else if seen.insert(target.method).inserted, let request = UnsubscribeRequest(target.method, list: list, from: from) {
                requests.append(request)
            }
            done.append(thread.id)
        }

        var notes: [String] = []
        if !later.isEmpty { notes.append("Press ⌘U again for \(later.count) more.") }
        if noLink > 0 { notes.append(noLink == 1 ? "1 has no unsubscribe link." : "\(noLink) have no unsubscribe link.") }
        if inSpam > 0 { notes.append("Skipped \(inSpam) in Spam.") }
        var detail: String? { notes.isEmpty ? nil : notes.joined(separator: " ") }

        guard !done.isEmpty else {
            if threads.count > 1 {
                showToast("Nothing to unsubscribe from.", detail: detail)
            } else if inSpam > 0 {
                showToast("This is in Spam. Unsubscribing would only tell the sender your address works.")
            } else {
                showToast("No unsubscribe link in this conversation. Press ! to report it as spam.")
            }
            return
        }

        // Instant, like archive: the list and the browser first, the store a moment later.
        applyOptimistically(.archive, to: done)
        // What another ⌘U can still do stays selected, unless the selection changed meanwhile.
        if selection == selected {
            if later.isEmpty {
                clearSelection()
            } else {
                visualAnchorID = nil
                selection = Set(later)
            }
        }
        for page in pages { openUnsubscribePage(page.url) }

        let delay = max(0, settings.undoSendSeconds)
        let sendAt = Date().addingTimeInterval(delay)
        let archived: UndoRecord?
        let outboxIDs: [Int64]
        do {
            archived = try await services.actions.perform(.archive, threads: done)
        } catch {
            AppModel.log.error("Unsubscribe: could not archive: \(error)")
            showToast("Could not unsubscribe: \(error.localizedDescription)", isError: true)
            await reloadList()
            return
        }
        do {
            // One transaction: all of them leave, or none.
            outboxIDs = try await services.store.enqueue(requests.map(OutboxOperation.unsubscribe), notBefore: sendAt)
        } catch {
            AppModel.log.error("Unsubscribe: could not queue: \(error)")
            if let archived { try? await services.actions.undo(archived) }
            showToast("Could not unsubscribe: \(error.localizedDescription)", isError: true)
            await reloadList()
            return
        }
        services.engine.wake()
        let emails = requests.filter { if case .email = $0.method { true } else { false } }.count
        AppModel.log.info("Unsubscribe: \(requests.count - emails) one-click and \(emails) email unsubscribe(s) leave in \(Int(delay))s, \(pages.count) page(s) opened, \(later.count) for the next ⌘U")

        if !outboxIDs.isEmpty {
            undoStack.append(.unsubscribe(outboxIDs: outboxIDs, lists: requests.map(\.list), archive: archived))
        } else if let archived {
            undoStack.append(.action(archived, nil))
        }
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()

        if requests.isEmpty {
            let text = pages.count == 1 ? "Finish unsubscribing from \(pages[0].list) in your browser." : "Finish unsubscribing from \(pages.count) lists in your browser."
            showToast(text, undoable: archived != nil, detail: detail)
        } else {
            if !pages.isEmpty { notes.insert(pages.count == 1 ? "Opened 1 unsubscribe page." : "Opened \(pages.count) unsubscribe pages.", at: 0) }
            let text = requests.count == 1 ? "Unsubscribing from \(requests[0].list)" : "Unsubscribing from \(requests.count) lists"
            showToast(delay > 0 ? text : "\(text)…", undoable: true, countdownTo: delay > 0 ? sendAt : nil, detail: detail)
        }
    }

    /// In the default browser. A debug script (`VIMAIL_SCRIPT`) only logs it, so test runs open nothing.
    private func openUnsubscribePage(_ url: URL) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["VIMAIL_SCRIPT"] != nil {
            AppModel.log.info("Debug script: not opening the unsubscribe page at \(url.host ?? "?")")
            return
        }
        #endif
        NSWorkspace.shared.open(url)
    }

    /// Fresh from the store: the reader's copy can be a moment old.
    private func storedThreads(_ ids: [String]) async -> [MailThread] {
        var threads: [MailThread] = []
        for id in ids {
            if let thread = try? await services.store.thread(id: id) { threads.append(thread) }
        }
        return threads
    }
}
