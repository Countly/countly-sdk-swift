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
  * "start(with:)" refuses a server URL that is not an absolute "http" or "https" URL, and an "http" URL while certificates are pinned.
  * "suspend()" / "resume()"
  * "halt(clearStorage:)", which tears the instance down and, when asked, wipes every persisted key including those an earlier Objective-C SDK wrote, whether the instance is running or not. The instance stays registered and can be started again.
  * Integration-wide operations: "setNewHost", "setNewAppKey", "setNewURLSessionConfiguration", "addCustomNetworkRequestHeaders", "recordMetrics", "addDirectRequest"
  * "setNewHost" ignores, with an error, a URL that is not an absolute "http" or "https" URL, and an "http" URL while certificates are pinned. "setNewAppKey" ignores, with an error, an empty or placeholder key, and ignores the key in use.
  * "setNewAppKey" first closes what belongs to the old app under the old key: the running views stop, pending events and profile changes are queued and the running session ends. A session then begins for the new app if one was running.
  * After "setNewHost" or "setNewAppKey" the new server or app is caught up: the push token and, while consent is required, the consent state are sent again, and its behavior settings and remote config are fetched. "setNewAppKey" also clears the old app's remote config values.
  * "addDirectRequest" encodes every key and value itself, so they are passed as they are, and drops the keys the SDK sets itself, such as "device_id", "av", "rr" and "dr". A request left without parameters is ignored with a warning.

* Added the events API on "countly.events":
  * "recordEvent(key, segmentation, count, sum, duration)"
  * "startEvent(key)" / "endEvent(key, segmentation, count, sum)" / "cancelEvent(key)"
  * "recordedEvents()", the events buffered and not yet moved into the request queue
  * "recordReservedEvent(key, ...)", which records a reserved event the SDK normally produces itself. An overload takes a "CountlyReservedEvent" instead of a key.
  * Recorded events are kept in storage until they are moved into a request, so they survive the application being closed or killed. At most 1000 are kept.
  * Feedback widget answers and push actions are sent right away rather than with the next batch.
  * A count below one is recorded as 1, and a sum or duration that is not a finite number, or a negative duration, as 0, with a warning.

* Added the views API on "countly.views":
  * "startView(name, segmentation)" / "startAutoStoppedView(name, segmentation)"
  * "stopView(name:segmentation:)" / "stopView(id:segmentation:)" / "stopAllViews(segmentation:)". Of several open views with one name, the last one started is the one stopped or segmented by name.
  * "pauseView(id:)" reports the time so far and stops counting; "resumeView(id:)" counts again without a new start. Stopping a paused view reports no further time. A second pause, or a resume of a view that is not paused, is ignored with a warning.
  * "addSegmentation(toViewWithID:segmentation:)" / "addSegmentation(toViewWithName:segmentation:)"
  * "setGlobalViewSegmentation(segmentation)" / "updateGlobalViewSegmentation(segmentation)"
  * "addAutoViewTrackingExclusionList(names)"
  * Every running view stops when the application goes to the background and starts again as a new visit when it returns. A view ID stays valid across that. "disableViewRestartForManualRecording" keeps the manual views from starting again; they still stop.
  * After a device ID change without merge or an app key change, no manual view starts again, and the view IDs held for the stopped views no longer work. Automatic view tracking starts a view for the screen on display.

* Added the sessions API on "countly.sessions":
  * "beginSession()" / "updateSession()" / "endSession()"
  * Manual session control and manual hybrid mode via "CountlyConfig.manualSessionHandling" and "enableManualSessionControlHybridMode"
  * Session durations come from a monotonic clock, so changing the device's date and time cannot stretch or shrink a session.
  * A session that is running when the server turns session tracking off still ends normally.
  * On macOS the automatic session ends when the application hides or quits, and the next activation begins a new one.

