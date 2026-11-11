//
//  AttributionTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Where the server is told this install came from.
///
/// Attribution arrives from outside the application, usually a deep link, so the
/// data is untrusted: it can be malformed, incomplete, or carry characters that
/// would break out of the query string it travels in. Most of these are about what
/// the SDK refuses.
final class AttributionTests: CountlyBaseTestCase {

    // MARK: - Direct attribution

    func testACountlyCampaignIsReportedAsACampaignIDAndUser() {
        let countly = startInstance()

        countly.attribution.recordDirectAttribution(
            campaignType: "countly",
            campaignData: #"{"cid": "campaign-1", "cuid": "user-9"}"#)

        guard let request = TestUtils.requests(requestQueue(of: countly), carrying: "campaign_id").last else {
            XCTFail("recording an attribution should have queued a request")
            return
        }
        TestUtils.assertBaseParameters(request)
        XCTAssertEqual(request["campaign_id"] as? String, "campaign-1")
        XCTAssertEqual(request["campaign_user"] as? String, "user-9")
    }

    /// The campaign user is optional: an install can be attributed to a campaign
    /// without the campaign knowing who clicked it.
    func testACampaignWithNoUserIsStillReported() {
        let countly = startInstance()

        countly.attribution.recordDirectAttribution(campaignType: "countly",
                                                    campaignData: #"{"cid": "campaign-1"}"#)

        guard let request = TestUtils.requests(requestQueue(of: countly), carrying: "campaign_id").last else {
            XCTFail("the campaign ID alone is worth reporting")
            return
        }
        XCTAssertEqual(request["campaign_id"] as? String, "campaign-1")
        XCTAssertNil(request["campaign_user"])
    }

    /// Direct attribution in the config needs both values: one alone is reported
    /// with a warning and nothing is sent.
    func testACampaignTypeWithoutDataInTheConfigSendsNothing() {
        let countly = startInstance { $0.campaignType = "countly" }

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "campaign_id").isEmpty)
        XCTAssertEqual(logCodeCount(HealthLogCode.invalidValue, of: countly), 1)
    }

    /// The campaign ID is the whole point of the request, so without one there is
    /// nothing to send.
    func testCampaignDataWithoutACampaignIDIsRefused() {
        let countly = startInstance()

        countly.attribution.recordDirectAttribution(campaignType: "countly",
                                                    campaignData: #"{"cuid": "user-9"}"#)
        countly.attribution.recordDirectAttribution(campaignType: "countly",
                                                    campaignData: #"{"cid": ""}"#)

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "campaign_id").isEmpty)
    }

