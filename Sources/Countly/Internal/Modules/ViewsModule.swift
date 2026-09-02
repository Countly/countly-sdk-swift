//
//  ViewsModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if os(iOS) || os(tvOS)
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

    /// Last reported interface orientation, so an unchanged rotation is not
    /// reported twice.
    private var lastInterfaceOrientation: String?

    /// Names and class names that automatic view tracking never reports.
    #if os(iOS) || os(tvOS)
    private var automaticViewTrackingExclusionList: [String] = AutoViewTracker.defaultExclusionList
    #else
    private var automaticViewTrackingExclusionList: [String] = []
    #endif

    /// Exclusion entries matched by name, and the subset that resolves to a real
    /// class. Rebuilt only when the list changes.
    private lazy var excludedNames: Set<String> = Set(automaticViewTrackingExclusionList)
    #if os(iOS) || os(tvOS)
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
        #if os(iOS) || os(tvOS)
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

    func stopView(name viewName: String, segmentation: [String: Any]? = nil) {
        logI("stopViewWithName", "stop view by name requested, name: [\(viewName)], segmentationKeyCount: [\(segmentation?.count ?? 0)]")

        guard manualCallsAllowed("stop view by name", "stopViewWithName") else { return }

        guard !viewName.isEmpty else {
            logE("stopViewWithName", "view name is null or empty, stop view by name will be ignored")
            return
        }

        guard core.modules.consent.hasConsent(for: .viewTracking) else {
            logV("stopViewWithName", "no consent for views, stop view by name will be ignored, name: [\(viewName)]")
            return
        }

        guard let viewID = viewID(forName: viewName) else {
            logE("stopViewWithName", "no view exists with the given name, it will not be stopped, name: [\(viewName)]")
            return
        }

        stopViewInternal(viewID: viewID, customSegmentation: segmentation, autoPaused: false)
    }

    func stopView(id viewID: String, segmentation: [String: Any]? = nil) {
        logI("stopViewWithID", "stop view by ID requested, viewID: [\(viewID)], segmentationKeyCount: [\(segmentation?.count ?? 0)]")

        guard manualCallsAllowed("stop view by ID", "stopViewWithID") else { return }

        stopViewInternal(viewID: viewID, customSegmentation: segmentation, autoPaused: false)
    }

    /// Stops the clock on a view without closing it.
    func pauseView(id viewID: String) {
        logI("pauseView", "pause view requested, viewID: [\(viewID)]")

        guard manualCallsAllowed("pause view", "pauseView") else { return }

        guard validateViewOperation(viewID: viewID, operation: "pause view") else { return }

        guard let viewData = viewDataDictionary[viewID] else {
            logE("pauseView", "no view exists with the given ID, it will not be paused, viewID: [\(viewID)]")
            return
        }

        logD("pauseView", "view resolved for pausing, viewID: [\(viewID)], name: [\(viewData.viewName)]")
        stopViewInternal(viewID: viewID, customSegmentation: nil, autoPaused: true)
        viewData.pause(at: core.clock.now())
    }

    /// Restarts the clock on a paused view.
    func resumeView(id viewID: String) {
        logI("resumeView", "resume view requested, viewID: [\(viewID)]")

        guard manualCallsAllowed("resume view", "resumeView") else { return }

        guard validateViewOperation(viewID: viewID, operation: "resume view") else { return }

        guard let viewData = viewDataDictionary[viewID] else {
            logE("resumeView", "no view exists with the given ID, it will not be resumed, viewID: [\(viewID)]")
            return
        }

        viewData.resume(at: core.clock.now())
        logD("resumeView", "view resumed and its duration clock restarted, viewID: [\(viewID)], name: [\(viewData.viewName)]")
    }

    /// Stops every open view.
    func stopAllViews(segmentation: [String: Any]? = nil) {
        logI("stopAllViews", "stop all views requested, segmentationKeyCount: [\(segmentation?.count ?? 0)]")

        guard manualCallsAllowed("stop all views", "stopAllViews") else { return }

        stopAllViewsInternal(segmentation: segmentation)
    }

    /// Adds segmentation to an open view, reported when it stops.
    func addSegmentation(toViewWithID viewID: String, segmentation: [String: Any]) {
        logI("addSegmentationToViewWithID", "add segmentation to view by ID requested, viewID: [\(viewID)], segmentationKeyCount: [\(segmentation.count)]")

        guard !viewID.isEmpty else {
            logE("addSegmentationToViewWithID", "view ID is null or empty, adding segmentation by view ID will be ignored")
            return
        }

        guard core.modules.consent.hasConsent(for: .viewTracking) else {
            logV("addSegmentationToViewWithID", "no consent for views, adding segmentation to view will be ignored, viewID: [\(viewID)]")
            return
        }

        guard let viewData = viewDataDictionary[viewID] else {
            logE("addSegmentationToViewWithID", "no view exists with the given ID, segmentation will not be added, viewID: [\(viewID)]")
            return
        }

        let filtered = sanitized(segmentation, context: "adding segmentation to a view")
        logD("addSegmentationToViewWithID", "segmentation will be added to view, viewID: [\(viewID)], name: [\(viewData.viewName)], keyCount: [\(filtered.count)]")
        viewData.segmentation.merge(filtered) { _, new in new }
    }

    /// Adds segmentation to the open view with this name.
    func addSegmentation(toViewWithName viewName: String, segmentation: [String: Any]) {
        logI("addSegmentationToViewWithName", "add segmentation to view by name requested, name: [\(viewName)], segmentationKeyCount: [\(segmentation.count)]")

        guard !viewName.isEmpty else {
            logE("addSegmentationToViewWithName", "view name is null or empty, adding segmentation to view will be ignored")
            return
        }

        guard let viewID = viewID(forName: viewName) else {
            logE("addSegmentationToViewWithName", "no view exists with the given name, segmentation will not be added, name: [\(viewName)]")
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
        return false
    }

    // MARK: - Internals

    private func startViewInternal(_ viewName: String,
                                   customSegmentation: [String: Any]?,
                                   isAutoStoppedView: Bool) -> String? {
        guard !viewName.isEmpty else {
            logE("startViewInternal", "view name is null or empty, start view will be ignored")
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

        let truncatedName = core.limits.truncatedKey(viewName, "View name")

        var segmentation = globalViewSegmentation
        if let customSegmentation {
            let filtered = sanitized(customSegmentation, context: "the segmentation of the view being started")
            logD("startViewInternal", "start segmentation will be merged over the global view segmentation, name: [\(truncatedName)], startKeys: [\(filtered.keys.sorted())], overriddenGlobalKeys: [\(filtered.keys.filter { globalViewSegmentation[$0] != nil }.sorted())]")
            segmentation.merge(filtered) { _, new in new }
        }
        segmentation = core.limits.truncatedAndLimited(segmentation, "View segmentation")

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

        let viewData = CountlyViewData(viewID: viewID, viewName: truncatedName, startTime: core.clock.now())
        viewData.startSegmentation = customSegmentation ?? [:]
        viewData.isAutoStoppedView = isAutoStoppedView
        viewDataDictionary[viewID] = viewData

        core.modules.events.recordReservedEvent(ReservedEventKey.view,
                                                segmentation: segmentation,
                                                id: viewID)

        logD("startViewInternal", "view started, name: [\(truncatedName)], viewID: [\(viewID)], previousViewID: [\(previousViewID ?? "")], segmentationKeyCount: [\(segmentation.count)], segmentationKeys: [\(segmentation.keys.sorted())], isAutoStoppedView: [\(isAutoStoppedView)]")
        logV("startViewInternal", "started view segmentation value detail, viewID: [\(viewID)], segmentation: [\(segmentation)]")

        return viewID
    }

    /// Records the view event and, unless the view is only being paused, forgets
    /// the view.
    private func stopViewInternal(viewID: String, customSegmentation: [String: Any]?, autoPaused: Bool) {
        guard validateViewOperation(viewID: viewID, operation: "stop view by ID") else { return }

        guard let viewData = viewDataDictionary[viewID] else {
            logE("stopViewInternal", "no view exists with the given ID, it will not be stopped, viewID: [\(viewID)]")
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

        segmentation = core.limits.truncatedAndLimited(segmentation, "View segmentation")
        segmentation[SegKey.name] = viewData.viewName
        segmentation[SegKey.segment] = DeviceMetrics.osName

        let duration = viewData.duration(now: core.clock.now())
        core.modules.events.recordReservedEvent(ReservedEventKey.view,
                                                segmentation: segmentation,
                                                duration: TimeInterval(duration),
                                                id: viewData.viewID)

        logD("stopViewInternal", "view stopped, name: [\(viewData.viewName)], viewID: [\(viewData.viewID)], durationSeconds: [\(duration)], segmentationKeyCount: [\(segmentation.count)], segmentationKeys: [\(segmentation.keys.sorted())], autoPaused: [\(autoPaused)]")
        logV("stopViewInternal", "stopped view segmentation value detail, viewID: [\(viewData.viewID)], segmentation: [\(segmentation)]")

        if !autoPaused {
            viewDataDictionary.removeValue(forKey: viewID)
        }
    }

    private func validateViewOperation(viewID: String, operation: String) -> Bool {
        guard !viewID.isEmpty else {
            logE("validateViewOperation", "view ID is null or empty, the view operation will be ignored, operation: [\(operation)]")
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

    private func viewID(forName viewName: String) -> String? {
        viewDataDictionary.first { $0.value.viewName == viewName }?.key
    }

    private func stopAutoStoppedView() {
        guard let currentView, currentView.isAutoStoppedView else { return }

        guard !currentView.willStartAgain else {
            logD("stopAutoStoppedView", "the current auto stopped view is waiting to be restarted, it will not be stopped again, viewID: [\(currentView.viewID)], name: [\(currentView.viewName)]")
            return
        }

        logD("stopAutoStoppedView", "a new view is starting, the current auto stopped view will be stopped, viewID: [\(currentView.viewID)], name: [\(currentView.viewName)]")
        stopViewInternal(viewID: currentView.viewID, customSegmentation: nil, autoPaused: false)
    }

    private func stopCurrentView() {
        guard let currentView else {
            logD("stopCurrentView", "there is no current view, nothing will be stopped")
            return
        }

        logD("stopCurrentView", "the current view will be stopped, viewID: [\(currentView.viewID)], name: [\(currentView.viewName)]")
        stopViewInternal(viewID: currentView.viewID, customSegmentation: nil, autoPaused: false)
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
        let ordered = viewDataDictionary
            .sorted { $0.value.viewStartTime < $1.value.viewStartTime }
            .map(\.key)

        for viewID in ordered {
            stopViewInternal(viewID: viewID, customSegmentation: segmentation, autoPaused: false)
        }
    }

    /// Closes every open view but remembers them, so foregrounding can reopen them
    /// with fresh IDs and durations.
    private func stopRunningViewsForRestart() {
        logD("stopRunningViewsForRestart", "running views will be stopped automatically and marked for restart, viewCount: [\(viewDataDictionary.count)]")
        for viewData in viewDataDictionary.values.sorted(by: { $0.viewStartTime < $1.viewStartTime }) {
            viewData.willStartAgain = true
            stopViewInternal(viewID: viewData.viewID, customSegmentation: nil, autoPaused: true)
        }
    }

    /// Reopens the views that backgrounding closed.
    private func startStoppedViews() {
        let toRestart = viewDataDictionary.values
            .filter(\.willStartAgain)
            .sorted { $0.viewStartTime < $1.viewStartTime }
        logD("startStoppedViews", "previously stopped views will be started automatically, viewCount: [\(toRestart.count)]")

        for viewData in toRestart {
            let newID = startViewInternal(viewData.viewName,
                                          customSegmentation: viewData.startSegmentation,
                                          isAutoStoppedView: viewData.isAutoStoppedView)

            if let newID, let newData = viewDataDictionary[newID] {
                logD("startStoppedViews", "view started automatically after restart, name: [\(viewData.viewName)], newViewID: [\(newID)], previousViewID: [\(viewData.viewID)], carriedSegmentationKeyCount: [\(viewData.segmentation.count)]")
                newData.segmentation = viewData.segmentation
            } else {
                logD("startStoppedViews", "a view marked for restart could not be started again, name: [\(viewData.viewName)], previousViewID: [\(viewData.viewID)]")
            }

            viewDataDictionary.removeValue(forKey: viewData.viewID)
        }
    }

    /// Drops the keys the SDK owns and the value types the server cannot store.
    /// Every entry point that accepts view segmentation applies both, in that
    /// order.
    private func sanitized(_ segmentation: [String: Any], context: String) -> [String: Any] {
        core.limits.filterSupportedDataTypes(stripReservedKeys(segmentation, context: context))
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

    // MARK: - Automatic view tracking

    /// Starts reporting a view for every view controller that appears.
    func startAutoViewTracking() {
        #if os(iOS) || os(tvOS)
        guard core.serverConfig.automaticViewTrackingEnabled else {
            logD("startAutoViewTracking", "automatic view tracking is not enabled by behavior settings, it will not be started")
            return
        }

        guard core.modules.consent.hasConsent(for: .viewTracking) else {
            logV("startAutoViewTracking", "no consent for views, automatic view tracking will not be started")
            return
        }

        setAutoViewTrackingActive(true)
        AutoViewTracker.shared.register(self)
        logD("startAutoViewTracking", "automatic view tracking is enabled and registered for view controller appearances, exclusionEntryCount: [\(automaticViewTrackingExclusionList.count)]")

        let topViewController = AutoViewTracker.topViewController()
        guard let topViewController, let title = AutoViewTracker.title(for: topViewController) else {
            logD("startAutoViewTracking", "no view controller with a resolvable title is on screen, no view will be started until the next appearance")
            return
        }

        guard !isExcludedFromAutoTracking(topViewController, title: title, from: "startAutoViewTracking") else { return }

        logD("startAutoViewTracking", "the view already on screen will be started automatically, name: [\(title)]")
        _ = startViewInternal(title, customSegmentation: nil, isAutoStoppedView: true)
        #endif
    }

    /// Stops reporting view controller appearances.
    func stopAutoViewTracking() {
        #if os(iOS) || os(tvOS)
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

    #if os(iOS) || os(tvOS)
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
            logD("handleAutoTrackedViewController", "appeared view controller has no resolvable title, no view will be started for it, class: [\(NSStringFromClass(type(of: viewController)))]")
            return
        }

        // Compared against the truncated form: that is what was stored when the
        // view started, so a long screen name would never match its own view and
        // would restart on every appearance.
        if currentView?.viewName == core.limits.truncatedKey(title, "View name") {
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
        _ = startViewInternal(title, customSegmentation: nil, isAutoStoppedView: true)
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

    /// Reports the interface orientation when it changes.
    ///
    /// Deduplicated: rotation notifications fire more often than the orientation
    /// actually changes, and a repeated event would inflate the numbers.
    func recordOrientation() {
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

        guard mode != lastInterfaceOrientation else {
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
        var orientation: UIInterfaceOrientation?

        if #available(iOS 13.0, *) {
            orientation = ScreenReader.keyWindow?.windowScene?.interfaceOrientation
        } else {
            orientation = UIApplication.shared.statusBarOrientation
        }

        guard let orientation else { return nil }
        if orientation.isPortrait { return "portrait" }
        if orientation.isLandscape { return "landscape" }
        return nil
    }
    #endif

    // MARK: - Lifecycle

    func applicationWillEnterForeground() {
        #if os(iOS) || os(tvOS)
        if !isAutoViewTrackingActive, isManualViewRestartActive {
            logD("applicationWillEnterForeground", "app entered foreground with manual view restart active, stopped views will be started automatically")
            startStoppedViews()
        } else {
            logD("applicationWillEnterForeground", "app entered foreground, no views will be restarted, isAutoViewTrackingActive: [\(isAutoViewTrackingActive)], isManualViewRestartActive: [\(isManualViewRestartActive)]")
        }
        #else
        if isManualViewRestartActive {
            logD("applicationWillEnterForeground", "app entered foreground on a non UIKit platform, stopped views will be started automatically")
            startStoppedViews()
        } else {
            logD("applicationWillEnterForeground", "app entered foreground on a non UIKit platform with manual view restart off, no views will be restarted")
        }
        #endif
    }

    func applicationDidEnterBackground() {
        #if os(iOS) || os(tvOS)
        if isAutoViewTrackingActive {
            logD("applicationDidEnterBackground", "app entered background while automatic view tracking is active, current view will be stopped automatically")
            stopCurrentView()
        } else if isManualViewRestartActive {
            logD("applicationDidEnterBackground", "app entered background with manual view restart active, running views will be stopped automatically")
            stopRunningViewsForRestart()
        } else {
            logD("applicationDidEnterBackground", "app entered background with automatic view tracking and manual view restart both off, running views will be left open, viewCount: [\(viewDataDictionary.count)]")
        }
        #else
        if isManualViewRestartActive {
            logD("applicationDidEnterBackground", "app entered background on a non UIKit platform, running views will be stopped automatically")
            stopRunningViewsForRestart()
        } else {
            logD("applicationDidEnterBackground", "app entered background on a non UIKit platform with manual view restart off, running views will be left open, viewCount: [\(viewDataDictionary.count)]")
        }
        #endif
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
        #if os(iOS) || os(tvOS)
        AutoViewTracker.shared.deregister(self)
        isAutoViewTrackingActive = false
        #endif

        viewDataDictionary.removeAll()
        globalViewSegmentation.removeAll()
        currentViewID = nil
        previousViewID = nil
        currentViewName = nil
        previousViewName = nil
        lastInterfaceOrientation = nil
        isFirstView = true
    }
}
