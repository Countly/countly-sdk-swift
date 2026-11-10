//
//  ViewsModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

/// Tracks which screens the user is on and for how long.
///
/// A view is a reserved event with a start marker, a duration and a name. Several
/// views can be open at once, which is what makes tabbed and split layouts
/// reportable, so the module keeps a set rather than a single current view.
final class ViewsModule: ModuleBase {

    override class var moduleName: String { "Views" }

    /// Open views, keyed by view ID.
    private var viewDataDictionary: [String: CountlyViewData] = [:]

    /// The start order the next view gets, see `CountlyViewData.startOrder`.
    private var nextStartOrder = 0

    /// IDs handed out for views that a background and foreground cycle has since
    /// reopened, mapped to the ID the view is open under now.
    ///
    /// A restart opens the view again under a fresh ID, which is what the wire
    /// reports. The host still holds the ID it was given, so every call taking a
    /// view ID resolves it through here first.
    private var restartedViewIDs: [String: String] = [:]

    /// Segmentation merged into every view event.
    private var globalViewSegmentation: [String: Any] = [:]

    /// Whether the next started view is the first of the session, which the server
    /// uses to mark the session's landing screen.
    private var isFirstView = true

    private(set) var currentViewID: String?
    private(set) var previousViewID: String?
    private(set) var currentViewName: String?
    private(set) var previousViewName: String?

    /// Whether views stopped by backgrounding are started again on foreground.
    var isManualViewRestartActive = true

    /// Whether the SDK is starting views from view controller appearances.
    private(set) var isAutoViewTrackingActive = false

    #if os(iOS) || os(tvOS) || os(visionOS)
    /// Whether going to the background stopped the automatically tracked screen's
    /// view, which coming back then reopens. A foreground without a background
    /// before it, such as the one at launch or after Control Center, reopens nothing.
    private var reopensScreenOnForeground = false
    #endif

    /// Last reported interface orientation, so an unchanged rotation is not
    /// reported twice.
    private var lastInterfaceOrientation: String?

    /// Names and class names that automatic view tracking never reports.
    #if os(iOS) || os(tvOS) || os(visionOS)
    private var automaticViewTrackingExclusionList: [String] = AutoViewTracker.defaultExclusionList
    #else
    private var automaticViewTrackingExclusionList: [String] = []
    #endif

    /// Exclusion entries matched by name, and the subset that resolves to a real
    /// class. Rebuilt only when the list changes.
    private lazy var excludedNames: Set<String> = Set(automaticViewTrackingExclusionList)
    #if os(iOS) || os(tvOS) || os(visionOS)
    private lazy var excludedClasses: [AnyClass] = automaticViewTrackingExclusionList.compactMap { NSClassFromString($0) }
    #endif

    /// Keys the SDK owns inside a view event's segmentation. A host application
    /// setting one of these has it dropped rather than overwriting the SDK's.
    private static let reservedSegmentationKeys: Set<String> = [
        SegKey.name, SegKey.segment, SegKey.visit, SegKey.start, SegKey.bounce,
        SegKey.exit, SegKey.view, SegKey.domain, SegKey.duration,
    ]

    // MARK: - Configuration

    /// Replaces the global view segmentation.
    func setGlobalViewSegmentation(_ segmentation: [String: Any]) {
        logI("setGlobalViewSegmentation", "global view segmentation will be set, keyCount: [\(segmentation.count)]")
        globalViewSegmentation = sanitized(segmentation, context: "setting global view segmentation")
        logD("setGlobalViewSegmentation", "global view segmentation replaced, keys: [\(globalViewSegmentation.keys.sorted())], keyCount: [\(globalViewSegmentation.count)]")
        logV("setGlobalViewSegmentation", "global view segmentation value detail, segmentation: [\(globalViewSegmentation)]")
    }

    /// Merges into the global view segmentation.
    func updateGlobalViewSegmentation(_ segmentation: [String: Any]) {
        logI("updateGlobalViewSegmentation", "global view segmentation will be updated, keyCount: [\(segmentation.count)]")
        let filtered = sanitized(segmentation, context: "updating global view segmentation")
        logD("updateGlobalViewSegmentation", "global view segmentation will be merged, incomingKeys: [\(filtered.keys.sorted())], overwrittenKeys: [\(filtered.keys.filter { globalViewSegmentation[$0] != nil }.sorted())], existingKeyCount: [\(globalViewSegmentation.count)]")
        globalViewSegmentation.merge(filtered) { _, new in new }
        logV("updateGlobalViewSegmentation", "global view segmentation update value detail, segmentation: [\(globalViewSegmentation)]")
    }

    /// Adds names to the automatic view tracking exclusion list.
    func addAutoViewTrackingExclusionList(_ names: [String]) {
        logI("addAutoViewTrackingExclusionList", "auto view tracking exclusion list will be extended, incomingCount: [\(names.count)], currentCount: [\(automaticViewTrackingExclusionList.count)]")
        logD("addAutoViewTrackingExclusionList", "auto view tracking exclusion entry detail, addedNames: [\(names)]")
        automaticViewTrackingExclusionList.append(contentsOf: names)
        rebuildExclusionLookups()
    }

