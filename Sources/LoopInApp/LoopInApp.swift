import Foundation
import LoopCore
#if canImport(UIKit)
import UIKit
#endif

/// In-app messages. A new IAM session begins when the app returns to the
/// foreground after ≥30s in the background (SessionManager in LoopCore). On iOS we
/// hook the app lifecycle notifications; the session math itself is in LoopCore so
/// it's unit-tested.
public final class LoopInApp: @unchecked Sendable {
    public static let shared = LoopInApp()
    private let lock = NSLock()
    private var session = SessionManager()

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

    public static func start() { _ = shared }

    public var currentSessionId: String {
        lock.lock(); defer { lock.unlock() }; return session.sessionId
    }

    @objc private func onBackground() {
        lock.lock(); session.didEnterBackground(); lock.unlock()
    }

    @objc private func onForeground() {
        lock.lock(); let isNew = session.willEnterForeground(); let sid = session.sessionId; lock.unlock()
        if isNew { Loop.track("session_started", ["session_id": .string(sid)]) }
    }
}
