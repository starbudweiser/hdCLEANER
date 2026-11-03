import AppKit
import HdCleanerCore
import OSLog
import ServiceManagement
import SwiftUI

enum Brand {
    static let nsColor = NSColor(srgbRed: 0xA7 / 255, green: 0x8B / 255, blue: 0xFA / 255, alpha: 1)
    static let color = Color(nsColor)
}

enum Log {
    static let app = Logger(subsystem: "com.stephan.hdcleaner", category: "app")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var window: NSWindow?
    private var status: MonitorStatus?
    /// Lancé par l'agent de connexion : surveillance seule, sans fenêtre.
    private let background = CommandLine.arguments.contains("--monitor")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Socle.brand("hdCLEANER", color: Brand.color)
        Socle.apply(model.socleTheme)
        NSApp.mainMenu = makeMenu()
        status = MonitorStatus(model: model, open: { [weak self] in self?.showWindow() })
        model.startMonitoring()
        model.applyWatcher()
        DistributedNotificationCenter.default().addObserver(forName: SingleInstance.showWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showWindow() }
        }
        if background {
            NSApp.setActivationPolicy(.accessory)
        } else {
            startSplash()
            NSApp.setActivationPolicy(.regular)
            showWindow()
        }
    }

    /// Splash Socle (4 s, fenêtre à t = 2 s) à chaque lancement avec fenêtre ; pas pour l'agent de connexion ni pour les essais silencieux.
    private func startSplash() {
        #if HDCLEANER_SELFTEST
        if ProcessInfo.processInfo.environment["HDCLEANER_QUIET"] != nil { return }
        #endif
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        Splash.shared.start(Splash.Config(title: "hdCLEANER", accentLetters: 2, subtitle: L("splash.subtitle"), footer: version.isEmpty ? "" : "v" + version,
                                          iconView: AnyView(AnimatedDiskMark()), accent: Brand.color))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.keepsRunningWithoutWindow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func windowDidResize(_ notification: Notification) {
        if let w = notification.object as? NSWindow, !w.inLiveResize { WindowSize.save(w) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let w = notification.object as? NSWindow { WindowSize.save(w) }
    }

    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow { WindowSize.save(w) }
        if model.keepsRunningWithoutWindow { NSApp.setActivationPolicy(.accessory) } // plus d'icône dans le Dock sans fenêtre
    }

    private func showWindow() {
        #if HDCLEANER_SELFTEST
        let quiet = ProcessInfo.processInfo.environment["HDCLEANER_QUIET"] != nil // essai : fenêtre derrière les autres, sans prendre le focus
        #else
        let quiet = false
        #endif
        NSApp.setActivationPolicy(quiet ? .accessory : .regular)
        if window == nil {
            let hosting = NSHostingController(rootView: MainView().environmentObject(model).splashGated())
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = "hdCLEANER"
            w.contentMinSize = WindowSize.minimum
            w.setContentSize(WindowSize.loaded())
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.socleCenter()
            window = w
        }
        if quiet { window?.orderBack(nil) } else { window?.present() }
    }

    private func makeMenu() -> NSMenu {
        let bar = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            bar.addItem(item)
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            menu.addItem(item)
        }
        let app = submenu("hdCLEANER")
        add(app, L("about.menu"), #selector(openAbout), target: self)
        app.addItem(.separator())
        add(app, L("menu.settings"), #selector(openSettings), ",", target: self)
        app.addItem(.separator())
        add(app, L("menu.hide"), #selector(NSApplication.hide(_:)), "h")
        add(app, L("menu.quit"), #selector(NSApplication.terminate(_:)), "q")
        let window = submenu(L("menu.window"))
        add(window, L("menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, L("menu.close"), #selector(NSWindow.performClose(_:)), "w")
        NSApp.windowsMenu = window
        return bar
    }

    @objc private func openAbout() { About.show() }
    @objc private func openSettings() { SettingsWindow.show(model: model) }
}

/// Taille de la fenêtre principale : retenue d'un lancement à l'autre ; la position, elle, est recalculée (centrée) à chaque lancement.
enum WindowSize {
    static let minimum = NSSize(width: 980, height: 600)
    static let fallback = NSSize(width: 1080, height: 680)
    private static let key = "windowSize"

    static func loaded() -> NSSize {
        guard let text = UserDefaults.standard.string(forKey: key) else { return fallback }
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return fallback }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? NSSize(width: 4000, height: 3000)
        // Jamais plus petite que le minimum, jamais plus grande que l'écran (écran changé depuis).
        return NSSize(width: min(max(parts[0], minimum.width), max(screen.width, minimum.width)), height: min(max(parts[1], minimum.height), max(screen.height, minimum.height)))
    }

    /// Pas en plein écran ni zoomée : ces tailles-là ne sont pas un choix de l'utilisateur.
    @MainActor static func save(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        UserDefaults.standard.set("\(Int(size.width)),\(Int(size.height))", forKey: key)
    }
}

/// Icône de barre de menus, visible seulement quand la surveillance est active.
@MainActor
final class MonitorStatus: NSObject {
    private let model: AppModel
    private let open: () -> Void
    private var item: NSStatusItem?
    private var header: NSMenuItem?
    private var menu: NSMenu?
    private var tip = ""

    init(model: AppModel, open: @escaping () -> Void) {
        self.model = model
        self.open = open
        super.init()
        model.onMonitorChange = { [weak self] in self?.render() }
        render()
    }

    private func render() {
        guard model.keepsRunningWithoutWindow else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            menu = nil
            return
        }
        if item == nil {
            let new = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            let head = NSMenuItem(title: "", action: nil, keyEquivalent: "") // nom du disque surveillé et son espace libre
            head.isEnabled = false
            menu.addItem(head)
            header = head
            menu.addItem(.separator())
            let entry = NSMenuItem(title: L("menu.open"), action: #selector(openWindow), keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
            menu.addItem(.separator())
            let about = NSMenuItem(title: L("about.menu"), action: #selector(openAbout), keyEquivalent: "")
            about.target = self
            menu.addItem(about)
            menu.addItem(NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
            // Menu ouvert à la main, ancré sur le bouton : le menu attaché à l'item s'ouvrait parfois loin de l'icône (plusieurs écrans).
            self.menu = menu
            new.button?.target = self
            new.button?.action = #selector(showMenu(_:))
            new.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item = new
        }
        guard let button = item?.button else { return }
        let symbol = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        symbol?.isTemplate = !model.belowThreshold
        button.image = symbol
        button.contentTintColor = model.belowThreshold ? .systemRed : nil
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        guard model.settings.monitorEnabled else { // surveillance des fichiers invisibles seule : une icône sans disque
            button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.title = ""
            let text = L("watch.tooltip", model.settings.watchedFolders.count) + (model.invisibles.watchRemoved > 0 ? " · " + L("watch.removed", model.invisibles.watchRemoved) : "")
            setTip(button, text)
            header?.title = text
            return
        }
        guard let disk = model.monitoredDisk else { // volume démonté : on le dit au lieu d'afficher le disque de démarrage
            let name = URL(fileURLWithPath: model.settings.monitoredVolume).lastPathComponent
            button.title = "\(name) –"
            setTip(button, L("status.missing", name))
            header?.title = L("status.missing", name)
            return
        }
        let text = L("status.tooltip", disk.name, SizeFormat.text(disk.available))
        button.title = "\(disk.name)  \(SizeFormat.text(disk.available))"
        setTip(button, text)
        header?.title = text
    }

    /// Réaffecter une info-bulle identique la relance : elle restait affichée et suivait le pointeur.
    private func setTip(_ button: NSStatusBarButton, _ text: String) {
        tip = text
        if button.toolTip != text { button.toolTip = text }
    }

    @objc private func showMenu(_ sender: NSStatusBarButton) {
        guard let menu else { return }
        sender.toolTip = nil // pas d'info-bulle par-dessus le menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
        sender.toolTip = tip
    }

    @objc private func openWindow() { open() }
    @objc private func openAbout() { About.show() }
}

/// Surveillance dès l'ouverture de session : agent lancé avec `--monitor`, donc sans fenêtre.
@MainActor
enum LoginAgent {
    private static let service = SMAppService.agent(plistName: "com.stephan.hdcleaner.monitor.plist")

    static var enabled: Bool { service.status == .enabled }

    static func set(_ on: Bool) -> Bool {
        do {
            if on { try service.register() } else { try service.unregister() }
            return true
        } catch {
            Log.app.error("Agent de connexion : \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
