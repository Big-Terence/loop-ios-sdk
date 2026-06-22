import Foundation
#if canImport(UserNotifications) && os(iOS)
import UserNotifications

/// Base class for the app's NotificationServiceExtension target (a SEPARATE Xcode
/// target with a suffixed bundle id + shared App Group). Subclass it in your NSE.
///
/// Two gotchas this guards against:
///  1. `mutable-content:1` must be set by the server (it is) AND the NSE must call
///     `contentHandler` on EVERY branch — otherwise the rich payload silently
///     degrades. We always call it (success, failure, and `serviceExtensionTimeWillExpire`).
///  2. `UNNotificationAttachment` drops the file if the URL lacks a correct
///     extension; we infer one from the MIME/type hint and rename the temp file.
open class LoopNotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    open override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttempt = (request.content.mutableCopy() as? UNMutableNotificationContent)
        guard let bestAttempt else { contentHandler(request.content); return }

        let info = request.content.userInfo
        guard let urlString = (info["image_url"] as? String) ?? (info["loop_media"] as? String),
              let url = URL(string: urlString) else {
            contentHandler(bestAttempt) // no media — still deliver (R: every branch)
            return
        }

        URLSession.shared.downloadTask(with: url) { [weak self] tmp, response, _ in
            guard let self else { return }
            defer { self.deliver() }
            guard let tmp else { return }
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
#endif
