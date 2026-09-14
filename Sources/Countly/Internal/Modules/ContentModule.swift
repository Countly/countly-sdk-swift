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
    private static let journeyFetchAttempts = 3

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
    private var isJourneyRetrying = false

    /// Bumped on every enter and every clear, so work scheduled by one visit to
    /// the zone cannot land after a later exit. The initial fetch is delayed by up
    /// to `contentInitialDelay` seconds, which is a long time for an application to
    /// change its mind in.
    private var zoneGeneration: UInt = 0

    #if os(iOS) || os(visionOS) || os(macOS)
    private var webViewManager: WebViewManager?
    #endif

    // MARK: - Zone lifecycle

    /// Starts polling for content.
    func enterContentZone() {
        guard !isShown() else {
            logD("enterContentZone", "a content is already shown, skipping this enter")
            return
        }

        invalidateTimers()

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
        zoneGeneration &+= 1
        let generation = zoneGeneration
        stateLock.unlock()

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

        stateLock.lock()
        if isJourneyRetrying {
            stateLock.unlock()
            logD("refreshContentZoneForJourneyTrigger", "a journey content fetch is already retrying, skipping this trigger")
            return
        }
        isJourneyRetrying = true
        stateLock.unlock()

        clearContentState()
        fetchForJourney(attempt: 1)
    }

    private func endJourneyRetry() {
        stateLock.lock()
        isJourneyRetrying = false
        stateLock.unlock()
    }

    private func fetchForJourney(attempt: Int) {
        logD("fetchForJourney", "journey content fetch starting, attempt: [\(attempt)], maxAttempts: [\(Self.journeyFetchAttempts)]")

        fetchContents(contentID: nil) { [weak self] in
            guard let self else { return }

            // Both hops capture `self` weakly again. The `guard let self` above
            // makes it a strong local, and a nested block that captured that local
            // would keep this module alive past the core it holds `unowned`: the
            // retry is a second away, and an instance halted in between would be
            // read after it was released.
            if attempt < Self.journeyFetchAttempts {
                self.logD("fetchForJourney", "retrying the journey content fetch in one second, nextAttempt: [\(attempt + 1)]")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.fetchForJourney(attempt: attempt + 1)
                }
            } else {
                self.logD("fetchForJourney", "the journey content fetch exhausted every attempt, re-entering the content zone")
                self.endJourneyRetry()
                DispatchQueue.main.async { [weak self] in self?.enterContentZone() }
            }
        }
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
        isJourneyRetrying = false
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

            self.logD("fetchContents", "the content details response parsed, statusCode: [\((response as? HTTPURLResponse)?.statusCode ?? 0)], responseSize: [\(data?.count ?? 0)]")
            self.logD("fetchContents", "content details response detail, response: [\(payload)]")
            self.logV("fetchContents", "content details response URL detail, url: [\(response?.url?.absoluteString ?? "")]")

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
        let request = core.network.instantRequest(queryString: queryString, path: Self.endpoint)

        // A content fetch the server answers with nothing is usually a question
        // about what was asked for, and which half of the request carries the query
        // depends on its length and on `alwaysUsePOST`, so both are reported.
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
