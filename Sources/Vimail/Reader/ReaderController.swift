import AppKit
import MailCore
import WebKit

/// Data for one reader render. Encoded to JSON and passed to `vimail.render`.
struct ReaderPayload: Encodable {
    struct LabelChip: Encodable {
        var name: String
        var fg: String
        var soft: String
        /// How rules added the label, as a tooltip ("rule Receipts · Claude: payment receipt for Figma").
        var source: String?
    }
    struct MenuItem: Encodable { var title = ""; var icon = ""; var key: String?; var action = ""; var separator = false }
    struct AttachmentItem: Encodable { var id: String; var name: String; var kind: String; var size: String }
    struct Message: Encodable {
        var id: String
        var fromName: String
        var fromFull: String
        var initials: String
        var toShort: String
        var toFull: String
        var ccFull: String?
        var time: String
        var dateLong: String
        var snippet: String
        /// Unread when the reader first showed it. Stays set after the conversation is marked read.
        var isNew: Bool
        var expanded: Bool
        var focus: Bool
        /// "text", "html" (simple, rendered in theme colors) or "rich" (sandboxed iframe on a light card).
        var kind: String
        var text: String?
        var html: String?
        var attachments: [AttachmentItem]
        var sending: Bool
        /// The message is the invitation the event page shows: it collapses to one line under the page.
        var invitation = false
    }

    /// An event shown as a page: an invitation in mail, or an event in the calendar.
    struct EventPage: Encodable, Equatable {
        struct Chip: Encodable, Equatable { var text: String; var kind: String }
        struct Fact: Encodable, Equatable { var label: String; var value: String; var key: String?; var link: String? }
        struct Guest: Encodable, Equatable { var name: String; var answer: String; var kind: String }
        struct Answer: Encodable, Equatable { var title: String; var key: String; var action: String; var selected: Bool }
        /// One event in the day column. Minutes are after midnight; `kind`: mine, invite, clash, maybe, declined.
        struct Block: Encodable, Equatable { var title: String; var time: String; var start: Int; var end: Int; var column: Int; var columns: Int; var kind: String }
        struct Day: Encodable, Equatable {
            var title: String
            var startMinute: Int
            var endMinute: Int
            var allDay: [String]
            var blocks: [Block]
            var note: String?
            var noteKind: String?
            var nowMinute: Int?
            /// Where a narrow reader scrolls the column to (the invitation's start).
            var focusMinute: Int
            /// The column shows another day than the event's ({ and }).
            var peeking: Bool
        }

        var kicker: String
        var title: String
        var when: String
        var relative: String?
        var zone: String?
        var repeats: String?
        var chips: [Chip] = []
        var facts: [Fact] = []
        var guests: [Guest] = []
        var guestSummary: String?
        var agenda: String?
        var changes: [String] = []
        var answers: [Answer] = []
        var footer: String?
        var day: Day?
        /// Shown instead of the day column, for example when the calendar is not connected.
        var dayMessage: String?
        /// One line for the collapsed original email.
        var original: String?
    }

    var dark = true
    var emptyText: String?
    /// A render of the conversation already on screen keeps what is expanded, focused and scrolled to.
    var threadID: String?
    var subject = ""
    var labels: [LabelChip] = []
    /// Under the header, one line per label a rule added: "◆ receipts · rule Receipts · Claude: …".
    var provenance: [String] = []
    var position = ""
    var hasPrevious = false
    var hasNext = false
    var canReplyAll = false
    var allowRemote = false
    var showHints = false
    var menu: [MenuItem] = []
    var messages: [Message] = []
    var event: EventPage?
    /// "Next with Alex Morgan: Mon Oct 12 13:00 · 1:1 with Alex", under the conversation's header.
    var nextWith: String?

    static func empty(_ text: String, dark: Bool) -> ReaderPayload {
        var payload = ReaderPayload()
        payload.dark = dark
        payload.emptyText = text
        return payload
    }

    /// Styled marketing or notification HTML keeps its own colors on a light card.
    static func isRich(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("bgcolor") || lower.contains("background-color") || lower.contains("background:")
            || lower.contains("<table") || lower.contains("<style")
    }
}

