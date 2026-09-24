//
//  CrashTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// The `crash` payload: what the server is told about something going wrong.
///
/// A crash report is only useful if it can be symbolicated and attributed, so
/// these check the fields that make that possible, the breadcrumb trail that gives
/// it context, and the two filters an application can use to keep a report from
/// leaving the device at all.
final class CrashTests: CountlyBaseTestCase {

    /// The `crash` object of the last crash request, or `nil` when none was queued.
    private func lastCrash(of instance: CountlyInstance) -> [String: Any]? {
        TestUtils.requests(requestQueue(of: instance), carrying: "crash")
            .last?["crash"] as? [String: Any]
    }

    private func crashCount(of instance: CountlyInstance) -> Int {
        TestUtils.requests(requestQueue(of: instance), carrying: "crash").count
    }

    /// Crash requests in the instance's queue file, read back from disk by a store
    /// of its own. What a process killed right now would find on the next launch,
    /// which the in-memory queue does not show.
    private func crashCountOnDisk(of instance: CountlyInstance) -> Int {
        let fromDisk = RequestQueueStore(namespace: core(of: instance).namespace, logger: nil)
        return TestUtils.requests(fromDisk.snapshot, carrying: "crash").count
    }

    /// Crash requests that reached the transport.
    private var sentCrashCount: Int {
        MockURLProtocol.requests.filter { $0.query.contains("crash=") }.count
    }

    // MARK: - Durability

    /// A crash the SDK detects itself is written to disk before the handler
    /// returns, and nothing is sent while the process goes down. The stored report
    /// carries the breadcrumbs, and the breadcrumb file is emptied so the next
    /// launch does not attach the same lines to an unrelated report.
    func testADetectedCrashIsStoredWithItsBreadcrumbsAndNothingIsSent() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respondToEverything(json: #"{"result":"Success"}"#)
        let countly = startInstance { $0.features = [.crashReporting] }
        countly.crashes.addCrashBreadcrumb("opened cart")

        reportAutoDetectedCrash(on: countly)
        TestUtils.pump(0.5)

        XCTAssertEqual(sentCrashCount, 0, "nothing may be sent while the process goes down")
        XCTAssertEqual(crashCountOnDisk(of: countly), 1,
                       "the report should be on disk by the time the handler returns")
        let logs = lastCrash(of: countly)?["_logs"] as? String ?? ""
        XCTAssertTrue(logs.contains("opened cart"), "the stored report should carry the breadcrumbs, logs were: [\(logs)]")
        XCTAssertEqual(core(of: countly).crashLogStore.readAll() ?? "", "",
                       "the breadcrumb file should be empty once the report holding them is stored")
    }

    /// The next launch sends what the crashed run stored, through the ordinary
    /// queue, and the report leaves the queue once the server accepts it.
    func testAStoredCrashIsSentOnTheNextLaunch() throws {
        try skipUnlessNetworkIsInterceptable()
        let name = uniqueInstanceName()
        let crashedConfig = baseConfig(instanceName: name)
        crashedConfig.features = [.crashReporting]
        let crashed = start(crashedConfig)

        reportAutoDetectedCrash(on: crashed, name: "SIGSEGV", reason: "App terminated by SIGSEGV")
        XCTAssertEqual(sentCrashCount, 0, "the crashed run may not send the report itself")
        crashed.halt()

        MockURLProtocol.respondToEverything(json: #"{"result":"Success"}"#)
        let relaunched = start(baseConfig(instanceName: name))

        TestUtils.waitUntil("the stored crash report is sent") { self.sentCrashCount == 1 }
        let sent = MockURLProtocol.requests.first { $0.query.contains("crash=") }
        let crash = sent.flatMap { TestUtils.parseQuery($0.query)["crash"] as? [String: Any] }
        XCTAssertEqual(sent?.path, "/i")
        XCTAssertEqual(crash?["_type"] as? String, "SIGSEGV")
        XCTAssertEqual(crash?["_name"] as? String, "App terminated by SIGSEGV")
        XCTAssertEqual(crash?["_nonfatal"] as? Bool, false)
        TestUtils.waitUntil("the accepted crash report leaves the queue") { self.crashCount(of: relaunched) == 0 }
    }

    /// Tracking off is a kill switch, and the crash path honours it like every
    /// other request: nothing is kept for a later launch.
    func testNoCrashReportIsStoredWhileTrackingIsDisabled() {
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().tracking(false).json()
        }

        reportAutoDetectedCrash(on: countly)

        XCTAssertEqual(crashCountOnDisk(of: countly), 0, "no crash report may be kept while tracking is switched off")
    }

