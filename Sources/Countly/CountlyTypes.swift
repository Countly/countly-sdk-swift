//
//  CountlyTypes.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

// MARK: - Logging

/// Severity of an internal SDK log line.
///
/// The SDK prints nothing unless `CountlyConfig.enableDebug` is set or a
/// `CountlyLoggerDelegate` is attached. A line is emitted only when its level is
/// less than or equal to the configured `internalLogLevel`.
@objc public enum CountlyLogLevel: Int, CaseIterable, Sendable {
    case none = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4
    case verbose = 5

    /// Prefix used in the emitted log line, e.g. `[Warning]`.
    var label: String {
        switch self {
        case .none: return "None"
        case .error: return "Error"
        case .warning: return "Warning"
        case .info: return "Info"
        case .debug: return "Debug"
        case .verbose: return "Verbose"
        }
    }
}

/// Receives every internal SDK log line the configured level allows.
///
/// Lines arrive already prefixed with `[Countly] [<Level>] `. The delegate is
/// called on whichever thread produced the log, so implementations must be
/// thread safe and must not block.
@objc public protocol CountlyLoggerDelegate: AnyObject {
    func internalLog(_ log: String, level: CountlyLogLevel)
}

// MARK: - Consent

/// A feature that can be individually consented to.
///
/// Raw values are the wire names the server expects in the `consent=` payload.
@objc public enum ConsentFeature: Int, CaseIterable, Sendable {
    case sessions
    case events
    case userDetails
    case crashReporting
    case pushNotifications
    case location
    case viewTracking
    case attribution
    case performanceMonitoring
    case feedback
    case remoteConfig
    case content
    case metrics

    /// The name this feature carries on the wire.
    public var wireName: String {
        switch self {
        case .sessions: return "sessions"
        case .events: return "events"
        case .userDetails: return "users"
        case .crashReporting: return "crashes"
        case .pushNotifications: return "push"
        case .location: return "location"
        case .viewTracking: return "views"
        case .attribution: return "attribution"
        case .performanceMonitoring: return "apm"
        case .feedback: return "feedback"
        case .remoteConfig: return "remote-config"
        case .content: return "content"
        case .metrics: return "metrics"
        }
    }

    /// The feature a wire name refers to, or nil for a name this SDK does not know.
    ///
    /// Public because a bridge SDK receives consent as the wire strings its own
    /// users wrote, and both references accept those directly: Android takes
    /// `giveConsent(String[])` and the Objective-C SDK takes an array of names.
    /// Without this every bridge would carry a duplicate of the table above, which
    /// is exactly how the two drift apart.
    public init?(wireName: String) {
        guard let match = ConsentFeature.byWireName[wireName] else { return nil }
        self = match
    }

    /// Built once, because a bridge translates a whole consent list a name at a time.
    private static let byWireName: [String: ConsentFeature] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.wireName, $0) })
}

// MARK: - Device ID

/// How the current device ID was obtained.
///
/// The raw values are the cross SDK meaning of the `t` query parameter: `0` is
/// an ID the host application supplied and `1` is one the SDK generated. The
/// Objective-C SDK spelled `1` as "IDFV" and used a separate `2` for the
/// platforms it called "NSUUID", but both branches produced a `UUID()` and
/// `identifierForVendor` was never read, so the distinction described nothing.
@objc public enum DeviceIDType: Int, Sendable {
    /// Supplied by the host application.
    case developerSupplied = 0
    /// A UUID this SDK generated and stored.
    case sdkGenerated = 1
    /// Temporary device ID mode: nothing is sent until a real ID is set.
    case temporary = 9

    /// The numeric value sent as the `t` query parameter.
    public var wireValue: Int { rawValue }
}

// MARK: - Features enabled at init

/// Optional features that have to be switched on explicitly at init time.
@objc public enum CountlyFeature: Int, CaseIterable, Sendable {
    case pushNotifications
    case crashReporting
}

// MARK: - Push

/// Which APNs environment the token should be reported against.
@objc public enum PushTestMode: Int, Sendable {
    /// Development / debug builds signed with a development certificate.
    case development
    /// TestFlight or ad hoc builds signed with a distribution certificate.
    case testFlightOrAdHoc

    /// The numeric token-type value sent as the `test_mode` query parameter.
    ///
    /// The server uses this to pick the APNs environment, so getting it backwards
    /// sends every notification to the wrong one and they all fail on a token
    /// minted for the other.
    var wireValue: Int {
        switch self {
        case .development: return 1
        case .testFlightOrAdHoc: return 2
        }
    }
}

// MARK: - Metrics

/// Keys of the device metrics dictionary sent with `begin_session` and metric overrides.
///
/// A class, so Objective-C sees the keys too.
@objc(CountlyMetricKey)
@objcMembers
public final class MetricKey: NSObject {
    public static let device = "_device"
    public static let deviceType = "_device_type"
    public static let os = "_os"
    public static let osVersion = "_os_version"
    public static let appVersion = "_app_version"
    public static let carrier = "_carrier"
    public static let resolution = "_resolution"
    public static let density = "_density"
    public static let locale = "_locale"
    public static let hasWatch = "_has_watch"
    public static let installedWatchApp = "_installed_watch_app"

    private override init() {}
}

/// Keys accepted by `recordIndirectAttribution`.
///
/// A class, so Objective-C sees the keys too.
@objc(CountlyAttributionKey)
@objcMembers
public final class AttributionKey: NSObject {
    public static let idfa = "idfa"
    public static let adid = "adid"

    private override init() {}
}

// MARK: - Request results

/// Outcome of a networked SDK call that reports back to the host application.
@objc public enum RequestResult: Int, Sendable {
    /// The request never reached the server.
    case networkIssue
    /// The server answered and the answer was usable.
    case success
    /// The server answered with an error, or the answer could not be parsed.
    case error
}

// MARK: - Errors

/// Errors surfaced through completion handlers of the public API.
public enum CountlyError: Int, Error, Sendable {
    case feedbackWidgetNotAvailable = 10001
    case feedbackWidgetNotTargetedForDevice = 10002
    case feedbackConsentNotGiven = 10003
    case networkingDisabled = 10004
    case remoteConfigGeneralAPIError = 10011
    case feedbacksGeneralAPIError = 10012
    case serverConfigGeneralAPIError = 10013

    public static let domain = "ly.count.ErrorDomain"

    var localizedDescriptionText: String {
        switch self {
        case .feedbackWidgetNotAvailable: return "Feedback widget is not available."
        case .feedbackWidgetNotTargetedForDevice: return "Feedback widget is not targeted for this device."
        case .feedbackConsentNotGiven: return "Consent is not granted."
        case .networkingDisabled: return "Networking is disabled by the server configuration."
        case .remoteConfigGeneralAPIError: return "Remote Config general API error."
        case .feedbacksGeneralAPIError: return "Feedbacks general API error."
        case .serverConfigGeneralAPIError: return "Server Config general API error."
        }
    }

    /// Bridged `NSError` so Objective-C hosts and existing integrations see the same
    /// domain and codes the Objective-C SDK produced.
    public var asNSError: NSError {
        NSError(domain: CountlyError.domain,
                code: rawValue,
                userInfo: [NSLocalizedDescriptionKey: localizedDescriptionText])
    }
}
