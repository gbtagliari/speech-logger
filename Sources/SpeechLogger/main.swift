import AppKit

// Menubar-only (accessory) app: no Dock icon, no main window, no app-switcher
// entry. `LSUIElement` in Info.plist plus `.accessory` here keep it out of both.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
