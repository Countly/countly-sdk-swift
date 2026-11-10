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

    /// Increases with every view started, so of several views with one name the
    /// last one started can be found, and views can be stopped oldest first.
    let startOrder: Int

    /// When the current stretch of visible time began. Reset on resume, so the
    /// duration reported is time the view was actually on screen.
    var viewStartTime: TimeInterval

    /// Whether the view is paused: its time so far was reported when it was
    /// paused, and no time is counted until it is resumed.
    private(set) var isPaused = false

    /// Whether starting another view should stop this one.
    ///
    /// Automatic view tracking produces auto-stopped views, so the application's
    /// view stack maps to a chain rather than a growing set of open views.
    var isAutoStoppedView = false

    /// Whether automatic view tracking started this view, rather than the host
    /// application.
    var isAutomatic = false

    /// Whether this view was stopped by backgrounding and should be started again
    /// when the application returns.
    var willStartAgain = false

    /// Segmentation added after the view started.
    var segmentation: [String: Any] = [:]

    /// The segmentation the view was started with, replayed when it restarts.
    var startSegmentation: [String: Any] = [:]

    init(viewID: String, viewName: String, startTime: TimeInterval, startOrder: Int) {
        self.viewID = viewID
        self.viewName = viewName
        self.viewStartTime = startTime
        self.startOrder = startOrder
    }

    /// Whole seconds the view has been visible since it started or was last
    /// resumed, or 0 while it is paused, its time having been reported already.
    ///
    /// Rounded rather than truncated: a view that was open for 0.6 seconds is
    /// better reported as 1 than as 0, which the server reads as "no duration".
    func duration(now: TimeInterval) -> Int {
        guard !isPaused else { return 0 }
        return max(0, Int((now - viewStartTime).rounded()))
    }

    /// Stops the clock.
    func pause() {
        isPaused = true
    }

    /// Restarts the clock.
    func resume(at time: TimeInterval) {
        isPaused = false
        viewStartTime = time
    }
}
