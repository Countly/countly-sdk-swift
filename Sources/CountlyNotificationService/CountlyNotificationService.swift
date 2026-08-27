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
        log("didReceive, handling a notification request")

        guard let countlyPayload = request.content.userInfo[CountlyPushKey.countlyPayload] as? [String: Any],
              let notificationID = countlyPayload[CountlyPushKey.notificationID] as? String,
              !notificationID.isEmpty else {
            log("didReceive, no Countly payload found in the notification, passing it through unchanged")
            contentHandler(request.content)
            return
        }

        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            log("didReceive, the notification content could not be copied, passing it through unchanged")
            contentHandler(request.content)
            return
        }

        // The content handler must run exactly once. Everything below can reach it
        // from a download callback, from the deadline, or synchronously.
        let deliver = onceDelivery(contentHandler)

        // Whatever has been assembled by the deadline is what gets delivered.
        // Buttons but no image beats the system giving up and delivering neither.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.overallTimeout) {
            log("didReceive, the deadline passed, delivering whatever is ready")
            deliver(content)
        }

        let buttons = countlyPayload[CountlyPushKey.buttons] as? [[String: Any]] ?? []
        if buttons.isEmpty {
            finish(content: content,
                   attachmentURL: countlyPayload[CountlyPushKey.attachment] as? String,
                   notificationID: notificationID,
                   deliver: deliver)
            return
        }

        registerCategory(for: buttons, notificationID: notificationID) { categoryIdentifier in
            content.categoryIdentifier = categoryIdentifier
            finish(content: content,
                   attachmentURL: countlyPayload[CountlyPushKey.attachment] as? String,
                   notificationID: notificationID,
                   deliver: deliver)
        }
    }

    // MARK: - Action buttons

    /// Registers a category carrying this notification's buttons.
    ///
    /// The categories already registered are read back and preserved, minus any
    /// this SDK registered for an earlier notification. Replacing the whole set
    /// outright, which is the obvious implementation, silently unregisters every
    /// category the host application set up for its own notifications.
    private static func registerCategory(for buttons: [[String: Any]],
                                         notificationID: String,
                                         completion: @escaping (String) -> Void) {
        let actions = buttons.enumerated().map { index, button in
            UNNotificationAction(identifier: "\(CountlyPushKey.actionIdentifierPrefix)\(index + 1)",
                                 title: button[CountlyPushKey.actionButtonTitle] as? String ?? "",
                                 options: [.foreground])
        }

        let categoryIdentifier = CountlyPushKey.categoryIdentifierPrefix + notificationID
        let category = UNNotificationCategory(identifier: categoryIdentifier,
                                              actions: actions,
                                              intentIdentifiers: [],
                                              options: [])

        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            // Everything already registered is kept, the host application's and this
            // SDK's alike. Clearing the SDK's own on each notification, which is the
            // obvious way to stop the set growing, unregisters the category an
            // earlier notification is still sitting in Notification Center pointing
            // at, and that notification then expands with no buttons at all.
            var categories = existing
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
            log("registerCategory, registered \(actions.count) action buttons under category [\(categoryIdentifier)]")

            // Read back before continuing. Two notifications arriving together run
            // in two extension processes, and this read-modify-write is not atomic
            // across them, so the loser of the race would deliver a notification
            // pointing at a category that is no longer registered.
            center.getNotificationCategories { confirmed in
                guard !confirmed.contains(where: { $0.identifier == categoryIdentifier }) else {
                    completion(categoryIdentifier)
                    return
                }

                log("registerCategory, the category was overwritten by a concurrent registration, writing it again")
                var retry = confirmed
                retry.insert(category)
                center.setNotificationCategories(retry)
                completion(categoryIdentifier)
            }
        }
    }

    // MARK: - Attachment

    private static func finish(content: UNMutableNotificationContent,
                               attachmentURL: String?,
                               notificationID: String,
                               deliver: @escaping (UNNotificationContent) -> Void) {
        guard let attachmentURL, !attachmentURL.isEmpty, let url = URL(string: attachmentURL) else {
            log("finish, no attachment specified in the Countly payload")
            deliver(content)
            return
        }

        log("finish, downloading the attachment specified in the Countly payload")

        // A dedicated ephemeral session rather than a shared one: this runs in the
        // extension's own short lived process, and a cached or cookie carrying
        // request to a media host is not wanted.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = attachmentTimeout
        let session = URLSession(configuration: configuration)

        let task = session.downloadTask(with: url) { location, response, error in
            defer {
                session.finishTasksAndInvalidate()
                deliver(content)
            }

            if let error {
                log("finish, attachment download failed: \(error.localizedDescription)")
                return
            }

            guard let location else {
                log("finish, attachment download produced no file")
                return
            }

            let suggested = response?.suggestedFilename ?? url.lastPathComponent
            let fileName = "\(notificationID)-\(suggested)"
            let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)

            do {
                // The system deletes the downloaded file as soon as this callback
                // returns, and a leftover from a previous notification with the
                // same name would make the move fail.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                content.attachments = [try UNNotificationAttachment(identifier: fileName, url: destination, options: nil)]
                log("finish, attachment added to the notification")
            } catch {
                log("finish, attachment could not be attached: \(error.localizedDescription)")
            }
        }
        task.resume()
    }

    // MARK: - Helpers

    /// Wraps the content handler so that only the first call reaches the system.
    private static func onceDelivery(_ contentHandler: @escaping (UNNotificationContent) -> Void) -> (UNNotificationContent) -> Void {
        let lock = NSLock()
        var delivered = false
        return { content in
            lock.lock()
            let alreadyDelivered = delivered
            delivered = true
            lock.unlock()

            guard !alreadyDelivered else { return }
            contentHandler(content)
        }
    }

    private static func log(_ message: String) {
        #if DEBUG
        NSLog("[CountlyNSE] %@", message)
        #endif
    }
}

#endif
