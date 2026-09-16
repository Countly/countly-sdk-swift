//
//  EventsModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Records events and batches them into requests.
///
/// Events are held in memory and sent together once enough of them accumulate,
/// because one request per event would be wasteful and would lose the ordering
/// the server relies on. They are also flushed whenever something else has to go
/// out first, so an event recorded before a session end is never reported after
/// it.
final class EventsModule: ModuleBase {

    override class var moduleName: String { "Events" }

    /// Events waiting to be batched. Guarded by `eventLock`.
    private var recordedEvents: [CountlyEvent] = []

    /// Timed events that have been started but not ended, keyed by event key.
    private var startedEvents: [String: CountlyEvent] = [:]

    private let eventLock = NSRecursiveLock()

    /// ID of the previously recorded non-reserved event, which forms the chain the
    /// server walks. Guarded by `eventLock` so a burst from several threads still
    /// produces one consistent chain.
    private var previousEventID: String?
    private var previousEventName: String?

    /// How many events accumulate before they are sent.
    private var sendThreshold: Int { max(1, core.config.eventSendThreshold) }

    /// The recorded events not yet moved into the request queue, each serialized
    /// the way it will be sent. Oldest first.
    ///
    /// Diagnostic surface. Android's `CountlyStore.getEvents` returns the same
    /// thing as JSON strings and its Flutter bridge forwards them straight to the
    /// integration suite.
    var recordedEventsJSON: [String] {
        eventLock.lock()
        let snapshot = recordedEvents
        eventLock.unlock()
        return snapshot.compactMap { CountlyJSON.string(from: $0.dictionaryRepresentation, logger: core.logger) }
    }

    /// Events sitting in memory and not yet moved into the request queue. Read by
    /// the user profile module, which has to report the queue depth it is about to
    /// flush.
    var pendingEventCount: Int {
        eventLock.lock()
        defer { eventLock.unlock() }
        return recordedEvents.count
    }

    /// Keys of the timers started and not yet ended or cancelled. Only read from
    /// log messages, which are built lazily.
    private var startedTimedEventKeys: [String] {
        eventLock.lock()
        defer { eventLock.unlock() }
        return startedEvents.keys.sorted()
    }

    // MARK: - Public recording

    /// Records an event after applying consent, behavior settings and the SDK
    /// limits.
    func recordEvent(_ key: String,
                     segmentation: [String: Any]? = nil,
                     count: Int = 1,
                     sum: Double = 0,
                     duration: TimeInterval = 0) {
        logI("recordEvent", "recording an event, key: [\(key)], segmentationKeyCount: [\(segmentation?.count ?? 0)], count: [\(count)], sum: [\(sum.logValue)], duration: [\(duration.logSeconds)]")
        logD("recordEvent", "event segmentation keys, key: [\(key)], segmentationKeys: [\(segmentation?.keys.sorted() ?? [])]")
        logV("recordEvent", "event segmentation detail, key: [\(key)], segmentation: [\(segmentation ?? [:])]")

        if let reservedConsent = consentForReservedEvent(key) {
            guard reservedConsent else {
                logD("recordEvent", "no consent given for the reserved event, it will not be recorded, key: [\(key)]")
                return
            }
            logD("recordEvent", "specific consent is given for the reserved event, it will be recorded, key: [\(key)]")
        } else if !core.modules.consent.hasConsent(for: .events) {
            logD("recordEvent", "no consent given for events, the event will not be recorded, key: [\(key)]")
            return
        }

        guard core.serverConfig.customEventTrackingEnabled else {
            logD("recordEvent", "dropping the event, custom event tracking is disabled by the server config, key: [\(key)]")
            return
        }

        guard core.serverConfig.shouldRecordEvent(key) else {
            logD("recordEvent", "dropping the event, it is filtered out by the server config event filter, key: [\(key)]")
            return
        }

        let filtered = core.serverConfig.filterSegmentation(segmentation, eventKey: key)
        let sanitized = core.limits.sanitized(filtered, "Event segmentation")

        let providedKeyCount = segmentation?.count ?? 0
        let acceptedKeyCount = sanitized?.count ?? 0
        if providedKeyCount != acceptedKeyCount {
            logD("recordEvent", "some segmentation entries were removed by the server config filter or the segmentation limits, key: [\(key)], providedKeyCount: [\(providedKeyCount)], acceptedKeyCount: [\(acceptedKeyCount)], acceptedKeys: [\(sanitized?.keys.sorted() ?? [])]")
        }

        record(key: key,
               segmentation: sanitized,
               count: count,
               sum: sum,
               duration: duration,
               id: nil,
               timestamp: core.clock.now())
    }

