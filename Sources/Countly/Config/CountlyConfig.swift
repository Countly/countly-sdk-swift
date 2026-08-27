//
//  CountlyConfig.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation
import CoreLocation

/// Everything the SDK needs at init, in one object.
///
/// Nothing here takes effect until the object is handed to
/// `Countly.initShared(_:)` or `CountlyInstance.start(with:)`. The instance takes
/// a snapshot at that point, so mutating the config afterwards does nothing.
public final class CountlyConfig {

    // MARK: - Required

    /// URL of the Countly server, for example `https://try.count.ly`.
    public var host: String = ""

    /// App key of the dashboard application this data belongs to.
    public var appKey: String = ""

    // MARK: - Instance identity

    /// Name of the instance this config belongs to.
    ///
    /// Advisory. The registry key passed to `Countly.instance(named:)` is what
    /// actually decides storage isolation; this is validated against it at init
    /// and a mismatch is logged. Leave it unset for the default instance.
    public var instanceName: String?

    // MARK: - Logging

    /// Prints SDK logs to the console in debug builds and enables the logger
    /// delegate in every build.
    public var enableDebug: Bool = false

    /// Highest severity that is emitted. Default `.debug`, so verbose stays an
    /// explicit opt-in.
    public var internalLogLevel: CountlyLogLevel = .debug

    /// Receives every emitted log line. Held weakly by the SDK.
    ///
    /// This path is live in release builds. Treat the lines as a production
    /// privacy surface, not a debug-only convenience.
    public weak var loggerDelegate: CountlyLoggerDelegate?

    // MARK: - Features

    /// Features that have to be switched on explicitly, such as push
    /// notifications and crash reporting.
    public var features: [CountlyFeature] = []

    /// Extra metrics merged into the metrics dictionary sent with sessions.
    public var customMetrics: [String: String] = [:]

    // MARK: - Views

    /// Reports a view every time a view controller appears.
    public var enableAutomaticViewTracking: Bool = false

    /// View names that automatic view tracking skips.
    public var automaticViewTrackingExclusionList: [String] = []

    /// Segmentation merged into every view event.
    public var globalViewSegmentation: [String: Any]?

    /// Stops a paused view from being restarted when the application returns to
    /// the foreground, for views that were started manually.
    public var disableViewRestartForManualRecording: Bool = false

    // MARK: - Consent

    /// Withholds every feature until consent for it is given.
    public var requiresConsent: Bool = false

    /// Features consented to at init time.
    public var consents: [ConsentFeature] = []

    /// Grants consent for every feature at init time. Overrides `consents`.
    public var enableAllConsents: Bool = false

    // MARK: - Push notifications

    /// APNs environment the push token belongs to. Leave `nil` to let the SDK
    /// infer it from the build's provisioning profile.
    public var pushTestMode: PushTestMode?

    /// Sends the push token even when push consent has not been given, so the
    /// server can hold it until consent arrives.
    public var sendPushTokenAlways: Bool = false

    /// Leaves the application delegate and the notification centre delegate alone.
    ///
    /// The SDK normally installs itself on both, chaining to whatever the host
    /// application already has, so the device token is reported and a tapped
    /// notification records its action and opens its URL without the host writing
    /// any code. Set this when the host would rather wire it up itself, and then
    /// forward `Countly.didRegisterForRemoteNotifications(deviceToken:)` and
    /// `push.recordAction(for:clickedButtonIndex:)` by hand.
    public var disableAutomaticPushHandling: Bool = false

    /// The `userInfo` of the `NSApplication.didFinishLaunchingNotification` that
    /// started the application, on macOS.
    ///
    /// macOS hands a notification that launched the application to the application
    /// delegate rather than to the notification centre delegate, and it has already
    /// been delivered by the time the SDK could observe it. Passing it here is the
    /// only way for a click that cold started the application to be recorded as a
    /// push action and to open its URL. Ignored everywhere else, where the
    /// notification centre delegate receives it directly.
    ///
    /// ```swift
    /// func applicationDidFinishLaunching(_ notification: Notification) {
    ///     config.launchNotification = notification.userInfo
    ///     Countly.shared.start(with: config)
    /// }
    /// ```
    public var launchNotification: [AnyHashable: Any]?

    /// Suppresses the SDK's own alert for notifications received in the
    /// foreground.
    public var doNotShowAlertForNotifications: Bool = false

    // MARK: - Location

    /// Coordinates reported with the session. Defaults to an invalid coordinate,
    /// meaning "not provided".
    public var location: CLLocationCoordinate2D = kCLLocationCoordinate2DInvalid

    /// City name reported with the session.
    public var city: String?

    /// ISO country code reported with the session.
    public var isoCountryCode: String?

    /// IP address the server should geolocate instead of the request's own.
    public var ipAddress: String?

    /// Tells the server to discard location for this device entirely.
    public var disableLocation: Bool = false

    // MARK: - Device ID

    /// Device ID to use. Leave `nil` to let the SDK pick the platform default.
    public var deviceID: String?

    /// Starts in temporary device ID mode: nothing leaves the device until a
    /// real device ID is set.
    public var temporaryDeviceIDMode: Bool = false

    /// Discards a device ID stored by a previous run before resolving the ID for
    /// this run.
    public var resetStoredDeviceID: Bool = false

    // MARK: - Queues and timing

    /// How often a session update is sent while the application is in the
    /// foreground, in seconds. Default 60, or 20 on watchOS.
    public var updateSessionPeriod: TimeInterval = {
        #if os(watchOS)
        return 20.0
        #else
        return 60.0
        #endif
    }()

