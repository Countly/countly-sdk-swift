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
    /// dismissal callback.
    private var presentedWidgetManagers: [AnyObject] = []

    /// One line per widget, enough to tell why a given one was or was not picked.
    /// Widget names and tags are authored in the dashboard, not by the end user.
    private static func describe(_ widgets: [CountlyFeedbackWidget]) -> String {
        widgets.map { "\($0.id)/\($0.type.wireName)/\($0.name)/tags=\($0.tags.joined(separator: "+"))" }
            .joined(separator: ", ")
    }

    // MARK: - Widget list

    /// Fetches the widgets the server offers for this application.
    ///
    /// Answers with an empty list rather than an error when the SDK is not allowed
    /// to ask, so a host application can call this unconditionally.
    func getAvailableFeedbackWidgets(completion: @escaping ([CountlyFeedbackWidget]?, Error?) -> Void) {
        logI("getAvailableFeedbackWidgets", "feedback widget list fetch requested")

        guard core.serverConfig.networkingEnabled else {
            logD("getAvailableFeedbackWidgets", "feedback widget list fetch is dropped, networking is disabled by server config")
            completion(nil, nil)
            return
        }

        guard core.modules.consent.hasConsent(for: .feedback) else {
            logD("getAvailableFeedbackWidgets", "no feedback consent given, feedback widget list is not fetched")
            completion(nil, nil)
            return
        }

        guard !core.modules.deviceID.isTemporary else {
            logD("getAvailableFeedbackWidgets", "feedback widget list fetch is dropped, device ID is temporary")
            completion(nil, nil)
            return
        }

        let request = widgetListRequest()
        logD("getAvailableFeedbackWidgets", "feedback widget list request is started, path: [\(request.url?.path ?? "")]")

        core.network.instantTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil,
                  statusCode == 200,
                  let payload = CountlyJSON.object(from: data, logger: self.log) as? [String: Any] else {
                let nsError = error as NSError?
                self.logD("getAvailableFeedbackWidgets", "feedback widget list fetch failed, statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)], error: [\(nsError?.localizedDescription ?? "")], domain: [\(nsError?.domain ?? "")], code: [\(nsError?.code ?? 0)]")
                DispatchQueue.main.async {
                    completion(nil, error ?? CountlyError.feedbacksGeneralAPIError.asNSError)
                }
                return
            }

            guard let rawWidgets = payload["result"] as? [[String: Any]] else {
                self.logE("getAvailableFeedbackWidgets", "feedback widget list response has no result field, ignoring the response")
                self.logD("getAvailableFeedbackWidgets", "widget list response shape detail, responseSize: [\(data?.count ?? 0)], responseFields: [\(payload.keys.sorted().joined(separator: ", "))]")
                DispatchQueue.main.async { completion(nil, CountlyError.feedbacksGeneralAPIError.asNSError) }
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
        }?.resume()
    }

    private func widgetListRequest() -> URLRequest {
        var queryString = [
            "\(QS.method)=\(Key.feedback)",
            "\(QS.appKey)=\(core.config.appKey.urlEscaped)",
            "\(QS.deviceID)=\(core.modules.deviceID.deviceID.urlEscaped)",
            "\(QS.sdkName)=\(core.sdkName)",
            "\(QS.sdkVersion)=\(core.sdkVersion)",
        ].joined(separator: "&")

        queryString += "&\(QS.appVersion)=\(DeviceMetrics.appVersion)"
        queryString = core.network.builder.appendChecksum(queryString)

        return core.network.instantRequest(queryString: queryString, path: Endpoint.output + Endpoint.sdk)
    }

    // MARK: - Presentation

    /// Presents the first widget of a type, or the one matching a name, ID or tag.
    func present(type: FeedbackWidgetType, nameIDOrTag: String?, callback: WidgetCallback?) {
        logI("present", "presenting a widget by type is requested, widgetType: [\(type.wireName)], nameIDorTag: [\(nameIDOrTag ?? "")]")

        getAvailableFeedbackWidgets { [weak self] widgets, error in
            guard let self else { return }

            if let error {
                self.logD("present", "widget list could not be retrieved while resolving a widget to present, widgetType: [\(type.wireName)], error: [\(error.localizedDescription)]")
                return
            }

            let candidates = (widgets ?? []).filter { $0.type == type }
            self.logD("present", "widget list filtered by type, widgetType: [\(type.wireName)], matchingWidgetCount: [\(candidates.count)], availableWidgetCount: [\(widgets?.count ?? 0)]")

            var chosen: CountlyFeedbackWidget?

            if let nameIDOrTag, !nameIDOrTag.isEmpty {
                chosen = candidates.first {
                    $0.name == nameIDOrTag || $0.id == nameIDOrTag || $0.tags.contains(nameIDOrTag)
                }
                if chosen != nil {
                    self.logD("present", "exact widget match found, nameIDorTag: [\(nameIDOrTag)], widgetType: [\(type.wireName)]")
                }
            }

            // Falling back to the first of the type keeps the simple call working
            // when a host application asks for a kind rather than a specific
            // widget.
            if chosen == nil, let first = candidates.first {
                chosen = first
                self.logD("present", "no exact widget match, falling back to the first widget of the type, widgetType: [\(type.wireName)], widgetID: [\(first.id)]")
            }

            guard let widget = chosen else {
                self.logW("present", "no feedback widget found to present, widgetType: [\(type.wireName)], nameIDorTag: [\(nameIDOrTag ?? "")]")
                return
            }

            widget.present(callback: callback)
        }
    }

    /// Puts one widget on screen.
    func present(widget: CountlyFeedbackWidget, callback: WidgetCallback?) {
        logI("present", "widget presentation requested, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")

        guard core.modules.consent.hasConsent(for: .feedback) else {
            logD("present", "no feedback consent given, widget will not be presented")
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

            // `self` is captured weakly in both blocks. The module holds the
            // manager, the manager holds the blocks, and a strong `self` there
            // would close the cycle and leak the web view, the overlay window and
            // the module itself for the life of the process.
            manager.present(url: url,
                            widgetType: widget.type,
                            widgetPosition: widget.position,
                            appear: { [weak self] in
                                self?.logI("present", "widget shown, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")
                                callback?(.appeared)
                            },
                            dismiss: { [weak self, weak manager] in
                                callback?(.closed)
                                guard let self else { return }
                                self.logI("present", "widget dismissed, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")
                                self.recordDismissal(for: widget)
                                self.presentedWidgetManagers.removeAll { $0 === manager }
                            })
        }
        #else
        logW("present", "feedback widgets are not available on this platform, the widget will not be presented, widgetID: [\(widget.id)]")
        #endif
    }

    // MARK: - Lifecycle

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

        let close = {
            for manager in managers {
                (manager as? WebViewManager)?.close()
            }
        }

        onMainThread(close)
        #endif
    }

    /// The URL the widget web view loads.
    ///
    /// - Parameter surface: the size the widget will be shown in. It goes into
    ///   `custom` because the widget templates lay themselves out from it, not from
    ///   anything they can measure on their own.
    private func widgetURL(for widget: CountlyFeedbackWidget, surface: CGSize) -> URL? {
        var urlString = "\(core.config.normalizedHost)\(Endpoint.feedback)/\(widget.type.wireName)"

        var queryItems = [
            "\(QS.appKey)=\(core.config.appKey.urlEscaped)",
            "\(QS.deviceID)=\(core.modules.deviceID.deviceID.urlEscaped)",
            "\(QS.sdkName)=\(core.sdkName)",
            "\(QS.sdkVersion)=\(core.sdkVersion)",
            "\(Key.appVersion)=\(DeviceMetrics.appVersion)",
            "\(Key.platform)=\(DeviceMetrics.osName ?? "")",
            "\(Key.widgetID)=\(widget.id)",
            "\(QS.appVersion)=\(DeviceMetrics.appVersion)",
            // What the page checks a `resize` message against.
            //
            // The widget's own listener compares `event.origin` to the `origin`
            // query parameter and ignores anything that does not match, without
            // logging or erroring. Omit this and the page never answers the SDK's
            // surface message, so it never states the size it wants and every
            // widget is shown at the maximum its type allows.
            "\(Key.origin)=\(core.config.normalizedHost.urlEscaped)",
        ].joined(separator: "&")

        queryItems = core.network.builder.appendChecksum(queryItems)
        urlString += "?\(queryItems)"

        // Tells the page it is being shown inside the SDK's own container, and for
        // a newer widget version that it should render its own close control.
        let custom = Self.customParameters(rendersOwnCloseControl: widget.widgetVersion != nil,
                                           surface: surface)
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

        var queryString = [
            "\(QS.sdkName)=\(core.sdkName)",
            "\(QS.sdkVersion)=\(core.sdkVersion)",
            "\(Key.appVersion)=\(DeviceMetrics.appVersion)",
            "\(Key.platform)=\(DeviceMetrics.osName ?? "")",
            "\(Key.shown)=1",
            "\(Key.widgetID)=\(widget.id)",
        ].joined(separator: "&")

        queryString += "&\(QS.appVersion)=\(DeviceMetrics.appVersion)"
        queryString = core.network.builder.appendChecksum(queryString)

        let path = "\(Endpoint.output)\(Endpoint.surveys)/\(widget.type.wireName)\(Endpoint.widget)"
        let request = core.network.instantRequest(queryString: queryString, path: path)
        logD("fetchWidgetData", "widget data request is started, widgetID: [\(widget.id)], path: [\(path)]")

        core.network.instantTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
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
        }?.resume()
    }

    // MARK: - Recording results

    /// Records the answers of a widget, or its dismissal when `result` is `nil`.
    func recordResult(_ result: [String: Any]?, for widget: CountlyFeedbackWidget) {
        logI("recordResult", "widget result recording requested, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)], answeredFieldCount: [\(result?.count ?? 0)], isDismissalOnly: [\(result == nil)]")

        guard let result else {
            recordDismissal(for: widget)
            return
        }

        // Field names describe the widget, the values behind them are what the
        // end user answered.
        logD("recordResult", "widget result field detail, widgetID: [\(widget.id)], answeredFields: [\(result.keys.sorted().joined(separator: ", "))]")
        logV("recordResult", "widget result recording detail, widgetID: [\(widget.id)], result: [\(result)]")

        recordWidgetEvent(segmentation: result, for: widget)
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
            result[key] = core.limits.truncatedValue(text, explanation + " value")
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
        payload[Key.appVersion] = DeviceMetrics.appVersion
        payload[Key.widgetID] = widget.id

        logI("recordWidgetEvent", "widget result submitted, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)], submittedFieldCount: [\(segmentation.count)]")

        core.modules.events.recordReservedEvent(widget.type.eventKey, segmentation: payload)

        // Sent right away: a widget answer is a moment the product team is
        // watching for, and batching it behind ninety-nine other events would
        // delay it by minutes.
        core.modules.events.sendEvents()
    }

    /// Records the result of a rating widget presented by the host application.
    func recordRatingWidget(id widgetID: String,
                            rating: Int,
                            email: String?,
                            comment: String?,
                            userCanBeContacted: Bool) {
        logI("recordRatingWidget", "rating widget result recording requested, widgetID: [\(widgetID)], emailProvided: [\(!(email ?? "").isEmpty)], commentProvided: [\(!(comment ?? "").isEmpty)], userCanBeContacted: [\(userCanBeContacted)]")

        guard core.modules.consent.hasConsent(for: .feedback) else {
            logD("recordRatingWidget", "no feedback consent given, rating widget result is not recorded")
            return
        }

        guard !widgetID.isEmpty else {
            logE("recordRatingWidget", "rating widget result is dropped, widget ID is empty or nil")
            return
        }

        var segmentation: [String: Any] = [:]
        segmentation[Key.platform] = DeviceMetrics.osName
        segmentation[Key.appVersion] = DeviceMetrics.appVersion
        segmentation[Key.rating] = rating
        segmentation[Key.widgetID] = widgetID
        segmentation[Key.email] = email.map { core.limits.truncatedValue($0, "rating widget email") }
        segmentation[Key.comment] = comment.map { core.limits.truncatedValue($0, "rating widget comment") }
        segmentation[Key.contactMe] = userCanBeContacted

        // The rating, the comment and the email are what the end user typed.
        logV("recordRatingWidget", "rating widget result detail, widgetID: [\(widgetID)], rating: [\(rating)], email: [\(email ?? "")], comment: [\(comment ?? "")]")
        logD("recordRatingWidget", "rating widget result is submitted as a reserved event, widgetID: [\(widgetID)], eventKey: [\(ReservedEventKey.ratingWidget)], segmentationFieldCount: [\(segmentation.count)]")

        core.modules.events.recordReservedEvent(ReservedEventKey.ratingWidget, segmentation: segmentation)
    }
}
