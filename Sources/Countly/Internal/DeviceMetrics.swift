//
//  DeviceMetrics.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if os(watchOS)
import WatchKit
#endif
#if os(macOS)
import AppKit
import IOKit.ps
#endif
#if canImport(CoreTelephony) && os(iOS) && !targetEnvironment(macCatalyst)
import CoreTelephony
#endif

/// Facts about the device and the build.
///
/// Everything here describes the process, not an instance, so it is static: two
/// Countly instances in one application see the same device. The only per-instance
/// part of metrics is the custom metrics dictionary, which lives on the instance.
extension UInt64 {
    /// Zero when the subtraction that produced this value underflowed.
    func clampedToZero(_ isValid: Bool) -> UInt64 { isValid ? self : 0 }
}

enum DeviceMetrics {

    // MARK: - Hardware

    /// Hardware identifier such as `iPhone16,1`.
    static var device: String {
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        return sysctlString(key) ?? ""
    }

    /// Broad device class the dashboard groups by.
    static var deviceType: String? {
        #if targetEnvironment(macCatalyst)
        return "desktop"
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "mobile"
        #elseif os(watchOS)
        return "wearable"
        #elseif os(tvOS)
        return "smarttv"
        #elseif os(macOS)
        return "desktop"
        #elseif os(visionOS)
        return "vr"
        #else
        return nil
        #endif
    }

    /// CPU architecture of the running process.
    static var architecture: String? {
        var type = cpu_type_t()
        var size = MemoryLayout<cpu_type_t>.size
        guard sysctlbyname("hw.cputype", &type, &size, nil, 0) == 0 else { return nil }

        switch type {
        case CPU_TYPE_ARM64: return "arm64"
        case CPU_TYPE_ARM: return "armv7"
        case CPU_TYPE_ARM64_32: return "arm64_32"
        case CPU_TYPE_X86, CPU_TYPE_X86_64: return "x86_64"
        default: return nil
        }
    }

    // MARK: - Operating system

    static var osName: String? {
        #if os(iOS)
        return "iOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return nil
        #endif
    }

