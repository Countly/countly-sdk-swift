//
//  CrashModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation
import Darwin
import MachO

/// Captures crashes and handled errors, with the context needed to symbolicate
/// them later.
///
/// A crash the SDK detects itself is written to disk while the process goes down
/// and sent on the next launch. Everything else goes through the normal queue.
final class CrashModule: ModuleBase {

    override class var moduleName: String { "Crash" }

    /// Keys of the crash payload.
    private enum Key {
        static let binaryImages = "_binary_images"
        static let os = "_os"
        static let osVersion = "_os_version"
        static let device = "_device"
        static let architecture = "_architecture"
        static let resolution = "_resolution"
        static let appVersion = "_app_version"
        static let appBuild = "_app_build"
        static let buildUUID = "_build_uuid"
        static let executableName = "_executable_name"
        static let name = "_name"
        static let type = "_type"
        static let error = "_error"
        static let nonfatal = "_nonfatal"
        static let ramCurrent = "_ram_current"
        static let ramTotal = "_ram_total"
        static let diskCurrent = "_disk_current"
        static let diskTotal = "_disk_total"
        static let battery = "_bat"
        static let orientation = "_orientation"
        static let online = "_online"
        static let root = "_root"
        static let background = "_background"
        static let run = "_run"
        static let custom = "_custom"
        static let logs = "_logs"
        static let changedFields = "_ob"
        static let imageLoadAddress = "la"
        static let imageBuildUUID = "id"
    }

    private static let mebibyte: UInt64 = 1_048_576

    /// Guards everything mutable in this module.
    ///
    /// One lock rather than one per field: `setCrashSegmentation` and a consent
    /// change are both public entry points reachable from any thread, and a crash
    /// arriving in between reads the segmentation and the handler flag together.
    private let stateLock = NSRecursiveLock()

    /// Breadcrumbs kept in memory for this run. Guarded by `stateLock`.
    private var breadcrumbs: [String] = []

    /// Global segmentation merged into every report. Guarded by `stateLock`.
    private var crashSegmentation: [String: Any] = [:]

    /// Whether this instance installed the process-wide handlers. Guarded by
    /// `stateLock`.
    private var isHandlerInstalled = false

    // MARK: - Init

    func applyInitialConfig() {
        logD("applyInitialConfig", "crash module starting, crashSegmentationInConfig: [\(core.config.crashSegmentation != nil)], crashFilterRegexSet: [\(core.config.crashFilter != nil)], crashFilterCallbackSet: [\(core.config.crashes.crashFilterCallback != nil)], shouldSendCrashReportCallbackSet: [\(core.config.shouldSendCrashReportCallback != nil)], maxBreadcrumbCount: [\(core.config.sdkInternalLimits.maxBreadcrumbCount)]")

        if let segmentation = core.config.crashSegmentation {
            setCrashSegmentation(segmentation)
        }
        adoptBreadcrumbsFromPreviousRun()
    }

    /// Sets the segmentation merged into every crash report.
    func setCrashSegmentation(_ segmentation: [String: Any]) {
        logI("setCrashSegmentation", "global crash segmentation is being set, keyCount: [\(segmentation.count)]")
        logD("setCrashSegmentation", "global crash segmentation keys, keys: [\(segmentation.keys.sorted().joined(separator: ", "))]")
        logV("setCrashSegmentation", "global crash segmentation detail, segmentation: [\(segmentation)]")

        let sanitized = limits.truncatedAndLimited(segmentation, "Crash segmentation")
        if sanitized.count < segmentation.count {
            logD("setCrashSegmentation", "some global crash segmentation keys were dropped by the SDK limits, keptKeyCount: [\(sanitized.count)], requestedKeyCount: [\(segmentation.count)]")
        }

        stateLock.lock()
        crashSegmentation = sanitized
        stateLock.unlock()
    }

    // MARK: - Handler installation

