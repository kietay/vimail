import AppKit
import MailCore
import MailStore
import Observation
import VimailKit

/// State for the compose overlay: the draft, address fields, suggestions, live preview,
/// autosave to the local store, and the optional embedded vim session.
@MainActor
@Observable
final class ComposeModel {
    var draft: Draft {
        didSet { if draft != oldValue { draftChanged(previous: oldValue) } }
    }
    let source: MailMessage?
    var toText: String { didSet { if toText != oldValue { addressesChanged(.composeTo) } } }
    var ccText: String { didSet { if ccText != oldValue { addressesChanged(.composeCc) } } }
    var bccText: String { didSet { if bccText != oldValue { addressesChanged(.composeBcc) } } }
    var showCc: Bool
    var showBcc: Bool
    var suggestions: [EmailAddress] = []
    var suggestionIndex = 0
    var lastFocus: FocusTarget? = .composeBody
    var previewHTML = ""
    var savedAt: Date?
    var vim: VimSession?
    var vimRunning: Bool { vim != nil }
    /// Vim keys in the body's text view (Esc for normal mode). Ctrl+G is the full editor, `vim`.
    @ObservationIgnored let bodyVim = BodyVim()
    /// Set when the embedded editor quits: the body takes focus once its text view is back.
    @ObservationIgnored var focusBodyOnAppear = false
    private(set) var bodyMode: InlineVim.Mode = .insert
    private(set) var bodyPendingKeys = ""

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let store: MailStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var everSaved = false
    /// The signature that turning it back on restores.
    @ObservationIgnored private var signatureBeforeOff: SignatureChoice?

    init(draft: Draft, source: MailMessage?, store: MailStore, app: AppModel) {
        var draft = draft
        if draft.signature == nil { draft.signature = app.defaultSignatureChoice }
        self.draft = draft
        self.source = source
        self.store = store
        self.app = app
        toText = draft.to.isEmpty ? "" : draft.to.formattedList + ", "
        ccText = draft.cc.isEmpty ? "" : draft.cc.formattedList + ", "
        bccText = draft.bcc.isEmpty ? "" : draft.bcc.formattedList + ", "
        showCc = !draft.cc.isEmpty
        showBcc = !draft.bcc.isEmpty
        everSaved = !draft.isBlank
        previewHTML = EmailComposer.html(draft: draft, source: source, signature: app.emailSignature(draft.signature ?? .off))
    }

    var title: String { draft.kind.title }
    var draftDirectory: URL { app?.services.draftFilesDirectory.appendingPathComponent(draft.id, isDirectory: true) ?? FileManager.default.temporaryDirectory }

    // MARK: - Changes, preview and autosave

    private func draftChanged(previous: Draft) {
        if draft.body != previous.body || draft.includeQuote != previous.includeQuote || draft.signature != previous.signature {
            schedulePreview()
        }
        scheduleSave()
    }

    /// Re-renders the preview, for example after the signatures change in Settings.
    func refreshPreview() { schedulePreview() }

