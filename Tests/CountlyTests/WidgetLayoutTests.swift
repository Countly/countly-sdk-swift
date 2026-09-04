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

    // MARK: - The surface the layout is measured against

    /// Layout and placement have to agree on which rectangle they mean.
    ///
    /// Regression test for a real misplacement: the frame was computed against the
    /// screen while the panel was positioned against the application window, so an
    /// NPS laid out for the bottom of a 2130 tall screen was placed against a 1023
    /// tall window and ended up below its bottom edge, ten points off screen, and
    /// off centre horizontally too. The arithmetic below is what the placement step
    /// performs, so it fails if the two ever diverge again.
    func testAWidgetPlacedInAWindowLandsInsideThatWindow() {
        // A window on a second display, left of and below the origin, which is what
        // made the mismatch obvious rather than merely wrong.
        let window = CGRect(x: -1634, y: 1097, width: 1289, height: 1023)

        let placed = WidgetLayout.resolve(type: .nps, position: nil, surface: window.size)

        // Measured from the top of the surface, as the background view is flipped.
        XCTAssertEqual(placed.maxY, window.height, "flush with the bottom of the window")
        XCTAssertEqual(placed.origin.x, (window.width - 480) / 2, "centred in the window")

        // The conversion the placement step applies, from a top left origin within
        // the surface to AppKit's bottom left desktop coordinates.
        let panelY = window.origin.y + window.height - placed.origin.y - placed.height
        let panelX = window.origin.x + placed.origin.x

        XCTAssertEqual(panelY, window.origin.y, "the panel sits on the window's bottom edge")
        XCTAssertGreaterThanOrEqual(panelX, window.origin.x, "and within its left edge")
        XCTAssertLessThanOrEqual(panelX + placed.width, window.maxX, "and its right")
    }

}

/// A height the SDK measured is not a height the page asked for.
///
/// The page's announcement is clamped by its own breakpoint and, for an NPS,
/// arrives before the incoming screen has laid out, so it understates a tall
/// step. The measurement is the page's own formula read after layout. The first
/// is held to the type's maximum; the second is held only to the surface, because
/// a comment step that needs 675 points and gets 450 scrolls inside its card.
final class WidgetLayoutMeasuredHeightTests: XCTestCase {

    private let surface = CGSize(width: 1440, height: 900)

    func testAMeasuredHeightMayPassTheTypeMaximum() {
        let frame = WidgetLayout.resolve(type: .nps, position: nil, surface: surface,
                                         requestedHeight: 675, boundedByTypeMaximum: false)

        XCTAssertEqual(frame.height, 675)
        // Still along the bottom edge, which is where an NPS belongs.
        XCTAssertEqual(frame.maxY, surface.height)
    }

    func testAnAnnouncedHeightStaysHeldToTheTypeMaximum() {
        let frame = WidgetLayout.resolve(type: .nps, position: nil, surface: surface,
                                         requestedHeight: 675)

        XCTAssertEqual(frame.height, WidgetLayout.npsMaximumHeight,
                       "an announced height escaped the maximum that guards against a viewport echo")
    }

    func testAMeasuredHeightIsStillHeldToTheSurface() {
        let small = CGSize(width: 480, height: 600)
        let frame = WidgetLayout.resolve(type: .nps, position: nil, surface: small,
                                         requestedHeight: 675, boundedByTypeMaximum: false)

        XCTAssertEqual(frame.height, small.height)
        XCTAssertEqual(frame.minY, 0)
    }

    func testASurveyMeasurementIsTreatedTheSameWay() {
        let frame = WidgetLayout.resolve(type: .survey, position: "bRight", surface: surface,
                                         requestedHeight: 720, boundedByTypeMaximum: false)

        XCTAssertEqual(frame.height, 720)
        XCTAssertEqual(frame.maxX, surface.width - WidgetLayout.sideMargin)
    }
}

/// A rectangle the page asked for is a size, not a proportion. When the surface
/// changes it keeps its size, stays against the edge it was nearer to, and is
/// clamped onto the surface.
final class WidgetLayoutReanchorTests: XCTestCase {

    func testABottomAlignedFrameStaysOnTheBottomAsTheWindowGrows() {
        let old = CGSize(width: 1000, height: 600)
        let frame = CGRect(x: 50, y: 300, width: 500, height: 300)   // flush with the bottom
        let moved = WidgetLayout.reanchor(frame, from: old, to: CGSize(width: 1000, height: 900))

        XCTAssertEqual(moved.size, frame.size, "the page's size was changed")
        XCTAssertEqual(moved.maxY, 900, "it floated mid-window instead of following the bottom edge")
        XCTAssertEqual(moved.minX, 50, "it was nearer the left edge and should have stayed there")
    }

    func testARightAlignedFrameFollowsTheRightEdge() {
        let old = CGSize(width: 1000, height: 600)
        let frame = CGRect(x: 450, y: 0, width: 500, height: 200)    // 50 from the right, 450 from the left
        let moved = WidgetLayout.reanchor(frame, from: old, to: CGSize(width: 1400, height: 600))

        XCTAssertEqual(moved.maxX, 1350)
    }

    func testACentredFrameStaysCentred() {
        let old = CGSize(width: 1000, height: 600)
        let frame = CGRect(x: 250, y: 150, width: 500, height: 300)
        let moved = WidgetLayout.reanchor(frame, from: old, to: CGSize(width: 1600, height: 1000))

        XCTAssertEqual(moved.midX, 800)
        XCTAssertEqual(moved.midY, 500)
    }

    func testAFrameIsClampedOntoASmallerSurface() {
        let old = CGSize(width: 1000, height: 600)
        let frame = CGRect(x: 450, y: 300, width: 500, height: 300)
        let moved = WidgetLayout.reanchor(frame, from: old, to: CGSize(width: 400, height: 250))

        XCTAssertEqual(moved.minX, 0)
        XCTAssertEqual(moved.minY, 0)
        XCTAssertEqual(moved.width, 400, "wider than the surface, so as wide as the surface")
        XCTAssertEqual(moved.height, 250)
    }
}
