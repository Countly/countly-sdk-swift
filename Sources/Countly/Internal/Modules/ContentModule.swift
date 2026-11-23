//
//  ContentModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

/// Polls the server for in-app content and puts it on screen.
///
/// While a content zone is entered the SDK asks periodically whether the server
/// has anything to show this user. At most one content is displayed at a time,
/// enforced by a presentation slot, because two overlapping web views over the
/// application would be unusable.
final class ContentModule: ModuleBase {

    override class var moduleName: String { "Content" }

    /// Endpoint content is fetched from.
    private static let endpoint = Endpoint.output + Endpoint.sdk + "/content"

    /// The `method` value of a content fetch.
    private static let fetchMethod = "queue"

    /// How many times a journey trigger retries before giving up and going back to
    /// ordinary polling.
    private static let queueCheckInterval: TimeInterval = 0.5
    private static let queueChecks = 5
    private static let contentRetryInterval: TimeInterval = 1.0
    private static let contentRequests = 3
    private static let earlyTriggerLimit = 50
    /// Least time before the same trigger starts another round: a listed event key, view name or user property
    private static let gapSpecificMs: Int64 = 10_000
    /// Least time before the same trigger starts another round: any view, any user property or any error
    private static let gapNonSpecificMs: Int64 = 60_000

    /// How long after launch content is allowed to appear, so it does not land on
    /// top of the application's own first screen.
    private var contentInitialDelay = 4

    private var zoneTimer: Timer?
    private var reentryTimer: Timer?

    private let stateLock = NSLock()

    /// Set while a content is on screen. The single presentation slot.
    private var isContentShown = false

    /// Incremented on every claim, so a teardown queued for an older presentation
    /// cannot dismiss a newer one.
    private var presentationSequence: UInt = 0

    /// Set while a fetch is in flight, so ticks do not pile up.
    private var isFetchInFlight = false

    /// Set while a refresh is waiting for the request queue to drain, so repeated
    /// refresh calls do not each queue their own fetch.
    private var isRefreshPending = false

    /// Set from the moment the zone is entered, before the polling timer exists.
    private var isZoneEntered = false

    /// Set while a journey trigger's retry series is running, so a second trigger
    /// arriving during it does not start a series of its own. Cleared when a
    /// content is shown or the attempts run out.
    // Guarded by stateLock: wanted after an enter, until an exit; exited after an exit, until an enter.
    private var isZoneWanted = false
    private var isZoneExited = false
    private var behaviorSettingsSettled = false
    private var triggersHalted = false

    // Content trigger rounds, main queue only.
    private var isTriggerRoundRunning = false
    private var isTriggerRoundPending = false
    private var contentTriggerChain: UInt = 0
    private var triggerGeneration: UInt = 0
    private var earlyTriggers: [RecordedTrigger] = []

    /// Bumped on every enter and every clear, so work scheduled by one visit to
    /// the zone cannot land after a later exit. The initial fetch is delayed by up
    /// to `contentInitialDelay` seconds, which is a long time for an application to
    /// change its mind in.
    private var zoneGeneration: UInt = 0

    #if os(iOS) || os(visionOS) || os(macOS)
    private var webViewManager: WebViewManager?
    #endif

    /// Keys the server reads off content and feedback widget events to count and
    /// attribute them, which a global segmentation therefore may not set.
    static let reservedGlobalSegmentationKeys: Set<String> = [
        "platform", "app_version", "widget_id", "closed", "shown", "started", "answered", "rating",
        "comment", "email", "contactMe", "campaign_id", "content_id", "element_id", "dismissed",
        "journey_id", "journey_definition_id", "journeyId", "journeyDefinitionId", "journeyInstanceId",
    ]

    /// Prefix of the keys a survey reports its answers under, reserved like the
    /// keys above.
    static let reservedSurveyAnswerKeyPrefix = "answ-"

    /// Recorded with every content and feedback widget event. Replaced whole under
    /// `stateLock`, since the setter runs on any thread while an event reads it.
    private var globalSegmentation: [String: Any] = [:]

    // MARK: - Global segmentation

    /// Sets the segmentation recorded with every content and feedback widget
    /// event, on top of the keys those events report themselves. Reserved keys
    /// and survey answer keys are dropped, then the SDK limits applied. `nil` or
    /// an empty dictionary clears it. Kept for the life of the run only.
    func setGlobalContentSegmentation(_ segmentation: [String: Any]?) {
        guard let segmentation, !segmentation.isEmpty else {
            logD("setGlobalContentSegmentation", "the global content segmentation is cleared")
            replaceGlobalSegmentation([:])
            return
        }

        var allowed: [String: Any] = [:]
        for (key, value) in segmentation {
            if Self.reservedGlobalSegmentationKeys.contains(key) || key.hasPrefix(Self.reservedSurveyAnswerKeyPrefix) {
                logW("setGlobalContentSegmentation", "a reserved key is dropped from the global content segmentation, key: [\(key)]")
            } else {
                allowed[key] = value
            }
        }

        // After the reserved keys are gone, so they do not use up the segmentation limit.
        let sanitized = limits.sanitized(allowed, "Global content segmentation") ?? [:]
        logD("setGlobalContentSegmentation", "the global content segmentation is set, providedKeyCount: [\(segmentation.count)], keptKeys: [\(sanitized.keys.sorted())]")
        replaceGlobalSegmentation(sanitized)
    }

