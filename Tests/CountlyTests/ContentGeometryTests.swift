//
//  ContentGeometryTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

#if os(iOS) || os(visionOS)

import XCTest
@testable import Countly

/// The one rule that decides both how big a content page is built and where it is
/// put.
///
/// These two have to stay in step. When the size reported to the server is larger
/// than the slot the page is finally placed in, the page overflows its own web view:
/// it scrolls, and whatever sits at the bottom of it is cut in half by the edge of
/// the view. That is a bug the wire cannot show, so it is pinned here.
final class ContentGeometryTests: XCTestCase {

    /// iPhone 16 Pro in portrait: Dynamic Island above, home indicator below.
    private let device = CGSize(width: 402, height: 874)
    private let notched = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)

    /// A device with a status bar rather than a cutout.
    private let plain = UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)

    // MARK: - The size the server builds against

    /// Immersive means under the status bar, not under the Dynamic Island: nothing
    /// legible fits behind a cutout, so it comes out of the height either way.
    func testACutoutIsSubtractedEvenWhenTheContentIsImmersive() {
        let size = ContentGeometry.contentSize(in: device, insets: notched, displayOption: .immersive)

        XCTAssertEqual(size.height, 874 - 59)
        XCTAssertEqual(size.width, 402)
    }

    /// The home indicator is only cleared when the display option asks for it, so an
    /// immersive page still reaches the bottom edge of the screen.
    func testTheBottomInsetIsOnlySubtractedInSafeAreaMode() {
        let immersive = ContentGeometry.contentSize(in: device, insets: notched, displayOption: .immersive)
        let safeArea = ContentGeometry.contentSize(in: device, insets: notched, displayOption: .safeArea)

        XCTAssertEqual(immersive.height, 874 - 59)
        XCTAssertEqual(safeArea.height, 874 - 59 - 34)
    }

    /// A status bar is not a cutout: an immersive page is allowed to sit under it,
    /// so the full height is reported.
    func testAStatusBarDoesNotShrinkAnImmersivePage() {
        let size = ContentGeometry.contentSize(in: device, insets: plain, displayOption: .immersive)

        XCTAssertEqual(size.height, 874)
    }

    /// Safe area mode clears the status bar as well, which is what it was asked for.
    func testAStatusBarShrinksASafeAreaPage() {
        let size = ContentGeometry.contentSize(in: device, insets: plain, displayOption: .safeArea)

        XCTAssertEqual(size.height, 874 - 20)
    }

    /// Whichever way the device is held, the cutout eats the same amount of width,
    /// so one subtraction of the larger inset describes both.
    func testTheCutoutWidthIsSubtractedOnceInEitherLandscape() {
        let landscape = CGSize(width: 874, height: 402)
        let left = UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 0)
        let right = UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 59)

        XCTAssertEqual(ContentGeometry.contentSize(in: landscape, insets: left, displayOption: .immersive).width,
                       874 - 59)
        XCTAssertEqual(ContentGeometry.contentSize(in: landscape, insets: right, displayOption: .immersive).width,
                       874 - 59)
    }

    // MARK: - Where the page is put

    /// The page was built for the space below the cutout, so it has to be pushed
    /// down into it. Reporting the smaller size and then placing the page at the top
    /// of the screen is what leaves it overflowing at the bottom.
    func testAPageBuiltBelowTheCutoutIsPushedDownIntoIt() {
        let offset = ContentGeometry.placementOffset(insets: notched,
                                                     displayOption: .immersive,
                                                     isLandscapeLeft: false)

        XCTAssertEqual(offset.y, 59)
        XCTAssertEqual(offset.x, 0)
    }

    /// The offset undoes exactly what the size subtracted, which is the invariant
    /// the two halves of this type exist to keep.
    func testThePlacementUndoesWhatTheSizeTookOut() {
        for option in [WebViewDisplayOption.immersive, .safeArea] {
            let size = ContentGeometry.contentSize(in: device, insets: notched, displayOption: option)
            let offset = ContentGeometry.placementOffset(insets: notched,
                                                         displayOption: option,
                                                         isLandscapeLeft: false)

            XCTAssertLessThanOrEqual(offset.y + size.height, device.height,
                                     "a page placed at the offset must still end inside the screen")
        }
    }

    /// A status bar is not moved clear of in immersive mode, matching the height
    /// that was not taken out of it.
    func testAStatusBarDoesNotMoveAnImmersivePage() {
        let offset = ContentGeometry.placementOffset(insets: plain,
                                                     displayOption: .immersive,
                                                     isLandscapeLeft: false)

        XCTAssertEqual(offset, .zero)
    }

    /// In landscape left the cutout is on the trailing edge, so the page already
    /// starts clear of it and shifting would only push it off the far side.
    func testAPageIsNotShiftedAwayFromACutoutItAlreadyClears() {
        let insets = UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 59)

        let left = ContentGeometry.placementOffset(insets: insets, displayOption: .immersive, isLandscapeLeft: true)
        let right = ContentGeometry.placementOffset(insets: insets, displayOption: .immersive, isLandscapeLeft: false)

        XCTAssertEqual(left.x, 0)
        XCTAssertEqual(right.x, 59)
    }
}

#endif
