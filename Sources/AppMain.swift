import AppKit
import SwiftUI

/// Opens SwiftUI's `Settings` scene from AppKit code. A `Settings` scene only
/// exists inside an `App`, and `showSettingsWindow:` neither exists on `NSApp`
/// nor creates a window. The reliable path is to send the app menu's own
/// `Settings…` item's action to its own target, then bring the resulting window
/// forward: it opens visible but not key.
@MainActor
enum SettingsWindow {
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
            NSApp.windows.first { $0.title.hasSuffix(" Settings") }?.makeKeyAndOrderFront(nil)
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
