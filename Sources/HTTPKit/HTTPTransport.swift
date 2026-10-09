import Foundation

/// Sends HTTP requests. `URLSessionTransport` in the app; tests use a scripted fake.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The transport answered with something that is not an HTTP response.
public struct NotHTTPResponse: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "No HTTP response" }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.default
        // Slow networks (plane wifi) need patience; offline is detected by URLError, not by waiting.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotHTTPResponse() }
        return (data, http)
    }
}
