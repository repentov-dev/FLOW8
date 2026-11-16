import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.setActivationPolicy(.regular)
    application.run()
}
