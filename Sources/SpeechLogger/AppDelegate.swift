import AppKit

/// Owns the menubar presence for the app's lifetime. This scaffold ticket shows
/// a placeholder icon and a Quit item; the state-driven icon ladder
/// (`recording` > `failed` > `processing` > `idle`) and the panel are later tickets.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Placeholder glyph. A template image inherits the menubar's colour
            // and adapts to light/dark automatically.
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "speech logger")
            button.image?.isTemplate = true
        }
        statusItem.menu = makeMenu()
        self.statusItem = statusItem
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let heading = NSMenuItem(title: "speech logger", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Sair", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