    /// Records an event the SDK owns, skipping the event consent gate.
    ///
    /// Reserved events belong to another feature, so they answer to that feature's
    /// consent instead, which is resolved by the caller.
    func recordReservedEvent(_ key: String,
                             segmentation: [String: Any]?,
                             count: Int = 1,
                             sum: Double = 0,
                             duration: TimeInterval = 0,
                             id: String? = nil,
                             timestamp: TimeInterval? = nil) {
        logD("recordReservedEvent", "recording a reserved event, key: [\(key)], segmentationKeys: [\(segmentation?.keys.sorted() ?? [])], count: [\(count)], sum: [\(sum.logValue)], duration: [\(duration.logSeconds)], idProvided: [\(id != nil)], timestampProvided: [\(timestamp != nil)]")
        logV("recordReservedEvent", "reserved event segmentation detail, key: [\(key)], segmentation: [\(segmentation ?? [:])]")

        record(key: key,
               segmentation: segmentation,
               count: count,
               sum: sum,
               duration: duration,
               id: id,
               timestamp: timestamp ?? core.clock.now())
    }

    // MARK: - Timed events

    /// Starts a timer under `key`. Ending it records an event carrying the elapsed
    /// duration.
    func startEvent(_ key: String) {
        logI("startEvent", "starting a timed event, key: [\(key)]")

        guard core.modules.consent.hasConsent(for: .events) else {
            logD("startEvent", "no consent given for events, the timed event will not be started, key: [\(key)]")
            return
        }

        eventLock.lock()
        defer { eventLock.unlock() }

        guard startedEvents[key] == nil else {
            logW("startEvent", "timed event is not started, reason: a timed event with the same key is already started, key: [\(key)]")
            return
        }

        let event = CountlyEvent(key: key)
        event.timestamp = core.clock.now()
        startedEvents[key] = event
        logD("startEvent", "timed event is started, key: [\(key)], startedTimedEventCount: [\(startedEvents.count)]")
    }

    /// Ends a timer and records the event.
    func endEvent(_ key: String, segmentation: [String: Any]? = nil, count: Int = 1, sum: Double = 0) {
        logI("endEvent", "ending a timed event, key: [\(key)], segmentationKeyCount: [\(segmentation?.count ?? 0)], count: [\(count)], sum: [\(sum.logValue)]")
        logD("endEvent", "timed event end segmentation keys, key: [\(key)], segmentationKeys: [\(segmentation?.keys.sorted() ?? [])]")
        logV("endEvent", "timed event end segmentation detail, key: [\(key)], segmentation: [\(segmentation ?? [:])]")

        guard core.modules.consent.hasConsent(for: .events) else {
            logD("endEvent", "no consent given for events, the timed event will not be ended, key: [\(key)]")
            return
        }

        guard let event = takeTimedEvent(key) else {
            logW("endEvent", "omitting the call, the timed event was not started or was already ended, key: [\(key)]")
            logD("endEvent", "no timed event matched the key that was ended, these are the ones still running, key: [\(key)], startedTimedEventKeys: [\(startedTimedEventKeys)]")
            return
        }

        // Read from the same clock that stamped the start. The monotonic clock runs
        // ahead of the wall clock under a burst, so mixing the two can produce a
        // negative duration.
        let duration = core.clock.now() - event.timestamp
        logD("endEvent", "the timed event is ended and its duration measured, key: [\(key)], duration: [\(duration.logSeconds)], remainingTimedEventKeys: [\(startedTimedEventKeys)]")
        recordEvent(key, segmentation: segmentation, count: count, sum: sum, duration: duration)
    }

