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
            logV("getAvailableFeedbackWidgets", "no feedback consent given, feedback widget list is not fetched")
            completion(nil, nil)
            return
        }

        guard !core.modules.deviceID.isTemporary else {
            logW("getAvailableFeedbackWidgets", "feedback widget list fetch is dropped, device ID is temporary")
            completion(nil, nil)
            return
        }

        let request = widgetListRequest()

        core.network.instantSession().dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil,
                  statusCode == 200,
                  let payload = CountlyJSON.object(from: data, logger: self.log) as? [String: Any] else {
                self.logW("getAvailableFeedbackWidgets", "feedback widget list fetch failed, statusCode: [\(statusCode)]")
                DispatchQueue.main.async {
                    completion(nil, error ?? CountlyError.feedbacksGeneralAPIError.asNSError)
                }
                return
            }

            guard let rawWidgets = payload["result"] as? [[String: Any]] else {
                self.logE("getAvailableFeedbackWidgets", "feedback widget list response has no result field, ignoring the response")
                DispatchQueue.main.async { completion(nil, CountlyError.feedbacksGeneralAPIError.asNSError) }
                return
            }

            let widgets = rawWidgets.compactMap { CountlyFeedbackWidget(dictionary: $0, module: self) }
            self.logI("getAvailableFeedbackWidgets", "feedback widget list fetched, widgetCount: [\(widgets.count)]")

            DispatchQueue.main.async { completion(widgets, nil) }
        }.resume()
    }

    private func widgetListRequest() -> URLRequest {
        var queryString = [
            "\(QS.method)=\(Key.feedback)",
            "\(QS.appKey)=\(core.config.appKey.urlEscaped)",
            "\(QS.deviceID)=\(core.modules.deviceID.deviceID.urlEscaped)",
            "\(QS.sdkName)=\(SDKIdentity.name)",
            "\(QS.sdkVersion)=\(SDKIdentity.version)",
        ].joined(separator: "&")

        queryString += "&\(QS.appVersion)=\(DeviceMetrics.appVersion)"
        queryString = core.network.builder.appendChecksum(queryString)

        return core.network.instantRequest(queryString: queryString, path: Endpoint.output + Endpoint.sdk)
    }

    // MARK: - Presentation

    /// Presents the first widget of a type, or the one matching a name, ID or tag.
    func present(type: FeedbackWidgetType, nameIDOrTag: String?, callback: WidgetCallback?) {
        getAvailableFeedbackWidgets { [weak self] widgets, error in
            guard let self else { return }

            if let error {
                self.logD("present", "widget list could not be retrieved while resolving a widget to present, widgetType: [\(type.wireName)], error: [\(error.localizedDescription)]")
                return
            }

            let candidates = (widgets ?? []).filter { $0.type == type }
            self.logD("present", "widget list filtered by type, widgetType: [\(type.wireName)], matchingWidgetCount: [\(candidates.count)]")

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
            logV("present", "no feedback consent given, widget will not be presented")
            return
        }

        #if os(iOS) || os(visionOS)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Built on the main thread: the URL carries the resolved theme, and
            // resolving it reads the key window's trait collection.
            let url = self.widgetURL(for: widget)

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
        logW("present", "feedback widgets are only available on iOS and visionOS")
        #endif
    }

    // MARK: - Lifecycle

    /// Takes any widget still on screen down with the instance.
    ///
    /// A widget is presented in an overlay window above the whole application, so
    /// one left behind by a halt would sit there with no SDK to report its result
    /// to and no way for the user to be sure it belongs to anything.
    override func halt(clearStorage: Bool) {
        #if os(iOS) || os(visionOS)
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
    private func widgetURL(for widget: CountlyFeedbackWidget) -> URL? {
        var urlString = "\(core.config.normalizedHost)\(Endpoint.feedback)/\(widget.type.wireName)"

        var queryItems = [
            "\(QS.appKey)=\(core.config.appKey.urlEscaped)",
            "\(QS.deviceID)=\(core.modules.deviceID.deviceID.urlEscaped)",
            "\(QS.sdkName)=\(SDKIdentity.name)",
            "\(QS.sdkVersion)=\(SDKIdentity.version)",
            "\(Key.appVersion)=\(DeviceMetrics.appVersion)",
            "\(Key.platform)=\(DeviceMetrics.osName ?? "")",
            "\(Key.widgetID)=\(widget.id)",
            "\(QS.appVersion)=\(DeviceMetrics.appVersion)",
        ].joined(separator: "&")

        queryItems = core.network.builder.appendChecksum(queryItems)
        urlString += "?\(queryItems)"

        // Tells the page it is being shown inside the SDK's own container, and for
        // a newer widget version that it should render its own close control.
        var custom: [String: String] = ["tc": "1"]
        if widget.widgetVersion != nil {
            custom["rw"] = "1"
            custom["xb"] = "1"
        }
        urlString += "&custom=\(CountlyJSON.escapedString(from: custom, logger: log))"

        let finalURL = DeviceMetrics.urlStringByAppendingThemeMode(urlString)
        logD("widgetURL", "widget URL generated, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)]")
        return URL(string: finalURL)
    }

    // MARK: - Widget data

    /// Fetches one widget's definition.
    func fetchWidgetData(for widget: CountlyFeedbackWidget, completion: @escaping ([String: Any]?, Error?) -> Void) {
        var queryString = [
            "\(QS.sdkName)=\(SDKIdentity.name)",
            "\(QS.sdkVersion)=\(SDKIdentity.version)",
            "\(Key.appVersion)=\(DeviceMetrics.appVersion)",
            "\(Key.platform)=\(DeviceMetrics.osName ?? "")",
            "\(Key.shown)=1",
            "\(Key.widgetID)=\(widget.id)",
        ].joined(separator: "&")

        queryString += "&\(QS.appVersion)=\(DeviceMetrics.appVersion)"
        queryString = core.network.builder.appendChecksum(queryString)

        let path = "\(Endpoint.output)\(Endpoint.surveys)/\(widget.type.wireName)\(Endpoint.widget)"
        let request = core.network.instantRequest(queryString: queryString, path: path)

        core.network.instantSession().dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil,
                  statusCode == 200,
                  let widgetData = CountlyJSON.object(from: data, logger: self.log) as? [String: Any] else {
                DispatchQueue.main.async {
                    completion(nil, error ?? CountlyError.feedbackWidgetNotAvailable.asNSError)
                }
                return
            }

            self.logD("fetchWidgetData", "widget data fetched, widgetID: [\(widget.id)], fieldCount: [\(widgetData.count)]")
            DispatchQueue.main.async { completion(widgetData, nil) }
        }.resume()
    }

    // MARK: - Recording results

    /// Records the answers of a widget, or its dismissal when `result` is `nil`.
    func recordResult(_ result: [String: Any]?, for widget: CountlyFeedbackWidget) {
        logI("recordResult", "widget result recording requested, widgetID: [\(widget.id)], widgetType: [\(widget.type.wireName)], answeredFieldCount: [\(result?.count ?? 0)]")
        logV("recordResult", "widget result recording detail, widgetID: [\(widget.id)], result: [\(result ?? [:])]")

        guard let result else {
            recordDismissal(for: widget)
            return
        }
        recordWidgetEvent(segmentation: result, for: widget)
    }

    private func recordDismissal(for widget: CountlyFeedbackWidget) {
        recordWidgetEvent(segmentation: [Key.closed: 1], for: widget)
    }

    private func recordWidgetEvent(segmentation: [String: Any], for widget: CountlyFeedbackWidget) {
        guard core.modules.consent.hasConsent(for: .feedback) else {
            logV("recordWidgetEvent", "no feedback consent given, widget result event is not recorded")
            return
        }

        var payload = segmentation
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
            logV("recordRatingWidget", "no feedback consent given, rating widget result is not recorded")
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
        segmentation[Key.email] = email
        segmentation[Key.comment] = comment
        segmentation[Key.contactMe] = userCanBeContacted

        core.modules.events.recordReservedEvent(ReservedEventKey.ratingWidget, segmentation: segmentation)
    }
}
