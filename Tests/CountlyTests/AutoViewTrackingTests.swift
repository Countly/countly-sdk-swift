//
//  AutoViewTrackingTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

#if os(iOS) || os(tvOS) || os(visionOS)

import XCTest
import UIKit
@testable import Countly

/// Naming screens without the application having to.
///
/// The SDK swizzles `viewDidAppear` and turns every screen into a view. That makes
/// two things easy to get wrong and invisible when they are: which name a screen
/// reports, and whether the screen the user just left is closed so it reports how
/// long they were on it.
///
/// These push real view controllers through the same callback the swizzle uses.
final class AutoViewTrackingTests: CountlyBaseTestCase {

    /// A view controller with a title, which is what the SDK names a screen by.
    private final class TitledViewController: UIViewController {
        convenience init(named name: String) {
            self.init(nibName: nil, bundle: nil)
            title = name
        }
    }

    /// A screen that names itself, overriding whatever its title says.
    private final class SelfNamingViewController: UIViewController, CountlyAutoViewTrackingName {
        var countlyAutoViewTrackingName: String? { "TheNameIChose" }
    }

    private final class ExcludedByClassViewController: UIViewController {}

    /// Generic, so the runtime only knows it by a mangled name, the same way it
    /// knows a SwiftUI hosting controller.
    private final class GenericViewController<Content>: UIViewController {}

