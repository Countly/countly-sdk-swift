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
            ("temporary device ID", { $0.temporaryDeviceIDMode = true }),
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
}
