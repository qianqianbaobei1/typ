import AppKit

MainActor.assumeIsolated {
    let bundleID = Bundle.main.bundleIdentifier ?? "local.typ.app"
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0.processIdentifier != currentPID }
    if let existing = others.first {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("local.typ.app.showWindow"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        existing.activate()
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
