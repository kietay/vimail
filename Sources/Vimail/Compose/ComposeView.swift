import MailCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Bindable var compose: ComposeModel
    @FocusState private var focus: FocusTarget?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(theme.status.opacity(0.4))
                    .background(.ultraThinMaterial.opacity(0.5))
                    .ignoresSafeArea()
                    .onTapGesture { model.closeCompose() }
                panel
                    .frame(maxWidth: model.settings.showComposePreview ? 1120 : 760)
                    .frame(height: max(420, geometry.size.height * 0.84))
                    .padding(.top, geometry.size.height * 0.05)
                    .padding(.horizontal, 24)
            }
        }
        .onAppear { focus = model.focusTarget }
        .onChange(of: model.focusTarget) { _, target in focus = target }
        .onChange(of: focus) { _, value in
            if model.focusTarget != value { model.focusTarget = value }
            if let value { compose.lastFocus = value }
            compose.focusChanged(to: value)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.border).frame(height: 1)
            fields
            Rectangle().fill(theme.border).frame(height: 1)
            HStack(spacing: 0) {
                editor
                if model.settings.showComposePreview {
                    Rectangle().fill(theme.border).frame(width: 1)
                    preview
                }
            }
            .frame(maxHeight: .infinity)
            if !compose.draft.attachments.isEmpty {
                Rectangle().fill(theme.border).frame(height: 1)
                attachments
            }
            Rectangle().fill(theme.border).frame(height: 1)
            footer
        }
        .background(theme.reader.opacity(0.98), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border.opacity(0.8), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 50, y: 24)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in compose.attach([url]) }
                }
            }
            return true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(compose.title).font(AppFonts.mono(12)).foregroundStyle(theme.foreground)
            Text(compose.vimRunning ? "VIM" : "MARKDOWN")
                .font(AppFonts.mono(9, .semibold))
                .tracking(1)
                .foregroundStyle(compose.vimRunning ? theme.green : theme.mutedForeground)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(compose.vimRunning ? theme.greenSoft : theme.muted, in: RoundedRectangle(cornerRadius: 4))
            Spacer()
            if let saved = compose.savedAt {
                Text("saved \(Formatting.readerTime(saved))").font(AppFonts.mono(9)).foregroundStyle(theme.mutedForeground)
            }
            Button { model.settings.showComposePreview.toggle() } label: {
                Text(model.settings.showComposePreview ? "hide preview" : "show preview").font(AppFonts.mono(9)).foregroundStyle(theme.mutedForeground)
            }
            .buttonStyle(.plain)
            .help("Toggle the HTML preview (p in compose normal mode)")
            CloseButton(help: "Close and keep the draft (esc, esc)") { model.closeCompose() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: Fields

    private var fields: some View {
        VStack(spacing: 0) {
            addressRow("To", input: $compose.toInput, field: .composeTo) {
                HStack(spacing: 12) {
                    if !compose.showCc { smallToggle("Cc") { compose.showCc = true; focus = .composeCc } }
                    if !compose.showBcc { smallToggle("Bcc") { compose.showBcc = true; focus = .composeBcc } }
                }
            }
            if compose.showCc { addressRow("Cc", input: $compose.ccInput, field: .composeCc) { EmptyView() } }
            if compose.showBcc { addressRow("Bcc", input: $compose.bccInput, field: .composeBcc) { EmptyView() } }
            HStack(spacing: 16) {
                Text("Subject").font(AppFonts.sans(12)).foregroundStyle(theme.mutedForeground).frame(width: 52, alignment: .leading)
                TextField("", text: $compose.draft.subject, prompt: Text("Subject").foregroundColor(theme.mutedForeground.opacity(0.6)))
                    .textFieldStyle(.plain)
                    .font(AppFonts.sans(14))
                    .foregroundStyle(theme.foreground)
                    .focused($focus, equals: .composeSubject)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .zIndex(2)
    }

    /// Finished recipients as pills, then the text field for the one being typed.
    private func addressRow<Trailing: View>(_ title: String, input: Binding<String>, field: FocusTarget, @ViewBuilder trailing: () -> Trailing) -> some View {
        let recipients = compose.recipients(field)
        return HStack(alignment: .top, spacing: 16) {
            Text(title).font(AppFonts.sans(12)).foregroundStyle(theme.mutedForeground)
                .frame(width: 52, height: RecipientFlow.lineHeight, alignment: .leading)
            RecipientFlow {
                ForEach(recipients, id: \.normalized) { address in
                    RecipientPill(address: address) { compose.removeRecipient(address, from: field) }
                }
                TextField("", text: input, prompt: recipients.isEmpty ? Text("name@example.com").foregroundColor(theme.mutedForeground.opacity(0.6)) : nil)
                    .textFieldStyle(.plain)
                    .font(AppFonts.sans(13))
                    .foregroundStyle(theme.foreground)
                    .focused($focus, equals: field)
            }
            .contentShape(Rectangle())
            .onTapGesture { focus = field }
            trailing().frame(height: RecipientFlow.lineHeight)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border.opacity(0.6)).frame(height: 1).padding(.horizontal, 24) }
        .overlay(alignment: .bottomLeading) {
            if focus == field, !compose.suggestions.isEmpty {
                // Just below the row, however many lines of pills it has.
                suggestionList(for: field)
                    .alignmentGuide(.bottom) { $0[.top] - 2 }
                    .offset(x: 92)
            }
        }
        .zIndex(focus == field ? 3 : 1)
    }

    private func suggestionList(for target: FocusTarget) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(compose.suggestions.enumerated()), id: \.element.normalized) { index, address in
                HStack(spacing: 10) {
                    Text(address.initials).font(AppFonts.mono(9)).foregroundStyle(theme.mutedForeground)
                        .frame(width: 22, height: 22).background(theme.muted, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(address.displayName).font(AppFonts.sans(12)).foregroundStyle(theme.foreground)
                        if address.name != nil { Text(address.email).font(AppFonts.sans(10)).foregroundStyle(theme.mutedForeground) }
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(index == compose.suggestionIndex ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { compose.acceptSuggestion(for: target, index: index) }
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(theme.reader, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }

    private func smallToggle(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(AppFonts.sans(11)).foregroundStyle(theme.mutedForeground)
        }
        .buttonStyle(.plain)
    }

    // MARK: Editor and preview

    @ViewBuilder
    private var editor: some View {
        if let vim = compose.vim {
            VimTerminalView(session: vim, palette: theme.palette)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $compose.draft.body)
                    .font(AppFonts.mono(13))
                    .foregroundStyle(theme.foreground)
                    .scrollContentBackground(.hidden)
                    .lineSpacing(5)
                    .focused($focus, equals: .composeBody)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .onAppear {
                        guard compose.focusBodyOnAppear else { return }
                        compose.focusBodyOnAppear = false
                        Task { await focusBodyTextView() }
                    }
                if compose.draft.body.isEmpty {
                    Text("Write a message…")
                        .font(AppFonts.mono(13))
                        .foregroundStyle(theme.mutedForeground.opacity(0.6))
                        .padding(.horizontal, 25)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Focuses the body after the embedded editor quits (:wq). SwiftUI drops focus requests made
    /// before the new text view is in the window, so this waits for it and asks AppKit, like a
    /// click does. SwiftUI's focus state follows.
    private func focusBodyTextView() async {
        for _ in 0..<40 {
            if let textView = MainWindow.shared?.contentView?.firstDescendant(of: NSTextView.self, where: { !$0.isFieldEditor && $0.isEditable }) {
                textView.window?.makeFirstResponder(textView)
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PREVIEW · WHAT RECIPIENTS SEE").font(AppFonts.mono(9)).tracking(1).foregroundStyle(theme.mutedForeground)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            PreviewWebView(html: compose.previewHTML)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Attachments and footer

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(compose.draft.attachments) { attachment in
                    HStack(spacing: 8) {
                        Icon(name: .file, size: 14).foregroundStyle(theme.orange)
                        Text(attachment.filename).font(AppFonts.sans(11)).foregroundStyle(theme.foreground).lineLimit(1)
                        Text(Formatting.fileSize(attachment.size)).font(AppFonts.mono(9)).foregroundStyle(theme.mutedForeground)
                        Button { compose.removeAttachment(attachment.id) } label: { Icon(name: .close, size: 11).foregroundStyle(theme.mutedForeground) }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.muted.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
    }

    private var footerHint: String {
        if compose.vimRunning { return ":w updates the preview · :wq returns" }
        switch model.focusTarget {
        case nil: return "i edit · t to · s subject · p preview · esc close"
        case .composeBody: return compose.bodyMode == .normal
            ? "vim keys · i insert · esc compose keys · ^g your editor"
            : "esc vim keys · ^g your editor · ⌘↵ send"
        default: return "esc compose keys · ^g your editor · ⌘↵ send"
        }
    }

    /// Signature on/off, and which one. Off keeps the name, dimmed, so you see what comes back.
    @ViewBuilder
    private var signatureControl: some View {
        let options = model.signatureOptions
        if options.isEmpty {
            Button { model.overlay = .settings } label: {
                Text("Add a signature…").font(AppFonts.sans(11)).foregroundStyle(theme.mutedForeground.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Signatures are in Settings, under Compose")
        } else {
            let active = compose.activeSignature(in: options)
            HStack(spacing: 5) {
                Toggle(isOn: Binding(get: { active != nil }, set: { compose.setSignature(on: $0, options: options) })) {
                    Text("Signature").font(AppFonts.sans(11))
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(theme.mutedForeground)
                Menu {
                    ForEach(options) { option in
                        Toggle(option.name, isOn: Binding(get: { active == option }, set: { _ in compose.chooseSignature(option.choice) }))
                    }
                    Divider()
                    Button("Edit signatures…") { model.overlay = .settings }
                } label: {
                    HStack(spacing: 3) {
                        Text((active ?? compose.signatureToRestore(in: options))?.name ?? "")
                        Icon(name: .down, size: 8)
                    }
                    .font(AppFonts.sans(11))
                    .foregroundStyle(active == nil ? theme.mutedForeground.opacity(0.45) : theme.foreground.opacity(0.75))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose the signature for this message")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if compose.source != nil {
                Toggle(isOn: $compose.draft.includeQuote) {
                    Text(compose.draft.kind == .forward ? "Include forwarded message" : "Include quoted text").font(AppFonts.sans(11))
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(theme.mutedForeground)
            }
            signatureControl
            Text(footerHint)
                .font(AppFonts.mono(9))
                .foregroundStyle(theme.mutedForeground)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            Button { compose.chooseAttachments() } label: {
                HStack(spacing: 6) { Icon(name: .attach, size: 14); Text("Attach").font(AppFonts.sans(12)) }
                    .foregroundStyle(theme.mutedForeground)
            }
            .buttonStyle(.plain)
            Button { model.discardCompose() } label: {
                Text("Discard").font(AppFonts.sans(12)).foregroundStyle(theme.mutedForeground)
            }
            .buttonStyle(.plain)
            Button { model.send(compose) } label: {
                HStack(spacing: 12) {
                    Text("Send message").font(AppFonts.sans(12))
                    Icon(name: .send, size: 15)
                    KeyChip("⌘↵", dark: true, alwaysVisible: true)
                }
                .foregroundStyle(theme.buttonText)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(theme.status, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

/// Shows the outgoing HTML on a white page, like a recipient's mail client.
struct PreviewWebView: NSViewRepresentable {
    let html: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = false
        var pending: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let pending { PreviewWebView.update(webView, html: pending); self.pending = nil }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: https: http:;">
        <style>html,body{margin:0;background:#ffffff;color-scheme:light;}#mail{padding:20px 22px;}</style></head>
        <body><div id="mail"></div></body></html>
        """
        view.loadHTMLString(page, baseURL: nil)
        context.coordinator.pending = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded {
            Self.update(view, html: html)
        } else {
            context.coordinator.pending = html
        }
    }

    static func update(_ view: WKWebView, html: String) {
        guard let data = try? JSONEncoder().encode([html]), let json = String(data: data, encoding: .utf8) else { return }
        view.evaluateJavaScript("document.getElementById('mail').innerHTML = \(json)[0];", completionHandler: nil)
    }
}

extension NSView {
    /// The first view below this one, depth first, of the type that matches.
    func firstDescendant<T: NSView>(of type: T.Type, where matches: (T) -> Bool) -> T? {
        for subview in subviews {
            if let view = subview as? T, matches(view) { return view }
            if let view = subview.firstDescendant(of: type, where: matches) { return view }
        }
        return nil
    }
}
