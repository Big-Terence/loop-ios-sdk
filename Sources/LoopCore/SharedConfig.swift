import Foundation

/// Cross-process configuration shared between the app and its
/// NotificationServiceExtension via an **App Group** `UserDefaults`.
///
/// The NSE runs in a SEPARATE process and never sees the app's runtime
/// `Loop.shared` state. To emit the `received` deliverability event from the NSE
/// we persist the minimum it needs (ingest base URL, tenant, write-key, the
/// current external id + APNs env) into the App Group at `Loop.configure` /
/// `Loop.identify`, and read it back in the NSE.
public struct LoopSharedConfig: Codable, Sendable, Equatable {
    public var apiBase: URL
    public var tenantId: String
    public var publishableKey: String?
    /// The id last passed to `Loop.identify` — required to attribute `received`.
    public var externalId: String?
    public var environment: ApnsEnvironment?
    /// Install source detected by the app (the NSE can't reliably detect its own) so the
    /// `received` event carries the same TestFlight/App Store signal as `track` events.
    public var installSource: InstallSource?

    public init(
        apiBase: URL,
        tenantId: String,
        publishableKey: String? = nil,
        externalId: String? = nil,
        environment: ApnsEnvironment? = nil,
        installSource: InstallSource? = nil
    ) {
        self.apiBase = apiBase
        self.tenantId = tenantId
        self.publishableKey = publishableKey
        self.externalId = externalId
        self.environment = environment
        self.installSource = installSource
    }
}

/// Reads/writes `LoopSharedConfig` to an App Group `UserDefaults` suite. The app
/// and the NSE must use the SAME App Group id (`Loop.configure(appGroup:)` ==
/// the NSE's `loopAppGroup`). No-ops cleanly when the suite can't be opened.
public enum LoopAppGroupStore {
    static let key = "com.loop.sdk.sharedConfig.v1"

    public static func save(_ config: LoopSharedConfig, appGroup: String) {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }

    public static func load(appGroup: String) -> LoopSharedConfig? {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LoopSharedConfig.self, from: data)
    }

    public static func clear(appGroup: String) {
        UserDefaults(suiteName: appGroup)?.removeObject(forKey: key)
    }
}
