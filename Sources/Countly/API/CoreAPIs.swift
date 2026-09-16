//
//  CoreAPIs.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation
import CoreLocation

/// Shared plumbing of the feature facades.
///
/// A facade holds its instance weakly and resolves the internal module on every
/// call, so a call made before `start(with:)` or after `halt()` is a logged no-op
/// rather than a crash. The SDK must never take the host application down over
/// call ordering.
public class CountlyAPIBase {

    unowned let instance: CountlyInstance

    init(instance: CountlyInstance) {
        self.instance = instance
    }

    func core(_ function: String = #function) -> SDKCore? {
        instance.requireCore(function)
    }
}

// MARK: - Events

/// Records custom events.
public final class EventsAPI: CountlyAPIBase {

    private static let module = "Events"

    /// Records an event.
    ///
    /// - Parameters:
    ///   - key: Name of the event.
    ///   - segmentation: Extra dimensions to break the event down by. Values may be
    ///     numbers, strings, booleans, or arrays of those.
    ///   - count: How many times it happened. Values below one are raised to one.
    ///   - sum: A value to total across occurrences, such as a price.
    ///   - duration: How long it took, in seconds.
    public func recordEvent(_ key: String,
                            segmentation: [String: Any]? = nil,
                            count: Int = 1,
                            sum: Double = 0,
                            duration: TimeInterval = 0) {
        core()?.modules.events.recordEvent(key, segmentation: segmentation, count: count, sum: sum, duration: duration)
    }

    /// Starts timing an event. End it with `endEvent` to record the elapsed time.
    /// The recorded events not yet moved into the request queue, oldest first, each
    /// serialized the way it will be sent.
    ///
    /// Diagnostic surface, for a test asserting on what the SDK buffered before a
    /// flush. Android exposes the same through `CountlyStore.getEvents`.
    public func recordedEvents() -> [String] {
        guard let core = core() else { return [] }
        let events = core.modules.events.recordedEventsJSON
        core.logger.d(Self.module, "recordedEvents", "the event queue contents were read through the public API, pendingEventCount: [\(events.count)]")
        return events
    }

    public func startEvent(_ key: String) {
        core()?.modules.events.startEvent(key)
    }

    /// Ends a timed event and records it.
    public func endEvent(_ key: String,
                         segmentation: [String: Any]? = nil,
                         count: Int = 1,
                         sum: Double = 0) {
        core()?.modules.events.endEvent(key, segmentation: segmentation, count: count, sum: sum)
    }

    /// Discards a timed event without recording it.
    public func cancelEvent(_ key: String) {
        core()?.modules.events.cancelEvent(key)
    }
}

// MARK: - Sessions

/// Drives session reporting when automatic sessions are switched off.
///
/// Every call here is ignored while automatic session tracking is on. Driving a
/// session by hand alongside the automatic one produces overlapping sessions and
/// double-counted durations, so the two are mutually exclusive rather than
/// additive.
public final class SessionsAPI: CountlyAPIBase {

    private static let module = "Sessions"

    /// Opens a session.
    public func beginSession() {
        guard let core = core(), allowed(core, "beginSession") else { return }
        core.logger.i(Self.module, "beginSession", "a session begin was requested through the manual sessions API")
        core.modules.sessions.beginSession()
    }

    /// Reports the time elapsed since the last update.
    public func updateSession() {
        guard let core = core(), allowed(core, "updateSession") else { return }
        guard !core.config.enableManualSessionControlHybridMode else {
            core.logger.w(Self.module, "updateSession", "the call will be ignored since manual session control hybrid mode is enabled, session updates are sent by the timer")
            return
        }
        core.logger.i(Self.module, "updateSession", "a session update was requested through the manual sessions API")
        core.modules.sessions.updateSession()
    }

    /// Closes the session, sending anything recorded first.
    public func endSession() {
        guard let core = core(), allowed(core, "endSession") else { return }
        core.logger.i(Self.module, "endSession", "a session end was requested through the manual sessions API, recorded events are sent first")
        core.modules.events.sendEventsWithSaveIfNeeded()
        core.modules.sessions.endSession()
    }

    private func allowed(_ core: SDKCore, _ function: String) -> Bool {
        guard core.serverConfig.automaticSessionTrackingEnabled else { return true }
        core.logger.w(Self.module, function, "the call will be ignored since automatic session tracking is active")
        return false
    }
}

// MARK: - Views

/// Reports which screens the user is on.
public final class ViewsAPI: CountlyAPIBase {

    /// Starts a view that stays open until stopped.
    ///
    /// - Returns: The view's ID, for stopping or annotating it later.
    @discardableResult
    public func startView(_ viewName: String, segmentation: [String: Any]? = nil) -> String? {
        core()?.modules.views.startView(viewName, segmentation: segmentation)
    }

