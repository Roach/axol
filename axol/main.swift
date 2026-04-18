import Cocoa

// Accessory-policy app: no Dock icon, no menu bar entry. The floating
// axolotl window is the entire UI surface. AppDelegate wires everything
// together (server, registry, stage, alert store) on applicationDidFinishLaunching.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
