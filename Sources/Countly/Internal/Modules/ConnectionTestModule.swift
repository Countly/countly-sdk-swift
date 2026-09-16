//
//  ConnectionTestModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Server armed connection test.
///
/// A top level `ct` on a live behavior settings response runs one battery of
/// parameterless GETs against every endpoint the SDK depends on and queues one
/// `ct_results` report. Probes carry no app key, device ID or body: the expected
/// answer on most rows is the application level `400 Missing parameter`, which
/// proves the request crossed the proxy and reached Countly code. Nothing about
/// the test is persisted.
final class ConnectionTestModule: ModuleBase {

    override class var moduleName: String { "ConnectionTest" }

    /// Deadline for one probe. A `var` so the suite can hold it open: a probe that
    /// stalls on a loaded machine would otherwise be graded as a timeout rather
    /// than on the status the server gave it.
    static var defaultPerRequestTimeout: TimeInterval = 10
    static let defaultBatteryCapExtra: TimeInterval = 30
    static let maxRows = 32
    static let maxReportBytes = 8 * 1024
    static let maxErrorLength = 256

    /// The `e` vocabulary. Kept byte identical across SDKs so the dashboard can
    /// group results.
    enum Reason {
        static let timeout = "timeout"
        static let transport = "transport error"
        static let redirected = "redirected"
        static let notRun = "not run: battery cap"
        /// Success qualifier of opaque browser probes. Never produced here, but by
        /// cross SDK rule it survives the size cap.
        static let opaque = "opaque"
    }

    /// Keys of the report.
    enum ReportKey {
        static let timestamp = "ts"
        static let sdk = "sdk"
        static let sdkName = "name"
        static let sdkVersion = "version"
        static let results = "results"
        static let feature = "f"
        static let ok = "ok"
        static let status = "st"
        static let latency = "ms"
        static let error = "e"
        static let pathCount = "n"
    }

    /// One feature row of the battery.
    struct ProbeRow {
        let feature: String
        /// Rows with no legitimate 4xx answer, where anything but a 2xx is a fault.
        let requiresSuccessStatus: Bool
        /// Empty for the `sc` row, which is measured from the fetch that armed us.
        let paths: [String]
    }

    /// Feature rows in report order.
    static let rows: [ProbeRow] = [
        ProbeRow(feature: "core", requiresSuccessStatus: true, paths: ["/o/ping"]),
        ProbeRow(feature: "core-write", requiresSuccessStatus: false, paths: ["/i"]),
        ProbeRow(feature: "sc", requiresSuccessStatus: false, paths: []),
        ProbeRow(feature: "rc", requiresSuccessStatus: false, paths: ["/o/sdk?method=rc"]),
        ProbeRow(feature: "ab", requiresSuccessStatus: false, paths: ["/o/sdk?method=ab_fetch_variants"]),
        ProbeRow(feature: "feedback", requiresSuccessStatus: false, paths: ["/o/sdk?method=feedback"]),
        ProbeRow(feature: "feedback-widget", requiresSuccessStatus: false,
                 paths: ["/o/surveys/nps/widget", "/o/surveys/survey/widget", "/o/feedback/widget"]),
        ProbeRow(feature: "feedback-submit", requiresSuccessStatus: false, paths: ["/i/feedback/inputs"]),
        ProbeRow(feature: "content", requiresSuccessStatus: false, paths: ["/o/sdk/content"]),
        ProbeRow(feature: "feedback-page", requiresSuccessStatus: false,
                 paths: ["/feedback/nps", "/feedback/survey", "/feedback/rating"]),
        ProbeRow(feature: "feedback-assets", requiresSuccessStatus: true,
                 paths: ["/surveys/images/ct-probe.png", "/star-rating/images/ct-probe.png"]),
        ProbeRow(feature: "content-page", requiresSuccessStatus: false, paths: ["/_external/content/"]),
    ]

    /// Raw outcome of one probe request, before grading.
    struct ProbeOutcome {
        /// HTTP status, or 0 when none could be read.
        let status: Int
        let latencyMs: Int64
        /// Read only when the status is 0: `Reason.timeout` for an elapsed
        /// deadline, anything else, `nil` included, grades as a transport error.
        let failure: String?
    }