/// Owns the reader's web view: one persistent WKWebView, re-rendered through JavaScript.
@MainActor
final class ReaderController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private var ready = false
    private var queued: [String] = []
    var onAction: ((String) -> Void)?
    var onAttachment: ((String, String) -> Void)?
    var onMailto: ((URL) -> Void)?
    /// Images a message embeds by Content-ID (`cid:`), as bytes and MIME type.
    var onInlineImage: ((_ messageID: String, _ contentID: String) async -> (Data, String)?)? {
        get { inlineImages.resolve }
        set { inlineImages.resolve = newValue }
    }
    private let inlineImages = InlineImageSchemeHandler()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(inlineImages, forURLScheme: InlineImageSchemeHandler.scheme)
        configuration.suppressesIncrementalRendering = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(ScriptBridge(owner: self), name: "vimail")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.loadHTMLString(ReaderHTML.shell(fontFaces: AppFonts.fontFaceCSS), baseURL: nil)
    }

    private func run(_ script: String) {
        if ready {
            webView.evaluateJavaScript(script, completionHandler: nil)
        } else {
            queued.append(script)
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            let pending = queued
            queued.removeAll()
            pending.forEach { webView.evaluateJavaScript($0, completionHandler: nil) }
        case "action":
            if let name = message["name"] as? String { onAction?(name) }
        case "attachment":
            if let messageID = message["messageID"] as? String, let attachmentID = message["attachmentID"] as? String {
                onAttachment?(messageID, attachmentID)
            }
        default:
            break
        }
    }

    func setTheme(_ palette: Palette) {
        guard let data = try? JSONSerialization.data(withJSONObject: palette.cssVariables), let json = String(data: data, encoding: .utf8) else { return }
        run("vimail.setTheme(\(json), \(palette.isDark))")
        webView.layer?.backgroundColor = NSColor(hex: palette.reader).cgColor
    }

    func render(_ payload: ReaderPayload) {
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else { return }
        // Replace the queue: only the latest render matters.
        if !ready { queued.removeAll { $0.hasPrefix("vimail.render(") } }
        run("vimail.render(\(json))")
    }

    func scrollLines(_ count: Int) { run("vimail.scrollLines(\(count))") }
    func scrollPage(_ fraction: Double) { run("vimail.scrollPage(\(fraction))") }
    func scrollTo(top: Bool) { run("vimail.scrollTo('\(top ? "top" : "bottom")')") }
    func focusMessage(_ delta: Int) { run("vimail.focusMessage(\(delta))") }
    func toggleFocusedMessage() { run("vimail.toggleFocused()") }
    func expandAll() { run("vimail.expandAll()") }
    func closeMenu() { run("vimail.closeMenu()") }

    #if DEBUG
    /// Debug scripts: clicks the ⋯ button (`menu`) or the button with that `data-action`, through the page.
    func debugClick(_ target: String) {
        guard !target.isEmpty, target.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
        run("document.querySelector('\(target == "menu" ? "[data-menu]" : "[data-action=\"\(target)\"]")')?.click()")
    }
    #endif

    // MARK: - Navigation: open links outside the app

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "data" {
            return decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
        }
        if scheme == "mailto" {
            onMailto?(url)
            return decisionHandler(.cancel)
        }
        if ["http", "https"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.scheme?.lowercased() == "mailto" { onMailto?(url) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.loadHTMLString(ReaderHTML.shell(fontFaces: AppFonts.fontFaceCSS), baseURL: nil)
    }
}

/// Forwards script messages without retaining the controller (WKUserContentController holds handlers strongly).
private final class ScriptBridge: NSObject, WKScriptMessageHandler {
    weak var owner: ReaderController?

    init(owner: ReaderController) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { owner?.receive(body) }
    }
}

/// Serves `vimail-cid://inline/<message ID>/<Content-ID>` URLs: images embedded in a message
/// (logos, signatures) that HTML refers to as `cid:…`. The reader rewrites those references.
final class InlineImageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "vimail-cid"
    var resolve: ((String, String) async -> (Data, String)?)?
    private var running = Set<ObjectIdentifier>()

    static func url(messageID: String, contentID: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        return "\(scheme)://inline/\(encode(messageID))/\(encode(contentID))"
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let resolve else { return task.didFailWithError(URLError(.badURL)) }
        running.insert(id)
        Task {
            let result = await resolve(parts[0], parts[1])
            guard running.remove(id) != nil else { return }
            guard let (data, mimeType) = result else { return task.didFailWithError(URLError(.resourceUnavailable)) }
            // Served as an image whatever the part claims to be.
            let type = mimeType.lowercased().hasPrefix("image/") ? mimeType : "application/octet-stream"
            task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }
}
