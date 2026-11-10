//
//  CountlyFeedbackWidget.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Kind of feedback widget.
@objc public enum FeedbackWidgetType: Int, Sendable {
    case survey
    case nps
    case rating

    /// The name the server uses in the widget list and in URLs.
    public var wireName: String {
        switch self {
        case .survey: return "survey"
        case .nps: return "nps"
        case .rating: return "rating"
        }
    }

    /// The reserved event key the widget's answers are recorded under.
    var eventKey: String {
        switch self {
        case .survey: return ReservedEventKey.survey
        case .nps: return ReservedEventKey.nps
        case .rating: return ReservedEventKey.ratingWidget
        }
    }

    init?(wireName: String) {
        switch wireName {
        case "survey": self = .survey
        case "nps": self = .nps
        case "rating": self = .rating
        default: return nil
        }
    }
}

/// What happened to a widget the SDK was asked to present.
@objc public enum WidgetState: Int, Sendable {
    /// The widget is on screen.
    case appeared
    /// The widget was on screen and is closed.
    case closed
    /// The widget could not be shown, and nothing was recorded for it: the widget
    /// list could not be fetched, no widget matched, feedback consent is missing,
    /// the SDK is in temporary device ID mode, web views are disabled, another
    /// overlay is on screen, or the page did not load.
    case failed
}

/// Called when a widget appears, is closed, or could not be shown.
public typealias WidgetCallback = (_ state: WidgetState) -> Void

/// One feedback widget the server offers for this application.
///
/// Obtained from `feedback.getAvailableFeedbackWidgets`. Presenting it, or
/// recording a result for it, goes back through the instance that produced it, so
/// the answers land on the right server.
@objcMembers
public final class CountlyFeedbackWidget: NSObject {

    public let type: FeedbackWidgetType
    /// `ID` in Objective-C, as the Objective-C SDK names it, since `id` is a type there.
    @objc(ID) public let id: String
    public let name: String
    public let tags: [String]

    /// The widget definition, populated by `getWidgetData`.
    public private(set) var data: [String: Any] = [:]

    /// Set when the server offers a newer widget rendering. Its presence switches
    /// presentation to the full screen web view. Public because a bridge SDK passes
    /// the widget list across to its own layer and has to carry this field with it.
    public let widgetVersion: String?

    /// The widget's `appearance.position`, such as `bLeft` or `bRight`, or `nil`
    /// when the dashboard did not set one. Only a survey is placed by it; an NPS is
    /// always centred. The web and Java SDKs read the same field.
    let position: String?

    /// The instance this widget was fetched through. Weak: a widget object must
    /// not keep an instance alive.
    weak var module: FeedbackModule?

    init?(dictionary: [String: Any], module: FeedbackModule?) {
        guard let id = dictionary["_id"] as? String,
              let typeName = dictionary["type"] as? String,
              let type = FeedbackWidgetType(wireName: typeName) else { return nil }

        self.id = id
        self.type = type
        self.name = (dictionary["name"] as? String) ?? ""
        self.tags = (dictionary["tg"] as? [String]) ?? []
        self.widgetVersion = dictionary["wv"] as? String
        self.position = (dictionary["appearance"] as? [String: Any])?["position"] as? String
        self.module = module
    }

    /// Presents the widget over the top view controller.
    public func present() {
        present(callback: nil)
    }

    /// Presents the widget and reports when it appears and when it is dismissed.
    /// `dismissBlock` is also called when the widget could not be shown, so a
    /// caller waiting for the widget to go away is not left waiting.
    public func present(appearBlock: (() -> Void)?, dismissBlock: (() -> Void)?) {
        present { state in
            switch state {
            case .appeared: appearBlock?()
            case .closed, .failed: dismissBlock?()
            }
        }
    }

    /// Presents the widget and reports its state changes.
    public func present(callback: WidgetCallback?) {
        module?.present(widget: self, callback: callback)
    }

    /// Fetches the widget definition, for building a custom interface.
    public func getWidgetData(completion: @escaping ([String: Any]?, Error?) -> Void) {
        // Answered rather than dropped when the instance that listed the widget is
        // gone, so a caller awaiting the data is never left waiting.
        guard let module else {
            completion(nil, CountlyError.feedbackWidgetNotAvailable.asNSError)
            return
        }
        module.fetchWidgetData(for: self) { [weak self] data, error in
            if let data { self?.data = data }
            completion(data, error)
        }
    }

    /// Records the answers of a manually presented widget, sent right away.
    ///
    /// Pass `nil` when the user dismissed it without answering, which records the
    /// dismissal rather than nothing. An NPS result needs a whole number "rating"
    /// from 0 to 10, a rating result one from 1 to 5; a result without one is not
    /// recorded. Entries with an empty key or an `NSNull` value are dropped.
    public func recordResult(_ result: [String: Any]?) {
        module?.recordResult(result, for: self)
    }
}