    /// How many recorded events accumulate before the SDK sends them. Default 100.
    public var eventSendThreshold: Int = 100

    /// Maximum number of requests held on disk. The oldest are dropped past this.
    /// Default 1000.
    public var storedRequestsLimit: Int = 1000

    /// Requests older than this are dropped instead of sent. Zero disables age
    /// based dropping.
    public var requestDropAgeHours: Int = 0

    /// Per-request timeout in seconds. Default 30.
    public var requestTimeoutDuration: TimeInterval = 30

    /// Sends every request as POST, whatever its length.
    public var alwaysUsePOST: Bool = false

    // MARK: - Sessions

    /// Turns off automatic session handling. The host application drives
    /// `beginSession` / `updateSession` / `endSession` itself.
    public var manualSessionHandling: Bool = false

    /// With manual session handling on, still sends automatic session updates on
    /// the update timer.
    public var enableManualSessionControlHybridMode: Bool = false

    // MARK: - User profile

    /// User properties applied before the first request leaves the device.
    public var providedUserProperties: [String: Any]?

    // MARK: - Attribution

    /// Campaign type for direct attribution.
    public var campaignType: String?

    /// Campaign data for direct attribution.
    public var campaignData: String?

    /// Indirect attribution keys, see `AttributionKey`.
    public var indirectAttribution: [String: String]?

    // MARK: - Crash reporting

    /// Segmentation merged into every crash report.
    public var crashSegmentation: [String: Any]?

    /// Crash reports whose stack trace matches are dropped.
    public var crashFilter: NSRegularExpression?

    /// Last word on whether a crash report is sent. Return `false` to drop it.
    public var shouldSendCrashReportCallback: (([String: Any]) -> Bool)?

    // MARK: - Networking

    /// Names of certificate files bundled with the application. The server's key
    /// must match one of them. Empty means no pinning.
    public var pinnedCertificates: [String] = []

    /// Salt appended before the request checksum is computed. Must match the
    /// server's configured salt.
    public var secretSalt: String?

    /// Session configuration used for every request the SDK makes.
    public var urlSessionConfiguration: URLSessionConfiguration = .default

    /// Skips server trust evaluation. Debug builds and local servers only.
    public var shouldIgnoreTrustCheck: Bool = false

    /// Headers added to every request the SDK makes.
    public var customNetworkRequestHeaders: [String: String]?

    // MARK: - Remote config

    /// Downloads remote config values at init and after a device ID change.
    public var enableRemoteConfigAutomaticTriggers: Bool = false

    /// Keeps previously downloaded values that the latest download did not
    /// return, instead of clearing them.
    public var enableRemoteConfigValueCaching: Bool = false

    /// Enrolls the device in the A/B tests of every key it downloads.
    public var enrollABOnRCDownload: Bool = false

    /// Callbacks notified after each remote config download.
    public private(set) var remoteConfigGlobalCallbacks: [RCDownloadCallback] = []

    /// Registers a callback notified after each remote config download.
    public func remoteConfigRegisterGlobalCallback(_ callback: @escaping RCDownloadCallback) {
        remoteConfigGlobalCallbacks.append(callback)
    }

    // MARK: - Orientation

    /// Records an orientation event when the device rotates. Default on.
    public var enableOrientationTracking: Bool = true

    // MARK: - Server behavior settings

    /// Behavior settings supplied by the host application as a JSON string,
    /// applied before the first server fetch answers.
    public var sdkBehaviorSettings: String?

    /// Stops the SDK from fetching behavior settings from the server.
    public var disableSDKBehaviorSettingsUpdates: Bool = false

    /// Turns off the request backoff mechanism.
    public var disableBackoffMechanism: Bool = false

    // MARK: - Sub-configurations

    /// Caps applied to keys, values and segmentation.
    public let sdkInternalLimits = CountlySDKLimitsConfig()

    /// Crash reporting settings.
    public let crashes = CountlyCrashesConfig()

    /// Performance monitoring settings.
    public let apm = CountlyAPMConfig()

    /// Content zone settings.
    public let content = CountlyContentConfig()

    /// Features that are still being shaped.
    public let experimental = CountlyExperimentalConfig()

    // MARK: - Init

    public init() {}

    /// Convenience initializer for the two values every integration must set.
    public convenience init(appKey: String, host: String) {
        self.init()
        self.appKey = appKey
        self.host = host
    }

    // MARK: - Validation

    /// Why an init attempt was rejected.
    enum ValidationFailure {
        case missingAppKey
        case missingHost

        var message: String {
            switch self {
            case .missingAppKey:
                return "the appKey on the config object is missing or still holds the placeholder value, initialization will be aborted"
            case .missingHost:
                return "the host on the config object is missing or still holds the placeholder value, initialization will be aborted"
            }
        }
    }

    /// Checks the two values that make the SDK unusable when wrong.
    ///
    /// Returns the failure rather than throwing, so the caller decides whether to
    /// abort loudly or degrade. The SDK never takes down the host application
    /// over a configuration mistake.
    func validate() -> ValidationFailure? {
        if appKey.isEmpty || appKey == Placeholder.appKey { return .missingAppKey }
        if host.isEmpty || host == Placeholder.host { return .missingHost }
        return nil
    }

    /// Host with any trailing slashes removed, which is how every request URL is
    /// built.
    var normalizedHost: String {
        var result = host
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
