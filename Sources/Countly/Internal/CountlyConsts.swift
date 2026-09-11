//
//  CountlyConsts.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// SDK identity reported to the server on every request.
enum SDKIdentity {
    static let version = "26.8.0"
    static let name = "swift-native-ios"
}

/// Query string keys of the Countly wire protocol.
///
/// These names are the contract with the server. Changing one changes what the
/// server records, so they are kept verbatim from the protocol reference.
enum QS {
    static let appKey = "app_key"

    static let deviceID = "device_id"
    static let deviceIDOld = "old_device_id"
    static let deviceIDType = "t"

    static let timestamp = "timestamp"
    static let timeZone = "tz"
    static let hourOfDay = "hour"
    static let dayOfWeek = "dow"

    static let sdkVersion = "sdk_version"
    static let sdkName = "sdk_name"

    static let sessionBegin = "begin_session"
    static let sessionDuration = "session_duration"
    static let sessionEnd = "end_session"

    static let pushTokenSession = "token_session"
    static let pushTokeniOS = "ios_token"
    static let pushTestMode = "test_mode"

    static let location = "location"
    static let locationCity = "city"
    static let locationCountry = "country_code"
    static let locationIP = "ip"

    static let attributionID = "aid"
    static let idfa = "idfa"
    static let adid = "adid"
    static let campaignID = "campaign_id"
    static let campaignUser = "campaign_user"
    static let attributionData = "attribution_data"

    static let metrics = "metrics"
    static let events = "events"
    static let userDetails = "user_details"
    static let crash = "crash"
    static let checksum256 = "checksum256"
    static let consent = "consent"
    static let apm = "apm"
    static let remainingRequest = "rr"

    static let method = "method"
    static let theme = "th"

    static let appVersion = "av"

    static let rcKeys = "keys"
    static let rcOmitKeys = "omit_keys"
    static let abOptIn = "ab"
    static let abOptOut = "ab_opt_out"

    /// One batch of the SDK's own gathered log lines, see `LogGatherer`.
    static let sdkLogs = "sdk_logs"
    /// The connection test report, see `ConnectionTestModule`.
    static let connectionTestResults = "ct_results"

    static let newEndPoint = "new_end_point"
    static let endPointOverrideTag = "&new_end_point="
    static let callbackID = "callback_id"
}

/// Server endpoints the SDK talks to.
enum Endpoint {
    /// Input endpoint: everything the SDK reports.
    static let input = "/i"
    /// Output endpoint: everything the SDK reads back.
    static let output = "/o"
    static let sdk = "/sdk"
    static let feedback = "/feedback"
    static let widget = "/widget"
    static let surveys = "/surveys"
}

/// Reserved event keys the SDK emits on the host application's behalf.
///
/// Each one is gated on the consent of the feature that owns it rather than on
/// event consent, which is why they are listed together.
enum ReservedEventKey {
    static let orientation = "[CLY]_orientation"
    static let view = "[CLY]_view"
    /// Result of a rating type feedback widget. The wire key is historical.
    static let ratingWidget = "[CLY]_star_rating"
    static let nps = "[CLY]_nps"
    static let survey = "[CLY]_survey"
    static let pushAction = "[CLY]_push_action"

    static let all: Set<String> = [orientation, view, ratingWidget, nps, survey, pushAction]
}

/// Keys of the Countly payload carried inside a push notification.
///
/// The notification service extension target has its own copy of these, because
/// it is a separate process that does not link the main SDK. Both are the wire
/// contract with the server, so neither side gets to change one alone.
enum CountlyPushKey {
    /// The Countly payload, nested under this key in `userInfo`.
    static let countlyPayload = "c"
    /// Server side ID of the notification.
    static let notificationID = "i"
    /// Array of action button descriptors.
    static let buttons = "b"
    /// URL opened when the notification body itself is tapped.
    static let defaultURL = "l"
    /// URL of a media attachment to download and attach.
    static let attachment = "a"
    /// Index of the tapped action button, as reported in the action event.
    static let actionButtonIndex = "b"
    /// Title of an action button.
    static let actionButtonTitle = "t"
    /// URL opened when an action button is tapped.
    static let actionButtonURL = "l"
    /// Platform the action was taken on, as reported in the action event.
    static let platform = "p"

    /// Prefix of the action identifiers the notification service extension
    /// registers, followed by the one based index of the button.
    static let actionIdentifierPrefix = "CountlyActionIdentifier"

    /// Prefix of the notification category the extension registers, followed by
    /// the notification ID, so two notifications never share a button set.
    static let categoryIdentifierPrefix = "CountlyCategoryIdentifier"
}

/// Segmentation keys the SDK owns. A host application setting one of these has
/// it overwritten.
enum SegKey {
    static let visibility = "cly_v"
    static let currentViewName = "cly_cvn"
    static let previousViewName = "cly_pvn"
    static let previousEventName = "cly_pen"

    // View event payload
    static let name = "name"
    static let segment = "segment"
    static let visit = "visit"
    static let start = "start"
    static let bounce = "bounce"
    static let exit = "exit"
    static let view = "view"
    static let domain = "domain"
    static let duration = "dur"
}

/// Requests larger than this are sent as POST even when `alwaysUsePOST` is off.
let kGETRequestMaxLength = 2048

/// Boundary used when the SDK uploads a user profile picture.
let kUploadBoundary = "0cae04a8b698d63ff6ea55d168993f21"

/// Default SDK internal limits. Overridable through `CountlyConfig.sdkInternalLimits`.
enum DefaultLimits {
    static let maxKeyLength = 128
    static let maxValueSize = 256
    static let maxValueSizePicture = 4096
    static let maxSegmentationValues = 100
    static let maxBreadcrumbCount = 100
    static let maxStackTraceLinesPerThread = 30
    static let maxStackTraceLineLength = 200
}

/// Keys under which the SDK persists state.
///
/// The default instance uses these verbatim so that data written by an earlier
/// Countly SDK on the same device is picked up unchanged. Named instances get the
/// same keys with a namespace suffix appended, see `StorageNamespace`.
enum PersistencyKey {
    static let queuedRequests = "kCountlyQueuedRequestsPersistencyKey"
    static let healthCheckState = "kCountlyHealthCheckStatePersistencyKey"
    static let storedDeviceID = "kCountlyStoredDeviceIDKey"
    static let storedNSUUID = "kCountlyStoredNSUUIDKey"
    static let notificationPermission = "kCountlyNotificationPermissionKey"
    static let isCustomDeviceID = "kCountlyIsCustomDeviceIDKey"
    static let remoteConfig = "kCountlyRemoteConfigKey"
    static let serverConfig = "kCountlyServerConfigPersistencyKey"
}

/// The sentinel device ID that means "hold everything until a real ID arrives".
///
/// Kept as the literal the Objective-C SDK used, because a queue written by an
/// earlier SDK on the same device may still contain it and has to be recognized.
enum TemporaryDeviceID {
    static let value = "CLYTemporaryDeviceID"
}

/// Placeholder values the SDK refuses to initialize with.
enum Placeholder {
    static let appKey = "YOUR_APP_KEY"
    static let host = "https://YOUR_COUNTLY_SERVER"
}