    func testMalformedCampaignDataIsRefused() {
        let countly = startInstance()

        countly.attribution.recordDirectAttribution(campaignType: "countly",
                                                    campaignData: "not json at all")

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "campaign_id").isEmpty)
    }

    func testAnUnknownCampaignTypeIsRefused() {
        let countly = startInstance()

        countly.attribution.recordDirectAttribution(campaignType: "some-other-network",
                                                    campaignData: #"{"cid": "campaign-1"}"#)

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "campaign_id").isEmpty)
    }

    func testEmptyCampaignTypeOrDataIsRefused() {
        let countly = startInstance()

        countly.attribution.recordDirectAttribution(campaignType: "", campaignData: #"{"cid": "c"}"#)
        countly.attribution.recordDirectAttribution(campaignType: "countly", campaignData: "")

        XCTAssertTrue(requestQueue(of: countly).contains {
            TestUtils.parseQuery($0)["campaign_id"] != nil
        } == false)
    }

    /// Campaign values come from a deep link the application did not write, so an
    /// unescaped `&` in one would inject a parameter of its own into the request.
    func testCampaignValuesAreEscapedSoTheyCannotInjectParameters() {
        let countly = startInstance()

        countly.attribution.recordDirectAttribution(
            campaignType: "countly",
            campaignData: #"{"cid": "a&device_id=stolen", "cuid": "b=c"}"#)

        guard let raw = requestQueue(of: countly).last(where: { $0.contains("campaign_id") }) else {
            XCTFail("recording an attribution should have queued a request")
            return
        }

        let parsed = TestUtils.parseQuery(raw)
        XCTAssertEqual(parsed["campaign_id"] as? String, "a&device_id=stolen",
                       "the value survives round tripping intact")
        XCTAssertEqual(parsed["device_id"] as? String, Self.deviceID,
                       "and it did not become a device_id parameter of its own")
    }

    // MARK: - Indirect attribution

    func testAdvertisingIdentifiersAreSentAsTheirOwnRequest() {
        let countly = startInstance()

        countly.attribution.recordIndirectAttribution([AttributionKey.idfa: "AD-ID-1"])

        guard let request = TestUtils.requests(requestQueue(of: countly), carrying: "aid").last else {
            XCTFail("recording an indirect attribution should have queued a request")
            return
        }
        let payload = request["aid"] as? [String: Any]
        XCTAssertEqual(payload?[AttributionKey.idfa] as? String, "AD-ID-1")
    }

    /// An empty identifier is worse than a missing one: it would overwrite a value
    /// the server already holds with nothing.
    func testEmptyIdentifiersAreDroppedRatherThanSentAsBlanks() {
        let countly = startInstance()

        countly.attribution.recordIndirectAttribution([
            AttributionKey.idfa: "AD-ID-1",
            AttributionKey.adid: "",
        ])

        guard let request = TestUtils.requests(requestQueue(of: countly), carrying: "aid").last,
              let payload = request["aid"] as? [String: Any] else {
            XCTFail("recording an indirect attribution should have queued a request")
            return
        }
        XCTAssertEqual(payload.count, 1)
        XCTAssertNil(payload[AttributionKey.adid])
    }

    func testAnAttributionWithNothingUsableInItSendsNothing() {
        let countly = startInstance()

        countly.attribution.recordIndirectAttribution([AttributionKey.idfa: ""])

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "aid").isEmpty)
    }

    // MARK: - Config

    func testAttributionSuppliedAtInitIsReportedAsTheSDKStarts() {
        let countly = startInstance {
            $0.campaignType = "countly"
            $0.campaignData = #"{"cid": "from-config"}"#
            $0.indirectAttribution = [AttributionKey.idfa: "AD-FROM-CONFIG"]
        }

        let queue = requestQueue(of: countly)
        XCTAssertEqual(TestUtils.requests(queue, carrying: "campaign_id").first?["campaign_id"] as? String,
                       "from-config")
        XCTAssertNotNil(TestUtils.requests(queue, carrying: "aid").first)
    }

    // MARK: - Consent

    func testNothingIsReportedWithoutAttributionConsent() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.attribution.recordDirectAttribution(campaignType: "countly",
                                                    campaignData: #"{"cid": "blocked"}"#)
        countly.attribution.recordIndirectAttribution([AttributionKey.idfa: "AD-ID-1"])

        let queue = requestQueue(of: countly)
        XCTAssertTrue(TestUtils.requests(queue, carrying: "campaign_id").isEmpty)
        XCTAssertTrue(TestUtils.requests(queue, carrying: "aid").isEmpty)
    }

    // MARK: - Limits

    func testIndirectAttributionRespectsTheValueLimits() {
        let countly = startInstance { $0.sdkInternalLimits.maxValueSize = 4 }

        countly.attribution.recordIndirectAttribution([AttributionKey.idfa: "a-long-advertising-id"])

        guard let payload = TestUtils.requests(requestQueue(of: countly), carrying: "aid")
            .last?["aid"] as? [String: Any] else {
            XCTFail("recording an indirect attribution should have queued a request")
            return
        }
        XCTAssertEqual(payload[AttributionKey.idfa] as? String, "a-lo")
    }
}
