import AppKit

MainActor.assumeIsolated {
    #if HDCLEANER_SELFTEST
    if SelfTest.runIfRequested(CommandLine.arguments) { exit(0) }
    #endif
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
