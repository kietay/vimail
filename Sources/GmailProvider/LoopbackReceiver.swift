import Foundation
import Network

/// A one-shot HTTP server on 127.0.0.1 that receives Google's OAuth redirect
/// (the "loopback IP address" flow for desktop apps). It only accepts local connections,
/// answers the browser with a short page, and stops after the first redirect.
public final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.vimail.oauth-loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private var finished = false

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }

    public var port: UInt16 { listener.port?.rawValue ?? 0 }
    public var redirectURI: String { "http://127.0.0.1:\(port)" }

    /// Starts listening. Returns when the port is known.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                case .cancelled: if once.claim() { continuation.resume(throwing: GoogleOAuthError.cancelled) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to reach the redirect URI and returns the query parameters.
    public func callback(timeout: Duration) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.finish(.failure(GoogleOAuthError.timedOut)) }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                let ready: Result<[String: String], Error>? = lock.withLock {
                    if let pending { return pending }
                    self.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            finish(.failure(GoogleOAuthError.cancelled))
        }
    }

    public func stop() {
        finish(.failure(GoogleOAuthError.cancelled))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let waiting: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            if let continuation {
                self.continuation = nil
                return continuation
            }
            pending = result
            return nil
        }
        waiting?.resume(with: result)
        // Stop accepting. Connections already open still get their response.
        queue.asyncAfter(deadline: .now() + 1) { [listener] in listener.cancel() }
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: buffer[..<end.lowerBound], on: connection)
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        guard let query = Self.callbackQuery(fromRequestHead: String(decoding: head, as: UTF8.self)) else {
            // The browser also asks for /favicon.ico. Only the redirect counts.
            send(status: "404 Not Found", body: "", on: connection)
            return
        }
        send(status: "200 OK", body: Self.page(succeeded: query["code"] != nil), on: connection)
        finish(.success(query))
    }

    /// The query of a `GET /?code=…&state=…` (or `?error=…`) request, or nil for any other request.
    static func callbackQuery(fromRequestHead head: String) -> [String: String]? {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path.isEmpty || components.path == "/" else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        return query["code"] != nil || query["error"] != nil ? query : nil
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(succeeded: Bool) -> String {
        let title = succeeded ? "vimail is connected" : "Sign-in cancelled"
        let detail = succeeded ? "You can close this tab and go back to vimail." : "Nothing changed. You can close this tab."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{margin:0;height:100vh;display:grid;place-items:center;background:#1d2021;color:#ebdbb2;
        font:15px -apple-system,BlinkMacSystemFont,sans-serif}main{text-align:center}h1{font:600 20px ui-monospace,Menlo,monospace;
        color:#fe8019;margin:0 0 8px}p{color:#a89984;margin:0}</style></head>
        <body><main><h1>\(title)</h1><p>\(detail)</p></main></body></html>
        """
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
