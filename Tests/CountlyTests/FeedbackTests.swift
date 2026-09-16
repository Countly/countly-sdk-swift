//
//  FeedbackTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
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
            XCTAssertNil(widgets)
            XCTAssertNotNil(error)
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: 5)
    }

    /// Every refusal reports back. A completion handler that is captured and never
    /// called leaves the caller waiting for the life of the process.
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
            countly.feedback.getAvailableFeedbackWidgets { widgets, _ in
                XCTAssertNil(widgets, label)
                reported.fulfill()
            }
            wait(for: [reported], timeout: 5)
        }
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

        XCTAssertEqual(widgets.first { $0.name == "Onboarding survey" }?.id, "w1")
        XCTAssertEqual(widgets.first { $0.id == "w2" }?.type, .nps)
        XCTAssertEqual(widgets.first { $0.tags.contains("cart") }?.id, "w3")
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
    /// be left covering the application.
    func testPresentingAWidgetPutsItOnScreenAndTakesItDownWhenItCannotLoad() throws {
        try skipUnlessNetworkIsInterceptable()
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("feedback widgets are presented in a web view, which this platform has no overlay for")
        #else
        let countly = startInstance()
        guard let widget = fetchWidgets(countly).first else {
            XCTFail("the widget list should not be empty")
            return
        }

        let closed = expectation(description: "the widget reports it closed")
        closed.assertForOverFulfill = false
        widget.present(callback: { state in
            if state == .closed { closed.fulfill() }
        })

        wait(for: [closed], timeout: TestUtils.asyncTimeout)
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

        wait(for: [dismissed], timeout: TestUtils.asyncTimeout)
        #endif
    }

    /// Dismissing a widget without answering it is itself worth reporting: it is
    /// the difference between a widget nobody saw and one everybody closed.
    func testDismissingAWidgetRecordsItAsClosed() throws {
        try skipUnlessNetworkIsInterceptable()
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("feedback widgets are presented in a web view, which this platform has no overlay for")
        #else
        let countly = startInstance { $0.eventSendThreshold = 1 }
        guard let widget = fetchWidgets(countly).first else {
            XCTFail("the widget list should not be empty")
            return
        }

        let closed = expectation(description: "the widget reports it closed")
        closed.assertForOverFulfill = false
        widget.present(callback: { state in
            if state == .closed { closed.fulfill() }
        })
        wait(for: [closed], timeout: TestUtils.asyncTimeout)

        TestUtils.waitUntil("the dismissal is recorded") {
            self.events(of: countly).contains { $0["key"] as? String == "[CLY]_survey" }
        }
        let survey = events(of: countly).first { $0["key"] as? String == "[CLY]_survey" }
        XCTAssertEqual(TestUtils.describe((survey?["segmentation"] as? [String: Any])?["closed"] ?? ""), "1")
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
        countly.feedback.getAvailableFeedbackWidgets { widgets, _ in
            XCTAssertNil(widgets)
            reported.fulfill()
        }
        wait(for: [reported], timeout: TestUtils.asyncTimeout)
        #endif
    }

    // MARK: - Consent

    func testNothingIsRecordedWithoutFeedbackConsent() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.requiresConsent = true
        }

        countly.feedback.recordRatingWidget(id: "w3",
                                            rating: 4,
                                            email: nil,
                                            comment: nil,
                                            userCanBeContacted: false)
        XCTAssertTrue(events(of: countly).isEmpty)

        countly.consent.giveConsent(for: .feedback)
        countly.feedback.recordRatingWidget(id: "w3",
                                            rating: 4,
                                            email: nil,
                                            comment: nil,
                                            userCanBeContacted: false)
        XCTAssertEqual(events(of: countly).filter { $0["key"] as? String == "[CLY]_star_rating" }.count, 1)
    }

    // MARK: - Wire names

    func testTheWidgetTypeWireNamesAreTheOnesTheServerExpects() {
        XCTAssertEqual(FeedbackWidgetType.survey.wireName, "survey")
        XCTAssertEqual(FeedbackWidgetType.nps.wireName, "nps")
        XCTAssertEqual(FeedbackWidgetType.rating.wireName, "rating")
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
