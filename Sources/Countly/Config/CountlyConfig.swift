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
/// `CountlyInstance.start(with:)`. The instance takes a snapshot at that point, so
/// mutating the config afterwards does nothing, and neither the server's behavior
/// settings nor calls such as `setNewAppKey` change it: one object can start
/// several instances, or the same instance again after a halt.
@objcMembers
public final class CountlyConfig: NSObject {

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
    /// and a mismatch is logged. Leave it unset for the default instance, which is
    /// reached through `Countly.shared`: `Countly.instance(named:)` refuses an
    /// empty name, and a `nil` passed from Objective-C arrives as one.
    public var instanceName: String?

    // MARK: - Logging

    /// Prints SDK logs to the console, in release builds as well unless
    /// ``disableSDKLoggingInProduction`` is set. The ``loggerDelegate`` receives
    /// the lines whether or not this is set.
    public var enableDebug: Bool = false

    /// Keeps console logs off in release builds even when ``enableDebug`` is set,
    /// because the console of a published application can be read by other
    /// applications and by anyone holding the device. The logger delegate and log
    /// gathering are not affected. Off by default.
    public var disableSDKLoggingInProduction: Bool = false

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

    /// `features` for Objective-C, as `CountlyFeature` values.
    @available(swift, obsoleted: 1)
    @objc(features)
    public var objcFeatures: [NSNumber] {
        get { features.map { NSNumber(value: $0.rawValue) } }
        set { features = newValue.compactMap { CountlyFeature(rawValue: $0.intValue) } }
    }

    /// Extra metrics merged into the metrics dictionary sent with sessions.
    public var customMetrics: [String: String] = [:]

    // MARK: - SDK identity

    /// Name this SDK reports as, on `sdk_name`. Leave nil for the built-in value.
    ///
    /// For a bridge SDK, not for an application. A Flutter, React Native or Unity
    /// integration wraps this SDK and has to report itself, or every request from
    /// it is attributed to the native SDK and the dashboard cannot tell the two
    /// apart. The Objective-C SDK exposes the same through `CountlyCommon.SDKName`
    /// and Android through `Countly.COUNTLY_SDK_NAME`.
    ///
    /// Blank or whitespace is ignored, since a name is required on the wire.
    public var sdkName: String?

    /// Version this SDK reports as, on `sdk_version`. Leave nil for the built-in
    /// value. A bridge sets its own version here, the counterpart to ``sdkName``.
    public var sdkVersion: String?

    // MARK: - Views

    /// Reports a view every time a view controller appears.
    public var enableAutomaticViewTracking: Bool = false

    /// Stops the SDK from exchanging `UIViewController.viewDidAppear` and
    /// `viewDidDisappear` implementations.
    ///
    /// That exchange is the only thing automatic view tracking watches, so this
    /// also turns automatic view tracking off, whatever
    /// ``enableAutomaticViewTracking`` says. Report screens with ``ViewsAPI`` or
    /// the SwiftUI `countlyView(_:segmentation:instance:)` modifier instead.
    ///
    /// It also holds against SDK behavior settings, which can otherwise switch
    /// automatic view tracking on from the server.
    ///
    /// Two things it does not cover:
    /// - Other instances. The exchange is process-wide and never uninstalled, so
    ///   an instance that allows it installs it for the process; this flag only
    ///   decides whether *this* instance asks for it and listens to it.
    /// - Push handling, which adds the registration callbacks to the application
    ///   delegate at runtime. Turn that off with ``disableAutomaticPushHandling``.
    public var disableSwizzling: Bool = false

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

    /// `consents` for Objective-C, as `ConsentFeature` values.
    @available(swift, obsoleted: 1)
    @objc(consents)
    public var objcConsents: [NSNumber] {
        get { consents.map { NSNumber(value: $0.rawValue) } }
        set { consents = newValue.compactMap { ConsentFeature(rawValue: $0.intValue) } }
    }

    /// Grants consent for every feature at init time. Overrides `consents`.
    public var enableAllConsents: Bool = false

    // MARK: - Push notifications

    /// APNs environment the push token belongs to. Leave `nil` for App Store
    /// builds, which are reported as production. Set `.development` for builds
    /// signed with a development profile, such as debug builds run from Xcode, and
    /// `.testFlightOrAdHoc` for TestFlight and ad hoc builds.
    public var pushTestMode: PushTestMode?

