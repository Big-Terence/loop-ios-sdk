import Foundation
import PushlaneCore
#if canImport(UserNotifications) && os(iOS)
import UserNotifications

/// Base class for the app's NotificationServiceExtension target (a SEPARATE Xcode
/// target with a suffixed bundle id + shared App Group). Subclass it in your NSE.
///
/// Three jobs this handles:
///  1. `mutable-content:1` must be set by the server (it is) AND the NSE must call
///     `contentHandler` on EVERY branch — otherwise the rich payload silently
///     degrades. We always call it (success, failure, and `serviceExtensionTimeWillExpire`).
///  2. `UNNotificationAttachment` drops the file if the URL lacks a correct
///     extension; we infer one from the MIME/type hint and rename the temp file.
///  3. Emits a `received` deliverability event (best-effort, non-blocking) the
///     moment a push lands — measured even when the user never opens it. The NSE
///     is a SEPARATE process, so it reads the ingest config the app mirrored into
///     the App Group (`Pushlane.configure(appGroup:)`). Override `pushlaneAppGroup`.
open class PushlaneNotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    /// Override to the SAME App Group id passed to `Pushlane.configure(appGroup:)`.
    /// When nil, rich media still works but no `received` event is sent.
    open var pushlaneAppGroup: String? { nil }

    // I9 — bounds for the rich-media download. The payload comes from APNs (the
    // tenant's own backend wrote it), but defense-in-depth: https only (redirects
    // included), bounded size (50 MB = Apple's own cap for video attachments,
    // enforced mid-flight AND on the final file) and bounded time so a
    // slow/hostile host can't eat the NSE's ~30s execution budget.
    static let maxMediaBytes: Int64 = 50 * 1024 * 1024
    private static let mediaSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10   // stalled connection
        cfg.timeoutIntervalForResource = 20  // whole transfer, inside the NSE budget
        // The delegate blocks https→http redirect downgrades and cancels
        // oversized transfers early; URLSession still routes those callbacks
        // through the session delegate for completion-handler tasks.
        return URLSession(configuration: cfg, delegate: PushlaneMediaSessionDelegate(), delegateQueue: nil)
    }()

    open override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttempt = (request.content.mutableCopy() as? UNMutableNotificationContent)

        // Fire `received` first so its POST runs concurrently with the media
        // download (which keeps this process alive) — best-effort, never blocking.
        emitReceived(for: request)

        guard let bestAttempt else { contentHandler(request.content); return }

        let info = request.content.userInfo
        // "loop_media" payload key kept across the Loop→Pushlane rebrand — wire contract with the APNs sender and shipped apps
        guard let urlString = (info["image_url"] as? String) ?? (info["loop_media"] as? String),
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "https" else { // I9 — https only (redirects re-checked by the delegate)
            contentHandler(bestAttempt) // no (valid) media — still deliver (R: every branch)
            return
        }

        Self.mediaSession.downloadTask(with: url) { [weak self] tmp, response, _ in
            guard let self else { return }
            defer { self.deliver() }
            guard let tmp else { return } // nil on error, incl. delegate-cancelled transfers
            // I9 — only attach a successful, size-bounded response. The file-size
            // check is a backstop: the delegate already cancels oversized
            // transfers mid-flight.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
            if let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber,
               size.int64Value > Self.maxMediaBytes { return }
            let ext = Self.fileExtension(for: response, fallbackURL: url)
            let dest = tmp.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                let attachment = try UNNotificationAttachment(identifier: "media", url: dest)
                bestAttempt.attachments = [attachment]
            } catch {
                // fall through — deliver text-only rather than dropping the push
            }
        }.resume()
    }

    open override func serviceExtensionTimeWillExpire() {
        deliver() // the OS is about to kill us — deliver our best attempt (every branch)
    }

    private func deliver() {
        guard let handler = contentHandler, let content = bestAttempt else { return }
        contentHandler = nil
        handler(content)
    }

    /// Best-effort `received` event. Reads the App-Group-mirrored ingest config and
    /// POSTs via the same PushlaneCore Transport (so the envelope shape, write-key auth
    /// and trace are identical to the app's events). Fire-and-forget: a failure or
    /// a missing App Group never affects push rendering.
    private func emitReceived(for request: UNNotificationRequest) {
        guard let group = pushlaneAppGroup,
              let cfg = PushlaneAppGroupStore.load(appGroup: group),
              let envelope = Pushlane.receivedEnvelope(userInfo: request.content.userInfo, config: cfg)
        else { return }
        let transport = Transport(config: PushlaneConfig(
            apiBase: cfg.apiBase,
            tenantId: cfg.tenantId,
            publishableKey: cfg.publishableKey
        ))
        transport.send(envelope)
    }

    static func fileExtension(for response: URLResponse?, fallbackURL: URL) -> String {
        let urlExt = fallbackURL.pathExtension
        if !urlExt.isEmpty { return urlExt }
        switch response?.mimeType {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        default: return "jpg"
        }
    }
}

/// I9 — session-level guards the completion-handler API can't express. URLSession
/// routes redirect and download-progress callbacks through the session delegate
/// even for tasks created with a completion handler.
private final class PushlaneMediaSessionDelegate: NSObject, URLSessionDownloadDelegate {
    /// Refuse to leave https: a 30x pointing at http:// (or any other scheme)
    /// would otherwise be followed silently, defeating the scheme check made on
    /// the original URL. Returning nil ends the task with the 30x response,
    /// which the status check in `didReceive` rejects → text-only delivery.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }

    /// Cancel as soon as the transfer is KNOWN to exceed the cap — upfront when
    /// Content-Length announces it (`totalBytesExpectedToWrite`, -1 if unknown),
    /// or mid-flight for chunked/lying servers — instead of downloading it all
    /// and discarding the file afterwards. Cancelling surfaces in the completion
    /// handler as `tmp == nil`, so the push still delivers (every-branch rule).
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > PushlaneNotificationService.maxMediaBytes
            || totalBytesExpectedToWrite > PushlaneNotificationService.maxMediaBytes {
            downloadTask.cancel()
        }
    }

    // Required by URLSessionDownloadDelegate; never called here — the file URL
    // goes to the task's completion handler instead.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
#endif