    /// Starts a view that is stopped as soon as another view starts.
    @discardableResult
    public func startAutoStoppedView(_ viewName: String, segmentation: [String: Any]? = nil) -> String? {
        core()?.modules.views.startAutoStoppedView(viewName, segmentation: segmentation)
    }

    /// Stops the open view with this name.
    public func stopView(name viewName: String, segmentation: [String: Any]? = nil) {
        core()?.modules.views.stopView(name: viewName, segmentation: segmentation)
    }

    /// Stops the view with this ID.
    public func stopView(id viewID: String, segmentation: [String: Any]? = nil) {
        core()?.modules.views.stopView(id: viewID, segmentation: segmentation)
    }

    /// Stops the clock on a view without closing it.
    public func pauseView(id viewID: String) {
        core()?.modules.views.pauseView(id: viewID)
    }

    /// Restarts the clock on a paused view.
    public func resumeView(id viewID: String) {
        core()?.modules.views.resumeView(id: viewID)
    }

    /// Stops every open view.
    public func stopAllViews(segmentation: [String: Any]? = nil) {
        core()?.modules.views.stopAllViews(segmentation: segmentation)
    }

    /// Replaces the segmentation merged into every view event.
    public func setGlobalViewSegmentation(_ segmentation: [String: Any]) {
        core()?.modules.views.setGlobalViewSegmentation(segmentation)
    }

    /// Merges into the segmentation applied to every view event.
    public func updateGlobalViewSegmentation(_ segmentation: [String: Any]) {
        core()?.modules.views.updateGlobalViewSegmentation(segmentation)
    }

    /// Adds segmentation to an open view, reported when it stops.
    public func addSegmentation(toViewWithID viewID: String, segmentation: [String: Any]) {
        core()?.modules.views.addSegmentation(toViewWithID: viewID, segmentation: segmentation)
    }

    /// Adds segmentation to the open view with this name.
    public func addSegmentation(toViewWithName viewName: String, segmentation: [String: Any]) {
        core()?.modules.views.addSegmentation(toViewWithName: viewName, segmentation: segmentation)
    }

    /// Adds names that automatic view tracking should skip.
    public func addAutoViewTrackingExclusionList(_ names: [String]) {
        core()?.modules.views.addAutoViewTrackingExclusionList(names)
    }
}

// MARK: - User profile

/// Sets what is known about the current user.
public final class UserProfileAPI: CountlyAPIBase {

    /// Sets one property. Predefined keys such as `name` and `email` are stored as
    /// their own fields; anything else becomes a custom property.
    ///
    /// Pass `NSNull()` or an empty string to clear a field.
    public func setProperty(_ key: String, value: Any?) {
        core()?.modules.userProfile.setProperty(key, value: value)
    }

    /// Sets several properties at once.
    public func setProperties(_ data: [String: Any]) {
        core()?.modules.userProfile.setProperties(data)
    }

    /// Sets a custom property, never routing to a predefined field.
    public func setCustomProperty(_ key: String, value: Any?) {
        core()?.modules.userProfile.setCustomProperty(key, value: value)
    }

    /// Clears a custom property on the server.
    public func unsetCustomProperty(_ key: String) {
        core()?.modules.userProfile.unsetCustomProperty(key)
    }

    /// Sets a property only if it has no value yet.
    public func setOnce(_ key: String, value: Any) {
        core()?.modules.userProfile.setOnce(key, value: value)
    }

    /// Adds one to a numeric property.
    public func increment(_ key: String) {
        core()?.modules.userProfile.increment(key)
    }

    /// Adds an amount to a numeric property.
    public func incrementBy(_ key: String, value: Double) {
        core()?.modules.userProfile.incrementBy(key, value: value)
    }

    /// Multiplies a numeric property.
    public func multiply(_ key: String, value: Double) {
        core()?.modules.userProfile.multiply(key, value: value)
    }

    /// Keeps the larger of the stored and the given value.
    public func max(_ key: String, value: Double) {
        core()?.modules.userProfile.max(key, value: value)
    }

    /// Keeps the smaller of the stored and the given value.
    public func min(_ key: String, value: Double) {
        core()?.modules.userProfile.min(key, value: value)
    }

    /// Appends to a list property, duplicates allowed.
    public func push(_ key: String, value: Any) {
        core()?.modules.userProfile.push(key, value: value)
    }

    /// Appends to a list property only if it is not already there.
    public func pushUnique(_ key: String, value: Any) {
        core()?.modules.userProfile.pushUnique(key, value: value)
    }

    /// Removes from a list property.
    public func pull(_ key: String, value: Any) {
        core()?.modules.userProfile.pull(key, value: value)
    }

