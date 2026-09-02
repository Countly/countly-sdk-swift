//
//  LogFormattingTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
import CoreGraphics
@testable import Countly

/// How numbers and geometry are written into log lines.
///
/// Log formatting looks like the least consequential code in the SDK, and it is
/// the code most likely to be read under pressure: someone is looking at a log
/// because something is already wrong. A duration printed as
/// `1.0000000000000002` or a frame printed as four bare numbers costs the reader
/// time exactly when they have least of it.
///
/// It is also the code most likely to trap. Turning a `Double` into an `Int64` is
/// a trapping conversion in Swift, so a value that is merely large, or not a
/// number at all, crashes the process from inside a logging call. That is the
/// worst possible origin for a crash: the SDK would take the host application
/// down while describing something.
final class LogFormattingTests: CountlyBaseTestCase {

    // MARK: - Doubles

    /// A whole number reads as a whole number. `String(2.0)` is `"2.0"`, and a
    /// count or an index printed with a decimal point invites the reader to wonder
    /// what the fraction meant.
    func testAWholeNumberIsPrintedWithoutADecimalPoint() {
        XCTAssertEqual(Double(2).logValue, "2")
        XCTAssertEqual(Double(0).logValue, "0")
        XCTAssertEqual(Double(-17).logValue, "-17")
    }

    /// A fractional value keeps its digits. Swift's own description is the shortest
    /// text that reads back as the same value, so this neither pads nor rounds.
    func testAFractionalNumberKeepsItsDigits() {
        XCTAssertEqual(Double(2.5).logValue, "2.5")
        XCTAssertEqual(Double(-0.25).logValue, "-0.25")
    }

    /// The conversion to `Int64` traps outside the integer range, so the guard is
    /// the difference between a log line and a crash. `1e15` is the documented
    /// cutoff: at and above it the value is printed in full rather than converted.
    func testAValueTooLargeToConvertIsPrintedRatherThanTrapping() {
        // Just below the cutoff still converts.
        XCTAssertEqual(Double(1e14).logValue, "100000000000000")

        // At and above it, the guard sends the value down the printing path. The
        // assertion that matters is that these return at all.
        XCTAssertFalse(Double(1e15).logValue.isEmpty)
        XCTAssertFalse(Double(1e300).logValue.isEmpty)
        XCTAssertFalse((-Double(1e300)).logValue.isEmpty)

        // `Double.greatestFiniteMagnitude` is finite and integral, which is exactly
        // the combination that would reach the conversion without the magnitude
        // check.
        XCTAssertFalse(Double.greatestFiniteMagnitude.logValue.isEmpty)
    }

    /// Not-a-number and the infinities are finite-guarded for the same reason:
    /// `Int64(Double.nan)` traps. They reach logs from real arithmetic, most often
    /// a duration computed from two clock readings that went backwards, or a
    /// division by a zero-sized view.
    func testTheNonFiniteValuesArePrintedRatherThanTrapping() {
        XCTAssertEqual(Double.nan.logValue, String(Double.nan))
        XCTAssertEqual(Double.infinity.logValue, String(Double.infinity))
        XCTAssertEqual((-Double.infinity).logValue, String(-Double.infinity))
    }

    /// Negative zero is integral and finite, so it takes the conversion path, and
    /// `Int64(-0.0)` is `0`. Worth pinning because the alternative, `"-0"`, reads
    /// like a real measurement of something.
    func testNegativeZeroReadsAsZero() {
        XCTAssertEqual((-0.0).logValue, "0")
    }

    /// `CGFloat` forwards to the same formatter, so a geometry component reads the
    /// same as any other number. It is the type every frame is actually made of, so
    /// a divergence here would show up in exactly the logs that matter most.
    func testACGFloatFormatsLikeTheEquivalentDouble() {
        XCTAssertEqual(CGFloat(42).logValue, "42")
        XCTAssertEqual(CGFloat(0).logValue, "0")
        XCTAssertEqual(CGFloat(-1.5).logValue, "-1.5")
        XCTAssertEqual(CGFloat.infinity.logValue, Double.infinity.logValue)
    }

    // MARK: - Geometry

    /// A printed `CGPoint` and a printed `CGSize` are indistinguishable as bare
    /// pairs, which is the whole reason these exist: the label is the information.
    func testAPointAndASizeAreToldApartByTheirLabels() {
        XCTAssertEqual(CGPoint(x: 1, y: 2).logValue, "x=1 y=2")
        XCTAssertEqual(CGSize(width: 1, height: 2).logValue, "w=1 h=2")
    }

    /// The rect is the composition, so a frame reads the same wherever it was
    /// printed from. This is the form that shows up in the content geometry logs.
    func testARectReadsAsAnOriginFollowedByASize() {
        let frame = CGRect(x: 0, y: 59, width: 402, height: 815)

        XCTAssertEqual(frame.logValue, "x=0 y=59 w=402 h=815")
    }

    /// Geometry carries fractions in practice, from a scale factor or a safe area
    /// inset, and those must survive rather than being rounded into a lie.
    func testGeometryKeepsItsFractions() {
        let frame = CGRect(x: 0.5, y: 59.25, width: 402, height: 815.75)

        XCTAssertEqual(frame.logValue, "x=0.5 y=59.25 w=402 h=815.75")
    }

    /// `.zero` and `.null` reach logs from an unplaced view, and neither may trap.
    /// `CGRect.null` holds `.infinity`, which is the non-finite case arriving
    /// through geometry rather than through arithmetic.
    func testTheEmptyAndNullRectsAreBothPrintable() {
        XCTAssertEqual(CGRect.zero.logValue, "x=0 y=0 w=0 h=0")
        XCTAssertFalse(CGRect.null.logValue.isEmpty)
        XCTAssertFalse(CGRect.infinite.logValue.isEmpty)
    }
}
