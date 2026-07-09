import Foundation
#if canImport(Security) && canImport(CryptoKit)
import Security
import CryptoKit
#endif

/// Configuration handed to `Pushlane.configure`.
public struct PushlaneConfig: Sendable {
    /// Base URL of the Ingest Worker. MUST be https (L16) — the write-key,
    /// device tokens and events ride on every request. Cleartext http is only
    /// tolerated towards loopback (`http://localhost:8787` for a local
    /// `wrangler dev` worker); any other http base is refused and the SDK
    /// drops sends instead of leaking secrets on the network.
    public var apiBase: URL
    public var tenantId: String
    /// Publishable write-key (`lpk_…`) shown in the dashboard. When set, it is sent
    /// as `Authorization: Bearer <key>` on `/v1/events` and `/v1/register` so the
    /// worker can authenticate ingestion (A2). Optional for back-compat.
    public var publishableKey: String?
    /// App Group id shared with the NotificationServiceExtension. When set, the SDK
    /// mirrors the ingest config into the shared App Group Keychain so the NSE (a
    /// separate process) can emit the `received` event. See README → "received".
    public var appGroup: String?
    /// Optional TLS certificate pinning (L16). SHA-256 hashes of the DER
    /// encoding of certificates you accept (leaf or any CA in the chain). When
    /// set (and no custom `URLSession` is injected), the SDK builds its session
    /// with `PushlaneCertificatePinner` and refuses connections whose validated
    /// chain contains none of the pins. Default `nil` = system trust, exactly
    /// as before — existing integrations are unaffected.
    public var pinnedCertificatesSHA256: [Data]?

    public init(
        apiBase: URL,
        tenantId: String,
        publishableKey: String? = nil,
        appGroup: String? = nil,
        pinnedCertificatesSHA256: [Data]? = nil
    ) {
        self.apiBase = apiBase
        self.tenantId = tenantId
        self.publishableKey = publishableKey
        self.appGroup = appGroup
        self.pinnedCertificatesSHA256 = pinnedCertificatesSHA256
    }
}

/// Posts envelopes to the Ingest Worker. JSON-encodes the canonical EventEnvelope
/// and POSTs to `/v1/events`. A failed send is retried with bounded backoff.
public final class Transport: @unchecked Sendable {
    private let config: PushlaneConfig
    private let session: URLSession
    private let encoder: JSONEncoder
    /// L16 — false when `apiBase` would carry the write-key/tokens/events over
    /// cleartext http to a non-loopback host. Every send becomes a no-op.
    private let transportAllowed: Bool

    public init(config: PushlaneConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else if let pins = config.pinnedCertificatesSHA256, !pins.isEmpty {
            #if canImport(Security) && canImport(CryptoKit)
            self.session = URLSession(
                configuration: .ephemeral,
                delegate: PushlaneCertificatePinner(sha256OfDERCertificates: pins),
                delegateQueue: nil
            )
            #else
            self.session = .shared
            #endif
        } else {
            self.session = .shared
        }
        self.encoder = JSONEncoder()
        self.transportAllowed = Self.isTransportSafe(config.apiBase)
        if !transportAllowed {
            PushlaneLog.error("Pushlane refuses to send over '\(config.apiBase.scheme ?? "?")': apiBase must be https (http is only allowed towards localhost for dev). Events and registrations are dropped.")
        }
    }

