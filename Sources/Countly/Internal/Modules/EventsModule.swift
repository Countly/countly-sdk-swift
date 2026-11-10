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
/// Events are held in the event queue and sent together once enough of them
/// accumulate, because one request per event would be wasteful and would lose the
/// ordering the server relies on. They are also flushed whenever something else
/// has to go out first, so an event recorded before a session end is never
/// reported after it. The event queue is written to storage on every change, so
/// recorded events survive the application being killed before they are sent.
final class EventsModule: ModuleBase {

    override class var moduleName: String { "Events" }

    /// The most events the event queue holds: reaching it moves them into a
    /// request, whatever the send threshold says.
    static let maxQueuedEvents = 1000

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

    /// Reads the event queue a previous run stored.
    override init(core: SDKCore) {
        super.init(core: core)
        restoreRecordedEvents()
    }

    /// The recorded events not yet moved into the request queue, each serialized
    /// the way it will be sent. Oldest first.
    ///
    /// Diagnostic surface. See ``EventsAPI/recordedEvents()``.
    var recordedEventsJSON: [String] {
        eventLock.lock()
        let snapshot = recordedEvents
        eventLock.unlock()
        return snapshot.compactMap { CountlyJSON.string(from: $0.dictionaryRepresentation, logger: log) }
    }