    /// Discards a timer without recording anything.
    func cancelEvent(_ key: String) {
        logI("cancelEvent", "cancelling a timed event, key: [\(key)]")

        guard core.modules.consent.hasConsent(for: .events) else {
            logD("cancelEvent", "no consent given for events, the timed event will not be cancelled, key: [\(key)]")
            return
        }

        guard takeTimedEvent(key) != nil else {
            logW("cancelEvent", "nothing to cancel, no timed event is running for the key, key: [\(key)]")
            return
        }

        logD("cancelEvent", "the timed event is cancelled, key: [\(key)], remainingTimedEventKeys: [\(startedTimedEventKeys)]")
    }

    /// Drops every running timer. Used when the user changes.
    func clearAllTimedEvents() {
        eventLock.lock()
        defer { eventLock.unlock() }
        logD("clearAllTimedEvents", "clearing all started timed events, droppedTimedEventKeys: [\(startedEvents.keys.sorted())]")
        startedEvents.removeAll()
    }

    private func takeTimedEvent(_ key: String) -> CountlyEvent? {
        eventLock.lock()
        defer { eventLock.unlock() }
        let event = startedEvents.removeValue(forKey: key)
        logD("takeTimedEvent", "timed event is requested from the started timed events, key: [\(key)], found: [\(event != nil)]")
        return event
    }

    // MARK: - Recording internals

    /// Builds the event, chains it, and hands it to the queue.
    private func record(key: String,
                        segmentation: [String: Any]?,
                        count: Int,
                        sum: Double,
                        duration: TimeInterval,
                        id: String?,
                        timestamp: TimeInterval) {
        guard !key.isEmpty else {
            logE("record", "omitting the call, the event key is nil or empty")
            return
        }

        let isReserved = ReservedEventKey.all.contains(key)
        let event = CountlyEvent(key: key)
        if let id, !id.isEmpty {
            event.id = id
        } else {
            event.id = core.clock.generateEventID()
        }

        // A view event points backwards at the view it replaced; everything else
        // points at the view it happened inside.
        if key == ReservedEventKey.view {
            event.previousViewID = core.modules.views.previousViewID ?? ""
        } else {
            event.currentViewID = core.modules.views.currentViewID ?? ""
        }

        if count < 1 {
            logD("record", "the provided event count is below one and will be clamped, key: [\(key)], providedCount: [\(count)]")
        }

        event.count = max(count, 1)
        event.sum = sum
        event.timestamp = timestamp
        event.hourOfDay = core.clock.hourOfDay()
        event.dayOfWeek = core.clock.dayOfWeek()
        event.duration = duration

        // Already filtered by `sanitized` on the public path; reserved events pass
        // SDK-built segmentation, which is well formed by construction.
        var filteredSegmentation = segmentation ?? [:]

        if isReserved {
            event.segmentation = processSegmentation(&filteredSegmentation, eventKey: key)
            enqueue(event, callback: journeyTriggerCallbackForReserved(key: key, segmentation: event.segmentation))
            return
        }

        let truncatedKey = core.limits.truncatedKey(key, "Event key")

        // The chain update and the enqueue happen under one lock so two threads
        // recording at once cannot produce two events claiming the same
        // predecessor.
        eventLock.lock()
        event.previousEventID = previousEventID ?? ""
        previousEventID = event.id

        if core.config.experimental.enablePreviousNameRecording {
            filteredSegmentation[SegKey.previousEventName] = previousEventName ?? ""
            filteredSegmentation[SegKey.currentViewName] = core.modules.views.currentViewName ?? ""
            previousEventName = truncatedKey
        }

        event.key = truncatedKey
        event.segmentation = processSegmentation(&filteredSegmentation, eventKey: truncatedKey)

        logD("record", "the event is chained to the previous non reserved event, key: [\(truncatedKey)], eventID: [\(event.id)], previousEventID: [\(event.previousEventID ?? "")]")

        let isJourneyTrigger = core.serverConfig.isJourneyTriggerEvent(truncatedKey)
        if isJourneyTrigger {
            logD("record", "the event key is a journey trigger, the batch will be sent immediately, key: [\(truncatedKey)]")
        }

        enqueue(event, callback: isJourneyTrigger ? journeyTriggerCallback() : nil)
        eventLock.unlock()
    }