    /// Name matching is a set lookup; class matching needs the runtime, so the
    /// classes are resolved when the list changes rather than on every screen.
    private func rebuildExclusionLookups() {
        excludedNames = Set(automaticViewTrackingExclusionList)
        #if os(iOS) || os(tvOS) || os(visionOS)
        excludedClasses = automaticViewTrackingExclusionList.compactMap { NSClassFromString($0) }
        // An entry that resolves to no class only ever matches by name, so a
        // mistyped class name shows up here as a gap between the two counts.
        logD("rebuildExclusionLookups", "auto view tracking exclusion lookups rebuilt, nameCount: [\(excludedNames.count)], resolvedClassCount: [\(excludedClasses.count)]")
        #else
        logD("rebuildExclusionLookups", "auto view tracking exclusion name lookup rebuilt, nameCount: [\(excludedNames.count)]")
        #endif
    }

    // MARK: - Public view operations

    /// Starts a view that stays open until it is stopped.
    @discardableResult
    func startView(_ viewName: String, segmentation: [String: Any]? = nil) -> String? {
        logI("startView", "start view requested, name: [\(viewName)], segmentationKeyCount: [\(segmentation?.count ?? 0)], segmentationKeys: [\(segmentation?.keys.sorted() ?? [])]")
        logV("startView", "start view segmentation value detail, name: [\(viewName)], segmentation: [\(segmentation ?? [:])]")

        guard manualCallsAllowed("start view", "startView") else { return nil }

        return startViewInternal(viewName, customSegmentation: segmentation, isAutoStoppedView: false)
    }

    /// Starts a view that is stopped as soon as another view starts.
    @discardableResult
    func startAutoStoppedView(_ viewName: String, segmentation: [String: Any]? = nil) -> String? {
        logI("startAutoStoppedView", "start auto stopped view requested, name: [\(viewName)], segmentationKeyCount: [\(segmentation?.count ?? 0)], segmentationKeys: [\(segmentation?.keys.sorted() ?? [])]")
        logV("startAutoStoppedView", "start auto stopped view segmentation value detail, name: [\(viewName)], segmentation: [\(segmentation ?? [:])]")

        guard manualCallsAllowed("start auto stopped view", "startAutoStoppedView") else { return nil }

        return startViewInternal(viewName, customSegmentation: segmentation, isAutoStoppedView: true)
    }

    /// Stops the view with this name, the last one started when several share it.
    func stopView(name viewName: String, segmentation: [String: Any]? = nil) {
        logI("stopViewWithName", "stop view by name requested, name: [\(viewName)], segmentationKeyCount: [\(segmentation?.count ?? 0)]")

        guard manualCallsAllowed("stop view by name", "stopViewWithName") else { return }

        guard !viewName.isEmpty else {
            warnViewNotFound("stopViewWithName", "view name is null or empty, stop view by name will be ignored")
            return
        }

        guard core.modules.consent.hasConsent(for: .viewTracking) else {
            logV("stopViewWithName", "no consent for views, stop view by name will be ignored, name: [\(viewName)]")
            return
        }

        guard let viewID = viewID(forName: viewName) else {
            warnViewNotFound("stopViewWithName", "no view exists with the given name, it will not be stopped, name: [\(viewName)]")
            return
        }

        stopViewInternal(viewID: viewID, customSegmentation: segmentation, keepsView: false)
    }

    func stopView(id viewID: String, segmentation: [String: Any]? = nil) {
        logI("stopViewWithID", "stop view by ID requested, viewID: [\(viewID)], segmentationKeyCount: [\(segmentation?.count ?? 0)]")

        guard manualCallsAllowed("stop view by ID", "stopViewWithID") else { return }

        stopViewInternal(viewID: currentID(for: viewID), customSegmentation: segmentation, keepsView: false)
    }

    /// Reports the time a view was on screen so far and stops counting it, keeping
    /// the view open until it is resumed or stopped.
    func pauseView(id heldID: String) {
        logI("pauseView", "pause view requested, viewID: [\(heldID)]")
        let viewID = currentID(for: heldID)

        guard manualCallsAllowed("pause view", "pauseView") else { return }

        guard validateViewOperation(viewID: viewID, operation: "pause view") else { return }

        guard let viewData = viewDataDictionary[viewID] else {
            warnViewNotFound("pauseView", "no view exists with the given ID, it will not be paused, viewID: [\(viewID)]")
            return
        }

        guard !viewData.isPaused else {
            logW("pauseView", "the view is already paused, the call will be ignored, viewID: [\(viewID)], name: [\(viewData.viewName)], stoppedForBackground: [\(viewData.willStartAgain)]")
            core.healthTracker.recordLogCode(HealthLogCode.viewPauseMismatch, area: .views)
            return
        }

        logD("pauseView", "view resolved for pausing, its time so far is reported, viewID: [\(viewID)], name: [\(viewData.viewName)]")
        stopViewInternal(viewID: viewID, customSegmentation: nil, keepsView: true)
        viewData.pause()
    }

