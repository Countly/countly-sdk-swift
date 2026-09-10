//
//  WidgetLayout.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import CoreGraphics

/// Where a feedback widget sits on screen.
///
/// A widget page is authored for a phone viewport and has no breakpoint above it,
/// and unlike a content page it never sends `resize_me`. Handed the whole window
/// it lays out against a viewport it was never designed for and drifts into a
/// corner, which is what a large screen made obvious.
///
/// On the web nothing needs to size it: the page sits in an iframe inside a
/// wrapper the server's stylesheet has already sized, so it renders into a small
/// viewport and its own CSS looks right. Native has no wrapper, so the SDK does
/// that job instead.
///
/// The numbers and the per-type rules are `WidgetLayout.java` in `countly-sdk-java`
/// rather than anything chosen here, because that SDK presents these same pages on
/// a desktop and does it correctly. Keeping them identical is what makes a widget
/// look the same on a Mac as it does on a Java desktop client.
enum WidgetLayout {

    static let maximumWidth: CGFloat = 480
    static let npsMaximumHeight: CGFloat = 450
    static let surveyMaximumHeight: CGFloat = 650
    static let ratingWidth: CGFloat = 400
    static let ratingHeight: CGFloat = 800

    /// Gap left between a survey and the edge it is aligned to.
    static let sideMargin: CGFloat = 50

    /// The frame for a widget of `type` on a surface of `surface`.
    ///
    /// - Parameters:
    ///   - type: `nil` for a widget whose type is not known, which is treated as a
    ///     centred survey, exactly as the Java SDK does.
    ///   - position: the widget's `appearance.position`, such as `bLeft` or
    ///     `bRight`. Only a survey is placed by it; an NPS is always centred.
    ///   - requestedHeight: a height the page asked for, or zero. Honoured up to
    ///     the type's maximum, so a short survey does not get a tall box.
    ///   - boundedByTypeMaximum: whether `requestedHeight` is held to the type's
    ///     maximum. It is when the page announced the height, because the
    ///     templates echo the viewport they were given and the maximum is what
    ///     keeps an echo from becoming the box. It is not when the SDK measured the
    ///     card in the DOM: that number is the page's own formula, unclamped, and a
    ///     step taller than the maximum needs a box that tall or it scrolls inside
    ///     itself. Either way the surface bounds it.
    static func resolve(type: FeedbackWidgetType?,
                        position: String?,
                        surface: CGSize,
                        requestedHeight: CGFloat = 0,
                        boundedByTypeMaximum: Bool = true) -> CGRect {
        guard let type else {
            let width = min(maximumWidth, surface.width)
            let height = min(requestedHeight > 0 ? requestedHeight : surveyMaximumHeight, surface.height)
            return centred(width: width, height: height, in: surface)
        }

        if type == .rating {
            return centred(width: min(ratingWidth, surface.width),
                           height: min(ratingHeight, surface.height),
                           in: surface)
        }

        let maximumHeight = type == .nps ? npsMaximumHeight : surveyMaximumHeight
        let width = min(maximumWidth, surface.width)

        // A height nobody asked for is the type's maximum. One that was asked for is
        // held to the type's maximum only when the page announced it; either way the
        // surface has the last word.
        let height: CGFloat
        if requestedHeight > 0 {
            let ceiling = boundedByTypeMaximum ? maximumHeight : surface.height
            height = min(requestedHeight, ceiling, surface.height)
        } else {
            height = min(maximumHeight, surface.height)
        }

        // Along the bottom edge. A widget is an interruption, and the bottom is
        // where it interrupts least.
        return CGRect(x: horizontalOffset(type: type, position: position, surface: surface, width: width),
                      y: max(0, surface.height - height),
                      width: width,
                      height: height)
    }

    /// Moves a page-sized frame onto a new surface without changing its size.
    ///
    /// A rectangle the page asked for is a size, not a proportion: a survey wants
    /// its 500 wide card whatever the window is. So the size is kept, and on each
    /// axis the frame stays against whichever edge it was nearer to; equal margins
    /// mean it was centred and stays centred. Then it is clamped onto the surface,
    /// because a frame that keeps its old origin as the window shrinks ends up with
    /// part of itself off screen, and one that keeps it as the window grows floats
    /// mid-window rather than against the edge it was placed at.
    static func reanchor(_ frame: CGRect, from oldSurface: CGSize, to newSurface: CGSize) -> CGRect {
        CGRect(x: reanchoredOrigin(frame.origin.x, length: frame.width,
                                   from: oldSurface.width, to: newSurface.width),
               y: reanchoredOrigin(frame.origin.y, length: frame.height,
                                   from: oldSurface.height, to: newSurface.height),
               width: min(frame.width, newSurface.width),
               height: min(frame.height, newSurface.height))
    }

    /// A margin difference this small is rounding, not an alignment.
    private static let centringTolerance: CGFloat = 1

    /// Where one axis of a re-anchored frame starts on the new surface.
    private static func reanchoredOrigin(_ origin: CGFloat,
                                         length: CGFloat,
                                         from old: CGFloat,
                                         to new: CGFloat) -> CGFloat {
        let usable = max(0, new - length)

        // No old surface to have been placed against, so there is no edge to have
        // been nearer to and the origin is only clamped.
        guard old > 0 else { return min(max(0, origin), usable) }

        let leading = origin
        let trailing = old - origin - length

        let anchored: CGFloat
        if abs(leading - trailing) <= centringTolerance {
            anchored = (new - length) / 2
        } else if leading < trailing {
            anchored = leading
        } else {
            anchored = new - length - trailing
        }
        return min(max(0, anchored), usable)
    }

    private static func centred(width: CGFloat, height: CGFloat, in surface: CGSize) -> CGRect {
        CGRect(x: max(0, (surface.width - width) / 2),
               y: max(0, (surface.height - height) / 2),
               width: width,
               height: height)
    }

    private static func horizontalOffset(type: FeedbackWidgetType,
                                         position: String?,
                                         surface: CGSize,
                                         width: CGFloat) -> CGFloat {
        // An NPS is always centred, whatever the appearance says.
        if type == .nps {
            return max(0, (surface.width - width) / 2)
        }

        if position?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("bRight") == .orderedSame {
            return max(0, surface.width - width - sideMargin)
        }
        return min(sideMargin, max(0, surface.width - width))
    }
}
