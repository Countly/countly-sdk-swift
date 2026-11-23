//
//  PrivacyManifestTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// The privacy manifest the Countly library ships in its resource bundle.
///
/// App Store Connect refuses an app whose code calls an API Apple asks a reason
/// for, such as user defaults or the free disk space, unless a privacy manifest
/// in the app gives the reason. The SDK calls several of them, so it declares
/// them itself, together with collected data types for Xcode's privacy report.
final class PrivacyManifestTests: XCTestCase {

    /// The APIs Apple asks a reason for, by category, as Swift spells them. An
    /// API counts as called wherever its name appears as a whole word on a line
    /// that is not a comment, so a mention in a string counts too.
    private static let requiredReasonAPIs: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp": [
            "creationDate", "modificationDate", "fileModificationDate", "contentModificationDateKey",
            "creationDateKey", "getattrlist", "getattrlistbulk", "fgetattrlist", "getattrlistat",
            "stat", "fstat", "fstatat", "lstat",
        ],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
        "NSPrivacyAccessedAPICategoryDiskSpace": [
            "volumeAvailableCapacityKey", "volumeAvailableCapacityForImportantUsageKey",
            "volumeAvailableCapacityForOpportunisticUsageKey", "volumeTotalCapacityKey",
            "systemFreeSize", "systemSize", "statfs", "statvfs", "fstatfs", "fstatvfs",
            "getattrlist", "fgetattrlist", "getattrlistat",
        ],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults", "AppStorage"],
    ]

    // MARK: - Shipping

    /// The manifest reaches an app only through the package's resource bundle, so
    /// it is read from there, with the four keys Apple defines and nothing else.
    func testTheCountlyLibraryShipsAPrivacyManifest() throws {
        let manifest = try shippedManifest()

        XCTAssertEqual(Set(manifest.keys), [
            "NSPrivacyTracking",
            "NSPrivacyTrackingDomains",
            "NSPrivacyCollectedDataTypes",
            "NSPrivacyAccessedAPITypes",
        ])
    }

    // MARK: - Required reason APIs

    /// Each category once, with one reason: user defaults hold the SDK's own
    /// state, the free and total disk space go into crash reports, and the system
    /// uptime measures durations and waits inside the app.
    func testEachCalledCategoryIsDeclaredWithItsReason() throws {
        let manifest = try shippedManifest()

        XCTAssertEqual(manifest["NSPrivacyAccessedAPITypes"] as? NSArray, [
            accessedAPI("NSPrivacyAccessedAPICategoryUserDefaults", reason: "CA92.1"),
            accessedAPI("NSPrivacyAccessedAPICategoryDiskSpace", reason: "7D9E.1"),
            accessedAPI("NSPrivacyAccessedAPICategorySystemBootTime", reason: "35F9.1"),
        ] as NSArray)
    }

    /// App Store Connect reads the code, not the intent: a category the SDK calls
    /// without declaring it gets every app that links the SDK refused. A category
    /// declared but no longer called would claim more than the SDK does.
    func testTheDeclaredCategoriesAreTheOnesTheLibraryCalls() throws {
        let entries = try XCTUnwrap(shippedManifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let declared = Set(entries.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })

        XCTAssertEqual(try categoriesCalled(inSourceFolder: "Sources/Countly"), declared)
    }

    /// The notification service product ships no manifest of its own, so it must
    /// call none of these APIs.
    func testTheNotificationServiceCallsNoRequiredReasonAPI() throws {
        XCTAssertEqual(try categoriesCalled(inSourceFolder: "Sources/CountlyNotificationService"), [])
    }

    // MARK: - Tracking and collected data

    /// The SDK sends data only to the app's own Countly server and never links it
    /// with data from other companies' apps or websites.
    func testTheManifestDeclaresNoTracking() throws {
        let manifest = try shippedManifest()

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
    }

    /// The same collected data types countly-sdk-ios declares: both SDKs send the
    /// same requests, so an app moving between them keeps the same privacy report.
    /// Data the app passes in, such as user properties, is the app's to declare.
    func testTheManifestDeclaresTheDataTheSDKCollects() throws {
        let manifest = try shippedManifest()

        XCTAssertEqual(manifest["NSPrivacyCollectedDataTypes"] as? NSArray, [
            collectedData("NSPrivacyCollectedDataTypePerformanceData", linked: false,
                          purpose: "NSPrivacyCollectedDataTypePurposeAnalytics"),
            collectedData("NSPrivacyCollectedDataTypeCrashData", linked: false,
                          purpose: "NSPrivacyCollectedDataTypePurposeAnalytics"),
            collectedData("NSPrivacyCollectedDataTypeDeviceID", linked: true,
                          purpose: "NSPrivacyCollectedDataTypePurposeAnalytics"),
            collectedData("NSPrivacyCollectedDataTypeOtherDiagnosticData", linked: true,
                          purpose: "NSPrivacyCollectedDataTypePurposeAppFunctionality"),
        ] as NSArray)
    }

    // MARK: - Helpers

    /// The manifest as Xcode reads it from the Countly resource bundle.
    private func shippedManifest() throws -> [String: Any] {
        // The Countly target's accessor, reached through `@testable import`: this
        // test target has no resources, so it has no `Bundle.module` of its own.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "The Countly resource bundle carries no PrivacyInfo.xcprivacy")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(plist as? [String: Any], "PrivacyInfo.xcprivacy is not a dictionary")
    }

    /// The categories of `requiredReasonAPIs` that the Swift files in a folder of
    /// the package call. The files are read from where this test file was
    /// compiled, so this runs where the sources are: on a Mac or a simulator.
    private func categoriesCalled(inSourceFolder folder: String) throws -> Set<String> {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: packageRoot.appendingPathComponent(folder),
                                                                 includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "No Swift files found in \(folder)")

        let notInIdentifiers = CharacterSet(charactersIn: "_").union(.alphanumerics).inverted
        var words = Set<String>()
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            words.formUnion(code.joined(separator: "\n").components(separatedBy: notInIdentifiers))
        }
        return Set(Self.requiredReasonAPIs.filter { !words.isDisjoint(with: $0.value) }.keys)
    }

    /// One entry of `NSPrivacyAccessedAPITypes`.
    private func accessedAPI(_ category: String, reason: String) -> NSDictionary {
        [
            "NSPrivacyAccessedAPIType": category,
            "NSPrivacyAccessedAPITypeReasons": [reason],
        ]
    }

    /// One entry of `NSPrivacyCollectedDataTypes`, never used for tracking.
    private func collectedData(_ type: String, linked: Bool, purpose: String) -> NSDictionary {
        [
            "NSPrivacyCollectedDataType": type,
            "NSPrivacyCollectedDataTypeLinked": linked,
            "NSPrivacyCollectedDataTypeTracking": false,
            "NSPrivacyCollectedDataTypePurposes": [purpose],
        ]
    }
}
