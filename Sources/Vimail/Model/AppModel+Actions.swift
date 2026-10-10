import AppKit
import MailCore
import MailRules
import MailStore
import MailSync
import UniformTypeIdentifiers
import VimailKit

extension AppModel {
    // MARK: - Conversation actions

    /// Runs an action on conversations: updates the list instantly, writes the local store,
    /// queues the provider change, and records undo. A label edit is reported to the rules, which stop
    /// re-adding a label you removed; with `teaching`, the rule also gets an example under the same undo.
    func perform(
        _ action: ThreadAction, on ids: [String]? = nil, labelName: String? = nil, recordUndo: Bool = true, silent: Bool = false,
        teaching: RuleTeaching? = nil
    ) {
        var targets = ids ?? actionTargets
        let draftRows = targets.filter { $0.hasPrefix("draft:") }
        targets.removeAll { $0.hasPrefix("draft:") }
        if !draftRows.isEmpty, case .trash = action {
            discardDrafts(draftRows.map { String($0.dropFirst(6)) })
        }
        guard !targets.isEmpty else {
            if draftRows.isEmpty && !silent { showToast("Nothing selected.") }
            return
        }

        if case .markRead = action, currentQuery.read == .unread { stickyIDs.formUnion(targets) }
        if case .markUnread = action, currentQuery.read == .read { stickyIDs.formUnion(targets) }
        applyOptimistically(action, to: targets)
        if !silent {
            clearSelection()
            if action.isRepeatable { lastAction = (action, labelName) }
        }
        let services = services
        Task {
            do {
                guard let record = try await services.actions.perform(action, threads: targets, labelName: labelName) else {
                    if case .deleteForever = action, !silent { showToast(action.summary(count: targets.count)) }
                    if let teaching { await teachUnchanged(action, teaching, labelName: labelName, in: services) }
                    return
                }
                let edit = Self.labelEdit(record)
                if recordUndo { pushUndo(.action(record, edit)) }
                var summary = record.summary
                if let edit {
                    let note = await noteLabelEdit(.applied(edit), teaching: teaching, in: services)
                    let name = labelName ?? labels.first { $0.id == edit.labelID }?.name ?? "label"
                    if let text = note?.removalToast(labelName: name) { summary = text }
                }
                if !silent { showToast(summary, undoable: recordUndo) }
            } catch {
                showToast("Could not update mail: \(error.localizedDescription)", isError: true)
                await reloadList()
            }
        }
    }

    /// Records a step `u` can undo. A new step ends what redo could bring back.
    func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Tells the rules about a label edit or its undo, and teaches the rule an example when asked to.
    /// Reports go out one at a time in the order of your edits, so undoing an edit never overtakes the
    /// edit's own report. Failures are logged: the edit itself stands.
    @discardableResult
    func noteLabelEdit(_ change: UserLabelChange, teaching: RuleTeaching? = nil, in services: AppServices) async -> LabelEditNote? {
        let previous = ruleReport
        let report = Task { () -> LabelEditNote? in
            _ = await previous?.value
            do {
                var note = try await services.rules.noteUserChange(change)
                if let teaching, case .applied(let edit) = change,
                   let name = try await services.rules.teach(ruleID: teaching.ruleID, messageID: teaching.messageID, matches: teaching.matches, undoKey: edit.undoKey),
                   !note.taughtRules.contains(name) {
                    // It learns from this even when its edits don't teach.
                    note.taughtRules.append(name)
                }
                return note
            } catch {
                AppModel.log.error("Could not tell rules about a label edit: \(String(describing: type(of: error)))")
                return nil
            }
        }
        ruleReport = report
        return await report.value
    }

    /// `x` or `a` in "why these labels?" when the label was already like that: the rule still gets
    /// its example, and `u` takes it back.
    private func teachUnchanged(_ action: ThreadAction, _ teaching: RuleTeaching, labelName: String?, in services: AppServices) async {
        let labelID: String
        switch action {
        case .addLabel(let id), .removeLabel(let id): labelID = id
        default: return
        }
        let edit = LabelEdit(undoKey: UUID().uuidString, labelID: labelID, added: teaching.matches, messageIDs: [])
        pushUndo(.teaching(edit))
        let note = await noteLabelEdit(.applied(edit), teaching: teaching, in: services)
        let name = labelName ?? labels.first { $0.id == labelID }?.name ?? "label"
        showToast(note?.unchangedToast(labelName: name, added: teaching.matches) ?? "Nothing changed: the label was already like that.", undoable: true)
    }