    static var osVersion: String? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        return UIDevice.current.systemVersion
        #elseif os(watchOS)
        return WKInterfaceDevice.current().systemVersion
        #elseif os(macOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #else
        return nil
        #endif
    }

    /// Cellular carrier name.
    ///
    /// Always `nil` on iOS 16.4 and later: the platform API is deprecated there and
    /// answers `--` for anything built against that SDK, which is worse than
    /// reporting nothing.
    static var carrier: String? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 16.4, *) {
            return nil
        } else {
            return CTTelephonyNetworkInfo().subscriberCellularProvider?.carrierName
        }
        #else
        // CoreTelephony is not available on watchOS, tvOS, macOS or visionOS.
        return nil
        #endif
    }

    // MARK: - Screen

    /// Screen size in pixels, `<width>x<height>`.
    ///
    /// Read from the key window rather than the screen where possible, because on
    /// iPad multitasking the window is what the application actually occupies.
    static var resolution: String? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        guard let window = ScreenReader.keyWindow else { return nil }
        let bounds = window.bounds
        let scale = window.traitCollection.displayScale
        return String(format: "%gx%g", bounds.size.width * scale, bounds.size.height * scale)
        #elseif os(watchOS)
        let bounds = WKInterfaceDevice.current().screenBounds
        let scale = WKInterfaceDevice.current().screenScale
        return String(format: "%gx%g", bounds.size.width * scale, bounds.size.height * scale)
        #elseif os(macOS)
        guard let screen = NSScreen.main else { return nil }
        let bounds = screen.frame
        let scale = screen.backingScaleFactor
        return String(format: "%gx%g", bounds.size.width * scale, bounds.size.height * scale)
        #else
        return nil
        #endif
    }

    /// Screen scale, `@2x` style.
    static var density: String? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        return "@\(Int(ScreenReader.screenScale))x"
        #elseif os(watchOS)
        return "@\(Int(WKInterfaceDevice.current().screenScale))x"
        #elseif os(macOS)
        guard let screen = NSScreen.main else { return nil }
        return "@\(Int(screen.backingScaleFactor))x"
        #else
        return nil
        #endif
    }

    /// `d` for dark, `l` for light, `nil` when the platform has no notion of it.
    ///
    /// Read from the key window, because in-app messages render in that window and
    /// its style is the theme they will be shown against.
    static var themeMode: String? {
        #if os(iOS) || os(tvOS)
        let traits = ScreenReader.keyWindow?.traitCollection ?? UIScreen.main.traitCollection
        switch traits.userInterfaceStyle {
        case .dark: return "d"
        case .light: return "l"
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Appends the current theme to a URL that will be loaded in a web view, so
    /// the widget renders against the same theme as the application.
    static func urlStringByAppendingThemeMode(_ url: String) -> String {
        urlString(url, byAppendingThemeMode: themeMode)
    }

    /// The separator and omission logic, split out so it is testable without a
    /// running interface style.
    /// When the process this SDK is running in was started, in milliseconds since
    /// the epoch.
    ///
    /// The app start trace measures how long the application took to become
    /// usable, so it has to start where the process did. Reading the clock when
    /// the SDK is constructed measures from `start(with:)` instead, which throws
    /// away exactly the part the metric exists to report: an application that
    /// spends most of its launch on its own work before starting Countly would
    /// report the small remainder as its launch time.
    ///
    /// The reference SDK approximates this by stamping the clock in a `+load`
    /// method. Swift has no equivalent, and the kernel knows the real answer, so
    /// this asks it directly. If the query fails the current time is returned,
    /// which yields a zero-ish duration rather than a wrong one.
    static func processStartTimestampMs() -> Int64 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = sysctl(&name, UInt32(name.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }

        let started = info.kp_proc.p_starttime
        return Int64(started.tv_sec) * 1000 + Int64(started.tv_usec) / 1000
    }

    static func urlString(_ url: String, byAppendingThemeMode theme: String?) -> String {
        guard let theme, !theme.isEmpty else { return url }
        let separator = url.contains("?") ? "&" : "?"
        return "\(url)\(separator)\(QS.theme)=\(theme)"
    }

    // MARK: - Locale and bundle

    static var locale: String { Locale.current.identifier }

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    static var appBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String) ?? ""
    }

    // MARK: - Metrics payload

    /// The metrics dictionary sent with `begin_session` and metric overrides.
    ///
    /// Custom metrics are merged last, so a host application can override any SDK
    /// collected value.
    static func metricsDictionary(customMetrics: [String: String], logger: Logger?) -> [String: String] {
        var metrics: [String: String] = [:]
        metrics[MetricKey.device] = device
        metrics[MetricKey.deviceType] = deviceType
        metrics[MetricKey.os] = osName
        metrics[MetricKey.osVersion] = osVersion
        metrics[MetricKey.appVersion] = appVersion
        metrics[MetricKey.carrier] = carrier
        metrics[MetricKey.resolution] = resolution
        metrics[MetricKey.density] = density
        metrics[MetricKey.locale] = locale

        metrics.merge(customMetrics) { _, custom in custom }

        logger?.d("DeviceMetrics", "metricsDictionary", "metrics collected, keys: [\(metrics.keys.sorted())], count: [\(metrics.count)]")
        logger?.v("DeviceMetrics", "metricsDictionary", "collected metrics dictionary value detail, metrics: [\(metrics)]")

        return metrics
    }

    // MARK: - Crash enrichment

    /// How the device is currently connected: 0 none, 1 wifi, 2 cellular.
    static var connectionType: Int {
        var connection = 0
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return connection }
        defer { freeifaddrs(interfaces) }

        var pointer = interfaces
        while let current = pointer {
            if let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                if name == "pdp_ip0" {
                    connection = 2
                } else if name == "en0" {
                    connection = 1
                    break
                }
            }
            pointer = current.pointee.ifa_next
        }
        return connection
    }

    static var freeRAM: UInt64 {
        var stats = vm_statistics_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_VM_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(vm_page_size) * UInt64(stats.free_count)
    }

    static var totalRAM: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Free and total disk in one reading.
    ///
    /// Returned together because they come from a single filesystem call, and a
    /// crash report needs both.
    static func diskSpace() -> (free: UInt64, total: UInt64) {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) else {
            return (0, 0)
        }
        return ((attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0,
                (attributes[.systemSize] as? NSNumber)?.uint64Value ?? 0)
    }

    /// Battery percentage, or `-1` when it cannot be read.
    static var batteryLevel: Int {
        #if os(iOS) || os(visionOS)
        guard UIDevice.current.batteryState != .unknown else { return -1 }
        return abs(Int(UIDevice.current.batteryLevel * 100))
        #elseif os(watchOS)
        return abs(Int(WKInterfaceDevice.current().batteryLevel * 100))
        #elseif os(macOS)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int,
              maximum > 0 else { return 100 }
        return Int(Double(current) / Double(maximum) * 100)
        #else
        return -1
        #endif
    }

    static var orientation: String? {
        #if os(iOS)
        let names = ["Unknown", "Portrait", "PortraitUpsideDown", "LandscapeLeft", "LandscapeRight", "FaceUp", "FaceDown"]
        let raw = UIDevice.current.orientation.rawValue
        guard raw >= 0, raw < names.count else { return nil }
        return names[Int(raw)]
        #elseif os(watchOS)
        let names = ["CrownLeft", "CrownRight"]
        let raw = WKInterfaceDevice.current().crownOrientation.rawValue
        guard raw >= 0, raw < names.count else { return nil }
        return names[Int(raw)]
        #else
        return nil
        #endif
    }

    /// Whether a shell is reachable, the cheapest jailbreak signal available.
    static var isJailbroken: Bool {
        guard let file = fopen("/bin/bash", "r") else { return false }
        fclose(file)
        return true
    }

    // MARK: - Helpers

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
/// Window and screen lookups, isolated so the platform conditionals stay in one
/// place.
enum ScreenReader {

