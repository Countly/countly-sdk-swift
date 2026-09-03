//
//  ContentScenarioDriver.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Drives every content and feedback scenario against a real server and reports
/// what happened.
///
/// The counterpart of `content_test_runner.py` in `countly-sdk-android`. That one
/// drives the demo through `adb` and UIAutomator and asserts on logcat; macOS has
/// no equivalent, and the sample keeps its configuration in memory so there is
/// nothing to seed before launch. What it does have is `CountlyLoggerDelegate`,
/// which carries the same lines logcat would, so the SDK is driven directly and
/// the log stream is read the same way.
///
/// The variant list and the device ID prefix routing are the Android runner's:
/// the server decides which content to return from the prefix of the device ID,
/// so `sticky_top_<run>` gets a sticky top and `fullscreen_<run>` a fullscreen.
///
/// Opt in with `COUNTLY_SCENARIOS=1`. It talks to a real server and writes real
/// app users, so it must never run in CI alongside the rest of the suite.
final class ContentScenarioDriver: XCTestCase {

    // The Android runner's `CONTENT_VARIANTS`, unchanged.
    private static let contentVariants = [
        "sticky_top", "sticky_bottom", "modal",
        "half_modal_top", "half_modal_bottom", "fullscreen",
    ]
    private static let feedbackTypes: [FeedbackWidgetType] = [.nps, .rating, .survey]

    private static let host = "https://master.count.ly"
    private static let appKey = "dte_mobile_v2"

    /// Collects the SDK's log lines for a run, standing in for logcat.
    private final class LogSink: CountlyLoggerDelegate {
        private let lock = NSLock()
        private var lines: [String] = []

        func internalLog(_ log: String, level: CountlyLogLevel) {
            lock.lock(); defer { lock.unlock() }
            lines.append(log)
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }

        /// The first line containing `needle`, or nil.
        func first(_ needle: String) -> String? {
            all.first { $0.contains(needle) }
        }

        func has(_ needle: String) -> Bool { first(needle) != nil }
    }

    /// One scenario's outcome.
    private struct Finding {
        let scenario: String
        var served = false
        var geo: String?
        var placedFrame: String?
        var surfaceReported = false
        var pageAskedForSize = false
        var fittedBeforeShowing = false
        var shown = false
        var notes: [String] = []
    }