    /// Installs the uncaught exception and signal handlers.
    ///
    /// Idempotent, because it is reached from init, from a consent change, and
    /// from a behavior settings response that may land on any thread.
    func startCrashReporting() {
        guard core.serverConfig.automaticCrashReportingEnabled else {
            logD("startCrashReporting", "crash handlers are not installed, automatic crash reporting is disabled")
            return
        }

        // Every instance would record the same crash, so a named one does only when its developer asked for it.
        guard core.namespace.isDefault || core.config.features.contains(.crashReporting) else {
            logD("startCrashReporting", "crash handlers are not installed, a named instance reports crashes only when its own config enables crash reporting")
            return
        }

        guard core.modules.consent.hasConsent(for: .crashReporting) else {
            logV("startCrashReporting", "no crashes consent given, crash handlers are not installed")
            return
        }

        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isHandlerInstalled else {
            logD("startCrashReporting", "crash handlers are already installed, nothing to do")
            return
        }

        logD("startCrashReporting", "installing the built in uncaught exception handler and signal handlers")
        CrashHandlerInstaller.shared.register(self)
        isHandlerInstalled = true
    }

    /// Stops reporting and drops the breadcrumbs.
    ///
    /// Reachable from the crash handler itself, so every log line here stays at
    /// debug or lower.
    func stopCrashReporting() {
        // Breadcrumbs are gathered under crash consent alone, so they can exist
        // even when no handler was ever installed and a consent withdrawal has to
        // drop them either way.
        clearCrashLogs()

        stateLock.lock()
        defer { stateLock.unlock() }

        guard isHandlerInstalled else {
            logD("stopCrashReporting", "crash handler uninstall is a no-op, no crash handlers were installed by this instance")
            return
        }

        logD("stopCrashReporting", "uninstalling this instance from the crash handlers")
        CrashHandlerInstaller.shared.deregister(self)
        isHandlerInstalled = false
    }

    // MARK: - Recording

    /// Records an exception, fatal or handled.
    func recordException(_ exception: NSException,
                         isFatal: Bool,
                         stackTrace: [String]?,
                         segmentation: [String: Any]?) {
        logI("recordException", "exception recording requested, exceptionName: [\(exception.name.rawValue)], isFatal: [\(isFatal)], stackTraceFrameCount: [\(stackTrace?.count ?? 0)], segmentationKeyCount: [\(segmentation?.count ?? 0)]")
        if let segmentation, !segmentation.isEmpty {
            logD("recordException", "exception recording segmentation keys, keys: [\(segmentation.keys.sorted().joined(separator: ", "))]")
        }
        logV("recordException", "exception recording detail, exception: [\(exception)], stackTrace: [\(stackTrace ?? [])], segmentation: [\(segmentation ?? [:])]")

        guard core.modules.consent.hasConsent(for: .crashReporting) else {
            logV("recordException", "no crashes consent given, exception is not recorded")
            return
        }

        let frames = stackTrace ?? exception.callStackSymbols
        logD("recordException", "stack trace resolved for the exception, suppliedByCaller: [\(stackTrace != nil)], frameCount: [\(frames.count)]")

        let overrides = limits.sanitized(segmentation, "Exception segmentation")

        handle(name: exception.name.rawValue,
               description: exception.reason ?? exception.name.rawValue,
               stackTrace: frames,
               userInfo: exception.userInfo as? [String: Any] ?? [:],
               segmentationOverride: overrides,
               isFatal: isFatal,
               isAutoDetected: false)
    }

    /// Records an error described by a name rather than an exception.
    func recordError(_ errorName: String,
                     isFatal: Bool,
                     stackTrace: [String]?,
                     segmentation: [String: Any]?) {
        logI("recordError", "error recording requested, errorNameLength: [\(errorName.count)], isFatal: [\(isFatal)], stackTraceFrameCount: [\(stackTrace?.count ?? 0)], segmentationKeyCount: [\(segmentation?.count ?? 0)]")
        logV("recordError", "error recording detail, errorName: [\(errorName)], stackTrace: [\(stackTrace ?? [])], segmentation: [\(segmentation ?? [:])]")

        let exception = NSException(name: NSExceptionName("Swift Error"), reason: errorName, userInfo: nil)
        recordException(exception, isFatal: isFatal, stackTrace: stackTrace, segmentation: segmentation)
    }

