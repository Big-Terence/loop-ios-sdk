import Foundation
#if canImport(os)
import os
#endif

/// Internal SDK logging (L17). Two rules:
///  1. Developer-integration diagnostics (`debug`) are **compiled out of Release
///     builds** entirely (`#if DEBUG`) — event names or other app data never
///     reach production logs.
///  2. `error` stays in Release for genuine misconfigurations, but callers must
///     only pass static, non-sensitive text (never keys, tokens, ids or URLs
///     with credentials).
enum PushlaneLog {
    #if canImport(os)
    // legacy os_log subsystem kept across the Loop→Pushlane rebrand (identity continuity) — do not change
    private static let logger = Logger(subsystem: "com.pushlane.sdk", category: "pushlane")
    #endif

    /// Development-only diagnostic (visible in the Xcode console while a DEBUG
    /// build runs; absent from Release binaries).
    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        #if canImport(os)
        logger.debug("\(text, privacy: .public)")
        #else
        print("[Pushlane] \(text)")
        #endif
        #endif
    }

    /// Misconfiguration surfaced even in Release. MUST NOT contain secrets or
    /// variable app data.
    static func error(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #else
        print("[Pushlane] \(message)")
        #endif
    }
}
