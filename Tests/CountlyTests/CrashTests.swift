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

    func testStackTraceLinesAreTruncatedToTheConfiguredLength() {
        let countly = startInstance {
            $0.sdkInternalLimits.maxStackTraceLineLength = 10
            $0.sdkInternalLimits.maxStackTraceLinesPerThread = 2
        }

        countly.crashes.recordError("Long trace", isFatal: false, stackTrace: [
            "a line that is considerably longer than ten characters",
            "another long line here",
            "a third one that should be dropped",
        ])

        let trace = lastCrash(of: countly)?["_error"] as? String ?? ""
        let lines = trace.split(separator: "\n").map(String.init)
        XCTAssertLessThanOrEqual(lines.count, 2)
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