    /// L16 — only https may carry secrets; cleartext http is tolerated solely
    /// towards loopback (local `wrangler dev`), never over a real network.
    static func isTransportSafe(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            let host = url.host?.lowercased() ?? ""
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
                || host.hasSuffix(".localhost")
        default:
            return false
        }
    }

    public func send(_ envelope: EventEnvelope) {
        guard transportAllowed else { return }
        guard let body = try? encoder.encode(envelope) else { return }
        var req = URLRequest(url: config.apiBase.appendingPathComponent("v1/events"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(envelope.traceparent, forHTTPHeaderField: "traceparent")
        authorize(&req)
        req.httpBody = body
        post(req, attempt: 0)
    }

    /// Registers/updates a device subscription (token + auto-detected environment).
    /// M9 — appVersion + osVersion are included so the dashboard can show "which
    /// SDK version / OS version is this token from" without a separate identify call.
    /// Both are Foundation-only (Bundle + ProcessInfo) — no UIKit dependency.
    ///
    /// - Parameter authorizationLevel: The push authorization state read from
    ///   `UNUserNotificationCenter.getNotificationSettings()` immediately after the
    ///   APNs token is delivered. Optional — absent for SDK < 0.4 builds.
    public func register(
        externalId: String,
        deviceToken: String,
        environment: ApnsEnvironment,
        authorizationLevel: String? = nil,
        onSuccess: (() -> Void)? = nil
    ) {
        guard transportAllowed else { return } // L16 — never a token over cleartext http
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

        var payload: [String: String] = [
            "tenantId": config.tenantId,
            "externalId": externalId,
            "deviceToken": deviceToken,
            "pushEnvironment": environment.rawValue,
            "osVersion": osVersion,
        ]
        if !appVersion.isEmpty {
            payload["appVersion"] = appVersion
        }
        if let level = authorizationLevel, !level.isEmpty {
            payload["authorizationLevel"] = level
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: config.apiBase.appendingPathComponent("v1/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req)
        req.httpBody = body
        // A successful registration materialises the backend user, so it's the
        // moment to replay any consent choice that was made before the user existed.
        post(req, attempt: 0, onSuccess: onSuccess)
    }

    /// Attach the publishable write-key as `Authorization: Bearer <key>` (A2). No-op
    /// when no key is configured (back-compat: unauthenticated ingestion).
    private func authorize(_ req: inout URLRequest) {
        guard let key = config.publishableKey, !key.isEmpty else { return }
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    /// Posts a consent record to `/v1/consent`.
    ///
    /// Pushlane operates on an **opt-out model**: device registration alone is sufficient
    /// for delivery. Call this only to forward an explicit user choice (opt-out or
    /// re-opt-in) so the backend can honour it. Body shape:
    /// `{ "externalId": …, "category": …, "action": "opt_in" | "opt_out" }`.
    ///
    /// A 404 is treated as **retryable** here (unlike events): the subject may not
    /// exist server-side yet — e.g. an opt-out toggled during onboarding, before the
    /// first `/v1/register`. Retrying (bounded) lets the choice land once the user
    /// materialises. `onSuccess` fires on a 2xx so the caller can clear its durable
    /// pending-consent record. Combined with replay-after-register, this makes an
    /// explicit opt-out impossible to lose (the sacred invariant).
    public func sendConsent(
        externalId: String,
        category: String,
        optedIn: Bool,
        onSuccess: (() -> Void)? = nil
    ) {
        guard transportAllowed else { return }
        let payload: [String: String] = [
            "externalId": externalId,
            "category": category,
            "action": optedIn ? "opt_in" : "opt_out",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: config.apiBase.appendingPathComponent("v1/consent"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req)
        req.httpBody = body
        post(req, attempt: 0, retryNotFound: true, maxRetries: 8, onSuccess: onSuccess)
    }

    private func post(
        _ req: URLRequest,
        attempt: Int,
        retryNotFound: Bool = false,
        maxRetries: Int = 4,
        onSuccess: (() -> Void)? = nil
    ) {
        session.dataTask(with: req) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                onSuccess?()
                return
            }
            // A 404 is retried only for subjects that may still be materialising
            // (consent before register); events/registrations never retry a 404.
            let transient = error != nil || status >= 500 || status == 429
                || (retryNotFound && status == 404)
            if transient && attempt < maxRetries {
                let delay = min(pow(2.0, Double(attempt)) * 0.5, 30)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self?.post(req, attempt: attempt + 1, retryNotFound: retryNotFound,
                               maxRetries: maxRetries, onSuccess: onSuccess)
                }
            }
        }.resume()
    }
}

#if canImport(Security) && canImport(CryptoKit)
/// Opt-in TLS certificate pinning (L16). Wired automatically by `Transport`
/// when `PushlaneConfig.pinnedCertificatesSHA256` is set, or usable directly as
/// the delegate of a custom `URLSession` handed to `Transport(config:session:)`.
///
/// Semantics: the system trust evaluation runs FIRST (a pin never weakens ATS);
/// the challenge is then accepted only if the SHA-256 of the DER encoding of at
/// least one certificate in the validated chain matches a pin. Pin an
/// intermediate/root CA rather than the leaf to survive routine cert rotations.
public final class PushlaneCertificatePinner: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pins: Set<Data>

    public init(sha256OfDERCertificates: [Data]) {
        self.pins = Set(sha256OfDERCertificates)
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 1. Standard system evaluation (hostname, expiry, chain of trust).
        var evalError: CFError?
        guard SecTrustEvaluateWithError(trust, &evalError) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // 2. At least one certificate of the validated chain must match a pin.
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        for cert in chain {
            let der = SecCertificateCopyData(cert) as Data
            if pins.contains(Data(SHA256.hash(data: der))) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
#endif
