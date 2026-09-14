## 26.8.0

* Initial release of the Countly Swift SDK.

* Added multi-instance entrypoints on "Countly":
  * "Countly.shared", the default instance, which reads and writes the storage an application's previous "countly-sdk-ios" integration left behind.
  * "Countly.instance(named:)", returns the instance for a name, creating it if needed. Getting a handle never starts it; the caller always calls "start(with:)".
  * "Countly.getInstance(named:)" / "Countly.listInstances()"
  * "Countly.haltAllInstances(clearStorage:)"
  * "Countly.removeInstance(named:)", stops a named instance and drops it from the registry, keeping its stored data.
  * Each instance owns its own app key, server, request queue, device ID, logger, monotonic clock and storage namespace. Named instances get their own files and user defaults keys; the default instance keeps the legacy ones.

* Added instance lifecycle on "CountlyInstance":
  * "start(with:)" / "isStarted"
  * "suspend()" / "resume()"
  * "halt(clearStorage:)", tears the instance down and, when asked, wipes every persisted key including those an earlier Objective-C SDK wrote.
  * Integration-wide operations: "setNewHost", "setNewAppKey", "setNewURLSessionConfiguration", "addCustomNetworkRequestHeaders", "recordMetrics", "addDirectRequest"

* Added the events API on "countly.events":
  * "recordEvent(key, segmentation, count, sum, duration)"
  * "startEvent(key)" / "endEvent(key, segmentation, count, sum)" / "cancelEvent(key)"

* Added the views API on "countly.views":
  * "startView(name, segmentation)" / "startAutoStoppedView(name, segmentation)"
  * "stopView(name:segmentation:)" / "stopView(id:segmentation:)" / "stopAllViews(segmentation:)"
  * "pauseView(id:)" / "resumeView(id:)"
  * "addSegmentation(toViewWithID:segmentation:)" / "addSegmentation(toViewWithName:segmentation:)"
  * "setGlobalViewSegmentation(segmentation)" / "updateGlobalViewSegmentation(segmentation)"
  * "addAutoViewTrackingExclusionList(names)"

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

* Added the consent API on "countly.consent":
  * "giveConsent(for:)" for one feature or an array / "giveAllConsents()"
  * "cancelConsent(for:)" for one feature or an array / "cancelAllConsents()"
  * "hasConsent(for:)"
  * Init-time configuration via "CountlyConfig.requiresConsent", "consents" and "enableAllConsents"

* Added the device ID API on "countly.deviceID":
  * "current" / "type" / "isTemporaryIDMode"
  * "setID(deviceID)", which picks the merge behavior from how the current ID was obtained
  * "changeWithMerge(deviceID)" / "changeWithoutMerge(deviceID)"
  * "enableTemporaryIDMode()"

* Added the location API on "countly.location":
  * "recordLocation(coordinate, city, isoCountryCode, ipAddress)" / "disableLocationInfo()"

* Added the crashes API on "countly.crashes":
  * "recordException(exception, isFatal, stackTrace, segmentation)"
  * "recordError(error, ...)" / "recordError(errorName, ...)"
  * "addCrashBreadcrumb(log)" / "clearCrashBreadcrumbs()"
  * "setCrashSegmentation(segmentation)"
  * Automatic signal and uncaught exception handlers, chaining to any handler already installed, plus a crash filter callback and a regular expression filter via "CountlyConfig.crashes" and "crashFilter"

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

* Added the content API on "countly.content":
  * "enterContentZone(tags:)" / "exitContentZone()" / "refreshContentZone()"
  * "changeContent(tags:)" / "previewContent(contentID)"

* Added the performance monitoring API on "countly.performance":
  * "recordNetworkTrace(name, requestPayloadSize, responsePayloadSize, responseStatusCode, startTime, endTime)"
  * "startCustomTrace(name)" / "endCustomTrace(name, metrics:)" / "cancelCustomTrace(name)" / "clearAllCustomTraces()"
  * "appLoadingFinished()"
  * App start, foreground and background traces via "CountlyConfig.apm". The app start trace is measured from when the process was launched, not from when the SDK was started, so it covers the whole launch even when the SDK is started late. Override it with "CountlyConfig.apm.appStartTimestampOverride".

