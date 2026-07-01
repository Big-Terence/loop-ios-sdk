import Foundation

/// Session boundary logic (pure, testable). A return to the foreground after ≥30s
/// in the background starts a NEW in-app-message session (OneSignal-style), so
/// IAMs don't re-fire on a quick app switch.
public struct SessionManager {
    public static let sessionGapSeconds: TimeInterval = 30
    private var backgroundedAt: Date?
    public private(set) var sessionId: String

    public init(sessionId: String = UUID().uuidString.lowercased()) {
        self.sessionId = sessionId
    }

    public mutating func didEnterBackground(at: Date = Date()) {
        backgroundedAt = at
    }

    /// Returns true and rotates the session id if a new session should start.
    public mutating func willEnterForeground(at: Date = Date()) -> Bool {
        defer { backgroundedAt = nil }
        guard let bg = backgroundedAt else { return false }
        if at.timeIntervalSince(bg) >= Self.sessionGapSeconds {
            sessionId = UUID().uuidString.lowercased()
            return true
        }
        return false
    }
}

#if os(iOS)
private let osName = "iOS"
#elseif os(macOS)
private let osName = "macOS"
#else
private let osName = "unknown"
#endif

/// The Loop SDK facade. One user = one external identity, many subscriptions.
public final class Loop: @unchecked Sendable {
    public static let shared = Loop()

    private let lock = NSLock()
    private var config: LoopConfig?
    private var transport: Transport?
    private var externalId: String?
    private var environment: ApnsEnvironment = .sandbox
    private var installSource: InstallSource = .development

    // N22 — warn ONCE (never spam) when track() or registerDeviceToken() is
    // called before identify(). Without an externalId the event is silently
    // dropped; the warning surfaces the root cause immediately in the Xcode
    // console so the developer doesn't waste time hunting for missing events.
    private var didWarnNoIdentity = false

    private init() {}

    // MARK: configure / identify

    /// Configure the SDK. `publishableKey` is the `lpk_…` write-key from the
    /// dashboard (sent as `Authorization: Bearer …` — A2). `appGroup` is the shared
    /// App Group id the NotificationServiceExtension reads to emit `received`
    /// (see README). Both are optional and back-compatible.
    public static func configure(
        apiBase: URL,
        tenantId: String,
        publishableKey: String? = nil,
        appGroup: String? = nil
    ) {
        shared.configure(LoopConfig(
            apiBase: apiBase,
            tenantId: tenantId,
            publishableKey: publishableKey,
            appGroup: appGroup
        ))
    }

    public func configure(_ config: LoopConfig) {
        lock.lock()
        self.config = config
        self.transport = Transport(config: config)
        #if !targetEnvironment(simulator)
        self.environment = ProvisioningProfile.detect()
        #else
        self.environment = .sandbox // the Simulator has no real APNs
        #endif
        self.installSource = InstallSource.detect()
        let extId = self.externalId
        let env = self.environment
        let src = self.installSource
        lock.unlock()
        persistSharedConfig(config: config, externalId: extId, environment: env, installSource: src)
    }

    /// First-class external identity (R1) — dedup happens server-side.
    public static func identify(_ externalId: String) {
        shared.lock.lock()
        shared.externalId = externalId
        let config = shared.config
        let env = shared.environment
        let src = shared.installSource
        shared.lock.unlock()
        if let config { shared.persistSharedConfig(config: config, externalId: externalId, environment: env, installSource: src) }
    }

    /// Logout — detach the external id from this device.
    public static func reset() {
        shared.lock.lock()
        shared.externalId = nil
        let config = shared.config
        let env = shared.environment
        let src = shared.installSource
        shared.lock.unlock()
        if let config { shared.persistSharedConfig(config: config, externalId: nil, environment: env, installSource: src) }
    }

    /// Mirror the ingest config into the App Group so the NSE (separate process)
    /// can emit `received`. No-op when no App Group is configured.
    private func persistSharedConfig(config: LoopConfig, externalId: String?, environment: ApnsEnvironment, installSource: InstallSource) {
        guard let group = config.appGroup else { return }
        LoopAppGroupStore.save(
            LoopSharedConfig(
                apiBase: config.apiBase,
                tenantId: config.tenantId,
                publishableKey: config.publishableKey,
                externalId: externalId,
                environment: environment,
                installSource: installSource
            ),
            appGroup: group
        )
    }

    public var currentEnvironment: ApnsEnvironment {
        lock.lock(); defer { lock.unlock() }; return environment
    }

    // MARK: track

