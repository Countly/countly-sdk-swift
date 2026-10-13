## 26.8.0

* Initial release of the Countly Swift SDK.

* Added multi-instance entrypoints on "Countly":
  * "Countly.shared", the default instance, which reads and writes the storage a previous "countly-sdk-ios" integration left behind
  * "Countly.instance(named:)", which creates the instance if needed. Getting a handle never starts it; the caller always calls "start(with:)". An empty name is refused instead of falling back to the default instance.
  * "Countly.getInstance(named:)" / "Countly.listInstances()" / "Countly.haltAllInstances(clearStorage:)"
  * "Countly.removeInstance(named:)", which stops a named instance and drops it from the registry, keeping its stored data. A handle kept to the removed instance can no longer be started.
  * Each instance owns its app key, server, request queue, device ID, logger, clock and storage namespace. Named instances get their own files and user defaults keys; the default instance keeps the legacy ones.

* Added instance lifecycle on "CountlyInstance":
  * "start(with:)" / "isStarted". "start(with:)" takes a copy of the config, so one object can start several instances, or the same instance again after a halt.
  * "suspend()" / "resume()"
  * "halt(clearStorage:)", which tears the instance down and, when asked, wipes every persisted key including those an earlier Objective-C SDK wrote, whether the instance is running or not. The instance stays registered and can be started again.
  * Integration-wide operations: "setNewHost", "setNewAppKey", "setNewURLSessionConfiguration", "addCustomNetworkRequestHeaders", "recordMetrics", "addDirectRequest"
  * "addDirectRequest" encodes every key and value itself, so they are passed as they are, and drops the keys the SDK sets itself, such as "device_id"

* Added the events API on "countly.events":
  * "recordEvent(key, segmentation, count, sum, duration)"
  * "startEvent(key)" / "endEvent(key, segmentation, count, sum)" / "cancelEvent(key)"
  * "recordedEvents()", the events buffered and not yet moved into the request queue
  * "recordReservedEvent(key, ...)", which records a reserved event the SDK normally produces itself. An overload takes a "CountlyReservedEvent" instead of a key.

* Added the views API on "countly.views":
  * "startView(name, segmentation)" / "startAutoStoppedView(name, segmentation)"
  * "stopView(name:segmentation:)" / "stopView(id:segmentation:)" / "stopAllViews(segmentation:)"
  * "pauseView(id:)" / "resumeView(id:)"
  * "addSegmentation(toViewWithID:segmentation:)" / "addSegmentation(toViewWithName:segmentation:)"
  * "setGlobalViewSegmentation(segmentation)" / "updateGlobalViewSegmentation(segmentation)"
  * "addAutoViewTrackingExclusionList(names)"
  * A view ID stays valid after a background and foreground cycle reopens its view

* Added the sessions API on "countly.sessions":
  * "beginSession()" / "updateSession()" / "endSession()"
  * Manual session control and manual hybrid mode via "CountlyConfig.manualSessionHandling" and "enableManualSessionControlHybridMode"

* Added the user profile API on "countly.userProfile":
  * "setProperty(key, value)" / "setProperties(data)"
  * "setCustomProperty(key, value)" / "unsetCustomProperty(key)"
  * "setOnce(key, value)" / "increment(key)" / "incrementBy(key, value)" / "multiply(key, value)"
  * "max(key, value)" / "min(key, value)"
  * "push(key, value)" / "pushUnique(key, value)" / "pull(key, value)"
  * "save()" / "clear()"
  * Predefined properties: name, username, email, organization, phone, picture, picturePath, gender, byear
  * "picturePath" uploads a local image on iOS and visionOS. On the other platforms the path is dropped rather than sent as text.

* Added the consent API on "countly.consent":
  * "giveConsent(for:)" for one feature or an array / "giveAllConsents()"
  * "cancelConsent(for:)" for one feature or an array / "cancelAllConsents()"
  * "hasConsent(for:)"
  * Init-time configuration via "CountlyConfig.requiresConsent", "consents" and "enableAllConsents"
  * Withdrawing view consent closes every open view, manual ones included

