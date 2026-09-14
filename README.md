[![Build](https://github.com/Countly/countly-sdk-swift/actions/workflows/build.yml/badge.svg)](https://github.com/Countly/countly-sdk-swift/actions/workflows/build.yml)
[![Tests](https://github.com/Countly/countly-sdk-swift/actions/workflows/test.yml/badge.svg)](https://github.com/Countly/countly-sdk-swift/actions/workflows/test.yml)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg?style=flat)
![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20macOS%20%7C%20visionOS-brightgreen.svg?style=flat)

# Countly Swift SDK

This repository contains the Countly Swift SDK, which can be integrated into iOS, iPadOS, tvOS, watchOS, macOS and visionOS applications written in Swift. The Countly Swift SDK is intended to be used with [Countly Lite](https://countly.com/lite), [Countly Flex](https://countly.com/flex), [Countly Enterprise](https://countly.com/enterprise).

Its interface is Swift only. For an application written in Objective-C, use the [Countly iOS SDK](https://github.com/Countly/countly-sdk-ios).

## What is Countly?

[Countly](https://countly.com) is a product analytics solution and innovation enabler that helps teams track product performance and customer journey and behavior across [mobile](https://countly.com/mobile-analytics), [web](https://countly.com/web-analytics), and [desktop](https://countly.com/desktop-analytics) applications. [Ensuring privacy by design](https://countly.com/privacy-by-design), Countly allows you to innovate and enhance your products to provide personalized and customized customer experiences, and meet key business and revenue goals.

Track, measure, and take action - all without leaving Countly.

* **Questions or feature requests?** [Join the Countly Community on Discord](https://discord.gg/countly)
* **Looking for the Countly Server?** [Countly Server repository](https://github.com/Countly/countly-server)
* **Looking for other Countly SDKs?** [An overview of all Countly SDKs for mobile, web and desktop](https://support.count.ly/hc/en-us/articles/360037236571-Downloading-and-Installing-SDKs#h_01H9QCP8G5Y9PZJGERZ4XWYDY9)

## Integrating Countly SDK in your projects

This SDK supports the following features:
* [Analytics](https://support.count.ly/hc/en-us/articles/4431589003545-Analytics)
* [Push Notifications](https://support.count.ly/hc/en-us/articles/4405405459225-Push-Notifications)
* [User Profiles](https://support.count.ly/hc/en-us/articles/4403281285913-User-Profiles)
* [Crash Reports](https://support.count.ly/hc/en-us/articles/4404213566105-Crashes-Errors)
* [A/B Testing](https://support.count.ly/hc/en-us/articles/4416496362393-A-B-Testing-)
* [Performance Monitoring](https://support.count.ly/hc/en-us/articles/4734457847705-Performance)
* [Feedback Widgets](https://support.count.ly/hc/en-us/articles/4652903481753-Feedback-Surveys-NPS-and-Ratings-)

## Installation

### Swift Package Manager

```swift
.package(url: "https://github.com/Countly/countly-sdk-swift.git", from: "26.8.0")
```

### CocoaPods

```ruby
pod 'CountlySwift', '~> 26.8'
```

Rich push notifications need the notification service extension subspec in your extension target:

```ruby
target 'YourNotificationServiceExtension' do
  pod 'CountlySwift/NotificationService', '~> 26.8'
end
```

## Minimal integration

```swift
import Countly

let config = CountlyConfig()
config.appKey = "YOUR_APP_KEY"
config.host = "https://your.server.ly"

Countly.shared.start(with: config)
```

That is the whole integration. Sessions, device metrics and the device ID are handled from there.

Recording is grouped by feature rather than spread across one flat surface:

```swift
Countly.shared.events.recordEvent("purchase", segmentation: ["item": "hat"], count: 1, sum: 9.99)

let viewID = Countly.shared.views.startView("Checkout")
Countly.shared.views.stopView(id: viewID!)

Countly.shared.userProfile.setProperties(["name": "Ada", "email": "ada@example.com"])
Countly.shared.userProfile.save()
```

With `config.requiresConsent = true` nothing is collected until consent is given:

```swift
Countly.shared.consent.giveConsent(for: [.sessions, .events, .viewTracking])
```

## Multiple instances

Several instances can run side by side. Each one owns its storage, device ID, request queue, timers, log level and lifecycle observation, so one application can report to two app keys, two servers, or two tenants at once without them seeing each other's data.

```swift
let analytics = Countly.instance(named: "analytics")
analytics.start(with: analyticsConfig)
```

`Countly.instance(named:)` creates the handle but never starts it, so holding a reference cannot begin collecting data by accident. `Countly.shared` is the default instance, and it reads and writes the same storage a previous `countly-sdk-ios` integration used, so an application moving to this SDK keeps its device ID and its queued requests.

## Push notifications

Add `.pushNotifications` to `config.features` and the SDK takes over the two application delegate registration callbacks and the `UNUserNotificationCenter` delegate, always calling your own implementations afterwards. The device token is reported, a tapped notification records its action event, and any attached URL is opened.

Set `config.disableAutomaticPushHandling = true` to keep the SDK out of both delegates and forward the callbacks yourself.

Action buttons and media attachments need a notification service extension:

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

## Requirements

iOS 15, tvOS 15, watchOS 9, macOS 12, visionOS 1. Swift 5.9. These are the oldest deployment targets Xcode 27 builds for.

## Security

Security is very important to us. If you discover any issue regarding security, please disclose the information responsibly by sending an email to security@count.ly and **not by creating a GitHub issue**.

## Badges

If you like Countly, [why not use one of our badges](https://countly.com/brand-assets) and give a link back to us so others know about this wonderful platform?

<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://countly.com/badges/dark.svg?v2" alt="Countly - Product Analytics" /></a>

```JS
<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://countly.com/badges/dark.svg" alt="Countly - Product Analytics" /></a>
```

<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://countly.com/badges/light.svg?v2" alt="Countly - Product Analytics" /></a>

```JS
<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://countly.com/badges/light.svg" alt="Countly - Product Analytics" /></a>
```

## How can I help you with your efforts?

Glad you asked! For community support, feature requests, and engaging with the Countly Community, please join us at [our Discord Server](https://discord.gg/countly). We're excited to have you there!

Also, we are on [Twitter](https://twitter.com/gocountly) and [LinkedIn](https://www.linkedin.com/company/countly) if you would like to keep up with Countly related updates.
