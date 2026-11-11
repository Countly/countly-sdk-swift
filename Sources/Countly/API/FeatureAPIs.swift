//
//  FeatureAPIs.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

// MARK: - Crashes

/// Reports crashes, handled errors, and the breadcrumbs leading to them.
@objcMembers
public final class CrashesAPI: CountlyAPIBase {

    /// Records an exception.
    ///
    /// - Parameters:
    ///   - exception: The exception to report.
    ///   - isFatal: Whether the application cannot continue. A fatal report is
    ///     written to storage at once, because the process usually ends right
    ///     after, and is sent through the queue like any other.
    ///   - stackTrace: Frames to report instead of the exception's own. Without
    ///     either, the stack of this call is reported.
    ///   - segmentation: Extra context for this one report.
    public func recordException(_ exception: NSException,
                                isFatal: Bool = false,
                                stackTrace: [String]? = nil,
                                segmentation: [String: Any]? = nil) {
        guard let core = core() else { return }
        core.healthTracker.recordUsage(.crashes, "record")
        core.modules.crashes.recordException(exception, isFatal: isFatal, stackTrace: stackTrace, segmentation: segmentation)
    }

    /// Records a Swift error.
    @objc(recordNSError:isFatal:stackTrace:segmentation:)
    public func recordError(_ error: Error,
                            isFatal: Bool = false,
                            stackTrace: [String]? = nil,
                            segmentation: [String: Any]? = nil) {
        guard let core = core() else { return }
        core.healthTracker.recordUsage(.crashes, "record")
        core.modules.crashes.recordError(error, isFatal: isFatal, stackTrace: stackTrace, segmentation: segmentation)
    }

    /// Records an error described by a name.
    public func recordError(_ errorName: String,
                            isFatal: Bool = false,
                            stackTrace: [String]? = nil,
                            segmentation: [String: Any]? = nil) {
        guard let core = core() else { return }
        core.healthTracker.recordUsage(.crashes, "record")
        core.modules.crashes.recordError(errorName, isFatal: isFatal, stackTrace: stackTrace, segmentation: segmentation)
    }

    /// Records a breadcrumb, reported with the next crash.
    public func addCrashBreadcrumb(_ log: String) {
        guard let core = core() else { return }
        core.healthTracker.recordUsage(.crashes, "log")
        core.modules.crashes.log(log)
    }

    /// Drops every recorded breadcrumb.
    public func clearCrashBreadcrumbs() {
        guard let core = core() else { return }
        core.healthTracker.recordUsage(.crashes, "clear")
        core.modules.crashes.clearCrashLogs()
    }

    /// Replaces the segmentation merged into every crash report.
    public func setCrashSegmentation(_ segmentation: [String: Any]) {
        core()?.modules.crashes.setCrashSegmentation(segmentation)
    }
}

// MARK: - Remote config

/// Reads server-controlled values and drives A/B tests.
@objcMembers
public final class RemoteConfigAPI: CountlyAPIBase {

    /// The cached value for a key.
    ///
    /// Returns a wrapper rather than the bare value, because whether the value
    /// still belongs to the current user matters after a user change.
    public func getValue(_ key: String) -> CountlyRCData {
        core()?.modules.remoteConfig.getValue(key) ?? CountlyRCData(value: nil, isCurrentUsersData: true)
    }

    /// Every cached value.
    public func getAllValues() -> [String: CountlyRCData] {
        core()?.modules.remoteConfig.getAllValues() ?? [:]
    }

    /// Reads a value and enrolls the device in its A/B test.
    public func getValueAndEnroll(_ key: String) -> CountlyRCData {
        core()?.modules.remoteConfig.getValueAndEnroll(key) ?? CountlyRCData(value: nil, isCurrentUsersData: true)
    }

    /// Reads every value and enrolls the device in all of their A/B tests.
    public func getAllValuesAndEnroll() -> [String: CountlyRCData] {
        core()?.modules.remoteConfig.getAllValuesAndEnroll() ?? [:]
    }

    /// Downloads every key.
    ///
    /// The completion is called whatever happens, with an error when the SDK is
    /// not running, so a caller awaiting it is never left waiting.
    public func downloadKeys(completion: RCDownloadCallback? = nil) {
        guard let core = core() else {
            completion?(.error, CountlyError.remoteConfigGeneralAPIError.asNSError, false, [:])
            return
        }
        core.modules.remoteConfig.downloadKeys(completion: completion)
    }

    /// Downloads only the named keys, merging them into the cache. The completion
    /// is called whatever happens, as with `downloadKeys(completion:)`.
    public func downloadSpecificKeys(_ keys: [String], completion: RCDownloadCallback? = nil) {
        guard let core = core() else {
            completion?(.error, CountlyError.remoteConfigGeneralAPIError.asNSError, false, [:])
            return
        }
        core.modules.remoteConfig.downloadSpecificKeys(keys, completion: completion)
    }