    /// One graded report row.
    struct ResultRow: Equatable {
        let feature: String
        var ok = true
        var status = 0
        var latencyMs: Int64 = 0
        var error: String?
        var pathCount = 0
    }

    // MARK: - State

    /// Guards the running flag and the halted flag, which are touched from the
    /// arming thread, the battery worker and `halt`.
    private let stateLock = NSLock()
    private var batteryRunning = false
    private var halted = false

    /// Test hooks: the deadlines can be shrunk and the network swapped out.
    var perRequestTimeout: TimeInterval = ConnectionTestModule.defaultPerRequestTimeout
    var batteryCapExtra: TimeInterval = ConnectionTestModule.defaultBatteryCapExtra
    lazy var transport: ProbeTransport = URLSessionProbeTransport(core: core)

    var isBatteryRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return batteryRunning
    }

    private var isHalted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return halted
    }

    override func halt(clearStorage: Bool) {
        stateLock.lock()
        halted = true
        stateLock.unlock()
    }

    /// Takes the single battery slot, checked and claimed in one critical section
    /// so two deliveries landing together cannot both start one. Returns why the
    /// claim was refused, or `nil` once it is held.
    private func claimBattery() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if halted { return "the module is halted, the armed connection test is ignored" }
        if batteryRunning { return "a battery is already running, this delivery is ignored" }
        batteryRunning = true
        return nil
    }

    /// Lets the next armed delivery start a battery.
    private func releaseBattery() {
        stateLock.lock()
        batteryRunning = false
        stateLock.unlock()
    }

    // MARK: - Battery

    /// Runs the battery off the calling thread, once per delivery.
    ///
    /// - Parameter serverConfigLatencyMs: Wall clock of the fetch that delivered
    ///   `ct`, reported as the `sc` row. Negative when unknown, which omits the row.
    func startBattery(serverConfigLatencyMs: Int64) {
        // The spec does not cover it: honouring the operator's own kill switch was
        // judged safer than probe traffic.
        guard core.serverConfig.networkingEnabled else {
            logD("startBattery", "networking is disabled by behavior settings, the armed connection test is ignored")
            return
        }

        if let refusal = claimBattery() {
            logD("startBattery", refusal)
            return
        }

        logI("startBattery", "connection test armed by the server, running the probe battery, serverConfigLatencyMs: [\(serverConfigLatencyMs)]")

        // The core is captured strongly for the life of the battery: the module
        // holds it `unowned`, and `halt()` can release it while probes are still
        // running. The halted flag then drops the report.
        DispatchQueue.global(qos: .utility).async { [weak self, core] in
            guard let self else { return }
            self.runBatteryAndReport(serverConfigLatencyMs: serverConfigLatencyMs, serverURL: core.config.normalizedHost)
            self.releaseBattery()
        }
    }

    /// Runs every row in order and queues the report, unless the instance was
    /// halted meanwhile.
    func runBatteryAndReport(serverConfigLatencyMs: Int64, serverURL: String) {
        let results = runBattery(serverConfigLatencyMs: serverConfigLatencyMs, serverURL: serverURL)

        guard !isHalted else {
            logD("runBatteryAndReport", "the module was halted during the battery, the report is dropped")
            return
        }

        let report = buildReport(results)
        logD("runBatteryAndReport", "queueing the connection test report, rowCount: [\(results.count)], reportLength: [\(report.count)]")
        core.network.sendConnectionTestResults(report)
    }

    /// Probes every row sequentially against `serverURL`. Rows not reached before
    /// the battery cap report `not run`.
    func runBattery(serverConfigLatencyMs: Int64, serverURL: String) -> [ResultRow] {
        let requestCount = Self.rows.reduce(0) { $0 + $1.paths.count }
        let cap = Double(requestCount) * perRequestTimeout + batteryCapExtra
        let batteryStart = Date()

        var results: [ResultRow] = []
        for row in Self.rows {
            if isHalted { break }

            if row.paths.isEmpty {
                if serverConfigLatencyMs >= 0 {
                    results.append(ResultRow(feature: row.feature, ok: true, status: 200, latencyMs: serverConfigLatencyMs))
                }
                continue
            }

            if -batteryStart.timeIntervalSinceNow > cap {
                results.append(ResultRow(feature: row.feature, ok: false, status: 0, latencyMs: 0, error: Reason.notRun))
                continue
            }

            results.append(probeRow(row, serverURL: serverURL))
        }

        transport.batteryFinished()
        return results
    }

    /// Probes every path of one row and combines them: `ok` only if all passed,
    /// the first failing status and reason, summed latency.
    func probeRow(_ row: ProbeRow, serverURL: String) -> ResultRow {
        var result = ResultRow(feature: row.feature, ok: true, pathCount: row.paths.count)

        for (index, path) in row.paths.enumerated() {
            if isHalted { break }

            let url = Self.probeURL(path: path, serverURL: serverURL)
            let outcome = transport.probe(url, timeout: perRequestTimeout)
            result.latencyMs += outcome.latencyMs

            let failure = Self.grade(status: outcome.status, failure: outcome.failure, requiresSuccessStatus: row.requiresSuccessStatus)
            logV("probeRow", "probe answered, feature: [\(row.feature)], url: [\(url.absoluteString)], status: [\(outcome.status)], latencyMs: [\(outcome.latencyMs)], failure: [\(failure ?? "none")]")

            // The row reports the first status observed, unless a failing path
            // overrides it: the first failing path decides status and reason.
            if index == 0 {
                result.status = outcome.status
            }
            if let failure, result.ok {
                result.ok = false
                result.status = outcome.status
                result.error = failure
            }
        }

        return result
    }

    // MARK: - Grading and URLs

    /// `nil` when the Countly application answered, otherwise the `e` reason.
    static func grade(status: Int, failure: String?, requiresSuccessStatus: Bool) -> String? {
        if status <= 0 {
            return failure ?? Reason.transport
        }
        if (200..<300).contains(status) {
            return nil
        }
        if (300..<400).contains(status) {
            return Reason.redirected
        }
        // A 4xx other than 403 is the Countly application answering, unless this
        // row has no legitimate 4xx answer.
        if !requiresSuccessStatus, (400..<500).contains(status), status != 403 {
            return nil
        }
        return "HTTP \(status)"
    }

    /// Resolves a path against the configured URL, path prefix included, and
    /// appends the log marker and a cache buster.
    static func probeURL(path: String, serverURL: String) -> URL {
        var base = serverURL
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let joined = path.hasPrefix("/") ? base + path : base + "/" + path
        let separator = joined.contains("?") ? "&" : "?"
        let cacheBuster = Int64(Date().timeIntervalSince1970 * 1000)
        return URL(string: "\(joined)\(separator)ct=1&_=\(cacheBuster)") ?? URL(string: "https://invalid")!
    }

    // MARK: - Report

    /// The report JSON, with the caps enforced: at most 32 rows and 8 KB, `e`
    /// truncated to 256 characters and dropped when still over, except `opaque`.
    func buildReport(_ rows: [ResultRow]) -> String {
        var results: [[String: Any]] = rows.prefix(Self.maxRows).map(Self.rowJSON)

        // Measured in bytes before URL escaping, which is what the server's cap
        // is measured against.
        var report = serializedReport(results)
        if report.utf8.count > Self.maxReportBytes {
            logW("buildReport", "the connection test report is over the size cap, error details are dropped, reportBytes: [\(report.utf8.count)]")
            for index in results.indices where results[index][ReportKey.error] as? String != Reason.opaque {
                // The qualifier of an opaque success is not detail: dropping it
                // would upgrade the row's apparent certainty.
                results[index].removeValue(forKey: ReportKey.error)
            }
            report = serializedReport(results)
        }

        while report.utf8.count > Self.maxReportBytes, !results.isEmpty {
            logW("buildReport", "the connection test report is still over the size cap, the last row is dropped, rowCount: [\(results.count)]")
            results.removeLast()
            report = serializedReport(results)
        }

        return report
    }

    private static func rowJSON(_ row: ResultRow) -> [String: Any] {
        var json: [String: Any] = [
            ReportKey.feature: row.feature,
            ReportKey.ok: row.ok,
            ReportKey.status: row.status,
            ReportKey.latency: row.latencyMs,
        ]
        if let error = row.error {
            json[ReportKey.error] = error.countlyPrefix(maxErrorLength)
        }
        if row.pathCount > 1 {
            json[ReportKey.pathCount] = row.pathCount
        }
        return json
    }

    private func serializedReport(_ results: [[String: Any]]) -> String {
        let report: [String: Any] = [
            ReportKey.timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            ReportKey.sdk: [ReportKey.sdkName: core.sdkName, ReportKey.sdkVersion: core.sdkVersion],
            ReportKey.results: results,
        ]
        return CountlyJSON.string(from: report, logger: log) ?? "{}"
    }
}