* Added the surface a bridge SDK needs to wrap this one:
  * "CountlyConfig.sdkName" and "CountlyConfig.sdkVersion", reported in place of this SDK's own, so a Flutter, React Native or Unity integration is attributed to itself
  * "ConsentFeature(wireName:)", which maps a consent name as written on the wire onto its feature

* Added the device ID API on "countly.deviceID":
  * "current" / "type" / "isTemporaryIDMode"
  * "setID(deviceID)", which picks the merge behavior from how the current ID was obtained
  * "changeWithMerge(deviceID)" / "changeWithoutMerge(deviceID)"
  * "enableTemporaryIDMode()"
  * "CountlyConfig.resetStoredDeviceID", which drops the stored device ID at start, one the SDK generated included, so a new one is generated when no device ID is configured

* Added the location API on "countly.location":
  * "recordLocation(coordinate, city, isoCountryCode, ipAddress)" / "disableLocationInfo()"

* Added the crashes API on "countly.crashes":
  * "recordException(exception, isFatal, stackTrace, segmentation)"
  * "recordError(error, ...)" / "recordError(errorName, ...)"
  * "addCrashBreadcrumb(log)" / "clearCrashBreadcrumbs()"
  * "setCrashSegmentation(segmentation)"
  * Automatic signal and uncaught exception handlers, chaining to any handler already installed, plus a crash filter callback and a regular expression filter via "CountlyConfig.crashes" and "crashFilter". A signal the application ignores, such as SIGPIPE, is left alone, and every other one is passed on after it is reported, so the process ends exactly as it would without the SDK.
  * A detected crash is stored for every instance while the process goes down and sent on the next launch. Nothing is sent from inside the crash handler.
  * A named instance installs the automatic handlers only when its own "CountlyConfig.features" includes crash reporting. SDK behavior settings can switch automatic crash reporting on for the default instance alone, so one crash is not stored once per instance.
  * Stopping the SDK gives a signal back only while the SDK's own handler is still the one installed, so a crash reporter installed after it keeps working.

* Added the remote config API on "countly.remoteConfig":
  * "getValue(key)" / "getAllValues()"
  * "getValueAndEnroll(key)" / "getAllValuesAndEnroll()"
  * "downloadKeys(completion:)" / "downloadSpecificKeys(keys, completion:)" / "downloadOmittingKeys(keys, completion:)"
  * "enrollIntoABTests(forKeys:)" / "exitABTests(forKeys:)"
  * "registerDownloadCallback(callback)" / "removeAllDownloadCallbacks()" / "clearAll()"
  * A/B testing helpers: "testingGetAllVariants()", "testingGetVariants(forKey:)", "testingGetAllExperimentInfo()", "testingDownloadVariantInformation(completion:)", "testingDownloadExperimentInformation(completion:)", "testingEnrollIntoVariant(key:variantName:completion:)"
  * Automatic triggers, enroll-on-download and value caching via "CountlyConfig.enableRemoteConfigAutomaticTriggers", "enrollABOnRCDownload" and "enableRemoteConfigValueCaching"

* Added the feedback API on "countly.feedback":
  * "getAvailableFeedbackWidgets(completion:)"
  * "presentNPS(nameIDOrTag, callback:)" / "presentSurvey(...)" / "presentRating(...)"
  * "recordRatingWidget(id:rating:email:comment:userCanBeContacted:)"
  * "widget(from:)", which rebuilds a widget from a description the caller already holds, so presenting or reporting it needs no second fetch
  * A widget that is not shown because another content or widget is on screen calls back as closed and records nothing

* Added the content API on "countly.content":
  * "enterContentZone()" / "exitContentZone()" / "refreshContentZone()" / "previewContent(contentID)"
  * "setGlobalContentSegmentation(segmentation)", recorded with every content and feedback widget event and handed to a widget page that records its own answers. It never overrides a key the event reports itself, and the keys the server counts and attributes these events by cannot be set through it.
  * SDK behavior settings enter or leave the content zone only when they change the zone settings, so a zone the application entered stays open across every other settings refresh

