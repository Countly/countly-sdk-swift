//
//  FeedbackModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Presents surveys, NPS and rating widgets, and records their answers.
///
/// The widget itself is a web page the server renders. The SDK's job is to know
/// which widgets exist, put the right one on screen, and turn what the user
/// answered into a reserved event.
final class FeedbackModule: ModuleBase {

    override class var moduleName: String { "Feedback" }

    /// Keys of the widget request and result payloads.
    private enum Key {
        static let platform = "platform"
        static let appVersion = "app_version"
        static let rating = "rating"
        static let widgetID = "widget_id"

        /// The origin the page compares an incoming `resize` message against.
        static let origin = "origin"
        static let feedback = "feedback"
        static let email = "email"
        static let comment = "comment"
        static let contactMe = "contactMe"
        static let closed = "closed"
        static let shown = "shown"
    }

    /// Presenters of widgets currently on screen.
    ///
    /// A widget is dismissed by the page rather than by the SDK, so its presenter
    /// has to outlive the call that created it. Entries are dropped in the
    /// dismissal callback. Internal so the suite can hand the module a presenter
    /// without putting a window on screen.
    var presentedWidgetManagers: [AnyObject] = []

    /// One line per widget, enough to tell why a given one was or was not picked.
    /// Widget names and tags are authored in the dashboard, not by the end user.
    private static func describe(_ widgets: [CountlyFeedbackWidget]) -> String {
        widgets.map { "\($0.id)/\($0.type.wireName)/\($0.name)/tags=\($0.tags.joined(separator: "+"))" }
            .joined(separator: ", ")
    }

    // MARK: - Widget list

