//
//  RequestCompressionTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Request compression, against the mock transport answering the way the Countly
/// server does: a body is read as gzip only when the compression marker is the
/// only query of the URL. Each settings answer carries its own `lkl` value, so a
/// test can wait until the SDK has read it.
final class RequestCompressionTests: CountlyBaseTestCase {

    private static let marker = "content_encoding=gzip"
    private static let big = 5000

    // MARK: - The server

    /// One request as the server read it.
    private struct Sent {
        let captured: MockURLProtocol.Captured
        let isCompressed: Bool
        let body: String

        var parameters: [String: Any] { TestUtils.parseQuery(body) }
        var marker: String? { parameters["marker"] as? String }
    }

    /// What the server answers. Read on the transport's thread, so the state is
    /// behind a lock.
    private final class Server {
        struct State {
            var lkl = 100
            var gzip = true
            var refuseCompressed = 0
            var refusal = (status: 400, body: "{\"result\":\"Invalid request body\"}")
            var failCompressed = false
            var failSettingsOfHost: String?
        }

        private let lock = NSLock()
        private var state = State()

        func set(_ change: (inout State) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            change(&state)
        }

        var current: State {
            lock.lock()
            defer { lock.unlock() }
            return state
        }

        /// The answer a compressed request is refused with, while refusals are left.
        func takeRefusal() -> (status: Int, body: String)? {
            lock.lock()
            defer { lock.unlock() }
            guard state.refuseCompressed > 0 else { return nil }
            state.refuseCompressed -= 1
            return state.refusal
        }

        var settingsAnswer: String {
            let answer = current
            return "{\"v\":1,\"t\":1,\"c\":{\"lkl\":\(answer.lkl)}" + (answer.gzip ? ",\"gzip\":true}" : "}")
        }
    }

    private func read(_ captured: MockURLProtocol.Captured) -> Sent {
        let isCompressed = captured.url.query == Self.marker
        let body = isCompressed ? Self.gunzip(captured.bodyData).map { String(decoding: $0, as: UTF8.self) } ?? "" : captured.body
        return Sent(captured: captured, isCompressed: isCompressed, body: body)
    }

    private func sent(_ marker: String) -> [Sent] {
        MockURLProtocol.requests.map(read).filter { $0.marker == marker }
    }

    private var settingsRequests: [Sent] {
        MockURLProtocol.requests.map(read).filter { ($0.parameters["method"] as? String) == "sc" }
    }

    /// Answers the settings requests, refuses or fails compressed requests while
    /// told to, and accepts everything else.
    private func install(_ server: Server) {
        MockURLProtocol.fail { [weak self] captured in
            guard let self else { return nil }
            let sent = self.read(captured)
            if (sent.parameters["method"] as? String) == "sc", captured.url.host == server.current.failSettingsOfHost {
                return .notConnectedToInternet
            }
            return sent.isCompressed && server.current.failCompressed ? .timedOut : nil
        }
        MockURLProtocol.respond { [weak self] captured in
            guard let self else { return nil }
            let sent = self.read(captured)
            if (sent.parameters["method"] as? String) == "sc" {
                return (200, Data(server.settingsAnswer.utf8))
            }
            if sent.isCompressed, let refusal = server.takeRefusal() {
                return (refusal.status, Data(refusal.body.utf8))
            }
            return (200, Data("{\"result\":\"Success\"}".utf8))
        }
    }

    /// Starts an instance against `server` and waits until it has read the first
    /// settings answer.
    @discardableResult
    private func start(_ server: Server, compression: Bool, adjust: (CountlyConfig) -> Void = { _ in }) -> CountlyInstance {
        install(server)
        let instance = startInstance {
            $0.enableRequestCompression = compression
            // the base config turns the cool-down off, which leaves a retry to the next timer tick a minute later
            $0.failedRequestCooldown = 1
            adjust($0)
        }
        let lkl = server.current.lkl
        TestUtils.waitUntil("the settings answer is read") { self.core(of: instance).serverConfig.limitKeyLength == lkl }
        return instance
    }

    /// A request the server did not get as often as the test waited for.
    private struct RequestDidNotArrive: Error {
        let marker: String
        let times: Int
    }

    /// Queues a request with a payload of `length` characters, told apart by its
    /// marker parameter, waits until the server got it as often as `times`, and
    /// returns every copy the server got. Throws when fewer copies arrived.
    @discardableResult
    private func send(_ marker: String, _ length: Int, on instance: CountlyInstance, times: Int = 1) throws -> [Sent] {
        let network: ConnectionManager = core(of: instance).network
        network.enqueueAndProceed(network.builder.queryEssentials() + "&marker=\(marker)&payload=" + String(repeating: "a", count: length))
        TestUtils.waitUntil("the request \(marker) arrives \(times) times") { self.sent(marker).count >= times }
        let copies = sent(marker)
        guard copies.count >= times else { throw RequestDidNotArrive(marker: marker, times: times) }
        return copies
    }

