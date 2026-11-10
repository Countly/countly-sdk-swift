//
//  FeedbackTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
#if canImport(WebKit)
import WebKit
#endif
@testable import Countly

/// Feedback widgets: what the SDK asks the server for, and what it reports back.
///
/// The presentation itself is a web view and belongs to a UI test, so these cover
/// the two halves around it: the fetch that discovers which widgets exist, and the
/// reserved events that carry a result back once one has been answered.
final class FeedbackTests: CountlyBaseTestCase {

    private static let widgetList = """
    {"result": [
      {"_id": "w1", "type": "survey", "name": "Onboarding survey", "tg": ["signup"]},
      {"_id": "w2", "type": "nps", "name": "NPS", "tg": []},
      {"_id": "w3", "type": "rating", "name": "Rate us", "tg": ["cart"]}
    ]}
    """

    /// Every event the SDK recorded, whatever its key.
    private func events(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
    }

    // MARK: - Discovering widgets

    func testTheWidgetListIsFetchedAndParsedIntoItsThreeTypes() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: Self.widgetList)
        let countly = startInstance()

        let fetched = expectation(description: "the widget list arrives")
        var widgets: [CountlyFeedbackWidget] = []
        countly.feedback.getAvailableFeedbackWidgets { result, error in
            XCTAssertNil(error)
            widgets = result ?? []
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: 5)

        XCTAssertEqual(widgets.map(\.id), ["w1", "w2", "w3"])
        XCTAssertEqual(widgets.map(\.type), [.survey, .nps, .rating])
        XCTAssertEqual(widgets.first?.name, "Onboarding survey")
        XCTAssertEqual(widgets.first?.tags, ["signup"])
    }

    /// The fetch is an instant request on the read endpoint: a widget nobody is
    /// waiting for is not worth queueing, and one somebody is waiting for cannot
    /// afford to be.
    func testTheWidgetListIsFetchedImmediatelyRatherThanThroughTheQueue() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: Self.widgetList)
        let countly = startInstance()

        let fetched = expectation(description: "the widget list arrives")
        countly.feedback.getAvailableFeedbackWidgets { _, _ in fetched.fulfill() }
        wait(for: [fetched], timeout: 5)

        guard let request = MockURLProtocol.requests.last(where: { $0.query.contains("method=feedback") }) else {
            XCTFail("a widget list request should have gone out")
            return
        }
        XCTAssertEqual(request.path, "/o/sdk")
        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "method").isEmpty)
    }

    func testAResponseWithoutAResultFieldIsReportedAsAnError() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"something": "else"}"#)
        let countly = startInstance()

        let fetched = expectation(description: "the fetch reports back")
        countly.feedback.getAvailableFeedbackWidgets { widgets, error in
            XCTAssertEqual(widgets?.count, 0)
            XCTAssertNotNil(error)
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: 5)
    }

    /// Every refusal reports back, with an empty list and the reason. A completion
    /// handler that is captured and never called leaves the caller waiting for the
    /// life of the process.
    func testEveryRefusalStillCallsTheCompletionHandler() {
        let cases: [(String, (CountlyConfig) -> Void)] = [
            ("no consent", { $0.requiresConsent = true }),
            ("temporary device ID", { $0.temporaryDeviceIDMode = true; $0.deviceID = nil }),
            ("networking off", {
                $0.sdkBehaviorSettings = ServerConfigBuilder().networking(false).json()
            }),
        ]

        for (label, adjust) in cases {
            let countly = startInstance(adjust)
            let reported = expectation(description: "the fetch reports back with \(label)")
            countly.feedback.getAvailableFeedbackWidgets { widgets, error in
                XCTAssertEqual(widgets?.count, 0, label)
                XCTAssertNotNil(error, label)
                reported.fulfill()
            }
            wait(for: [reported], timeout: 5)
        }
    }

    /// A presentation that cannot happen still answers, so the caller is not left
    /// waiting for a widget that will never appear.
    func testAPresentationThatCannotHappenReportsAFailure() {
        let countly = startInstance { $0.requiresConsent = true }

        let failed = expectation(description: "the presentation reports a failure")
        countly.feedback.presentNPS(nil) { state in
            XCTAssertEqual(state, .failed)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5)
    }

    // MARK: - Recording a rating

    /// The rating widget reports under the historical `[CLY]_star_rating` key,
    /// which is what the dashboard's rating report reads.
    func testARatingIsRecordedUnderTheReservedRatingKey() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.feedback.recordRatingWidget(id: "w3",
                                            rating: 4,
                                            email: "a@b.c",
                                            comment: "works well",
                                            userCanBeContacted: true)

        let recorded = events(of: countly).filter { $0["key"] as? String == "[CLY]_star_rating" }
        XCTAssertEqual(recorded.count, 1)

        let segmentation = (recorded[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.int(segmentation["rating"]), 4)
        XCTAssertEqual(segmentation["widget_id"] as? String, "w3")
        XCTAssertEqual(segmentation["email"] as? String, "a@b.c")
        XCTAssertEqual(segmentation["comment"] as? String, "works well")
        XCTAssertEqual(TestUtils.describe(segmentation["contactMe"] ?? ""), "1")
        XCTAssertNotNil(segmentation["platform"])
        XCTAssertNotNil(segmentation["app_version"])
    }

    func testARatingWithNoWidgetIDIsDropped() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.feedback.recordRatingWidget(id: "",
                                            rating: 4,
                                            email: nil,
                                            comment: nil,
                                            userCanBeContacted: false)

        XCTAssertTrue(events(of: countly).isEmpty)
    }

    /// The legacy call never moves a rating into the range: an answer outside it is
    /// not one the user gave.
    func testARatingOutsideOneToFiveIsDropped() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.feedback.recordRatingWidget(id: "w3", rating: 0, email: nil, comment: nil, userCanBeContacted: false)
        countly.feedback.recordRatingWidget(id: "w3", rating: 6, email: nil, comment: nil, userCanBeContacted: false)

        XCTAssertTrue(events(of: countly).isEmpty)
        XCTAssertEqual(logCodeCount(HealthLogCode.invalidValue, of: countly), 2)
    }

    func testTheOptionalContactFieldsCanBeOmitted() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.feedback.recordRatingWidget(id: "w3",
                                            rating: 5,
                                            email: nil,
                                            comment: nil,
                                            userCanBeContacted: false)

        let segmentation = (events(of: countly).first?["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.int(segmentation["rating"]), 5)
        XCTAssertNil(segmentation["email"])
        XCTAssertNil(segmentation["comment"])
    }

    // MARK: - Recording a widget result

    /// Answering a widget records a reserved event named after the widget's type,
    /// which is how the dashboard separates surveys from NPS responses.
    func testAnsweringAWidgetRecordsAnEventNamedAfterItsType() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: Self.widgetList)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let fetched = expectation(description: "the widget list arrives")
        var widgets: [CountlyFeedbackWidget] = []
        countly.feedback.getAvailableFeedbackWidgets { result, _ in
            widgets = result ?? []
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: 5)

        widgets.first { $0.type == .survey }?.recordResult(["answer": "yes"])
        widgets.first { $0.type == .nps }?.recordResult(["rating": 9])

        let keys = events(of: countly).compactMap { $0["key"] as? String }
        XCTAssertTrue(keys.contains("[CLY]_survey"))
        XCTAssertTrue(keys.contains("[CLY]_nps"))
    }

    /// The server adds NPS ratings into its score, so a rating that is missing, not
    /// a whole number or out of range is not recorded at all.
    func testAManualResultNeedsARatingInTheRangeOfItsType() throws {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        let nps = try XCTUnwrap(countly.feedback.widget(from: ["_id": "w2", "type": "nps"]))
        let rating = try XCTUnwrap(countly.feedback.widget(from: ["_id": "w3", "type": "rating"]))

        nps.recordResult(["rating": 11])
        nps.recordResult(["rating": 7.5])
        nps.recordResult(["rating": "8"])
        nps.recordResult(["comment": "no rating"])
        rating.recordResult(["rating": 0])
        XCTAssertTrue(events(of: countly).isEmpty)
        XCTAssertEqual(logCodeCount(HealthLogCode.invalidValue, of: countly), 5)

        nps.recordResult(["rating": 0, "": "dropped", "comment": NSNull()])
        rating.recordResult(["rating": 5])

        let recorded = events(of: countly)
        XCTAssertEqual(recorded.count, 2)
        let npsSegmentation = (recorded.first { $0["key"] as? String == "[CLY]_nps" }?["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.int(npsSegmentation["rating"]), 0)
        XCTAssertNil(npsSegmentation[""])
        XCTAssertNil(npsSegmentation["comment"])
    }

    /// A nil result means the widget was closed without being answered, which is
    /// itself worth reporting: it is the difference between a widget nobody saw
    /// and one everybody dismissed.
    func testClosingAWidgetWithoutAnsweringIsReportedAsAClose() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: Self.widgetList)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let fetched = expectation(description: "the widget list arrives")
        var widgets: [CountlyFeedbackWidget] = []
        countly.feedback.getAvailableFeedbackWidgets { result, _ in
            widgets = result ?? []
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: 5)

        widgets.first { $0.type == .survey }?.recordResult(nil)

        let survey = events(of: countly).first { $0["key"] as? String == "[CLY]_survey" }
        let segmentation = (survey?["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.describe(segmentation["closed"] ?? ""), "1")
    }

    // MARK: - Choosing which widget to present

    /// Fetches the list and hands back the widgets, so the resolution tests can
    /// work from the same data the SDK sees.
    private func fetchWidgets(_ countly: CountlyInstance) -> [CountlyFeedbackWidget] {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: Self.widgetList)
        let fetched = expectation(description: "the widget list arrives")
        var widgets: [CountlyFeedbackWidget] = []
        countly.feedback.getAvailableFeedbackWidgets { result, _ in
            widgets = result ?? []
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: TestUtils.asyncTimeout)
        return widgets
    }

    /// Asking for a kind rather than a specific widget is the simple call, and it
    /// resolves to the first of that kind.
    func testAskingForATypeWithNoNamePresentsTheFirstOfThatType() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: Self.widgetList)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.feedback.presentSurvey()
        countly.feedback.presentNPS()
        countly.feedback.presentRating()

        // The list is fetched once per presentation attempt, which is what proves
        // each call got as far as resolving a widget.
        TestUtils.waitUntil("every presentation resolves a widget") {
            MockURLProtocol.requests.filter { $0.query.contains("method=feedback") }.count >= 3
        }
    }

    /// A name, an ID and a tag all identify a widget, because an integration may
    /// know any one of the three.
    func testAWidgetCanBeIdentifiedByNameByIDOrByTag() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startInstance()
        let widgets = fetchWidgets(countly)

        XCTAssertEqual(FeedbackModule.widget(in: widgets, matching: "Onboarding survey")?.id, "w1")
        XCTAssertEqual(FeedbackModule.widget(in: widgets, matching: "w2")?.type, .nps)
        XCTAssertEqual(FeedbackModule.widget(in: widgets, matching: "cart")?.id, "w3")
    }

    /// An ID wins over a name, a name over a tag, and a value that matches nothing
    /// never falls back to another widget.
    func testAnIDMatchWinsOverANameAndANameOverATag() throws {
        let countly = startInstance()
        let byTag = try XCTUnwrap(countly.feedback.widget(from: ["_id": "a", "type": "nps", "name": "x", "tg": ["target"]]))
        let byName = try XCTUnwrap(countly.feedback.widget(from: ["_id": "b", "type": "nps", "name": "target"]))
        let byID = try XCTUnwrap(countly.feedback.widget(from: ["_id": "target", "type": "nps", "name": "y"]))

        XCTAssertEqual(FeedbackModule.widget(in: [byTag, byName, byID], matching: "target")?.id, "target")
        XCTAssertEqual(FeedbackModule.widget(in: [byTag, byName], matching: "target")?.id, "b")
        XCTAssertEqual(FeedbackModule.widget(in: [byTag], matching: "target")?.id, "a")
        XCTAssertNil(FeedbackModule.widget(in: [byTag, byName, byID], matching: "nothing-like-it"))
        XCTAssertEqual(FeedbackModule.widget(in: [byTag, byName], matching: nil)?.id, "a")
    }

    /// A list the SDK cannot make sense of yields no widgets rather than a
    /// half-parsed one.
    func testWidgetsMissingTheirRequiredFieldsAreDropped() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: """
        {"result": [
          {"type": "survey", "name": "no id"},
          {"_id": "w9", "name": "no type"},
          {"_id": "w8", "type": "not-a-real-type", "name": "unknown type"},
          {"_id": "w7", "type": "survey", "name": "fine"}
        ]}
        """)
        let countly = startInstance()

        let fetched = expectation(description: "the widget list arrives")
        var widgets: [CountlyFeedbackWidget] = []
        countly.feedback.getAvailableFeedbackWidgets { result, _ in
            widgets = result ?? []
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: TestUtils.asyncTimeout)

        XCTAssertEqual(widgets.map(\.id), ["w7"])
    }

    // MARK: - Widget data

    /// A widget's definition is fetched separately from the list, because the list
    /// carries only enough to choose between them.
    func testAWidgetsDefinitionIsFetchedFromItsOwnEndpoint() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startInstance()
        guard let widget = fetchWidgets(countly).first else {
            XCTFail("the widget list should not be empty")
            return
        }

        MockURLProtocol.respond(pathContaining: "/o/surveys",
                                json: #"{"name": "Onboarding survey", "questions": []}"#)

        let loaded = expectation(description: "the widget data arrives")
        widget.getWidgetData { data, error in
            XCTAssertNil(error)
            XCTAssertEqual(data?["name"] as? String, "Onboarding survey")
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: TestUtils.asyncTimeout)

        guard let request = MockURLProtocol.requests.last(where: { $0.path.contains("/o/surveys") }) else {
            XCTFail("a widget data request should have gone out")
            return
        }
        XCTAssertTrue(request.path.hasSuffix("/survey/widget"),
                      "the path names the widget type, path was \(request.path)")
        let parsed = TestUtils.parseQuery(request.query)
        XCTAssertEqual(parsed["widget_id"] as? String, "w1")
        XCTAssertEqual(parsed["shown"] as? String, "1")
    }

    func testAFailedWidgetDataFetchReportsAnError() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startInstance()
        guard let widget = fetchWidgets(countly).first else {
            XCTFail("the widget list should not be empty")
            return
        }

        MockURLProtocol.reset()  // nothing answers, so the fetch fails

        let reported = expectation(description: "the fetch reports back")
        widget.getWidgetData { data, error in
            XCTAssertNil(data)
            XCTAssertNotNil(error)
            reported.fulfill()
        }
        wait(for: [reported], timeout: TestUtils.asyncTimeout)
    }

    // MARK: - Putting a widget on screen

    /// Presenting a widget builds its URL and puts it in an overlay above the whole
    /// application. The page cannot load without a server, so it comes back down
    /// again, which is the path worth checking: a widget that cannot load must not
    /// be left covering the application. It was never shown, so the caller hears it
    /// failed and no "closed" event is recorded, which could hide the widget from
    /// that user for good.
    func testPresentingAWidgetPutsItOnScreenAndTakesItDownWhenItCannotLoad() throws {
        try skipUnlessNetworkIsInterceptable()
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("feedback widgets are presented in a web view, which this platform has no overlay for")
        #else
        let countly = startInstance { $0.eventSendThreshold = 1 }
        guard let widget = fetchWidgets(countly).first else {
            XCTFail("the widget list should not be empty")
            return
        }

        let failed = expectation(description: "the widget reports it could not be shown")
        failed.assertForOverFulfill = false
        widget.present(callback: { state in
            if state == .failed { failed.fulfill() }
        })

        wait(for: [failed], timeout: TestUtils.webKitTimeout)
        TestUtils.pump(0.3)
        XCTAssertFalse(events(of: countly).contains { $0["key"] as? String == "[CLY]_survey" },
                       "a widget that never appeared was recorded as closed")
        #endif
    }

    /// The appear and dismiss blocks are the older shape of the same callback, and
    /// both still have to fire.
    func testTheAppearAndDismissBlocksAreBothCalled() throws {
        try skipUnlessNetworkIsInterceptable()
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("feedback widgets are presented in a web view, which this platform has no overlay for")
        #else
        let countly = startInstance()
        guard let widget = fetchWidgets(countly).first else {
            XCTFail("the widget list should not be empty")
            return
        }

        let dismissed = expectation(description: "the widget reports it was dismissed")
        dismissed.assertForOverFulfill = false
        widget.present(appearBlock: nil, dismissBlock: { dismissed.fulfill() })

        wait(for: [dismissed], timeout: TestUtils.webKitTimeout)
        #endif
    }

    /// Dismissing a widget the user saw without answering it is itself worth
    /// reporting: it is the difference between a widget nobody saw and one
    /// everybody closed.
    func testDismissingAWidgetThatAppearedRecordsItAsClosed() throws {
        try skipUnlessNetworkIsInterceptable()
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("feedback widgets are presented in a web view, which this platform has no overlay for")
        #else
        let countly = startInstance { $0.eventSendThreshold = 1 }
        guard let widget = fetchWidgets(countly).first else {
            XCTFail("the widget list should not be empty")
            return
        }

        let appeared = expectation(description: "the widget reports it appeared")
        appeared.assertForOverFulfill = false
        let closed = expectation(description: "the widget reports it closed")
        closed.assertForOverFulfill = false
        widget.present(callback: { state in
            if state == .appeared { appeared.fulfill() }
            if state == .closed { closed.fulfill() }
        })

        // The server's page cannot load here, so a local one takes its place.
        let feedback = core(of: countly).modules.feedback
        TestUtils.waitUntil("the widget is put in an overlay") { !feedback.presentedWidgetManagers.isEmpty }
        let manager = try XCTUnwrap(feedback.presentedWidgetManagers.first as? WebViewManager)
        let page: WKWebView? = manager.webView
        page?.loadHTMLString("<html><body>ok</body></html>", baseURL: URL(string: "https://example.com/"))
        wait(for: [appeared], timeout: TestUtils.webKitTimeout)

        manager.close()
        wait(for: [closed], timeout: TestUtils.webKitTimeout)

        TestUtils.waitUntil("the dismissal is recorded") {
            self.events(of: countly).contains { $0["key"] as? String == "[CLY]_survey" }
        }
        let survey = events(of: countly).first { $0["key"] as? String == "[CLY]_survey" }
        XCTAssertEqual(TestUtils.describe((survey?["segmentation"] as? [String: Any])?["closed"] ?? ""), "1")
        #endif
    }

    /// A widget refused because another overlay is on screen was never seen, so
    /// the caller hears it closed while no dismissal is recorded: that would count
    /// as an answer the user never gave.
    func testAWidgetRefusedForAnotherOverlayRecordsNoDismissal() throws {
        try skipUnlessNetworkIsInterceptable()
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("feedback widgets are presented in a web view, which this platform has no overlay for")
        #else
        let countly = startInstance { $0.eventSendThreshold = 1 }
        let widget = try XCTUnwrap(fetchWidgets(countly).first)
        let overlayOnScreen = WebViewManager(core: core(of: countly))
        XCTAssertTrue(WebViewManager.gate.claim(overlayOnScreen))
        defer { WebViewManager.gate.release(overlayOnScreen) }

        let failed = expectation(description: "the caller hears the widget could not be shown")
        widget.present(callback: { state in
            if state == .failed { failed.fulfill() }
        })
        wait(for: [failed], timeout: TestUtils.asyncTimeout)
        TestUtils.pump(0.3)

        XCTAssertFalse(events(of: countly).contains { $0["key"] as? String == "[CLY]_survey" },
                       "a widget nobody saw was recorded as dismissed")
        #endif
    }

    /// A widget cannot be presented without feedback consent, whatever the host
    /// application asks.
    func testAWidgetIsNotPresentedWithoutConsent() throws {
        try skipUnlessNetworkIsInterceptable()
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("feedback widgets are presented in a web view, which this platform has no overlay for")
        #else
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: Self.widgetList)
        let countly = startInstance { $0.requiresConsent = true }

        // The list itself is refused without consent, so nothing can be presented.
        let reported = expectation(description: "the fetch reports back")
        countly.feedback.getAvailableFeedbackWidgets { widgets, error in
            XCTAssertEqual(widgets?.count, 0)
            XCTAssertNotNil(error)
            reported.fulfill()
        }
        wait(for: [reported], timeout: TestUtils.asyncTimeout)
        #endif
    }

    // MARK: - Consent

    /// The legacy rating call answers to the "star-rating" consent; the "feedback"
    /// consent covers the widgets, not this call.
    func testTheLegacyRatingCallNeedsTheStarRatingConsent() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.requiresConsent = true
        }

        countly.feedback.recordRatingWidget(id: "w3", rating: 4, email: nil, comment: nil, userCanBeContacted: false)
        XCTAssertTrue(events(of: countly).isEmpty)

        countly.consent.giveConsent(for: .feedback)
        countly.feedback.recordRatingWidget(id: "w3", rating: 4, email: nil, comment: nil, userCanBeContacted: false)
        XCTAssertTrue(events(of: countly).isEmpty, "feedback consent does not cover the legacy call")

        countly.consent.giveConsent(for: .starRating)
        countly.feedback.recordRatingWidget(id: "w3", rating: 4, email: nil, comment: nil, userCanBeContacted: false)
        XCTAssertEqual(events(of: countly).filter { $0["key"] as? String == "[CLY]_star_rating" }.count, 1)
    }

    // MARK: - Wire names

    func testTheWidgetTypeWireNamesAreTheOnesTheServerExpects() {
        XCTAssertEqual(FeedbackWidgetType.survey.wireName, "survey")
        XCTAssertEqual(FeedbackWidgetType.nps.wireName, "nps")
        XCTAssertEqual(FeedbackWidgetType.rating.wireName, "rating")
    }

    // MARK: - Global content segmentation

    /// The global content segmentation rides on every rating and widget result.
    /// It can neither overwrite a key the event reports itself nor set a key the
    /// server reads to count and attribute the result, and clearing it stops it.
    func testTheGlobalContentSegmentationTravelsWithRatingsAndWidgetResults() throws {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        countly.content.setGlobalContentSegmentation([
            "campaign": "spring", "answer": "global", "widget_id": "hijacked", "answ-q1": "forged", "rating": 1,
        ])

        countly.feedback.recordRatingWidget(id: "w3", rating: 4, email: nil, comment: nil, userCanBeContacted: false)
        let survey = try XCTUnwrap(countly.feedback.widget(from: ["_id": "w1", "type": "survey"]))
        survey.recordResult(["answer": "yes"])

        let rating = try XCTUnwrap(segmentation(of: "[CLY]_star_rating", in: countly))
        XCTAssertEqual(rating["campaign"] as? String, "spring")
        XCTAssertEqual(rating["answer"] as? String, "global", "a key the rating does not report itself is the global one")
        XCTAssertEqual(rating["widget_id"] as? String, "w3", "a reserved key is never taken from the global segmentation")
        XCTAssertEqual(TestUtils.int(rating["rating"]), 4)
        XCTAssertNil(rating["answ-q1"])

        let result = try XCTUnwrap(segmentation(of: "[CLY]_survey", in: countly))
        XCTAssertEqual(result["campaign"] as? String, "spring")
        XCTAssertEqual(result["answer"] as? String, "yes", "the result's own value wins")
        XCTAssertEqual(result["widget_id"] as? String, "w1")

        countly.content.setGlobalContentSegmentation(nil)
        countly.feedback.recordRatingWidget(id: "w3", rating: 2, email: nil, comment: nil, userCanBeContacted: false)
        let afterClear = events(of: countly).filter { $0["key"] as? String == "[CLY]_star_rating" }.last
        XCTAssertNil((afterClear?["segmentation"] as? [String: Any])?["campaign"])
    }

    /// The global segmentation fills only the room the segmentation limit leaves,
    /// so it never pushes out a key the event reports itself.
    func testTheGlobalContentSegmentationNeverDisplacesTheEventsOwnKeys() throws {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkInternalLimits.maxSegmentationValues = 6
        }
        countly.content.setGlobalContentSegmentation(["g1": 1, "g2": 2, "g3": 3])

        countly.feedback.recordRatingWidget(id: "w3", rating: 5, email: nil, comment: nil, userCanBeContacted: true)

        let rating = try XCTUnwrap(segmentation(of: "[CLY]_star_rating", in: countly))
        for key in ["platform", "app_version", "widget_id", "rating", "contactMe"] {
            XCTAssertNotNil(rating[key], "the rating's own [\(key)] was pushed out")
        }
        XCTAssertEqual(rating.count, 6)
        XCTAssertEqual(TestUtils.int(rating["g1"]), 1, "global keys fill the room left in key order")
    }

    /// The widget page records its answers itself, so the global segmentation
    /// travels to it as `sg` inside the `custom` parameter, reserved keys dropped.
    func testTheWidgetPageIsHandedTheGlobalContentSegmentation() throws {
        let countly = startInstance()
        let feedback = core(of: countly).modules.feedback
        let widget = try XCTUnwrap(countly.feedback.widget(from: ["_id": "w2", "type": "nps"]))
        let surface = CGSize(width: 320, height: 480)

        let plain = try XCTUnwrap(feedback.widgetURL(for: widget, surface: surface))
        XCTAssertNil(try custom(of: plain)["sg"])

        countly.content.setGlobalContentSegmentation(["campaign": "spring", "closed": true])
        let url = try XCTUnwrap(feedback.widgetURL(for: widget, surface: surface))

        let sg = try XCTUnwrap(try custom(of: url)["sg"] as? [String: Any])
        XCTAssertEqual(sg["campaign"] as? String, "spring")
        XCTAssertNil(sg["closed"], "a reserved key never reaches the page")
    }

    /// The segmentation of the last recorded event named `key`.
    private func segmentation(of key: String, in instance: CountlyInstance) -> [String: Any]? {
        events(of: instance).last { $0["key"] as? String == key }?["segmentation"] as? [String: Any]
    }

    /// The decoded `custom` object of a widget URL.
    private func custom(of url: URL) throws -> [String: Any] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let raw = try XCTUnwrap(components.queryItems?.first { $0.name == "custom" }?.value)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    // MARK: - Rebuilding a widget a caller already holds

    /// A bridge SDK keeps its widget list on its own side, so the widget comes back
    /// as the dictionary the server sent rather than as an object this SDK handed
    /// out. Rebuilt that way it has to be the same widget: same fields, and a result
    /// recorded on it lands as the same reserved event.
    func testAWidgetRebuiltFromItsDescriptionRecordsTheSameResultAsAFetchedOne() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let widget = countly.feedback.widget(from: [
            "_id": "w1",
            "type": "survey",
            "name": "Onboarding survey",
            "tg": ["signup"],
            "wv": "2",
        ])

        XCTAssertEqual(widget?.id, "w1")
        XCTAssertEqual(widget?.type, .survey)
        XCTAssertEqual(widget?.name, "Onboarding survey")
        XCTAssertEqual(widget?.tags, ["signup"])
        XCTAssertEqual(widget?.widgetVersion, "2")

        widget?.recordResult(["answer": "yes"])

        let recorded = events(of: countly).first { $0["key"] as? String == "[CLY]_survey" }
        XCTAssertNotNil(recorded, "a rebuilt widget reports through the instance that built it")
        XCTAssertEqual((recorded?["segmentation"] as? [String: Any])?["answer"] as? String, "yes")
        XCTAssertEqual((recorded?["segmentation"] as? [String: Any])?["widget_id"] as? String, "w1")
    }

    /// The dictionary crosses a bridge, so it is whatever the other side stored. A
    /// description that cannot name a widget produces nothing rather than a widget
    /// that reports against an empty ID.
    func testADescriptionThatNamesNoWidgetIsRefused() {
        let countly = startInstance()

        XCTAssertNil(countly.feedback.widget(from: ["type": "survey", "name": "no id"]))
        XCTAssertNil(countly.feedback.widget(from: ["_id": "w9", "name": "no type"]))
        XCTAssertNil(countly.feedback.widget(from: ["_id": "w8", "type": "not-a-real-type"]))
        XCTAssertNotNil(countly.feedback.widget(from: ["_id": "w7", "type": "rating"]))
    }
}