* Added the attribution API on "countly.attribution":
  * "recordDirectAttribution(campaignType:campaignData:)" / "recordIndirectAttribution(attribution)"

* Added the request queue API on "countly.requestQueue":
  * "count" / "attemptToSendStoredRequests()" / "flushQueues()"
  * "replaceAllAppKeysInQueueWithCurrentAppKey()" / "removeDifferentAppKeysFromQueue()"
  * "addQueueFlushRunnable(runnable)" / "clearQueueFlushRunnables()"

* Added the push API on "countly.push":
  * "askForNotificationPermission(options:completion:)"
  * "recordPushNotificationToken()" / "clearPushNotificationToken()"
  * "recordAction(for:clickedButtonIndex:)"

* Added automatic push notification handling. The SDK installs itself on the "UNUserNotificationCenter" delegate and on the two remote notification registration callbacks, chaining to whatever the host application already has, so the device token is reported and a tapped notification records its action event and opens its URL without any host code. Opt out with "CountlyConfig.disableAutomaticPushHandling" and forward "Countly.didRegisterForRemoteNotifications(deviceToken:)" instead.

* Added the "CountlyNotificationService" product for notification service extensions. One call adds a notification's action buttons and downloads its media attachment, preserving any notification categories the host application registered.

* Added automatic view tracking via "CountlyConfig.enableAutomaticViewTracking", with a name exclusion list ("automaticViewTrackingExclusionList") that matches on the resolved view name, the class name, or a superclass, and a "CountlyAutoViewTrackingName" protocol for naming a screen explicitly.

* Added automatic orientation tracking, on by default, toggleable via "CountlyConfig.enableOrientationTracking".

* Added SDK Behavior Settings (server-side configuration), fetched at init and merged over the developer's configuration:
  * Tracking control, networking control, and the automatic session, view and crash tracking toggles
  * Event and request queue size limits, key and value length limits, and the segmentation value cap
  * Event, user property and view segmentation allow and block lists
  * Developer-supplied settings via "CountlyConfig.sdkBehaviorSettings", and "disableSDKBehaviorSettingsUpdates" to pin them

* Added support for server requested SDK log gathering. When the server asks for it, the SDK uploads its own internal log lines, even if logging is disabled.
* Added support for the SDK connection test. When the server asks for it, the SDK checks that it can reach every endpoint it depends on and reports the results.

* Added networking configuration on "CountlyConfig":
  * "addCustomNetworkRequestHeaders(headers)" and "customNetworkRequestHeaders"
  * "storedRequestsLimit" / "requestDropAgeHours" / "requestTimeoutDuration" / "alwaysUsePOST"
  * "secretSalt" for parameter tampering protection, "pinnedCertificates" for certificate pinning, and "shouldIgnoreTrustCheck"
  * "disableBackoffMechanism()" to opt out of the server backoff response
  * "urlSessionConfiguration" to supply a session of the host application's own

* Added a configurable logging system:
  * Log levels: none, error, warning, info, debug, verbose, via "CountlyConfig.internalLogLevel"
  * Console output via "CountlyConfig.enableDebug", honoured in release builds as well as debug ones
  * A custom listener via "CountlyLoggerDelegate"

* Added a built-in device metric provider, with override support via "CountlyConfig.customMetrics" and "recordMetrics(metricsOverride)".

* Added the one-shot health check report sent at init, carrying the error and warning counts, the last failed request's status code and message, and the backoff counters, all carried across launches.

* On watchOS the session follows the extension's active state on its own: resigning active ends it and becoming active begins the next, so the host no longer calls "suspend()" and "resume()" from its extension delegate.

* Added support for iOS 15, tvOS 15, watchOS 9, macOS 12 and visionOS 1, the deployment floor of Xcode 27, from a single Swift package, also distributed as a CocoaPod with a separate "NotificationService" subspec.