* Added the user profile API on "countly.userProfile":
  * "setProperty(key, value)" / "setProperties(data)"
  * "setCustomProperty(key, value)" / "unsetCustomProperty(key)"
  * "setOnce(key, value)" / "increment(key)" / "incrementBy(key, value)" / "multiply(key, value)"
  * "max(key, value)" / "min(key, value)"
  * "push(key, value)" / "pushUnique(key, value)" / "pull(key, value)"
  * "save()" / "clear()"
  * Predefined properties: name, username, email, organization, phone, picture, picturePath, gender, byear. "byear" takes a whole number only.
  * An empty string clears a property on the server. A null value is ignored with a warning.
  * The same modifier called again on a key is combined before the save: increments add up, multiplications multiply, the highest or lowest value is kept, the first "setOnce" value is kept and list values are collected.
  * A different change for a key that has one pending, another modifier or a value, saves the pending changes first, so both reach the server in call order.
  * The calls need the "users" consent; without it they are ignored, and a save discards what is pending.
  * The server's user property cache limit ("upcl") saves the pending changes once it is reached. Nothing pending is dropped because of it.
  * "picturePath" uploads a local image on iOS and visionOS without sending the path itself. On the other platforms the path is dropped rather than sent as text.

* Added the consent API on "countly.consent":
  * "giveConsent(for:)" for one feature or an array / "giveAllConsents()"
  * "cancelConsent(for:)" for one feature or an array / "cancelAllConsents()"
  * "setConsent(for:given:)"
  * "createFeatureGroup(_:features:)" / "setConsentFeatureGroup(_:given:)" / "hasConsent(forGroup:)"
  * "hasConsent(for:)" / "checkAllConsent()", which logs the state of every feature
  * Init-time configuration via "CountlyConfig.requiresConsent", "consents" and "enableAllConsents"
  * The consent state is sent only when a call changed something. An empty feature list, or a value that names no feature, is ignored with a warning.
  * Withdrawing view consent closes every open view, manual ones included. Withdrawing push consent sends an empty push token. Withdrawing feedback consent closes a widget on screen without a "closed" event.
  * The "star-rating" consent covers "recordRatingWidget".

* Added the surface a bridge SDK needs to wrap this one:
  * "CountlyConfig.sdkName" and "CountlyConfig.sdkVersion", reported in place of this SDK's own, so a Flutter, React Native or Unity integration is attributed to itself
  * "ConsentFeature(wireName:)", which maps a consent name as written on the wire onto its feature

* Added the device ID API on "countly.deviceID":
  * "current" / "type" / "isTemporaryIDMode"
  * "setID(deviceID)", which picks the merge behavior from how the current ID was obtained
  * "changeWithMerge(deviceID)" / "changeWithoutMerge(deviceID)". An empty device ID is ignored with a warning.
  * "enableTemporaryIDMode()" / "disableTemporaryIDMode(deviceID)". Without a device ID, leaving the mode returns to the device ID and type in use before it, or generates one when the mode began at init.
  * A change without merge first stops the views, queues the pending events and profile changes and takes the push token back, all under the leaving user's device ID, then removes consent without a consent request and starts the new user clean.
  * A change with merge fetches the behavior settings and the remote config only once the server has accepted the merge request, so the new user is never created before the merge.
  * Every start replaces the temporary device ID in requests still queued under it, so such a request cannot hold the queue up.
  * Nothing is sent in temporary device ID mode, also requests queued before the mode began. They go out once it ends.
  * "CountlyConfig.resetStoredDeviceID", which drops the stored device ID at start, one the SDK generated included, so a new one is generated when no device ID is configured. The stored user's pending events and push token are handed back to that user first.

* Added the location API on "countly.location":
  * "recordLocation(coordinate, city, isoCountryCode, ipAddress)" / "disableLocationInfo()"
  * A location goes with the next "begin_session" when one is still to come, and on its own otherwise. A location request of its own leaves out the IP address, which the server uses only with "begin_session".
  * A country code that is not an uppercase ISO 3166-1 alpha-2 code, and an IP address that is not an IPv4 or IPv6 address, are not used.
  * "disableLocationInfo()" works with or without location consent, so a consent given later does not turn location back on.
  * The server's "lt" setting wins over the application's choice in both directions while the settings contain it. An off state that came from the server ends when the setting is removed.