    /// Sends everything staged since the last save.
    public func save() {
        core()?.modules.userProfile.save()
    }

    /// Drops everything staged without sending it.
    public func clear() {
        core()?.modules.userProfile.clear()
    }
}

// MARK: - Consent

/// Grants and withdraws consent per feature.
public final class ConsentAPI: CountlyAPIBase {

    private static let module = "Consent"

    /// Grants consent for one feature.
    public func giveConsent(for feature: ConsentFeature) {
        core()?.modules.consent.giveConsent(for: [feature])
    }

    /// Grants consent for several features.
    public func giveConsent(for features: [ConsentFeature]) {
        core()?.modules.consent.giveConsent(for: features)
    }

    /// Grants consent for every feature.
    public func giveAllConsents() {
        guard let core = core() else { return }
        core.logger.i(Self.module, "giveAllConsents", "consent for every feature was requested in one call")
        core.modules.consent.giveAllConsents()
    }

    /// Withdraws consent for one feature.
    public func cancelConsent(for feature: ConsentFeature) {
        core()?.modules.consent.cancelConsent(for: [feature])
    }

    /// Withdraws consent for several features.
    public func cancelConsent(for features: [ConsentFeature]) {
        core()?.modules.consent.cancelConsent(for: features)
    }

    /// Withdraws consent for every feature.
    public func cancelAllConsents() {
        guard let core = core() else { return }
        core.logger.i(Self.module, "cancelAllConsents", "withdrawal of consent for every feature was requested in one call")
        core.modules.consent.cancelAllConsents()
    }

    /// Whether a feature may currently be used.
    ///
    /// Always `true` when the integration does not require consent.
    public func hasConsent(for feature: ConsentFeature) -> Bool {
        guard let core = core() else { return false }
        let granted = core.modules.consent.hasConsent(for: feature)
        core.logger.d(Self.module, "hasConsent", "a consent state was read through the public API, feature: [\(feature.wireName)], granted: [\(granted)]")
        return granted
    }
}

// MARK: - Device ID

/// Reads and changes the identity data is attributed to.
public final class DeviceIDAPI: CountlyAPIBase {

    private static let module = "DeviceID"

    /// The current device ID.
    public var current: String? {
        guard let core = core() else { return nil }
        let deviceID = core.modules.deviceID.deviceID
        // The value itself is verbose only: the logger delegate is live in release
        // builds and a device ID identifies a person.
        core.logger.d(Self.module, "current", "the device ID was read through the public API, valuePresent: [\(!deviceID.isEmpty)], typeWireValue: [\(core.modules.deviceID.deviceIDType.wireValue)]")
        core.logger.v(Self.module, "current", "device ID detail, deviceID: [\(deviceID)]")
        return deviceID
    }

    /// How the current device ID was obtained.
    public var type: DeviceIDType? {
        guard let core = core() else { return nil }
        let deviceIDType = core.modules.deviceID.deviceIDType
        core.logger.d(Self.module, "type", "the device ID type was read through the public API, typeWireValue: [\(deviceIDType.wireValue)]")
        return deviceIDType
    }

    /// Whether the SDK is holding data back until a real device ID is set.
    public var isTemporaryIDMode: Bool {
        guard let core = core() else { return false }
        let isTemporary = core.modules.deviceID.isTemporary
        core.logger.d(Self.module, "isTemporaryIDMode", "the temporary device ID mode flag was read through the public API, isTemporaryIDMode: [\(isTemporary)]")
        return isTemporary
    }

    /// Sets the device ID, merging or not depending on where the current ID came
    /// from.
    ///
    /// Replacing a developer supplied ID means a different user, so no merge.
    /// Replacing a generated ID means the same person identified themselves, so the
    /// histories are merged.
    public func setID(_ deviceID: String) {
        core()?.modules.deviceID.setID(deviceID)
    }

    /// Changes the device ID and asks the server to merge the previous identity
    /// into it.
    public func changeWithMerge(_ deviceID: String) {
        core()?.modules.deviceID.changeDeviceIDWithMerge(deviceID)
    }

    /// Changes the device ID and starts a fresh identity, discarding user-scoped
    /// state.
    public func changeWithoutMerge(_ deviceID: String) {
        core()?.modules.deviceID.changeDeviceIDWithoutMerge(deviceID)
    }

    /// Holds everything back until a real device ID is set.
    ///
    /// Data recorded meanwhile is rewritten to that ID once it arrives, so nothing
    /// is lost and nothing is attributed to a placeholder.
    public func enableTemporaryIDMode() {
        core()?.modules.deviceID.enableTemporaryDeviceIDMode()
    }
}

// MARK: - Location