    /// The label a label action added or removed, with the messages that really changed, or nil for
    /// other actions. Moving to a label adds it.
    static func labelEdit(_ record: UndoRecord) -> LabelEdit? {
        let labelID: String
        let added: Bool
        switch record.action {
        case .addLabel(let id), .moveToLabel(let id): (labelID, added) = (id, true)
        case .removeLabel(let id): (labelID, added) = (id, false)
        default: return nil
        }
        let messageIDs = record.messageIDs(changing: labelID, added: added)
        guard !messageIDs.isEmpty else { return nil }
        return LabelEdit(undoKey: UUID().uuidString, labelID: labelID, added: added, messageIDs: messageIDs)
    }

    /// Updates the in-memory list immediately; the store reload a few milliseconds later reconciles.
    func applyOptimistically(_ action: ThreadAction, to ids: [String]) {
        let idSet = Set(ids)
        if removesFromCurrentList(action) {
            let firstIndex = threads.firstIndex { idSet.contains($0.id) }
            threads.removeAll { idSet.contains($0.id) }
            totalCount = max(0, totalCount - ids.count)
            if let cursorID, idSet.contains(cursorID) {
                if threads.isEmpty {
                    self.cursorID = nil
                } else {
                    self.cursorID = threads[min(firstIndex ?? 0, threads.count - 1)].id
                }
            }
            return
        }
        for index in threads.indices where idSet.contains(threads[index].id) {
            switch action {
            case .markRead: threads[index].isUnread = false
            case .markUnread, .wakeFromSnooze: threads[index].isUnread = true
            case .star: threads[index].isStarred = true
            case .unstar: threads[index].isStarred = false
            case .addLabel(let id): if !threads[index].labelIDs.contains(id) { threads[index].labelIDs.append(id) }
            case .removeLabel(let id): threads[index].labelIDs.removeAll { $0 == id }
            default: break
            }
        }
    }

    private func removesFromCurrentList(_ action: ThreadAction) -> Bool {
        let scope = currentQuery.scope
        let inInbox = scope == .mailbox(.inbox)
        switch action {
        case .archive, .moveToLabel: return inInbox
        case .snooze: return inInbox || scope == .mailbox(.archive)
        case .trash: return scope != .mailbox(.trash) && scope != .anywhere
        case .spam: return scope != .mailbox(.spam) && scope != .anywhere
        case .deleteForever: return true
        case .moveToInbox, .notSpam: return [.mailbox(.trash), .mailbox(.spam), .mailbox(.archive), .mailbox(.snoozed)].contains(scope)
        case .unsnooze: return scope == .mailbox(.snoozed)
        case .unstar: return currentQuery.starredOnly || scope == .mailbox(.starred)
        case .removeLabel(let id): return scope == .mailbox(.label(id)) || currentQuery.labelIDs.contains(id)
        default: return false
        }
    }

    // MARK: - Keyboard-level actions

    func archive() {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        let inInbox = targets.allSatisfy { id in threads.first { $0.id == id }?.labelIDs.contains(SystemLabel.inbox) ?? true }
        if inInbox || currentMailbox == .inbox {
            perform(.archive)
        } else if currentMailbox == .snoozed {
            perform(.unsnooze)
        } else {
            showToast("Already archived. Press m to move it back to the Inbox.")
        }
    }

    func trash() {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        if currentMailbox == .trash {
            guard services.provider.supportsPermanentDelete else {
                showToast("Gmail deletes mail in Trash after 30 days. vimail cannot delete it sooner.")
                return
            }
            let realTargets = targets.filter { !$0.hasPrefix("draft:") }
            overlay = .confirm(Confirmation(
                title: "Delete forever?",
                message: realTargets.count == 1 ? "This conversation will be deleted permanently. This cannot be undone." : "\(realTargets.count) conversations will be deleted permanently. This cannot be undone.",
                confirmTitle: "Delete forever",
                action: .deleteForever(realTargets)
            ))
        } else {
            perform(.trash)
        }
    }