* Added the crashes API on "countly.crashes":
  * "recordException(exception, isFatal, stackTrace, segmentation)"
  * "recordError(error, ...)" / "recordError(errorName, ...)". An error's type is reported as the crash type: the domain of an "NSError", otherwise the Swift type's name.
  * "addCrashBreadcrumb(log)" / "clearCrashBreadcrumbs()"
  * "setCrashSegmentation(segmentation)"
  * Automatic signal and uncaught exception handlers, chaining to any handler already installed, plus a crash filter callback via "CountlyConfig.crashes.crashFilterCallback".
  * A signal the application ignores, such as SIGPIPE, is left alone, and every other one is passed on after it is reported, so the process ends exactly as it would without the SDK.
  * A detected crash is stored for every instance while the process goes down and sent on the next launch. Nothing is sent from inside the crash handler.
  * A named instance installs the automatic handlers only when its own "CountlyConfig.features" includes crash reporting. SDK behavior settings can switch automatic crash reporting on for the default instance alone, so one crash is not stored once per instance.
  * Stopping the SDK gives a signal back only while the SDK's own handler is still the one installed, so a crash reporter installed after it keeps working.

* Added the remote config API on "countly.remoteConfig":
  * "getValue(key)" / "getAllValues()"
  * "getValueAndEnroll(key)" / "getAllValuesAndEnroll()"
  * "downloadKeys(completion:)" / "downloadSpecificKeys(keys, completion:)" / "downloadOmittingKeys(keys, completion:)"
  * "enrollIntoABTests(forKeys:)" / "exitABTests(forKeys:)". An enrollment without a usable key is ignored with a warning.
  * "registerDownloadCallback(callback)" / "removeAllDownloadCallbacks()" / "clearAll()"
  * A/B testing helpers: "testingGetAllVariants()", "testingGetVariants(forKey:)", "testingGetAllExperimentInfo()", "testingDownloadVariantInformation(completion:)", "testingDownloadExperimentInformation(completion:)", "testingEnrollIntoVariant(key:variantName:completion:)"
  * Automatic triggers, enroll-on-download and value caching via "CountlyConfig.enableRemoteConfigAutomaticTriggers", "enrollABOnRCDownload" and "enableRemoteConfigValueCaching"
  * A download that cannot reach the server reports "networkIssue". An answer that arrives after the device ID changed is discarded and reported as an error.
  * Nothing is downloaded while requests recorded in temporary device ID mode are still queued. "testingEnrollIntoVariant" succeeds only when the server answers "Success".

* Added the feedback API on "countly.feedback":
  * "getAvailableFeedbackWidgets(completion:)", which always calls back: with the widgets, or with an empty list and the reason
  * "presentNPS(nameIDOrTag, callback:)" / "presentSurvey(...)" / "presentRating(...)". The widget with that ID is chosen, else the one with that name, else the first one with that tag. A value that matches nothing shows nothing.
  * "recordRatingWidget(id:rating:email:comment:userCanBeContacted:)", the legacy call, which needs a rating from 1 to 5 and the "star-rating" consent
  * "widget(from:)", which rebuilds a widget from a description the caller already holds, so presenting or reporting it needs no second fetch
  * The widget callback reports "failed" when the widget could not be shown, for example when another content or widget is on screen or the page did not load. A "closed" event is recorded only for a widget that appeared.
  * A manual result needs a whole number "rating" from 0 to 10 for NPS and from 1 to 5 for a rating widget. Entries with an empty key or a null value are dropped.

* Added the content API on "countly.content":
  * "enterContentZone()" / "exitContentZone()" / "refreshContentZone()" / "previewContent(contentID)"
  * "setGlobalContentSegmentation(segmentation)", recorded with every content and feedback widget event and handed to a widget page that records its own answers. It never overrides a key the event reports itself, and the keys the server counts and attributes these events by cannot be set through it.
  * "CountlyConfig.content.allowedLinkSchemes", the schemes links from content and feedback widgets may open. The dangerous ones, such as "javascript" and "file", are never opened.
  * After a content closes, the next fetch waits two zone intervals. "zoneTimerInterval" takes 15 seconds or more.
  * "previewContent" needs the 24 character content ID. An answer is shown only with both the content address and its placement.
  * SDK behavior settings enter or leave the content zone only when they change the zone settings, so a zone the application entered stays open across every other settings refresh

* Added the attribution API on "countly.attribution":
  * "recordDirectAttribution(campaignType:campaignData:)" / "recordIndirectAttribution(attribution)"