    public static func track(_ name: String, _ properties: [String: LoopValue] = [:]) {
        shared.track(name, properties)
    }

    public func track(_ name: String, _ properties: [String: LoopValue] = [:]) {
        lock.lock()
        // N22 — warn once if track is called before identify; the event is dropped.
        if externalId == nil && !didWarnNoIdentity {
            didWarnNoIdentity = true
            lock.unlock()
            print("[Loop] ⚠️ track(\"\(name)\") called before Loop.identify() — the event is dropped until an external id is set. Call Loop.identify(yourUserId) in didFinishLaunchingWithOptions before tracking events.")
            return
        }
        guard let config, let transport, let externalId else { lock.unlock(); return }
        let env = environment
        let src = installSource
        lock.unlock()

        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let context = EventContext(
            os: osName,
            osVersion: "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            environment: env,
            installSource: src,
            tzIana: TimeZone.current.identifier,
            locale: Locale.current.identifier
        )
        let envelope = EventEnvelope(
            tenantId: config.tenantId,
            externalId: externalId,
            name: name,
            properties: properties,
            context: context
        )
        transport.send(envelope)
    }

    // MARK: push registration (called by LoopPush)

    public func registerDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        // N22 — warn once if the device token arrives before identify(); the
        // registration is dropped and the device will never be reachable for push.
        if externalId == nil && !didWarnNoIdentity {
            didWarnNoIdentity = true
            lock.unlock()
            print("[Loop] ⚠️ LoopPush.didRegister(deviceToken:) called before Loop.identify() — the token is dropped. Call Loop.identify(yourUserId) before LoopPush.register() so the device token is always attributed to a user.")
            return
        }
        guard let transport, let externalId else { lock.unlock(); return }
        let env = environment
        lock.unlock()
        transport.register(externalId: externalId, deviceToken: token, environment: env)
    }
}

// MARK: - RevenueCat link

public extension Loop {
    /// Identify the user for Loop AND return the exact id to hand RevenueCat.
    ///
    /// Loop attributes RevenueCat revenue events (trial_started, subscription_started,
    /// renewal, cancellation…) to a Loop user ONLY when RevenueCat's `appUserID`
    /// equals the id passed to `Loop.identify`. This convenience makes the contract
    /// one call site — feed the returned value to `Purchases.configure(appUserID:)`
    /// (or `Purchases.logIn`):
    ///
    /// ```swift
    /// let uid = Loop.identifyForRevenueCat(currentUser.id)
    /// Purchases.configure(withAPIKey: "appl_…", appUserID: uid)
    /// ```
    ///
    /// No dependency on the RevenueCat SDK — it only keeps the two ids in sync.
    @discardableResult
    static func identifyForRevenueCat(_ userId: String) -> String {
        identify(userId)
        return userId
    }
}

// MARK: - received (deliverability) envelope — built by the NSE, separate process

public extension Loop {
    /// Build (don't send) the `received` envelope from a push `userInfo` and the
    /// App-Group-shared config. Pure + testable; the NotificationServiceExtension
    /// calls this to measure deliverability (it runs in another process, with no
    /// `Loop.shared` runtime state). Returns nil when no user is identified
    /// (`externalId` not yet persisted), since events must attribute to a user.
    ///
    /// `message_id`/`flow_id`/`node_id` are read from the same top-level payload
    /// keys the Go sender writes (and that `opened` reads), so `received` and
    /// `opened` attribute to the SAME send.
    static func receivedEnvelope(
        userInfo: [AnyHashable: Any],
        config: LoopSharedConfig
    ) -> EventEnvelope? {
        guard let externalId = config.externalId, !externalId.isEmpty else { return nil }

        var props: [String: LoopValue] = [:]
        if let mid = userInfo["message_id"] as? String { props["message_id"] = .string(mid) }
        if let fid = userInfo["flow_id"] as? String { props["flow_id"] = .string(fid) }
        if let nid = userInfo["node_id"] as? String { props["node_id"] = .string(nid) }

        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let context = EventContext(
            os: osName,
            osVersion: "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            environment: config.environment,
            installSource: config.installSource,
            tzIana: TimeZone.current.identifier,
            locale: Locale.current.identifier
        )
        // Continue the send's trace if the server ever forwards one; else start fresh.
        let traceparent = (userInfo["traceparent"] as? String) ?? Trace.newTraceparent()
        return EventEnvelope(
            tenantId: config.tenantId,
            externalId: externalId,
            name: "received",
            properties: props,
            context: context,
            traceparent: traceparent
        )
    }
}