    /// Starts counting a paused view's time again, without a new start event.
    func resumeView(id heldID: String) {
        logI("resumeView", "resume view requested, viewID: [\(heldID)]")
        let viewID = currentID(for: heldID)

        guard manualCallsAllowed("resume view", "resumeView") else { return }

        guard validateViewOperation(viewID: viewID, operation: "resume view") else { return }

        guard let viewData = viewDataDictionary[viewID] else {
            warnViewNotFound("resumeView", "no view exists with the given ID, it will not be resumed, viewID: [\(viewID)]")
            return
        }

        guard viewData.isPaused, !viewData.willStartAgain else {
            let reason = viewData.willStartAgain
                ? "the view was stopped when the app went to the background and starts again when it returns"
                : "the view is not paused"
            logW("resumeView", "\(reason), the call will be ignored, viewID: [\(viewID)], name: [\(viewData.viewName)]")
            core.healthTracker.recordLogCode(HealthLogCode.viewPauseMismatch, area: .views)
            return
        }

        viewData.resume(at: core.clock.now())
        logD("resumeView", "view resumed and its duration clock restarted, viewID: [\(viewID)], name: [\(viewData.viewName)]")
    }

    /// Starts the view a SwiftUI screen reports for itself.
    ///
    /// Not gated like a manual call: the gate keeps a host from opening a second
    /// view for a screen automatic tracking already reports, and a SwiftUI screen
    /// is one the method exchange never sees. An ordinary view rather than an
    /// auto-stopped one, because the screen closes it itself when it disappears.
    func startReportedView(_ viewName: String, segmentation: [String: Any]?) -> String? {
        logI("startReportedView", "a SwiftUI screen reports itself, name: [\(viewName)], segmentationKeyCount: [\(segmentation?.count ?? 0)]")
        return startViewInternal(viewName, customSegmentation: segmentation, isAutoStoppedView: false)
    }

    /// Stops a view a SwiftUI screen reported for itself.
    ///
    /// Quiet when the view is already closed. A consent withdrawal or a switch of
    /// automatic tracking closes every open view, and the screen learning of it
    /// only when it disappears is not an error.
    func stopReportedView(id heldID: String, segmentation: [String: Any]?) {
        let viewID = currentID(for: heldID)
        guard viewDataDictionary[viewID] != nil else {
            logD("stopReportedView", "the reported view is already closed and nothing is stopped, viewID: [\(viewID)]")
            return
        }
        stopViewInternal(viewID: viewID, customSegmentation: segmentation, keepsView: false)
    }

    /// Closes every open view, not only the automatic ones, because view consent
    /// is being withdrawn. Runs while that consent still holds, so the views can
    /// still report how long they were open.
    func stopAllViewsForConsentWithdrawal() {
        stopAutoViewTracking()
        stopAllViewsInternal(segmentation: nil)
    }

    /// Stops every open view.
    func stopAllViews(segmentation: [String: Any]? = nil) {
        logI("stopAllViews", "stop all views requested, segmentationKeyCount: [\(segmentation?.count ?? 0)]")

        guard manualCallsAllowed("stop all views", "stopAllViews") else { return }

        stopAllViewsInternal(segmentation: segmentation)
    }

    /// Adds segmentation to an open view, reported when it stops.
    func addSegmentation(toViewWithID heldID: String, segmentation: [String: Any]) {
        logI("addSegmentationToViewWithID", "add segmentation to view by ID requested, viewID: [\(heldID)], segmentationKeyCount: [\(segmentation.count)]")
        let viewID = currentID(for: heldID)

        guard !viewID.isEmpty else {
            warnViewNotFound("addSegmentationToViewWithID", "view ID is null or empty, adding segmentation by view ID will be ignored")
            return
        }

        guard core.modules.consent.hasConsent(for: .viewTracking) else {
            logV("addSegmentationToViewWithID", "no consent for views, adding segmentation to view will be ignored, viewID: [\(viewID)]")
            return
        }

        guard let viewData = viewDataDictionary[viewID] else {
            warnViewNotFound("addSegmentationToViewWithID", "no view exists with the given ID, segmentation will not be added, viewID: [\(viewID)]")
            return
        }

        let filtered = sanitized(segmentation, context: "adding segmentation to a view")
        logD("addSegmentationToViewWithID", "segmentation will be added to view, viewID: [\(viewID)], name: [\(viewData.viewName)], keyCount: [\(filtered.count)]")
        viewData.segmentation.merge(filtered) { _, new in new }
    }

    /// Adds segmentation to the open view with this name, the last one started
    /// when several share it.
    func addSegmentation(toViewWithName viewName: String, segmentation: [String: Any]) {
        logI("addSegmentationToViewWithName", "add segmentation to view by name requested, name: [\(viewName)], segmentationKeyCount: [\(segmentation.count)]")

        guard !viewName.isEmpty else {
            warnViewNotFound("addSegmentationToViewWithName", "view name is null or empty, adding segmentation to view will be ignored")
            return
        }

        guard let viewID = viewID(forName: viewName) else {
            warnViewNotFound("addSegmentationToViewWithName", "no view exists with the given name, segmentation will not be added, name: [\(viewName)]")
            return
        }

        addSegmentation(toViewWithID: viewID, segmentation: segmentation)
    }

    /// Whether a manual view call may proceed.
    ///
    /// Automatic view tracking owns the view stack while it is running; letting a
    /// manual call in as well would produce two views for one screen.
    private func manualCallsAllowed(_ operation: String, _ function: String) -> Bool {
        guard isAutoViewTrackingActive else { return true }
        logW(function, "manual view calls are not allowed while automatic view tracking is active, the call will be ignored, operation: [\(operation)]")
        core.healthTracker.recordLogCode(HealthLogCode.automaticTrackingActive, area: .views)
        return false
    }

