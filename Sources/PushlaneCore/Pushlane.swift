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

/// The Pushlane SDK facade. One user = one external identity, many subscriptions.
public final class Pushlane: @unchecked Sendable {
    public static let shared = Pushlane()

    private let lock = NSLock()
    private var config: PushlaneConfig?
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
        shared.configure(PushlaneConfig(
            apiBase: apiBase,
            tenantId: tenantId,
            publishableKey: publishableKey,
            appGroup: appGroup
        ))
    }

    public func configure(_ config: PushlaneConfig) {
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
    private func persistSharedConfig(config: PushlaneConfig, externalId: String?, environment: ApnsEnvironment, installSource: InstallSource) {
        guard let group = config.appGroup else { return }
        PushlaneAppGroupStore.save(
            PushlaneSharedConfig(
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

    // MARK: - internal consent helper (accessed by the public extension below)

    /// Posts the consent record. Must be called on `shared` only.
    /// This method is **internal**, not `private` — it has to be module-visible so the
    /// `public extension` above can call it — but it is deliberately kept out of the
    /// PUBLIC API surface; the extension exposes the two typed entry-points
    /// (`setConsent` / `setMarketingConsent`).
    func _setConsent(category: String, optedIn: Bool) {
        lock.lock()
        // N22 pattern — warn once if called before identify(); the record is dropped.
        if externalId == nil && !didWarnNoIdentity {
            didWarnNoIdentity = true
            lock.unlock()
            // L17 — DEBUG-only diagnostic (compiled out of Release; no user data in prod logs).
            PushlaneLog.debug("Pushlane.setConsent(category:\"\(category)\") called before Pushlane.identify() — the consent record is dropped. Call Pushlane.identify(yourUserId) before registering consent preferences.")
            return
        }
        guard let transport, let externalId else { lock.unlock(); return }
        lock.unlock()
        let action = optedIn ? "opt_in" : "opt_out"
        // Durably record the explicit choice FIRST, then post. It is cleared only on a
        // 2xx ack; until then it survives the pre-register window and app restarts and
        // is replayed after registration, so an explicit opt-out is never lost (the
        // sacred invariant) even when posted before the backend user exists.
        PendingConsentStore.record(externalId: externalId, category: category, action: action)
        transport.sendConsent(externalId: externalId, category: category, optedIn: optedIn) {
            PendingConsentStore.clear(externalId: externalId, category: category, ifAction: action)
        }
    }

    /// Re-send any consent choice that hasn't been acknowledged yet. Called after a
    /// successful device registration — the point at which the backend user is
    /// guaranteed to exist — so a choice made before that (and 404'd) finally lands.
    private func replayPendingConsent(externalId: String) {
        let pending = PendingConsentStore.pending(externalId: externalId)
        guard !pending.isEmpty else { return }
        lock.lock(); let transport = self.transport; lock.unlock()
        guard let transport else { return }
        for (category, action) in pending {
            transport.sendConsent(externalId: externalId, category: category, optedIn: action == "opt_in") {
                PendingConsentStore.clear(externalId: externalId, category: category, ifAction: action)
            }
        }
    }

    // MARK: track

    public static func track(_ name: String, _ properties: [String: PushlaneValue] = [:]) {
        shared.track(name, properties)
    }

    public func track(_ name: String, _ properties: [String: PushlaneValue] = [:]) {
        lock.lock()
        // N22 — warn once if track is called before identify; the event is dropped.
        if externalId == nil && !didWarnNoIdentity {
            didWarnNoIdentity = true
            lock.unlock()
            // L17 — DEBUG-only diagnostic (compiled out of Release; no app data in prod logs).
            PushlaneLog.debug("track(\"\(name)\") called before Pushlane.identify() — the event is dropped until an external id is set. Call Pushlane.identify(yourUserId) in didFinishLaunchingWithOptions before tracking events.")
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

    // MARK: setAttributes

    /// Persistent user attributes — feeds `{{ name | fallback }}` personalisation at send time.
    ///
    /// POST /v1/attributes with the current externalId. No-op if called before `identify()`
    /// (same silent-drop behaviour as `track()`).
    public static func setAttributes(_ attributes: [String: PushlaneValue]) {
        shared.setAttributes(attributes)
    }

    /// Persistent user attributes — feeds `{{ name | fallback }}` personalisation at send time.
    public func setAttributes(_ attributes: [String: PushlaneValue]) {
        lock.lock()
        guard let transport, let externalId else { lock.unlock(); return }
        lock.unlock()
        transport.sendAttributes(externalId: externalId, attributes: attributes)
    }

    // MARK: push registration (called by PushlanePush)

    /// Register the APNs device token with Pushlane.
    ///
    /// Called by `PushlanePush.didRegister(deviceToken:)` which reads the authorization
    /// level from `UNUserNotificationCenter` before forwarding here. The older
    /// `registerDeviceToken(_:)` overload (no level) is kept for source compatibility
    /// with any callers that bypass `PushlanePush`.
    public func registerDeviceToken(_ tokenData: Data, authorizationLevel: String? = nil) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        // N22 — warn once if the device token arrives before identify(); the
        // registration is dropped and the device will never be reachable for push.
        if externalId == nil && !didWarnNoIdentity {
            didWarnNoIdentity = true
            lock.unlock()
            // L17 — DEBUG-only diagnostic (compiled out of Release; no token/app data in prod logs).
            PushlaneLog.debug("PushlanePush.didRegister(deviceToken:) called before Pushlane.identify() — the token is dropped. Call Pushlane.identify(yourUserId) before PushlanePush.register() so the device token is always attributed to a user.")
            return
        }
        guard let transport, let externalId else { lock.unlock(); return }
        let env = environment
        lock.unlock()
        transport.register(externalId: externalId, deviceToken: token, environment: env, authorizationLevel: authorizationLevel) { [weak self] in
            self?.replayPendingConsent(externalId: externalId)
        }
    }

    /// Re-read the current authorization level from UNUserNotificationCenter.
    ///
    /// MVP: the level is captured at the next full `register` call. A dedicated
    /// token-less level-only POST is deferred to phase-2. This method is a hook
    /// for future wiring (e.g. foreground return from Settings).
    public func reportAuthorizationLevel() {
        // Phase-2 placeholder: phase-2 will POST a level-only update to /v1/register
        // without re-supplying the token. For now, a no-op — the level is refreshed
        // whenever the next full didRegister cycle runs (e.g. after an app update).
    }
}

// MARK: - Consent (opt-out model)

public extension Pushlane {
    /// Register an **explicit** user consent choice for the given notification
    /// category (default: `"marketing"`).
    ///
    /// **Pushlane is opt-out by default.** Granting push-notification permission in the
    /// iOS system prompt (which produces a registered device token) is all that is
    /// needed for Pushlane to deliver notifications. Your app does **not** need to call
    /// this method to start receiving pushes.
    ///
    /// Call this **only** when the user makes an explicit choice in your own
    /// preference UI (e.g. a "Marketing notifications" toggle in Settings):
    ///
    /// ```swift
    /// // User turned the toggle OFF — record the opt-out:
    /// Pushlane.setConsent(category: "marketing", optedIn: false)
    ///
    /// // User turned the toggle back ON — record the re-opt-in:
    /// Pushlane.setConsent(category: "marketing", optedIn: true)
    /// ```
    ///
    /// An explicit `optedIn: false` (opt-out) is **always honoured** server-side —
    /// Pushlane will never deliver a notification to a user who has explicitly opted out,
    /// regardless of any flow configuration. This invariant is unconditional.
    ///
    /// Requires a prior `Pushlane.identify` call so the consent record can be attributed
    /// to a user. If called before `identify`, the call is silently dropped and a
    /// one-time diagnostic is logged to the Xcode console (DEBUG builds only).
    static func setConsent(category: String = "marketing", optedIn: Bool) {
        shared._setConsent(category: category, optedIn: optedIn)
    }

    /// Convenience shorthand for `setConsent(category: "marketing", optedIn:)`.
    ///
    /// Equivalent to `Pushlane.setConsent(category: "marketing", optedIn: optedIn)`.
    /// See `setConsent(category:optedIn:)` for full semantics.
    static func setMarketingConsent(_ optedIn: Bool) {
        shared._setConsent(category: "marketing", optedIn: optedIn)
    }
}

// MARK: - RevenueCat link

public extension Pushlane {
    /// Identify the user for Pushlane AND return the exact id to hand RevenueCat.
    ///
    /// Pushlane attributes RevenueCat revenue events (trial_started, subscription_started,
    /// renewal, cancellation…) to a Pushlane user ONLY when RevenueCat's `appUserID`
    /// equals the id passed to `Pushlane.identify`. This convenience makes the contract
    /// one call site — feed the returned value to `Purchases.configure(appUserID:)`
    /// (or `Purchases.logIn`):
    ///
    /// ```swift
    /// let uid = Pushlane.identifyForRevenueCat(currentUser.id)
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

public extension Pushlane {
    /// Build (don't send) the `received` envelope from a push `userInfo` and the
    /// App-Group-shared config. Pure + testable; the NotificationServiceExtension
    /// calls this to measure deliverability (it runs in another process, with no
    /// `Pushlane.shared` runtime state). Returns nil when no user is identified
    /// (`externalId` not yet persisted), since events must attribute to a user.
    ///
    /// `message_id`/`flow_id`/`node_id` are read from the same top-level payload
    /// keys the Go sender writes (and that `opened` reads), so `received` and
    /// `opened` attribute to the SAME send.
    static func receivedEnvelope(
        userInfo: [AnyHashable: Any],
        config: PushlaneSharedConfig
    ) -> EventEnvelope? {
        guard let externalId = config.externalId, !externalId.isEmpty else { return nil }

        var props: [String: PushlaneValue] = [:]
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
