//
//  CountlyEvent.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// One recorded event, waiting to be batched into an `events=` payload.
final class CountlyEvent {

    /// Keys of the serialized form. They are the wire contract, not internal
    /// names, so they stay short and unchanged.
    private enum Field {
        static let key = "key"
        static let id = "id"
        static let currentViewID = "cvid"
        static let previousViewID = "pvid"
        static let previousEventID = "peid"
        static let segmentation = "segmentation"
        static let count = "count"
        static let sum = "sum"
        static let timestamp = "timestamp"
        static let hourOfDay = "hour"
        static let dayOfWeek = "dow"
        static let duration = "dur"
    }

    var key: String = ""

    /// Unique per event, used by the server to deduplicate retries.
    var id: String = ""

    /// The view that was open when this event happened. Empty for view events.
    var currentViewID: String?

    /// The view that preceded this one. Only set on view events.
    var previousViewID: String?

    /// The event recorded before this one, which is what lets the server
    /// reconstruct a per-user event chain.
    var previousEventID: String?

    var segmentation: [String: Any]?
    var count: Int = 1
    var sum: Double = 0
    var duration: TimeInterval = 0

    /// Seconds since the epoch. Serialized as milliseconds.
    var timestamp: TimeInterval = 0
    var hourOfDay: Int = 0
    var dayOfWeek: Int = 0

    init(key: String) {
        self.key = key
    }

    /// Rebuilds an event from the form ``dictionaryRepresentation`` produces, as
    /// the stored event queue holds it. Nil for an entry without a key.
    convenience init?(dictionary: [String: Any]) {
        guard let key = dictionary[Field.key] as? String, !key.isEmpty else { return nil }
        self.init(key: key)
        id = dictionary[Field.id] as? String ?? ""
        currentViewID = dictionary[Field.currentViewID] as? String
        previousViewID = dictionary[Field.previousViewID] as? String
        previousEventID = dictionary[Field.previousEventID] as? String
        segmentation = dictionary[Field.segmentation] as? [String: Any]
        count = (dictionary[Field.count] as? NSNumber)?.intValue ?? 1
        sum = (dictionary[Field.sum] as? NSNumber)?.doubleValue ?? 0
        duration = (dictionary[Field.duration] as? NSNumber)?.doubleValue ?? 0
        timestamp = ((dictionary[Field.timestamp] as? NSNumber)?.doubleValue ?? 0) / 1000
        hourOfDay = (dictionary[Field.hourOfDay] as? NSNumber)?.intValue ?? 0
        dayOfWeek = (dictionary[Field.dayOfWeek] as? NSNumber)?.intValue ?? 0
    }

    /// The form that goes into the `events=` array.
    var dictionaryRepresentation: [String: Any] {
        var result: [String: Any] = [:]
        result[Field.key] = key
        if let segmentation, !segmentation.isEmpty {
            result[Field.segmentation] = segmentation
        }
        result[Field.id] = id
        result[Field.currentViewID] = currentViewID
        result[Field.previousViewID] = previousViewID
        result[Field.previousEventID] = previousEventID
        result[Field.count] = count
        result[Field.sum] = sum
        result[Field.timestamp] = Int64((timestamp * 1000).rounded())
        result[Field.hourOfDay] = hourOfDay
        result[Field.dayOfWeek] = dayOfWeek
        result[Field.duration] = duration
        return result
    }
}
