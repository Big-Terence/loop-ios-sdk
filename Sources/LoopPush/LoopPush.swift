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

    /// Ask for notification permission and register for remote notifications.
    /// Safe to call once at launch.
    public static func register() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = OpenTracker.shared }
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            #if canImport(UIKit) && os(iOS)
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            #endif
        }
        #endif
    }

    /// Forward from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// The environment is auto-detected (sandbox vs production) — never `#if DEBUG`.
    public static func didRegister(deviceToken: Data) {
        Loop.shared.registerDeviceToken(deviceToken)
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
        Loop.track("opened", props)
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