    /// Called by the process-wide handler when a crash is detected.
    ///
    /// Stores the report for the next launch to send.
    func handleAutoDetectedCrash(name: String, reason: String, stackTrace: [String]) {
        // Reached from the signal handler, so nothing here may log at error or
        // warning: those bump the health tracker, whose dispatch primitives are
        // not async signal safe and can deadlock the process mid crash.
        logD("handleAutoDetectedCrash", "an automatically detected crash arrived, crashName: [\(name)], stackTraceFrameCount: [\(stackTrace.count)]")

        guard core.serverConfig.crashReportingEnabled else {
            logD("handleAutoDetectedCrash", "the detected crash is not reported, crash reporting is disabled by server config")
            return
        }

        guard core.serverConfig.automaticCrashReportingEnabled else {
            logD("handleAutoDetectedCrash", "the detected crash is not reported, automatic crash reporting is disabled by server config")
            return
        }

        guard core.modules.consent.hasConsent(for: .crashReporting) else {
            logD("handleAutoDetectedCrash", "the detected crash is not reported, no crashes consent is given")
            return
        }

        handle(name: name,
               description: reason,
               stackTrace: stackTrace,
               userInfo: [:],
               segmentationOverride: nil,
               isFatal: true,
               isAutoDetected: true)
    }