* Added the request queue API on "countly.requestQueue":
  * "count" / "attemptToSendStoredRequests()" / "flushQueues()"
  * "replaceAllAppKeysInQueueWithCurrentAppKey()" / "removeDifferentAppKeysFromQueue()"
  * "addQueueFlushRunnable(runnable)" / "clearQueueFlushRunnables()"
  * "queuedRequests()" / "store(queryString)", which read the queue and append a request verbatim

* Added request queue persistence in an SQLite database, "CountlyRequests.sqlite", one per instance, that writes every change as a single transaction.
  * The queue "countly-sdk-ios" left in "Countly.dat" moves into it on the first launch. Cached remote config values are archived the way "countly-sdk-ios" does.

* Added "Migration/CountlySwiftSDKMigration.m", the one file an app going back to "countly-sdk-ios" adds to its target. It runs by itself on the first launch, before that SDK starts, and moves the queued requests into "Countly.dat". There is nothing to call.

* Added the push API on "countly.push":
  * "askForNotificationPermission(options:completion:)"
  * "recordPushNotificationToken()" / "clearPushNotificationToken()"
  * "recordAction(for:clickedButtonIndex:)"
  * Automatic handling, which takes the "UNUserNotificationCenter" delegate and the two registration callbacks and chains to the host's own, so the token is reported and a tapped notification is recorded without host code. Opt out with "CountlyConfig.disableAutomaticPushHandling".
  * "Countly.handleNotificationResponse(response)", for a host or bridge that owns the delegate itself. A tap handed over before the SDK started is kept and recorded at start with the time it happened.
  * "CountlyConfig.pushActionHandler", which gets the link of a tapped notification first and can take it over. The action is recorded either way.
  * "CountlyConfig.pushAllowedLinkSchemes", the schemes notification links may open. The dangerous ones, such as "javascript" and "file", are never opened.
  * "CountlyPushKey", public, so a host reading the payload itself uses the SDK's keys rather than a copy
  * The "CountlyNotificationService" product for notification service extensions, which adds a notification's action buttons and downloads its media attachment while preserving the host's own notification categories
  * Push is handled by the default instance only, since the token and the notification taps belong to the whole process. A named instance that enables push registers for nothing and reports nothing.
  * Before a device ID change without merge, the token is taken back from the leaving user with an empty token, and afterwards it is reported for the new user, so the previous user's notifications stop reaching the device.

* Added automatic view tracking on iOS, tvOS and visionOS:
  * "CountlyConfig.enableAutomaticViewTracking", with an exclusion list ("automaticViewTrackingExclusionList") matching the resolved view name, the class name or a superclass, and a "CountlyAutoViewTrackingName" protocol for naming a screen explicitly
  * The screen on display is reported again when the application returns from the background, which UIKit does not report as an appearance
  * A SwiftUI hosting controller is reported under the name of the view it hosts, so `UIHostingController<CheckoutView>` reports as "CheckoutView".
  * A hosted view that also reports itself with "countlyView" is reported twice unless its name is on the exclusion list.
  * A host of an erased "AnyView", which SwiftUI uses for its own sheets and navigation destinations, and any other screen known only by a compiler-generated Swift class name, is not reported; give it a title or adopt "CountlyAutoViewTrackingName"
  * "CountlyConfig.disableSwizzling", which stops the "viewDidAppear" and "viewDidDisappear" exchange. That exchange is the only thing automatic view tracking watches, so this leaves it off, even when SDK behavior settings would switch it on.
  * "disableSwizzling" applies to its own instance only and does not cover push handling, which "disableAutomaticPushHandling" turns off. Report screens yourself instead.
  * A SwiftUI "countlyView(_:segmentation:)" modifier, and "countlyView(_:segmentation:instance:)" for a named instance, because one hosting controller is a single appearance and a SwiftUI screen has to name itself.
  * "countlyView" works with automatic view tracking on or off. The instance is not optional, so a missing one is never replaced by the default instance.

* Added support for "Date" values in segmentation and user properties, sent as epoch milliseconds.

* Added automatic orientation tracking, on by default, toggleable via "CountlyConfig.enableOrientationTracking".