    /// Downloads everything except the named keys, merging into the cache. The
    /// completion is called whatever happens, as with `downloadKeys(completion:)`.
    public func downloadOmittingKeys(_ omitKeys: [String], completion: RCDownloadCallback? = nil) {
        guard let core = core() else {
            completion?(.error, CountlyError.remoteConfigGeneralAPIError.asNSError, false, [:])
            return
        }
        core.modules.remoteConfig.downloadOmittingKeys(omitKeys, completion: completion)
    }

    /// Puts the device into the A/B tests of the given keys.
    public func enrollIntoABTests(forKeys keys: [String]) {
        core()?.modules.remoteConfig.enrollIntoABTests(forKeys: keys)
    }

    /// Takes the device out of the A/B tests of the given keys.
    public func exitABTests(forKeys keys: [String]) {
        core()?.modules.remoteConfig.exitABTests(forKeys: keys)
    }

    /// Registers a callback notified after each download.
    /// Registers a callback that hears about every remote config download.
    ///
    /// - Returns: a token for `removeDownloadCallback(_:)`, or `nil` when the SDK
    ///   has not been started. Discard it if the callback is meant to live for the
    ///   life of the process.
    @discardableResult
    public func registerDownloadCallback(_ callback: @escaping RCDownloadCallback) -> RCCallbackToken? {
        core()?.modules.remoteConfig.registerDownloadCallback(callback)
    }

    /// Removes one registered download callback.
    public func removeDownloadCallback(_ token: RCCallbackToken) {
        core()?.modules.remoteConfig.removeDownloadCallback(token)
    }

    /// Drops every registered download callback.
    public func removeAllDownloadCallbacks() {
        core()?.modules.remoteConfig.removeAllDownloadCallbacks()
    }

    /// Erases every cached value.
    public func clearAll() {
        core()?.modules.remoteConfig.clearAll()
    }

    // MARK: Testing helpers

    /// Every variant from the last testing download.
    public func testingGetAllVariants() -> [String: [String]] {
        core()?.modules.remoteConfig.testingGetAllVariants() ?? [:]
    }

    /// The variants of one key from the last testing download.
    public func testingGetVariants(forKey key: String) -> [String] {
        core()?.modules.remoteConfig.testingGetVariants(forKey: key) ?? []
    }

    /// Every experiment from the last testing download.
    public func testingGetAllExperimentInfo() -> [String: CountlyExperimentInformation] {
        core()?.modules.remoteConfig.testingGetAllExperimentInfo() ?? [:]
    }

    /// Downloads which variants exist, so a tester can pick one. The completion is
    /// called whatever happens, with an error when the SDK is not running.
    public func testingDownloadVariantInformation(completion: @escaping RCVariantCallback) {
        guard let core = core() else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }
        core.modules.remoteConfig.testingDownloadVariantInformation(completion: completion)
    }

    /// Downloads the experiments this device is part of. The completion is called
    /// whatever happens, with an error when the SDK is not running.
    public func testingDownloadExperimentInformation(completion: @escaping RCVariantCallback) {
        guard let core = core() else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }
        core.modules.remoteConfig.testingDownloadExperimentInformation(completion: completion)
    }

    /// Forces this device into a named variant. The completion is called whatever
    /// happens, with an error when the SDK is not running.
    public func testingEnrollIntoVariant(key: String, variantName: String, completion: @escaping RCVariantCallback) {
        guard let core = core() else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }
        core.modules.remoteConfig.testingEnrollIntoVariant(key: key, variantName: variantName, completion: completion)
    }
}

// MARK: - Attribution

/// Reports where an install or a session came from.
@objcMembers
public final class AttributionAPI: CountlyAPIBase {

    /// Reports a Countly campaign the user came from.
    ///
    /// - Parameters:
    ///   - campaignType: Only `countly` is supported.
    ///   - campaignData: JSON carrying at least `cid`, optionally `cuid`.
    public func recordDirectAttribution(campaignType: String, campaignData: String) {
        core()?.modules.attribution.recordDirectAttribution(campaignType: campaignType, campaignData: campaignData)
    }

    /// Reports advertising identifiers the host application obtained. See
    /// `AttributionKey` for the keys.
    public func recordIndirectAttribution(_ attribution: [String: String]) {
        core()?.modules.attribution.recordIndirectAttribution(attribution)
    }
}

// MARK: - Feedback

/// Presents surveys, NPS and rating widgets.
@objcMembers
public final class FeedbackAPI: CountlyAPIBase {

    /// Fetches the widgets the server offers for this application.
    public func getAvailableFeedbackWidgets(completion: @escaping ([CountlyFeedbackWidget]?, Error?) -> Void) {
        guard let core = core() else {
            completion(nil, nil)
            return
        }
        core.modules.feedback.getAvailableFeedbackWidgets(completion: completion)
    }

