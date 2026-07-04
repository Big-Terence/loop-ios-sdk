import Foundation
import LoopCore
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Push registration + open-tracking. Wire `LoopPush.register()` and the
/// AppDelegate forwards below in your app. Open tracking must be installed BEFORE
/// `didFinishLaunchingWithOptions` returns to catch a cold-launch-via-tap.
public enum LoopPush {

    /// Category identifier attached (always-on) to every Loop push by the sender.
    /// Registered with `.customDismissAction` so an explicit Notification-Center
    /// clear routes through our delegate and emits a `dismissed` event.
    ///
    /// Honesty: Apple fires `UNNotificationDismissActionIdentifier` ONLY on an
    /// explicit clear (Clear button / ✕ / Clear All). A lock-screen swipe-away,
    /// an ignore, or an OS auto-clear produce NO signal — so `dismissed` is
    /// best-effort and under-counts real dismissals.
    public static let categoryIdentifier = "LOOP_DEFAULT"

    #if canImport(UserNotifications)
    /// Register Loop's `LOOP_DEFAULT` category (with `.customDismissAction`) WITHOUT
    /// clobbering categories the host app already registered — the new set is the
    /// union of the existing categories and ours. Call this from apps that manage
    /// their own `UNNotificationCategory` set; `register()` also calls it for you.
    public static func registerCategories() {
        let center = UNUserNotificationCenter.current()
        let loop = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.getNotificationCategories { existing in
            center.setNotificationCategories(existing.union([loop]))
        }
    }
    #endif

    /// Ask for notification permission and register for remote notifications.
    ///
    /// - Parameter provisional: When `true`, requests `.provisional` authorization
    ///   (iOS 12+). Provisional grants are silent by default — notifications arrive
    ///   in Notification Center without sound or banner, with "Keep"/"Turn Off"
    ///   actions. This produces a real APNs token immediately WITHOUT showing the
    ///   system prompt. The user can promote to full ("Keep → Deliver Prominently")
    ///   or opt out at any time. Default is `false`, preserving the original
    ///   behavior for already-shipped apps.
    ///
    /// - Note: Provisional does NOT override a prior explicit denial. It is
    ///   iOS-only — Android has no equivalent concept. Delivery is unchanged:
    ///   Loop sends normally; the OS decides display style.
    public static func register(provisional: Bool = false) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = OpenTracker.shared }
        // Register the LOOP_DEFAULT dismiss category (union — never clobbers the app's).
        registerCategories()
        var options: UNAuthorizationOptions = [.alert, .badge, .sound]
        if provisional {
            if #available(iOS 12.0, *) {
                options.insert(.provisional)
            }
        }
        center.requestAuthorization(options: options) { granted, _ in
            // With .provisional, `granted` is always true (no prompt shown).
            guard granted else {
                // Permission explicitly denied — read and report the level so the
                // funnel captures it if a token already existed (phase-2 token-less
                // ping is deferred; this is best-effort on grant failure).
                Loop.shared.reportAuthorizationLevel()
                return
            }
            #if canImport(UIKit) && os(iOS)
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            #endif
        }
        #endif
    }

    /// Convenience: request provisional (silent) push authorization.
    /// Equivalent to `register(provisional: true)`. iOS 12+ only.
    public static func registerForProvisionalPush() {
        register(provisional: true)
    }

    /// Forward from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// The environment is auto-detected (sandbox vs production) — never `#if DEBUG`.
    public static func didRegister(deviceToken: Data) {
        #if canImport(UserNotifications)
        // Read the authorization level right after the token arrives so it is
        // always captured alongside the registration at the most accurate point.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let level: String
            if #available(iOS 12.0, *) {
                switch settings.authorizationStatus {
                case .authorized:    level = "authorized"
                case .provisional:   level = "provisional"
                case .denied:        level = "denied"
                case .ephemeral:     level = "ephemeral"
                case .notDetermined: level = "notDetermined"
                @unknown default:    level = "notDetermined"
                }
            } else {
                level = settings.authorizationStatus == .authorized ? "authorized" : "denied"
            }
            Loop.shared.registerDeviceToken(deviceToken, authorizationLevel: level)
        }
        #else
        Loop.shared.registerDeviceToken(deviceToken, authorizationLevel: nil)
        #endif
    }

    /// Forward from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    public static func didFailToRegister(error: Error) {
        // The Simulator has no APNs; swallow there. On device, surface via analytics.
        Loop.track("push_registration_failed", ["error": .string(String(describing: error))])
    }
}

#if canImport(UserNotifications)
/// Captures notification opens (cold-launch tap + foreground) and emits an
/// `opened` event carrying the `message_id` embedded in the push payload.
final class OpenTracker: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OpenTracker()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        var props: [String: LoopValue] = [:]
        if let mid = info["message_id"] as? String { props["message_id"] = .string(mid) }
        if let fid = info["flow_id"] as? String { props["flow_id"] = .string(fid) }
        if let nid = info["node_id"] as? String { props["node_id"] = .string(nid) }
        // Explicit clear (Clear / ✕ / Clear All) → `dismissed`; a tap (Default) or
        // any future custom action → `opened`. Best-effort: Apple gives no signal
        // for swipe-away / ignore / OS auto-clear (see `categoryIdentifier`).
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            Loop.track("dismissed", props)
        } else {
            Loop.track("opened", props)
        }
        completionHandler()
    }

    // Show banners while in the foreground (so foreground opens are trackable too).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
#endif
