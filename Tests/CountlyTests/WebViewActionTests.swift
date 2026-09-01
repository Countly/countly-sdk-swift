//
//  WebViewActionTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

// The action parser lives in the web view manager, which is only compiled where
// there is a web view to manage.
#if os(iOS) || os(visionOS) || os(macOS)

import XCTest
@testable import Countly

/// Reading what a content page asked the SDK to do.
///
/// A page talks to the SDK by navigating to a sentinel URL whose query carries the
/// request. That query cannot be split on `&` the obvious way: `link` carries an
/// unescaped URL with its own query string, and `event` and `resize_me` carry JSON
/// that may contain an `&` inside a string. So the parser consumes from the right,
/// taking the rightmost reserved marker whose value is actually valid for its key,
/// and letting anything that does not validate be absorbed as ordinary text.
///
/// Getting this wrong loses the user's answer to a survey or opens the wrong link,
/// so the awkward inputs matter more than the tidy ones.
final class WebViewActionTests: XCTestCase {

    private func parse(_ url: String) -> [String: Any] {
        WebViewManager.parseActionQuery(url)
    }

    // MARK: - The ordinary shapes

    func testASimpleActionIsRead() {
        let parsed = parse("countly://action?action=event&event=[{\"key\":\"tap\"}]")

        XCTAssertEqual(parsed["action"] as? String, "event")
        XCTAssertEqual(parsed["event"] as? String, "[{\"key\":\"tap\"}]")
    }

    func testAURLWithNoQueryYieldsNothing() {
        XCTAssertTrue(parse("countly://action").isEmpty)
        XCTAssertTrue(parse("").isEmpty)
    }

    func testAnIdentifierBeforeTheReservedKeysIsKept() {
        let parsed = parse("countly://action?id=42&name=cta&action=event&event=[]")

        XCTAssertEqual(parsed["id"] as? String, "42")
        XCTAssertEqual(parsed["name"] as? String, "cta")
        XCTAssertEqual(parsed["action"] as? String, "event")
    }

    // MARK: - The awkward shapes the parser exists for

    /// A link carries an unescaped URL with its own query string. Splitting on `&`
    /// would cut the link in half and open a truncated address.
    func testALinkKeepsItsOwnQueryString() {
        let parsed = parse("countly://action?action=link&link=https://example.com/p?a=1&b=2&c=3")

        XCTAssertEqual(parsed["action"] as? String, "link")
        XCTAssertEqual(parsed["link"] as? String, "https://example.com/p?a=1&b=2&c=3")
    }

    /// Event JSON can contain an `&` inside a string value, which a naive split
    /// would treat as a parameter boundary and destroy.
    func testEventJSONSurvivesAnAmpersandInsideAString() {
        let json = "[{\"key\":\"tap\",\"segmentation\":{\"label\":\"salt & pepper\"}}]"
        let parsed = parse("countly://action?action=event&event=\(json)")

        XCTAssertEqual(parsed["event"] as? String, json)
        XCTAssertEqual(parsed["action"] as? String, "event")
    }

    func testResizeJSONSurvivesAnAmpersandInsideAString() {
        let json = "{\"p\":{\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"note\":\"a & b\"}}"
        let parsed = parse("countly://action?action=resize_me&resize_me=\(json)")

        XCTAssertEqual(parsed["resize_me"] as? String, json)
    }

    /// A marker whose value is not valid for its key is ordinary text inside an
    /// enclosing value, so it must be absorbed rather than treated as a boundary.
    func testTextThatLooksLikeAMarkerIsAbsorbedWhenItsValueIsInvalid() {
        // `&close=maybe` is not a valid close value, so it belongs to the link.
        let parsed = parse("countly://action?action=link&link=https://example.com/p?x=1&close=maybe")

        XCTAssertEqual(parsed["link"] as? String, "https://example.com/p?x=1&close=maybe")
        XCTAssertNil(parsed["close"])
    }

    func testAValidCloseAfterALinkIsReadAsItsOwnParameter() {
        let parsed = parse("countly://action?action=link&link=https://example.com/p?x=1&close=1")

        XCTAssertEqual(parsed["link"] as? String, "https://example.com/p?x=1")
        XCTAssertEqual(parsed["close"] as? String, "1")
    }

    /// Several reserved parameters after one another all have to be found, which is
    /// what the right-to-left walk is for.
    func testSeveralReservedParametersAreAllRead() {
        let json = "[{\"key\":\"tap\"}]"
        let parsed = parse("countly://action?id=7&action=event&event=\(json)&close=1")

        XCTAssertEqual(parsed["id"] as? String, "7")
        XCTAssertEqual(parsed["action"] as? String, "event")
        XCTAssertEqual(parsed["event"] as? String, json)
        XCTAssertEqual(parsed["close"] as? String, "1")
    }

