import AppKit

// Single-instance check: prevent running multiple copies
let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
let existingInstances = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == bundleID && $0 != NSRunningApplication.current
}
if !existingInstances.isEmpty {
    existingInstances.first?.activate()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