    /// Adds the SDK owned segmentation keys.
    private func processSegmentation(_ segmentation: inout [String: Any], eventKey: String) -> [String: Any]? {
        let isViewEvent = eventKey == ReservedEventKey.view

        if isViewEvent, core.config.experimental.enablePreviousNameRecording {
            segmentation[SegKey.previousViewName] = core.modules.views.previousViewName ?? ""
        }

        if core.config.experimental.enableVisibilityTracking {
            // A view event carries visibility only at its start: the end of a view
            // is bookkeeping, not a moment the user was present for.
            let isViewStart = (segmentation[SegKey.visit] as? NSNumber)?.intValue == 1
            if !isViewEvent || isViewStart {
                segmentation[SegKey.visibility] = AppState.isActive ? 1 : 0
            }
        }

        return segmentation.isEmpty ? nil : segmentation
    }

    /// Which consent a reserved event answers to, or `nil` when the key is not
    /// reserved.
    private func consentForReservedEvent(_ key: String) -> Bool? {
        let consent = core.modules.consent
        switch key {
        case ReservedEventKey.orientation: return consent.hasConsent(for: .userDetails)
        case ReservedEventKey.ratingWidget, ReservedEventKey.survey, ReservedEventKey.nps:
            return consent.hasConsent(for: .feedback)
        case ReservedEventKey.pushAction: return consent.hasConsent(for: .pushNotifications)
        case ReservedEventKey.view: return consent.hasConsent(for: .viewTracking)
        default: return nil
        }
    }

    /// A view event whose name is a journey trigger flushes like a trigger event.
    ///
    /// The name is matched as sent, after truncation and filtering, so what the
    /// server configured and what it receives are compared on the same value.
    private func journeyTriggerCallbackForReserved(key: String, segmentation: [String: Any]?) -> RequestCallback? {
        guard key == ReservedEventKey.view,
              let viewName = segmentation?[SegKey.name] as? String,
              core.serverConfig.isJourneyTriggerView(viewName) else { return nil }
        logD("journeyTriggerCallbackForReserved", "the view name is a journey trigger, the batch will be sent immediately, viewName: [\(viewName)]")
        return journeyTriggerCallback()
    }

    /// Recording with a callback force-flushes the batch, and refreshing content
    /// once the server has it is what makes a journey react to the trigger.
    private func journeyTriggerCallback() -> RequestCallback {
        { [weak self] _, success in
            guard success else { return }
            // `weak` on the hop as well as on the callback, which is not belt and
            // braces. Binding `self` in the outer closure and hopping would capture
            // it strongly, keeping this module alive on the main queue while the
            // `SDKCore` that owns it is released by a halt. `core` is `unowned`, so
            // the block would then read a deallocated object and trap, taking the
            // host application down from a request that had already been answered.
            DispatchQueue.main.async { [weak self] in
                self?.core.modules.content.refreshContentZoneForJourneyTrigger()
            }
        }
    }

    // MARK: - Queueing