    /// Logs a call naming a view that is not open, and counts it for the health
    /// check.
    private func warnViewNotFound(_ function: String, _ message: String) {
        logW(function, message)
        core.healthTracker.recordLogCode(HealthLogCode.viewNotFound, area: .views)
    }

    // MARK: - Internals

    private func startViewInternal(_ viewName: String,
                                   customSegmentation: [String: Any]?,
                                   isAutoStoppedView: Bool,
                                   isAutomatic: Bool = false) -> String? {
        guard !viewName.isEmpty else {
            logW("startViewInternal", "view name is null or empty, start view will be ignored")
            core.healthTracker.recordLogCode(HealthLogCode.emptyViewName, area: .views)
            return nil
        }

        guard core.modules.consent.hasConsent(for: .viewTracking) else {
            logV("startViewInternal", "no consent for views, start view will be ignored, name: [\(viewName)]")
            return nil
        }

        guard core.serverConfig.viewTrackingEnabled else {
            logD("startViewInternal", "view tracking is disabled by server config, start view will be ignored, name: [\(viewName)]")
            return nil
        }

        stopAutoStoppedView()

        let truncatedName = limits.truncatedKey(viewName, "View name")

        var segmentation = globalViewSegmentation
        if let customSegmentation {
            let filtered = sanitized(customSegmentation, context: "the segmentation of the view being started")
            logD("startViewInternal", "start segmentation will be merged over the global view segmentation, name: [\(truncatedName)], startKeys: [\(filtered.keys.sorted())], overriddenGlobalKeys: [\(filtered.keys.filter { globalViewSegmentation[$0] != nil }.sorted())]")
            segmentation.merge(filtered) { _, new in new }
        }
        segmentation = limits.truncatedAndLimited(segmentation, "View segmentation")

        segmentation[SegKey.name] = truncatedName
        segmentation[SegKey.segment] = DeviceMetrics.osName
        segmentation[SegKey.visit] = 1

        // Only marked once a session is actually open, so a view started before
        // the session begins does not claim to be the session's landing screen.
        if isFirstView {
            if core.modules.sessions.isSessionStarted {
                isFirstView = false
                segmentation[SegKey.start] = 1
                logD("startViewInternal", "this is the first view of the session, it will be marked as the session start view, name: [\(truncatedName)]")
            } else {
                logD("startViewInternal", "no session is running yet, the view will not be marked as the session start view, name: [\(truncatedName)]")
            }
        }

        let viewID = core.clock.generateEventID()
        previousViewID = currentViewID
        currentViewID = viewID
        previousViewName = currentViewName
        currentViewName = truncatedName

        let viewData = CountlyViewData(viewID: viewID, viewName: truncatedName, startTime: core.clock.now(), startOrder: nextStartOrder)
        nextStartOrder += 1
        viewData.startSegmentation = customSegmentation ?? [:]
        viewData.isAutoStoppedView = isAutoStoppedView
        viewData.isAutomatic = isAutomatic
        viewDataDictionary[viewID] = viewData

        core.modules.events.recordReservedEvent(ReservedEventKey.view,
                                                segmentation: segmentation,
                                                id: viewID)

        logD("startViewInternal", "view started, name: [\(truncatedName)], viewID: [\(viewID)], previousViewID: [\(previousViewID ?? "")], segmentationKeyCount: [\(segmentation.count)], segmentationKeys: [\(segmentation.keys.sorted())], isAutoStoppedView: [\(isAutoStoppedView)], isAutomatic: [\(isAutomatic)]")
        logV("startViewInternal", "started view segmentation value detail, viewID: [\(viewID)], segmentation: [\(segmentation)]")

        return viewID
    }

    /// Records the view's end event and, unless the view is kept, forgets it.
    ///
    /// - Parameter keepsView: whether the view stays open, as it does when it is
    ///   paused or stopped for the background. A paused view's end event carries
    ///   a duration of 0, its time having been reported when it was paused.
    private func stopViewInternal(viewID: String, customSegmentation: [String: Any]?, keepsView: Bool) {
        guard validateViewOperation(viewID: viewID, operation: "stop view by ID") else { return }

        guard let viewData = viewDataDictionary[viewID] else {
            warnViewNotFound("stopViewInternal", "no view exists with the given ID, it will not be stopped, viewID: [\(viewID)]")
            return
        }

        var segmentation = viewData.segmentation
        if !globalViewSegmentation.isEmpty {
            logD("stopViewInternal", "global view segmentation takes precedence over the segmentation added to the view, viewID: [\(viewID)], globalKeys: [\(globalViewSegmentation.keys.sorted())], overriddenViewKeys: [\(segmentation.keys.filter { globalViewSegmentation[$0] != nil }.sorted())]")
        }
        segmentation.merge(globalViewSegmentation) { _, global in global }

        if let customSegmentation {
            let filtered = sanitized(customSegmentation, context: "the segmentation of the view being stopped")
            logD("stopViewInternal", "stop segmentation will be merged over the view segmentation, viewID: [\(viewID)], stopKeys: [\(filtered.keys.sorted())]")
            segmentation.merge(filtered) { _, new in new }
        }

        segmentation = limits.truncatedAndLimited(segmentation, "View segmentation")
        segmentation[SegKey.name] = viewData.viewName
        segmentation[SegKey.segment] = DeviceMetrics.osName

        let duration = viewData.duration(now: core.clock.now())
        core.modules.events.recordReservedEvent(ReservedEventKey.view,
                                                segmentation: segmentation,
                                                duration: TimeInterval(duration),
                                                id: viewData.viewID)

        logD("stopViewInternal", "view stopped, name: [\(viewData.viewName)], viewID: [\(viewData.viewID)], durationSeconds: [\(duration)], wasPaused: [\(viewData.isPaused)], segmentationKeyCount: [\(segmentation.count)], segmentationKeys: [\(segmentation.keys.sorted())], keepsView: [\(keepsView)]")
        logV("stopViewInternal", "stopped view segmentation value detail, viewID: [\(viewData.viewID)], segmentation: [\(segmentation)]")

        if !keepsView {
            viewDataDictionary.removeValue(forKey: viewID)
            forgetRestartAliases(of: viewID)
        }
    }

