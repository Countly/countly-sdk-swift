//
//  ConnectionTestTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// The server armed connection test: the trigger on a live `ct`, the probe
/// battery, grading, the combined rows, the report shape and its caps, and what
/// must never happen: persisting `ct`, probing while networking is off, two
/// batteries at once, a report from a halted instance.
final class ConnectionTestTests: CountlyBaseTestCase {

    private let expectedFeatures = ["core", "core-write", "sc", "rc", "ab", "feedback", "feedback-widget",
                                    "feedback-submit", "content", "feedback-page", "feedback-assets", "content-page"]

    private let expectedProbePaths = [
        "/o/ping", "/i", "/o/sdk?method=rc", "/o/sdk?method=ab_fetch_variants", "/o/sdk?method=feedback",
        "/o/surveys/nps/widget", "/o/surveys/survey/widget", "/o/feedback/widget", "/i/feedback/inputs", "/o/sdk/content",
        "/feedback/nps", "/feedback/survey", "/feedback/rating",
        "/surveys/images/ct-probe.png", "/star-rating/images/ct-probe.png", "/_external/content/",
    ]

    // MARK: - Helpers

    private func isProbe(_ captured: MockURLProtocol.Captured) -> Bool {
        captured.query.contains("ct=1") && !captured.query.contains("app_key=")
    }

    /// Path plus query of a probe, without the marker and cache buster the SDK
    /// appends. Taken from the raw string: `URL.path` would drop the trailing
    /// slash of `/_external/content/`.
    private func probePath(_ captured: MockURLProtocol.Captured) -> String {
        let absolute = captured.url.absoluteString
        guard let host = captured.url.host, let hostRange = absolute.range(of: host) else { return "" }
        var path = String(absolute[hostRange.upperBound...])
        if let queryStart = path.firstIndex(of: "?") {
            let query = String(path[path.index(after: queryStart)...])
            path = String(path[..<queryStart])
            let kept = query.split(separator: "&").filter { !$0.hasPrefix("ct=") && !$0.hasPrefix("_=") }
            if !kept.isEmpty { path += "?" + kept.joined(separator: "&") }
        }
        return path
    }

    private func probes() -> [MockURLProtocol.Captured] {
        MockURLProtocol.requests.filter(isProbe)
    }

    /// Answers the behavior settings fetch with `scResponse`, answers probes from
    /// the status table (400 by default, 200 on the strict rows), fails the listed
    /// probes with a transport error, and leaves every queued request failing so
    /// it stays in the queue.
    private func installHandler(scResponse: String,
                                probeStatus: [String: Int] = [:],
                                probeErrors: [String: URLError.Code] = [:],
                                probeDelay: TimeInterval = 0) {
        MockURLProtocol.fail { [self] captured in
            guard isProbe(captured) else { return nil }
            return probeErrors[probePath(captured)]
        }
        MockURLProtocol.respond { [self] captured in
            if captured.path.contains("/o/sdk"), captured.query.contains("method=sc") {
                return (200, Data(scResponse.utf8))
            }
            guard isProbe(captured) else { return nil }
            if probeDelay > 0 { Thread.sleep(forTimeInterval: probeDelay) }
            let path = probePath(captured)
            let healthy = path == "/o/ping" || path.hasSuffix(".png") || path.hasPrefix("/_external") ? 200 : 400
            return (probeStatus[path] ?? healthy, Data("{}".utf8))
        }
    }

    private func armedResponse(networking: Bool = true) -> String {
        ServerConfigBuilder().networking(networking).armConnectionTest().json()
    }

    private func module(of instance: CountlyInstance) -> ConnectionTestModule {
        core(of: instance).modules.connectionTest
    }

