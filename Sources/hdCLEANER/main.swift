import AppKit

MainActor.assumeIsolated {
    #if HDCLEANER_SELFTEST
    if SelfTest.runIfRequested(CommandLine.arguments) { exit(0) }
    #endif
    if !SingleInstance.acquire() {
        // Déjà lancée (souvent par l'agent de connexion) : on lui fait ouvrir sa fenêtre, sauf si c'est l'agent lui-même qui arrive en double.
        if !CommandLine.arguments.contains("--monitor") { SingleInstance.askRunningInstanceToShowWindow() }
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
