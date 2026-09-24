//
//  CountlySwiftUI.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

#if canImport(SwiftUI)
import SwiftUI

/// Reports a SwiftUI screen as a Countly view for as long as it is on screen.
///
/// Automatic view tracking watches `UIViewController` appearances, which a
/// SwiftUI hierarchy does not produce: everything inside one hosting controller
/// is a single appearance, reported under a mangled generic class name. A
/// SwiftUI screen therefore names itself.
struct CountlyViewModifier: ViewModifier {

    let viewName: String
    let segmentation: [String: Any]?
    let instance: CountlyInstance?

    /// Held rather than re-resolved by name, so two screens reported under the
    /// same name stop the one they each started.
    @State private var openViewID: String?

    /// The name the open view was started under, so a renamed screen can tell
    /// its old view from the one it should have.
    @State private var openViewName: String?

    func body(content: Content) -> some View {
        content
            // `task(id:)` rather than `onAppear`: it runs on every appearance and
            // again whenever the name changes, which is what a screen titled from
            // data that is still loading needs.
            .task(id: viewName) { report(viewName) }
            .onDisappear { end() }
    }

    /// Opens the view for this name, first closing one left open under another.
    ///
    /// A repeated call for the name already open does nothing. SwiftUI signals an
    /// appearance twice in several ordinary cases, a list cell scrolled back into
    /// view among them, and each would otherwise open a second view for one
    /// visit. An empty name opens nothing, since the server would refuse it.
    private func report(_ name: String) {
        if openViewID != nil, openViewName == name { return }
        end()
        guard !name.isEmpty else { return }

        openViewID = resolvedInstance.views.startReportedView(name, segmentation: segmentation)
        openViewName = name
    }

    /// Closes the view this screen opened, carrying the segmentation onto the
    /// end event as well, which is the one with the duration.
    private func end() {
        guard let startedID = openViewID else { return }
        openViewID = nil
        openViewName = nil
        resolvedInstance.views.stopReportedView(id: startedID, segmentation: segmentation)
    }

    /// The instance to report to, resolved when a screen actually appears.
    ///
    /// `Countly.shared` takes the registry lock, and a default argument on the
    /// modifier would pay for that on every body evaluation rather than on the
    /// far rarer appearance.
    private var resolvedInstance: CountlyInstance {
        instance ?? Countly.shared
    }
}

public extension View {

    /// Reports this screen to Countly while it is on screen.
    ///
    /// Works whether or not automatic view tracking is enabled. A screen whose
    /// name changes while it is shown closes the view for the old name and opens
    /// one for the new name; an empty name reports nothing until it is set.
    ///
    /// - Parameters:
    ///   - name: The view name the dashboard shows.
    ///   - segmentation: Merged into the view's start and end events.
    ///   - instance: The SDK instance to report to. Defaults to the shared one.
    func countlyView(_ name: String,
                     segmentation: [String: Any]? = nil,
                     instance: CountlyInstance? = nil) -> some View {
        modifier(CountlyViewModifier(viewName: name,
                                     segmentation: segmentation,
                                     instance: instance))
    }
}
#endif
