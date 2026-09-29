import AppKit
import SwiftUI

/// Opens and configures SwiftUI's `Settings` scene from AppKit.
///
/// A `Settings` scene only exists inside an `App`, and `showSettingsWindow:`
/// neither exists on `NSApp` nor creates a window. The reliable path is to send
/// the app menu's own `Settings…` item's action to its own target, then bring
/// the resulting window forward: it opens visible but not key.
///
/// SwiftUI also *ignores* `.windowResizability` on a `Settings` scene and puts a
/// SwiftUI `.toolbar` outside the title bar, so the window is configured
/// directly here instead: `.resizable`, a floor, and a real `NSToolbar`.
@MainActor
enum SettingsWindow {
    /// The floor for the sidebar + detail layout.
    private static let minimumSize = NSSize(width: 720, height: 520)
    /// Only the first open sets the content size, so a size the user dragged to
    /// survives the next open.
    private static var didSetInitialSize = false
    /// `NSToolbar` holds its delegate weakly, so this keeps it alive.
    private static let toolbarDelegate = SettingsToolbarDelegate()

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

    /// Makes the Settings window resizable with a floor, installs the sidebar
    /// toolbar, and gives the window a decent first size. Idempotent, and called
    /// both from `open()` and from the view itself
    /// (`SettingsWindowConfigurator`), because the scene ignores
    /// `.windowResizability`.
    static func prepare(_ window: NSWindow?) {
        guard let window, isSettingsWindow(window.title) else { return }
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        window.contentMinSize = minimumSize
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "PesaSettingsToolbar")
            toolbar.delegate = toolbarDelegate
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
        // Only the first time, so a size the user dragged to survives reopening.
        if !didSetInitialSize {
            didSetInitialSize = true
            window.setContentSize(NSSize(width: 900, height: 640))
            window.center()
        }
    }
}

/// The Settings window's title-bar toolbar: one button that shows or hides the
/// sidebar. It flips the shared `AppState.showSidebar`, so the SwiftUI content
/// and the toolbar always agree.
@MainActor
final class SettingsToolbarDelegate: NSObject, NSToolbarDelegate {
    private static let toggleSidebar = NSToolbarItem.Identifier("toggleSidebar")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toggleSidebar]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toggleSidebar]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.toggleSidebar else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Sidebar"
        item.paletteLabel = "Sidebar"
        item.toolTip = "Show or hide the sidebar"
        item.image = NSImage(systemSymbolName: "sidebar.left",
                             accessibilityDescription: "Toggle sidebar")
        item.target = self
        item.action = #selector(toggleSidebarAction)
        return item
    }

    @objc private func toggleSidebarAction() {
        AppState.shared.showSidebar.toggle()
    }
}

/// Reaches the hosting `NSWindow` from inside SwiftUI, so the Settings scene's
/// window is configured even when `open()`'s menu action is not what showed it.
struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { SettingsWindow.prepare(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { SettingsWindow.prepare(view.window) }
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
