import Foundation
import Testing
@testable import GmailProvider
import HTTPKit
@testable import MailCore

/// A scripted HTTP server. Records every request; `route` answers them.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Call {
        var method: String
        var url: URL
        var body: Data
        var contentType: String?
        var headers: [String: String] = [:]

        var path: String { url.path }
        var query: [String: String] {
            Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let route: @Sendable (Call) -> (Int, String)

    init(route: @escaping @Sendable (Call) -> (Int, String)) {
        self.route = route
    }

    var calls: [Call] { lock.withLock { recorded } }
    var apiCalls: [Call] { calls.filter { $0.url.host == "gmail.googleapis.com" } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = Call(method: request.httpMethod ?? "GET", url: request.url!, body: request.httpBody ?? Data(),
                        contentType: request.value(forHTTPHeaderField: "Content-Type"), headers: request.allHTTPHeaderFields ?? [:])
        lock.withLock { recorded.append(call) }
        let (status, body) = call.url.host == "oauth2.googleapis.com" && call.path == "/token"
            ? (200, #"{"access_token":"token-1","expires_in":3600}"#)
            : route(call)
        // Rate limits say how long to wait; one second keeps tests quick.
        let headers = status == 429 ? ["Retry-After": "1"] : [:]
        return (Data(body.utf8), HTTPURLResponse(url: call.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

/// A provider whose pacing never slows tests down.
func makeProvider(_ transport: any HTTPTransport, web: (any HTTPTransport)? = nil) -> GmailProvider {
    GmailProvider(credential: testCredential, transport: transport, web: web ?? transport, concurrency: 8,
                  pacer: QuotaPacer(unitsPerSecond: 1_000_000, maxRate: 1_000_000, burst: 1_000_000, maxConcurrent: 8))
}

let testClient = GoogleOAuthClient(clientID: "client.apps.googleusercontent.com", clientSecret: "secret")
let testCredential = GoogleCredential(email: "me@example.com", refreshToken: "refresh", scopes: [GmailScope.modify], client: testClient)

func b64(_ text: String) -> String { Data(text.utf8).base64URLEncodedString() }
func b64(_ data: Data) -> String { data.base64URLEncodedString() }

func json(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// A typical message: text + HTML alternative (the HTML in ISO-8859-1), a PDF and an inline logo.
func sampleMessage(id: String = "m1", thread: String = "t1", labels: [String] = ["INBOX", "UNREAD"]) -> [String: Any] {
    let latin1HTML = Data("<p>Caf".utf8) + Data([0xE9]) + Data(" <img src=\"cid:logo@x\"></p>".utf8)
    return [
        "id": id, "threadId": thread, "labelIds": labels, "snippet": "Caf&eacute;", "internalDate": "1791000000000", "sizeEstimate": 4321,
        "payload": [
            "partId": "", "mimeType": "multipart/mixed",
            "headers": [
                ["name": "From", "value": "Alex Morgan <alex@studio.co>"],
                ["name": "To", "value": "Me <me@example.com>, \"Last, First\" <first@example.com>"],
                ["name": "Cc", "value": "team@example.com"],
                ["name": "Subject", "value": "=?UTF-8?B?w6l0w6k=?= plans"],
                ["name": "Message-Id", "value": "<abc@studio.co>"],
                ["name": "In-Reply-To", "value": "<prev@example.com>"],
                ["name": "References", "value": "<root@example.com> <prev@example.com>"],
                ["name": "List-Unsubscribe", "value": "<mailto:unsub@studio.co>"],
            ],
            "body": ["size": 0],
            "parts": [
                [
                    "partId": "0", "mimeType": "multipart/related", "body": ["size": 0],
                    "parts": [
                        [
                            "partId": "0.0", "mimeType": "multipart/alternative", "body": ["size": 0],
                            "parts": [
                                ["partId": "0.0.0", "mimeType": "text/plain", "headers": [["name": "Content-Type", "value": "text/plain; charset=\"UTF-8\""]],
                                 "body": ["size": 12, "data": b64("Café plans\nOn Mon, Oct 5, 2026 at 9:00 AM Sam <sam@x.co> wrote:\n> old")]],
                                ["partId": "0.0.1", "mimeType": "text/html", "headers": [["name": "Content-Type", "value": "text/html; charset=iso-8859-1"]],
                                 "body": ["size": 30, "data": b64(latin1HTML)]],
                            ],
                        ],
                        ["partId": "0.1", "mimeType": "image/png", "filename": "logo.png",
                         "headers": [["name": "Content-ID", "value": "<logo@x>"], ["name": "Content-Disposition", "value": "inline; filename=logo.png"]],
                         "body": ["attachmentId": "att-logo", "size": 900]],
                        ["partId": "0.2", "mimeType": "image/jpeg", "filename": "photo.jpg",
                         "headers": [["name": "Content-ID", "value": "<photo@x>"]],
                         "body": ["attachmentId": "att-photo", "size": 5000]],
                    ],
                ],
                ["partId": "1", "mimeType": "application/pdf", "filename": "Plan.pdf",
                 "headers": [["name": "Content-Disposition", "value": "attachment; filename=\"Plan.pdf\""]],
                 "body": ["attachmentId": "att-pdf", "size": 2048]],
                ["partId": "2", "mimeType": "text/calendar", "headers": [], "body": ["attachmentId": "att-cal", "size": 100]],
            ],
        ],
    ]
}

// MARK: - OAuth

struct OAuthTests {
    @Test func pkceChallengeMatchesRFC7636() {
        // RFC 7636, appendix B.
        #expect(GoogleAuthorizationRequest.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func authorizationURLAsksForOfflineAccessWithPKCE() {
        let request = GoogleAuthorizationRequest(client: testClient, scopes: [GmailScope.modify], redirectURI: "http://127.0.0.1:5555", loginHint: "me@example.com")
        let items = Dictionary(URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) }, uniquingKeysWith: { a, _ in a })
        #expect(items["client_id"] == testClient.clientID)
        #expect(items["redirect_uri"] == "http://127.0.0.1:5555")
        #expect(items["scope"] == GmailScope.modify)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == GoogleAuthorizationRequest.codeChallenge(for: request.codeVerifier))
        #expect(items["access_type"] == "offline")
        #expect(items["prompt"] == "consent")
        #expect(items["login_hint"] == "me@example.com")
        #expect(items["state"] == request.state)
        #expect(request.codeVerifier.count >= 43)
    }

    @Test func callbackIsCheckedAgainstTheRequest() throws {
        let request = GoogleAuthorizationRequest(client: testClient, scopes: [GmailScope.modify], redirectURI: "http://127.0.0.1:1")
        #expect(try request.code(fromCallback: ["code": "c", "state": request.state]) == "c")
        #expect(throws: GoogleOAuthError.stateMismatch) { try request.code(fromCallback: ["code": "c", "state": "other"]) }
        #expect(throws: GoogleOAuthError.cancelled) { try request.code(fromCallback: ["error": "access_denied", "state": request.state]) }
    }

    @Test func parsesDownloadedClientAndPythonTokenFiles() throws {
        let client = try GoogleOAuthClient(clientSecretJSON: Data(#"{"installed":{"client_id":"id","client_secret":"s","token_uri":"https://oauth2.googleapis.com/token","redirect_uris":["http://localhost"]}}"#.utf8))
        #expect(client.clientID == "id" && client.clientSecret == "s")
        #expect(throws: GoogleOAuthError.invalidClientFile) { try GoogleOAuthClient(clientSecretJSON: Data("{}".utf8)) }

        let credential = try GoogleCredential(authorizedUserJSON: Data(#"{"token":"t","refresh_token":"r","client_id":"id","client_secret":"s","scopes":["https://www.googleapis.com/auth/gmail.readonly"],"account":""}"#.utf8))
        #expect(credential.refreshToken == "r")
        #expect(!credential.allowsChanges)
    }

    @Test func loopbackParsesOnlyTheRedirect() {
        #expect(LoopbackReceiver.callbackQuery(fromRequestHead: "GET /?state=s&code=4%2F0Ab HTTP/1.1\r\nHost: 127.0.0.1") == ["state": "s", "code": "4/0Ab"])
        #expect(LoopbackReceiver.callbackQuery(fromRequestHead: "GET /?error=access_denied&state=s HTTP/1.1") == ["error": "access_denied", "state": "s"])
        #expect(LoopbackReceiver.callbackQuery(fromRequestHead: "GET /favicon.ico HTTP/1.1") == nil)
        #expect(LoopbackReceiver.callbackQuery(fromRequestHead: "POST /?code=x HTTP/1.1") == nil)
    }

    @Test func loopbackServerReceivesTheBrowserRedirect() async throws {
        let receiver = try LoopbackReceiver()
        try await receiver.start()
        #expect(receiver.port > 0)
        let url = URL(string: receiver.redirectURI + "/?code=abc&state=xyz")!
        async let page = URLSession.shared.data(from: url)
        let query = try await receiver.callback(timeout: .seconds(10))
        #expect(query["code"] == "abc")
        let (data, response) = try await page
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("vimail is connected"))
    }

    @Test func expiredRefreshTokenMeansSignedOut() async throws {
        let transport = FakeTransportWithTokenFailure()
        let provider = makeProvider(transport)
        await #expect(throws: ProviderError.unauthorized) { try await provider.labels() }
    }
}

final class FakeTransportWithTokenFailure: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
    }
}

// MARK: - Mapping

struct MappingTests {
    @Test func mapsHeadersBodiesAndAttachments() throws {
        let message = GmailMapping.message(try JSONDecoder().decode(GmailMessage.self, from: Data(json(sampleMessage()).utf8)))
        #expect(message.id == "m1" && message.threadID == "t1")
        #expect(message.labelIDs == ["INBOX", "UNREAD"])
        #expect(message.from == EmailAddress(name: "Alex Morgan", email: "alex@studio.co"))
        #expect(message.to.map(\.email) == ["me@example.com", "first@example.com"])
        #expect(message.to.last?.name == "Last, First")
        #expect(message.cc.map(\.email) == ["team@example.com"])
        #expect(message.subject == "été plans")
        #expect(message.messageIDHeader == "<abc@studio.co>")
        #expect(message.inReplyTo == "<prev@example.com>")
        #expect(message.references == ["<root@example.com>", "<prev@example.com>"])
        #expect(message.listUnsubscribe == "<mailto:unsub@studio.co>")
        #expect(message.date == Date(timeIntervalSince1970: 1_791_000_000))
        #expect(message.textBody?.hasPrefix("Café plans") == true)
        // ISO-8859-1 bytes decode as text.
        #expect(message.htmlBody?.contains("Café") == true)
        // The snippet stops at the quoted reply.
        #expect(message.snippet == "Café plans")
        #expect(message.sizeEstimate == 4321)

        let files = message.fileAttachments.map(\.filename)
        #expect(files == ["photo.jpg", "Plan.pdf"])
        let logo = message.attachments.first { $0.filename == "logo.png" }
        #expect(logo?.isInline == true && logo?.contentID == "logo@x" && logo?.id == "att-logo")
        // The calendar part repeats an invite; it is not listed.
        #expect(!message.attachments.contains { $0.mimeType == "text/calendar" })
    }

    @Test func decodesEncodedWordsAndCharsets() {
        #expect(GmailMapping.decodeHeader("=?UTF-8?B?w6l0w6k=?= =?ISO-8859-1?Q?caf=E9_cr=E8me?=") == "étécafé crème")
        #expect(GmailMapping.decodeHeader("Plain subject") == "Plain subject")
        #expect(GmailMapping.decodeHeader("Re: =?utf-8?q?na=C3=AFve?= idea") == "Re: naïve idea")
        #expect(GmailMapping.decodeText(Data([0x93, 0x68, 0x69, 0x94]), charset: "iso-8859-1") == "\u{201C}hi\u{201D}")
        #expect(GmailMapping.decodeText(Data("ok ✓".utf8), charset: "us-ascii") == "ok ✓")
        #expect(GmailMapping.decodeText(Data([0xE9]), charset: nil) == "é")
        #expect(GmailMapping.parameters(of: "text/html; charset=\"utf-8\"; format=flowed")["charset"] == "utf-8")
    }

    @Test func singlePartAndNamelessAttachments() throws {
        let html: [String: Any] = [
            "id": "m2", "threadId": "m2", "labelIds": ["INBOX"], "internalDate": "1791000000000",
            "payload": ["partId": "", "mimeType": "text/html", "headers": [["name": "From", "value": "news@x.co"], ["name": "Subject", "value": "Hi"]],
                        "body": ["size": 10, "data": b64("<b>Hello</b>")]],
        ]
        let message = GmailMapping.message(try JSONDecoder().decode(GmailMessage.self, from: Data(json(html).utf8)))
        #expect(message.htmlBody == "<b>Hello</b>")
        #expect(message.textBody == nil)
        #expect(message.plainText.contains("Hello"))
        #expect(message.from.email == "news@x.co")

        let zip: [String: Any] = [
            "id": "m3", "threadId": "m3", "payload": ["partId": "", "mimeType": "application/zip", "filename": "", "body": ["size": 10, "data": b64("PK")]],
        ]
        let attachment = GmailMapping.message(try JSONDecoder().decode(GmailMessage.self, from: Data(json(zip).utf8))).attachments.first
        #expect(attachment?.id == "part:")
        #expect(attachment?.filename == "attachment.zip")
    }

    /// Headers of a list message as Gmail delivers them: its verdict on top, folded values.
    func listHeaders(verdict: String = "dkim=pass header.i=@news.co header.s=s1 header.b=AbC+/d12",
                     signed: String = "From:To:Subject:List-Unsubscribe:\r\n\tList-Unsubscribe-Post:Message-ID",
                     post: String? = "List-Unsubscribe=One-Click") -> [GmailHeader] {
        var headers = [
            GmailHeader(name: "Authentication-Results", value: "mx.google.com;\r\n       \(verdict);\r\n       spf=pass (google.com: domain of b@news.co designates 1.2.3.4; really) smtp.mailfrom=b@news.co"),
            GmailHeader(name: "DKIM-Signature", value: "v=1; a=rsa-sha256; c=relaxed/relaxed; d=news.co; s=s1;\r\n\th=\(signed);\r\n\tbh=xyz=; b=AbC+/d12EfGh\r\n\tIjKl=="),
            GmailHeader(name: "From", value: "News <hello@news.co>"),
            GmailHeader(name: "List-Unsubscribe", value: "<https://news.co/u/123>, <mailto:u-123@news.co>"),
        ]
        if let post { headers.append(GmailHeader(name: "List-Unsubscribe-Post", value: post)) }
        return headers
    }

    @Test func oneClickNeedsADKIMSignatureGmailVerified() throws {
        #expect(GmailMapping.isOneClickUnsubscribe(listHeaders()))
        // Gmail names the signature by its domain only.
        #expect(GmailMapping.isOneClickUnsubscribe(listHeaders(verdict: "dkim=pass header.d=news.co")))
        // The signature does not cover List-Unsubscribe-Post: anyone on the way could have added it.
        #expect(!GmailMapping.isOneClickUnsubscribe(listHeaders(signed: "From:To:Subject:List-Unsubscribe")))
        #expect(!GmailMapping.isOneClickUnsubscribe(listHeaders(verdict: "dkim=fail (bad signature) header.i=@news.co header.b=AbC+/d12")))
        // Another signature passed.
        #expect(!GmailMapping.isOneClickUnsubscribe(listHeaders(verdict: "dkim=pass header.i=@esp.example header.b=Zz99Zz99")))
        #expect(!GmailMapping.isOneClickUnsubscribe(listHeaders(post: nil)))
        #expect(!GmailMapping.isOneClickUnsubscribe(listHeaders(post: "List-Unsubscribe=Later")))

        // A verdict the sender wrote further down does not count; only Gmail's, on top.
        var forged = listHeaders(verdict: "dkim=fail header.i=@news.co header.b=AbC+/d12")
        forged.append(GmailHeader(name: "Authentication-Results", value: "mx.google.com; dkim=pass header.i=@news.co header.b=AbC+/d12"))
        #expect(!GmailMapping.isOneClickUnsubscribe(forged))
        var notGmail = listHeaders()
        notGmail[0].value = "mx.example.net; dkim=pass header.i=@news.co header.b=AbC+/d12"
        #expect(!GmailMapping.isOneClickUnsubscribe(notGmail))
        notGmail[0].value = "mx.google.com.example.net; dkim=pass header.i=@news.co header.b=AbC+/d12"
        #expect(!GmailMapping.isOneClickUnsubscribe(notGmail))

        // Someone on the way adds the headers with a forged signature that starts like the real one,
        // which signs neither list header. Two signatures then match Gmail's verdict: refused.
        var relayed = listHeaders(signed: "From:To:Subject")
        relayed.insert(GmailHeader(name: "DKIM-Signature", value: "v=1; d=news.co; s=s1; h=List-Unsubscribe:List-Unsubscribe-Post; b=AbC+/d12Fake"), at: 1)
        #expect(!GmailMapping.isOneClickUnsubscribe(relayed))
        // The verified domain must be the signature's.
        #expect(!GmailMapping.isOneClickUnsubscribe(listHeaders(verdict: "dkim=pass header.i=@other.co header.b=AbC+/d12")))
        // A second List-Unsubscribe above the signed one would not break the signature.
        var doubled = listHeaders()
        doubled.insert(GmailHeader(name: "List-Unsubscribe", value: "<https://evil.example/u>"), at: 0)
        #expect(!GmailMapping.isOneClickUnsubscribe(doubled))

        // Mapped messages carry the answer; mail without the header is known not to have it.
        var verified = sampleMessage()
        var payload = verified["payload"] as! [String: Any]
        payload["headers"] = listHeaders().map { ["name": $0.name, "value": $0.value] }
        verified["payload"] = payload
        #expect(GmailMapping.message(try JSONDecoder().decode(GmailMessage.self, from: Data(json(verified).utf8))).oneClickUnsubscribe == true)
        #expect(GmailMapping.message(try JSONDecoder().decode(GmailMessage.self, from: Data(json(sampleMessage()).utf8))).oneClickUnsubscribe == false)
    }
}

// MARK: - Provider requests

struct ProviderTests {
    @Test func listsInboxPagesWithFields() async throws {
        let transport = FakeTransport { call in
            (200, #"{"threads":[{"id":"a"},{"id":"b"}],"nextPageToken":"p2"}"#)
        }
        let provider = makeProvider(transport)
        let page = try await provider.listThreadIDs(labelID: "INBOX", pageToken: "p1", pageSize: 25)
        #expect(page.ids == ["a", "b"] && page.nextPageToken == "p2")
        let call = try #require(transport.apiCalls.first)
        #expect(call.path == "/gmail/v1/users/me/threads")
        #expect(call.query["labelIds"] == "INBOX" && call.query["pageToken"] == "p1" && call.query["maxResults"] == "25")
    }

    @Test func profileListsSendAsAliasesWithoutThePrimaryAddress() async throws {
        let transport = FakeTransport { call in
            switch call.path {
            case "/gmail/v1/users/me/profile":
                return (200, #"{"emailAddress":"me@example.com","historyId":"42"}"#)
            case "/gmail/v1/users/me/settings/sendAs":
                return (200, json(["sendAs": [
                    ["sendAsEmail": "Me@Example.com", "displayName": "Sam Carter", "isPrimary": true],
                    ["sendAsEmail": "sam@studio.co", "displayName": "Sam Carter"],
                    ["sendAsEmail": "hello@studio.co"],
                ]]))
            default:
                return (404, #"{"error":{"code":404,"message":"Not Found"}}"#)
            }
        }
        let profile = try await makeProvider(transport).profile()
        #expect(profile.email == "me@example.com")
        #expect(profile.displayName == "Sam Carter")
        #expect(profile.aliases == ["sam@studio.co", "hello@studio.co"])
    }

    @Test func fetchesThreadsAndBodiesSentByReference() async throws {
        let transport = FakeTransport { call in
            switch call.path {
            case "/gmail/v1/users/me/threads/t1":
                var big = sampleMessage()
                // Gmail sends large body parts by attachment ID instead of inline data.
                var payload = big["payload"] as! [String: Any]
                payload["parts"] = [["partId": "0", "mimeType": "text/html", "body": ["attachmentId": "att-body", "size": 900000]]]
                big["payload"] = payload
                let draft = sampleMessage(id: "d1", labels: ["DRAFT"])
                return (200, json(["id": "t1", "messages": [big, draft]]))
            case "/gmail/v1/users/me/messages/m1/attachments/att-body":
                return (200, json(["size": 11, "data": b64("<p>Long</p>")]))
            default:
                return (404, #"{"error":{"code":404,"message":"Not Found"}}"#)
            }
        }
        let provider = makeProvider(transport)
        let threads = try await provider.threads(ids: ["t1", "missing"])
        #expect(threads.count == 1)
        // Drafts saved in Gmail are skipped.
        #expect(threads[0].map(\.id) == ["m1"])
        #expect(threads[0][0].htmlBody == "<p>Long</p>")
        #expect(transport.apiCalls.allSatisfy { $0.method == "GET" })
    }

    @Test func historyBecomesAChangeSet() async throws {
        let history: [String: Any] = [
            "historyId": "200",
            "history": [
                ["id": "150", "messagesAdded": [["message": ["id": "new", "threadId": "new", "labelIds": ["INBOX", "UNREAD"]]]]],
                ["id": "151", "messagesAdded": [["message": ["id": "draft", "threadId": "draft", "labelIds": ["DRAFT"]]]]],
                ["id": "152", "labelsRemoved": [["message": ["id": "old", "threadId": "t0", "labelIds": ["SENT"]], "labelIds": ["INBOX"]]]],
                ["id": "153", "labelsAdded": [["message": ["id": "old", "threadId": "t0", "labelIds": ["SENT", "STARRED"]], "labelIds": ["STARRED"]]]],
                ["id": "154", "messagesDeleted": [["message": ["id": "gone", "threadId": "t9"]]]],
            ],
        ]
        let historyJSON = json(history)
        let transport = FakeTransport { call in
            switch call.path {
            case "/gmail/v1/users/me/history": return (200, historyJSON)
            case "/gmail/v1/users/me/messages/new": return (200, json(sampleMessage(id: "new", thread: "new")))
            case "/gmail/v1/users/me/labels": return (200, #"{"labels":[{"id":"INBOX","name":"INBOX","type":"system"},{"id":"UNREAD","name":"UNREAD","type":"system"},{"id":"SENT","name":"SENT","type":"system"},{"id":"STARRED","name":"STARRED","type":"system"}]}"#)
            default: return (404, "{}")
            }
        }
        let provider = makeProvider(transport)
        _ = try await provider.labels()
        let changes = try await provider.changes(since: "100")
        #expect(changes.cursor == "200")
        #expect(changes.upserted.map(\.id) == ["new"])
        #expect(changes.labelUpdates == ["old": ["SENT", "STARRED"]])
        #expect(changes.deleted == ["gone"])
        #expect(!changes.labelsChanged)
        #expect(transport.apiCalls.first { $0.path.hasSuffix("/history") }?.query["startHistoryId"] == "100")
        #expect(!transport.apiCalls.contains { $0.path.hasSuffix("/messages/draft") })
    }

    @Test func expiredHistoryNeedsAResync() async throws {
        let transport = FakeTransport { _ in (404, #"{"error":{"code":404,"message":"Requested entity was not found."}}"#) }
        let provider = makeProvider(transport)
        await #expect(throws: ProviderError.cursorExpired) { try await provider.changes(since: "1") }
    }

    @Test func labelChangesUseBatchModifyAndSkipLocalIDs() async throws {
        let transport = FakeTransport { _ in (204, "") }
        let provider = makeProvider(transport)
        try await provider.modifyLabels(messageIDs: ["m1", "local-123", "m2"], add: ["TRASH", "local-ai"], remove: ["INBOX"])
        let call = try #require(transport.apiCalls.first)
        #expect(call.method == "POST" && call.path == "/gmail/v1/users/me/messages/batchModify")
        #expect(call.json["ids"] as? [String] == ["m1", "m2"])
        #expect(call.json["addLabelIds"] as? [String] == ["TRASH"])
        #expect(call.json["removeLabelIds"] as? [String] == ["INBOX"])

        try await provider.modifyLabels(messageIDs: ["local-1"], add: ["STARRED"], remove: [])
        #expect(transport.apiCalls.count == 1)
    }

    @Test func readOnlyAccessIsRejectedNotRetried() async throws {
        let transport = FakeTransport { _ in
            (403, #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","errors":[{"reason":"insufficientPermissions"}],"status":"PERMISSION_DENIED"}}"#)
        }
        let provider = makeProvider(transport)
        await #expect(throws: ProviderError.rejected("Request had insufficient authentication scopes.")) {
            try await provider.modifyLabels(messageIDs: ["m1"], add: [], remove: ["UNREAD"])
        }
        #expect(transport.apiCalls.count == 1)
    }

    @Test func expiredAccessTokenIsRenewedOnce() async throws {
        let attempts = Counter()
        let transport = FakeTransport { _ in
            attempts.increment() == 1 ? (401, #"{"error":{"code":401}}"#) : (200, #"{"labels":[]}"#)
        }
        let provider = makeProvider(transport)
        _ = try await provider.labels()
        #expect(transport.calls.filter { $0.path == "/token" }.count == 2)
        #expect(transport.apiCalls.count == 2)
    }

    @Test func rateLimitsAreRetried() async throws {
        let attempts = Counter()
        let transport = FakeTransport { _ in
            attempts.increment() == 1 ? (429, #"{"error":{"code":429,"message":"Too many"}}"#) : (200, #"{"labels":[]}"#)
        }
        let provider = makeProvider(transport)
        _ = try await provider.labels()
        #expect(transport.apiCalls.count == 2)
    }

    @Test func sendUploadsMIMEIntoTheThread() async throws {
        let transport = FakeTransport { call in
            switch (call.method, call.path) {
            case ("POST", "/upload/gmail/v1/users/me/messages/send"): return (200, #"{"id":"s1","threadId":"t1","labelIds":["SENT"]}"#)
            case ("GET", "/gmail/v1/users/me/messages/s1"): return (200, json(sampleMessage(id: "s1", thread: "t1", labels: ["SENT"])))
            default: return (404, "{}")
            }
        }
        let provider = makeProvider(transport)
        let outgoing = OutgoingMessage(
            from: EmailAddress(name: "Me", email: "me@example.com"), to: [EmailAddress(email: "alex@studio.co")],
            subject: "Re: plans", textBody: "Sounds good", htmlBody: "<p>Sounds good</p>", threadID: "t1",
            inReplyTo: "<abc@studio.co>", references: ["<abc@studio.co>"],
            attachments: [DraftAttachment(id: "f1", filename: "notes.txt", mimeType: "text/plain", size: 5, source: .file(path: "/tmp/x"))],
            messageID: "<vimail.1@example.com>"
        )
        let sent = try await provider.send(outgoing, fileData: ["f1": Data("notes".utf8)], isRetry: false)
        #expect(sent.id == "s1")
        let upload = try #require(transport.apiCalls.first { $0.method == "POST" })
        #expect(upload.query["uploadType"] == "multipart")
        #expect(upload.contentType?.hasPrefix("multipart/related; boundary=") == true)
        let body = String(decoding: upload.body, as: UTF8.self)
        #expect(body.contains(#"{"threadId":"t1"}"#))
        #expect(body.contains("Content-Type: message/rfc822"))
        #expect(body.contains("Message-ID: <vimail.1@example.com>"))
        #expect(body.contains("In-Reply-To: <abc@studio.co>"))
        #expect(body.contains("filename=\"notes.txt\""))
        // No search for an earlier copy on a first attempt.
        #expect(!transport.apiCalls.contains { $0.query["q"] != nil })
    }

    @Test func retriedSendDoesNotSendTwice() async throws {
        let transport = FakeTransport { call in
            switch (call.method, call.path) {
            case ("GET", "/gmail/v1/users/me/messages") where call.query["q"] == "rfc822msgid:vimail.1@example.com":
                return (200, #"{"messages":[{"id":"s1","threadId":"t1"}]}"#)
            case ("GET", "/gmail/v1/users/me/messages/s1"): return (200, json(sampleMessage(id: "s1", thread: "t1", labels: ["SENT"])))
            default: return (500, "{}")
            }
        }
        let provider = makeProvider(transport)
        let outgoing = OutgoingMessage(from: EmailAddress(email: "me@example.com"), to: [EmailAddress(email: "a@b.co")], subject: "Hi", textBody: "Hi", messageID: "<vimail.1@example.com>")
        let sent = try await provider.send(outgoing, fileData: [:], isRetry: true)
        #expect(sent.id == "s1")
        #expect(!transport.apiCalls.contains { $0.method == "POST" })
    }

    @Test func dryRunNeverWritesToGmail() async throws {
        let transport = FakeTransport { call in
            call.method == "GET" ? (200, #"{"labels":[]}"#) : (500, "{}")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-dryrun-\(UUID().uuidString)")
        let provider = DryRunProvider(wrapping: makeProvider(transport), directory: directory)
        try await provider.modifyLabels(messageIDs: ["m1"], add: ["STARRED"], remove: ["INBOX"])
        _ = try await provider.createLabel(name: "Later")
        let sent = try await provider.send(
            OutgoingMessage(from: EmailAddress(email: "me@example.com"), to: [EmailAddress(email: "a@b.co")], subject: "Test", textBody: "Body", threadID: "t1"),
            fileData: [:], isRetry: false
        )
        try await provider.unsubscribe(oneClick: URL(string: "https://news.co/u/123")!)
        #expect(sent.id.hasPrefix("dryrun-") && sent.threadID == "t1")
        #expect(transport.apiCalls.isEmpty)
        #expect(!transport.calls.contains { $0.url.host == "news.co" })
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.contains("changes.log"))
        #expect(files.contains { $0.hasSuffix(".eml") })
        let log = try String(contentsOf: directory.appendingPathComponent("changes.log"), encoding: .utf8)
        #expect(log.contains("unsubscribe one-click host=news.co"))
        #expect(!log.contains("/u/123"))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func oneClickUnsubscribeIsOnePlainPost() async throws {
        let transport = FakeTransport { call in call.url.host == "news.co" ? (204, "") : (404, "{}") }
        let provider = makeProvider(transport)
        try await provider.unsubscribe(oneClick: URL(string: "https://news.co/u/123?t=abc")!)
        let call = try #require(transport.calls.first)
        #expect(transport.calls.count == 1)
        #expect(call.method == "POST" && call.url.absoluteString == "https://news.co/u/123?t=abc")
        #expect(String(decoding: call.body, as: UTF8.self) == "List-Unsubscribe=One-Click")
        #expect(call.contentType == "application/x-www-form-urlencoded")
        // RFC 8058: no cookies, no credentials. Not even a Google token is fetched.
        #expect(call.headers["Authorization"] == nil && call.headers["Cookie"] == nil)
        await #expect(throws: ProviderError.rejected("One-click unsubscribe needs an https address")) {
            try await provider.unsubscribe(oneClick: URL(string: "http://news.co/u/123")!)
        }
    }

    @Test func oneClickUnsubscribeAnswers() async throws {
        let transport = FakeTransport { call in
            switch call.path {
            case "/moved": (302, "")
            case "/busy": (503, "")
            case "/slow-down": (429, "")
            default: (404, "")
            }
        }
        let provider = makeProvider(transport)
        // RFC 8058 forbids redirects, but the server received the request.
        try await provider.unsubscribe(oneClick: URL(string: "https://news.co/moved")!)
        // Server trouble is worth another try later: the outbox retries it, not the provider.
        await #expect(throws: ProviderError.server("news.co answered 503")) {
            try await provider.unsubscribe(oneClick: URL(string: "https://news.co/busy")!)
        }
        #expect(transport.calls.filter { $0.path == "/busy" }.count == 1)
        await #expect(throws: ProviderError.server("news.co answered 429")) {
            try await provider.unsubscribe(oneClick: URL(string: "https://news.co/slow-down")!)
        }
        await #expect(throws: ProviderError.rejected("news.co answered 404")) {
            try await provider.unsubscribe(oneClick: URL(string: "https://news.co/gone")!)
        }
    }

    @Test func oneClickUnsubscribeBlamesTheMacOnlyWhenItIsOffline() async throws {
        let offline = makeProvider(FakeTransport { _ in (200, "{}") }, web: FailingTransport(error: URLError(.notConnectedToInternet)))
        await #expect(throws: ProviderError.offline(URLError(.notConnectedToInternet).localizedDescription)) {
            try await offline.unsubscribe(oneClick: URL(string: "https://news.co/u")!)
        }
        for code: URLError.Code in [.cannotFindHost, .networkConnectionLost, .timedOut] {
            let failing = makeProvider(FakeTransport { _ in (200, "{}") }, web: FailingTransport(error: URLError(code)))
            await #expect(throws: ProviderError.server("news.co could not be reached")) {
                try await failing.unsubscribe(oneClick: URL(string: "https://news.co/u")!)
            }
        }
    }
}

struct FailingTransport: HTTPTransport {
    let error: URLError

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}

struct PacerTests {
    @Test func limitsRequestsInFlight() async {
        let pacer = QuotaPacer(unitsPerSecond: 10_000, burst: 10_000, maxConcurrent: 2)
        let peak = Counter()
        let current = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await pacer.enter()
                    peak.record(current.increment())
                    try? await Task.sleep(for: .milliseconds(30))
                    current.decrement()
                    await pacer.leave()
                }
            }
        }
        #expect(peak.maximum == 2)
    }

    @Test func rateLimitSlowsEveryRequestDownOncePerWindow() async throws {
        let pacer = QuotaPacer(unitsPerSecond: 100, maxRate: 250, burst: 100, maxConcurrent: 4)
        await pacer.rateLimited(retryAfter: 1, reason: "test")
        // A second report from the same burst does not halve the rate again.
        await pacer.rateLimited(retryAfter: 1, reason: "test")
        #expect(await pacer.currentLimits.unitsPerSecond == 50)
        #expect(await pacer.currentLimits.concurrent == 3)
        let clock = ContinuousClock.now
        await pacer.acquire(1)
        #expect(ContinuousClock.now - clock >= .milliseconds(900))
        // Rejections after the pause, while Gmail's minute window drains, pause again but do not halve.
        await pacer.rateLimited(retryAfter: 0.1, reason: "test")
        #expect(await pacer.currentLimits.unitsPerSecond == 50)
    }

    @Test func interactiveRequestsDoNotWaitForBulkPacing() async {
        let pacer = QuotaPacer(unitsPerSecond: 10, maxRate: 10, burst: 10, maxConcurrent: 4)
        await pacer.acquire(10, priority: .bulk)
        let clock = ContinuousClock.now
        // The bucket is empty: an archive goes now, the next download waits for the refill.
        await pacer.acquire(50, priority: .interactive)
        #expect(ContinuousClock.now - clock < .milliseconds(100))
        await pacer.acquire(1, priority: .bulk)
        #expect(ContinuousClock.now - clock >= .seconds(4))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    private var highest = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    func decrement() {
        lock.withLock { value -= 1 }
    }

    func record(_ sample: Int) {
        lock.withLock { highest = max(highest, sample) }
    }

    var maximum: Int { lock.withLock { highest } }
}

// MARK: - MIME

struct MIMETests {
    @Test func buildsAlternativesAttachmentsAndEncodedHeaders() throws {
        let message = OutgoingMessage(
            from: EmailAddress(name: "Kieran Taylor", email: "me@example.com"),
            to: [EmailAddress(name: "Zoë Ångström", email: "zoe@example.com"), EmailAddress(name: "Doe, Jane", email: "jane@example.com")],
            cc: [EmailAddress(email: "cc@example.com")], bcc: [EmailAddress(email: "hidden@example.com")],
            subject: "Café ☕ notes for the quarterly planning review with the whole team, part two",
            textBody: "Line one\nLine two with trailing space \n" + String(repeating: "long ", count: 40) + "\n= sign and é",
            htmlBody: "<p>Hello <b>world</b> — é</p>",
            references: ["<a@x>", "<b@x>"]
        )
        let pdf = Data((0..<300).map { UInt8($0 % 256) })
        let mime = MIMEBuilder.build(message, messageID: "<vimail.test@example.com>", files: [
            MIMEBuilder.File(filename: "Plan.pdf", mimeType: "application/pdf", data: pdf),
            MIMEBuilder.File(filename: "résumé.txt", mimeType: "text/plain", data: Data("hi".utf8)),
        ], date: Date(timeIntervalSince1970: 0))
        let text = String(decoding: mime, as: UTF8.self)

        // CRLF only, no line longer than 998, everything ASCII.
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 998 })
        #expect(mime.allSatisfy { $0 < 0x80 })

        let headerBlock = text.components(separatedBy: "\r\n\r\n")[0]
        #expect(headerBlock.contains("From: Kieran Taylor <me@example.com>"))
        #expect(headerBlock.contains("=?UTF-8?B?"))
        #expect(headerBlock.contains("\"Doe, Jane\" <jane@example.com>"))
        #expect(headerBlock.contains("Bcc: hidden@example.com"))
        #expect(headerBlock.contains("Message-ID: <vimail.test@example.com>"))
        #expect(headerBlock.contains("References: <a@x> <b@x>"))
        // The encoded subject decodes back to the original.
        let subjectLines = headerBlock.components(separatedBy: "\r\n").drop { !$0.hasPrefix("Subject:") }
        let subject = ([subjectLines.first!.replacingOccurrences(of: "Subject: ", with: "")] + subjectLines.dropFirst().prefix { $0.hasPrefix(" ") })
            .joined(separator: " ")
        #expect(GmailMapping.decodeHeader(subject) == message.subject)
        #expect(subject.components(separatedBy: " ").allSatisfy { $0.count <= 75 })

        #expect(text.contains("Content-Type: multipart/mixed; boundary="))
        #expect(text.contains("Content-Type: multipart/alternative; boundary="))
        #expect(text.contains("Content-Type: application/pdf; name=\"Plan.pdf\""))
        #expect(text.contains("filename*=UTF-8''r%C3%A9sum%C3%A9.txt"))
        #expect(text.contains(pdf.base64EncodedString().prefix(60)))
    }

    @Test func quotedPrintableRoundTrips() {
        let original = "Hello é ✓\nTrailing space \n" + String(repeating: "x", count: 200) + "\n=done\n\ttab"
        let encoded = MIMEBuilder.quotedPrintable(original)
        #expect(encoded.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
        #expect(decodeQuotedPrintable(encoded) == original)
    }

    func decodeQuotedPrintable(_ text: String) -> String {
        var bytes: [UInt8] = []
        let lines = text.components(separatedBy: "\r\n")
        for (index, line) in lines.enumerated() {
            var chars = Array(line.utf8)
            let soft = chars.last == UInt8(ascii: "=")
            if soft { chars.removeLast() }
            var i = 0
            while i < chars.count {
                if chars[i] == UInt8(ascii: "="), i + 2 < chars.count + 0, let value = UInt8(String(decoding: chars[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(value)
                    i += 3
                } else {
                    bytes.append(chars[i])
                    i += 1
                }
            }
            if !soft, index < lines.count - 1 { bytes.append(UInt8(ascii: "\n")) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
