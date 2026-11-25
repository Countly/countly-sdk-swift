//
//  ContentTriggerTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Content triggers: the `jt` key next to `c` in the behavior settings answer, and
/// the deprecated journey trigger events and views that apply without it.
///
/// A matched trigger sends the queued requests and then asks for content, up to
/// three times a second apart while the server has none.
final class ContentTriggerTests: CountlyBaseTestCase {

    private static let accepted = #"{"result": "Success"}"#

    /// Skips a test that waits for a content fetch: it needs a transport the test
    /// can see, and a web view, without which content is never fetched.
    private func skipUnlessContentIsFetched() throws {
        #if os(iOS) || os(visionOS) || os(macOS)
        try skipUnlessNetworkIsInterceptable()
        #else
        throw XCTSkip("content needs a web view, which tvOS and watchOS have no WebKit for")
        #endif
    }

    /// Answers the queue with success and every content fetch with no content.
    private func answerQueueAndContent() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        MockURLProtocol.respond { captured in
            captured.path == "/i" ? (200, Data(Self.accepted.utf8)) : nil
        }
    }

    private var contentRequestCount: Int {
        MockURLProtocol.requests.filter { $0.path.contains("/o/sdk/content") }.count
    }

    private var behaviorSettingsRequests: [MockURLProtocol.Captured] {
        MockURLProtocol.requests.filter { $0.query.contains("method=sc") }
    }

    /// Starts an instance with the given behavior settings and a high event
    /// threshold, so only a content trigger round sends the recorded events.
    private func startWithSettings(_ builder: ServerConfigBuilder, _ adjust: @escaping (CountlyConfig) -> Void = { _ in }) -> CountlyInstance {
        startInstance {
            $0.eventSendThreshold = 100
            $0.sdkBehaviorSettings = builder.json()
            adjust($0)
        }
    }

    /// Enters the content zone and waits for its own first fetch, which a new
    /// instance holds back by the content initial delay, so the counts a test
    /// compares are the trigger's alone.
    private func enterZoneAndSettle(_ countly: CountlyInstance) -> Int {
        countly.content.enterContentZone()
        TestUtils.waitUntil("the content zone's own first fetch goes out") { self.contentRequestCount >= 1 }
        TestUtils.pump(0.5)
        return contentRequestCount
    }

    // MARK: - Asking for the content triggers

    /// The behavior settings request asks for the content triggers with `jt=1`.
    func testTheSettingsRequestAsksForTheContentTriggers() throws {
        try skipUnlessContentIsFetched()
        answerQueueAndContent()

        _ = startInstance()

        TestUtils.waitUntil("the behavior settings request is sent") { !self.behaviorSettingsRequests.isEmpty }
        XCTAssertTrue(behaviorSettingsRequests[0].query.contains("jt=1"))
    }

    /// Content triggers given with the behavior settings are used and stored with them.
    func testTheContentTriggersAreStoredWithTheSettings() throws {
        let countly = startWithSettings(ServerConfigBuilder().contentTriggers(["e": ["purchase"], "v": ["Checkout"], "p": ["custom.plan"]]))

        let triggers = core(of: countly).serverConfig.contentTriggers
        XCTAssertEqual(triggers?.keys, ["purchase"])
        XCTAssertEqual(triggers?.views, ["Checkout"])
        XCTAssertEqual(triggers?.properties, ["custom.plan"])
        XCTAssertNotNil(core(of: countly).keyValueStore.serverConfig?["jt"])
    }

    /// With `disableAutoContentTriggers` the SDK neither asks for the content
    /// triggers nor follows the ones it was given.
    func testDisableAutoContentTriggersNeitherAsksNorFollows() throws {
        try skipUnlessContentIsFetched()
        answerQueueAndContent()

        let countly = startWithSettings(ServerConfigBuilder().contentTriggers(["e": ["purchase"]])) {
            $0.content.disableAutoContentTriggers = true
        }
        TestUtils.waitUntil("the behavior settings request is sent") { !self.behaviorSettingsRequests.isEmpty }
        XCTAssertFalse(behaviorSettingsRequests[0].query.contains("jt=1"))
        XCTAssertNil(core(of: countly).serverConfig.contentTriggers)

        let zoneRequests = enterZoneAndSettle(countly)
        countly.events.recordEvent("purchase")
        TestUtils.pump(2.5)

        XCTAssertEqual(contentRequestCount, zoneRequests)
    }

    // MARK: - Rounds

    /// A listed event, while the content zone is wanted, sends the recorded events
    /// first and then asks for content three times while there is none.
    func testAListedEventSendsTheQueueThenAsksForContent() throws {
        try skipUnlessContentIsFetched()
        answerQueueAndContent()

        let countly = startWithSettings(ServerConfigBuilder().contentTriggers(["e": ["purchase"]]))
        let zoneRequests = enterZoneAndSettle(countly)
        let requestsBefore = MockURLProtocol.requests.count

        countly.events.recordEvent("browse")
        countly.events.recordEvent("purchase")

        TestUtils.waitUntil("three content requests follow the trigger") { self.contentRequestCount >= zoneRequests + 3 }
        TestUtils.pump(1.5)
        XCTAssertEqual(contentRequestCount, zoneRequests + 3)

        let sinceTrigger = Array(MockURLProtocol.requests.dropFirst(requestsBefore))
        let eventsIndex = sinceTrigger.firstIndex { $0.path == "/i" && $0.query.contains("purchase") }
        let contentIndex = sinceTrigger.firstIndex { $0.path.contains("/o/sdk/content") }
        XCTAssertNotNil(eventsIndex)
        XCTAssertNotNil(contentIndex)
        if let eventsIndex, let contentIndex {
            XCTAssertLessThan(eventsIndex, contentIndex, "the events go out before content is asked for")
            XCTAssertTrue(sinceTrigger[eventsIndex].query.contains("browse"), "every held event goes out with the trigger")
        }
    }

    /// Content triggers apply only while the content zone is wanted.
    func testContentTriggersNeedTheContentZone() throws {
        try skipUnlessContentIsFetched()
        answerQueueAndContent()

        let countly = startWithSettings(ServerConfigBuilder().contentTriggers(["e": ["purchase"]]))
        countly.events.recordEvent("purchase")
        TestUtils.pump(2.5)

        XCTAssertEqual(contentRequestCount, 0)
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.path == "/i" && $0.query.contains("purchase") })
    }

    /// An answer with content triggers, even an empty one, makes the SDK ignore the
    /// journey trigger events.
    func testAnEmptyContentTriggerAnswerMakesTheJourneyTriggerEventsIgnored() throws {
        try skipUnlessContentIsFetched()
        answerQueueAndContent()

        let countly = startWithSettings(ServerConfigBuilder().journeyTriggerEvents(["purchase"]).contentTriggers([:]))
        let zoneRequests = enterZoneAndSettle(countly)

        countly.events.recordEvent("purchase")
        TestUtils.pump(2.5)

        XCTAssertEqual(contentRequestCount, zoneRequests)
    }

    /// The start and the end of a listed view each start a round, each with its own gap.
    func testTheStartAndTheEndOfAListedViewEachStartARound() throws {
        try skipUnlessContentIsFetched()
        answerQueueAndContent()

        let countly = startWithSettings(ServerConfigBuilder().contentTriggers(["v": ["Checkout"]]))
        let zoneRequests = enterZoneAndSettle(countly)

        countly.views.startView("Checkout")
        TestUtils.waitUntil("the start of the view starts a round") { self.contentRequestCount >= zoneRequests + 3 }
        TestUtils.pump(1.5)

        countly.views.stopView(name: "Checkout")
        TestUtils.waitUntil("the end of the view starts a round") { self.contentRequestCount >= zoneRequests + 6 }
    }
}