    /// The window the application is presenting in, preferring the active scene.
    ///
    /// Scenes only exist from iOS 13; before that the application had a single
    /// window list, which is what the fallback reads.
    static var keyWindow: UIWindow? {
        if #available(iOS 13.0, tvOS 13.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                    return key
                }
                if let first = windowScene.windows.first {
                    return first
                }
            }
            return nil
        }

        #if os(visionOS)
        return nil
        #else
        return UIApplication.shared.windows.first { $0.isKeyWindow } ?? UIApplication.shared.windows.first
        #endif
    }

    /// Scale of the window the application is presenting in.
    ///
    /// visionOS has no `UIScreen`, so there is nothing to fall back to there.
    static var screenScale: CGFloat {
        #if os(visionOS)
        return keyWindow?.traitCollection.displayScale ?? 2.0
        #else
        return keyWindow?.traitCollection.displayScale ?? UIScreen.main.scale
        #endif
    }

    static var screenBounds: CGRect {
        #if os(visionOS)
        return keyWindow?.bounds ?? .zero
        #else
        return keyWindow?.bounds ?? UIScreen.main.bounds
        #endif
    }
}
#endif

#if os(macOS)
/// Screen lookups for the overlay, mirroring the UIKit reader above.
///
/// A macOS application has no single "key window" the SDK should present over, and
/// content is shown in a panel of its own, so what matters here is the screen the
/// user is actually looking at rather than any window of the host's.
enum ScreenReader {

    /// The screen carrying the application's key window, or the main screen.
    static var activeScreen: NSScreen? {
        NSApplication.shared.keyWindow?.screen ?? NSScreen.main
    }

    /// Backing scale of the screen content will be shown on.
    static var screenScale: CGFloat {
        activeScreen?.backingScaleFactor ?? 2.0
    }

    /// The area content may occupy: the screen minus the menu bar and the Dock,
    /// which is what `visibleFrame` reports.
    ///
    /// Origin is dropped to zero because the overlay panel is positioned by the
    /// window server, and the geometry a content page sends is relative to the
    /// overlay rather than to the desktop.
    static var screenBounds: CGRect {
        guard let screen = activeScreen else { return .zero }
        return CGRect(origin: .zero, size: screen.visibleFrame.size)
    }
}
#endif