    /// Fetches the settings again, as the refresh timer does, answered with `lkl`.
    private func fetchSettings(_ server: Server, lkl: Int, gzip: Bool, on instance: CountlyInstance) {
        server.set {
            $0.lkl = lkl
            $0.gzip = gzip
        }
        let sdk = self.core(of: instance)
        sdk.serverConfig.fetch(config: sdk.config)
        TestUtils.waitUntil("the settings answer with lkl \(lkl) is read") { sdk.serverConfig.limitKeyLength == lkl }
    }

    // MARK: - Flows

    func test_compressionOff_settingsRequestDoesNotAsk_requestsArePlain() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        let instance = start(server, compression: false)

        let big = try send("big", Self.big, on: instance)

        XCTAssertNil(settingsRequests.first?.parameters["gzip"])
        XCTAssertFalse(big[0].isCompressed)
        XCTAssertEqual((big[0].parameters["payload"] as? String)?.count, Self.big)
    }

    func test_compressionOn_serverReadsGzip_bigRequestIsCompressed_withThePlainChecksum() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        let instance = start(server, compression: true) { $0.secretSalt = "gzip-salt" }

        let big = try send("big", Self.big, on: instance)[0]

        XCTAssertEqual(TestUtils.int(settingsRequests.first?.parameters["gzip"]), 1)
        XCTAssertTrue(big.isCompressed)
        XCTAssertEqual(big.captured.path, "/i")
        XCTAssertLessThan(big.captured.bodyData.count, 1000)
        XCTAssertEqual(big.captured.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertNil(big.captured.headers["Content-Encoding"])
        XCTAssertEqual(big.parameters["payload"] as? String, String(repeating: "a", count: Self.big))
        let parts = big.body.components(separatedBy: "&checksum256=")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual((parts[0] + "gzip-salt").sha256Hex, parts[1])
    }

    func test_compressionOn_smallRequestStaysPlain_biggerOneIsCompressed() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        let instance = start(server, compression: true)

        let small = try send("small", 300, on: instance)[0]
        let big = try send("big", Self.big, on: instance)[0]

        XCTAssertFalse(small.isCompressed)
        XCTAssertLessThan(small.captured.bodyData.count, 1024)
        XCTAssertTrue(big.isCompressed)
    }

    func test_compressionOn_answerWithoutGzip_requestsArePlain() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        server.set { $0.gzip = false }
        let instance = start(server, compression: true)

        let big = try send("big", Self.big, on: instance)[0]

        XCTAssertEqual(TestUtils.int(settingsRequests.first?.parameters["gzip"]), 1)
        XCTAssertFalse(big.isCompressed)
    }

    func test_compressionOn_bodyOverOneMegabyteStaysPlain_compressionStaysOn() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        let instance = start(server, compression: true)

        let huge = try send("huge", ConnectionManager.compressionMaxBytes, on: instance)[0]
        let big = try send("big", Self.big, on: instance)[0]

        XCTAssertFalse(huge.isCompressed)
        XCTAssertGreaterThan(huge.captured.bodyData.count, ConnectionManager.compressionMaxBytes)
        XCTAssertTrue(big.isCompressed)
    }

    func test_compressedRequestRefused_retryAndLaterRequestsArePlain() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        server.set { $0.refuseCompressed = 1 }
        let instance = start(server, compression: true)

        let refused = try send("refused", Self.big, on: instance, times: 2)
        let after = try send("after", Self.big, on: instance)[0]

        XCTAssertEqual(refused.map(\.isCompressed), [true, false])
        XCTAssertEqual(refused[0].parameters["payload"] as? String, refused[1].parameters["payload"] as? String)
        XCTAssertFalse(after.isCompressed)
    }

    func test_compressedRequestAnsweredWithoutResult_stopsCompression() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        server.set {
            $0.refuseCompressed = 1
            $0.refusal = (200, "{}")
        }
        let instance = start(server, compression: true)

        let answered = try send("no_result", Self.big, on: instance, times: 2)

        XCTAssertEqual(answered.map(\.isCompressed), [true, false])
    }

    func test_compressedRequestRefused_nextGzipAnswerTurnsCompressionOnAgain() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        server.set { $0.refuseCompressed = 1 }
        let instance = start(server, compression: true)
        try send("refused", Self.big, on: instance, times: 2)

        fetchSettings(server, lkl: 101, gzip: false, on: instance)
        let withoutGzipAnswer = try send("without_gzip_answer", Self.big, on: instance)[0]
        fetchSettings(server, lkl: 102, gzip: true, on: instance)
        let withGzipAnswer = try send("with_gzip_answer", Self.big, on: instance)[0]

        XCTAssertEqual(settingsRequests.compactMap { TestUtils.int($0.parameters["gzip"]) }, [1, 1, 1])
        XCTAssertFalse(withoutGzipAnswer.isCompressed)
        XCTAssertTrue(withGzipAnswer.isCompressed)
    }

    func test_compressedInstantRequestAnsweredWithJSON_compressionStaysOn() throws {
        try skipUnlessNetworkIsInterceptable()
        XCTAssertTrue(try instantRequestKeepsCompression(status: 200, body: "{\"color\":\"red\"}"))
    }

    func test_compressedInstantRequestAnsweredWithPage_stopsCompression() throws {
        try skipUnlessNetworkIsInterceptable()
        XCTAssertFalse(try instantRequestKeepsCompression(status: 200, body: "<html><body>Bad gateway</body></html>"))
    }

    func test_compressedInstantRequestAnsweredWithNothing_stopsCompression() throws {
        try skipUnlessNetworkIsInterceptable()
        XCTAssertFalse(try instantRequestKeepsCompression(status: 200, body: ""))
    }

    func test_compressedInstantRequestAnsweredWithError_stopsCompression() throws {
        try skipUnlessNetworkIsInterceptable()
        XCTAssertFalse(try instantRequestKeepsCompression(status: 400, body: "{\"result\":\"Invalid request body\"}"))
    }

    func test_compressedRequestWithoutAnswer_compressionStaysOn() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        server.set { $0.failCompressed = true }
        let instance = start(server, compression: true)

        let network: ConnectionManager = core(of: instance).network
        network.enqueueAndProceed(network.builder.queryEssentials() + "&marker=dropped&payload=" + String(repeating: "a", count: Self.big))
        TestUtils.waitUntil("a compressed attempt fails") { !self.sent("dropped").isEmpty }
        server.set { $0.failCompressed = false }
        network.proceedOnQueue()
        TestUtils.waitUntil("the request is delivered") { self.requestQueue(of: instance).isEmpty }

        let dropped = sent("dropped")
        XCTAssertGreaterThanOrEqual(dropped.count, 2)
        XCTAssertTrue(dropped.allSatisfy(\.isCompressed))
    }

    func test_gzipAnswer_isNotStored() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        let instance = start(server, compression: true)

        // the SDK stores the answer only after it has applied the settings start() waits for
        let store = core(of: instance).keyValueStore
        TestUtils.waitUntil("the settings answer is stored") { store.serverConfig != nil }
        let stored = try XCTUnwrap(store.serverConfig)
        XCTAssertNotNil(stored["c"])
        XCTAssertNil(stored["gzip"])
    }

    func test_newHost_getsPlainRequestsUntilItSaysGzip() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        server.set { $0.failSettingsOfHost = "other.count.ly" }
        let instance = start(server, compression: true)

        instance.setNewHost("https://other.count.ly")
        TestUtils.waitUntil("the new host is asked for its settings") { self.settingsRequests.contains { $0.captured.url.host == "other.count.ly" } }
        let beforeAnswer = try send("before_answer", Self.big, on: instance)[0]
        server.set { $0.failSettingsOfHost = nil }
        fetchSettings(server, lkl: 101, gzip: true, on: instance)
        let afterAnswer = try send("after_answer", Self.big, on: instance)[0]

        XCTAssertEqual(beforeAnswer.captured.url.host, "other.count.ly")
        XCTAssertFalse(beforeAnswer.isCompressed)
        XCTAssertEqual(afterAnswer.captured.url.host, "other.count.ly")
        XCTAssertTrue(afterAnswer.isCompressed)
    }

    func test_compressIfAllowed_onlyFormPostsBetweenTheBoundsWithoutQuery() throws {
        try skipUnlessNetworkIsInterceptable()
        let server = Server()
        let instance = start(server, compression: true)
        let network: ConnectionManager = core(of: instance).network

        func request(_ url: String, method: String = "POST", contentType: String = "application/x-www-form-urlencoded", length: Int = Self.big) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = method
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(String(repeating: "a", count: length).utf8)
            return request
        }

        var allowed = request(CountlyBaseTestCase.host + "/i")
        XCTAssertTrue(network.compressIfAllowed(&allowed))
        XCTAssertEqual(allowed.url?.absoluteString, CountlyBaseTestCase.host + "/i?" + Self.marker)
        XCTAssertEqual(Self.gunzip(try XCTUnwrap(allowed.httpBody)), Data(String(repeating: "a", count: Self.big).utf8))

        for (description, refused) in [
            ("a GET", request(CountlyBaseTestCase.host + "/i", method: "GET")),
            ("a URL with a query", request(CountlyBaseTestCase.host + "/o/sdk?method=rc")),
            ("a multipart body", request(CountlyBaseTestCase.host + "/i", contentType: "multipart/form-data; boundary=x")),
            ("a body under 1 KB", request(CountlyBaseTestCase.host + "/i", length: ConnectionManager.compressionMinBytes - 1)),
            ("a body over 1 MB", request(CountlyBaseTestCase.host + "/i", length: ConnectionManager.compressionMaxBytes + 1)),
        ] {
            var copy = refused
            XCTAssertFalse(network.compressIfAllowed(&copy), description)
            XCTAssertEqual(copy, refused, description)
        }
    }

    // MARK: - The encoder

    func test_crc32_matchesTheStandardCheckValue() {
        XCTAssertEqual(Data("123456789".utf8).crc32, 0xCBF4_3926)
        XCTAssertEqual(Data().crc32, 0)
    }

    func test_gunzipHelper_readsGzipFromAnotherEncoder() throws {
        // "countly " 64 times, compressed by Node.js zlib.gzipSync
        let other = try XCTUnwrap(Data(base64Encoded: "H4sIAAAAAAAACkvOL80ryalUSB6lRyQNAAmgxRMAAgAA"))
        XCTAssertEqual(Self.gunzip(other), Data(String(repeating: "countly ", count: 64).utf8))
    }

    func test_gzipCompressed_isGzipThatDecodesToTheInput() throws {
        let plain = Data(("app_key=key&payload=" + String(repeating: "a", count: 2000)).utf8)
        let compressed = try XCTUnwrap(plain.gzipCompressed())

        XCTAssertEqual(Array(compressed.prefix(3)), [0x1f, 0x8b, 0x08])
        XCTAssertLessThan(compressed.count, plain.count)
        XCTAssertEqual(Self.gunzip(compressed), plain)
    }

    func test_isAcceptedInstantAnswer_onlyTwoHundredsWithJSON() {
        func answer(_ status: Int, _ body: String) -> Bool {
            let response = HTTPURLResponse(url: URL(string: CountlyBaseTestCase.host)!, statusCode: status, httpVersion: nil, headerFields: nil)
            return ConnectionManager.isAcceptedInstantAnswer(response: response, data: Data(body.utf8))
        }
        XCTAssertTrue(answer(200, "{\"a\":1}"))
        XCTAssertTrue(answer(204, "[1]"))
        XCTAssertFalse(answer(400, "{\"result\":\"x\"}"))
        XCTAssertFalse(answer(200, "<html></html>"))
        XCTAssertFalse(answer(200, ""))
        XCTAssertFalse(answer(200, "\"text\""))
        XCTAssertFalse(ConnectionManager.isAcceptedInstantAnswer(response: nil, data: nil))
    }

    // MARK: - Helpers

    /// Sends a big request that skips the queue, answered with `status` and
    /// `body`, then tells whether a big queued request after it was compressed.
    private func instantRequestKeepsCompression(status: Int, body: String) throws -> Bool {
        let server = Server()
        let instance = start(server, compression: true)
        // installed last, so it is tried before the server's own answers
        MockURLProtocol.respond { [weak self] captured in
            guard let self, self.read(captured).marker == "instant" else { return nil }
            return (status, Data(body.utf8))
        }
        let network: ConnectionManager = core(of: instance).network

        let query = network.builder.finishImmediateRequest(network.builder.queryEssentials() + "&method=rc&marker=instant&payload=" + String(repeating: "a", count: Self.big))
        let answered = expectation(description: "the instant request is answered")
        let task = try XCTUnwrap(network.instantTask(with: network.instantRequest(queryString: query, path: Endpoint.output + Endpoint.sdk)) { _, _, _ in
            answered.fulfill()
        })
        task.resume()
        wait(for: [answered], timeout: TestUtils.asyncTimeout)

        let instant = try XCTUnwrap(sent("instant").first)
        XCTAssertTrue(instant.isCompressed)
        XCTAssertEqual(instant.captured.path, "/o/sdk")
        return try send("after_instant", Self.big, on: instance)[0].isCompressed
    }

    /// Decodes a gzip stream the way a gzip reader does: checks the header,
    /// inflates the raw DEFLATE data and checks the CRC-32 and size trailer.
    private static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08, bytes[3] == 0 else { return nil }
        let deflated = Data(bytes[10..<(bytes.count - 8)])
        guard let plain = try? (deflated as NSData).decompressed(using: .zlib) as Data else { return nil }
        let trailer = Array(bytes[(bytes.count - 8)...])
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        guard crc == plain.crc32, size == UInt32(truncatingIfNeeded: plain.count) else { return nil }
        return plain
    }
}
