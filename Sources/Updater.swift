import AppKit
import Sparkle

/// The only file that touches Sparkle. Inert (`isAvailable == false`) unless the
/// build is a `.app` stamped with a public key, so the raw `.build/Pesa` binary
/// and key-less local builds never start an updater.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    func start() {
        guard controller == nil,
              UpdateSupport.isConfigured(
                info: Bundle.main.infoDictionary ?? [:],
                isBundled: Bundle.main.bundlePath.hasSuffix(".app"))
        else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// The app is `LSUIElement`, so Sparkle's windows need an explicit activate
    /// to come to the front.
    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateSupport.overrideFeedURL(UserDefaults.standard.string(forKey: UpdateSupport.overrideKey))
            ?? UpdateSupport.feedURL
    }
}
