import Foundation

/// A typed property value. Mirrors the catalogue's value space (string/number/
/// bool/array). The SDK sends typed values; the backend coerces against the
/// declared catalogue type (it never infers from the first value — R6).
public enum PushlaneValue: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([PushlaneValue])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
}

extension PushlaneValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// SDK/app context attached to every event (used for routing + observability).
public struct EventContext: Encodable, Sendable {
    public var sdk: String
    public var sdkVersion: String?
    public var os: String?
    public var osVersion: String?
    public var appVersion: String?
    public var environment: ApnsEnvironment?
    /// How the build was installed (appstore | testflight | development) — distinct from
    /// `environment` (APNs routing). Lets the dashboard tell TestFlight from App Store.
    public var installSource: InstallSource?
    public var tzIana: String?
    public var locale: String?

    public init(
        sdk: String = "pushlane-ios",
        sdkVersion: String? = PushlaneSDKInfo.version,
        os: String? = nil,
        osVersion: String? = nil,
        appVersion: String? = nil,
        environment: ApnsEnvironment? = nil,
        installSource: InstallSource? = nil,
        tzIana: String? = nil,
        locale: String? = nil
    ) {
        self.sdk = sdk
        self.sdkVersion = sdkVersion
        self.os = os
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.environment = environment
        self.installSource = installSource
        self.tzIana = tzIana
        self.locale = locale
    }

    enum CodingKeys: String, CodingKey {
        case sdk, sdkVersion, os, osVersion, appVersion, environment, installSource, tzIana, locale
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sdk, forKey: .sdk)
        try c.encodeIfPresent(sdkVersion, forKey: .sdkVersion)
        try c.encodeIfPresent(os, forKey: .os)
        try c.encodeIfPresent(osVersion, forKey: .osVersion)
        try c.encodeIfPresent(appVersion, forKey: .appVersion)
        try c.encodeIfPresent(environment?.rawValue, forKey: .environment)
        try c.encodeIfPresent(installSource?.rawValue, forKey: .installSource)
        try c.encodeIfPresent(tzIana, forKey: .tzIana)
        try c.encodeIfPresent(locale, forKey: .locale)
    }
}

/// The canonical event envelope — the exact shape the Ingest Worker validates.
/// The `eventId` is generated at the true origin (here) and carried unchanged
/// end-to-end (R2); `traceparent` (R3) too.
public struct EventEnvelope: Encodable, Sendable {
    public var eventId: String
    public var tenantId: String
    public var externalId: String
    public var name: String
    public var properties: [String: PushlaneValue]
    public var occurredAt: Int64
    public var context: EventContext
    public var traceparent: String
    public var tracestate: String?

    public init(
        tenantId: String,
        externalId: String,
        name: String,
        properties: [String: PushlaneValue] = [:],
        occurredAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        context: EventContext,
        eventId: String = UUID().uuidString.lowercased(),
        traceparent: String = Trace.newTraceparent()
    ) {
        self.eventId = eventId
        self.tenantId = tenantId
        self.externalId = externalId
        self.name = name
        self.properties = properties
        self.occurredAt = occurredAt
        self.context = context
        self.traceparent = traceparent
    }
}

/// W3C trace context generation (origin-side).
public enum Trace {
    public static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
    /// version-traceid(16B)-spanid(8B)-flags(sampled).
    public static func newTraceparent() -> String {
        "00-\(randomHex(16))-\(randomHex(8))-01"
    }
}

public enum PushlaneSDKInfo {
    public static let version = "0.5.0"
}
