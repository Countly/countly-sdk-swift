# Countly SDK for Swift

Countly product analytics for iOS, iPadOS, tvOS, watchOS, macOS and visionOS,
written in Swift.

## What is different from countly-sdk-ios

Same wire protocol, same server, same features. Two things changed:

**Several SDKs can run side by side.** Every instance owns its storage, device
ID, request queue, timers, log level and lifecycle observation. Two instances
cannot see each other's data, so one application can report to two app keys, two
servers, or two tenants at once.

**The API is grouped by feature.** `Countly.shared.events.recordEvent(...)`
rather than a flat surface of sixty methods. Operations that do not belong to a
single feature stay on the instance.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/Countly/countly-sdk-swift.git", from: "26.8.0")
```

## Getting started

```swift
import Countly

let config = CountlyConfig(appKey: "YOUR_APP_KEY", host: "https://your.server")
config.enableDebug = true

Countly.shared.start(with: config)
```

That is the whole integration. Sessions, device metrics and the device ID are
handled from here.

### Recording

```swift
Countly.shared.events.recordEvent("purchase", segmentation: ["item": "hat"], count: 1, sum: 9.99)

let viewID = Countly.shared.views.startView("Checkout")
Countly.shared.views.stopView(id: viewID!)

Countly.shared.userProfile.setProperties(["name": "Ada", "email": "ada@example.com"])
Countly.shared.userProfile.save()
```

### Consent

With `config.requiresConsent = true` nothing is collected until you say so:

```swift
Countly.shared.consent.giveConsent(for: [.sessions, .events, .viewTracking])
```

Without it, every feature reports itself as consented and the calls above are
no-ops.

## Several instances

```swift
let analytics = Countly.instance(named: "analytics")
analytics.start(with: analyticsConfig)

let crashes = Countly.instance(named: "crashes")
crashes.start(with: crashConfig)
```

`Countly.instance(named:)` creates the handle but never starts it: initialization
is always an explicit `start(with:)`, so holding a reference cannot begin
collecting data by accident.

A natural choice of name is the app key, which gives one isolated instance per
dashboard application.

### Where the data goes

The default instance reads and writes the same paths and user defaults keys
earlier Countly SDKs used, so an application migrating from `countly-sdk-ios`
keeps its device ID and its queued requests. Named instances get their own
namespace derived from the name.

Some things stay process-wide, because the platform only offers one of each: the
crash handlers, the view controller swizzle, the APNs registration and the
notification centre delegate. All of them fan out to every instance that asked
for them.

## Push notifications

Nothing to wire up. Add `.pushNotifications` to `config.features` and the SDK
takes over the two application delegate registration callbacks and the
`UNUserNotificationCenter` delegate, always calling your own implementations
afterwards. The device token is reported, a tapped notification records its
action event, and any URL attached to the notification or to the tapped button is
opened.

Set `config.disableAutomaticPushHandling = true` to keep the SDK out of both
delegates, and then forward the callbacks yourself:

```swift
func application(_ app: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    Countly.didRegisterForRemoteNotifications(deviceToken: token)
}

func application(_ app: UIApplication,
                 didFailToRegisterForRemoteNotificationsWithError error: Error) {
    Countly.didFailToRegisterForRemoteNotifications(error: error)
}

// and, from your UNUserNotificationCenterDelegate:
Countly.shared.push.recordAction(for: response.notification.request.content.userInfo,
                                 clickedButtonIndex: 0)
```

### Rich notifications

Action buttons and media attachments need a notification service extension. Add
one to your project, link the `CountlyNotificationService` product, and forward
the one callback:

```swift
import UserNotifications
import CountlyNotificationService

class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        CountlyNotificationService.didReceive(request, withContentHandler: contentHandler)
    }
}
```

## Parity testing

`Tools/parity/` holds a local capture server and a comparison script, used to
prove this SDK sends the same traffic as `countly-sdk-ios` for the same flows.

```bash
python3 Tools/parity/capture_server.py --out captures/objc.jsonl --port 8080
# drive the sample app against http://localhost:8080, then repeat with this SDK
python3 Tools/parity/compare_captures.py captures/objc.jsonl captures/swift.jsonl
```

The comparison normalizes away what legitimately differs between two runs
(timestamps, device ID, checksums, SDK name and version) and reports everything
else.

## Requirements

iOS 12, tvOS 12, watchOS 4, macOS 10.14, visionOS 1. Swift 5.9.

## License

MIT. See `LICENSE`.