    /// Percent encoding is undone before parsing, because the page encodes the
    /// whole query.
    func testAPercentEncodedQueryIsDecodedBeforeParsing() {
        let parsed = parse("countly://action?action=link&link=https%3A%2F%2Fexample.com%2Fa%20b")

        XCTAssertEqual(parsed["link"] as? String, "https://example.com/a b")
    }

    // MARK: - Value validation

    /// Value validation decides *where the query is split*, not whether a value is
    /// kept: whatever is left at the front is parsed as ordinary parameters, so a
    /// value that fails validation still arrives, it just does not act as a
    /// boundary. That distinction is the whole design, so it is asserted directly.
    func testValidationChoosesTheSplitPointRatherThanDroppingValues() {
        // `close=maybe` is not a valid flag, so it is not treated as a boundary and
        // is absorbed by the link that encloses it.
        let absorbed = parse("countly://action?action=link&link=https://example.com?a=1&close=maybe")
        XCTAssertEqual(absorbed["link"] as? String, "https://example.com?a=1&close=maybe")
        XCTAssertNil(absorbed["close"], "it was never a parameter, it was part of the link")

        // The same text with a valid flag value does act as a boundary.
        let split = parse("countly://action?action=link&link=https://example.com?a=1&close=1")
        XCTAssertEqual(split["link"] as? String, "https://example.com?a=1")
        XCTAssertEqual(split["close"] as? String, "1")
    }

    /// A reserved key at the front of the query, with nothing enclosing it, is
    /// plain text and is read as an ordinary parameter whatever its value. The
    /// action handler is what then refuses to act on it.
    func testAReservedKeyAtTheFrontIsReadWhateverItsValue() {
        XCTAssertEqual(parse("countly://action?event={\"not\":\"an array\"}")["event"] as? String,
                       "{\"not\":\"an array\"}")
        XCTAssertEqual(parse("countly://action?action=dance")["action"] as? String, "dance")
    }

    /// The two JSON-carrying keys are told apart by the shape of their payload,
    /// which is what keeps an events array from being read as a resize request.
    func testTheTwoJSONKeysAreDistinguishedByTheirShape() {
        let events = "[{\"key\":\"tap\"}]"
        let geometry = "{\"p\":{\"x\":0}}"

        let both = parse("countly://action?action=event&resize_me=\(geometry)&event=\(events)")
        XCTAssertEqual(both["event"] as? String, events)
        XCTAssertEqual(both["resize_me"] as? String, geometry)
    }

    // MARK: - Scheme detection

    /// A link value is recognised by having a URI scheme, which covers both an
    /// ordinary web address and a custom-scheme deep link into another app.
    func testASchemeIsRecognisedForWebAddressesAndDeepLinks() {
        XCTAssertTrue(WebViewManager.hasURIScheme("https://example.com"))
        XCTAssertTrue(WebViewManager.hasURIScheme("myapp://open/thing"))
        XCTAssertTrue(WebViewManager.hasURIScheme("mailto:someone@example.com"))
        XCTAssertTrue(WebViewManager.hasURIScheme("a+b-c.d://x"), "the scheme grammar allows + - .")
    }

    func testTextWithoutASchemeIsNotALink() {
        XCTAssertFalse(WebViewManager.hasURIScheme("example.com"))
        XCTAssertFalse(WebViewManager.hasURIScheme(""))
        XCTAssertFalse(WebViewManager.hasURIScheme(":no-scheme-before-the-colon"))
        XCTAssertFalse(WebViewManager.hasURIScheme("1http://starts-with-a-digit"))
        XCTAssertFalse(WebViewManager.hasURIScheme("has space://x"))
    }

    // MARK: - The documented limitation

    /// A value that literally contains `&<reserved key>=<valid value>` can still be
    /// mis-split. This is asserted rather than hidden, because it is the known
    /// boundary of the approach and a future change should have to acknowledge it.
    func testAValueContainingAValidLookingMarkerIsMisSplit() {
        let parsed = parse("countly://action?action=link&link=https://example.com/p?q=%26close=1")

        // The `close=1` inside the link is indistinguishable from a real one.
        XCTAssertEqual(parsed["close"] as? String, "1")
        XCTAssertEqual(parsed["link"] as? String, "https://example.com/p?q=")
    }
}

#endif
