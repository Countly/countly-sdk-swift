//
//  WidgetLayoutTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Where a feedback widget is put, and why it is put there.
///
/// These are not preferences. A widget page is authored for a phone viewport, has
/// no breakpoint above it, and never sends `resize_me`, so given the whole window
/// it lays itself out against a viewport ten times wider than anything it was
/// drawn for and ends up in a corner. On the web a stylesheet on the wrapper does
/// this job; native has no wrapper, so the SDK does.
///
/// Every number here is `WidgetLayout.java` in `countly-sdk-java`, which presents
/// these same pages on a desktop and does it correctly. They are asserted rather
/// than trusted so the two cannot drift apart: a widget should look the same on a
/// Mac as it does on a Java desktop client.
final class WidgetLayoutTests: XCTestCase {

    private let desktop = CGSize(width: 3840, height: 2130)

    // MARK: - NPS

    /// Bottom centre, whatever the dashboard's position says. Java centres an NPS
    /// unconditionally and ignores `appearance.position` for this type.
    func testAnNPSSitsAtTheBottomCentre() {
        for position in [nil, "bLeft", "bRight"] {
            let frame = WidgetLayout.resolve(type: .nps, position: position, surface: desktop)

            XCTAssertEqual(frame.width, 480, "the NPS width cap")
            XCTAssertEqual(frame.height, 450, "the NPS height cap")
            XCTAssertEqual(frame.origin.x, (3840 - 480) / 2, "centred, position: [\(position ?? "none")]")
            XCTAssertEqual(frame.maxY, 2130, "on the bottom edge")
        }
    }

    // MARK: - Survey

    /// A survey is the one type the dashboard's position applies to: left by
    /// default, right when it says so, and always a margin clear of the edge.
    func testASurveySitsAtTheBottomOnTheSideTheDashboardChose() {
        let left = WidgetLayout.resolve(type: .survey, position: nil, surface: desktop)
        XCTAssertEqual(left.origin.x, 50, "the default side margin")
        XCTAssertEqual(left.maxY, 2130)
        XCTAssertEqual(left.height, 650, "the survey height cap")

        let right = WidgetLayout.resolve(type: .survey, position: "bRight", surface: desktop)
        XCTAssertEqual(right.origin.x, 3840 - 480 - 50, "a margin clear of the right edge")
        XCTAssertEqual(right.maxY, 2130)
    }

    /// The comparison is neither case sensitive nor whitespace sensitive, because a
    /// dashboard value is typed by a person.
    func testTheDashboardPositionIsReadLeniently() {
        for spelling in ["bRight", "bright", "BRIGHT", " bRight "] {
            let frame = WidgetLayout.resolve(type: .survey, position: spelling, surface: desktop)
            XCTAssertEqual(frame.origin.x, 3840 - 480 - 50, "spelling: [\(spelling)]")
        }
    }

    // MARK: - Rating

    /// A rating is centred in both axes rather than pinned to an edge, and it is the
    /// one type with its own width.
    func testARatingIsCentredInBothAxes() {
        let frame = WidgetLayout.resolve(type: .rating, position: "bRight", surface: desktop)

        XCTAssertEqual(frame.width, 400, "the rating has its own width, not the shared cap")
        XCTAssertEqual(frame.height, 800)
        XCTAssertEqual(frame.origin.x, (3840 - 400) / 2)
        XCTAssertEqual(frame.origin.y, (2130 - 800) / 2)
    }

    // MARK: - A window smaller than the caps

    /// Every dimension is a cap, not a size. On a phone the window is smaller than
    /// all of them, so the widget takes the window and nothing changes there, which
    /// is what keeps this from altering iOS.
    func testAWindowSmallerThanTheCapsIsUsedWhole() {
        let phone = CGSize(width: 390, height: 844)

        for type in [FeedbackWidgetType.nps, .survey, .rating] {
            let frame = WidgetLayout.resolve(type: type, position: nil, surface: phone)
            XCTAssertEqual(frame.width, 390, "type: [\(type.wireName)] should take the full width")
            XCTAssertLessThanOrEqual(frame.height, 844, "type: [\(type.wireName)]")
            XCTAssertEqual(frame.origin.x, 0, "nothing to centre within, type: [\(type.wireName)]")
        }
    }

    // MARK: - A height the page asked for

    /// A page that says how tall it needs to be is believed, up to its type's cap. A
    /// short survey should not be given a tall box.
    func testARequestedHeightIsHonouredUpToTheTypesCap() {
        let short = WidgetLayout.resolve(type: .survey, position: nil,
                                         surface: desktop, requestedHeight: 200)
        XCTAssertEqual(short.height, 200, "a modest request is granted")
        XCTAssertEqual(short.maxY, 2130, "and it still sits on the bottom edge")

        let greedy = WidgetLayout.resolve(type: .nps, position: nil,
                                          surface: desktop, requestedHeight: 5000)
        XCTAssertEqual(greedy.height, 450, "a request past the cap is clamped to it")
    }

    /// An unknown type is treated as a centred survey rather than refused, which is
    /// what Java does. A widget the SDK does not recognise still has to appear
    /// somewhere sensible.
    func testAnUnknownTypeIsCentredLikeASurvey() {
        let frame = WidgetLayout.resolve(type: nil, position: nil, surface: desktop)

        XCTAssertEqual(frame.width, 480)
        XCTAssertEqual(frame.height, 650)
        XCTAssertEqual(frame.origin.x, (3840 - 480) / 2)
        XCTAssertEqual(frame.origin.y, (2130 - 650) / 2)
    }
}