    /// Fetches the widgets the server offers for this user.
    ///
    /// The completion is called in every case: with the list and no error, or
    /// with an empty list and the error, also when the SDK is not allowed to ask.
    func getAvailableFeedbackWidgets(completion: @escaping ([CountlyFeedbackWidget]?, Error?) -> Void) {
        logI("getAvailableFeedbackWidgets", "feedback widget list fetch requested")

        guard core.serverConfig.networkingEnabled else {
            logD("getAvailableFeedbackWidgets", "feedback widget list fetch is dropped, networking is disabled by server config")
            completion([], CountlyError.networkingDisabled.asNSError)
            return
        }

        guard core.modules.consent.hasConsent(for: .feedback) else {
            logD("getAvailableFeedbackWidgets", "no feedback consent given, feedback widget list is not fetched")
            completion([], CountlyError.feedbackConsentNotGiven.asNSError)
            return
        }

        guard !core.modules.deviceID.isTemporary else {
            logD("getAvailableFeedbackWidgets", "feedback widget list fetch is dropped, device ID is temporary")
            completion([], CountlyError.feedbackWidgetNotAvailable.asNSError)
            return
        }

        let request = widgetListRequest()
        logD("getAvailableFeedbackWidgets", "feedback widget list request is started, path: [\(request.url?.path ?? "")]")

        let task = core.network.instantTask(with: request) { [weak self] data, response, error in
            // The caller is answered even once a halt has released the module.
            guard let self else {
                DispatchQueue.main.async { completion([], error ?? CountlyError.feedbacksGeneralAPIError.asNSError) }
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil,
                  statusCode == 200,
                  let payload = CountlyJSON.object(from: data, logger: self.log) as? [String: Any] else {
                let nsError = error as NSError?
                self.logD("getAvailableFeedbackWidgets", "feedback widget list fetch failed, statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)], error: [\(nsError?.localizedDescription ?? "")], domain: [\(nsError?.domain ?? "")], code: [\(nsError?.code ?? 0)]")
                DispatchQueue.main.async {
                    completion([], error ?? CountlyError.feedbacksGeneralAPIError.asNSError)
                }
                return
            }

            guard let rawWidgets = payload["result"] as? [[String: Any]] else {
                self.logW("getAvailableFeedbackWidgets", "feedback widget list response has no result field, ignoring the response")
                self.logD("getAvailableFeedbackWidgets", "widget list response shape detail, responseSize: [\(data?.count ?? 0)], responseFields: [\(payload.keys.sorted().joined(separator: ", "))]")
                DispatchQueue.main.async { completion([], CountlyError.feedbacksGeneralAPIError.asNSError) }
                return
            }

            let widgets = rawWidgets.compactMap { CountlyFeedbackWidget(dictionary: $0, module: self) }
            self.logI("getAvailableFeedbackWidgets", "feedback widget list fetched, widgetCount: [\(widgets.count)]")
            self.logD("getAvailableFeedbackWidgets", "available feedback widget detail, widgets: [\(Self.describe(widgets))]")

            // A widget with no id, or one of a type this SDK version does not
            // know, is dropped by the model initialiser and would otherwise just
            // be missing from the list with no explanation.
            if widgets.count != rawWidgets.count {
                self.logD("getAvailableFeedbackWidgets", "some widget entries could not be read and were dropped from the list, receivedWidgetCount: [\(rawWidgets.count)], usableWidgetCount: [\(widgets.count)]")
            }

            DispatchQueue.main.async { completion(widgets, nil) }
        }
        guard let task else {
            completion([], CountlyError.feedbacksGeneralAPIError.asNSError)
            return
        }
        task.resume()
    }

    private func widgetListRequest() -> URLRequest {
        var queryString = core.network.builder.queryEssentials()
        queryString += "&\(QS.method)=\(Key.feedback)"
        queryString = core.network.builder.finishImmediateRequest(queryString)

        return core.network.instantRequest(queryString: queryString, path: Endpoint.output + Endpoint.sdk)
    }

    // MARK: - Presentation

    /// Presents the first widget of a type, or, when `nameIDOrTag` is given, the
    /// widget whose ID matches it, else the one whose name does, else the first
    /// one tagged with it. A given value that matches nothing shows nothing: the
    /// SDK never falls back to another widget. The callback gets `.failed` when
    /// nothing is shown.
    func present(type: FeedbackWidgetType, nameIDOrTag: String?, callback: WidgetCallback?) {
        logI("present", "presenting a widget by type is requested, widgetType: [\(type.wireName)], nameIDorTag: [\(nameIDOrTag ?? "")]")

        getAvailableFeedbackWidgets { [weak self] widgets, error in
            guard let self else {
                callback?(.failed)
                return
            }

            if let error {
                self.logD("present", "widget list could not be retrieved while resolving a widget to present, widgetType: [\(type.wireName)], error: [\(error.localizedDescription)]")
                callback?(.failed)
                return
            }

            let candidates = (widgets ?? []).filter { $0.type == type }
            self.logD("present", "widget list filtered by type, widgetType: [\(type.wireName)], matchingWidgetCount: [\(candidates.count)], availableWidgetCount: [\(widgets?.count ?? 0)]")

            guard let widget = Self.widget(in: candidates, matching: nameIDOrTag) else {
                self.logW("present", "no feedback widget matches, nothing is shown, widgetType: [\(type.wireName)], nameIDorTag: [\(nameIDOrTag ?? "")]")
                callback?(.failed)
                return
            }

            widget.present(callback: callback)
        }
    }

    /// The widget `nameIDOrTag` names among `candidates`: the one with that ID,
    /// else the one with that name, else the first one with that tag. Without a
    /// value, the first candidate. `nil` when nothing matches.
    static func widget(in candidates: [CountlyFeedbackWidget], matching nameIDOrTag: String?) -> CountlyFeedbackWidget? {
        guard let nameIDOrTag, !nameIDOrTag.isEmpty else { return candidates.first }
        return candidates.first { $0.id == nameIDOrTag }
            ?? candidates.first { $0.name == nameIDOrTag }
            ?? candidates.first { $0.tags.contains(nameIDOrTag) }
    }

    /// Puts one widget on screen. The callback gets `.appeared` once it is shown,
    /// `.closed` when it is closed and `.failed` when it could not be shown.
    func present(widget: CountlyFeedbackWidget, callback: WidgetCallback?) {
        logI("present", "widget presentation requested, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")

        guard core.modules.consent.hasConsent(for: .feedback) else {
            logD("present", "no feedback consent given, widget will not be presented")
            callback?(.failed)
            return
        }

        guard !core.config.disableWebView else {
            logW("present", "the SDK's web views are turned off by disableWebView, the widget will not be presented, widgetID: [\(widget.id)]")
            callback?(.failed)
            return
        }

        guard !core.modules.deviceID.isTemporary else {
            logD("present", "the widget will not be presented in temporary device ID mode, widgetID: [\(widget.id)]")
            callback?(.failed)
            return
        }

        // The widget page is loaded from the server, which networking off forbids.
        guard core.serverConfig.networkingEnabled else {
            logD("present", "networking is disabled by the server config, the widget will not be presented, widgetID: [\(widget.id)]")
            callback?(.failed)
            return
        }

        #if os(iOS) || os(visionOS) || os(macOS)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Built on the main thread: the URL carries the resolved theme, and
            // resolving it reads interface state that is only safe to touch there.
            // Read here rather than inside the builder so the URL carries the same
            // surface the overlay is about to be given.
            let surface = ContentGeometry.windowSize(
                displayOption: self.core.config.content.webViewDisplayOption,
                withinApp: self.core.config.content.showWidgetsWithinApp)
            let url = self.widgetURL(for: widget, surface: surface)

            // Retained for the lifetime of the presentation. Nothing else holds
            // it: the web view's navigation delegate is weak, so without this the
            // manager deallocates before the page finishes loading.
            let manager = WebViewManager(core: self.core)
            self.presentedWidgetManagers.append(manager)

            // A widget that never appeared, because its page failed to load or
            // did not load in time, was not closed by the user: a "closed" event
            // for it could hide the widget from that user for good.
            var hasAppeared = false

            // `self` is captured weakly in both blocks. The module holds the
            // manager, the manager holds the blocks, and a strong `self` there
            // would close the cycle and leak the web view, the overlay window and
            // the module itself for the life of the process.
            manager.present(url: url,
                            widgetType: widget.type,
                            widgetPosition: widget.position,
                            appear: { [weak self] in
                                hasAppeared = true
                                self?.logI("present", "widget shown, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")
                                callback?(.appeared)
                            },
                            dismiss: { [weak self, weak manager] in
                                callback?(hasAppeared ? .closed : .failed)
                                guard let self else { return }
                                self.presentedWidgetManagers.removeAll { $0 === manager }
                                guard hasAppeared else {
                                    self.logD("present", "the widget is taken down without having been shown, no closed event is recorded, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")
                                    return
                                }
                                self.logI("present", "widget dismissed, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")
                                self.recordDismissal(for: widget)
                            },
                            refused: { [weak self, weak manager] in
                                // Never shown, so nothing is recorded: a dismissal would count as an answer the user never gave.
                                callback?(.failed)
                                guard let self else { return }
                                self.logI("present", "widget is not shown, another content or feedback overlay is on screen, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")
                                self.presentedWidgetManagers.removeAll { $0 === manager }
                            })
        }
        #else
        logW("present", "feedback widgets are not available on this platform, the widget will not be presented, widgetID: [\(widget.id)]")
        callback?(.failed)
        #endif
    }

