import Foundation

/// The Sparkle-free parts of OTA updates, kept separate from `Updater` so
/// `--selftest` can exercise them without a bundle or the framework running.
enum UpdateSupport {
    static let feedURL = "https://github.com/lukszy/pesa/releases/latest/download/appcast.xml"

    /// `defaults write local.pesa PesaFeedURLOverride <url>` points the updater at
    /// a local appcast for manual end-to-end testing. Updates are still
    /// EdDSA-verified, so this cannot install unsigned code.
    static let overrideKey = "PesaFeedURLOverride"

    /// The override if it is safe to use: https, or http only to loopback.
    static func overrideFeedURL(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" { return raw }
        if scheme == "http", host == "localhost" || host == "127.0.0.1" { return raw }
        return nil
    }

    /// The updater runs only from a `.app` whose build stamped a public key.
    static func isConfigured(info: [String: Any], isBundled: Bool) -> Bool {
        guard isBundled, let key = info["SUPublicEDKey"] as? String else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
