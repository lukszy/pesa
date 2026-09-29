import AppKit
import SwiftUI

/// The app's Settings window.
///
/// Apple's `Settings` scene is deliberately **not resizable** (its minimize and
/// maximize are dimmed and it sizes itself to its content), so it cannot give
/// the resizable sidebar + detail window this app needs. The scene is therefore
/// only used to keep a valid `App` and its `⌘,` menu slot; the real window is an
/// `NSWindow` created and owned here, which is why resizing works.
///
/// `open()` is called from the status item's `Settings…` item, the popover tile,
/// and the app menu command.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    /// `NSToolbar` holds its delegate weakly, so this keeps it alive.
    private static let toolbarDelegate = SettingsToolbarDelegate()

    static func open() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            // No `.miniaturizable`: the Settings scene convention is a quick task
            // that is not minimized. `.resizable` is the point of owning the
            // window rather than using the scene.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.title = "Pesa Settings"
        window.contentViewController = NSHostingController(
            rootView: SettingsView(state: AppState.shared))
        let toolbar = NSToolbar(identifier: "PesaSettingsToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
        return window
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

/// The SwiftUI entry point. `AppDelegate` owns the status item and popover; the
/// `Settings` scene here keeps a valid `App` (and installs the standard app
/// menu) while its `.appSettings` command is replaced with one that opens the
/// resizable window above. The scene's own window is never shown.
struct AppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { SettingsWindow.open() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
