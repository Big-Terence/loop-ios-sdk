import Foundation
#if canImport(Security) && canImport(CryptoKit)
import Security
import CryptoKit
#endif

/// Configuration handed to `Loop.configure`.
public struct LoopConfig: Sendable {
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
    /// with `LoopCertificatePinner` and refuses connections whose validated
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
    private let config: LoopConfig
    private let session: URLSession
    private let encoder: JSONEncoder
    /// L16 — false when `apiBase` would carry the write-key/tokens/events over
    /// cleartext http to a non-loopback host. Every send becomes a no-op.
    private let transportAllowed: Bool

    public init(config: LoopConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else if let pins = config.pinnedCertificatesSHA256, !pins.isEmpty {
            #if canImport(Security) && canImport(CryptoKit)
            self.session = URLSession(
                configuration: .ephemeral,
                delegate: LoopCertificatePinner(sha256OfDERCertificates: pins),
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
            LoopLog.error("Loop refuses to send over '\(config.apiBase.scheme ?? "?")': apiBase must be https (http is only allowed towards localhost for dev). Events and registrations are dropped.")
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
    public func register(externalId: String, deviceToken: String, environment: ApnsEnvironment) {
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
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: config.apiBase.appendingPathComponent("v1/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req)
        req.httpBody = body
        post(req, attempt: 0)
    }

    /// Attach the publishable write-key as `Authorization: Bearer <key>` (A2). No-op
    /// when no key is configured (back-compat: unauthenticated ingestion).
    private func authorize(_ req: inout URLRequest) {
        guard let key = config.publishableKey, !key.isEmpty else { return }
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private func post(_ req: URLRequest, attempt: Int) {
        session.dataTask(with: req) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let transient = error != nil || status >= 500 || status == 429
            if transient && attempt < 4 {
                let delay = pow(2.0, Double(attempt)) * 0.5
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self?.post(req, attempt: attempt + 1)
                }
            }
        }.resume()
    }
}

#if canImport(Security) && canImport(CryptoKit)
/// Opt-in TLS certificate pinning (L16). Wired automatically by `Transport`
/// when `LoopConfig.pinnedCertificatesSHA256` is set, or usable directly as
/// the delegate of a custom `URLSession` handed to `Transport(config:session:)`.
///
/// Semantics: the system trust evaluation runs FIRST (a pin never weakens ATS);
/// the challenge is then accepted only if the SHA-256 of the DER encoding of at
/// least one certificate in the validated chain matches a pin. Pin an
/// intermediate/root CA rather than the leaf to survive routine cert rotations.
public final class LoopCertificatePinner: NSObject, URLSessionDelegate, @unchecked Sendable {
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