    func spam() {
        perform(currentMailbox == .spam ? .notSpam : .spam)
    }

    func toggleStar() {
        let targets = actionTargets
        let allStarred = targets.allSatisfy { id in threads.first { $0.id == id }?.isStarred ?? false }
        perform(allStarred ? .unstar : .star)
    }

    func toggleRead() {
        let anyUnread = actionTargets.contains { id in threads.first { $0.id == id }?.isUnread ?? false }
        perform(anyUnread ? .markRead : .markUnread)
    }

    func undo() {
        // ⌘U is still checking how to unsubscribe: stop it before it has done anything.
        if let check = unsubscribeChecks.popLast() {
            check.cancelled = true
            showToast("Unsubscribe cancelled.")
            return
        }
        guard let entry = undoStack.popLast() else {
            showToast("Nothing to undo.")
            return
        }
        switch entry {
        case .action(let record, let edit):
            let services = services
            Task {
                do {
                    try await services.actions.undo(record)
                    if let edit { await noteLabelEdit(.undone(edit), in: services) }
                    redoStack.append(record)
                    showToast("Undone: \(record.summary)")
                    if let first = record.threadIDs.first {
                        await reloadList()
                        if threads.contains(where: { $0.id == first }) { cursorID = first }
                    }
                } catch {
                    AppModel.log.error("Undo failed: \(error)")
                    showToast("Could not undo: \(error.localizedDescription)", isError: true)
                }
            }
        case .send(let outboxID, let draft, let localMessageID, let archived):
            Task {
                if let archived {
                    do {
                        try await services.actions.undo(archived)
                        await reloadList()
                    } catch {
                        AppModel.log.error("Could not undo archive on send: \(error)")
                    }
                }
                if (try? await services.store.cancelSend(outboxID: outboxID, draft: draft, localMessageID: localMessageID)) == true {
                    AppModel.log.info("Undo send: outbox #\(outboxID) cancelled before it left")
                    showToast("Sending cancelled. The draft is open again.")
                    openCompose(draft)
                } else {
                    AppModel.log.info("Undo send: outbox #\(outboxID) had already left")
                    showToast("Too late: the message was already sent.")
                }
            }
        case .ruleRun(let runID):
            undoRuleRun(runID)
        case .teaching(let edit):
            let services = services
            Task {
                await noteLabelEdit(.undone(edit), in: services)
                showToast("Undone: the rule forgot that example.")
            }
        case .unsubscribe(let outboxIDs, let lists, let archive):
            Task {
                let cancelled = (try? await services.store.cancelOutboxItems(outboxIDs)) ?? []
                AppModel.log.info("Undo unsubscribe: \(cancelled.count) of \(outboxIDs.count) cancelled before they left")
                if let archive {
                    try? await services.actions.undo(archive)
                    await reloadList()
                    if let first = archive.threadIDs.first, threads.contains(where: { $0.id == first }) { cursorID = first }
                }
                let one = lists.count == 1 ? lists[0] : nil
                if cancelled.count == outboxIDs.count {
                    showToast(one.map { "Still subscribed to \($0)." } ?? "Unsubscribes cancelled.")
                } else if cancelled.isEmpty {
                    showToast(one.map { "Too late: already unsubscribed from \($0)." } ?? "Too late: already unsubscribed.")
                } else {
                    showToast("Cancelled \(cancelled.count) of \(outboxIDs.count) unsubscribes. The others had already gone.")
                }
            }
        }
    }

    /// Redoes an undone action. Its label edit reaches the rules again, as a new edit. Runs of `=` and
    /// examples taught without a label change are not redone.
    func redo() {
        guard let record = redoStack.popLast() else {
            showToast("Nothing to redo.")
            return
        }
        perform(record.action, on: record.threadIDs)
    }

    func repeatLastAction() {
        guard let lastAction else {
            showToast("Nothing to repeat.")
            return
        }
        perform(lastAction.action, labelName: lastAction.labelName)
    }

    // MARK: - Snooze, labels and moving

