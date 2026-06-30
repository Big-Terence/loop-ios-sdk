import Foundation

/// How the running build was INSTALLED — distinct from `ApnsEnvironment` (the APNs
/// routing env, where TestFlight AND development both report `.sandbox`). The dashboard
/// uses this to tell a TestFlight build from a live App Store release WITHOUT App Store
/// Connect, so an operator can target "everyone on my TestFlight build" precisely.
///
/// Detection (synchronous, pure Foundation — no StoreKit/AppTransaction dependency):
///   • development — the build ships `embedded.mobileprovision` (Xcode / ad-hoc / dev),
///     which the App Store AND TestFlight both strip. A present profile is the strongest
///     signal, so it wins regardless of the receipt.
///   • else the App Store receipt NAME disambiguates the two stripped-profile cases:
///       "receipt"        → appstore   (a live App Store install)
///       "sandboxReceipt" → testflight (a TestFlight beta install)
///   The URL's last component reflects the environment even before the receipt file is
///   written to disk, so this is reliable on a fresh install.
///
/// Ambiguity we accept honestly: `sandboxReceipt` alone can't separate TestFlight from a
/// dev build — that's why we check the provisioning profile FIRST. The Simulator (no real
/// receipt) is treated as development.
public enum InstallSource: String, Sendable, Codable {
    case appstore
    case testflight
    case development

    public static func detect(bundle: Bundle = .main) -> InstallSource {
        #if targetEnvironment(simulator)
        return .development
        #else
        // Dev / ad-hoc builds carry an embedded provisioning profile; store + TestFlight strip it.
        if bundle.url(forResource: "embedded", withExtension: "mobileprovision") != nil {
            return .development
        }
        switch bundle.appStoreReceiptURL?.lastPathComponent {
        case "receipt": return .appstore
        case "sandboxReceipt": return .testflight
        // No receipt URL at all (rare on a real device): stay neutral — never claim a
        // build is the live App Store release when we can't actually tell.
        default: return .development
        }
        #endif
    }
}
