// MockURLProtocol.swift — offline HTTP stubbing for McBlink tests
// Lets BlinkAPIClient be exercised without network access by injecting a
// URLSession whose protocol stack returns canned responses.

import Foundation

/// A URLProtocol that returns canned responses supplied via `setHandler`.
/// The handler is set once before a request and treated as immutable during it,
/// so the `nonisolated(unsafe)` storage is safe for test usage.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    private static let lock = NSLock()

    /// Installs the response handler. Call before issuing requests.
    static func setHandler(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        Self.handler = nil
    }

    private static func currentHandler() -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock(); defer { lock.unlock() }
        return Self.handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLSession {
    /// A session whose only protocol is `MockURLProtocol`.
    static func mocked() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Builds an HTTPURLResponse for `url` with the given status code.
func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}
