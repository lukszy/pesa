import AppKit
import SwiftUI

/// Opens SwiftUI's `Settings` scene from AppKit code. A `Settings` scene only
/// exists inside an `App`, and `showSettingsWindow:` neither exists on `NSApp`
/// nor creates a window. The reliable path is to send the app menu's own
/// `Settings…` item's action to its own target, then bring the resulting window
/// forward: it opens visible but not key.
@MainActor
enum SettingsWindow {
    /// The floor for the sidebar + detail layout. Raised on the window below.
    private static let minimumSize = NSSize(width: 720, height: 520)
    /// Only the first open sets the content size, so a size the user dragged to
    /// survives the next open.
    private static var didSetInitialSize = false

    static func open() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let item = appMenu.items.first(where: { $0.title.hasPrefix("Settings") }),
              let action = item.action
        else { return }

        // SwiftUI keeps one Settings window; re-sending its action brings an
        // already-open one forward rather than creating a second.
        _ = NSApp.sendAction(action, to: item.target, from: item)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: { Self.isSettingsWindow($0.title) })
            else { return }
            Self.prepare(window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Whether a window is the SwiftUI `Settings` scene. The title is
    /// "<App> Settings" on macOS; a bare "Settings" is accepted too.
    static func isSettingsWindow(_ title: String) -> Bool {
        title == "Settings" || title.hasSuffix(" Settings")
    }

    /// Make the Settings window resizable with a floor, and give it a decent
    /// first size. A SwiftUI `Settings` scene otherwise opens a fixed-size
    /// panel. Called from `open()` and from the AppDelegate's key-window
    /// observer, so the app menu's own `Settings…` item (⌘,) gets it too.
    static func prepare(_ window: NSWindow) {
        guard isSettingsWindow(window.title) else { return }
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        window.contentMinSize = minimumSize
        // Only the first time, so a size the user dragged to survives reopening.
        if !didSetInitialSize {
            didSetInitialSize = true
            window.setContentSize(NSSize(width: 900, height: 640))
            window.center()
        }
    }
}

/// The SwiftUI entry point. `AppDelegate` still owns the status item and
/// popover; this only contributes the `Settings` scene (which also installs the
/// app menu's About/Settings…/Services/Hide/Quit items, so ⌘, works).
struct AppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(state: AppState.shared)
        }
    }
}
