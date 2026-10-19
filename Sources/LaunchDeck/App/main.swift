import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
Preferences.applyDockVisibility()
app.run()