    /// The decoded `ct_results` reports in the request queue, in order.
    private func queuedReports(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance).map(TestUtils.parseQuery).compactMap { $0["ct_results"] as? [String: Any] }
    }

    /// Waits until the behavior settings fetch was answered, which is the moment a
    /// live `ct` would have armed the battery.
    private func waitForBehaviorSettingsFetch() {
        TestUtils.waitUntil("the behavior settings fetch is answered") {
            MockURLProtocol.requests.contains { $0.query.contains("method=sc") }
        }
    }

    private func waitForReport(of instance: CountlyInstance) -> [String: Any]? {
        TestUtils.waitUntil("a ct_results report reaches the request queue") { !queuedReports(of: instance).isEmpty }
        return queuedReports(of: instance).first
    }

    private func rows(_ report: [String: Any]) -> [[String: Any]] {
        (report["results"] as? [[String: Any]]) ?? []
    }

    private func row(_ report: [String: Any], _ feature: String) -> [String: Any]? {
        rows(report).first { ($0["f"] as? String) == feature }
    }

    /// A transport that answers every probe with one status and never touches the
    /// network, for the battery mechanics.
    private final class CannedTransport: ProbeTransport {
        let status: Int
        let delay: TimeInterval
        private let lock = NSLock()
        private var _urls: [URL] = []

        init(status: Int, delay: TimeInterval = 0) {
            self.status = status
            self.delay = delay
        }

        var urls: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return _urls
        }

        func probe(_ url: URL, timeout: TimeInterval) -> ConnectionTestModule.ProbeOutcome {
            lock.lock()
            _urls.append(url)
            lock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return ConnectionTestModule.ProbeOutcome(status: status, latencyMs: Int64(delay * 1000), failure: nil)
        }

        func batteryFinished() {}
    }

    // MARK: - Battery and report

    func testAnArmedLiveResponseProbesEveryRowAndQueuesOneReportInOrder() throws {
        try skipUnlessNetworkIsInterceptable()
        installHandler(scResponse: armedResponse())
        let countly = startInstance()

        let report = try XCTUnwrap(waitForReport(of: countly), "no ct_results reached the request queue")

        // One report, every row, in spec order, with the SDK identity.
        XCTAssertEqual(queuedReports(of: countly).count, 1)
        XCTAssertEqual(rows(report).compactMap { $0["f"] as? String }, expectedFeatures)
        XCTAssertEqual((report["sdk"] as? [String: Any])?["name"] as? String, SDKIdentity.name)
        XCTAssertEqual((report["sdk"] as? [String: Any])?["version"] as? String, SDKIdentity.version)
        XCTAssertGreaterThan(TestUtils.int64(report["ts"]) ?? 0, 1_600_000_000_000)

        // 16 parameterless GETs, marker and cache buster on each, host path joined once.
        let probes = probes()
        XCTAssertEqual(probes.map(probePath), expectedProbePaths)
        for probe in probes {
            let url = probe.url.absoluteString
            XCTAssertEqual(probe.method, "GET")
            XCTAssertTrue(probe.body.isEmpty)
            XCTAssertFalse(url.contains("app_key="), url)
            XCTAssertFalse(url.contains("device_id="), url)
            XCTAssertTrue(url.contains("ct=1"), url)
            XCTAssertTrue(url.contains("&_="), url)
            XCTAssertTrue(url.hasPrefix("\(Self.host)/"), url)
            XCTAssertFalse(url.contains("ly//"), url)
        }

        // Healthy grading: 400 is reachable, the two strict rows saw their 200.
        for row in rows(report) {
            XCTAssertEqual(row["ok"] as? Bool, true, "\(row)")
            XCTAssertNil(row["e"], "\(row)")
        }
        XCTAssertEqual(TestUtils.int(row(report, "core")?["st"]), 200)
        XCTAssertEqual(TestUtils.int(row(report, "core-write")?["st"]), 400)
        XCTAssertEqual(TestUtils.int(row(report, "feedback-assets")?["st"]), 200)

        // The sc row carries the latency of the fetch that delivered the flag.
        let sc = try XCTUnwrap(row(report, "sc"))
        XCTAssertEqual(TestUtils.int(sc["st"]), 200)
        XCTAssertGreaterThanOrEqual(TestUtils.int(sc["ms"]) ?? -1, 0)

        // Path counts only on the combined rows.
        XCTAssertEqual(TestUtils.int(row(report, "feedback-widget")?["n"]), 3)
        XCTAssertEqual(TestUtils.int(row(report, "feedback-page")?["n"]), 3)
        XCTAssertEqual(TestUtils.int(row(report, "feedback-assets")?["n"]), 2)
        XCTAssertNil(row(report, "core")?["n"])
        XCTAssertNil(row(report, "rc")?["n"])

        // Its own queue entry, with the base parameters, and nothing persisted.
        let request = try XCTUnwrap(TestUtils.requests(requestQueue(of: countly), carrying: "ct_results").first)
        TestUtils.assertBaseParameters(request)
        XCTAssertFalse(module(of: countly).isBatteryRunning)
    }

    func testFaultyEndpointsAreGradedPerSpec() throws {
        try skipUnlessNetworkIsInterceptable()
        installHandler(scResponse: armedResponse(),
                       probeStatus: [
                           "/o/ping": 404,                          // strict row, a 404 is the DB being down
                           "/o/sdk?method=rc": 403,                 // proxy allowlist
                           "/o/sdk/content": 302,                   // captive portal
                           "/o/surveys/survey/widget": 500,         // second path of a combined row
                           "/o/feedback/widget": 404,               // widget not found is still the application answering
                           "/star-rating/images/ct-probe.png": 404,
                       ],
                       probeErrors: [
                           "/o/sdk?method=ab_fetch_variants": .timedOut,
                           "/i/feedback/inputs": .cannotConnectToHost,
                       ])
        let countly = startInstance()

        let report = try XCTUnwrap(waitForReport(of: countly))

        let core = try XCTUnwrap(row(report, "core"))
        XCTAssertEqual(core["ok"] as? Bool, false)
        XCTAssertEqual(TestUtils.int(core["st"]), 404)
        XCTAssertEqual(core["e"] as? String, "HTTP 404")

        XCTAssertEqual(row(report, "rc")?["e"] as? String, "HTTP 403")
        XCTAssertEqual(TestUtils.int(row(report, "rc")?["st"]), 403)

        XCTAssertEqual(row(report, "content")?["e"] as? String, "redirected")
        XCTAssertEqual(TestUtils.int(row(report, "content")?["st"]), 302)

        let ab = try XCTUnwrap(row(report, "ab"))
        XCTAssertEqual(ab["e"] as? String, "timeout")
        XCTAssertEqual(TestUtils.int(ab["st"]), 0)
        XCTAssertEqual(ab["ok"] as? Bool, false)

        XCTAssertEqual(row(report, "feedback-submit")?["e"] as? String, "transport error")
        XCTAssertEqual(TestUtils.int(row(report, "feedback-submit")?["st"]), 0)

        // Combined row: the first failing path decides status and reason, the 404
        // on the third path is fine.
        let widget = try XCTUnwrap(row(report, "feedback-widget"))
        XCTAssertEqual(widget["ok"] as? Bool, false)
        XCTAssertEqual(TestUtils.int(widget["st"]), 500)
        XCTAssertEqual(widget["e"] as? String, "HTTP 500")
        XCTAssertEqual(TestUtils.int(widget["n"]), 3)

        // Strict combined row: anything but 2xx on any path fails it.
        let assets = try XCTUnwrap(row(report, "feedback-assets"))
        XCTAssertEqual(assets["ok"] as? Bool, false)
        XCTAssertEqual(TestUtils.int(assets["st"]), 404)
        XCTAssertEqual(assets["e"] as? String, "HTTP 404")

        // Untouched rows stay green.
        XCTAssertEqual(row(report, "feedback")?["ok"] as? Bool, true)
        XCTAssertEqual(row(report, "content-page")?["ok"] as? Bool, true)
    }

    func testCtIsStrippedBeforeCachingAndNeverReadFromStorage() throws {
        try skipUnlessNetworkIsInterceptable()
        installHandler(scResponse: armedResponse())
        let name = uniqueInstanceName()
        let first = start(baseConfig(instanceName: name))
        _ = try XCTUnwrap(waitForReport(of: first))

        let stored = core(of: first).keyValueStore.serverConfig
        XCTAssertNotNil(stored?["c"], "the config itself must still be cached")
        XCTAssertNil(stored?["ct"], "the flag must never survive into storage")
        // Wiped, so the persisted report of the first run cannot be mistaken for a
        // second one.
        first.halt(clearStorage: true)

        // A stored flag, even if one got there somehow, must not arm anything on
        // the next start, and neither must a developer supplied one.
        let store = KeyValueStore(namespace: StorageNamespace(instanceName: name), logger: nil)
        store.serverConfig = ServerConfigBuilder().armConnectionTest().document()
        MockURLProtocol.reset()
        installHandler(scResponse: ServerConfigBuilder().json())

        let config = baseConfig(instanceName: name)
        config.sdkBehaviorSettings = ServerConfigBuilder().armConnectionTest().json()
        let second = start(config)
        waitForBehaviorSettingsFetch()
        TestUtils.pump(0.5)

        XCTAssertTrue(probes().isEmpty, "the battery ran from stored config: \(probes().map(probePath))")
        XCTAssertTrue(queuedReports(of: second).isEmpty)
        XCTAssertNil(core(of: second).keyValueStore.serverConfig?["ct"])
    }

    func testNetworkingDisabledByBehaviorSettingsSkipsTheBattery() throws {
        try skipUnlessNetworkIsInterceptable()
        installHandler(scResponse: armedResponse(networking: false))
        let countly = startInstance()

        TestUtils.waitUntil("the armed response lands") { !core(of: countly).serverConfig.networkingEnabled }
        TestUtils.pump(0.5)

        XCTAssertTrue(probes().isEmpty, "the operator's own kill switch outranks the test")
        XCTAssertTrue(queuedReports(of: countly).isEmpty)
        XCTAssertFalse(module(of: countly).isBatteryRunning)
    }

    func testASecondDeliveryWhileABatteryRunsIsIgnored() throws {
        try skipUnlessNetworkIsInterceptable()
        installHandler(scResponse: armedResponse(), probeDelay: 0.1)
        let countly = startInstance()

        TestUtils.waitUntil("the battery is running") { module(of: countly).isBatteryRunning }
        module(of: countly).startBattery(serverConfigLatencyMs: 5)
        module(of: countly).startBattery(serverConfigLatencyMs: 5)

        _ = try XCTUnwrap(waitForReport(of: countly))
        TestUtils.waitUntil("the battery finished") { !module(of: countly).isBatteryRunning }
        TestUtils.pump(0.3)

        XCTAssertEqual(queuedReports(of: countly).count, 1, "each delivery during a running battery must be dropped, not queued")
        XCTAssertEqual(probes().count, expectedProbePaths.count)
    }

    func testProbesCarryTheSDKCustomHeaders() throws {
        try skipUnlessNetworkIsInterceptable()
        installHandler(scResponse: armedResponse())
        let countly = startInstance { $0.customNetworkRequestHeaders = ["X-Gateway-Token": "abc123"] }
        _ = try XCTUnwrap(waitForReport(of: countly))

        let probes = probes()
        XCTAssertFalse(probes.isEmpty)
        for probe in probes {
            XCTAssertEqual(probe.headers["X-Gateway-Token"], "abc123", "a header checking gateway would report a healthy server as unreachable")
        }
    }

    func testAHaltDuringTheBatteryDropsTheReport() throws {
        try skipUnlessNetworkIsInterceptable()
        installHandler(scResponse: armedResponse(), probeDelay: 0.1)
        let countly = startInstance()
        let module = module(of: countly)
        TestUtils.waitUntil("the battery is running") { module.isBatteryRunning }

        countly.halt()

        TestUtils.waitUntil("the battery notices the halt") { !module.isBatteryRunning }
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.query.contains("ct_results=") }, "a halted instance queued into a torn down queue")
        XCTAssertLessThan(probes().count, expectedProbePaths.count, "probing stops at the next row boundary")
    }

    func testTheBatteryCapMarksUnreachedRowsAsNotRun() throws {
        try skipUnlessNetworkIsInterceptable()
        installHandler(scResponse: ServerConfigBuilder().json())
        let countly = startInstance()
        waitForBehaviorSettingsFetch()

        let module = module(of: countly)
        // 16 x 1 s minus 15.5 s: a cap of half a second, with probes that take 0.2 s.
        module.perRequestTimeout = 1
        module.batteryCapExtra = -15.5
        module.transport = CannedTransport(status: 200, delay: 0.2)
        module.startBattery(serverConfigLatencyMs: 12)

        let report = try XCTUnwrap(waitForReport(of: countly))
        let rows = rows(report)
        XCTAssertEqual(rows.count, expectedFeatures.count, "every row is reported, reached or not")
        XCTAssertEqual(rows.first?["ok"] as? Bool, true)
        XCTAssertEqual(TestUtils.int(row(report, "sc")?["ms"]), 12, "the sc row needs no probe and is never capped")

        let notRun = rows.filter { ($0["e"] as? String) == "not run: battery cap" }
        XCTAssertFalse(notRun.isEmpty)
        XCTAssertEqual(rows.last?["e"] as? String, "not run: battery cap")
        for row in notRun {
            XCTAssertEqual(row["ok"] as? Bool, false)
            XCTAssertEqual(TestUtils.int(row["st"]), 0)
            XCTAssertEqual(TestUtils.int(row["ms"]), 0)
        }
    }

    func testEachArmedInstanceRunsAndReportsOnItsOwn() throws {
        try skipUnlessNetworkIsInterceptable()
        installHandler(scResponse: armedResponse())
        let first = startInstance()
        let second = startInstance { $0.deviceID = "other-device" }

        _ = try XCTUnwrap(waitForReport(of: first))
        _ = try XCTUnwrap(waitForReport(of: second))
        TestUtils.pump(0.3)

        XCTAssertEqual(queuedReports(of: first).count, 1)
        XCTAssertEqual(queuedReports(of: second).count, 1)
        XCTAssertEqual(probes().count, expectedProbePaths.count * 2)
        let secondRequest = try XCTUnwrap(TestUtils.requests(requestQueue(of: second), carrying: "ct_results").first)
        TestUtils.assertBaseParameters(secondRequest, deviceID: "other-device")
    }

    // MARK: - Pure pieces

    func testGradingFollowsTheSpecTable() {
        XCTAssertNil(ConnectionTestModule.grade(status: 200, failure: nil, requiresSuccessStatus: false))
        XCTAssertNil(ConnectionTestModule.grade(status: 400, failure: nil, requiresSuccessStatus: false))
        XCTAssertNil(ConnectionTestModule.grade(status: 404, failure: nil, requiresSuccessStatus: false))
        XCTAssertEqual(ConnectionTestModule.grade(status: 403, failure: nil, requiresSuccessStatus: false), "HTTP 403")
        XCTAssertEqual(ConnectionTestModule.grade(status: 502, failure: nil, requiresSuccessStatus: false), "HTTP 502")
        XCTAssertEqual(ConnectionTestModule.grade(status: 301, failure: nil, requiresSuccessStatus: false), "redirected")
        XCTAssertEqual(ConnectionTestModule.grade(status: 0, failure: "timeout", requiresSuccessStatus: false), "timeout")
        XCTAssertEqual(ConnectionTestModule.grade(status: 0, failure: nil, requiresSuccessStatus: false), "transport error")
        // Strict rows.
        XCTAssertNil(ConnectionTestModule.grade(status: 204, failure: nil, requiresSuccessStatus: true))
        XCTAssertEqual(ConnectionTestModule.grade(status: 400, failure: nil, requiresSuccessStatus: true), "HTTP 400")
        XCTAssertEqual(ConnectionTestModule.grade(status: 404, failure: nil, requiresSuccessStatus: true), "HTTP 404")
    }

    func testTheProbeURLResolvesAgainstThePathPrefixAndAppendsTheMarker() {
        let ping = ConnectionTestModule.probeURL(path: "/o/ping", serverURL: "https://x.com/countly//").absoluteString
        XCTAssertTrue(ping.hasPrefix("https://x.com/countly/o/ping?ct=1&_="), ping)

        let rc = ConnectionTestModule.probeURL(path: "/o/sdk?method=rc", serverURL: "https://x.com").absoluteString
        XCTAssertTrue(rc.hasPrefix("https://x.com/o/sdk?method=rc&ct=1&_="), rc)

        let noSlash = ConnectionTestModule.probeURL(path: "i", serverURL: "https://x.com/").absoluteString
        XCTAssertTrue(noSlash.hasPrefix("https://x.com/i?ct=1&_="), noSlash)
    }

    func testTheConnectionTestFlagIsReadAndStripped() {
        for armed: Any in [1, true, 2.5, "1", "yes", ["nested": 1]] {
            var response: [String: Any] = ["v": 1, "ct": armed]
            XCTAssertTrue(ServerConfig.extractConnectionTestFlag(&response), "\(armed)")
            XCTAssertNil(response["ct"], "\(armed)")
            XCTAssertEqual(TestUtils.int(response["v"]), 1)
        }
        for disarmed: Any in [0, false, "0", "false", " FALSE ", "", NSNull()] {
            var response: [String: Any] = ["ct": disarmed]
            XCTAssertFalse(ServerConfig.extractConnectionTestFlag(&response), "\(disarmed)")
            XCTAssertNil(response["ct"], "\(disarmed)")
        }
        var absent: [String: Any] = ["v": 1]
        XCTAssertFalse(ServerConfig.extractConnectionTestFlag(&absent))
    }

    func testTheReportEnforcesTheRowByteAndErrorCaps() throws {
        let module = module(of: startInstance())
        var rows = (0..<40).map {
            ConnectionTestModule.ResultRow(feature: "row\($0)", ok: false, status: 403, latencyMs: 12,
                                           error: String(repeating: "x", count: 300))
        }
        rows[3].error = "opaque"

        let json = module.buildReport(rows)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let results = try XCTUnwrap(report["results"] as? [[String: Any]])

        XCTAssertLessThanOrEqual(results.count, 32)
        XCTAssertLessThanOrEqual(json.utf8.count, 8 * 1024)
        // 32 rows with 256 character reasons overflow the byte cap, so the reasons
        // went, except the opaque qualifier.
        XCTAssertEqual(results[3]["e"] as? String, "opaque", "dropping the qualifier would upgrade a low confidence row")
        for (index, row) in results.enumerated() where index != 3 {
            XCTAssertNil(row["e"], "\(row)")
        }

        // Under the byte cap a long reason is only truncated.
        let single = module.buildReport([ConnectionTestModule.ResultRow(feature: "core", ok: false, status: 500, latencyMs: 1,
                                                                        error: String(repeating: "y", count: 300))])
        let singleReport = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(single.utf8)) as? [String: Any])
        let singleRow = try XCTUnwrap((singleReport["results"] as? [[String: Any]])?.first)
        XCTAssertEqual((singleRow["e"] as? String)?.count, 256)
        XCTAssertEqual(TestUtils.int(singleRow["st"]), 500)
        XCTAssertNil(singleRow["n"], "a single path row carries no path count")
    }

    func testARunWithoutAServerConfigLatencyOmitsTheScRow() {
        let module = module(of: startInstance())
        let transport = CannedTransport(status: 400)
        module.transport = transport

        let rows = module.runBattery(serverConfigLatencyMs: -1, serverURL: "https://x.com/prefix")

        XCTAssertEqual(rows.map(\.feature), expectedFeatures.filter { $0 != "sc" }, "omitted rather than invented")
        XCTAssertEqual(transport.urls.count, expectedProbePaths.count)
        XCTAssertTrue(transport.urls.allSatisfy { $0.absoluteString.hasPrefix("https://x.com/prefix/") })
        XCTAssertEqual(rows.first { $0.feature == "core" }?.error, "HTTP 400", "the strict row has no legitimate 4xx")
        XCTAssertEqual(rows.first { $0.feature == "feedback-widget" }?.pathCount, 3)
        XCTAssertEqual(rows.first { $0.feature == "rc" }?.ok, true)
    }
}
