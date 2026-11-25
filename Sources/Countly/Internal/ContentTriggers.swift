//
//  ContentTriggers.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Something the SDK recorded, as content triggers compare it.
struct RecordedTrigger: Equatable {
    /// The event key as the application passed it, or one of the `ContentTriggerKey` keys.
    let key: String
    /// The view name as the application passed it, for a view event.
    var viewName: String?
    /// Whether the view event is the one recorded when the view ends.
    var viewEnd = false
    /// The user properties a user details request sends.
    var properties: [String]?
    /// Whether it is an event of the application rather than one the SDK records itself.
    var customEvent = false
}

/// A recorded trigger that starts a round: the triggers its gap is kept for, and
/// the gap in milliseconds.
struct TriggerMatch {
    let gapKeys: [String]
    let gapMs: Int64
}

/// Which recorded triggers start a content trigger round, and how long the same
/// trigger waits before it starts another one.
enum ContentTriggerRules {

    /// Least time before the same trigger starts another round, for a listed event
    /// key, view name or user property.
    static let gapSpecificMs: Int64 = 10_000

    /// Least time before the same trigger starts another round, for any view, any
    /// user property or any error, which can happen often.
    static let gapNonSpecificMs: Int64 = 60_000

    /// Whether what was recorded is a content trigger. When the behavior settings
    /// carry content triggers, only they decide, and only while the content zone is
    /// wanted. Otherwise a custom event key in the journey trigger events and a view
    /// name in the journey trigger views decide, also while it is not wanted.
    static func match(_ trigger: RecordedTrigger,
                      lists: ContentTriggerLists?,
                      zoneWanted: Bool,
                      isJourneyTriggerEvent: (String) -> Bool,
                      isJourneyTriggerView: (String) -> Bool) -> TriggerMatch? {
        if let lists {
            return zoneWanted ? match(trigger, lists: lists) : nil
        }
        return matchJourneyTriggers(trigger, isJourneyTriggerEvent: isJourneyTriggerEvent, isJourneyTriggerView: isJourneyTriggerView)
    }

    /// The match against the content triggers of the behavior settings.
    private static func match(_ trigger: RecordedTrigger, lists: ContentTriggerLists) -> TriggerMatch? {
        let isView = trigger.key == ReservedEventKey.view
        let viewSuffix = isView && trigger.viewEnd ? ":end" : ""

        if isView, let name = trigger.viewName, lists.views.contains(name) {
            return TriggerMatch(gapKeys: ["v:" + name + viewSuffix], gapMs: gapSpecificMs)
        }
        if trigger.key == ContentTriggerKey.userProperties {
            let listed = (trigger.properties ?? []).filter { lists.properties.contains($0) }
            if !listed.isEmpty {
                return TriggerMatch(gapKeys: listed.map { "p:" + $0 }, gapMs: gapSpecificMs)
            }
        }
        guard lists.keys.contains(trigger.key) else { return nil }

        let nonSpecific = isView || trigger.key == ContentTriggerKey.userProperties || trigger.key == ContentTriggerKey.crash
        return TriggerMatch(gapKeys: [trigger.key + viewSuffix], gapMs: nonSpecific ? gapNonSpecificMs : gapSpecificMs)
    }

    /// The match against the deprecated journey trigger events and views: custom
    /// events and both events of a view.
    private static func matchJourneyTriggers(_ trigger: RecordedTrigger,
                                             isJourneyTriggerEvent: (String) -> Bool,
                                             isJourneyTriggerView: (String) -> Bool) -> TriggerMatch? {
        if trigger.key == ReservedEventKey.view {
            guard let name = trigger.viewName, isJourneyTriggerView(name) else { return nil }
            return TriggerMatch(gapKeys: ["v:" + name + (trigger.viewEnd ? ":end" : "")], gapMs: gapSpecificMs)
        }
        guard trigger.customEvent, isJourneyTriggerEvent(trigger.key) else { return nil }
        return TriggerMatch(gapKeys: [trigger.key], gapMs: gapSpecificMs)
    }

    /// Whether a matched trigger may start a round now.
    ///
    /// - Parameters:
    ///   - match: the matched trigger.
    ///   - stored: when each trigger last started a round, in milliseconds by gap key.
    ///   - now: the current time in milliseconds.
    /// - Returns: the times to store when the trigger may start a round, with the
    ///   ones older than the longest gap dropped, or nil when every trigger of the
    ///   match is inside its gap. A time in the future is ignored.
    static func claimGap(_ match: TriggerMatch, stored: [String: Any], now: Int64) -> [String: Any]? {
        func inGap(_ value: Any?, _ gap: Int64) -> Bool {
            guard let time = (value as? NSNumber)?.int64Value else { return false }
            return now >= time && now - time < gap
        }

        guard match.gapKeys.contains(where: { !inGap(stored[$0], match.gapMs) }) else { return nil }

        var kept = stored.filter { inGap($0.value, gapNonSpecificMs) }
        for gapKey in match.gapKeys {
            kept[gapKey] = NSNumber(value: now)
        }
        return kept
    }

    /// How many queued requests there are up to and including the given one, 0
    /// when it is not queued any more.
    static func queuedCount(upTo request: String, in queue: [String]) -> Int {
        guard let index = queue.lastIndex(of: request) else { return 0 }
        return index + 1
    }
}
