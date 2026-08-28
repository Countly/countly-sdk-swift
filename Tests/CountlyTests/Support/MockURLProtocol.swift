//
//  MockURLProtocol.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Stands in for the network in every test.
///
/// The suite asserts on what the SDK *produced*, not on what a server did with it,
/// so the default answer is a connection failure. A failed request leaves the head
/// of the queue where it is, which means a test can record something and then read
/// the exact query string the SDK built for it. Tests that need a real answer
/// install their own handler with ``respond(to:)``.
///
/// Registered through `config.urlSessionConfiguration.protocolClasses`, so it only
/// intercepts the SDK's own sessions and never the rest of the process.
final class MockURLProtocol: URLProtocol {

    /// One request the SDK sent, captured before it was answered.
    struct Captured {
        let url: URL
        let method: String
        let body: String

        /// Everything after the `?`, or the body for a POST. Every test that looks
        /// at what went over the wire reads this.
        var query: String {
            if !body.isEmpty { return body }
            return url.query ?? ""
        }

        var path: String { url.path }
    }

    /// Answers one request. Returning `nil` falls through to the default failure.
    typealias Handler = (Captured) -> (status: Int, body: Data)?

    private static let lock = NSLock()
    private static var handlers: [Handler] = []
    private static var captured: [Captured] = []

    // MARK: - Test API

    /// Installs an answer for requests this handler recognizes. Handlers are tried
    /// newest first, so a test can narrow an earlier, broader one.
    static func respond(to handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers.insert(handler, at: 0)
    }

    /// Answers every request whose path contains `pathFragment` with `json`.
    static func respond(pathContaining pathFragment: String, json: String, status: Int = 200) {
        respond { captured in
            guard captured.path.contains(pathFragment) else { return nil }
            return (status, Data(json.utf8))
        }
    }

    /// Answers every request with `json`, whatever its path.
    static func respondToEverything(json: String, status: Int = 200) {
        respond { _ in (status, Data(json.utf8)) }
    }

    /// Every request the SDK has sent since the last ``reset()``.
    static var requests: [Captured] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    /// The requests whose path contains `pathFragment`.
    static func requests(pathContaining pathFragment: String) -> [Captured] {
        requests.filter { $0.path.contains(pathFragment) }
    }

    /// Drops every handler and every captured request. Called from `setUp`.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll()
        captured.removeAll()
    }

    /// A session configuration wired to this protocol, for a config under test.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        // Nothing reaches a real server, so a short timeout only shortens the
        // failure path a test deliberately exercises.
        configuration.timeoutIntervalForRequest = 5
        return configuration
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession strips httpBody by the time the protocol sees the request, so
        // the stream is what a POST body has to be read from.
        var body = ""
        if let data = request.httpBody {
            body = String(decoding: data, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            body = MockURLProtocol.readAll(stream)
        }

        let captured = Captured(url: request.url ?? URL(string: "about:blank")!,
                                method: request.httpMethod ?? "GET",
                                body: body)

        MockURLProtocol.lock.lock()
        MockURLProtocol.captured.append(captured)
        let handlers = MockURLProtocol.handlers
        MockURLProtocol.lock.unlock()

        for handler in handlers {
            guard let (status, data) = handler(captured) else { continue }
            let response = HTTPURLResponse(url: captured.url,
                                           statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // No handler claimed it: report a connection failure, which is what leaves
        // the request at the head of the queue for the test to inspect.
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> String {
        stream.open()
        defer { stream.close() }

        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
