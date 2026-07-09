import Foundation
import PushlaneCore
#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - PushlanePrimerConfig

/// Configuration for the pre-permission primer UI.
///
/// A primer is a custom sheet shown BEFORE the iOS system permission prompt
/// to set expectations and improve the accept rate. It does NOT replace the
/// system prompt — it primes the user so they are more likely to tap "Allow"
/// when the real OS dialog appears.
///
/// For provisional flows, set `provisional: true` so the "Allow" button calls
/// `PushlanePush.register(provisional: true)` — no OS prompt is shown and a silent
/// token is granted immediately.
public struct PushlanePrimerConfig: Sendable {
    /// Sheet title (bold headline). Default: "Stay in the loop"
    public var title: String
    /// Body message below the title. Default: "Get timely, relevant updates from us."
    public var message: String
    /// Primary action button label. Default: "Enable notifications"
    public var allowTitle: String
    /// Secondary (dismiss) button label. Default: "Not now"
    public var notNowTitle: String
    /// When `true`, the Allow button calls `PushlanePush.register(provisional: true)`
    /// (silent, no OS prompt). When `false` (default) it calls the standard
    /// `PushlanePush.register()` which shows the OS prompt.
    public var provisional: Bool

    public init(
        title: String = "Stay in the loop",
        message: String = "Get timely, relevant updates from us.",
        allowTitle: String = "Enable notifications",
        notNowTitle: String = "Not now",
        provisional: Bool = false
    ) {
        self.title = title
        self.message = message
        self.allowTitle = allowTitle
        self.notNowTitle = notNowTitle
        self.provisional = provisional
    }
}

// MARK: - PushlanePrimerView

#if canImport(SwiftUI)
/// A minimal SwiftUI primer sheet.
///
/// Present it with `.sheet(isPresented:) { PushlanePrimerView(config: ...) }`.
/// The "Allow" button triggers push registration (provisional or standard, per
/// `config.provisional`) then dismisses the sheet. "Not now" dismisses only —
/// it does NOT request any permission (no permission burned).
///
/// This is a convenience component. You can build your own UI and call
/// `PushlanePush.register(provisional:)` directly from your own button handler.
///
/// Apple constraints (display these to users honestly):
/// - Provisional notifications are silent: no sound, no banner/lock-screen,
///   delivered only to Notification Center, below prominent notifications.
/// - They carry "Keep" / "Turn Off" actions. User promotes or opts out.
/// - We cannot force promotion. `.provisional` is iOS 12+.
/// - A prior explicit denial is NOT overridden by provisional.
@available(iOS 14.0, *)
public struct PushlanePrimerView: View {
    @Environment(\.dismiss) private var dismiss
    public let config: PushlanePrimerConfig

    public init(config: PushlanePrimerConfig = PushlanePrimerConfig()) {
        self.config = config
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bell.badge")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(.accentColor)
            VStack(spacing: 10) {
                Text(config.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(config.message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 12) {
                Button(config.allowTitle) {
                    // Optional primer analytics — gated behind identify (N22).
                    Pushlane.track("push_primer", ["result": .string("allow"), "provisional": .bool(config.provisional)])
                    PushlanePush.register(provisional: config.provisional)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)

                Button(config.notNowTitle) {
                    Pushlane.track("push_primer", ["result": .string("dismiss"), "provisional": .bool(config.provisional)])
                    dismiss()
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
