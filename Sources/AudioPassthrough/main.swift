import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no dock icon, menu bar only

let delegate = AppDelegate()
app.delegate = delegate
app.run()