    /// The ID a view the host holds an ID for is open under now.
    private func currentID(for heldID: String) -> String {
        restartedViewIDs[heldID] ?? heldID
    }

    /// Drops the aliases that lead to a view which is gone for good.
    private func forgetRestartAliases(of viewID: String) {
        guard !restartedViewIDs.isEmpty else { return }
        restartedViewIDs = restartedViewIDs.filter { $0.value != viewID }
    }

    private func validateViewOperation(viewID: String, operation: String) -> Bool {
        guard !viewID.isEmpty else {
            warnViewNotFound("validateViewOperation", "view ID is null or empty, the view operation will be ignored, operation: [\(operation)]")
            return false
        }

        guard core.modules.consent.hasConsent(for: .viewTracking) else {
            logV("validateViewOperation", "no consent for views, the view operation will be ignored, operation: [\(operation)], viewID: [\(viewID)]")
            return false
        }

        guard core.serverConfig.viewTrackingEnabled else {
            logD("validateViewOperation", "view tracking is disabled by server config, the view operation will be ignored, operation: [\(operation)], viewID: [\(viewID)]")
            return false
        }

        return true
    }

    private var currentView: CountlyViewData? {
        guard let currentViewID else { return nil }
        return viewDataDictionary[currentViewID]
    }

    /// The open view with this name that was started last.
    private func viewID(forName viewName: String) -> String? {
        viewDataDictionary.values
            .filter { $0.viewName == viewName }
            .max { $0.startOrder < $1.startOrder }?
            .viewID
    }

    /// Open views, oldest first, so what reaches the server keeps the order the
    /// views were started in.
    private var viewsOldestFirst: [CountlyViewData] {
        viewDataDictionary.values.sorted { $0.startOrder < $1.startOrder }
    }

    private func stopAutoStoppedView() {
        guard let currentView, currentView.isAutoStoppedView else { return }

        guard !currentView.willStartAgain else {
            logD("stopAutoStoppedView", "the current auto stopped view is waiting to be restarted, it will not be stopped again, viewID: [\(currentView.viewID)], name: [\(currentView.viewName)]")
            return
        }

        logD("stopAutoStoppedView", "a new view is starting, the current auto stopped view will be stopped, viewID: [\(currentView.viewID)], name: [\(currentView.viewName)]")
        stopViewInternal(viewID: currentView.viewID, customSegmentation: nil, keepsView: false)
    }

    private func stopAllViewsInternal(segmentation: [String: Any]?) {
        guard core.modules.consent.hasConsent(for: .viewTracking) else {
            logV("stopAllViewsInternal", "no consent for views, stop all views will be ignored")
            return
        }

        logD("stopAllViewsInternal", "all views will be stopped, viewCount: [\(viewDataDictionary.count)], segmentationKeyCount: [\(segmentation?.count ?? 0)]")

        // Oldest first, rather than in whatever order the dictionary happens to
        // hold them. The order reaches the server, and an unordered iteration makes
        // two identical runs report the same screens in different sequences, which
        // is noise in the data and noise in any test that compares captures.
        for viewData in viewsOldestFirst {
            stopViewInternal(viewID: viewData.viewID, customSegmentation: segmentation, keepsView: false)
        }
    }

    /// Reopens the views that backgrounding closed.
    private func startStoppedViews() {
        let toRestart = viewsOldestFirst.filter(\.willStartAgain)
        guard !toRestart.isEmpty else { return }
        logD("startStoppedViews", "previously stopped views will be started automatically, viewCount: [\(toRestart.count)]")

        for viewData in toRestart {
            let newID = startViewInternal(viewData.viewName,
                                          customSegmentation: viewData.startSegmentation,
                                          isAutoStoppedView: viewData.isAutoStoppedView)

            if let newID, let newData = viewDataDictionary[newID] {
                logD("startStoppedViews", "view started automatically after restart, name: [\(viewData.viewName)], newViewID: [\(newID)], previousViewID: [\(viewData.viewID)], carriedSegmentationKeyCount: [\(viewData.segmentation.count)]")
                newData.segmentation = viewData.segmentation

                // Every ID the host may still hold for this view moves on with
                // it, so aliases never chain and a lookup is always one step.
                for (heldID, current) in restartedViewIDs where current == viewData.viewID {
                    restartedViewIDs[heldID] = newID
                }
                restartedViewIDs[viewData.viewID] = newID
            } else {
                logD("startStoppedViews", "a view marked for restart could not be started again, name: [\(viewData.viewName)], previousViewID: [\(viewData.viewID)]")
                forgetRestartAliases(of: viewData.viewID)
            }

            viewDataDictionary.removeValue(forKey: viewData.viewID)
        }
    }

