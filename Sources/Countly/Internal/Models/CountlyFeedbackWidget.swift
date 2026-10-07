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

/// Whether a widget just appeared or was dismissed.
@objc public enum WidgetState: Int, Sendable {
    case appeared
    case closed
}

/// Called when a widget appears or is dismissed.
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
    public func present(appearBlock: (() -> Void)?, dismissBlock: (() -> Void)?) {
        present { state in
            switch state {
            case .appeared: appearBlock?()
            case .closed: dismissBlock?()
            }
        }
    }

    /// Presents the widget and reports its state changes.
    public func present(callback: WidgetCallback?) {
        module?.present(widget: self, callback: callback)
    }

    /// Fetches the widget definition, for building a custom interface.
    public func getWidgetData(completion: @escaping ([String: Any]?, Error?) -> Void) {
        module?.fetchWidgetData(for: self) { [weak self] data, error in
            if let data { self?.data = data }
            completion(data, error)
        }
    }

    /// Records the answers of a manually presented widget.
    ///
    /// Pass `nil` when the user dismissed it without answering, which records the
    /// dismissal rather than nothing.
    public func recordResult(_ result: [String: Any]?) {
        module?.recordResult(result, for: self)
    }
}