* Added the performance monitoring API on "countly.performance":
  * "recordNetworkTrace(name, requestPayloadSize, responsePayloadSize, responseStatusCode, startTime, endTime)"
  * "startCustomTrace(name)" / "endCustomTrace(name, metrics:)" / "cancelCustomTrace(name)" / "clearAllCustomTraces()"
  * "appLoadingFinished()"
  * App start, foreground and background traces via "CountlyConfig.apm". The app start trace is measured from process launch rather than from SDK start, so it covers the whole launch; override it with "appStartTimestampOverride".

* Added the attribution API on "countly.attribution":
  * "recordDirectAttribution(campaignType:campaignData:)" / "recordIndirectAttribution(attribution)"

* Added the request queue API on "countly.requestQueue":
  * "count" / "attemptToSendStoredRequests()" / "flushQueues()"
  * "replaceAllAppKeysInQueueWithCurrentAppKey()" / "removeDifferentAppKeysFromQueue()"
  * "addQueueFlushRunnable(runnable)" / "clearQueueFlushRunnables()"
  * "queuedRequests()" / "store(queryString)", which read the queue and append a request verbatim

* Added request queue persistence in an SQLite database, "CountlyRequests.sqlite", one per instance, that writes every change as a single transaction. The queue "countly-sdk-ios" left in "Countly.dat" moves into it on the first launch. Cached remote config values are archived the way "countly-sdk-ios" does.

* Added "Migration/CountlySwiftSDKMigration.m", the one file an app going back to "countly-sdk-ios" adds to its target. It runs by itself on the first launch, before that SDK starts, and moves the queued requests into "Countly.dat". There is nothing to call.

* Added the push API on "countly.push":
  * "askForNotificationPermission(options:completion:)"
  * "recordPushNotificationToken()" / "clearPushNotificationToken()"
  * "recordAction(for:clickedButtonIndex:)"
  * Automatic handling, which takes the "UNUserNotificationCenter" delegate and the two registration callbacks and chains to the host's own, so the token is reported and a tapped notification is recorded without host code. Opt out with "CountlyConfig.disableAutomaticPushHandling".
  * "Countly.handleNotificationResponse(response)", for a host or bridge that owns the delegate itself, and for replaying a tap that arrived before the SDK was started
  * "CountlyPushKey", public, so a host reading the payload itself uses the SDK's keys rather than a copy
  * The "CountlyNotificationService" product for notification service extensions, which adds a notification's action buttons and downloads its media attachment while preserving the host's own notification categories
  * Push is handled by the default instance only, since the token and the notification taps belong to the whole process. A named instance that enables push registers for nothing and reports nothing.
  * After a device ID change without merge, the token is reported again for the new user, so the previous user's notifications stop reaching the device

* Added automatic view tracking on iOS, tvOS and visionOS:
  * "CountlyConfig.enableAutomaticViewTracking", with an exclusion list ("automaticViewTrackingExclusionList") matching the resolved view name, the class name or a superclass, and a "CountlyAutoViewTrackingName" protocol for naming a screen explicitly
  * The screen on display is reported again when the application returns from the background, which UIKit does not report as an appearance
  * A SwiftUI hosting controller is reported under the name of the view it hosts, so `UIHostingController<CheckoutView>` reports as "CheckoutView". A hosted view that also reports itself with "countlyView" is reported twice unless its name is on the exclusion list.
  * A host of an erased "AnyView", which SwiftUI uses for its own sheets and navigation destinations, and any other screen known only by a compiler-generated Swift class name, is not reported; give it a title or adopt "CountlyAutoViewTrackingName"
  * "CountlyConfig.disableSwizzling", which stops the "viewDidAppear" and "viewDidDisappear" exchange. That exchange is the only thing automatic view tracking watches, so this leaves it off, even when SDK behavior settings would switch it on; report screens yourself instead. It applies to its own instance only and does not cover push handling, which "disableAutomaticPushHandling" turns off.
  * A SwiftUI "countlyView(_:segmentation:)" modifier, and "countlyView(_:segmentation:instance:)" for a named instance, because one hosting controller is a single appearance and a SwiftUI screen has to name itself. Works with automatic view tracking on or off. The instance is not optional, so a missing one is never replaced by the default instance.