    /// Builds the report, gives the filter callback a say, and queues it.
    ///
    /// An automatically detected crash is only stored, for the next launch to
    /// send; everything else joins the queue and starts a drain.
    private func handle(name: String,
                        description: String,
                        stackTrace: [String],
                        userInfo: [String: Any],
                        segmentationOverride: [String: Any]?,
                        isFatal: Bool,
                        isAutoDetected: Bool) {
        guard core.serverConfig.crashReportingEnabled else {
            logD("handle", "crash report is dropped before it is built, crash reporting is disabled by server config, isFatal: [\(isFatal)], isAutoDetected: [\(isAutoDetected)]")
            return
        }

        // Limited before anything reads it, so the regular expression filter, the
        // filter callback and the wire report all see the same trace.
        let stackTrace = limits.truncatedStackTrace(stackTrace, "Crash stack trace")
        let stackTraceJoined = stackTrace.joined(separator: "\n")

        var matchesFilter = false
        if let filter = core.config.crashFilter {
            let matchedStackTrace = matches(filter, stackTraceJoined)
            let matchedDescription = matches(filter, description)
            let matchedName = matches(filter, name)
            matchesFilter = matchedStackTrace || matchedDescription || matchedName

            if matchesFilter {
                logD("handle", "the crash filter regular expression matched, matchedStackTrace: [\(matchedStackTrace)], matchedDescription: [\(matchedDescription)], matchedName: [\(matchedName)]")
            }
        }

        stateLock.lock()
        var custom = crashSegmentation
        let currentBreadcrumbs = breadcrumbs
        stateLock.unlock()

        if let segmentationOverride {
            custom.merge(segmentationOverride) { _, new in new }
        }
        custom.merge(userInfo) { _, new in new }

        let filterCallback = core.config.crashes.crashFilterCallback

        let crashData = CountlyCrashData(
            stackTrace: stackTraceJoined,
            name: name,
            crashDescription: description,
            crashSegmentation: limits.sanitized(custom, "Exception segmentation") ?? [:],
            breadcrumbs: currentBreadcrumbs,
            crashMetrics: crashMetrics(),
            fatal: isFatal,
            // Fourteen digests over the stack trace and every collection, needed
            // only to detect what the callback changed. Skipped when there is no
            // callback, which is the common case.
            trackChanges: filterCallback != nil)

        let filteredByCallback = filterCallback?(crashData) ?? false

        guard !matchesFilter, !filteredByCallback else {
            logD("handle", "crash report is filtered out and will not be processed, crashName: [\(name)], isFatal: [\(isFatal)], matchesRegexFilter: [\(matchesFilter)], matchesFilterCallback: [\(filteredByCallback)]")
            if isAutoDetected { stopCrashReporting() }
            return
        }

        let report = wireReport(for: crashData,
                                stackTrace: stackTrace,
                                hadFilterCallback: filterCallback != nil)

        if let shouldSend = core.config.shouldSendCrashReportCallback, !shouldSend(report) {
            logD("handle", "crash report is dropped by the shouldSendCrashReport callback, crashName: [\(name)], isFatal: [\(isFatal)], reportFieldCount: [\(report.count)]")
            if isAutoDetected { stopCrashReporting() }
            return
        }

        logI("handle", "crash recorded, crashName: [\(name)], isFatal: [\(crashData.fatal)], isAutoDetected: [\(isAutoDetected)], delivery: [\(isAutoDetected ? "next launch" : "queued")], customSegmentationKeyCount: [\(crashData.crashSegmentation.count)], breadcrumbCount: [\(crashData.breadcrumbs.count)], stackTraceFrameCount: [\(stackTrace.count)]")
        logV("handle", "crash detail, breadcrumbs: [\(crashData.breadcrumbs)], crashSegmentation: [\(crashData.crashSegmentation)], stackTrace: [\(crashData.stackTrace)]")

        // `CountlyJSON` reports a serialization failure at error level, and an
        // automatically detected crash comes off the signal handler where error
        // logging is not safe. That path therefore serializes without a logger and
        // reports the failure itself at debug.
        let payload = CountlyJSON.string(from: report, logger: isAutoDetected ? nil : log)
        if payload == nil {
            logD("handle", "the crash report could not be serialized to JSON and will not be sent, crashName: [\(name)], isAutoDetected: [\(isAutoDetected)]")
        }

        guard isAutoDetected else {
            core.network.sendCrashReport(payload?.urlEscaped)
            return
        }

        core.network.storeCrashReport(payload?.urlEscaped)

        // The stored report carries the breadcrumbs, which the next launch would
        // attach again, and a handler left installed would re-enter on the way down.
        stopCrashReporting()
    }

    /// Turns the assembled crash data into the payload the server reads.
    ///
    /// - Parameter hadFilterCallback: whether the host application was given the
    ///   report to change, which decides whether the segmentation has to be
    ///   sanitized again.
    private func wireReport(for crashData: CountlyCrashData,
                            stackTrace: [String],
                            hadFilterCallback: Bool) -> [String: Any] {
        // The metrics are the SDK's own keys, so only their value types need
        // checking, and only when a callback had the chance to change them. One
        // value JSON cannot carry would otherwise make the whole report
        // serialize to nothing.
        var report = hadFilterCallback
            ? limits.filterSupportedDataTypes(crashData.crashMetrics)
            : crashData.crashMetrics
        report[Key.error] = crashData.stackTrace
        let symbolication = binaryImages(for: stackTrace)
        report[Key.binaryImages] = symbolication.images
        report[Key.buildUUID] = symbolication.buildUUID ?? ""
        report[Key.executableName] = symbolication.executableName ?? ""
        report[Key.architecture] = symbolication.architecture
        report[Key.name] = crashData.crashDescription
        report[Key.type] = crashData.name
        report[Key.nonfatal] = !crashData.fatal

        // Tells the server which fields the host application's filter changed, so
        // a doctored report is not mistaken for a raw one.
        crashData.calculateChangedFields()
        let changed = crashData.changedFieldsBitfield
        if changed > 0 {
            logD("wireReport", "the crash filter callback changed the report, the server is told which fields, changedFieldsBitfield: [\(changed)]")
            report[Key.changedFields] = changed
        }

        if !crashData.crashSegmentation.isEmpty {
            // Sanitized rather than merely capped when there was a callback that
            // could have changed the segmentation. `CountlyCrashData` is a class,
            // so an enriching callback would otherwise ship unbounded keys and
            // values, and a value JSON cannot represent would make the whole
            // report serialize to nothing and be lost. Without a callback the
            // dictionary is still exactly what was sanitized on the way in, and
            // redoing that is pure rework on every recorded error.
            report[Key.custom] = hadFilterCallback
                ? (limits.sanitized(crashData.crashSegmentation, "Crash segmentation") ?? [:])
                : crashData.crashSegmentation
        }

        if !crashData.breadcrumbs.isEmpty {
            report[Key.logs] = crashData.breadcrumbs.joined(separator: "\n")
        }

        return report
    }