/// Reports where the user is, when the host application knows.
public final class LocationAPI: CountlyAPIBase {

    /// Records a location and reports it.
    ///
    /// City and country code only resolve as a pair; one without the other is
    /// ignored by the server.
    public func recordLocation(_ coordinate: CLLocationCoordinate2D = kCLLocationCoordinate2DInvalid,
                               city: String? = nil,
                               isoCountryCode: String? = nil,
                               ipAddress: String? = nil) {
        core()?.modules.location.recordLocation(coordinate, city: city, isoCountryCode: isoCountryCode, ipAddress: ipAddress)
    }

    /// Clears the stored location and tells the server to stop inferring one from
    /// the request IP.
    public func disableLocationInfo() {
        core()?.modules.location.disableLocationInfo()
    }
}

// MARK: - Request queue

/// Operations on the queue of requests waiting to be sent.
public final class RequestQueueAPI: CountlyAPIBase {

    private static let module = "RequestQueue"

    /// How many requests are waiting.
    public var count: Int {
        guard let core = core() else { return 0 }
        let queued = core.requestQueueStore.count
        core.logger.d(Self.module, "count", "the request queue size was read through the public API, queuedRequestCount: [\(queued)]")
        return queued
    }

    /// Sends everything that is waiting, right now.
    /// Every queued request, oldest first, as the query strings they will be sent as.
    ///
    /// Diagnostic surface, for a test asserting on what the SDK actually queued.
    /// Android exposes the same through `CountlyStore.getRequests`. Reading it does
    /// not change the queue.
    public func queuedRequests() -> [String] {
        guard let core = core() else { return [] }
        let queued = core.requestQueueStore.all
        core.logger.d(Self.module, "queuedRequests", "the request queue contents were read through the public API, queuedRequestCount: [\(queued.count)]")
        return queued
    }

    /// Appends a request to the queue exactly as given.
    ///
    /// Diagnostic surface, the counterpart to ``queuedRequests()`` and the mirror
    /// of `CountlyStore.addRequest` on Android. Unlike a recorded event this skips
    /// the app version stamping and the tracking check, so the string reaches the
    /// wire as written, which is the point for a test. The queue's size and age
    /// limits still apply.
    public func store(_ queryString: String) {
        guard let core = core() else { return }
        core.logger.i(Self.module, "store", "a request is being stored verbatim through the public API, queryStringLength: [\(queryString.count)]")
        core.requestQueueStore.appendVerbatim(queryString)
        core.requestQueueStore.saveSync()
    }

    public func attemptToSendStoredRequests() {
        guard let core = core() else { return }
        core.logger.i(Self.module, "attemptToSendStoredRequests", "an immediate drain of the request queue was requested, queuedRequestCount: [\(core.requestQueueStore.count)]")
        core.modules.events.addEventsToRequestQueue()
        core.requestQueueStore.saveSync()
        core.network.proceedOnQueue()
    }

    /// Drops every queued request and every recorded event.
    ///
    /// Data is lost. Intended for a user asking to have their pending data
    /// discarded.
    public func flushQueues() {
        guard let core = core() else { return }
        core.logger.i(Self.module, "flushQueues", "the request queue and the event queue are being flushed, queuedRequestCount: [\(core.requestQueueStore.count)]")
        core.modules.events.flushEvents()
        core.requestQueueStore.flush()
        core.requestQueueStore.saveSync()
    }

    /// Rewrites queued requests recorded under a different app key so they report
    /// the current one.
    public func replaceAllAppKeysInQueueWithCurrentAppKey() {
        guard let core = core() else { return }
        core.logger.i(Self.module, "replaceAllAppKeysInQueueWithCurrentAppKey", "queued requests recorded under a different app key will be rewritten to the current one")
        core.requestQueueStore.replaceAllAppKeys(with: core.config.appKey)
        core.requestQueueStore.saveSync()
        core.network.proceedOnQueue()
    }

    /// Drops queued requests recorded under a different app key.
    public func removeDifferentAppKeysFromQueue() {
        guard let core = core() else { return }
        core.logger.i(Self.module, "removeDifferentAppKeysFromQueue", "queued requests recorded under a different app key will be dropped")
        core.requestQueueStore.removeDifferentAppKeys(than: core.config.appKey)
        core.requestQueueStore.saveSync()
        core.network.proceedOnQueue()
    }

    /// Registers a block to run the next time the queue drains with nothing having
    /// failed.
    public func addQueueFlushRunnable(_ runnable: @escaping () -> Void) {
        core()?.network.addQueueFlushRunnable(runnable)
    }

    /// Drops every registered flush block.
    public func clearQueueFlushRunnables() {
        core()?.network.clearQueueFlushRunnables()
    }
}