* Added support for "Date" values in segmentation and user properties, sent as epoch milliseconds.

* Added automatic orientation tracking, on by default, toggleable via "CountlyConfig.enableOrientationTracking".

* Added SDK Behavior Settings (server-side configuration), fetched at init and merged over the developer's configuration:
  * Tracking control, networking control, and the automatic session, view and crash tracking toggles
  * Event and request queue size limits, key and value length limits, and the segmentation value cap
  * Event, user property and view segmentation allow and block lists
  * Developer-supplied settings via "CountlyConfig.sdkBehaviorSettings", and "disableSDKBehaviorSettingsUpdates" to pin them
  * Switching automatic sessions on in a running application begins a session at once. Switching them off ends the session the SDK began, while a session the application began itself is left to it.

* Added the two server requested diagnostics: log gathering, which uploads the SDK's own internal log lines even when logging is disabled, and the connection test, which checks every endpoint the SDK depends on and reports the results.
  * When consent is required, a gathered log line is uploaded only after the consent of the feature that wrote it is given, and a line that belongs to no single feature needs both the events and user details consents.
  * A value the behavior settings filter out, such as an event, a segmentation key or a user property on a block list, is never written to the log, so no gathered line carries it.
  * One gathered batch waits in the request queue at a time, and the rest wait in a bounded buffer, so a device that cannot reach the server never fills its queue with log batches. While the application is in the background, nothing is uploaded on the session timer.
  * When the server stops a gather, its last lines are still uploaded under it.
  * The connection test report needs no consent. It carries the device ID the test was requested for and is dropped when the device ID changes with merge first, since the merge cancels the test on the server. The test does not run while behavior settings switch networking or tracking off.

* Added networking configuration on "CountlyConfig":
  * "customNetworkRequestHeaders", and "addCustomNetworkRequestHeaders(headers)" on the instance to change them while it runs
  * "storedRequestsLimit" / "requestDropAgeHours" / "requestTimeoutDuration" / "alwaysUsePOST"
  * "secretSalt" for parameter tampering protection, "pinnedCertificates" for certificate pinning, and "shouldIgnoreTrustCheck"
  * "disableBackoffMechanism" to opt out of the server backoff response
  * "urlSessionConfiguration" to supply a session of the host application's own

* Added a configurable logging system:
  * Log levels: none, error, warning, info, debug, verbose, via "CountlyConfig.internalLogLevel"
  * Console output via "CountlyConfig.enableDebug", honoured in release builds as well as debug ones
  * A custom listener via "CountlyLoggerDelegate"

* Added a built-in device metric provider, with override support via "CountlyConfig.customMetrics" and "recordMetrics(metricsOverride)".

* Added the one-shot health check sent at init, carrying the error and warning counts, the last failed request's status code and message, and the backoff counters, all kept across launches.

* On watchOS the session follows the extension's active state on its own, so the host no longer calls "suspend()" and "resume()" from its extension delegate.

* Added support for iOS 15, tvOS 15, watchOS 9, macOS 12 and visionOS 1, the deployment floor of Xcode 27, from a single Swift package.

* Added Objective-C support: the public API is available to an Objective-C application under the same names, with "startWithConfig:" and "didReceiveNotificationRequest:withContentHandler:" as in "countly-sdk-ios". Values Swift keeps as optional enums or arrays of enums, such as "pushTestMode" and "consents", are "NSNumber" there. The SwiftUI "countlyView" modifier stays Swift only.