    private func matches(_ filter: NSRegularExpression, _ text: String) -> Bool {
        filter.numberOfMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) > 0
    }

    // MARK: - Breadcrumbs

    /// Records a breadcrumb, dropping the oldest when the buffer is full.
    func log(_ text: String) {
        logI("log", "crash breadcrumb recording requested, textLength: [\(text.count)]")

        guard core.modules.consent.hasConsent(for: .crashReporting) else {
            logV("log", "no crashes consent given, breadcrumb is not recorded")
            return
        }

        let truncated = limits.truncatedValue(text, "Custom Crash log")
        logV("log", "breadcrumb text detail, log: [\(truncated)]")

        stateLock.lock()
        defer { stateLock.unlock() }

        breadcrumbs.append(truncated)
        let limit = core.config.sdkInternalLimits.maxBreadcrumbCount
        if breadcrumbs.count > limit {
            logD("log", "breadcrumb buffer is full, the oldest breadcrumb is dropped, breadcrumbCount: [\(breadcrumbs.count)], limit: [\(limit)]")
            breadcrumbs.removeFirst()
        } else {
            logD("log", "breadcrumb added to the in memory buffer, breadcrumbCount: [\(breadcrumbs.count)]")
        }

        // Also written to disk, so the run that crashes can still contribute its
        // breadcrumbs: the in-memory buffer dies with the process.
        core.crashLogStore.append(truncated)
    }

    /// Drops every breadcrumb, in memory and on disk.
    func clearCrashLogs() {
        stateLock.lock()
        logD("clearCrashLogs", "breadcrumbs are being cleared, breadcrumbCount: [\(breadcrumbs.count)]")
        breadcrumbs.removeAll()
        stateLock.unlock()

        core.crashLogStore.deleteAll()
    }

    /// Breadcrumbs left behind by a run that did not get to send them.
    ///
    /// Read once at init and cleared, so they are attached to the next report
    /// rather than to every future one.
    func adoptBreadcrumbsFromPreviousRun() {
        guard let stored = core.crashLogStore.readAll(), !stored.isEmpty else {
            logD("adoptBreadcrumbsFromPreviousRun", "no breadcrumbs were left behind by a previous run")
            return
        }

        let recovered = stored.split(separator: "\n").map(String.init)
        guard !recovered.isEmpty else {
            logD("adoptBreadcrumbsFromPreviousRun", "the stored breadcrumbs from a previous run held no usable lines, storedLength: [\(stored.count)]")
            return
        }

        logD("adoptBreadcrumbsFromPreviousRun", "breadcrumbs from a previous run were found, breadcrumbCount: [\(recovered.count)]")

        let limit = core.config.sdkInternalLimits.maxBreadcrumbCount
        if recovered.count > limit {
            logD("adoptBreadcrumbsFromPreviousRun", "the recovered breadcrumbs exceed the buffer limit, the oldest ones are dropped, breadcrumbCount: [\(recovered.count)], limit: [\(limit)]")
        }

        stateLock.lock()
        breadcrumbs = Array(recovered.suffix(limit))
        stateLock.unlock()

        core.crashLogStore.deleteAll()
    }

    // MARK: - Context

    /// Device state at the moment of the crash.
    private func crashMetrics() -> [String: Any] {
        var metrics: [String: Any] = [:]
        metrics[Key.os] = DeviceMetrics.osName
        metrics[Key.osVersion] = DeviceMetrics.osVersion
        metrics[Key.device] = DeviceMetrics.device
        metrics[Key.resolution] = DeviceMetrics.resolution
        metrics[Key.appVersion] = DeviceMetrics.appVersion
        metrics[Key.appBuild] = DeviceMetrics.appBuild

        // Subtracted with a floor: a reading that reports free space without total
        // space would underflow, and an unsigned underflow traps in Swift, inside
        // the crash reporter.
        let totalRAM = DeviceMetrics.totalRAM
        let freeRAM = DeviceMetrics.freeRAM
        let disk = DeviceMetrics.diskSpace()
        let usedRAMMB = totalRAM.subtractingReportingOverflow(freeRAM).partialValue.clampedToZero(totalRAM >= freeRAM) / Self.mebibyte
        let totalRAMMB = totalRAM / Self.mebibyte
        let usedDiskMB = disk.total.subtractingReportingOverflow(disk.free).partialValue.clampedToZero(disk.total >= disk.free) / Self.mebibyte
        let totalDiskMB = disk.total / Self.mebibyte
        metrics[Key.ramCurrent] = usedRAMMB
        metrics[Key.ramTotal] = totalRAMMB
        metrics[Key.diskCurrent] = usedDiskMB
        metrics[Key.diskTotal] = totalDiskMB

        // Only reported when the platform actually knows it, so a missing reading
        // is not recorded as a real battery level.
        let battery = DeviceMetrics.batteryLevel
        if battery >= 0 {
            metrics[Key.battery] = battery
        }

        metrics[Key.orientation] = DeviceMetrics.orientation
        metrics[Key.online] = DeviceMetrics.connectionType != 0 ? 1 : 0
        metrics[Key.root] = DeviceMetrics.isJailbroken
        metrics[Key.background] = !AppState.isForeground
        metrics[Key.run] = core.clock.timeSinceLaunch()

        logD("crashMetrics", "device state captured for the crash report, ramUsedMB: [\(usedRAMMB)], ramTotalMB: [\(totalRAMMB)], diskUsedMB: [\(usedDiskMB)], diskTotalMB: [\(totalDiskMB)], batteryReported: [\(battery >= 0)], online: [\(DeviceMetrics.connectionType != 0)], inBackground: [\(!AppState.isForeground)], secondsSinceLaunch: [\(core.clock.timeSinceLaunch())]")

        return metrics
    }

    /// Load addresses and UUIDs of the images the stack trace touches.
    ///
    /// Without these the server cannot map an address back to a symbol. The main
    /// executable is always included, even with no frame of its own: with Xcode's
    /// debug dylib the application's code lives in a separate image and the
    /// executable would otherwise be filtered out, leaving the build UUID empty.
    ///
    /// The build UUID, the executable name and the architecture are returned with
    /// the images rather than stored on the module: they describe one report, and
    /// keeping them as shared state would let two concurrent crashes hand each
    /// other's symbolication fields to the server.
    private func binaryImages(for stackTrace: [String]) -> (images: [String: Any],
                                                            buildUUID: String?,
                                                            executableName: String?,
                                                            architecture: String) {
        var namesInStack = Set<String>()
        for line in stackTrace {
            // The backtrace format pads the image name into a fixed column.
            let nsLine = line as NSString
            guard nsLine.length >= 39 else { continue }
            let name = nsLine.substring(with: NSRange(location: 4, length: 35))
                .trimmingCharacters(in: .whitespaces)
            namesInStack.insert(name)
        }

        var images: [String: Any] = [:]
        var cpuType: cpu_type_t = 0
        var cpuSubtype: cpu_subtype_t = 0
        var mainBuildUUID: String?
        var mainExecutableName: String?

        for index in 0..<_dyld_image_count() {
            guard let namePointer = _dyld_get_image_name(index) else { continue }
            let imageName = (String(cString: namePointer) as NSString).lastPathComponent

            guard let header = _dyld_get_image_header(index) else { continue }

            let isMainExecutable = header.pointee.filetype == MH_EXECUTE
            guard isMainExecutable || namesInStack.contains(imageName) else { continue }

            if header.pointee.cputype != 0 { cpuType = header.pointee.cputype }
            if header.pointee.cpusubtype != 0, cpuSubtype == 0 || header.pointee.cpusubtype > cpuSubtype {
                cpuSubtype = header.pointee.cpusubtype
            }

            guard let uuidString = imageUUID(header) else {
                logD("binaryImages", "binary image UUID can not be retrieved, symbolication may fail for it, imageName: [\(imageName)]")
                continue
            }

            if isMainExecutable {
                mainBuildUUID = uuidString
                mainExecutableName = imageName
            }

            let loadAddress = String(format: "0x%llX", UInt64(UInt(bitPattern: header)))
            images[imageName] = [Key.imageLoadAddress: loadAddress, Key.imageBuildUUID: uuidString]
        }

        logD("binaryImages", "binary images resolved for the stack trace, matchedImageCount: [\(images.count)], stackTraceImageNameCount: [\(namesInStack.count)], mainExecutableResolved: [\(mainBuildUUID != nil)]")

        return (images,
                mainBuildUUID,
                mainExecutableName,
                Self.architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype))
    }

    /// Walks the load commands looking for `LC_UUID`.
    private func imageUUID(_ header: UnsafePointer<mach_header>) -> String? {
        let is64Bit = header.pointee.magic == MH_MAGIC_64 || header.pointee.magic == MH_CIGAM_64
        var cursor = UInt(bitPattern: header) + UInt(is64Bit ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size)

        for _ in 0..<header.pointee.ncmds {
            let command = UnsafeRawPointer(bitPattern: cursor)!.assumingMemoryBound(to: load_command.self)
            if command.pointee.cmd == LC_UUID {
                let uuidCommand = UnsafeRawPointer(command).assumingMemoryBound(to: uuid_command.self)
                return UUID(uuid: uuidCommand.pointee.uuid).uuidString
            }
            cursor += UInt(command.pointee.cmdsize)
        }
        return nil
    }

    /// Human readable architecture for the crashing process.
    static func architectureName(cpuType: cpu_type_t, cpuSubtype: cpu_subtype_t) -> String {
        // The pointer-authentication bits describe the ABI, not the architecture.
        let baseSubtype = cpuSubtype & ~cpu_subtype_t(bitPattern: CPU_SUBTYPE_PTRAUTH_ABI)

        switch cpuType {
        case CPU_TYPE_ARM:
            return baseSubtype == CPU_SUBTYPE_ARM_V7 || baseSubtype == CPU_SUBTYPE_ARM_V7K ? "armv7" : "arm"
        case CPU_TYPE_ARM64:
            return baseSubtype == CPU_SUBTYPE_ARM64E ? "arm64e" : "arm64"
        case CPU_TYPE_ARM64_32:
            return "arm64_32"
        case CPU_TYPE_X86:
            return "i386"
        case CPU_TYPE_X86_64:
            return baseSubtype == CPU_SUBTYPE_X86_64_H ? "x86_64h" : "x86_64"
        default:
            return "unknown"
        }
    }

    // MARK: - Lifecycle

    override func halt(clearStorage: Bool) {
        logD("halt", "crash module halting, the handlers are uninstalled and the global crash segmentation is dropped")
        stopCrashReporting()
        stateLock.lock()
        crashSegmentation.removeAll()
        stateLock.unlock()
    }
}