    /// Adds an event to the batch and sends it when the batch is full or when a
    /// callback demands an immediate answer.
    private func enqueue(_ event: CountlyEvent, callback: RequestCallback?) {
        eventLock.lock()

        // Unsent user properties have to reach the server before the event does,
        // or the event is attributed to a stale profile.
        if core.modules.userProfile.hasUnsyncedChanges {
            logD("enqueue", "unsynced user properties will be saved before this event is queued, so the event is attributed to the new profile, eventKey: [\(event.key)]")
            core.modules.userProfile.save()
        }

        recordedEvents.append(event)
        let pending = recordedEvents.count
        eventLock.unlock()

        logD("enqueue", "event is added to the in memory event queue, pendingEventCount: [\(pending)], eventSendThreshold: [\(sendThreshold)], callbackProvided: [\(callback != nil)]")

        guard callback != nil || pending >= sendThreshold else { return }

        let reason = callback != nil ? "a request callback is attached" : "the send threshold is reached"
        logD("enqueue", "the in memory event queue will be sent, reason: [\(reason)], pendingEventCount: [\(pending)]")
        sendEvents(callback: callback)
    }

    /// Serializes the batch and clears it.
    ///
    /// Returns `nil` when there is nothing to send, so the caller does not queue an
    /// empty `events=` request.
    private func serializeRecordedEvents() -> String? {
        eventLock.lock()
        defer { eventLock.unlock() }

        guard !recordedEvents.isEmpty else {
            logD("serializeRecordedEvents", "the in memory event queue is empty, no event request will be created")
            return nil
        }

        let payload = recordedEvents.map(\.dictionaryRepresentation)
        logD("serializeRecordedEvents", "serializing the recorded events for the next request, eventCount: [\(payload.count)]")
        recordedEvents.removeAll()

        let escaped = CountlyJSON.escapedString(from: payload, logger: log)
        if escaped.isEmpty {
            // The serializer reports the failure itself, so this only records what
            // was lost with it.
            logD("serializeRecordedEvents", "the recorded events could not be serialized and are gone from the in memory queue, eventCount: [\(payload.count)]")
        }
        return escaped
    }

    /// Moves the batch into the request queue without starting a drain.
    @discardableResult
    func addEventsToRequestQueue(callback: RequestCallback? = nil) -> Bool {
        guard let events = serializeRecordedEvents() else { return false }
        let queryString = "\(core.network.builder.queryEssentials())&\(QS.events)=\(events)"
        core.network.enqueue(queryString, callback: callback)
        return true
    }

    /// Sends whatever has been recorded so far.
    func sendEvents(callback: RequestCallback? = nil) {
        logD("sendEvents", "the recorded events will be moved to the request queue and the queue drained, pendingEventCount: [\(pendingEventCount)], callbackProvided: [\(callback != nil)]")
        addEventsToRequestQueue(callback: callback)
        core.network.proceedOnQueue()
    }

    /// Sends the batch, preferring to let a pending user profile save carry it.
    ///
    /// The profile has to reach the server before the events that assume it, and
    /// `save()` sends the events itself for exactly that reason. But `save()` can
    /// decline: no user details consent, or nothing actually staged. The reference
    /// treats that as done and returns, which strands the events in memory for the
    /// rest of the process, and every later lifecycle flush takes the same branch
    /// and strands them again. An application that sets a user property without
    /// user details consent never sends another event.
    func sendEventsWithSaveIfNeeded() {
        if core.modules.userProfile.hasUnsyncedChanges {
            logD("sendEventsWithSaveIfNeeded", "unsynced user properties are pending, the user details save will carry the events out, pendingEventCount: [\(pendingEventCount)]")
            if core.modules.userProfile.save() { return }
            logD("sendEventsWithSaveIfNeeded", "the user details save declined, the recorded events will be sent on their own")
        }
        sendEvents()
    }

    /// Drops the batch without sending it.
    func flushEvents() {
        eventLock.lock()
        defer { eventLock.unlock() }
        if !recordedEvents.isEmpty {
            logD("flushEvents", "the in memory event queue is dropped without being sent, droppedEventCount: [\(recordedEvents.count)]")
        }
        recordedEvents.removeAll()
    }

    // MARK: - Lifecycle

    override func halt(clearStorage: Bool) {
        sendEventsWithSaveIfNeeded()
        flushEvents()
        clearAllTimedEvents()
        eventLock.lock()
        previousEventID = nil
        previousEventName = nil
        eventLock.unlock()
    }
}