    /// The global segmentation for a widget page to report with its answers.
    var currentGlobalSegmentation: [String: Any] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return globalSegmentation
    }

    /// Merges the global segmentation under an event's own, the event's keys
    /// winning. Global keys are added only while the segmentation limit leaves
    /// room, so the limit never trims the event's own keys for them.
    func withGlobalSegmentation(_ eventSegmentation: [String: Any]?) -> [String: Any]? {
        let global = currentGlobalSegmentation
        guard !global.isEmpty else { return eventSegmentation }

        let own = eventSegmentation ?? [:]
        var room = max(0, core.config.sdkInternalLimits.maxSegmentationValues - own.count)
        var merged = own
        for key in global.keys.sorted() where merged[key] == nil {
            guard room > 0 else { break }
            merged[key] = global[key]
            room -= 1
        }
        return merged
    }

    /// Swaps in a new global segmentation under the lock.
    private func replaceGlobalSegmentation(_ segmentation: [String: Any]) {
        stateLock.lock()
        globalSegmentation = segmentation
        stateLock.unlock()
    }

    // MARK: - Zone lifecycle

    /// Starts polling for content.
    func enterContentZone() {
        guard isContentAvailable("enterContentZone") else { return }

        guard !isShown() else {
            logD("enterContentZone", "a content is already shown, skipping this enter")
            return
        }

        guard core.modules.consent.hasConsent(for: .content) else {
            logV("enterContentZone", "no consent given for content, skipping the content zone enter")
            return
        }

        stateLock.lock()
        isZoneWanted = true
        isZoneExited = false
        stateLock.unlock()

        // Claimed now rather than when the timer is created: the first fetch is
        // delayed by up to the initial delay, and a second enter inside that window
        // would otherwise pass the guard and leave an orphan timer polling forever.
        stateLock.lock()
        if isZoneEntered {
            stateLock.unlock()
            logW("enterContentZone", "already entered the content zone, please exit from the content zone first to start again")
            return
        }
        isZoneEntered = true
        zoneGeneration &+= 1
        let generation = zoneGeneration
        stateLock.unlock()

        invalidateTimers()

        // The first fetch is held back on a cold launch so content does not land
        // on top of the application's own first screen.
        let delay = core.clock.timeSinceLaunch() < contentInitialDelay ? contentInitialDelay : 0
        let interval = TimeInterval(core.config.content.zoneTimerInterval)

        logD("enterContentZone", "content zone entered, initialDelay: [\(delay)], zoneTimerInterval: [\(interval.logValue)]")

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self else { return }

            // The zone may have been exited, or exited and re-entered, while this
            // was waiting. Without the check the block would fetch after an
            // explicit exit and install a repeating timer that nothing holds a
            // reference to, which then polls for the life of the process.
            guard self.isCurrentGeneration(generation) else {
                self.logD("enterContentZone", "the delayed first fetch is dropped, the content zone was left while it was waiting")
                return
            }

            self.fetchContents()
            self.zoneTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.fetchContents()
            }
        }
    }

    /// Stops polling and takes any displayed content off screen.
    func exitContentZone() {
        logI("exitContentZone", "exiting the content zone and taking the content off screen")
        stateLock.lock()
        isZoneWanted = false
        isZoneExited = true
        stateLock.unlock()
        clearContentState()
        closeShownContent()
    }

    /// Enters the zone again once temporary device ID mode ends, when the server
    /// asks for the zone to be entered: entering the mode at runtime exited it.
    func temporaryDeviceIDModeLeft() {
        enterForServerIfNeeded(from: "temporaryDeviceIDModeLeft")
    }

    /// Enters the zone when the server's "ecz" setting asks for it and the zone
    /// is not entered yet.
    private func enterForServerIfNeeded(from function: String) {
        guard core.serverConfig.enterContentZone else { return }
        stateLock.lock()
        let isEntered = isZoneEntered
        stateLock.unlock()
        guard !isEntered else {
            logD(function, "the server asks for the content zone and it is already entered")
            return
        }
        logD(function, "the server asks for the content zone, it is entered")
        enterContentZone()
    }

    /// Fetches one content by ID without starting the polling loop. The ID is the
    /// 24 character hexadecimal ID of the content; anything else is ignored with a
    /// warning, since the server would answer it as an ordinary fetch.
    func previewContent(_ contentID: String) {
        guard contentID.count == 24, contentID.allSatisfy(\.isHexDigit) else {
            logW("previewContent", "the content ID is not a 24 character hexadecimal ID, the preview is ignored, contentIdLength: [\(contentID.count)]")
            core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
            return
        }
        guard isContentAvailable("previewContent") else { return }
        logD("previewContent", "fetching a content for preview, contentId: [\(contentID)]")
        fetchContents(contentID: contentID, failure: nil)
    }

    /// Asks the server again as soon as everything queued has been accepted.
    ///
    /// Refreshing before the queue drains would ask about a user state the server
    /// has not seen yet, so the refresh rides on the flush instead.
    func refreshContentZone() {
        guard isContentAvailable("refreshContentZone") else { return }

        guard core.serverConfig.refreshContentZoneEnabled else {
            logD("refreshContentZone", "the content zone refresh is disabled by the server config, skipping")
            return
        }

        guard !isShown() else {
            logD("refreshContentZone", "a content is already shown, skipping this content zone refresh")
            return
        }

        // Coalesced: without this, several refreshes before one flush each append a
        // runnable and then all fire together, producing a burst of concurrent
        // fetches whose extra answers are thrown away.
        stateLock.lock()
        if isRefreshPending {
            stateLock.unlock()
            logD("refreshContentZone", "a content refresh is already pending, skipping this duplicate refresh")
            return
        }
        isRefreshPending = true
        stateLock.unlock()

        core.network.addQueueFlushRunnable { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.isRefreshPending = false
            self.stateLock.unlock()

            self.logD("refreshContentZone", "the request queue flushed, will re-fetch contents")
            // State only: a refresh must never pull content off screen.
            self.clearContentState()
            self.enterContentZone()
        }

        core.modules.events.addEventsToRequestQueue()
        core.requestQueueStore.saveSync()
        core.network.proceedOnQueue()
    }

    // MARK: - Content triggers

    /// Something the SDK recorded, as content triggers compare it.
    struct RecordedTrigger: Equatable {
        /// The event key as the application passed it, or one of the `ContentTriggerKey` keys.
        let key: String
        /// The view name as the application passed it, for a view event.
        var viewName: String? = nil
        /// Whether the view event is the one recorded when the view ends.
        var viewEnd = false
        /// The user properties a user details request sends.
        var properties: [String]? = nil
        /// Whether it is an event of the application rather than one the SDK records itself.
        var customEvent = false
    }

    /// A recorded trigger that starts a round: the triggers its gap is kept for,
    /// and the gap in milliseconds.
    struct TriggerMatch {
        let gapKeys: [String]
        let gapMs: Int64
    }

    /// Checks whether something the SDK recorded is a content trigger and, when it
    /// is, sends the queued requests and asks for content right away instead of
    /// waiting for the content zone timer. Can be called on any thread.
    func contentTriggerRecorded(_ trigger: RecordedTrigger) {
        #if os(iOS) || os(visionOS) || os(macOS)
        guard !areTriggersHalted else { return }
        guard !core.config.disableWebView else { return }
        stateLock.lock()
        let settled = behaviorSettingsSettled
        stateLock.unlock()
        // Once the settings of this run are in, what matches nothing is dropped
        // here, so only triggers reach the main queue.
        if settled, contentTriggerMatch(trigger) == nil {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.handleContentTrigger(trigger)
        }
        #endif
    }

    /// Called when the behavior settings answer of this run arrived, or when none
    /// will arrive. What was recorded before it and the settings in use did not
    /// list is checked again, so content for a first session is still asked for.
    ///
    /// - Parameters:
    ///   - answered: whether an answer arrived and was applied.
    ///   - entersContentZone: whether the answer of a first start has "ecz" on,
    ///     so the content zone is entered now.
    func behaviorSettingsSettled(answered: Bool, entersContentZone: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let early = self.earlyTriggers
            self.earlyTriggers.removeAll()

            self.stateLock.lock()
            let wasSettled = self.behaviorSettingsSettled
            self.behaviorSettingsSettled = true
            let isWanted = self.isZoneWanted
            let isExited = self.isZoneExited
            self.stateLock.unlock()

            guard !wasSettled, answered else { return }

            if entersContentZone, !isWanted, !isExited {
                self.logD("behaviorSettingsSettled", "no behavior settings were stored at start, and the first answer has 'ecz' on, the content zone is entered")
                self.enterContentZone()
            }

            for trigger in early where self.contentTriggerMatch(trigger) != nil {
                self.logD("behaviorSettingsSettled", "the trigger was recorded before the behavior settings arrived, key: [\(trigger.key)]")
                self.handleContentTrigger(trigger)
                return
            }
        }
    }

    /// Whether what was recorded is a content trigger. When the behavior settings
    /// carry content triggers, only they decide, and only while the content zone
    /// is wanted. Otherwise a custom event key in the journey trigger events and a
    /// view name in the journey trigger views decide, also while it is not wanted.
    private func contentTriggerMatch(_ trigger: RecordedTrigger) -> TriggerMatch? {
        let settings = core.serverConfig
        let isView = trigger.key == ReservedEventKey.view
        let viewSuffix = isView && trigger.viewEnd ? ":end" : ""

        if let lists = settings.contentTriggers {
            stateLock.lock()
            let isWanted = isZoneWanted
            stateLock.unlock()
            guard isWanted else { return nil }

            if isView, let name = trigger.viewName, lists.views.contains(name) {
                return TriggerMatch(gapKeys: ["v:" + name + viewSuffix], gapMs: Self.gapSpecificMs)
            }
            if trigger.key == ContentTriggerKey.userProperties, let properties = trigger.properties {
                let listed = properties.filter { lists.properties.contains($0) }
                if !listed.isEmpty {
                    return TriggerMatch(gapKeys: listed.map { "p:" + $0 }, gapMs: Self.gapSpecificMs)
                }
            }
            guard lists.keys.contains(trigger.key) else { return nil }
            let nonSpecific = isView || trigger.key == ContentTriggerKey.userProperties || trigger.key == ContentTriggerKey.crash
            return TriggerMatch(gapKeys: [trigger.key + viewSuffix], gapMs: nonSpecific ? Self.gapNonSpecificMs : Self.gapSpecificMs)
        }

        if isView {
            guard let name = trigger.viewName, settings.isJourneyTriggerView(name) else { return nil }
            return TriggerMatch(gapKeys: ["v:" + name + viewSuffix], gapMs: Self.gapSpecificMs)
        }
        guard trigger.customEvent, settings.isJourneyTriggerEvent(trigger.key) else { return nil }
        return TriggerMatch(gapKeys: [trigger.key], gapMs: Self.gapSpecificMs)
    }

    /// Main queue only. Starts a round when what was recorded is a content
    /// trigger, content can be shown, and the trigger is outside its gap. A
    /// trigger during a running round only makes one more round follow it.
    private func handleContentTrigger(_ trigger: RecordedTrigger) {
        guard !areTriggersHalted else { return }
        guard let match = contentTriggerMatch(trigger) else {
            rememberEarlyTrigger(trigger)
            return
        }

        stateLock.lock()
        let isExited = isZoneExited
        stateLock.unlock()
        guard !isExited, core.modules.consent.hasConsent(for: .content), !core.modules.deviceID.isTemporary else {
            logD("handleContentTrigger", "the trigger is a content trigger, but content can not be shown now, so it is not asked for, key: [\(trigger.key)]")
            return
        }

        guard claimContentTriggerGap(match) else {
            logD("handleContentTrigger", "the trigger started a round less than [\(match.gapMs / 1000)] seconds ago, key: [\(trigger.key)]")
            return
        }

        guard !isTriggerRoundRunning else {
            logD("handleContentTrigger", "the trigger matched while a round is running, one more round follows it, key: [\(trigger.key)]")
            isTriggerRoundPending = true
            return
        }

        logD("handleContentTrigger", "the trigger matched, the queued requests are sent and content is asked for, key: [\(trigger.key)]")
        startContentTriggerRound()
    }

    /// Main queue only. Keeps what was recorded before the behavior settings
    /// answer of this run arrived.
    private func rememberEarlyTrigger(_ trigger: RecordedTrigger) {
        stateLock.lock()
        let settled = behaviorSettingsSettled
        stateLock.unlock()
        guard !settled, earlyTriggers.count < Self.earlyTriggerLimit, !earlyTriggers.contains(trigger) else { return }
        earlyTriggers.append(trigger)
    }

    /// Whether a matched trigger may start a round now. When it may, the time of
    /// the round is stored, so the gap holds after a restart. Times older than the
    /// longest gap are dropped, and a time in the future is ignored.
    private func claimContentTriggerGap(_ match: TriggerMatch) -> Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let stored = core.keyValueStore.contentTriggerGaps
        func inGap(_ value: Any?, _ gap: Int64) -> Bool {
            guard let time = (value as? NSNumber)?.int64Value else { return false }
            return now >= time && now - time < gap
        }

        guard match.gapKeys.contains(where: { !inGap(stored[$0], match.gapMs) }) else { return false }

        var kept = stored.filter { inGap($0.value, Self.gapNonSpecificMs) }
        for gapKey in match.gapKeys {
            kept[gapKey] = NSNumber(value: now)
        }
        core.keyValueStore.contentTriggerGaps = kept
        return true
    }

    /// Main queue only. Moves the recorded events into the request queue, sends
    /// the queue, and asks for content once the requests queued until now are sent.
    private func startContentTriggerRound() {
        guard !areTriggersHalted else { return }
        isTriggerRoundRunning = true
        isTriggerRoundPending = false

        core.modules.events.sendEvents()

        guard let lastQueued = core.requestQueueStore.snapshot.last else {
            contentTriggerChain &+= 1
            requestTriggeredContent(chain: contentTriggerChain, attempt: 1)
            endContentTriggerRound()
            return
        }

        let remaining = Self.queuedCount(upTo: lastQueued, in: core.requestQueueStore.snapshot)
        let generation = triggerGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.queueCheckInterval) { [weak self] in
            self?.waitForTriggerQueue(lastQueued: lastQueued, previousRemaining: remaining, checksWithoutProgress: 0, generation: generation)
        }
    }

    /// How many queued requests there are up to and including the given one, 0
    /// when it is not queued any more.
    private static func queuedCount(upTo request: String, in queue: [String]) -> Int {
        guard let index = queue.lastIndex(of: request) else { return 0 }
        return index + 1
    }

    /// Main queue only. Checks every `queueCheckInterval` whether the requests
    /// queued when the round started are sent, and asks for content once they are.
    /// When none of them is sent for `queueChecks` checks in a row (a request on
    /// its way, the backoff mechanism or a failed request holds them back), or
    /// temporary device ID mode starts, the round ends without asking for content,
    /// and the content zone timer picks the content up.
    private func waitForTriggerQueue(lastQueued: String, previousRemaining: Int, checksWithoutProgress: Int, generation: UInt) {
        guard !areTriggersHalted else { return }
        guard generation == triggerGeneration else { return }

        guard !core.modules.deviceID.isTemporary else {
            logD("waitForTriggerQueue", "temporary device ID mode started, the round ends without a content request")
            endContentTriggerRound()
            return
        }

        let remaining = Self.queuedCount(upTo: lastQueued, in: core.requestQueueStore.snapshot)
        guard remaining > 0 else {
            contentTriggerChain &+= 1
            requestTriggeredContent(chain: contentTriggerChain, attempt: 1)
            endContentTriggerRound()
            return
        }

        let withoutProgress = remaining < previousRemaining ? 0 : checksWithoutProgress + 1
        guard withoutProgress < Self.queueChecks else {
            logD("waitForTriggerQueue", "the queued requests could not be sent in time, the round ends without a content request")
            endContentTriggerRound()
            return
        }

        core.network.proceedOnQueue()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.queueCheckInterval) { [weak self] in
            self?.waitForTriggerQueue(lastQueued: lastQueued, previousRemaining: remaining, checksWithoutProgress: withoutProgress, generation: generation)
        }
    }

    /// Main queue only. Sends the content request of a round. When it brings no
    /// content, it is sent again `contentRetryInterval` later, up to
    /// `contentRequests` requests, because the server may still be processing what
    /// triggered it. A newer round's content request stops the remaining ones of an
    /// older round.
    private func requestTriggeredContent(chain: UInt, attempt: Int) {
        guard !areTriggersHalted else { return }
        guard chain == contentTriggerChain else { return }

        guard !isShown() else {
            logD("requestTriggeredContent", "a content is already shown, no content request is sent")
            return
        }

        stateLock.lock()
        let isWanted = isZoneWanted
        let isExited = isZoneExited
        stateLock.unlock()
        let zoneNeeded = core.serverConfig.contentTriggers != nil
        guard !isExited, !zoneNeeded || isWanted else {
            logD("requestTriggeredContent", "the content zone is not wanted now, no content request is sent")
            return
        }

        logD("requestTriggeredContent", "content request is sent, attempt: [\(attempt)], maxAttempts: [\(Self.contentRequests)]")
        fetchContents(contentID: nil) { [weak self] in
            guard let self, attempt < Self.contentRequests else { return }
            _ = self
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.contentRetryInterval) { [weak self] in
                self?.requestTriggeredContent(chain: chain, attempt: attempt + 1)
            }
        }
    }

    /// Main queue only. Ends the queue part of a round, and starts the round a
    /// trigger during it asked for.
    private func endContentTriggerRound() {
        isTriggerRoundRunning = false
        guard isTriggerRoundPending else { return }
        isTriggerRoundPending = false
        let generation = triggerGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.triggerGeneration else { return }
            self.startContentTriggerRound()
        }
    }

    /// Restarts a content zone that is entered, so a changed zone interval applies to it.
    func restartZoneIfEntered() {
        stateLock.lock()
        let isEntered = isZoneEntered
        stateLock.unlock()
        guard isEntered else { return }
        logD("restartZoneIfEntered", "the zone timer interval changed, the content zone is restarted")
        clearContentState()
        enterContentZone()
    }

    /// Whether the instance was halted, after which no content trigger acts.
    private var areTriggersHalted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return triggersHalted
    }

    /// Whether content can be fetched and shown in this run: the platform has web
    /// views, the application did not turn them off, and the SDK is not in offline
    /// mode. Logs why not.
    private func isContentAvailable(_ function: String) -> Bool {
        #if os(iOS) || os(visionOS) || os(macOS)
        guard !core.config.disableWebView else {
            logW(function, "the SDK's web views are turned off by disableWebView, the call is ignored")
            return false
        }
        guard !core.modules.deviceID.isTemporary else {
            logD(function, "the SDK is in temporary device ID mode, the call is ignored")
            return false
        }
        return true
        #else
        logD(function, "content needs a web view, which this platform does not have, the call is ignored")
        return false
        #endif
    }

    // MARK: - State

    /// Clears polling state without touching what is on screen.
    func clearContentState() {
        invalidateTimers()

        stateLock.lock()
        isFetchInFlight = false
        isZoneEntered = false
        // Anything the previous visit scheduled is now stale.
        zoneGeneration &+= 1
        stateLock.unlock()
    }

    /// Tears down both polling timers on the main thread.
    ///
    /// Timers belong to the main run loop, and `invalidate` has to be sent from
    /// the thread that scheduled them or the timer may keep firing. Both callers
    /// can be reached off the main thread: `clearContentState` from a queue flush
    /// runnable, which runs on a URLSession completion thread, and
    /// `enterContentZone` from wherever the host application calls it.
    private func invalidateTimers() {
        let invalidate = { [weak self] in
            guard let self else { return }
            self.zoneTimer?.invalidate()
            self.zoneTimer = nil
            self.reentryTimer?.invalidate()
            self.reentryTimer = nil
        }

        onMainThread(invalidate)
    }

    /// Whether the zone visit that scheduled some work is still the current one.
    private func isCurrentGeneration(_ generation: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isZoneEntered && zoneGeneration == generation
    }

    private func isShown() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isContentShown
    }

    /// Claims the single presentation slot, returning whether it was free.
    private func tryBeginPresentation() -> (claimed: Bool, sequence: UInt) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isContentShown else { return (false, presentationSequence) }
        isContentShown = true
        presentationSequence &+= 1
        return (true, presentationSequence)
    }

    private func endPresentation() {
        stateLock.lock()
        isContentShown = false
        stateLock.unlock()
    }

    private func currentSequence() -> UInt {
        stateLock.lock()
        defer { stateLock.unlock() }
        return presentationSequence
    }

    /// Dismisses displayed content and frees the slot in one main-queue turn.
    ///
    /// The slot is released as part of the teardown rather than before it, so a
    /// fetch cannot present a second web view mid-dismissal.
    private func closeShownContent() {
        #if os(iOS) || os(visionOS) || os(macOS)
        if Thread.isMainThread {
            tearDownShownContent()
            return
        }

        let requestedSequence = currentSequence()
        // The core is held until the content is torn down: from a halt off the
        // main thread this runs after the core was released, and without it the
        // module would be gone and the content left on screen.
        DispatchQueue.main.async { [weak self, core] in
            defer { withExtendedLifetime(core) {} }
            guard let self else { return }
            guard self.currentSequence() == requestedSequence else {
                self.logD("closeShownContent", "a newer presentation superseded this close request, skipping")
                return
            }
            self.tearDownShownContent()
        }
        #endif
    }

    #if os(iOS) || os(visionOS) || os(macOS)
    private func tearDownShownContent() {
        if let manager = webViewManager {
            logI("tearDownShownContent", "closing the currently shown content")
            // Cleared first so the dismiss block does not re-arm the zone for a
            // close the SDK itself initiated.
            webViewManager = nil
            manager.close()
        }
        // Released even with nothing retained, so a stranded claim cannot dead-end
        // later enters.
        endPresentation()
    }
    #endif

    // MARK: - Fetching

    private func fetchContents() {
        fetchContents(contentID: nil, failure: nil)
    }

    /// Whether a content fetch may start now. When it may, the fetch is marked as
    /// in flight, so a second one waits for its answer.
    private func claimFetch() -> Bool {
        guard core.modules.consent.hasConsent(for: .content) else {
            logV("fetchContents", "no consent given for content, skipping the content fetch")
            return false
        }

        guard core.serverConfig.networkingEnabled else {
            logD("fetchContents", "networking is disabled by the server config, skipping the content fetch")
            return false
        }

        guard !core.modules.deviceID.isTemporary else {
            logD("fetchContents", "content can not be fetched while in temporary device ID mode")
            return false
        }

        guard !isShown() else {
            logD("fetchContents", "a content is already shown, skipping the content fetch")
            return false
        }

        stateLock.lock()
        if isFetchInFlight {
            stateLock.unlock()
            logD("fetchContents", "a content fetch is already in flight, skipping this one")
            return false
        }
        isFetchInFlight = true
        stateLock.unlock()
        return true
    }

    /// Fetches content, or a preview of one content. A fetch that does not start
    /// reports through `failure` like one that fails, so a journey retry series
    /// always comes to an end.
    private func fetchContents(contentID: String?, failure: (() -> Void)?) {
        guard claimFetch() else {
            failure?()
            return
        }

        logD("fetchContents", "fetching the content details, isPreview: [\(contentID != nil)]")

        let request = fetchRequest(contentID: contentID)

        core.network.instantTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            defer {
                self.stateLock.lock()
                self.isFetchInFlight = false
                self.stateLock.unlock()
            }

            if let error {
                let nsError = error as NSError
                self.logD("fetchContents", "fetching the content details failed, it will be retried on the next content zone tick, error: [\(nsError.localizedDescription)], domain: [\(nsError.domain)], code: [\(nsError.code)]")
                failure?()
                return
            }

            guard let payload = CountlyJSON.object(from: data, logger: self.log) as? [String: Any] else {
                self.logD("fetchContents", "failed to parse the content details JSON or the response was empty, it will be retried on the next content zone tick, responseSize: [\(data?.count ?? 0)]")
                failure?()
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.logD("fetchContents", "the content details response parsed, statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)]")
            self.logD("fetchContents", "content details response detail, response: [\(payload)]")
            self.logV("fetchContents", "content details response URL detail, url: [\(response?.url?.absoluteString ?? "")]")

            guard (200...299).contains(statusCode) else {
                self.logD("fetchContents", "the content details request was refused, it will be retried on the next content zone tick, statusCode: [\(statusCode)]")
                failure?()
                return
            }

            // Valid only with both: without a placement there is nowhere to put the page.
            guard let html = payload["html"] as? String, let placement = payload["geo"] as? [String: Any] else {
                self.logD("fetchContents", "the content details response carries no content, result: [\(payload["result"] as? String ?? "")]")
                failure?()
                return
            }

            self.logD("fetchContents", "the content details response carries a content, will present it")
            self.showContent(urlString: html, placement: placement)
        }?.resume()
    }

    private func fetchRequest(contentID: String?) -> URLRequest {
        var queryString = core.network.builder.queryEssentials()
        queryString += "&\(QS.method)=\(Self.fetchMethod)"
        queryString += "&resolution=\(resolutionJSON().urlEscaped)"

        // The server matches content on the language alone, not the full locale.
        let language = DeviceMetrics.locale.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? DeviceMetrics.locale
        queryString += "&la=\(language)"

        if let deviceType = DeviceMetrics.deviceType {
            queryString += "&dt=\(deviceType)"
        }

        if let contentID {
            queryString += "&content_id=\(contentID.urlEscaped)&preview=true"
        }

        queryString = core.network.builder.finishImmediateRequest(queryString)
        let request = core.network.instantRequest(queryString: queryString, path: Self.endpoint)

        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        logD("fetchRequest", "content fetch request built, method: [\(request.httpMethod ?? "GET")], path: [\(request.url?.path ?? "")], bodySize: [\(body.count)]")
        logV("fetchRequest", "content fetch request detail, url: [\(request.url?.absoluteString ?? "")], body: [\(body)]")

        return request
    }

    /// The screen dimensions the server places content against.
    ///
    /// Both orientations are reported so the server can prepare a layout for each,
    /// whichever the device is in now.
    private func resolutionJSON() -> String {
        #if os(iOS) || os(visionOS) || os(macOS)
        let size = windowSize()
        let isLandscape = size.width > size.height
        let shortSide = isLandscape ? size.height : size.width
        let longSide = isLandscape ? size.width : size.height

        let payload: [String: Any] = [
            "portrait": ["height": longSide, "width": shortSide],
            "landscape": ["height": shortSide, "width": longSide],
        ]

        // The serialized form rather than the dictionary: this is what goes on the
        // wire, and a printed dictionary shows its numbers as `874.0` and its keys
        // in whatever order the hash landed in.
        let json = CountlyJSON.string(from: payload, logger: log) ?? "{}"

        logD("resolutionJSON", "resolution reported to the server, portraitWidth: [\(shortSide.logValue)], portraitHeight: [\(longSide.logValue)], landscapeWidth: [\(longSide.logValue)], landscapeHeight: [\(shortSide.logValue)], isLandscape: [\(isLandscape)]")
        logD("resolutionJSON", "resolution payload detail, resolution: [\(json)]")
        return json
        #else
        return "{}"
        #endif
    }

    #if os(iOS) || os(visionOS) || os(macOS)
    /// The area a content page may occupy, with any hardware cutout taken out.
    ///
    /// The same rule places what comes back, so the page is laid out at the size it
    /// is actually going to be given. See `ContentGeometry`.
    private func windowSize() -> CGSize {
        let displayOption = core.config.content.webViewDisplayOption
        let size = ContentGeometry.windowSize(displayOption: displayOption,
                                              withinApp: core.config.content.showWidgetsWithinApp)

        // Every part of the sum, not just its result. A page laid out against the
        // wrong size is the failure this path causes, and the result on its own
        // does not say whether the window or the insets were what went wrong.
        logD("windowSize", "content area resolved, windowBounds: [\(ContentGeometry.windowBounds.logValue)], safeAreaInsets: [\(ContentGeometry.safeAreaDescription)], displayOption: [\(displayOption)], contentSize: [\(size.logValue)]")
        return size
    }
    #endif

    // MARK: - Presentation

    /// Adds the `origin` the page's own message listener checks against.
    ///
    /// The server's content URL does not carry one. A content block never reads
    /// it, but a survey served through the content queue does: its listener
    /// accepts the host's `resize` message only when `event.origin` matches this
    /// parameter, and silently drops it otherwise. Without it a hosted survey is
    /// never told the surface changed and never re-anchors itself.
    ///
    /// The value is the page's own origin, because that is what `event.origin`
    /// reports for a message the page posts to itself through the SDK's bridge.
    static func appendingOrigin(to url: URL) -> URL {
        // `URLComponents` is read only here. Writing the query back through it
        // re-encodes every existing value, and the server's content URL is taken
        // as given, so the parameter is appended to the string the way the theme
        // is, leaving what was already there byte for byte.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host,
              !(components.queryItems ?? []).contains(where: { $0.name == "origin" }) else { return url }

        let port = components.port.map { ":\($0)" } ?? ""
        let origin = "\(scheme)://\(host)\(port)".urlEscaped
        let separator = url.query == nil ? "?" : "&"
        return URL(string: "\(url.absoluteString)\(separator)origin=\(origin)") ?? url
    }

    private func showContent(urlString: String, placement: [String: Any]) {
        #if os(iOS) || os(visionOS) || os(macOS)
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            logE("showContent", "the content URL is not valid, urlLength: [\(urlString.count)]")
            logV("showContent", "invalid content URL detail, url: [\(urlString)]")
            return
        }

        // Claimed before hopping to main, so a racing fetch cannot also decide to
        // present.
        let claim = tryBeginPresentation()
        guard claim.claimed else {
            logD("showContent", "a content is already shown, skipping this duplicate presentation")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // The zone can be exited while this is in flight, which releases the
            // claim. Content the application has already exited must not appear.
            guard self.isShown(), self.currentSequence() == claim.sequence else {
                self.logD("showContent", "the presentation claim was released or superseded before presenting, skipping")
                return
            }

            let windowSize = self.windowSize()
            let isLandscape = self.core.config.content.disableRotation ? false : windowSize.width > windowSize.height
            let coordinates = (placement[isLandscape ? "l" : "p"] as? [String: Any]) ?? [:]
            let frame = CGRect(contentGeometry: coordinates, container: windowSize)

            // The theme is resolved here, on the main thread, where reading the
            // trait collection is safe.
            let themed = DeviceMetrics.urlStringByAppendingThemeMode(urlString)
            let themedURL = Self.appendingOrigin(to: URL(string: themed) ?? url)

            self.logI("showContent", "showing a content, host: [\(themedURL.host ?? "")], path: [\(themedURL.path)], frame: [\(frame.logValue)], isLandscape: [\(isLandscape)], rotationDisabled: [\(self.core.config.content.disableRotation)]")
            self.logD("showContent", "shown content placement detail, orientationKey: [\(isLandscape ? "l" : "p")], x: [\(frame.origin.x.logValue)], y: [\(frame.origin.y.logValue)], width: [\(frame.width.logValue)], height: [\(frame.height.logValue)], windowSize: [\(windowSize.logValue)]")
            self.logD("showContent", "shown content placement payload detail, placementCoordinates: [\(placement)]")
            self.logV("showContent", "shown content URL detail, url: [\(themedURL.absoluteString)]")

            let manager = WebViewManager(core: self.core)
            self.webViewManager = manager

            manager.present(url: themedURL,
                            frame: frame,
                            placement: placement,
                            appear: { [weak self] in
                                self?.logI("showContent", "the content web view appeared on screen")
                            },
                            dismiss: { [weak self, weak manager] in
                                guard let self else { return }
                                let isCurrent = self.webViewManager === manager
                                self.logI("showContent", "the content web view was dismissed, isCurrentContent: [\(isCurrent)]")

                                // Only the current content's dismissal may touch
                                // shared zone state: this block can belong to a
                                // web view that was already superseded.
                                // The next fetch waits two intervals, so content does not follow content.
                                if isCurrent {
                                    self.webViewManager = nil
                                    self.endPresentation()
                                    self.reentryTimer = Timer.scheduledTimer(
                                        withTimeInterval: TimeInterval(2 * self.core.config.content.zoneTimerInterval),
                                        repeats: false) { [weak self] _ in
                                            self?.enterContentZone()
                                        }
                                }

                                // Reported whatever the state: this web view
                                // really did close.
                                self.core.config.content.globalContentCallback?(.closed, [:])
                            })

            self.clearContentState()
        }
        #endif
    }

    // MARK: - Lifecycle

    override func didInit() {
        // The server can ask for the zone to be entered without the application
        // doing anything.
        enterForServerIfNeeded(from: "didInit")
    }

    override func halt(clearStorage: Bool) {
        clearContentState()
        closeShownContent()
        stateLock.lock()
        isRefreshPending = false
        triggersHalted = true
        stateLock.unlock()
    }
}