    /// With several instances, every one of them stores the crash, and none sends
    /// it while the process goes down.
    func testEveryInstanceStoresTheCrashAndNoneSendsIt() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respondToEverything(json: #"{"result":"Success"}"#)
        let first = startInstance { $0.features = [.crashReporting]; $0.appKey = "first-app" }
        let second = startInstance { $0.features = [.crashReporting]; $0.appKey = "second-app" }

        CrashHandlerInstaller.shared.dispatch(name: "SIGSEGV", reason: "boom", stackTrace: ["0 MyApp 0x1 boom"])
        TestUtils.pump(0.5)

        XCTAssertEqual(crashCountOnDisk(of: first), 1)
        XCTAssertEqual(crashCountOnDisk(of: second), 1)
        XCTAssertEqual(sentCrashCount, 0, "no instance may send the crash while the process goes down")
    }

    /// The filter callback receives a mutable object, so whatever it puts back has
    /// to survive serialization. A value JSON cannot represent would otherwise
    /// make the whole report serialize to nothing and be lost silently.
    func testAValueTheFilterCallbackAddsIsSanitizedRatherThanLosingTheReport() {
        let countly = startInstance {
            $0.crashes.crashFilterCallback = { data in
                data.crashSegmentation["seenAt"] = Date(timeIntervalSince1970: 1_700_000_000)
                data.crashSegmentation["binary"] = Data([0x01])
                data.crashMetrics["lastSync"] = Date(timeIntervalSince1970: 1_700_000_000)
                data.crashMetrics["ratio"] = Double.nan
                return false
            }
        }

        countly.crashes.recordError("Boom", isFatal: false, stackTrace: ["0 MyApp 0x1 boom"])

        guard let crash = lastCrash(of: countly) else {
            XCTFail("the report should still have been queued, not lost to a serialization failure")
            return
        }
        let custom = crash["_custom"] as? [String: Any] ?? [:]
        XCTAssertEqual((custom["seenAt"] as? NSNumber)?.int64Value, 1_700_000_000_000)
        XCTAssertNil(custom["binary"])
        XCTAssertEqual((crash["lastSync"] as? NSNumber)?.int64Value, 1_700_000_000_000)
        XCTAssertNil(crash["ratio"], "a number JSON cannot carry should be dropped, not take the report with it")
    }

    /// A number JSON cannot represent in the segmentation is dropped on its own.
    /// Kept, it makes the whole report unserializable and every later crash with
    /// it is lost.
    func testANonFiniteCrashSegmentationValueDoesNotLoseTheReport() {
        let countly = startInstance()
        countly.crashes.setCrashSegmentation(["load": Double.infinity, "screen": "cart"])

        countly.crashes.recordError("Boom", isFatal: false, stackTrace: ["0 MyApp 0x1 boom"])

        let custom = lastCrash(of: countly)?["_custom"] as? [String: Any]
        XCTAssertEqual(custom?["screen"] as? String, "cart", "the report should still arrive")
        XCTAssertNil(custom?["load"])
    }

    // MARK: - Signal dispositions

    #if os(iOS) || os(tvOS) || os(visionOS) || os(macOS)
    /// A host that ignores a signal has decided the process survives it, SIGPIPE
    /// on a closed socket being the usual case. Replacing that with a handler
    /// reports a crash that never happened and then kills the process on the next
    /// one, so the SDK leaves such a signal alone, and gives every other signal
    /// back to its previous disposition when it stops.
    func testASignalTheHostIgnoresIsLeftAlone() throws {
        var original = sigaction()
        sigaction(SIGPIPE, nil, &original)
        defer { sigaction(SIGPIPE, &original, nil) }
        signal(SIGPIPE, SIG_IGN)

        let countly = startInstance { $0.features = [.crashReporting] }

        var whileStarted = sigaction()
        sigaction(SIGPIPE, nil, &whileStarted)
        XCTAssertTrue(CrashHandlerInstaller.isIgnored(whileStarted), "an ignored signal should stay ignored while the SDK runs")

        countly.halt()

        var afterHalt = sigaction()
        sigaction(SIGPIPE, nil, &afterHalt)
        XCTAssertTrue(CrashHandlerInstaller.isIgnored(afterHalt), "an ignored signal should still be ignored once the SDK stops")
    }