    /// Presents an NPS widget.
    ///
    /// - Parameter nameIDOrTag: Which widget to present. Without it, the first NPS
    ///   widget the server offers is used.
    public func presentNPS(_ nameIDOrTag: String? = nil, callback: WidgetCallback? = nil) {
        core()?.modules.feedback.present(type: .nps, nameIDOrTag: nameIDOrTag, callback: callback)
    }

    /// Presents a survey widget.
    public func presentSurvey(_ nameIDOrTag: String? = nil, callback: WidgetCallback? = nil) {
        core()?.modules.feedback.present(type: .survey, nameIDOrTag: nameIDOrTag, callback: callback)
    }

    /// Presents a rating widget.
    public func presentRating(_ nameIDOrTag: String? = nil, callback: WidgetCallback? = nil) {
        core()?.modules.feedback.present(type: .rating, nameIDOrTag: nameIDOrTag, callback: callback)
    }

    /// Builds a widget from a description the host application already holds, so it
    /// can be presented or reported without fetching the list again.
    ///
    /// Public because a bridge SDK keeps its widget list on the other side of the
    /// bridge: the widget comes back as the plain dictionary the JavaScript or Dart
    /// layer stored, not as an object this SDK handed out. Without this every bridge
    /// would have to refetch the list to turn an ID back into a widget, and a widget
    /// the user already saw would go unreported whenever that fetch failed.
    ///
    /// - Parameter dictionary: The widget as the server described it. `_id` and
    ///   `type` are required; `name`, `tg`, `wv` and `appearance` are read when present.
    /// - Returns: The widget, or `nil` when `_id` or `type` is missing, or the type is
    ///   one this SDK does not know.
    public func widget(from dictionary: [String: Any]) -> CountlyFeedbackWidget? {
        guard let core = core() else { return nil }
        return CountlyFeedbackWidget(dictionary: dictionary, module: core.modules.feedback)
    }

    /// Records the result of a rating widget the host application presented itself.
    public func recordRatingWidget(id widgetID: String,
                                   rating: Int,
                                   email: String? = nil,
                                   comment: String? = nil,
                                   userCanBeContacted: Bool = false) {
        core()?.modules.feedback.recordRatingWidget(id: widgetID,
                                                    rating: rating,
                                                    email: email,
                                                    comment: comment,
                                                    userCanBeContacted: userCanBeContacted)
    }
}

// MARK: - Content

/// Controls the in-app content zone.
@objcMembers
public final class ContentAPI: CountlyAPIBase {

    /// Starts polling the server for content to show.
    public func enterContentZone() {
        core()?.modules.content.enterContentZone()
    }

    /// Stops polling and takes any displayed content off screen.
    public func exitContentZone() {
        core()?.modules.content.exitContentZone()
    }

    /// Asks the server again as soon as everything queued has been accepted.
    public func refreshContentZone() {
        core()?.modules.content.refreshContentZone()
    }

    /// Fetches and shows one content by ID, without starting the polling loop.
    public func previewContent(_ contentID: String) {
        core()?.modules.content.previewContent(contentID)
    }

    /// Sets a segmentation recorded with every content and feedback widget event,
    /// on top of the keys those events report themselves.
    ///
    /// Keys those events reserve, such as `rating`, `closed`, `dismissed` or the
    /// `answ-` survey answers, are dropped. It lasts for the run, across sessions,
    /// and is not restored after a restart. `nil` clears it.
    public func setGlobalContentSegmentation(_ segmentation: [String: Any]?) {
        core()?.modules.content.setGlobalContentSegmentation(segmentation)
    }
}

// MARK: - Push

/// Registers for push notifications and records what the user did with them.
@objcMembers
public final class PushAPI: CountlyAPIBase {

    /// Asks the user for notification permission and reports the token afterwards.
    ///
    /// The completion is called whatever happens, with `false` when the SDK is
    /// not running, so a caller awaiting it is never left waiting.
    public func askForNotificationPermission(options: UInt = 0, completion: ((Bool, Error?) -> Void)? = nil) {
        guard let core = core() else {
            completion?(false, nil)
            return
        }
        core.modules.push.askForNotificationPermission(options: options, completion: completion)
    }

    /// Reports the current push token.
    public func recordPushNotificationToken() {
        core()?.modules.push.sendToken()
    }

    /// Tells the server this device has no usable token.
    public func clearPushNotificationToken() {
        core()?.modules.push.clearToken()
    }

    /// Records that the user acted on a notification.
    ///
    /// - Parameter buttonIndex: `0` for the notification body, `1` and up for its
    ///   action buttons.
    public func recordAction(for userInfo: [AnyHashable: Any], clickedButtonIndex buttonIndex: Int) {
        core()?.modules.push.recordAction(for: userInfo, clickedButtonIndex: buttonIndex)
    }
}
