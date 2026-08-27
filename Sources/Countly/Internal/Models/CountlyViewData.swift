//
//  CountlyViewData.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// One view that has been started and not yet stopped.
final class CountlyViewData {

    let viewID: String
    let viewName: String

    /// When the current stretch of visible time began. Reset on resume, so the
    /// duration reported is time the view was actually on screen.
    var viewStartTime: TimeInterval

    /// Whether starting another view should stop this one.
    ///
    /// Automatic view tracking produces auto-stopped views, so the application's
    /// view stack maps to a chain rather than a growing set of open views.
    var isAutoStoppedView = false

    /// Whether this view was stopped by backgrounding and should be started again
    /// when the application returns.
    var willStartAgain = false

    /// Segmentation added after the view started.
    var segmentation: [String: Any] = [:]

    /// The segmentation the view was started with, replayed when it restarts.
    var startSegmentation: [String: Any] = [:]

    init(viewID: String, viewName: String, startTime: TimeInterval) {
        self.viewID = viewID
        self.viewName = viewName
        self.viewStartTime = startTime
    }

    /// Whole seconds the view has been visible.
    ///
    /// Rounded rather than truncated: a view that was open for 0.6 seconds is
    /// better reported as 1 than as 0, which the server reads as "no duration".
    func duration(now: TimeInterval) -> Int {
        Int((now - viewStartTime).rounded())
    }

    /// Stops the clock.
    ///
    /// The start time is moved to now rather than zeroed, because a zero start
    /// time would produce a duration of decades if anything read it afterwards.
    func pause(at time: TimeInterval) {
        if viewStartTime != 0 {
            viewStartTime = time
        }
    }

    /// Restarts the clock.
    func resume(at time: TimeInterval) {
        viewStartTime = time
    }
}