    // MARK: - Lifecycle

    /// Closes the widgets on screen once feedback consent is removed. No "closed"
    /// event is recorded for them: the consent it needs is already gone, and the
    /// user did not close the widget. Their callbacks are told it closed.
    func consentRemoved() {
        #if os(iOS) || os(visionOS) || os(macOS)
        let managers = presentedWidgetManagers
        guard !managers.isEmpty else { return }
        logD("consentRemoved", "feedback consent was removed, the widgets on screen are closed, widgetCount: [\(managers.count)]")
        onMainThread {
            for manager in managers {
                (manager as? WebViewManager)?.close()
            }
        }
        #endif
    }

    /// Takes any widget still on screen down with the instance.
    ///
    /// A widget is presented in an overlay window above the whole application, so
    /// one left behind by a halt would sit there with no SDK to report its result
    /// to and no way for the user to be sure it belongs to anything.
    override func halt(clearStorage: Bool) {
        #if os(iOS) || os(visionOS) || os(macOS)
        let managers = presentedWidgetManagers
        presentedWidgetManagers.removeAll()

        guard !managers.isEmpty else { return }
        logD("halt", "taking the presented feedback widgets off screen, widgetCount: [\(managers.count)]")

        // The core is held until the widgets are closed. Off the main thread this
        // runs after the halt has released the core, and closing a widget, its
        // dismissal included, still reads it.
        let close = { [core] in
            for manager in managers {
                (manager as? WebViewManager)?.close()
            }
            withExtendedLifetime(core) {}
        }

        onMainThread(close)
        #endif
    }