* Added SDK Behavior Settings (server-side configuration), fetched at init, every few hours, after a device ID change and after a server URL or app key change:
  * Tracking control, networking control, and the automatic session, view and crash tracking toggles
  * Event and request queue size limits, key and value length limits, and the segmentation value cap
  * Event, user property and view segmentation allow and block lists. An empty list is ignored, and a block list wins only when both lists have entries.
  * Developer-supplied settings via "CountlyConfig.sdkBehaviorSettings", and "disableSDKBehaviorSettingsUpdates" to pin them
  * Each valid answer replaces the stored one. A setting the answer does not carry, or carries with an invalid value, falls back to the developer's configuration, so a setting removed in the dashboard stops applying.
  * The server's "cr", "lt" and "bom" settings win over the developer's in both directions while the settings contain them.
  * Switching automatic sessions on in a running application begins a session at once. Switching them off ends the session the SDK began, while a session the application began itself is left to it.

* Added the two server requested diagnostics: log gathering, which uploads the SDK's own internal log lines even when logging is disabled, and the connection test, which checks every endpoint the SDK depends on and reports the results.
  * When consent is required, a gathered log line is uploaded only after the consent of the feature that wrote it is given, and a line that belongs to no single feature needs both the events and user details consents.
  * A value the behavior settings filter out, such as an event, a segmentation key or a user property on a block list, is never written to the log, so no gathered line carries it.
  * One gathered batch waits in the request queue at a time, and the rest wait in a bounded buffer, so a device that cannot reach the server never fills its queue with log batches. While the application is in the background, nothing is uploaded on the session timer.
  * When the server stops a gather, its last lines are still uploaded under it. A batch size outside 10 to 500 falls back to the default of 100.
  * The connection test report needs no consent. It carries the device ID the test was requested for and is dropped when the device ID changes with merge first, since the merge cancels the test on the server.
  * The connection test does not run while behavior settings switch networking or tracking off.
  * On iOS, tvOS, visionOS and watchOS it waits for the foreground, and runs again when the application returns from a background that interrupted it. On macOS it runs right away.

* Added networking configuration on "CountlyConfig":
  * Every request is a POST, with its data in the body.
  * "customNetworkRequestHeaders", and "addCustomNetworkRequestHeaders(headers)" on the instance to change them while it runs
  * "storedRequestsLimit" / "requestDropAgeHours" / "requestTimeoutDuration" / "disableGradualRequestCleaner"
  * "failedRequestCooldown", how long the queue waits after a failed request before trying it again, 60 seconds by default
  * "secretSalt" for parameter tampering protection, "pinnedCertificates" for certificate pinning, and "shouldIgnoreTrustCheck"
  * "disableBackoffMechanism" to opt out of the server backoff response, unless the server's "bom" setting turns it on
  * "disableWebView" to keep the SDK from showing content and feedback widgets
  * "urlSessionConfiguration" to supply a session of the host application's own

* Added a configurable logging system:
  * Log levels: none, error, warning, info, debug, verbose, via "CountlyConfig.internalLogLevel"
  * Console output via "CountlyConfig.enableDebug", honoured in release builds as well as debug ones unless "disableSDKLoggingInProduction" is set
  * A custom listener via "CountlyLoggerDelegate"

* Added a built-in device metric provider, with override support via "CountlyConfig.customMetrics" and "recordMetrics(metricsOverride)".
  * Metrics are sent only with the "metrics" consent, on "begin_session" too. A metric override with an empty key or value is skipped with a warning.

* Added the one-shot health check sent at init, carrying the error and warning counts, the last failed request's status code and message, the backoff counters, the method usage and the log codes, all kept across launches. "disableHealthCheck" turns it off.

* On watchOS the session follows the extension's active state on its own, so the host no longer calls "suspend()" and "resume()" from its extension delegate.

* Added support for iOS 15, tvOS 15, watchOS 9, macOS 12 and visionOS 1, the deployment floor of Xcode 27, from a single Swift package.

* Added Objective-C support: the public API is available to an Objective-C application under the same names, with "startWithConfig:" and "didReceiveNotificationRequest:withContentHandler:" as in "countly-sdk-ios".
  * Values Swift keeps as optional enums or arrays of enums, such as "pushTestMode" and "consents", are "NSNumber" there. The SwiftUI "countlyView" modifier stays Swift only.
