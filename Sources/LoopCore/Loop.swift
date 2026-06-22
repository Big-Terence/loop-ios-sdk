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

    private init() {}

    // MARK: configure / identify

    public static func configure(apiBase: URL, tenantId: String) {
        shared.configure(LoopConfig(apiBase: apiBase, tenantId: tenantId))
    }

    public func configure(_ config: LoopConfig) {
        lock.lock(); defer { lock.unlock() }
        self.config = config
        self.transport = Transport(config: config)
        #if !targetEnvironment(simulator)
        self.environment = ProvisioningProfile.detect()
        #else
        self.environment = .sandbox // the Simulator has no real APNs
        #endif
    }

    /// First-class external identity (R1) — dedup happens server-side.
    public static func identify(_ externalId: String) {
        shared.lock.lock(); shared.externalId = externalId; shared.lock.unlock()
    }

    /// Logout — detach the external id from this device.
    public static func reset() {
        shared.lock.lock(); shared.externalId = nil; shared.lock.unlock()
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
        guard let config, let transport, let externalId else { lock.unlock(); return }
        let env = environment
        lock.unlock()

        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let context = EventContext(
            os: osName,
            osVersion: "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            environment: env,
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
        guard let transport, let externalId else { lock.unlock(); return }
        let env = environment
        lock.unlock()
        transport.register(externalId: externalId, deviceToken: token, environment: env)
    }
}