    /// The URL the widget web view loads.
    ///
    /// - Parameter surface: the size the widget will be shown in. It goes into
    ///   `custom` because the widget templates lay themselves out from it, not from
    ///   anything they can measure on their own.
    func widgetURL(for widget: CountlyFeedbackWidget, surface: CGSize) -> URL? {
        var urlString = "\(core.config.normalizedHost)\(Endpoint.feedback)/\(widget.type.wireName)"

        let queryItems = [
            "\(QS.appKey)=\(core.config.appKey.urlEscaped)",
            "\(QS.deviceID)=\(core.modules.deviceID.deviceID.urlEscaped)",
            "\(QS.sdkName)=\(core.sdkName)",
            "\(QS.sdkVersion)=\(core.sdkVersion)",
            "\(Key.appVersion)=\(core.appVersion.urlEscaped)",
            "\(Key.platform)=\((DeviceMetrics.osName ?? "").urlEscaped)",
            "\(Key.widgetID)=\(widget.id.urlEscaped)",
            "\(QS.appVersion)=\(core.appVersion.urlEscaped)",
            // What the page checks a `resize` message against.
            //
            // The widget's own listener compares `event.origin` to the `origin`
            // query parameter and ignores anything that does not match, without
            // logging or erroring. Omit this and the page never answers the SDK's
            // surface message, so it never states the size it wants and every
            // widget is shown at the maximum its type allows.
            "\(Key.origin)=\(core.config.normalizedHost.urlEscaped)",
        ].joined(separator: "&")

        // No checksum: the page sends the answers to endpoints that do not check it.
        urlString += "?\(queryItems)"

        // Tells the page it is being shown inside the SDK's own container, and for
        // a newer widget version that it should render its own close control.
        var custom = Self.customParameters(rendersOwnCloseControl: widget.widgetVersion != nil,
                                           surface: surface)
        // The page records the answers itself, so the global segmentation has to travel to it.
        let globalSegmentation = core.modules.content.currentGlobalSegmentation
        if !globalSegmentation.isEmpty {
            custom["sg"] = globalSegmentation
        }
        urlString += "&custom=\(CountlyJSON.escapedString(from: custom, logger: log))"

        let finalURL = DeviceMetrics.urlStringByAppendingThemeMode(urlString)
        logD("widgetURL", "widget URL generated, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)], widgetVersion: [\(widget.widgetVersion ?? "")], rendersOwnCloseControl: [\(widget.widgetVersion != nil)]")
        // The query string carries the device ID and the application key.
        logV("widgetURL", "widget URL detail, url: [\(finalURL)]")

        let url = URL(string: finalURL)
        if url == nil {
            logE("widgetURL", "the widget URL could not be parsed, the widget cannot be shown, widgetID: [\(widget.id)]")
        }
        return url
    }