    private var findings: [Finding] = []
    private var runID = ""

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COUNTLY_SCENARIOS"] == "1",
                          "Set COUNTLY_SCENARIOS=1 to drive the scenarios against a real server")
        runID = String(UUID().uuidString.prefix(6)).lowercased()
    }

    // MARK: - The run

    func testDriveEveryScenario() throws {
        for variant in Self.contentVariants {
            findings.append(driveContent(variant: variant))
        }
        for type in Self.feedbackTypes {
            findings.append(driveFeedback(type: type))
        }
        report()
    }

    // MARK: - Content

    private func driveContent(variant: String) -> Finding {
        var finding = Finding(scenario: "content/\(variant)")

        let sink = LogSink()
        let countly = start(deviceID: "\(variant)_\(runID)", sink: sink)
        defer { countly.halt(clearStorage: true) }

        // The journey only matches a device that has a session, so one is opened by
        // hand and its request is waited for. Content is also one-shot per device
        // per journey, which is why every run mints fresh IDs.
        countly.sessions.beginSession()
        guard waitUntil(15, { sink.has("session opened") }) else {
            finding.notes.append("the session never opened, so the device is in no journey and the fetch cannot match")
            return finding
        }
        guard waitUntil(15, { sink.has("endpoint: [/i]") && sink.has("the server accepted the request") }) else {
            finding.notes.append("the session request was never accepted by the server")
            return finding
        }

        countly.content.enterContentZone()

        // The fetch is an immediate request, not a queued one, so it is quick; the
        // presentation that follows is a page load.
        waitUntil(20) { sink.has("fetchContents, the content details response") }

        if sink.has("the content details response carries a content") {
            finding.served = true
        } else if sink.has("carries no content") {
            finding.notes.append("the server returned no content for this prefix")
            return finding
        } else {
            finding.notes.append("no fetch response was seen within the timeout")
            return finding
        }

        finding.geo = value(after: "placementCoordinates: ", in: sink)
            ?? value(after: "content details response detail: ", in: sink)
        finding.placedFrame = value(after: "frame: ", in: sink.first("showContent, showing a content") ?? "")

        waitUntil(20) { sink.has("the content web view appeared on screen") || sink.has("didFinish") }
        finding.shown = sink.has("the content web view appeared on screen")

        finding.surfaceReported = sink.has("the page is told how much room it has")
        finding.pageAskedForSize = sink.has("the page asked to be resized") || sink.has("the page replied")
        if sink.has("the page replied") { finding.notes.append("the page answered through the bridge") }

        countly.content.exitContentZone()
        pump(0.5)
        return finding
    }

    // MARK: - Feedback

    private func driveFeedback(type: FeedbackWidgetType) -> Finding {
        var finding = Finding(scenario: "feedback/\(type.wireName)")

        let sink = LogSink()
        let countly = start(deviceID: "\(type.wireName)_\(runID)", sink: sink)
        defer { countly.halt(clearStorage: true) }

        countly.sessions.beginSession()
        _ = waitUntil(15) { sink.has("session opened") }

        switch type {
        case .nps: countly.feedback.presentNPS()
        case .survey: countly.feedback.presentSurvey()
        case .rating: countly.feedback.presentRating()
        }

        waitUntil(25) { sink.has("widget shown") || sink.has("no widget of the requested type") }

        guard sink.has("widget presentation requested") else {
            finding.notes.append("no widget of this type was available on the server")
            return finding
        }
        finding.served = true
        finding.placedFrame = value(after: "frame: ", in: sink.first("the widget is placed by the SDK") ?? "")
        finding.shown = sink.has("widget shown")
        finding.surfaceReported = sink.has("the page is told how much room it has")
        finding.pageAskedForSize = sink.has("the page asked to be resized")
        finding.fittedBeforeShowing = sink.has("shown already fitted")

        finding.pageAskedForSize = finding.pageAskedForSize || sink.has("the page replied")

        if let fit = sink.first("the page drew a card smaller than the box") {
            finding.notes.append("fitted by measurement: \(value(after: "measuredCard: ", in: fit) ?? "?")")
        } else if sink.has("the card could not be measured") {
            finding.notes.append("the card could not be measured")
        }

        if sink.has("did not ask for a size within the deadline") {
            finding.notes.append("the page never stated a size within the deadline")
        }

        pump(0.5)
        return finding
    }

    // MARK: - Plumbing

    private func start(deviceID: String, sink: LogSink) -> CountlyInstance {
        let config = CountlyConfig()
        config.host = Self.host
        config.appKey = Self.appKey
        config.deviceID = deviceID
        config.instanceName = "scenario-\(deviceID)"
        config.enableDebug = true
        config.internalLogLevel = .debug
        config.loggerDelegate = sink
        config.content.zoneTimerInterval = 30
        // Sessions are driven by hand.
        //
        // Automatic sessions never start here: the SDK refuses to open one while the
        // application is in the background, and an `xctest` process is never
        // foreground, so it correctly logs "app is in the background, the automatic
        // session will not be started" and the device stays out of every journey.
        // The content endpoint then answers `No content block found!`, which reads
        // exactly like a server with nothing configured and cost the first three
        // runs of this driver.
        config.manualSessionHandling = true

        let instance = Countly.instance(named: config.instanceName)
        instance.start(with: config)
        return instance
    }

    /// Waits for `condition`, and says whether it held rather than leaving the
    /// caller to carry on as though it had. The first version of this driver
    /// ignored the result and reported a fetch that never had a session behind it.
    @discardableResult
    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// The remainder of a log line after `marker`, trimmed to one field.
    private func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return String(line[range.upperBound...].prefix(120))
    }

    private func value(after marker: String, in sink: LogSink) -> String? {
        guard let line = sink.all.first(where: { $0.contains(marker) }) else { return nil }
        return value(after: marker, in: line)
    }

    // MARK: - The report

    private func report() {
        var out = ["# Content and feedback scenario run", "",
                   "Run \(runID) against \(Self.host), app key \(Self.appKey).", "",
                   "| scenario | served | shown | surface reported | page asked for size | fitted first | placed frame |",
                   "| --- | --- | --- | --- | --- | --- | --- |"]

        for f in findings {
            out.append("| \(f.scenario) | \(mark(f.served)) | \(mark(f.shown)) | \(mark(f.surfaceReported)) | \(mark(f.pageAskedForSize)) | \(mark(f.fittedBeforeShowing)) | \(f.placedFrame ?? "-") |")
        }

        let noted = findings.filter { !$0.notes.isEmpty }
        if !noted.isEmpty {
            out += ["", "## Notes", ""]
            for f in noted {
                for note in f.notes { out.append("- **\(f.scenario)**: \(note)") }
            }
        }

        let text = out.joined(separator: "\n") + "\n"
        print("\n===== SCENARIO REPORT =====\n\(text)===== END =====\n")

        let path = ProcessInfo.processInfo.environment["COUNTLY_SCENARIO_REPORT"]
            ?? NSTemporaryDirectory() + "countly-scenarios.md"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print("report written to \(path)")
    }

    private func mark(_ value: Bool) -> String { value ? "yes" : "no" }
}
