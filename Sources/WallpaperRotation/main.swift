import AppKit

let application = NSApplication.shared
let delegate = AppCoordinator()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
