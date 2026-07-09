import Foundation
import PushlaneCore
#if canImport(UIKit)
import UIKit
#endif

/// In-app messages. A new IAM session begins when the app returns to the
/// foreground after ≥30s in the background (SessionManager in PushlaneCore). On iOS we
/// hook the app lifecycle notifications; the session math itself is in PushlaneCore so
/// it's unit-tested.
public final class PushlaneInApp: @unchecked Sendable {
    public static let shared = PushlaneInApp()
    private let lock = NSLock()
    private var session = SessionManager()
    private var didEmitAppOpen = false

    private init() {
        #if canImport(UIKit) && os(iOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }

    /// Call once at `didFinishLaunching`. Starts session tracking AND emits an
    /// `app_open` event for this cold launch (exactly once per process). This is
    /// distinct from `session_started`, which only fires on a ≥30s background→
    /// foreground return — so the two never double-count.
    public static func start() {
        shared.lock.lock()
        let firstStart = !shared.didEmitAppOpen
        shared.didEmitAppOpen = true
        let sid = shared.session.sessionId
        shared.lock.unlock()
        if firstStart { Pushlane.track("app_open", ["session_id": .string(sid)]) }
    }

    public var currentSessionId: String {
        lock.lock(); defer { lock.unlock() }; return session.sessionId
    }

    @objc private func onBackground() {
        lock.lock(); session.didEnterBackground(); lock.unlock()
    }

    @objc private func onForeground() {
        lock.lock(); let isNew = session.willEnterForeground(); let sid = session.sessionId; lock.unlock()
        if isNew { Pushlane.track("session_started", ["session_id": .string(sid)]) }
    }
}
