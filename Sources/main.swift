import AppKit
import Combine
import SwiftUI

var statusItem: NSStatusItem?

func makeStatusItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
        button.image = NSImage(
            systemSymbolName: "dollarsign.circle",
            accessibilityDescription: "Pesa"
        )
        button.title = " $0.00"
    }
    return item
}

func runProbe() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    statusItem = makeStatusItem()

    // Let AppKit attach and show the status item window before inspecting it.
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

    let button = statusItem?.button
    let window = button?.window
    print("statusItem=\(statusItem != nil) button=\(button != nil) window=\(window != nil) visible=\(window?.isVisible == true)")
    return 0
}

/// Renders the status item from whatever `MenuBarPresentation` decides, so the
/// never-both-nil invariant and the em-dash fallback have exactly one owner.
/// Also the tracking-area owner for hover: the status button has no hover
/// callback of its own, so entering and leaving reveal and re-hide the amount.
@MainActor
final class StatusItemController: NSObject {
    let item: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    /// Kept so a hover change can re-render without waiting for the next state
    /// emission: the title must flip the moment the pointer enters or leaves.
    private var latestRemaining: Double?
    private var latestError = false
    private var latestConfig = AppConfig()
    private var isHovering = false

    init(state: AppState, target: AnyObject, action: Selector) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.target = target
        item.button?.action = action
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // `.inVisibleRect` tracks the button's current bounds; `.activeAlways`
        // keeps hover working while the app is not frontmost.
        if let button = item.button {
            button.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil))
        }

        state.$remaining
            .combineLatest(state.$errorText, state.$config)
            .receive(on: RunLoop.main)
            .sink { [weak self] remaining, errorText, config in
                self?.render(remaining: remaining, error: errorText != nil, config: config)
            }
            .store(in: &cancellables)
    }

    @objc private func mouseEntered(_ event: NSEvent) {
        isHovering = true
        render(remaining: latestRemaining, error: latestError, config: latestConfig)
    }

    @objc private func mouseExited(_ event: NSEvent) {
        isHovering = false
        render(remaining: latestRemaining, error: latestError, config: latestConfig)
    }

    private func render(remaining: Double?, error: Bool, config: AppConfig) {
        latestRemaining = remaining
        latestError = error
        latestConfig = config
        // The caller owns the hover subtraction, so `MenuBarPresentation` stays
        // pure. A settings change re-enters here through the Combine sink and
        // picks up the current `isHovering` immediately.
        let presentation = MenuBarPresentation.of(
            showMoney: config.showMoneyInMenuBar,
            showIcon: config.showIconInMenuBar,
            balance: remaining,
            error: error,
            redacted: config.hidesAmountInMenuBar && !isHovering)
        item.button?.title = presentation.text.map { " \($0)" } ?? ""
        item.button?.image = presentation.symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: "Pesa")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var popover: NSPopover?
    private var statusController: StatusItemController?

    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the raw `.build/` binary out of the Dock; the bundled app is
        // already LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        // The same instance the `Settings` scene observes; see `AppState.shared`.
        let state = AppState.shared
        self.state = state

        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: PopoverView(state: state))
        popover.behavior = .transient
        self.popover = popover

        let controller = StatusItemController(
            state: state, target: self, action: #selector(togglePopover))
        statusController = controller
        statusItem = controller.item

        // Refresh once at launch; the timer and the refresh icon cover the rest.
        Task { await state.refresh() }
    }

    @objc private func togglePopover() {
        // A right-click shows the context menu; only a left-click toggles.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        guard let state, let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Show first: discovery runs off the main
            // actor afterwards, so it cannot delay the popover appearing.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await state.discoverProviders() }
        }
    }

    @objc private func openSettings() { SettingsWindow.open() }

    @objc private func openCredits() {
        // Guarded optional: a malformed literal must not crash the app.
        guard let url = URL(string: "https://openrouter.ai/settings/credits") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Pops an `NSMenu` from the status item. `statusItem.menu` is assigned only
    /// for the duration of the click and then cleared, so left-click keeps
    /// toggling the popover via the button action.
    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        statusItem?.menu = makeContextMenu()
        button.performClick(nil)
        statusItem?.menu = nil
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let creditsItem = NSMenuItem(
            title: "Buy credits…", action: #selector(openCredits), keyEquivalent: "")
        creditsItem.target = self
        menu.addItem(creditsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }
}

// Dispatch before touching NSApplication so --selftest runs in a plain terminal.
// Top-level code runs on the main thread; `assumeIsolated` states that so the
// main-actor `SelfTest.run()` (it exercises `CatalogCache`) can be called.
if CommandLine.arguments.contains("--selftest") {
    exit(MainActor.assumeIsolated { SelfTest.run() })
}
if CommandLine.arguments.contains("--probe") {
    exit(runProbe())
}

// The SwiftUI `App` owns the lifecycle from here: its `Settings` scene gives
// us the app menu's Settings… item (and ⌘, for free), while `AppDelegate`
// keeps the status item and popover.
AppMain.main()
