import AppKit

var statusItem: NSStatusItem?

func makeStatusItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
        button.image = NSImage(
            systemSymbolName: "dollarsign.circle",
            accessibilityDescription: "Provider Cost Controller"
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

// Dispatch before touching NSApplication so --selftest runs in a plain terminal.
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}
if CommandLine.arguments.contains("--probe") {
    exit(runProbe())
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
statusItem = makeStatusItem()
app.run()