    /// Events sitting in the event queue and not yet moved into the request queue.
    /// Read by the user profile module, which has to report the queue depth it is
    /// about to flush.
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
    ///
    /// A reserved `[CLY]_` key answers to the consent of the feature it belongs to,
    /// and the behavior settings' custom event switch and filters do not apply to
    /// it. Any other key is a custom event.
    func recordEvent(_ key: String,
                     segmentation: [String: Any]? = nil,
                     count: Int = 1,
                     sum: Double = 0,
                     duration: TimeInterval = 0) {
        logI("recordEvent", "recording an event, key: [\(key)], segmentationKeyCount: [\(segmentation?.count ?? 0)], count: [\(count)], sum: [\(sum.logValue)], duration: [\(duration.logSeconds)]")

        guard !key.isEmpty else {
            logW("recordEvent", "omitting the call, the event key is nil or empty")
            core.healthTracker.recordLogCode(HealthLogCode.emptyEventKey, area: .events)
            return
        }

        let isReserved = ReservedEventKey.all.contains(key)
        if isReserved {
            guard hasConsentForReservedEvent(key) else {
                logD("recordEvent", "no consent given for the reserved event, it will not be recorded, key: [\(key)]")
                return
            }
            logD("recordEvent", "specific consent is given for the reserved event, it will be recorded, key: [\(key)]")
        } else {
            guard core.modules.consent.hasConsent(for: .events) else {
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
        }

        var count = count
        if count < 1 {
            logW("recordEvent", "the event count is below one, it is ignored and 1 is used, key: [\(key)], providedCount: [\(count)]")
            core.healthTracker.recordLogCode(HealthLogCode.eventValueIgnored, area: .events)
            count = 1
        }

        var duration = duration
        if duration < 0 {
            logW("recordEvent", "the event duration is negative, it is ignored and 0 is used, key: [\(key)], providedDuration: [\(duration.logSeconds)]")
            core.healthTracker.recordLogCode(HealthLogCode.eventValueIgnored, area: .events)
            duration = 0
        }

        let filtered = isReserved ? segmentation : core.serverConfig.filterSegmentation(segmentation, eventKey: key)
        let sanitized = limits.sanitized(filtered, "Event segmentation")

        let providedKeyCount = segmentation?.count ?? 0
        let acceptedKeyCount = sanitized?.count ?? 0
        if providedKeyCount != acceptedKeyCount {
            logD("recordEvent", "some segmentation entries were removed by the server config filter or the segmentation limits, key: [\(key)], providedKeyCount: [\(providedKeyCount)], acceptedKeyCount: [\(acceptedKeyCount)], acceptedKeys: [\(sanitized?.keys.sorted() ?? [])]")
        }
        logV("recordEvent", "event segmentation detail as recorded, key: [\(key)], segmentation: [\(sanitized ?? [:])]")

        record(key: key,
               segmentation: sanitized,
               count: count,
               sum: sum,
               duration: duration,
               id: nil,
               timestamp: core.clock.now())
    }

    /// Records a reserved event on behalf of the host application.
    ///
    /// The SDK's own callers resolve consent and build well formed segmentation
    /// before calling ``recordReservedEvent(_:segmentation:count:sum:duration:id:timestamp:)``,
    /// so a host reaching the same path gets those gates applied here: the owning
    /// feature's consent, as the Android SDK applies to every reserved key, and the
    /// SDK limits on the segmentation. A key that is not reserved is an ordinary
    /// event and takes the ordinary path, with its own consent and filters.
    func recordReservedEventFromHost(_ key: String,
                                     segmentation: [String: Any]?,
                                     count: Int,
                                     sum: Double,
                                     duration: TimeInterval) {
        guard ReservedEventKey.all.contains(key) else {
            logD("recordReservedEventFromHost", "the key is not reserved, it is recorded as a regular event, key: [\(key)]")
            recordEvent(key, segmentation: segmentation, count: count, sum: sum, duration: duration)
            return
        }
        guard hasConsentForReservedEvent(key) else {
            logD("recordReservedEventFromHost", "no consent for the feature owning the reserved event, it is not recorded, key: [\(key)]")
            return
        }
        recordReservedEvent(key,
                            segmentation: limits.sanitized(segmentation, "Reserved event segmentation"),
                            count: count,
                            sum: sum,
                            duration: duration)
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

        guard !key.isEmpty else {
            logW("startEvent", "omitting the call, the event key is nil or empty")
            core.healthTracker.recordLogCode(HealthLogCode.emptyEventKey, area: .events)
            return
        }

        guard core.modules.consent.hasConsent(for: .events) else {
            logD("startEvent", "no consent given for events, the timed event will not be started, key: [\(key)]")
            return
        }

        eventLock.lock()
        defer { eventLock.unlock() }

        guard startedEvents[key] == nil else {
            logW("startEvent", "timed event is not started, reason: a timed event with the same key is already started, key: [\(key)]")
            core.healthTracker.recordLogCode(HealthLogCode.eventAlreadyRunning, area: .events)
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

        guard !key.isEmpty else {
            logW("endEvent", "omitting the call, the event key is nil or empty")
            core.healthTracker.recordLogCode(HealthLogCode.emptyEventKey, area: .events)
            return
        }

        guard core.modules.consent.hasConsent(for: .events) else {
            logD("endEvent", "no consent given for events, the timed event will not be ended, key: [\(key)]")
            return
        }

        guard let event = takeTimedEvent(key) else {
            logW("endEvent", "omitting the call, the timed event was not started or was already ended, key: [\(key)]")
            logD("endEvent", "no timed event matched the key that was ended, these are the ones still running, key: [\(key)], startedTimedEventKeys: [\(startedTimedEventKeys)]")
            core.healthTracker.recordLogCode(HealthLogCode.eventNotRunning, area: .events)
            return
        }

        // Read from the same clock that stamped the start. The monotonic clock runs
        // ahead of the wall clock under a burst, so mixing the two can produce a
        // negative duration.
        let duration = max(0, core.clock.now() - event.timestamp)
        logD("endEvent", "the timed event is ended and its duration measured, key: [\(key)], duration: [\(duration.logSeconds)], remainingTimedEventKeys: [\(startedTimedEventKeys)]")
        recordEvent(key, segmentation: segmentation, count: count, sum: sum, duration: duration)
    }

    /// Discards a timer without recording anything.
    func cancelEvent(_ key: String) {
        logI("cancelEvent", "cancelling a timed event, key: [\(key)]")

        guard !key.isEmpty else {
            logW("cancelEvent", "omitting the call, the event key is nil or empty")
            core.healthTracker.recordLogCode(HealthLogCode.emptyEventKey, area: .events)
            return
        }

        guard core.modules.consent.hasConsent(for: .events) else {
            logD("cancelEvent", "no consent given for events, the timed event will not be cancelled, key: [\(key)]")
            return
        }

        guard takeTimedEvent(key) != nil else {
            logW("cancelEvent", "nothing to cancel, no timed event is running for the key, key: [\(key)]")
            core.healthTracker.recordLogCode(HealthLogCode.cancelledEventNotRunning, area: .events)
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

    /// Whether the consent a reserved event answers to is given. A rating result
    /// answers to the "feedback" consent or to the legacy "star-rating" one.
    private func hasConsentForReservedEvent(_ key: String) -> Bool {
        let consent = core.modules.consent
        if key == ReservedEventKey.ratingWidget {
            return consent.hasConsent(for: .feedback) || consent.hasConsent(for: .starRating)
        }
        guard let feature = ReservedEventKey.owningFeature[key] else { return consent.hasConsent(for: .events) }
        return consent.hasConsent(for: feature)
    }

    /// Builds the event, chains it, and hands it to the queue.
    private func record(key: String,
                        segmentation: [String: Any]?,
                        count: Int,
                        sum: Double,
                        duration: TimeInterval,
                        id: String?,
                        timestamp: TimeInterval) {
        guard !key.isEmpty else {
            logW("record", "omitting the call, the event key is nil or empty")
            core.healthTracker.recordLogCode(HealthLogCode.emptyEventKey, area: .events)
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

        event.count = max(count, 1)
        event.sum = sum
        event.timestamp = timestamp
        event.hourOfDay = core.clock.hourOfDay()
        event.dayOfWeek = core.clock.dayOfWeek()
        event.duration = max(0, duration)

        // Already filtered by `sanitized` on the public path; reserved events pass
        // SDK-built segmentation, which is well formed by construction.
        var filteredSegmentation = segmentation ?? [:]

        if isReserved {
            event.segmentation = processSegmentation(&filteredSegmentation, eventKey: key)
            let sendsAtOnce = ReservedEventKey.sentImmediately.contains(key)
            if sendsAtOnce {
                logD("record", "the reserved event is sent right away rather than with the next batch, key: [\(key)]")
            }
            enqueue(event,
                    callback: journeyTriggerCallbackForReserved(key: key, segmentation: event.segmentation),
                    sendsAtOnce: sendsAtOnce)
            return
        }

        let truncatedKey = limits.truncatedKey(key, "Event key")

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

        enqueue(event, callback: isJourneyTrigger ? journeyTriggerCallback() : nil, sendsAtOnce: false)
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
                segmentation[SegKey.visibility] = AppState.isForeground ? 1 : 0
            }
        }

        return segmentation.isEmpty ? nil : segmentation
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

    /// Adds an event to the batch and sends it when the batch is full, when the
    /// event queue holds ``maxQueuedEvents``, when the event is sent at once, or
    /// when a callback demands an immediate answer.
    private func enqueue(_ event: CountlyEvent, callback: RequestCallback?, sendsAtOnce: Bool) {
        eventLock.lock()

        // Unsent user properties have to reach the server before the event does,
        // or the event is attributed to a stale profile.
        if core.modules.userProfile.hasUnsyncedChanges {
            logD("enqueue", "unsynced user properties will be saved before this event is queued, so the event is attributed to the new profile, eventKey: [\(event.key)]")
            core.modules.userProfile.save()
        }

        recordedEvents.append(event)
        let pending = recordedEvents.count
        persistRecordedEventsLocked()
        eventLock.unlock()

        logD("enqueue", "event is added to the event queue, pendingEventCount: [\(pending)], eventSendThreshold: [\(sendThreshold)], callbackProvided: [\(callback != nil)]")

        let reason: String
        if callback != nil {
            reason = "a request callback is attached"
        } else if sendsAtOnce {
            reason = "the event is sent right away"
        } else if pending >= sendThreshold {
            reason = "the send threshold is reached"
        } else if pending >= Self.maxQueuedEvents {
            reason = "the event queue holds its maximum number of events"
        } else {
            return
        }

        logD("enqueue", "the event queue will be sent, reason: [\(reason)], pendingEventCount: [\(pending)]")
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
            logD("serializeRecordedEvents", "the event queue is empty, no event request will be created")
            return nil
        }

        let payload = recordedEvents.map(\.dictionaryRepresentation)
        logD("serializeRecordedEvents", "serializing the recorded events for the next request, eventCount: [\(payload.count)]")
        recordedEvents.removeAll()
        persistRecordedEventsLocked()

        let escaped = CountlyJSON.escapedString(from: payload, logger: log)
        if escaped.isEmpty {
            // The serializer reports the failure itself, so this only records what
            // was lost with it.
            logD("serializeRecordedEvents", "the recorded events could not be serialized and are gone from the event queue, eventCount: [\(payload.count)]")
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

    /// Moves the stored event queue into a request filed under a device ID other
    /// than the current one: the ID a previous run stored, before a reset of the
    /// stored device ID replaces it, so that user's events stay with that user.
    func moveRecordedEvents(intoRequestFor deviceID: String, typeValue: Int) {
        guard let events = serializeRecordedEvents() else { return }
        logD("moveRecordedEvents", "the stored events are filed under the previous device ID before it is replaced")
        let queryString = "\(core.network.builder.queryEssentials(deviceID: deviceID, typeValue: typeValue))&\(QS.events)=\(events)"
        core.network.enqueue(queryString)
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
            logD("flushEvents", "the event queue is dropped without being sent, droppedEventCount: [\(recordedEvents.count)]")
        }
        recordedEvents.removeAll()
        persistRecordedEventsLocked()
    }

    // MARK: - Storage

    /// Writes the event queue to storage. The caller holds `eventLock`.
    private func persistRecordedEventsLocked() {
        core.keyValueStore.recordedEvents = recordedEvents.compactMap {
            CountlyJSON.string(from: $0.dictionaryRepresentation, logger: nil)
        }
    }

    /// Reads the event queue a previous run stored and could not send, oldest
    /// first, so those events go out with the next batch.
    private func restoreRecordedEvents() {
        let stored = core.keyValueStore.recordedEvents
        guard !stored.isEmpty else { return }

        let restored = stored.compactMap { json -> CountlyEvent? in
            guard let dictionary = CountlyJSON.object(from: Data(json.utf8), logger: nil) as? [String: Any] else { return nil }
            return CountlyEvent(dictionary: dictionary)
        }

        eventLock.lock()
        recordedEvents = restored + recordedEvents
        eventLock.unlock()

        logD("restoreRecordedEvents", "events a previous run recorded and did not send are restored to the event queue, restoredEventCount: [\(restored.count)], storedEntryCount: [\(stored.count)]")
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