    /// `pushTestMode` for Objective-C, a `PushTestMode` value or `nil`.
    @available(swift, obsoleted: 1)
    @objc(pushTestMode)
    public var objcPushTestMode: NSNumber? {
        get { pushTestMode.map { NSNumber(value: $0.rawValue) } }
        set { pushTestMode = newValue.flatMap { PushTestMode(rawValue: $0.intValue) } }
    }

    /// Sends the push token even when the user has not allowed the application to
    /// show notifications, so silent pushes can reach it. Push consent is still
    /// needed. A device that cannot show notifications still counts as reached in
    /// a visible campaign, so set this only when the application relies on silent
    /// pushes.
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

    /// Lets the application handle the link of a tapped Countly notification
    /// itself, for example to route its own deep link to the right screen.
    ///
    /// Called on the main thread with the link of the tapped part, the body's or
    /// the button's, or `nil` when it has none or it is not a URL, and the
    /// notification's `userInfo`. Return `true` when the application took the link
    /// over and the SDK opens nothing, `false` to let the SDK open it. The push
    /// action is recorded before the handler runs, whatever it returns.
    public var pushActionHandler: PushActionHandler?

    /// The URI schemes notification links may open, compared without case, for
    /// example `["https", "myapp"]`.
    ///
    /// Empty by default, which allows every scheme except the dangerous ones:
    /// file, content, javascript, jar, zip, intent and data. A refused link is not
    /// opened and is logged as a warning; the push action is still recorded.
    public var pushAllowedLinkSchemes: [String] = []

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

    /// Per-request timeout in seconds, at least 1. Default 30.
    public var requestTimeoutDuration: TimeInterval = 30

    /// How long the SDK waits after a failed request before it tries the same
    /// request again, in seconds, at least 1. Default 60. Requests recorded and
    /// timer ticks in between do not start an earlier attempt.
    public var failedRequestCooldown: TimeInterval = 60

    /// Trims a request queue that is over ``storedRequestsLimit`` in one step.
    /// By default the SDK removes at most 100 of the overflow per new request, so a
    /// queue far over its limit, for example after the server lowered it, shrinks
    /// step by step instead of losing a large backlog at once.
    public var disableGradualRequestCleaner: Bool = false

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
    public internal(set) var remoteConfigGlobalCallbacks: [RCDownloadCallback] = []

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

    /// Turns off the request backoff mechanism. The server's behavior settings
    /// still turn it on or off while they contain `bom`.
    public var disableBackoffMechanism: Bool = false

    // MARK: - Health check

    /// Stops the health check request the SDK sends once per start. The counters
    /// still accumulate, but nothing is reported.
    public var disableHealthCheck: Bool = false

    // MARK: - Web views

    /// Turns off every web view the SDK would show. Content is not fetched or
    /// shown, and feedback widgets are not presented: their callbacks get an
    /// error. Getting the widget list and widget data, and reporting a widget
    /// manually, keep working, so an application can show widgets in its own UI.
    public var disableWebView: Bool = false

    // MARK: - Sub-configurations

    /// Caps applied to keys, values and segmentation.
    public let sdkInternalLimits = CountlySDKLimitsConfig()

    /// Crash reporting settings.
    public let crashes = CountlyCrashesConfig()

    /// Content zone settings.
    public let content = CountlyContentConfig()

    /// Features that are still being shaped.
    public let experimental = CountlyExperimentalConfig()

    // MARK: - Init

    public override init() {}

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
        case invalidHost
        case pinningRequiresHTTPS