    private func schedulePreview() {
        previewTask?.cancel()
        let draft = draft
        let source = source
        let signature = signature
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            previewHTML = EmailComposer.html(draft: draft, source: source, signature: signature)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await saveNow()
        }
    }

    /// Saves to the local store unless the draft is blank.
    func saveNow() async {
        saveTask?.cancel()
        guard !draft.isBlank else { return }
        var copy = draft
        copy.updatedAt = Date()
        try? await store.saveDraft(copy)
        everSaved = true
        savedAt = copy.updatedAt
    }

    /// Called when compose closes. Keeps non-blank drafts; removes blank ones that were saved before.
    func finish() async {
        vim?.stop()
        if draft.isBlank {
            if everSaved { try? await store.deleteDraft(id: draft.id) }
        } else {
            await saveNow()
        }
    }

    // MARK: - Addresses

    private func addressesChanged(_ field: FocusTarget) {
        switch field {
        case .composeTo: draft.to = EmailAddress.parseList(toText)
        case .composeCc: draft.cc = EmailAddress.parseList(ccText)
        case .composeBcc: draft.bcc = EmailAddress.parseList(bccText)
        default: break
        }
        let text = field == .composeTo ? toText : field == .composeCc ? ccText : bccText
        let token = text.split(separator: ",", omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        suggestionTask?.cancel()
        guard token.count >= 1, !token.contains("<") else {
            suggestions = []
            return
        }
        let store = store
        suggestionTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let found = try? await store.contacts(matching: token) else { return }
            let existing = Set((draft.to + draft.cc + draft.bcc).map(\.normalized))
            suggestions = found.filter { !existing.contains($0.normalized) || $0.email.lowercased().hasPrefix(token.lowercased()) && token.count < $0.email.count }
            suggestionIndex = 0
        }
    }

    func moveSuggestion(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        suggestionIndex = (suggestionIndex + delta + suggestions.count) % suggestions.count
    }

    func acceptSuggestion(for field: FocusTarget, index: Int? = nil) {
        guard !suggestions.isEmpty else { return }
        let chosen = suggestions[min(index ?? suggestionIndex, suggestions.count - 1)]
        func replaced(_ text: String) -> String {
            var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if !parts.isEmpty { parts.removeLast() }
            let kept = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (kept + [chosen.formatted]).joined(separator: ", ") + ", "
        }
        switch field {
        case .composeTo: toText = replaced(toText)
        case .composeCc: ccText = replaced(ccText)
        case .composeBcc: bccText = replaced(bccText)
        default: break
        }
        suggestions = []
    }

    /// Recipients that do not look like email addresses.
    var invalidRecipients: [EmailAddress] { draft.recipients.filter { !$0.isValid } }

    // MARK: - Signature

    var signature: EmailSignature { app?.emailSignature(draft.signature ?? .off) ?? .markdown("") }

    /// The picked signature, when it is on and still exists.
    func activeSignature(in options: [SignatureOption]) -> SignatureOption? {
        options.first { $0.choice == draft.signature }
    }

    /// What turning the signature on gives: the last one picked, else the default, else the first.
    func signatureToRestore(in options: [SignatureOption]) -> SignatureOption? {
        let preferred = [signatureBeforeOff, app?.settings.defaultSignature].compactMap { $0 }
        return preferred.lazy.compactMap { choice in options.first { $0.choice == choice } }.first ?? options.first
    }

    func setSignature(on: Bool, options: [SignatureOption]) {
        if on {
            if let restored = signatureToRestore(in: options) { draft.signature = restored.choice }
        } else {
            if activeSignature(in: options) != nil { signatureBeforeOff = draft.signature }
            draft.signature = .off
        }
    }

    func chooseSignature(_ choice: SignatureChoice) {
        draft.signature = choice
    }

    // MARK: - Attachments

    func attach(_ urls: [URL]) {
        let directory = draftDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in urls {
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
            let type = UTTypeLookup.mimeType(for: destination)
            draft.attachments.append(DraftAttachment(filename: url.lastPathComponent, mimeType: type, size: size, source: .file(path: destination.path)))
        }
    }

    func removeAttachment(_ id: String) {
        if let attachment = draft.attachments.first(where: { $0.id == id }), case .file(let path) = attachment.source {
            try? FileManager.default.removeItem(atPath: path)
        }
        draft.attachments.removeAll { $0.id == id }
    }

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        if panel.runModal() == .OK { attach(panel.urls) }
    }

    // MARK: - Vim

    /// Copies the body's vim state into observed properties (status bar, footer).
    func syncBodyVim() {
        if bodyMode != bodyVim.mode { bodyMode = bodyVim.mode }
        if bodyPendingKeys != bodyVim.pendingDisplay { bodyPendingKeys = bodyVim.pendingDisplay }
    }

    /// The body starts in insert mode each time it gets focus again.
    func focusChanged(to target: FocusTarget?) {
        guard target != .composeBody else { return }
        bodyVim.reset()
        syncBodyVim()
    }

    /// Ctrl+G: edit the body in your own vim/nvim (with your config) inside the compose panel.
    func toggleVim() {
        if let vim {
            vim.focusTerminal()
            return
        }
        let file = draftDirectory.appendingPathComponent("message.md")
        do {
            try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
            try draft.body.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            app?.showToast("Could not start the editor: \(error.localizedDescription)", isError: true)
            return
        }
        let session = VimSession(file: file, command: app?.settings.editorCommand ?? "")
        session.onChange = { [weak self] text in self?.draft.body = text }
        session.onExit = { [weak self] text in
            guard let self else { return }
            if let text { self.draft.body = text }
            self.vim = nil
            self.focusBodyOnAppear = true
        }
        vim = session
        app?.focusTarget = nil
    }
}

enum UTTypeLookup {
    static func mimeType(for url: URL) -> String {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