    /// Drops the keys the SDK owns and the value types the server cannot store.
    /// Every entry point that accepts view segmentation applies both, in that
    /// order.
    private func sanitized(_ segmentation: [String: Any], context: String) -> [String: Any] {
        limits.filterSupportedDataTypes(stripReservedKeys(segmentation, context: context))
    }

    private func stripReservedKeys(_ segmentation: [String: Any], context: String) -> [String: Any] {
        let result = segmentation.filter { !Self.reservedSegmentationKeys.contains($0.key) }
        guard result.count != segmentation.count else { return result }

        logW("stripReservedKeys", "segmentation keys reserved by the SDK will be dropped, context: [\(context)], droppedKeyCount: [\(segmentation.count - result.count)], keptKeyCount: [\(result.count)]")
        logD("stripReservedKeys", "dropped reserved segmentation key detail, context: [\(context)], droppedKeys: [\(segmentation.keys.filter(Self.reservedSegmentationKeys.contains).sorted())]")
        return result
    }

    /// Clears the session start marker so the next view starts a new session's
    /// funnel.
    func resetFirstView() {
        logD("resetFirstView", "first view flag reset, the next started view will be marked as the session start view")
        isFirstView = true
    }

    // MARK: - Identity changes

    /// Stops every view before the identity its events carry changes: a device
    /// ID change without merge or an app key change. Each view, automatic or
    /// manual, paused or stopped by the background, records its end event under
    /// the leaving identity, and none starts again: the view IDs the app holds
    /// stop working.
    func stopAllViewsForIdentityChange() {
        logD("stopAllViewsForIdentityChange", "the identity changes, every view is stopped for good, viewCount: [\(viewDataDictionary.count)]")
        stopAllViewsInternal(segmentation: nil)

        // What consent or the behavior settings kept from being stopped above goes too.
        viewDataDictionary.removeAll()
        restartedViewIDs.removeAll()
        currentViewID = nil
        previousViewID = nil
        currentViewName = nil
        previousViewName = nil
    }