    /// Every catchable signal the kernel treats as a crash is reported, SIGSYS
    /// and SIGEMT included, and each goes back to what it was once the SDK stops.
    func testEveryCrashSignalIsHandledAndGivenBackOnStop() {
        let signals = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE, SIGTRAP, SIGSYS, SIGEMT]
        let before = signals.map(Self.handlerAddress)
        let ignoredBefore = signals.map { CrashHandlerInstaller.isIgnored(Self.action(of: $0)) }

        let countly = startInstance { $0.features = [.crashReporting] }
        let whileStarted = signals.map(Self.handlerAddress)
        countly.halt()
        let afterHalt = signals.map(Self.handlerAddress)

        // A signal the test runner ignores is left alone by design, so only the
        // others have to change hands.
        for (index, signalCode) in signals.enumerated() where !ignoredBefore[index] {
            XCTAssertNotEqual(whileStarted[index], before[index], "signal \(signalCode) should be handled while the SDK runs")
        }
        XCTAssertEqual(afterHalt, before, "every signal should be given back its previous disposition")
    }

    private static func action(of signalCode: Int32) -> sigaction {
        var action = sigaction()
        sigaction(signalCode, nil, &action)
        return action
    }

    /// The installed handler as an address, 0 for the default disposition.
    private static func handlerAddress(_ signalCode: Int32) -> Int {
        action(of: signalCode).__sigaction_u.__sa_handler.map { unsafeBitCast($0, to: Int.self) } ?? 0
    }
    #endif

    // MARK: - The payload

    func testAHandledErrorCarriesItsNameStackTraceAndTheNonFatalFlag() {
        let countly = startInstance()

        countly.crashes.recordError("Something went wrong",
                                    isFatal: false,
                                    stackTrace: ["0 MyApp 0x1 doThing", "1 MyApp 0x2 doOtherThing"])

        guard let crash = lastCrash(of: countly) else {
            XCTFail("recording an error should have queued a crash request")
            return
        }

        XCTAssertEqual(crash["_name"] as? String, "Something went wrong")
        XCTAssertTrue((crash["_error"] as? String ?? "").contains("doThing"))

        // A boolean, not a 1. Every other Countly SDK sends a boolean here and the
        // booleans beside it in this same payload are real booleans.
        XCTAssertEqual(crash["_nonfatal"] as? Bool, true)
    }

    func testAFatalErrorReportsNonFatalAsFalse() {
        let countly = startInstance()

        countly.crashes.recordError("Fatal", isFatal: true, stackTrace: ["0 MyApp 0x1 boom"])

        XCTAssertEqual(lastCrash(of: countly)?["_nonfatal"] as? Bool, false)
    }

    /// The device state at the moment of the crash is what turns a stack trace
    /// into a diagnosis, so every report carries it.
    func testEveryReportCarriesTheDeviceState() {
        let countly = startInstance()

        countly.crashes.recordError("Context", isFatal: false, stackTrace: [])

        guard let crash = lastCrash(of: countly) else {
            XCTFail("recording an error should have queued a crash request")
            return
        }

        XCTAssertNotNil(crash["_os"])
        XCTAssertNotNil(crash["_os_version"])
        XCTAssertNotNil(crash["_device"])
        XCTAssertNotNil(crash["_app_version"])
        XCTAssertNotNil(crash["_ram_total"])
        XCTAssertNotNil(crash["_disk_total"])
        XCTAssertNotNil(crash["_run"], "how long the process had been alive")

        // Booleans on the wire, not integers.
        XCTAssertNotNil(crash["_root"] as? Bool)
        XCTAssertNotNil(crash["_background"] as? Bool)
    }

    /// Without these the server cannot map an address back to a symbol, so a
    /// report that omits them is unreadable however complete the rest of it is.
    func testTheSymbolicationFieldsArePopulated() {
        let countly = startInstance()

        countly.crashes.recordError("Symbolicate me", isFatal: false, stackTrace: [])

        guard let crash = lastCrash(of: countly) else {
            XCTFail("recording an error should have queued a crash request")
            return
        }

        XCTAssertFalse((crash["_build_uuid"] as? String ?? "").isEmpty,
                       "the main executable's UUID identifies the exact build")
        XCTAssertFalse((crash["_executable_name"] as? String ?? "").isEmpty)
        XCTAssertFalse((crash["_architecture"] as? String ?? "").isEmpty)
        XCTAssertNotNil(crash["_binary_images"])
    }

    /// A report with no segmentation and no breadcrumbs omits both keys rather
    /// than sending an empty object and an empty string, which is what every other
    /// Countly SDK does.
    func testEmptySegmentationAndBreadcrumbsAreOmittedEntirely() {
        let countly = startInstance()

        countly.crashes.recordError("Bare", isFatal: false, stackTrace: [])

        guard let crash = lastCrash(of: countly) else {
            XCTFail("recording an error should have queued a crash request")
            return
        }
        XCTAssertNil(crash["_custom"])
        XCTAssertNil(crash["_logs"])
    }

    // MARK: - Segmentation

    func testGlobalCrashSegmentationTravelsWithEveryReport() {
        let countly = startInstance { $0.crashSegmentation = ["tier": "premium"] }

        countly.crashes.recordError("With context", isFatal: false, stackTrace: [])

        let custom = lastCrash(of: countly)?["_custom"] as? [String: Any]
        XCTAssertEqual(custom?["tier"] as? String, "premium")
    }

    func testPerReportSegmentationBeatsTheGlobalOne() {
        let countly = startInstance { $0.crashSegmentation = ["tier": "global"] }

        countly.crashes.recordError("Specific",
                                    isFatal: false,
                                    stackTrace: [],
                                    segmentation: ["tier": "local", "screen": "cart"])

        let custom = lastCrash(of: countly)?["_custom"] as? [String: Any]
        XCTAssertEqual(custom?["tier"] as? String, "local")
        XCTAssertEqual(custom?["screen"] as? String, "cart")
    }

    func testSetCrashSegmentationReplacesWhatTheConfigProvided() {
        let countly = startInstance { $0.crashSegmentation = ["from": "config"] }

        countly.crashes.setCrashSegmentation(["from": "runtime"])
        countly.crashes.recordError("Replaced", isFatal: false, stackTrace: [])

        let custom = lastCrash(of: countly)?["_custom"] as? [String: Any]
        XCTAssertEqual(custom?["from"] as? String, "runtime")
    }

    // MARK: - Breadcrumbs

    func testBreadcrumbsAreAttachedInTheOrderTheyWereRecorded() {
        let countly = startInstance()

        countly.crashes.addCrashBreadcrumb("opened the cart")
        countly.crashes.addCrashBreadcrumb("tapped checkout")
        countly.crashes.recordError("Crashed at checkout", isFatal: false, stackTrace: [])

        let logs = lastCrash(of: countly)?["_logs"] as? String ?? ""
        XCTAssertTrue(logs.contains("opened the cart"))
        XCTAssertTrue(logs.contains("tapped checkout"))
        XCTAssertLessThan(logs.range(of: "opened the cart")!.lowerBound,
                          logs.range(of: "tapped checkout")!.lowerBound)
    }

    /// The buffer is bounded, and it is the oldest breadcrumb that goes: the ones
    /// nearest the crash are the ones that explain it.
    func testTheBreadcrumbBufferKeepsTheNewestOnesWhenItOverflows() {
        let countly = startInstance { $0.sdkInternalLimits.maxBreadcrumbCount = 3 }

        for index in 0..<6 {
            countly.crashes.addCrashBreadcrumb("step-\(index)")
        }
        countly.crashes.recordError("Overflowed", isFatal: false, stackTrace: [])

        let logs = lastCrash(of: countly)?["_logs"] as? String ?? ""
        XCTAssertFalse(logs.contains("step-0"))
        XCTAssertTrue(logs.contains("step-5"))
    }

    func testClearingBreadcrumbsLeavesTheNextReportWithNone() {
        let countly = startInstance()

        countly.crashes.addCrashBreadcrumb("forget me")
        countly.crashes.clearCrashBreadcrumbs()
        countly.crashes.recordError("Clean", isFatal: false, stackTrace: [])

        XCTAssertNil(lastCrash(of: countly)?["_logs"])
    }

    // MARK: - Filters

    /// The regular expression filter is matched against the stack trace, the
    /// description and the name, so an application can suppress a known noisy
    /// crash without shipping a new build of the SDK.
    func testTheRegularExpressionFilterSuppressesAMatchingReport() throws {
        let countly = startInstance {
            $0.crashFilter = try? NSRegularExpression(pattern: "SecretError")
        }

        countly.crashes.recordError("SecretError leaked", isFatal: false, stackTrace: [])
        XCTAssertEqual(crashCount(of: countly), 0)

        countly.crashes.recordError("An ordinary error", isFatal: false, stackTrace: [])
        XCTAssertEqual(crashCount(of: countly), 1)
    }

    /// The callback filter gets the assembled report and can either drop it or
    /// edit it in place, which is how an application redacts a stack trace that
    /// would otherwise carry something it may not send.
    func testTheCallbackFilterCanDropAReport() {
        let countly = startInstance()
        core(of: countly).config.crashes.crashFilterCallback = { crashData in
            crashData.crashDescription.contains("drop me")
        }

        countly.crashes.recordError("please drop me", isFatal: false, stackTrace: [])
        XCTAssertEqual(crashCount(of: countly), 0)

        countly.crashes.recordError("keep me", isFatal: false, stackTrace: [])
        XCTAssertEqual(crashCount(of: countly), 1)
    }

    func testTheCallbackFilterCanEditTheReportInPlace() {
        let countly = startInstance()
        core(of: countly).config.crashes.crashFilterCallback = { crashData in
            crashData.crashSegmentation["redacted"] = true
            return false
        }

        countly.crashes.recordError("Edited", isFatal: false, stackTrace: [])

        let custom = lastCrash(of: countly)?["_custom"] as? [String: Any]
        XCTAssertEqual(TestUtils.describe(custom?["redacted"] ?? ""), "1")
    }

    // MARK: - Consent and server config

    func testNothingIsRecordedWithoutCrashReportingConsent() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.crashes.recordError("Blocked", isFatal: false, stackTrace: [])
        countly.crashes.addCrashBreadcrumb("also blocked")
        XCTAssertEqual(crashCount(of: countly), 0)

        countly.consent.giveConsent(for: .crashReporting)
        countly.crashes.recordError("Allowed", isFatal: false, stackTrace: [])
        XCTAssertEqual(crashCount(of: countly), 1)

        XCTAssertNil(lastCrash(of: countly)?["_logs"],
                     "the breadcrumb recorded without consent must not resurface later")
    }

    func testTheServerCanSwitchCrashReportingOff() {
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().crashReporting(false).json()
        }

        countly.crashes.recordError("Suppressed", isFatal: false, stackTrace: [])

        XCTAssertEqual(crashCount(of: countly), 0)
    }

    // MARK: - Limits

    /// Every frame is shortened to the configured length, and the trace keeps all
    /// of its frames: `maxStackTraceLinesPerThread` is accepted but not applied to
    /// the exception's own trace, which is what the crash filters read.
    func testStackTraceLinesAreTruncatedToTheConfiguredLengthButNoFramesAreDropped() {
        let countly = startInstance {
            $0.sdkInternalLimits.maxStackTraceLineLength = 10
            $0.sdkInternalLimits.maxStackTraceLinesPerThread = 2
        }

        countly.crashes.recordError("Long trace", isFatal: false, stackTrace: [
            "a line that is considerably longer than ten characters",
            "another long line here",
            "a third one that is kept",
            "deepest frame a filter might match",
        ])

        let trace = lastCrash(of: countly)?["_error"] as? String ?? ""
        let lines = trace.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4, "no frame is dropped")
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 10, "line was: \(line)")
        }
    }

    func testCrashSegmentationRespectsTheValueCountLimit() {
        let countly = startInstance { $0.sdkInternalLimits.maxSegmentationValues = 2 }

        countly.crashes.recordError("Capped",
                                    isFatal: false,
                                    stackTrace: [],
                                    segmentation: ["a": 1, "b": 2, "c": 3, "d": 4])

        let custom = lastCrash(of: countly)?["_custom"] as? [String: Any] ?? [:]
        XCTAssertEqual(custom.count, 2)
    }
}