/// Issues one probe. A protocol so tests can swap the network out.
protocol ProbeTransport: AnyObject {
    /// One bare GET, waited for synchronously.
    func probe(_ url: URL, timeout: TimeInterval) -> ConnectionTestModule.ProbeOutcome
    /// Called once the battery is over, so a transport can release what it built.
    func batteryFinished()
}

/// The default transport: a session built from the SDK's own configuration, so
/// probes ride the same custom headers and, through the delegate, the same
/// certificate pinning. Caching is off and redirects are not followed.
final class URLSessionProbeTransport: NSObject, ProbeTransport {

    /// Held weakly: the core owns the module that owns this transport, and a
    /// URLSession retains its delegate until it is invalidated.
    private weak var core: SDKCore?

    private let sessionLock = NSLock()
    private var session: URLSession?

    init(core: SDKCore) {
        self.core = core
        super.init()
    }

    func probe(_ url: URL, timeout: TimeInterval) -> ConnectionTestModule.ProbeOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout

        let done = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var status = 0
        var failure: String?
        let start = Date()

        let task = probeSession(timeout: timeout).dataTask(with: request) { _, response, error in
            resultLock.lock()
            if let error {
                failure = (error as NSError).code == NSURLErrorTimedOut ? ConnectionTestModule.Reason.timeout : ConnectionTestModule.Reason.transport
            } else if let http = response as? HTTPURLResponse {
                status = http.statusCode
            } else {
                failure = ConnectionTestModule.Reason.transport
            }
            resultLock.unlock()
            done.signal()
        }
        task.resume()

