import AppKit
import MailCore
import MailStore
import VimailKit

/// A signature compose can pick, with the name the menu shows.
struct SignatureOption: Identifiable, Hashable {
    let choice: SignatureChoice
    let name: String
    var id: SignatureChoice { choice }
}

extension AppModel {
    /// The account's own signature (Gmail settings) first, then yours. Empty ones are left out.
    var signatureOptions: [SignatureOption] {
        var options: [SignatureOption] = []
        if accountSignature != nil { options.append(SignatureOption(choice: .account, name: "Gmail")) }
        for signature in settings.signatures where !signature.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let name = signature.name.trimmingCharacters(in: .whitespaces)
            options.append(SignatureOption(choice: .custom(signature.id), name: name.isEmpty ? "Untitled" : name))
        }
        return options
    }

    /// The default from Settings, or the first signature when the default no longer exists.
    var defaultSignatureChoice: SignatureChoice {
        let options = signatureOptions.map(\.choice)
        if settings.defaultSignature == .off || options.contains(settings.defaultSignature) { return settings.defaultSignature }
        return options.first ?? .off
    }

    func emailSignature(_ choice: SignatureChoice) -> EmailSignature {
        switch choice {
        case .account: accountSignature.map(EmailSignature.html) ?? .markdown("")
        case .custom(let id): .markdown(settings.signatures.first { $0.id == id }?.markdown ?? "")
        case .off: .markdown("")
        }
    }

    private var accountSignature: String? {
        guard services.isGmail, let html = accountSignatureHTML, !html.isEmpty else { return nil }
        return html
    }

    /// Opens compose for a new message, or an existing draft.
    func openCompose(_ draft: Draft?) {
        if let compose {
            let previous = compose
            Task { await previous.finish() }
        }
        let draft = draft ?? Draft()
        Task {
            var source: MailMessage?
            if let id = draft.sourceMessageID { source = try? await services.store.message(id: id) }
            presentCompose(draft, source: source)
        }
    }

    private func presentCompose(_ draft: Draft, source: MailMessage?) {
        let model = ComposeModel(draft: draft, source: source, store: services.store, app: self)
        overlay = nil
        compose = model
        let focus: FocusTarget = draft.to.isEmpty ? .composeTo : (draft.subject.isEmpty ? .composeSubject : .composeBody)
        model.lastFocus = focus
        if settings.composeStartsInVim && draft.kind != .new {
            model.toggleVim()
        } else {
            focusTarget = focus
        }
    }

    func reply(all: Bool) {
        guard let thread = currentThread, cursorID == thread.id else {
            showToast("Select a conversation to reply to.")
            return
        }
        let me = services.store.selfAddresses
        guard let target = thread.latestReceived(excluding: me) else { return }
        Task {
            // Continue an existing reply draft for this conversation instead of starting over.
            if let existing = try? await services.store.draft(forThread: thread.id), existing.kind != .forward {
                openCompose(existing)
                return
            }
            openCompose(ReplyComposer.reply(to: target, all: all, me: me))
        }
    }

    func forward() {
        guard let thread = currentThread, let message = thread.messages.last else {
            showToast("Select a conversation to forward.")
            return
        }
        openCompose(ReplyComposer.forward(message))
    }

    func composeMailto(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let address = components?.path ?? ""
        var draft = Draft(to: EmailAddress.parseList(address))
        for item in components?.queryItems ?? [] {
            switch item.name.lowercased() {
            case "subject": draft.subject = item.value ?? ""
            case "body": draft.body = item.value ?? ""
            case "cc": draft.cc = EmailAddress.parseList(item.value ?? "")
            default: break
            }
        }
        openCompose(draft)
    }

    /// Closes compose. The draft stays in Drafts unless it is blank.
    func closeCompose() {
        guard let compose else { return }
        self.compose = nil
        focusTarget = nil
        blurTextInput()
        Task {
            await compose.finish()
            if !compose.draft.isBlank { showToast("Draft saved.") }
        }
    }

    func discardCompose() {
        guard let compose else { return }
        compose.vim?.stop()
        let id = compose.draft.id
        self.compose = nil
        focusTarget = nil
        blurTextInput()
        discardDrafts([id])
    }

    /// Sends after the undo window: shows an optimistic copy in Sent right away.
    func send(_ compose: ComposeModel) {
        if compose.vimRunning {
            showToast("Save and quit vim (:wq) before sending.")
            return
        }
        compose.commitAllInputs()
        var draft = compose.draft
        if draft.recipients.isEmpty {
            showToast("Add at least one recipient.", isError: true)
            focusTarget = .composeTo
            return
        }
        if let invalid = compose.invalidRecipients.first {
            showToast("“\(invalid.email)” is not a valid address.", isError: true)
            focusTarget = .composeTo
            return
        }
        draft.updatedAt = Date()
        let from = account.email.isEmpty ? EmailAddress(name: "Me", email: "me@localhost") : account
        let outgoing = EmailComposer.outgoing(draft: draft, source: compose.source, signature: compose.signature, from: from)
        let localThreadID = outgoing.threadID ?? "local-thread-\(UUID().uuidString.lowercased())"
        let localCopy = MailMessage(
            id: "local-\(UUID().uuidString.lowercased())", threadID: localThreadID, labelIDs: [SystemLabel.sent], from: from,
            to: outgoing.to, cc: outgoing.cc, bcc: outgoing.bcc, subject: outgoing.subject,
            snippet: HTMLText.snippet(from: draft.body), date: Date(), textBody: outgoing.textBody, htmlBody: outgoing.htmlBody,
            attachments: draft.attachments.map { MailAttachment(id: $0.id, filename: $0.filename, mimeType: $0.mimeType, size: $0.size) }
        )
        let delay = max(0, settings.undoSendSeconds)
        let sendAt = Date().addingTimeInterval(delay)
        self.compose = nil
        focusTarget = nil
        blurTextInput()
        Task {
            do {
                let outboxID = try await services.store.queueSend(draft: draft, message: outgoing, localCopy: localCopy, notBefore: sendAt)
                AppModel.log.info("Queued send as outbox #\(outboxID) (\(outgoing.messageID ?? "?"), \(outgoing.attachments.count) attachment(s), sends in \(Int(delay))s)")
                undoStack.append(.send(outboxID: outboxID, draft: draft, localMessageID: localCopy.id))
                if delay > 0 { showToast("Sending", undoable: true, countdownTo: sendAt) } else { showToast("Sending…") }
                services.engine.wake()
            } catch {
                AppModel.log.error("Could not queue a send: \(error)")
                showToast("Could not queue the message: \(error.localizedDescription)", isError: true)
                presentCompose(draft, source: compose.source)
            }
        }
    }
}