        var message: String {
            switch self {
            case .missingAppKey:
                return "the appKey on the config object is missing or still holds the placeholder value, initialization will be aborted"
            case .missingHost:
                return "the host on the config object is missing or still holds the placeholder value, initialization will be aborted"
            case .invalidHost:
                return "the host on the config object is not an absolute URL with an http or https scheme, initialization will be aborted"
            case .pinningRequiresHTTPS:
                return "certificate pinning is configured but the host does not use https, initialization will be aborted"
            }
        }
    }

    /// Checks the values that make the SDK unusable when wrong.
    ///
    /// Returns the failure rather than throwing, so the caller decides whether to
    /// abort loudly or degrade. The SDK never takes down the host application
    /// over a configuration mistake.
    func validate() -> ValidationFailure? {
        if appKey.isEmpty || appKey == Placeholder.appKey { return .missingAppKey }
        if host.isEmpty || host == Placeholder.host { return .missingHost }
        guard Self.isValidServerURL(normalizedHost) else { return .invalidHost }
        if !pinnedCertificates.isEmpty, !Self.usesHTTPS(normalizedHost) { return .pinningRequiresHTTPS }
        return nil
    }

    /// Whether `value` is an absolute URL with an http or https scheme and a host.
    static func isValidServerURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else { return false }
        return true
    }

    /// Whether `value` uses the https scheme.
    static func usesHTTPS(_ value: String) -> Bool {
        URLComponents(string: value)?.scheme?.lowercased() == "https"
    }

    /// The default of ``updateSessionPeriod``: 60 seconds, or 20 on watchOS,
    /// where applications run only briefly.
    static var defaultUpdateSessionPeriod: TimeInterval {
        #if os(watchOS)
        return 20.0
        #else
        return 60.0
        #endif
    }

    /// The shortest ``failedRequestCooldown`` the SDK accepts, in seconds.
    static var minimumFailedRequestCooldown: TimeInterval = 1

    /// Puts the default back for every option whose value is outside its valid
    /// range, with a warning for each. The SDK never raises, lowers or cuts a value
    /// to make it fit.
    ///
    /// - Returns: How many options were reset.
    @discardableResult
    func resetInvalidValues(logger: Logger) -> Int {
        var resetCount = 0
        func reject(_ option: String, _ value: Any, _ fallback: Any) {
            resetCount += 1
            logger.w("Countly", "start", "a config option has an invalid value, the value is ignored and the default is used, option: [\(option)], value: [\(value)], default: [\(fallback)]")
            logger.healthTracker?.recordLogCode(HealthLogCode.invalidSetting)
        }

        if updateSessionPeriod < 1 {
            reject("updateSessionPeriod", updateSessionPeriod, Self.defaultUpdateSessionPeriod)
            updateSessionPeriod = Self.defaultUpdateSessionPeriod
        }
        if eventSendThreshold < 1 {
            reject("eventSendThreshold", eventSendThreshold, 100)
            eventSendThreshold = 100
        }
        if storedRequestsLimit < 1 {
            reject("storedRequestsLimit", storedRequestsLimit, 1000)
            storedRequestsLimit = 1000
        }
        if requestDropAgeHours < 0 {
            reject("requestDropAgeHours", requestDropAgeHours, 0)
            requestDropAgeHours = 0
        }
        if requestTimeoutDuration < 1 {
            reject("requestTimeoutDuration", requestTimeoutDuration, 30)
            requestTimeoutDuration = 30
        }
        if failedRequestCooldown < Self.minimumFailedRequestCooldown {
            reject("failedRequestCooldown", failedRequestCooldown, 60)
            failedRequestCooldown = 60
        }
        if content.contentReloadOnStallTimeout < 1 {
            reject("contentReloadOnStallTimeout", content.contentReloadOnStallTimeout, 1000)
            content.contentReloadOnStallTimeout = 1000
        }
        if content.zoneTimerInterval < CountlyContentConfig.minimumZoneTimerInterval {
            reject("zoneTimerInterval", content.zoneTimerInterval, CountlyContentConfig.defaultZoneTimerInterval)
            content.zoneTimerInterval = CountlyContentConfig.defaultZoneTimerInterval
        }
        for (key, value) in customMetrics where key.isEmpty || value.isEmpty {
            resetCount += 1
            logger.w("Countly", "start", "a metric override with an empty key or value is skipped, key: [\(key)]")
            logger.healthTracker?.recordLogCode(HealthLogCode.invalidSetting)
            customMetrics.removeValue(forKey: key)
        }
        sdkInternalLimits.resetInvalidValues { name, value, fallback in
            reject(name, value, fallback)
        }

        return resetCount
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

    // MARK: - Snapshot

    /// The copy an instance runs on, so that what the SDK changes on it while
    /// running, the server's behavior settings among them, never reaches the
    /// caller's object.
    ///
    /// Every stored property is copied, and each sub-configuration as a copy of
    /// its own. The session configuration is copied too, since the SDK sets its
    /// timeouts. Callbacks and the logger delegate are shared, not copied.
    func snapshot() -> CountlyConfig {
        let copy = CountlyConfig()

        copy.host = host
        copy.appKey = appKey
        copy.instanceName = instanceName

        copy.enableDebug = enableDebug
        copy.disableSDKLoggingInProduction = disableSDKLoggingInProduction
        copy.internalLogLevel = internalLogLevel
        copy.loggerDelegate = loggerDelegate

        copy.features = features
        copy.customMetrics = customMetrics

        copy.sdkName = sdkName
        copy.sdkVersion = sdkVersion

        copy.enableAutomaticViewTracking = enableAutomaticViewTracking
        copy.disableSwizzling = disableSwizzling
        copy.automaticViewTrackingExclusionList = automaticViewTrackingExclusionList
        copy.globalViewSegmentation = globalViewSegmentation
        copy.disableViewRestartForManualRecording = disableViewRestartForManualRecording

        copy.requiresConsent = requiresConsent
        copy.consents = consents
        copy.enableAllConsents = enableAllConsents

        copy.pushTestMode = pushTestMode
        copy.sendPushTokenAlways = sendPushTokenAlways
        copy.disableAutomaticPushHandling = disableAutomaticPushHandling
        copy.launchNotification = launchNotification
        copy.doNotShowAlertForNotifications = doNotShowAlertForNotifications
        copy.pushActionHandler = pushActionHandler
        copy.pushAllowedLinkSchemes = pushAllowedLinkSchemes

        copy.location = location
        copy.city = city
        copy.isoCountryCode = isoCountryCode
        copy.ipAddress = ipAddress
        copy.disableLocation = disableLocation

        copy.deviceID = deviceID
        copy.temporaryDeviceIDMode = temporaryDeviceIDMode
        copy.resetStoredDeviceID = resetStoredDeviceID

        copy.updateSessionPeriod = updateSessionPeriod
        copy.eventSendThreshold = eventSendThreshold
        copy.storedRequestsLimit = storedRequestsLimit
        copy.requestDropAgeHours = requestDropAgeHours
        copy.requestTimeoutDuration = requestTimeoutDuration
        copy.failedRequestCooldown = failedRequestCooldown
        copy.disableGradualRequestCleaner = disableGradualRequestCleaner

        copy.manualSessionHandling = manualSessionHandling
        copy.enableManualSessionControlHybridMode = enableManualSessionControlHybridMode

        copy.providedUserProperties = providedUserProperties

        copy.campaignType = campaignType
        copy.campaignData = campaignData
        copy.indirectAttribution = indirectAttribution

        copy.crashSegmentation = crashSegmentation

        copy.pinnedCertificates = pinnedCertificates
        copy.secretSalt = secretSalt
        copy.urlSessionConfiguration = (urlSessionConfiguration.copy() as? URLSessionConfiguration) ?? urlSessionConfiguration
        copy.shouldIgnoreTrustCheck = shouldIgnoreTrustCheck
        copy.customNetworkRequestHeaders = customNetworkRequestHeaders

        copy.enableRemoteConfigAutomaticTriggers = enableRemoteConfigAutomaticTriggers
        copy.enableRemoteConfigValueCaching = enableRemoteConfigValueCaching
        copy.enrollABOnRCDownload = enrollABOnRCDownload
        copy.remoteConfigGlobalCallbacks = remoteConfigGlobalCallbacks

        copy.enableOrientationTracking = enableOrientationTracking

        copy.sdkBehaviorSettings = sdkBehaviorSettings
        copy.disableSDKBehaviorSettingsUpdates = disableSDKBehaviorSettingsUpdates
        copy.disableBackoffMechanism = disableBackoffMechanism
        copy.disableHealthCheck = disableHealthCheck
        copy.disableWebView = disableWebView

        copy.sdkInternalLimits.copyValues(from: sdkInternalLimits)
        copy.crashes.copyValues(from: crashes)
        copy.content.copyValues(from: content)
        copy.experimental.copyValues(from: experimental)

        return copy
    }
}
