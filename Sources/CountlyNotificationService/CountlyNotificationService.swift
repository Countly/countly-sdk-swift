//
//  CountlyNotificationService.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if canImport(UserNotifications) && (os(iOS) || os(visionOS))
import UserNotifications
#endif

/// Keys of the Countly payload carried inside a push notification.
///
/// Declared here rather than in the main SDK because the notification service
/// extension is a separate process that links only this target, by design: an
/// extension has a hard memory budget and no business loading an analytics SDK.
///
/// `CountlyPushKey` in `Sources/Countly/Internal/CountlyConsts.swift` is the same
/// block. It is the wire contract with the server, so neither side changes alone,
/// and the two are kept identical rather than each holding the subset it happens
/// to use, so a reader can diff them at a glance.
public enum CountlyPushKey {
    /// The Countly payload, nested under this key in `userInfo`.
    public static let countlyPayload = "c"
    /// Server side ID of the notification.
    public static let notificationID = "i"
    /// Array of action button descriptors.
    public static let buttons = "b"
    /// URL opened when the notification body itself is tapped.
    public static let defaultURL = "l"
    /// URL of a media attachment to download and attach.
    public static let attachment = "a"
    /// Index of the tapped action button, as reported in the action event.
    public static let actionButtonIndex = "b"
    /// Title of an action button.
    public static let actionButtonTitle = "t"
    /// URL opened when an action button is tapped.
    public static let actionButtonURL = "l"
    /// Platform the action was taken on, as reported in the action event.
    public static let platform = "p"

    /// Prefix of the action identifiers this extension registers, followed by the
    /// one based index of the button. The main SDK parses the index back out of it.
    public static let actionIdentifierPrefix = "CountlyActionIdentifier"

    /// Prefix of the notification category this extension registers, followed by
    /// the notification ID, so two notifications never share a button set.
    public static let categoryIdentifierPrefix = "CountlyCategoryIdentifier"
}

#if canImport(UserNotifications) && (os(iOS) || os(visionOS))

/// Turns a Countly push payload into a notification with action buttons and a
/// media attachment.
///
/// Call this from a `UNNotificationServiceExtension` subclass:
///
/// ```swift
/// override func didReceive(_ request: UNNotificationRequest,
///                          withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
///     CountlyNotificationService.didReceive(request, withContentHandler: contentHandler)
/// }
/// ```
///
/// A notification without a Countly payload is passed through untouched, so the
/// extension can be installed unconditionally.
public enum CountlyNotificationService {

    /// How long the attachment download is allowed to take.
    ///
    /// The system gives a service extension roughly 30 seconds before it discards
    /// the mutated content and shows the original. Timing out a little earlier
    /// means a slow image still yields a notification with its buttons instead of
    /// one with neither.
    private static let attachmentTimeout: TimeInterval = 20

    /// Deadline for the whole job, covering the parts no URL session timeout does.
    ///
    /// Registering the categories is an interprocess call that can be slow under
    /// memory pressure, and it is on the critical path. Without this, a delayed
    /// reply from it means the content handler is never called at all, and the
    /// system delivers the raw payload with neither buttons nor attachment.
    private static let overallTimeout: TimeInterval = 25

    /// How many notifications' worth of action buttons stay registered.
    ///
    /// Each notification gets its own category so two never share a button set, and
    /// a category has to outlive its notification because the buttons are rendered
    /// when the user expands it, not when it arrives.
    private static let maxRetainedCategories = 32

    public static func didReceive(_ request: UNNotificationRequest,
                                  withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        log("didReceive, handling a notification request, requestIdentifier: [\(request.identifier)], title: [\(request.content.title)], subtitle: [\(request.content.subtitle)], body: [\(request.content.body)], category: [\(request.content.categoryIdentifier)], userInfoKeys: [\(request.content.userInfo.keys.map { "\($0)" }.sorted())]")

        guard let countlyPayload = request.content.userInfo[CountlyPushKey.countlyPayload] as? [String: Any],
              let notificationID = countlyPayload[CountlyPushKey.notificationID] as? String,
              !notificationID.isEmpty else {
            log("didReceive, no Countly payload found in the notification, passing it through unchanged")
            contentHandler(request.content)
            return
        }

        let buttonTitles = (countlyPayload[CountlyPushKey.buttons] as? [[String: Any]] ?? []).map { $0[CountlyPushKey.actionButtonTitle] as? String ?? "" }
        let buttonURLs = (countlyPayload[CountlyPushKey.buttons] as? [[String: Any]] ?? []).map { $0[CountlyPushKey.actionButtonURL] as? String ?? "" }
        log("didReceive, Countly payload detail, countlyID: [\(notificationID)], defaultURL: [\(countlyPayload[CountlyPushKey.defaultURL] as? String ?? "none")], buttonTitles: [\(buttonTitles)], buttonURLs: [\(buttonURLs)], attachmentURL: [\(countlyPayload[CountlyPushKey.attachment] as? String ?? "none")], payload: [\(countlyPayload)]")

        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            log("didReceive, the notification content could not be copied, passing it through unchanged")
            contentHandler(request.content)
            return
        }