    /// The `custom` object the widget templates read their layout from.
    ///
    /// - Parameter rendersOwnCloseControl: whether the widget is new enough to draw
    ///   its own close button rather than relying on the SDK's.
    /// - Parameter surface: the area the widget will be shown in.
    ///
    /// The dimensions are not decoration. A template picks its breakpoint from
    /// `width` and `height` and works out where to put the card by subtracting the
    /// card's height from theirs. Send neither and it falls through to its largest
    /// breakpoint, caps the card at that breakpoint's maximum whatever the real
    /// screen is, and places the card at the top because the number it subtracts
    /// from is undefined. What the user sees is a short card in the wrong corner
    /// with its content scrolling inside it, which looks like anything except a
    /// missing query parameter.
    static func customParameters(rendersOwnCloseControl: Bool, surface: CGSize) -> [String: Any] {
        var custom: [String: Any] = ["tc": "1"]
        if rendersOwnCloseControl {
            custom["rw"] = "1"
            custom["xb"] = "1"
        }
        // Numbers, not strings. The template decides orientation with
        // `custom.width > custom.height` on the parsed values, and two JSON strings
        // compare character by character: "1440" > "900" is false, so a landscape
        // window would be laid out as a portrait one. The web SDK sends numbers.
        //
        // Omitted rather than sent as zero when there is no surface to report: a
        // zero is a dimension the template will believe and lay out against.
        if surface.width > 0, surface.height > 0 {
            custom["width"] = Int(surface.width.rounded())
            custom["height"] = Int(surface.height.rounded())
        }
        return custom
    }

    // MARK: - Widget data