    /// Every `[CLY]_view` event the instance produced, oldest first.
    private func viewEvents(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["key"] as? String == ReservedEventKey.view }
    }

    private func names(of instance: CountlyInstance) -> [String] {
        viewEvents(of: instance).compactMap {
            ($0["segmentation"] as? [String: Any])?[SegKey.name] as? String
        }
    }

    /// Starts an instance with automatic tracking on and waits for it to be live.
    private func trackingInstance(_ adjust: @escaping (CountlyConfig) -> Void = { _ in }) -> CountlyInstance {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.enableAutomaticViewTracking = true
            adjust($0)
        }
        let views = core(of: countly).modules.views
        TestUtils.waitUntil("automatic view tracking is active") { views.isAutoViewTrackingActive }
        return countly
    }

    /// Delivers an appearance the way the swizzled `viewDidAppear` does.
    private func appear(_ viewController: UIViewController) {
        if Thread.isMainThread {
            AutoViewTracker.shared.viewControllerDidAppear(viewController)
        } else {
            DispatchQueue.main.sync { AutoViewTracker.shared.viewControllerDidAppear(viewController) }
        }
    }

    // MARK: - Consent withdrawal

    /// Withdrawing view consent reports the screen open at the time, which only
    /// works while the consent flag still stands.
    func testWithdrawingViewConsentReportsTheScreenThatWasOpen() {
        let countly = trackingInstance {
            $0.requiresConsent = true
            $0.consents = [.events, .viewTracking]
        }

        appear(TitledViewController(named: "OpenWhenConsentWentAway"))
        XCTAssertEqual(names(of: countly), ["OpenWhenConsentWentAway"], "the screen should have opened")

        countly.consent.cancelConsent(for: .viewTracking)

        let closed = viewEvents(of: countly).filter {
            ($0["segmentation"] as? [String: Any])?[SegKey.name] as? String == "OpenWhenConsentWentAway"
        }
        XCTAssertEqual(closed.count, 2, "the open screen should be closed and reported while consent still stands")
    }

    /// A re-grant must not report the same screen again with a duration covering
    /// the opted-out window.
    func testRegrantingViewConsentDoesNotReportAScreenFromTheOptedOutWindow() {
        let countly = trackingInstance {
            $0.requiresConsent = true
            $0.consents = [.events, .viewTracking]
        }

        appear(TitledViewController(named: "OpenedBeforeTheWithdrawal"))
        countly.consent.cancelConsent(for: .viewTracking)
        let afterWithdrawal = viewEvents(of: countly).count

        countly.consent.giveConsent(for: .viewTracking)

        XCTAssertEqual(viewEvents(of: countly).count, afterWithdrawal,
                       "re-granting consent must not report a screen that spans the opted out window")
    }

    // MARK: - Naming a screen

    func testAScreenIsNamedByItsTitle() {
        let countly = trackingInstance()

        appear(TitledViewController(named: "Home"))

        XCTAssertEqual(names(of: countly), ["Home"])
    }

    /// A screen can name itself, which is how an application gives a meaningful
    /// name to a controller whose title is empty or is user-facing copy.
    func testAScreenCanNameItself() {
        let countly = trackingInstance()

        appear(SelfNamingViewController())

        XCTAssertEqual(names(of: countly), ["TheNameIChose"])
    }

    /// A controller with no title of any kind falls back to its class name, which
    /// is still more useful than dropping the screen entirely: a nameless screen in
    /// the report is a hole in the user's journey.
    func testAScreenWithNoTitleFallsBackToItsClassName() {
        let countly = trackingInstance()

        appear(UIViewController())

        XCTAssertEqual(names(of: countly), ["UIViewController"])
    }

    /// A controller that blanks its title, which applications do to shorten a back
    /// button, must not report a nameless view: the empty string is treated as no
    /// title rather than as a name.
    func testABlankedTitleIsTreatedAsNoTitle() {
        let countly = trackingInstance()

        let blank = UIViewController()
        blank.title = ""
        appear(blank)

        XCTAssertEqual(names(of: countly), ["UIViewController"])
    }

    /// A navigation title is used when the controller has no title of its own,
    /// which is where a screen's name usually lives in a navigation stack.
    func testANavigationTitleNamesTheScreen() {
        let countly = trackingInstance()

        let controller = UIViewController()
        controller.navigationItem.title = "FromTheNavigationBar"
        appear(controller)

        XCTAssertEqual(names(of: countly), ["FromTheNavigationBar"])
    }

    /// A custom title view is what an application uses when the name is a label
    /// rather than plain text, and it is read too.
    func testATitleViewLabelNamesTheScreen() {
        let countly = trackingInstance()

        let label = UILabel()
        label.text = "FromTheTitleView"
        let controller = UIViewController()
        controller.navigationItem.titleView = label
        appear(controller)

        XCTAssertEqual(names(of: countly), ["FromTheTitleView"])
    }

    // MARK: - Closing the screen the user left

    /// Each screen is closed when the next one opens, so every one reports how long
    /// the user was on it. Leaving them open would report one duration for a whole
    /// journey instead of one per screen.
    func testEachScreenIsClosedWhenTheNextOneOpens() {
        let countly = trackingInstance()

        appear(TitledViewController(named: "First"))
        TestUtils.pump(1.1)
        appear(TitledViewController(named: "Second"))

        XCTAssertEqual(names(of: countly), ["First", "First", "Second"],
                       "first opens, first closes, second opens")

        let closing = viewEvents(of: countly)[1]
        XCTAssertGreaterThanOrEqual(TestUtils.double(closing["dur"]) ?? 0, 1,
                                    "the closed screen reports how long the user was on it")
    }

    /// The same screen appearing again, as it does when a modal above it is
    /// dismissed, is not a new visit and must not restart the view.
    func testTheSameScreenAppearingAgainDoesNotRestartIt() {
        let countly = trackingInstance()

        appear(TitledViewController(named: "Home"))
        appear(TitledViewController(named: "Home"))

        XCTAssertEqual(names(of: countly), ["Home"])
    }

    // MARK: - The exclusion list

    func testAScreenOnTheExclusionListIsIgnoredByName() {
        let countly = trackingInstance { $0.automaticViewTrackingExclusionList = ["Secret"] }

        appear(TitledViewController(named: "Secret"))
        appear(TitledViewController(named: "Ordinary"))

        XCTAssertEqual(names(of: countly), ["Ordinary"])
    }

    /// Excluding by class name covers a screen whose title changes, and it is what
    /// the default list uses to keep the system's own controllers out.
    func testAScreenCanBeExcludedByItsClassName() {
        let className = NSStringFromClass(ExcludedByClassViewController.self)
        let countly = trackingInstance { $0.automaticViewTrackingExclusionList = [className] }

        let excluded = ExcludedByClassViewController()
        excluded.title = "Should not appear"
        appear(excluded)
        appear(TitledViewController(named: "Ordinary"))

        XCTAssertEqual(names(of: countly), ["Ordinary"])
    }

    func testTheExclusionListCanBeExtendedAfterStart() {
        let countly = trackingInstance()

        countly.views.addAutoViewTrackingExclusionList(["LaterExcluded"])
        appear(TitledViewController(named: "LaterExcluded"))
        appear(TitledViewController(named: "Ordinary"))

        XCTAssertEqual(names(of: countly), ["Ordinary"])
    }

    // MARK: - Gates

    func testNoScreenIsTrackedWithoutViewConsent() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.enableAutomaticViewTracking = true
            $0.requiresConsent = true
        }

        appear(TitledViewController(named: "Blocked"))
        XCTAssertTrue(viewEvents(of: countly).isEmpty)

        countly.consent.giveConsent(for: .viewTracking)
        let views = core(of: countly).modules.views
        TestUtils.waitUntil("automatic view tracking is active") { views.isAutoViewTrackingActive }

        appear(TitledViewController(named: "Allowed"))
        XCTAssertEqual(names(of: countly), ["Allowed"])
    }

    /// The behaviour settings are re-checked on every appearance, so a server
    /// switching view tracking off takes effect on the very next screen rather than
    /// on the next launch.
    func testTheServerCanStopTrackingFromTheNextScreenOnwards() {
        // The tracker is never switched on at all when the server has view tracking
        // off, so this deliberately does not wait for it to become active.
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.enableAutomaticViewTracking = true
            $0.sdkBehaviorSettings = ServerConfigBuilder().viewTracking(false).json()
        }

        appear(TitledViewController(named: "Suppressed"))

        XCTAssertTrue(viewEvents(of: countly).isEmpty)
    }

    /// Once automatic tracking is off, appearances are ignored and the application
    /// is free to record views itself.
    func testAppearancesAreIgnoredOnceTrackingIsStopped() {
        let countly = trackingInstance()

        appear(TitledViewController(named: "Tracked"))
        core(of: countly).modules.views.stopAutoViewTracking()
        appear(TitledViewController(named: "NotTracked"))

        XCTAssertFalse(names(of: countly).contains("NotTracked"))
    }

    /// A halted instance must stop hearing about screens, or the tracker keeps
    /// naming views for an SDK that is no longer running.
    func testAHaltedInstanceStopsHearingAboutScreens() {
        let countly = trackingInstance()

        appear(TitledViewController(named: "BeforeHalt"))
        countly.halt()

        // The swizzle outlives the last subscriber on purpose, so this has to be
        // safe rather than merely unobserved.
        appear(TitledViewController(named: "AfterHalt"))
    }

    // MARK: - Several instances

    /// Each instance applies its own exclusion list and consent to the same
    /// appearance, which is what makes two tenants in one application possible.
    func testEachInstanceAppliesItsOwnExclusionList() {
        let tracking = trackingInstance { $0.automaticViewTrackingExclusionList = ["Shared"] }
        let other = trackingInstance()

        appear(TitledViewController(named: "Shared"))

        XCTAssertFalse(names(of: tracking).contains("Shared"), "excluded here")
        XCTAssertTrue(names(of: other).contains("Shared"), "not excluded there")
    }

    // MARK: - Opting out of the method exchange

    /// Runs the main queue until everything `start(with:)` deferred to it has
    /// run. The main queue is serial and first in first out, so a block enqueued
    /// after start returns cannot run before the SDK's own. Asserting without
    /// this passes whatever the flag does, because nothing has happened yet.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    /// The exchange is the only source of appearances, so refusing it refuses the
    /// feature. Leaving the module active instead would be worse than off: the
    /// active flag makes it reject the host's own view calls too.
    func testDisablingSwizzlingLeavesAutomaticViewTrackingOff() {
        let countly = startInstance {
            $0.enableAutomaticViewTracking = true
            $0.disableSwizzling = true
        }
        drainMainQueue()

        XCTAssertFalse(core(of: countly).modules.views.isAutoViewTrackingActive,
                       "automatic view tracking cannot run without the method exchange")
    }

    /// The contract the flag exists for: with the exchange refused, the host
    /// reports its own screens and the SDK accepts them. The public API is what
    /// a host and the SwiftUI modifier both use, so that is what is driven here.
    func testDisablingSwizzlingLetsTheHostReportScreensItself() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.enableAutomaticViewTracking = true
            $0.disableSwizzling = true
        }
        drainMainQueue()

        countly.views.startView("Settings")
        countly.views.stopView(name: "Settings")

        XCTAssertTrue(names(of: countly).contains("Settings"),
                      "a screen the host reported should reach the server, found: [\(names(of: countly))]")
    }

    /// A SwiftUI screen reports itself even while automatic tracking runs. The
    /// method exchange never sees a SwiftUI screen, so this is not the second view
    /// for one screen that the manual call gate exists to prevent.
    func testAReportedViewIsAcceptedWhileAutomaticTrackingIsOn() {
        let countly = trackingInstance()

        let id = countly.views.startReportedView("Settings", segmentation: nil)

        XCTAssertNotNil(id, "the reported view should not be refused as a manual call")
        XCTAssertTrue(names(of: countly).contains("Settings"))
    }

    // MARK: - Screens with only a mangled class name

    /// A screen known only by a compiler-mangled class name is not reported under
    /// it, but the screen the user left is still closed, so its duration stops
    /// where the user actually left it.
    func testAScreenWithOnlyAMangledClassNameIsNotReportedButClosesThePreviousOne() {
        let countly = trackingInstance()
        let views = core(of: countly).modules.views

        views.handleAutoTrackedViewController(TitledViewController(named: "Cart"))
        views.handleAutoTrackedViewController(GenericViewController<Int>())

        XCTAssertFalse(names(of: countly).contains { $0.hasPrefix("_Tt") },
                       "no mangled class name should reach the dashboard, found: [\(names(of: countly))]")
        XCTAssertEqual(names(of: countly).filter { $0 == "Cart" }.count, 2,
                       "the screen the user left should be closed, a start and an end")
    }

    /// The same screen with a title is reported under it, as any other.
    func testAScreenWithAMangledClassNameIsReportedWhenItHasATitle() {
        let countly = trackingInstance()
        let screen = GenericViewController<Int>()
        screen.title = "Checkout"

        core(of: countly).modules.views.handleAutoTrackedViewController(screen)

        XCTAssertTrue(names(of: countly).contains("Checkout"))
    }

    /// Swizzling is allowed by default, so enabling automatic view tracking
    /// alone starts it.
    func testLeavingSwizzlingEnabledStartsAutomaticViewTracking() {
        let countly = trackingInstance()

        XCTAssertTrue(core(of: countly).modules.views.isAutoViewTrackingActive)
    }

}

#endif