        // The request's own deadline should fire first; this only guards against a
        // completion that never comes. Cancelling makes the completion run, so it
        // is waited for and its write cannot race the verdict.
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            done.wait()
            resultLock.lock()
            status = 0
            failure = ConnectionTestModule.Reason.timeout
            resultLock.unlock()
        }

        resultLock.lock()
        defer { resultLock.unlock() }
        return ConnectionTestModule.ProbeOutcome(status: status,
                                                 latencyMs: Int64(-start.timeIntervalSinceNow * 1000),
                                                 failure: failure)
    }

    func batteryFinished() {
        sessionLock.lock()
        let built = session
        session = nil
        sessionLock.unlock()
        built?.finishTasksAndInvalidate()
    }

    /// One session per battery, on a copy of the SDK's configuration so its
    /// headers and any installed URL protocol ride along without the timeouts set
    /// here leaking back into it.
    private func probeSession(timeout: TimeInterval) -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let session { return session }

        let source = core?.config.urlSessionConfiguration
        let configuration = (source?.copy() as? URLSessionConfiguration) ?? .default

        // Carried over explicitly rather than trusted to `copy()`. An application
        // that installs a `URLProtocol` expects the probes to go through it too,
        // and whether a copied configuration keeps the list is platform behaviour,
        // not a documented guarantee.
        if let protocolClasses = source?.protocolClasses {
            configuration.protocolClasses = protocolClasses
        }

        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false

        let built = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session = built
        return built
    }
}

extension URLSessionProbeTransport: URLSessionTaskDelegate {

    /// A redirect must not be mistaken for a healthy answer: the 3xx itself
    /// becomes the task's response.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// Forwards to the connection manager's pinning check when certificates are
    /// pinned. Without this a pinned host would report `transport error` while
    /// the SDK itself works.
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let core, !core.config.pinnedCertificates.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        core.network.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
}