        // The content handler must run exactly once, and the content must not be
        // written while it is being delivered. Everything below reaches the system
        // through this gate: the assembly task or the deadline, whichever is first.
        let gate = DeliveryGate(content: content, contentHandler: contentHandler)

        // Whatever has been assembled by the deadline is what gets delivered.
        // Buttons but no image beats the system giving up and delivering neither.
        // The system reuses the extension process between notifications, so this
        // fires for requests that went out long ago as well; those are no-ops and
        // stay out of the log.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.overallTimeout) {
            if gate.deliver() {
                log("didReceive, the deadline passed, delivering whatever is ready")
            }
        }

        let attachmentURL = countlyPayload[CountlyPushKey.attachment] as? String
        Task {
            if !buttonTitles.isEmpty {
                let categoryIdentifier = await registerCategory(buttonTitles: buttonTitles, notificationID: notificationID)
                gate.mutate { $0.categoryIdentifier = categoryIdentifier }
                log("didReceive, the notification now carries its action buttons, category: [\(categoryIdentifier)]")
            }
            await attach(from: attachmentURL, notificationID: notificationID, to: gate)
            gate.deliver()
        }
    }

    // MARK: - Action buttons

    /// Registers a category carrying this notification's buttons.
    ///
    /// The categories already registered are read back and preserved, minus any
    /// this SDK registered for an earlier notification. Replacing the whole set
    /// outright, which is the obvious implementation, silently unregisters every
    /// category the host application set up for its own notifications.
    ///
    /// - Returns: The identifier of the registered category.
    private static func registerCategory(buttonTitles: [String], notificationID: String) async -> String {
        let categoryIdentifier = CountlyPushKey.categoryIdentifierPrefix + notificationID
        let center = UNUserNotificationCenter.current()
        let category = makeCategory(identifier: categoryIdentifier, buttonTitles: buttonTitles)

        // Everything already registered is kept, the host application's and this
        // SDK's alike. Clearing the SDK's own on each notification, which is the
        // obvious way to stop the set growing, unregisters the category an earlier
        // notification is still sitting in Notification Center pointing at, and
        // that notification then expands with no buttons at all.
        //
        // `Set.insert` keeps whatever is already there, and two categories with the
        // same identifier but different actions are not equal, so a plain insert
        // would leave the set holding both. Which of them `setNotificationCategories`
        // keeps is undefined, and the identifier check below would report success
        // either way, so the notification can expand showing the previous
        // notification's buttons. The identifier is the key here, so anything
        // already under it is removed first.
        var categories = await center.notificationCategories().filter { $0.identifier != categoryIdentifier }
        categories.insert(category)

        // Bounded so a chatty application does not accumulate categories without
        // limit. Which of the older ones goes is arbitrary, because the set is
        // unordered and carries no timestamp; the newest is always kept.
        let ours = categories.filter { $0.identifier.hasPrefix(CountlyPushKey.categoryIdentifierPrefix) }
        if ours.count > Self.maxRetainedCategories {
            for stale in ours.filter({ $0.identifier != categoryIdentifier }).prefix(ours.count - Self.maxRetainedCategories) {
                categories.remove(stale)
            }
        }

        center.setNotificationCategories(categories)
        log("registerCategory, registered \(buttonTitles.count) action buttons under category [\(categoryIdentifier)]")

        // Read back before continuing. Two notifications arriving together run in
        // two extension processes, and this read-modify-write is not atomic across
        // them, so the loser of the race would deliver a notification pointing at a
        // category that is no longer registered.
        let confirmed = await center.notificationCategories()
        guard !confirmed.contains(where: { $0.identifier == categoryIdentifier }) else {
            return categoryIdentifier
        }

        log("registerCategory, the category was overwritten by a concurrent registration, writing it again")
        var retry = confirmed.filter { $0.identifier != categoryIdentifier }
        retry.insert(category)
        center.setNotificationCategories(retry)
        return categoryIdentifier
    }

    /// The category carrying one notification's action buttons, in payload order.
    private static func makeCategory(identifier: String, buttonTitles: [String]) -> UNNotificationCategory {
        let actions = buttonTitles.enumerated().map { index, title in
            UNNotificationAction(identifier: "\(CountlyPushKey.actionIdentifierPrefix)\(index + 1)",
                                 title: title,
                                 options: [.foreground])
        }
        return UNNotificationCategory(identifier: identifier,
                                      actions: actions,
                                      intentIdentifiers: [],
                                      options: [])
    }

    // MARK: - Attachment

    /// Downloads the payload's media, when it names one, and attaches it.
    ///
    /// Leaves the content as it was on any failure: a notification without its
    /// image still carries its text and its buttons.
    private static func attach(from attachmentURL: String?, notificationID: String, to gate: DeliveryGate) async {
        guard let attachmentURL, !attachmentURL.isEmpty else {
            log("attach, no attachment specified in the Countly payload")
            return
        }

        guard let url = resolveAttachmentURL(attachmentURL) else {
            log("attach, the attachment URL in the Countly payload is not a URL, url: [\(attachmentURL)]")
            return
        }

        log("attach, downloading the attachment specified in the Countly payload, url: [\(url.absoluteString)]")

        // A dedicated ephemeral session rather than a shared one: this runs in the
        // extension's own short lived process, and a cached or cookie carrying
        // request to a media host is not wanted.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = attachmentTimeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let location: URL
        let response: URLResponse
        do {
            (location, response) = try await session.download(from: url)
        } catch {
            let nsError = error as NSError
            log("attach, attachment download failed, url: [\(url.absoluteString)], domain: [\(nsError.domain)], code: [\(nsError.code)], error: [\(error.localizedDescription)]")
            return
        }

        // The async download leaves its file behind, unlike the completion handler form.
        defer { try? FileManager.default.removeItem(at: location) }

        let suggested = response.suggestedFilename ?? url.lastPathComponent
        let fileName = "\(notificationID)-\(suggested)"
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)

        do {
            // A leftover with the same name from an earlier notification would fail the move.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let attachment = try UNNotificationAttachment(identifier: fileName, url: destination, options: nil)
            gate.mutate { $0.attachments = [attachment] }
            log("attach, attachment added to the notification")
        } catch {
            log("attach, attachment could not be attached: \(error.localizedDescription)")
        }
    }

    /// The URL to download the attachment from, or nil when the payload's string
    /// cannot be made into one.
    ///
    /// The dashboard accepts the media address as typed, and a value without a
    /// scheme parses as a URL yet is refused by the session as unsupported, so
    /// `https` is assumed for it. Spaces and other characters a URL cannot carry
    /// are percent encoded as a last resort.
    static func resolveAttachmentURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.range(of: "://") == nil ? "https://" + trimmed : trimmed
        if let url = URL(string: withScheme), url.host != nil {
            return url
        }

        guard let encoded = withScheme.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encoded), url.host != nil else {
            return nil
        }
        return url
    }

    // MARK: - Helpers

    /// Owns the notification content and the one delivery the system allows.
    ///
    /// Three things race for that content: the category registration callback, the
    /// attachment download callback, and the deadline timer, each on a different
    /// queue. Serializing only the *delivery* is not enough, because the deadline
    /// can hand the content to the system while a download callback is still
    /// assigning `content.attachments` to the same object. Every read, every write
    /// and the delivery itself therefore go through one lock, which is what makes
    /// the unchecked `Sendable` true.
    private final class DeliveryGate: @unchecked Sendable {

        private let lock = NSLock()
        private let content: UNMutableNotificationContent
        private let contentHandler: (UNNotificationContent) -> Void
        private var delivered = false

        init(content: UNMutableNotificationContent,
             contentHandler: @escaping (UNNotificationContent) -> Void) {
            self.content = content
            self.contentHandler = contentHandler
        }

        /// Applies a change to the content, unless it has already gone out. A
        /// change arriving after delivery is dropped rather than applied to an
        /// object the system is already rendering.
        func mutate(_ change: (UNMutableNotificationContent) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !delivered else { return }
            change(content)
        }

        /// Hands the content to the system, at most once. Returns whether this call
        /// was the one that delivered it.
        ///
        /// The content is copied under the lock, so a mutation that starts after
        /// this returns cannot touch the object the system received.
        @discardableResult
        func deliver() -> Bool {
            lock.lock()
            let alreadyDelivered = delivered
            delivered = true
            let snapshot = alreadyDelivered ? nil : content.copy() as? UNNotificationContent
            lock.unlock()

            guard let snapshot else { return false }
            contentHandler(snapshot)
            return true
        }
    }

    private static func log(_ message: String) {
        #if DEBUG
        NSLog("[CountlyNSE] %@", message)
        #endif
    }
}

#endif
