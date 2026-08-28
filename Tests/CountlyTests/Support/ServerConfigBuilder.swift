//
//  ServerConfigBuilder.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation
@testable import Countly

/// Builds the behavior settings document the server sends, for tests that need the
/// SDK to be configured the way a real deployment would configure it.
///
/// Tests go through this rather than writing the resolved fields on `ServerConfig`
/// directly, because the parsing, the unknown-key pruning and the version/timestamp
/// guard are themselves behaviour worth exercising. The document is handed to the
/// SDK through `config.sdkBehaviorSettings`, which is the same path a developer
/// supplied bootstrap takes.
///
/// The counterpart of `ServerConfigBuilder` in the Android and Objective-C suites,
/// with the same key names, because the keys are the wire contract.
final class ServerConfigBuilder {

    private var settings: [String: Any] = [:]

    // MARK: - Switches

    @discardableResult
    func tracking(_ enabled: Bool) -> Self { set("tracking", enabled) }

    @discardableResult
    func networking(_ enabled: Bool) -> Self { set("networking", enabled) }

    @discardableResult
    func sessionTracking(_ enabled: Bool) -> Self { set("st", enabled) }

    @discardableResult
    func viewTracking(_ enabled: Bool) -> Self { set("vt", enabled) }

    @discardableResult
    func locationTracking(_ enabled: Bool) -> Self { set("lt", enabled) }

    @discardableResult
    func crashReporting(_ enabled: Bool) -> Self { set("crt", enabled) }

    @discardableResult
    func customEventTracking(_ enabled: Bool) -> Self { set("cet", enabled) }

    @discardableResult
    func consentRequired(_ required: Bool) -> Self { set("cr", required) }

    @discardableResult
    func backoffMechanism(_ enabled: Bool) -> Self { set("bom", enabled) }

    @discardableResult
    func automaticSessionTracking(_ enabled: Bool) -> Self { set("ast", enabled) }

    @discardableResult
    func automaticViewTracking(_ enabled: Bool) -> Self { set("avt", enabled) }

    // MARK: - Sizes and limits

    @discardableResult
    func requestQueueSize(_ size: Int) -> Self { set("rqs", size) }

    @discardableResult
    func eventQueueSize(_ size: Int) -> Self { set("eqs", size) }

    @discardableResult
    func sessionUpdateInterval(_ seconds: Int) -> Self { set("sui", seconds) }

    @discardableResult
    func dropOldRequestTime(_ hours: Int) -> Self { set("dort", hours) }

    @discardableResult
    func maxKeyLength(_ length: Int) -> Self { set("lkl", length) }

    @discardableResult
    func maxValueSize(_ size: Int) -> Self { set("lvs", size) }

    @discardableResult
    func maxSegmentationValues(_ count: Int) -> Self { set("lsv", count) }

    @discardableResult
    func maxBreadcrumbCount(_ count: Int) -> Self { set("lbc", count) }

    @discardableResult
    func maxStackTraceLineLength(_ length: Int) -> Self { set("ltl", length) }

    @discardableResult
    func maxStackTraceLinesPerThread(_ count: Int) -> Self { set("ltlpt", count) }

    @discardableResult
    func userPropertyCacheLimit(_ limit: Int) -> Self { set("upcl", limit) }

    // MARK: - Listing filters

    @discardableResult
    func eventBlacklist(_ keys: [String]) -> Self { set("eb", keys) }

    @discardableResult
    func eventWhitelist(_ keys: [String]) -> Self { set("ew", keys) }

    @discardableResult
    func userPropertyBlacklist(_ keys: [String]) -> Self { set("upb", keys) }

    @discardableResult
    func userPropertyWhitelist(_ keys: [String]) -> Self { set("upw", keys) }

    @discardableResult
    func segmentationBlacklist(_ keys: [String]) -> Self { set("sb", keys) }

    @discardableResult
    func segmentationWhitelist(_ keys: [String]) -> Self { set("sw", keys) }

    @discardableResult
    func eventSegmentationBlacklist(_ map: [String: [String]]) -> Self { set("esb", map) }

    @discardableResult
    func eventSegmentationWhitelist(_ map: [String: [String]]) -> Self { set("esw", map) }

    @discardableResult
    func journeyTriggerEvents(_ keys: [String]) -> Self { set("jte", keys) }

    @discardableResult
    func journeyTriggerViews(_ names: [String]) -> Self { set("jtv", names) }

    /// A key the SDK does not know, for asserting that unknown keys are pruned
    /// rather than carried into the cache.
    @discardableResult
    func unknown(_ key: String, _ value: Any) -> Self { set(key, value) }

    // MARK: - Building

    private func set(_ key: String, _ value: Any) -> Self {
        settings[key] = value
        return self
    }

    /// The full document, wrapped in the version and timestamp the SDK requires
    /// before it will apply anything at all.
    func document(version: Int = 1, timestamp: Int64 = 1_700_000_000_000) -> [String: Any] {
        ["v": version, "t": timestamp, "c": settings]
    }

    /// The document as the JSON string `config.sdkBehaviorSettings` takes.
    func json(version: Int = 1, timestamp: Int64 = 1_700_000_000_000) -> String {
        let data = try! JSONSerialization.data(withJSONObject: document(version: version,
                                                                       timestamp: timestamp))
        return String(decoding: data, as: UTF8.self)
    }

    /// The body a `/o/sdk?method=sc` response carries, for tests that answer the
    /// fetch instead of seeding the cache.
    func responseJSON(version: Int = 1, timestamp: Int64 = 1_700_000_000_000) -> String {
        json(version: version, timestamp: timestamp)
    }
}