    func snooze(until date: Date) {
        perform(.snooze(until: date), on: pickerTargets.isEmpty ? nil : pickerTargets)
    }

    /// b: snoozes without the picker, until the time in Settings. When that text is not a
    /// future time ("tonight" after 8 pm, a typo), the picker opens so the snooze still happens.
    func quickSnooze(on ids: [String]? = nil) {
        guard let date = SnoozeTimes.parseFuture(settings.quickSnooze) else {
            showToast("Quick snooze needs a future time. Pick one, or change it in Settings.")
            openPicker(.snooze, on: ids)
            return
        }
        perform(.snooze(until: date), on: ids)
    }

    func toggleLabel(_ label: MailLabel, on targets: [String]) {
        let all = targets.allSatisfy { id in threads.first { $0.id == id }?.labelIDs.contains(label.id) ?? false }
        perform(all ? .removeLabel(label.id) : .addLabel(label.id), on: targets, labelName: label.name)
    }

    func createLabel(named name: String, applyTo targets: [String], local: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                let label = try await services.actions.ensureLabel(named: trimmed, kind: local ? .local : .user)
                await reloadLabels()
                if !targets.isEmpty { perform(.addLabel(label.id), on: targets, labelName: label.name) } else { showToast("Created label “\(label.name)”.") }
            } catch {
                showToast("Could not create label: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func move(_ targets: [String], to destination: Mailbox) {
        switch destination {
        case .inbox: perform(.moveToInbox, on: targets)
        case .trash: perform(.trash, on: targets)
        case .spam: perform(.spam, on: targets)
        case .archive: perform(.archive, on: targets)
        case .label(let id): perform(.moveToLabel(id), on: targets, labelName: labels.first { $0.id == id }?.name)
        default: break
        }
    }

    func renameLabel(_ label: MailLabel, to name: String) {
        Task {
            try? await services.store.renameLabel(id: label.id, to: name, syncs: label.kind == .user)
            services.engine.wake()
        }
    }

    func deleteLabel(_ label: MailLabel) {
        Task {
            try? await services.store.removeLabel(id: label.id, syncs: label.kind == .user)
            services.engine.wake()
            if destination == .mailbox(.label(label.id)) { navigate(to: .mailbox(.inbox)) }
            showToast("Deleted label “\(label.name)”. Messages kept.")
        }
    }

    // MARK: - Confirmations

    func confirm(_ confirmation: Confirmation) {
        overlay = nil
        switch confirmation.action {
        case .deleteForever(let ids):
            perform(.deleteForever, on: ids, recordUndo: false)
        case .discardDraft(let id):
            discardDrafts([id])
        case .resetDummy:
            resetDummyData()
        case .signOut:
            signOutGmail()
        case .runRules(let messageIDs):
            runRules(on: messageIDs, confirmed: true)
        case .undoRuleRun(let runID):
            undoRuleRun(runID)
        case .deleteClaudeResults:
            deleteClaudeResults()
        }
    }

    func discardDrafts(_ ids: [String]) {
        Task {
            for id in ids {
                try? await services.store.deleteDraft(id: id)
                try? FileManager.default.removeItem(at: services.draftFilesDirectory.appendingPathComponent(id))
            }
            showToast(ids.count == 1 ? "Draft discarded." : "\(ids.count) drafts discarded.")
        }
    }

    // MARK: - Views

    func saveView(_ view: SavedView) {
        var view = view
        view.name = view.name.trimmingCharacters(in: .whitespaces)
        if !views.contains(where: { $0.id == view.id }) { view.position = (views.map(\.position).max() ?? 0) + 1 }
        Task {
            try? await services.store.saveView(view)
            await reloadViews()
            overlay = nil
            navigate(to: .view(view.id))
            showToast("View saved.")
        }
    }

    func togglePin(_ view: SavedView) {
        var updated = view
        updated.pinned.toggle()
        Task { try? await services.store.saveView(updated) }
    }

    func deleteView(_ view: SavedView) {
        Task {
            try? await services.store.deleteView(id: view.id)
            if destination == .view(view.id) { navigate(to: .mailbox(.inbox)) }
            showToast("View deleted. Messages kept.")
        }
    }

    func viewMatchCount(_ view: SavedView) async -> Int {
        (try? await services.store.count(view.query)) ?? 0
    }

    // MARK: - Reader and attachments

    func readerAction(_ name: String) {
        switch name {
        case "reply": reply(all: false)
        case "replyAll": reply(all: true)
        case "forward": forward()
        case "archive": archive()
        case "moveToInbox": perform(.moveToInbox)
        case "trash": trash()
        case "star": toggleStar()
        case "snooze": openPicker(.snooze)
        case "quickSnooze": quickSnooze()
        case "toggleRead": toggleRead()
        case "label": openPicker(.label)
        case "explain": openExplain()
        case "runRules": runRulesOnSelection()
        case "createRule": newRuleFromThread()
        case "move": openPicker(.move)
        case "spam": spam()
        case "unsubscribe": unsubscribe()
        case "previous": moveCursor(by: -1)
        case "next": moveCursor(by: 1)
        case "open": openCurrent()
        case "loadImages":
            if let id = cursorID { remoteImagesAllowed.insert(id) }
            rerenderReader()
        default: break
        }
    }

    func openAttachment(messageID: String, attachmentID: String) {
        guard let message = currentThread?.messages.first(where: { $0.id == messageID }),
              let attachment = message.attachments.first(where: { $0.id == attachmentID }) else { return }
        showToast("Opening \(attachment.filename)…")
        let provider = services.provider
        Task {
            do {
                let data = try await provider.attachmentData(messageID: messageID, attachmentID: attachmentID)
                let directory = AppPaths.attachmentCache.appendingPathComponent(Self.safeFilename(messageID), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var url = directory.appendingPathComponent(Self.safeFilename(attachment.filename))
                try data.write(to: url, options: .atomic)
                // Like a browser download: Gatekeeper checks the file before anything in it can run.
                var values = URLResourceValues()
                values.quarantineProperties = [
                    kLSQuarantineAgentNameKey as String: "vimail",
                    kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                ]
                try? url.setResourceValues(values)
                NSWorkspace.shared.open(url)
            } catch {
                AppModel.log.error("Could not open attachment \(attachmentID.prefix(16))… of message \(messageID): \(error)")
                showToast("Could not open \(attachment.filename): \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// A file name from an email that is safe as one path component (no "/", "..", or hidden files).
    static func safeFilename(_ name: String) -> String {
        let cleaned = name
            .map { "/:\\".contains($0) || $0.isNewline || $0 == "\0" ? "-" : $0 }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "attachment" : String(cleaned.prefix(200))
    }

    func openFirstAttachment() {
        guard let message = currentThread?.messages.last(where: { !$0.fileAttachments.isEmpty }), let attachment = message.fileAttachments.first else {
            showToast("No attachments.")
            return
        }
        openAttachment(messageID: message.id, attachmentID: attachment.id)
    }

    /// Enter / o: edit a draft, or move focus into the reader and mark it read.
    func openCurrent() {
        guard let id = cursorID else { return }
        if id.hasPrefix("draft:") {
            Task {
                if let draft = try? await services.store.draft(id: String(id.dropFirst(6))) { openCompose(draft) }
            }
            return
        }
        focus = .reader
        if currentSummary?.isUnread == true { perform(.markRead, on: [id], recordUndo: false, silent: true) }
    }

    // MARK: - Sync and data

    /// ^l: like vim's redraw. Refreshes the list (dropping sticky rows) and syncs.
    func syncNow() {
        refreshList()
        services.engine.wake()
        showToast("Syncing…")
    }

    func simulateIncomingMail() {
        guard let dummy = services.dummy else { return }
        Task {
            try? await dummy.deliverIncomingMail(count: 1)
            services.engine.wake()
        }
    }

    func resetDummyData() {
        guard let dummy = services.dummy else { return }
        Task {
            try? await dummy.reset()
            try? await services.store.resetMailData()
            threads = []
            cursorID = nil
            undoStack.removeAll()
            services.engine.wake()
            showToast("Dummy mailbox regenerated.")
        }
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.root])
    }
}

extension ThreadAction {
    var isRepeatable: Bool {
        switch self {
        case .markRead, .wakeFromSnooze, .deleteForever: false
        default: true
        }
    }
}