    /// Fetches one widget's definition.
    func fetchWidgetData(for widget: CountlyFeedbackWidget, completion: @escaping ([String: Any]?, Error?) -> Void) {
        logI("fetchWidgetData", "widget data fetch requested, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")

        guard core.serverConfig.networkingEnabled else {
            logD("fetchWidgetData", "widget data fetch is dropped, networking is disabled by server config, widgetID: [\(widget.id)]")
            completion(nil, CountlyError.networkingDisabled)
            return
        }

        // The request sends `shown=1`, so the server counts an impression.
        guard core.modules.consent.hasConsent(for: .feedback) else {
            logD("fetchWidgetData", "no feedback consent given, widget data is not fetched, widgetID: [\(widget.id)]")
            completion(nil, CountlyError.feedbackConsentNotGiven)
            return
        }

        guard !core.modules.deviceID.isTemporary else {
            logD("fetchWidgetData", "widget data is not fetched in temporary device ID mode, widgetID: [\(widget.id)]")
            completion(nil, CountlyError.feedbackWidgetNotAvailable.asNSError)
            return
        }

        var queryString = core.network.builder.queryEssentials()
        queryString += "&\(Key.appVersion)=\(core.appVersion.urlEscaped)"
        queryString += "&\(Key.platform)=\((DeviceMetrics.osName ?? "").urlEscaped)"
        queryString += "&\(Key.shown)=1"
        queryString += "&\(Key.widgetID)=\(widget.id.urlEscaped)"
        queryString = core.network.builder.finishImmediateRequest(queryString)

        let path = "\(Endpoint.output)\(Endpoint.surveys)/\(widget.type.wireName)\(Endpoint.widget)"
        let request = core.network.instantRequest(queryString: queryString, path: path)
        logD("fetchWidgetData", "widget data request is started, widgetID: [\(widget.id)], path: [\(path)]")

        let task = core.network.instantTask(with: request) { [weak self] data, response, error in
            // The caller is answered even once a halt has released the module.
            guard let self else {
                DispatchQueue.main.async { completion(nil, error ?? CountlyError.feedbackWidgetNotAvailable.asNSError) }
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil,
                  statusCode == 200,
                  let widgetData = CountlyJSON.object(from: data, logger: self.log) as? [String: Any] else {
                let nsError = error as NSError?
                self.logD("fetchWidgetData", "widget data request failed, widgetID: [\(widget.id)], statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)], error: [\(nsError?.localizedDescription ?? "")], domain: [\(nsError?.domain ?? "")], code: [\(nsError?.code ?? 0)]")
                DispatchQueue.main.async {
                    completion(nil, error ?? CountlyError.feedbackWidgetNotAvailable.asNSError)
                }
                return
            }

            self.logD("fetchWidgetData", "widget data fetched, widgetID: [\(widget.id)], fieldCount: [\(widgetData.count)], fields: [\(widgetData.keys.sorted().joined(separator: ", "))]")
            DispatchQueue.main.async { completion(widgetData, nil) }
        }
        guard let task else {
            completion(nil, CountlyError.feedbackWidgetNotAvailable.asNSError)
            return
        }
        task.resume()
    }

    // MARK: - Recording results

    /// Records the answers of a widget, or its dismissal when `result` is `nil`.
    ///
    /// An NPS result needs a whole number "rating" from 0 to 10, a rating result
    /// one from 1 to 5; a result without a valid one is not recorded. Entries with
    /// an empty key or an `NSNull` value are dropped. Each case is a warning.
    func recordResult(_ result: [String: Any]?, for widget: CountlyFeedbackWidget) {
        logI("recordResult", "widget result recording requested, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)], answeredFieldCount: [\(result?.count ?? 0)], isDismissalOnly: [\(result == nil)]")

        guard !core.modules.deviceID.isTemporary else {
            logW("recordResult", "the widget result is ignored in temporary device ID mode, widgetID: [\(widget.id)]")
            return
        }

        warnIfWidgetDataDoesNotMatch(widget)

        guard let result else {
            recordDismissal(for: widget)
            return
        }

        let usable = result.filter { !$0.key.isEmpty && !($0.value is NSNull) }
        if usable.count != result.count {
            logW("recordResult", "entries with an empty key or a null value are dropped from the widget result, droppedCount: [\(result.count - usable.count)], widgetID: [\(widget.id)]")
            core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
        }

        guard Self.isValidRating(usable[Key.rating], for: widget.type) else {
            logW("recordResult", "the widget result is not recorded, its rating is missing, not a whole number or out of range, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")
            core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
            return
        }

        // Field names describe the widget, the values behind them are what the
        // end user answered.
        logD("recordResult", "widget result field detail, widgetID: [\(widget.id)], answeredFields: [\(usable.keys.sorted().joined(separator: ", "))]")
        logV("recordResult", "widget result recording detail, widgetID: [\(widget.id)], result: [\(usable)]")

        recordWidgetEvent(segmentation: usable, for: widget)
    }

    /// Whether `value` is a rating the widget type takes: a whole number from 0
    /// to 10 for NPS and from 1 to 5 for a rating widget. A survey has none.
    static func isValidRating(_ value: Any?, for type: FeedbackWidgetType) -> Bool {
        let range: ClosedRange<Int>
        switch type {
        case .nps: range = 0...10
        case .rating: range = 1...5
        case .survey: return true
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded() else { return false }
        return range.contains(number.intValue)
    }

    /// Warns when the widget data fetched for `widget` describes another widget.
    private func warnIfWidgetDataDoesNotMatch(_ widget: CountlyFeedbackWidget) {
        let data = widget.data
        guard !data.isEmpty else { return }
        let dataID = data["_id"] as? String
        let dataType = data["type"] as? String
        if (dataID != nil && dataID != widget.id) || (dataType != nil && dataType != widget.type.wireName) {
            logW("recordResult", "the widget data does not belong to this widget, widgetID: [\(widget.id)], dataID: [\(dataID ?? "")], widgetType: [\(widget.type.wireName)], dataType: [\(dataType ?? "")]")
        }
    }

    private func recordDismissal(for widget: CountlyFeedbackWidget) {
        logD("recordDismissal", "the widget was closed without an answer, a dismissal will be recorded, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")
        recordWidgetEvent(segmentation: [Key.closed: 1], for: widget)
    }

    /// Truncates every string value, leaving the keys alone because they are the
    /// widget's question identifiers.
    private func truncatedStringValues(_ segmentation: [String: Any], _ explanation: String) -> [String: Any] {
        var result = segmentation
        for (key, value) in segmentation {
            guard let text = value as? String else { continue }
            result[key] = limits.truncatedValue(text, explanation + " value")
        }
        return result
    }

    private func recordWidgetEvent(segmentation: [String: Any], for widget: CountlyFeedbackWidget) {
        guard core.modules.consent.hasConsent(for: .feedback) else {
            logD("recordWidgetEvent", "no feedback consent given, widget result event is not recorded")
            return
        }

        // End user text, so the reserved event path's "SDK-built" premise does not hold.
        var payload = truncatedStringValues(segmentation, "recordWidgetEvent")
        payload[Key.platform] = DeviceMetrics.osName
        payload[Key.appVersion] = core.appVersion
        payload[Key.widgetID] = widget.id
        payload = core.modules.content.withGlobalSegmentation(payload) ?? payload

        logI("recordWidgetEvent", "widget result submitted, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)], submittedFieldCount: [\(segmentation.count)]")

        core.modules.events.recordReservedEvent(widget.type.eventKey, segmentation: payload)

        // Sent right away: a widget answer is a moment the product team is
        // watching for, and batching it behind ninety-nine other events would
        // delay it by minutes.
        core.modules.events.sendEvents()
    }

    /// Records the result of a rating widget presented by the host application,
    /// the legacy call. Needs the "star-rating" consent, a widget ID and a rating
    /// from 1 to 5; otherwise it is ignored with a warning. Sent right away.
    func recordRatingWidget(id widgetID: String,
                            rating: Int,
                            email: String?,
                            comment: String?,
                            userCanBeContacted: Bool) {
        logI("recordRatingWidget", "rating widget result recording requested, widgetID: [\(widgetID)], emailProvided: [\(!(email ?? "").isEmpty)], commentProvided: [\(!(comment ?? "").isEmpty)], userCanBeContacted: [\(userCanBeContacted)]")

        guard core.modules.consent.hasConsent(for: .starRating) else {
            logD("recordRatingWidget", "no star-rating consent given, rating widget result is not recorded")
            return
        }

        guard !widgetID.isEmpty else {
            logW("recordRatingWidget", "rating widget result is dropped, widget ID is empty")
            core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
            return
        }

        // Never moved into the range: a clamped answer would be one the user did not give.
        guard (1...5).contains(rating) else {
            logW("recordRatingWidget", "rating widget result is dropped, the rating must be a whole number from 1 to 5, rating: [\(rating)]")
            core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
            return
        }

        var segmentation: [String: Any] = [:]
        segmentation[Key.platform] = DeviceMetrics.osName
        segmentation[Key.appVersion] = core.appVersion
        segmentation[Key.rating] = rating
        segmentation[Key.widgetID] = widgetID
        segmentation[Key.email] = email.map { limits.truncatedValue($0, "rating widget email") }
        segmentation[Key.comment] = comment.map { limits.truncatedValue($0, "rating widget comment") }
        segmentation[Key.contactMe] = userCanBeContacted
        segmentation = core.modules.content.withGlobalSegmentation(segmentation) ?? segmentation

        // The rating, the comment and the email are what the end user typed.
        logV("recordRatingWidget", "rating widget result detail, widgetID: [\(widgetID)], rating: [\(rating)], email: [\(email ?? "")], comment: [\(comment ?? "")]")
        logD("recordRatingWidget", "rating widget result is submitted as a reserved event, widgetID: [\(widgetID)], eventKey: [\(ReservedEventKey.ratingWidget)], segmentationFieldCount: [\(segmentation.count)]")

        core.modules.events.recordReservedEvent(ReservedEventKey.ratingWidget, segmentation: segmentation)
    }
}