    /// Starts a view for the screen on display after an identity change, with
    /// automatic view tracking. In the background the screen gets its view when
    /// the application returns. Manual views are left to the application.
    func startViewForCurrentScreenAfterIdentityChange() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        guard isAutoViewTrackingActive else { return }
        guard AppState.isForeground else {
            reopensScreenOnForeground = true
            return
        }
        onMainThread { [weak self, core] in
            guard let self, core.hasStarted, self.isAutoViewTrackingActive else { return }
            self.startViewForTopViewController(from: "startViewForCurrentScreenAfterIdentityChange")
        }
        #endif
    }

    // MARK: - Automatic view tracking

    /// Starts reporting a view for every view controller that appears.
    func startAutoViewTracking() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        guard core.serverConfig.automaticViewTrackingEnabled else {
            logD("startAutoViewTracking", "automatic view tracking is not enabled by behavior settings, it will not be started")
            return
        }

        guard core.modules.consent.hasConsent(for: .viewTracking) else {
            logV("startAutoViewTracking", "no consent for views, automatic view tracking will not be started")
            return
        }

        // The method exchange is the only source of appearances, so refusing it
        // refuses the feature. Activating anyway would be worse than doing
        // nothing: the active flag makes the module reject the host's own view
        // calls, and the host would be left unable to report anything at all.
        guard !core.config.disableSwizzling else {
            logI("startAutoViewTracking", "automatic view tracking will not be started, reason: swizzling is disabled by configuration, report screens with the views API or the SwiftUI countlyView modifier instead")
            return
        }

        setAutoViewTrackingActive(true)
        AutoViewTracker.shared.register(self)
        logD("startAutoViewTracking", "automatic view tracking is enabled and registered for view controller appearances, exclusionEntryCount: [\(automaticViewTrackingExclusionList.count)]")

        startViewForTopViewController(from: "startAutoViewTracking")
        #endif
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    /// Starts an automatically stopped view for the view controller on screen,
    /// unless it has no usable name or is excluded.
    ///
    /// Used where the screen is already showing and no appearance will report
    /// it: when tracking starts, when the application comes back from the
    /// background, which UIKit does not report as an appearance, and after an
    /// identity change.
    private func startViewForTopViewController(from function: String) {
        let topViewController = AutoViewTracker.topViewController()
        guard let topViewController, let title = AutoViewTracker.title(for: topViewController) else {
            logD(function, "no view controller with a resolvable title is on screen, no view will be started until the next appearance")
            return
        }

        guard !isExcludedFromAutoTracking(topViewController, title: title, from: function) else { return }

        logD(function, "the view already on screen will be started automatically, name: [\(title)]")
        core.healthTracker.recordUsage(.views, "start", automatic: true)
        _ = startViewInternal(title, customSegmentation: nil, isAutoStoppedView: true, isAutomatic: true)
    }
    #endif

    /// Stops reporting view controller appearances.
    func stopAutoViewTracking() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        logD("stopAutoViewTracking", "automatic view tracking will be disabled, runningViewCount: [\(viewDataDictionary.count)]")
        setAutoViewTrackingActive(false)
        AutoViewTracker.shared.deregister(self)
        #endif
    }

    /// Applies the active state, stopping open views when it changes.
    ///
    /// Only enabling is gated: a disable has to go through whatever the reason, or
    /// a consent revocation would leave the tracker stuck on.
    private func setAutoViewTrackingActive(_ active: Bool) {
        if active {
            guard core.serverConfig.automaticViewTrackingEnabled else {
                logD("setAutoViewTrackingActive", "automatic view tracking is not enabled by behavior settings, active state change will be ignored")
                return
            }
            guard core.modules.consent.hasConsent(for: .viewTracking) else {
                logV("setAutoViewTrackingActive", "no consent for views, automatic view tracking active state change will be ignored")
                return
            }
        }

        if isAutoViewTrackingActive != active {
            logD("setAutoViewTrackingActive", "automatic view tracking active state changing from [\(isAutoViewTrackingActive)] to [\(active)], all running views will be stopped")
            stopAllViewsInternal(segmentation: nil)
        }

        isAutoViewTrackingActive = active
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    /// Called by the process-wide tracker for every appeared view controller.
    func handleAutoTrackedViewController(_ viewController: UIViewController) {
        guard isAutoViewTrackingActive else {
            logD("handleAutoTrackedViewController", "automatic view tracking is not active, appeared view controller will be ignored")
            return
        }

        // Re-checked per appearance, so a runtime disable from the server takes
        // effect on the very next screen rather than on the next launch.
        guard core.serverConfig.automaticViewTrackingEnabled else {
            logD("handleAutoTrackedViewController", "automatic view tracking is disabled by behavior settings, appeared view controller will be ignored")
            return
        }

        guard core.modules.consent.hasConsent(for: .viewTracking) else {
            logV("handleAutoTrackedViewController", "no consent for views, automatic view start will be ignored")
            return
        }

        guard let title = AutoViewTracker.title(for: viewController) else {
            let className = NSStringFromClass(type(of: viewController))
            guard !isExcludedFromAutoTracking(viewController, title: className, from: "handleAutoTrackedViewController") else { return }

            // The screen itself goes unreported, having no usable name, but the
            // one the user just left is still closed, or it would go on timing a
            // screen that is no longer shown.
            logD("handleAutoTrackedViewController", "appeared view controller has no readable name, only a compiler generated class name or a SwiftUI host of an erased view, no view is started for it and the current auto stopped view is closed, class: [\(className)]")
            stopAutoStoppedView()
            return
        }

        // Compared against the truncated form: that is what was stored when the
        // view started, so a long screen name would never match its own view and
        // would restart on every appearance.
        if currentView?.viewName == limits.truncatedKey(title, "View name") {
            logD("handleAutoTrackedViewController", "appeared view controller is already the current view, it will not be started again, name: [\(title)]")
            return
        }

        guard !isExcludedFromAutoTracking(viewController, title: title, from: "handleAutoTrackedViewController") else { return }

        // Automatically tracked views are auto stopped, so the screen the user just
        // left is closed and reports how long they were on it.
        //
        // The reference starts them as ordinary views, which are only ever closed
        // by an explicit stop. Nothing stops an automatic view, so navigating
        // A -> B -> C leaves A and B open for the life of the process and neither
        // reports a duration: the same journey yields three view durations on
        // Android and one here. Android is the reference when the SDKs disagree,
        // and a screen time feature that reports one screen out of three is not
        // worth being bug-compatible about.
        core.healthTracker.recordUsage(.views, "start", automatic: true)
        _ = startViewInternal(title, customSegmentation: nil, isAutoStoppedView: true, isAutomatic: true)
    }

    /// Whether the exclusion list covers this screen.
    ///
    /// Shared by the swizzle and by the first view recorded when automatic tracking
    /// starts. Those were two paths before, and only the swizzle consulted the
    /// list, so a screen the host application had excluded was still reported when
    /// tracking happened to start while it was on screen. The reference has the
    /// same split; it only escapes it because the screen is usually not there yet
    /// at that moment.
    private func isExcludedFromAutoTracking(_ viewController: UIViewController,
                                            title: String,
                                            from function: String) -> Bool {
        // Resolved once per appearance rather than once per exclusion entry: the
        // default list has 38 of them and this runs for every screen.
        let className = NSStringFromClass(type(of: viewController))

        for candidate in [title, className] where excludedNames.contains(candidate) {
            logD(function, "view is in the automatic view tracking exclusion list, it will be ignored, name: [\(title)], class: [\(className)], matchedEntry: [\(candidate)]")
            return true
        }

        if let excluded = excludedClasses.first(where: { viewController.isKind(of: $0) }) {
            logD(function, "view is a subclass of an excluded class, it will be ignored, name: [\(title)], class: [\(className)], matchedClass: [\(NSStringFromClass(excluded))]")
            return true
        }

        return false
    }
    #endif

    // MARK: - Orientation

    /// Records the interface orientation when it changed, or whenever `force` is
    /// set, which a session start uses so every `begin_session` carries one.
    ///
    /// Deduplicated: rotation notifications fire more often than the orientation
    /// actually changes, and a repeated event would inflate the numbers.
    func recordOrientation(force: Bool = false) {
        #if os(iOS)
        guard core.config.enableOrientationTracking else {
            logD("recordOrientation", "orientation tracking is disabled by the init config, orientation recording will be ignored")
            return
        }

        guard AppState.isForeground else {
            logD("recordOrientation", "app is in the background, orientation recording will be ignored")
            return
        }

        guard let mode = currentOrientationMode() else {
            logD("recordOrientation", "interface orientation is neither landscape nor portrait, orientation event will be skipped")
            return
        }

        guard force || mode != lastInterfaceOrientation else {
            logV("recordOrientation", "interface orientation did not change, orientation event will be skipped, mode: [\(mode)]")
            return
        }

        logD("recordOrientation", "interface orientation changed, previousMode: [\(lastInterfaceOrientation ?? "")], mode: [\(mode)]")

        guard core.modules.consent.hasConsent(for: .userDetails) else {
            logV("recordOrientation", "no consent for user details, the orientation event will not be recorded, mode: [\(mode)]")
            return
        }

        lastInterfaceOrientation = mode
        core.modules.events.recordReservedEvent(ReservedEventKey.orientation, segmentation: ["mode": mode])
        #endif
    }

    #if os(iOS)
    /// The interface orientation, read from the window's scene where one exists.
    ///
    /// Read from the interface rather than the device, because a device lying flat
    /// reports face up while the interface is still portrait or landscape.
    private func currentOrientationMode() -> String? {
        guard let orientation = ScreenReader.keyWindow?.windowScene?.interfaceOrientation else { return nil }
        if orientation.isPortrait { return "portrait" }
        if orientation.isLandscape { return "landscape" }
        return nil
    }
    #endif

    // MARK: - Lifecycle

    /// Starts again what the background stopped: the manual views marked for a
    /// restart, as new views, and with automatic view tracking a view for the
    /// screen on display.
    func applicationWillEnterForeground() {
        // Android re-reads the orientation on every activity start, not only at
        // launch, so a device rotated while the app was away is reported on the way
        // back in. The dedup against the last recorded mode keeps this quiet when
        // nothing changed.
        recordOrientation()

        startStoppedViews()

        #if os(iOS) || os(tvOS) || os(visionOS)
        guard isAutoViewTrackingActive else { return }
        guard reopensScreenOnForeground else {
            logD("applicationWillEnterForeground", "app entered foreground with automatic view tracking active, the background stopped no view, nothing is reopened")
            return
        }
        reopensScreenOnForeground = false
        logD("applicationWillEnterForeground", "app entered foreground with automatic view tracking active, the screen on display gets its view again")
        onMainThread { [weak self, core] in
            guard let self, core.hasStarted, self.isAutoViewTrackingActive else { return }
            self.startViewForTopViewController(from: "applicationWillEnterForeground")
        }
        #endif
    }

    /// Stops every running view with the time it was on screen, so no view counts
    /// time the application spends in the background. Manual views are kept for a
    /// restart on foreground unless `disableViewRestartForManualRecording` is set;
    /// an automatic view is not kept, the screen on display gets a new one. A
    /// paused view stays paused.
    func applicationDidEnterBackground() {
        let running = viewsOldestFirst.filter { !$0.isPaused }
        logD("applicationDidEnterBackground", "app entered background, running views will be stopped, runningViewCount: [\(running.count)], manualViewRestart: [\(isManualViewRestartActive)], automaticViewTracking: [\(isAutoViewTrackingActive)]")

        #if os(iOS) || os(tvOS) || os(visionOS)
        if running.contains(where: \.isAutomatic) {
            reopensScreenOnForeground = true
        }
        #endif

        for viewData in running {
            if !viewData.isAutomatic, isManualViewRestartActive {
                stopViewInternal(viewID: viewData.viewID, customSegmentation: nil, keepsView: true)
                viewData.pause()
                viewData.willStartAgain = true
            } else {
                stopViewInternal(viewID: viewData.viewID, customSegmentation: nil, keepsView: false)
            }
        }
    }

    func applicationWillTerminate() {
        logD("applicationWillTerminate", "app is terminating, every running view will be stopped, viewCount: [\(viewDataDictionary.count)]")
        stopAllViewsInternal(segmentation: nil)
    }

    override func halt(clearStorage: Bool) {
        logD("halt", "views module is halting, running views will be discarded without being reported, viewCount: [\(viewDataDictionary.count)], globalSegmentationKeyCount: [\(globalViewSegmentation.count)], clearStorage: [\(clearStorage)]")

        // Torn down without reporting. Routing through `stopAutoViewTracking` would
        // record a `[CLY]_view` end event for every open view, queued for an
        // instance that is going away, and written to a store that `clearStorage`
        // is about to wipe. The reference resets its state silently.
        #if os(iOS) || os(tvOS) || os(visionOS)
        AutoViewTracker.shared.deregister(self)
        isAutoViewTrackingActive = false
        reopensScreenOnForeground = false
        #endif

        viewDataDictionary.removeAll()
        restartedViewIDs.removeAll()
        globalViewSegmentation.removeAll()
        currentViewID = nil
        previousViewID = nil
        currentViewName = nil
        previousViewName = nil
        lastInterfaceOrientation = nil
        isFirstView = true
        nextStartOrder = 0
    }
}
