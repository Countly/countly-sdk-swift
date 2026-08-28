//
//  ContentModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if os(iOS) || os(visionOS)
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
    private static let journeyFetchAttempts = 3

    /// How long after launch content is allowed to appear, so it does not land on
    /// top of the application's own first screen.
    private var contentInitialDelay = 4

    /// Tags the current zone was entered with.

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

    #if os(iOS) || os(visionOS)
    private var webViewManager: WebViewManager?
    #endif

    // MARK: - Zone lifecycle

    /// Starts polling for content.
    func enterContentZone() {
        guard !isShown() else {
            logD("enterContentZone", "a content is already shown, skipping this enter")
            return
        }

        reentryTimer?.invalidate()
        reentryTimer = nil

        guard core.modules.consent.hasConsent(for: .content) else {
            logV("enterContentZone", "no consent given for content, skipping the content zone enter")
            return
        }

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
        stateLock.unlock()


        // The first fetch is held back on a cold launch so content does not land
        // on top of the application's own first screen.
        let delay = core.clock.timeSinceLaunch() < contentInitialDelay ? contentInitialDelay : 0
        let interval = TimeInterval(core.config.content.zoneTimerInterval)

        logD("enterContentZone", "content zone entered, initialDelay: [\(delay)], zoneTimerInterval: [\(interval)]")

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self else { return }
            self.fetchContents()
            self.zoneTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.fetchContents()
            }
        }
    }

    /// Stops polling and takes any displayed content off screen.
    func exitContentZone() {
        logI("exitContentZone", "exiting the content zone and taking the content off screen")
        clearContentState()
        closeShownContent()
    }


    /// Fetches one content by ID without starting the polling loop.
    func previewContent(_ contentID: String) {
        logD("previewContent", "fetching a content for preview, contentId: [\(contentID)]")
        fetchContents(contentID: contentID, failure: nil)
    }

    /// Asks the server again as soon as everything queued has been accepted.
    ///
    /// Refreshing before the queue drains would ask about a user state the server
    /// has not seen yet, so the refresh rides on the flush instead.
    func refreshContentZone() {
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

    /// Refresh path used by journey triggers, which retries a few times because
    /// the server may still be computing the journey's next step.
    func refreshContentZoneForJourneyTrigger() {
        guard core.serverConfig.refreshContentZoneEnabled else {
            logD("refreshContentZoneForJourneyTrigger", "the content zone refresh is disabled by the server config, skipping the journey content refresh")
            return
        }

        guard !isShown() else {
            logD("refreshContentZoneForJourneyTrigger", "a content is already shown, skipping the journey content refresh")
            return
        }

        clearContentState()
        fetchForJourney(attempt: 1)
    }

    private func fetchForJourney(attempt: Int) {
        logD("fetchForJourney", "journey content fetch starting, attempt: [\(attempt)], maxAttempts: [\(Self.journeyFetchAttempts)]")

        fetchContents(contentID: nil) { [weak self] in
            guard let self else { return }

            if attempt < Self.journeyFetchAttempts {
                logD("fetchForJourney", "retrying the journey content fetch in one second, nextAttempt: [\(attempt + 1)]")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.fetchForJourney(attempt: attempt + 1)
                }
            } else {
                logD("fetchForJourney", "the journey content fetch exhausted every attempt, re-entering the content zone")
                DispatchQueue.main.async { self.enterContentZone() }
            }
        }
    }

    // MARK: - State

    /// Clears polling state without touching what is on screen.
    func clearContentState() {
        // Timers belong to the main run loop, and `invalidate` has to be sent from
        // the thread that scheduled them. This is reached from a queue flush
        // runnable, which runs on a URLSession completion thread.
        let invalidate = { [weak self] in
            guard let self else { return }
            self.zoneTimer?.invalidate()
            self.zoneTimer = nil
            self.reentryTimer?.invalidate()
            self.reentryTimer = nil
        }

        if Thread.isMainThread {
            invalidate()
        } else {
            DispatchQueue.main.async(execute: invalidate)
        }

        stateLock.lock()
        isFetchInFlight = false
        isZoneEntered = false
        stateLock.unlock()
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
        #if os(iOS) || os(visionOS)
        if Thread.isMainThread {
            tearDownShownContent()
            return
        }

        let requestedSequence = currentSequence()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.currentSequence() == requestedSequence else {
                self.logD("closeShownContent", "a newer presentation superseded this close request, skipping")
                return
            }
            self.tearDownShownContent()
        }
        #endif
    }

    #if os(iOS) || os(visionOS)
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

    private func fetchContents(contentID: String?, failure: (() -> Void)?) {
        guard core.modules.consent.hasConsent(for: .content) else {
            logV("fetchContents", "no consent given for content, skipping the content fetch")
            return
        }

        guard core.serverConfig.networkingEnabled else {
            logD("fetchContents", "networking is disabled by the server config, skipping the content fetch")
            return
        }

        guard !core.modules.deviceID.isTemporary else {
            logD("fetchContents", "content can not be fetched while in temporary device ID mode")
            return
        }

        guard !isShown() else {
            logD("fetchContents", "a content is already shown, skipping the content fetch")
            return
        }

        stateLock.lock()
        if isFetchInFlight {
            stateLock.unlock()
            logD("fetchContents", "a content fetch is already in flight, skipping this one")
            return
        }
        isFetchInFlight = true
        stateLock.unlock()

        logD("fetchContents", "fetching the content details, isPreview: [\(contentID != nil)]")

        let request = fetchRequest(contentID: contentID)

        core.network.instantSession().dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            defer {
                self.stateLock.lock()
                self.isFetchInFlight = false
                self.stateLock.unlock()
            }

            if let error {
                self.logD("fetchContents", "fetching the content details failed, it will be retried on the next content zone tick, error: [\(error.localizedDescription)]")
                failure?()
                return
            }

            guard let payload = CountlyJSON.object(from: data, logger: self.log) as? [String: Any] else {
                self.logD("fetchContents", "failed to parse the content details JSON or the response was empty, it will be retried on the next content zone tick")
                failure?()
                return
            }

            self.logV("fetchContents", "the content details response parsed, url: [\(response?.url?.absoluteString ?? "")], jsonResponse: [\(payload)]")

            guard let html = payload["html"] as? String else {
                self.logD("fetchContents", "the content details response carries no content")
                failure?()
                return
            }

            self.logD("fetchContents", "the content details response carries a content, will present it")
            self.showContent(urlString: html, placement: payload["geo"] as? [String: Any] ?? [:])
        }.resume()
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

        queryString = core.network.builder.appendChecksum(queryString)
        return core.network.instantRequest(queryString: queryString, path: Self.endpoint)
    }

    /// The screen dimensions the server places content against.
    ///
    /// Both orientations are reported so the server can prepare a layout for each,
    /// whichever the device is in now.
    private func resolutionJSON() -> String {
        #if os(iOS) || os(visionOS)
        let size = windowSize()
        let isLandscape = size.width > size.height
        let shortSide = isLandscape ? size.height : size.width
        let longSide = isLandscape ? size.width : size.height

        let payload: [String: Any] = [
            "portrait": ["height": longSide, "width": shortSide],
            "landscape": ["height": shortSide, "width": longSide],
        ]

        logD("resolutionJSON", "resolution reported to the server, portraitWidth: [\(shortSide)], portraitHeight: [\(longSide)], isLandscape: [\(isLandscape)]")
        return CountlyJSON.string(from: payload, logger: log) ?? "{}"
        #else
        return "{}"
        #endif
    }

    #if os(iOS) || os(visionOS)
    private func windowSize() -> CGSize {
        ScreenReader.screenBounds.size
    }
    #endif

    // MARK: - Presentation

    private func showContent(urlString: String, placement: [String: Any]) {
        #if os(iOS) || os(visionOS)
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            logE("showContent", "the content URL is not valid, urlLength: [\(urlString.count)]")
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

            let isLandscape = self.core.config.content.disableRotation ? false : self.windowSize().width > self.windowSize().height
            let coordinates = (placement[isLandscape ? "l" : "p"] as? [String: Any]) ?? [:]

            let frame = CGRect(
                x: (coordinates["x"] as? NSNumber)?.doubleValue ?? 0,
                y: (coordinates["y"] as? NSNumber)?.doubleValue ?? 0,
                width: (coordinates["w"] as? NSNumber)?.doubleValue ?? Double(self.windowSize().width),
                height: (coordinates["h"] as? NSNumber)?.doubleValue ?? Double(self.windowSize().height))

            // The theme is resolved here, on the main thread, where reading the
            // trait collection is safe.
            let themedURL = URL(string: DeviceMetrics.urlStringByAppendingThemeMode(urlString)) ?? url

            self.logI("showContent", "showing a content, host: [\(themedURL.host ?? "")], path: [\(themedURL.path)], isLandscape: [\(isLandscape)]")

            let manager = WebViewManager(core: self.core)
            self.webViewManager = manager

            manager.present(url: themedURL,
                            frame: frame,
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
                                if isCurrent {
                                    self.webViewManager = nil
                                    self.endPresentation()
                                    self.reentryTimer = Timer.scheduledTimer(
                                        withTimeInterval: TimeInterval(self.core.config.content.zoneTimerInterval),
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
        if core.serverConfig.enterContentZone {
            enterContentZone()
        }
    }

    override func halt(clearStorage: Bool) {
        clearContentState()
        closeShownContent()
        stateLock.lock()
        isRefreshPending = false
        stateLock.unlock()
    }
}
