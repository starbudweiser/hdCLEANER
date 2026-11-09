#if HDCLEANER_SELFTEST
import AppKit
import HdCleanerCore
import SwiftUI

/// Essais sans fenêtre : `hdCLEANER --selftest library|e2e|trash|render <dossier>`. Absent des builds normaux.
@MainActor
enum SelfTest {
    static func runIfRequested(_ args: [String]) -> Bool {
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return false }
        let path = i + 2 < args.count ? args[i + 2] : ""
        switch args[i + 1] {
        case "library": library()
        case "e2e": endToEnd(URL(fileURLWithPath: path))
        case "trash": trash(URL(fileURLWithPath: path))
        case "apps": apps(path)
        case "watch": watch(URL(fileURLWithPath: path))
        case "repair": repair(URL(fileURLWithPath: path))
        case "maint": maint(path)
        case "exclude": exclude(URL(fileURLWithPath: path))
        case "render": render(to: URL(fileURLWithPath: path))
        case "security": security(URL(fileURLWithPath: path))
        case "securitywatch": securityWatch(URL(fileURLWithPath: path))
        case "tools": tools(to: URL(fileURLWithPath: path), only: i + 3 < args.count ? args[i + 3] : "")
        default: Swift.print("commande inconnue")
        }
        return true
    }

    /// Analyse d'un dossier avec le moteur embarqué (yara du paquet), isolement des menaces, restauration.
    private static func security(_ dir: URL) {
        let model = SecurityModel(home: AppModel.defaultHome)
        guard let config = model.config else { Swift.print("moteur introuvable dans le paquet"); return }
        let found = YaraEngine.scan([dir.path], config: config)
        Swift.print("moteur OK, règles : \(config.ruleFiles.map(\.lastPathComponent)), menaces : \(found.count)")
        for d in found { Swift.print("  \(d.rule)  \(d.path)") }
        Swift.print("base : \(YaraEngine.signatureInfo())")
    }

    /// Temps réel : un élément de démarrage suspect déposé dans ~/Library/LaunchAgents d'un faux dossier personnel est isolé tout seul.
    private static func securityWatch(_ home: URL) {
        _ = NSApplication.shared
        let fm = FileManager.default
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try? fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let model = MainActor.assumeIsolated { SecurityModel(home: home) }
        nonisolated(unsafe) var notified: [String] = []
        MainActor.assumeIsolated {
            model.onThreat = { name, isolated in notified.append("\(name) isolé=\(isolated)") }
            model.start(realtime: true)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        try? "<plist><dict><key>Label</key><string>x.evil</string><key>ProgramArguments</key><array><string>/private/tmp/payload</string></array></dict></plist>".write(to: agents.appendingPathComponent("evil.plist"), atomically: true, encoding: .utf8)
        try? "<plist><dict><key>ProgramArguments</key><array><string>/Applications/Foo.app/Contents/MacOS/foo</string></array></dict></plist>".write(to: agents.appendingPathComponent("fine.plist"), atomically: true, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        Swift.print("evil.plist", fm.fileExists(atPath: agents.appendingPathComponent("evil.plist").path) ? "reste" : "mis en quarantaine")
        Swift.print("fine.plist", fm.fileExists(atPath: agents.appendingPathComponent("fine.plist").path) ? "reste (normal)" : "déplacé (anormal)")
        Swift.print("notifications :", notified, "| quarantaine :", Quarantine.list(home: home).count)
    }

    private static func wait(_ model: AppModel) {
        let end = Date().addingTimeInterval(120)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        while model.busy && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private static func wait(_ model: InvisiblesModel) {
        let end = Date().addingTimeInterval(60)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        while model.busy && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    private static func show(_ r: ScanResult) {
        for c in JunkCategory.allCases where r.items[c] != nil || r.denied.contains(c) {
            Swift.print(c.rawValue, SizeFormat.text(r.total(c)), r.items[c]?.count ?? 0, r.denied.contains(c) ? "REFUSÉ" : "")
        }
    }

    /// Analyse réelle en lecture seule, limitée à ~/Library pour ne déclencher aucune demande d'autorisation.
    private static func library() {
        _ = NSApplication.shared
        let real = FileManager.default.homeDirectoryForCurrentUser
        let view = FileManager.default.temporaryDirectory.appendingPathComponent("hdcleaner-view-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: view, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: view.appendingPathComponent("Library"), withDestinationURL: real.appendingPathComponent("Library"))
        defer { try? FileManager.default.removeItem(at: view) }
        let c = ScanContext.live(home: view, settings: AppSettings(), running: ScanContext.runningNames())
        let start = Date()
        let r = Scanner.scan(c)
        show(r)
        Swift.print("applis :", c.installed.count, "durée :", String(format: "%.1f s", Date().timeIntervalSince(start)))
        for item in (r.items[.leftovers] ?? []).prefix(12) { Swift.print(" reste :", item.name, SizeFormat.text(item.size)) }
    }

    /// Exclusion par le modèle (suite de préférences jetable, jamais celles de l'utilisateur) : la ligne disparaît, reste exclue après une nouvelle analyse et au relancement.
    private static func exclude(_ home: URL) {
        _ = NSApplication.shared
        let suite = "com.stephan.hdcleaner.selftest"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(home: home, defaults: defaults)
        func scan() { model.scan(); wait(model) }
        scan()
        guard let item = model.result?.all.first else { Swift.print("rien à exclure"); return }
        model.exclude(item)
        Swift.print("exclu :", item.path, "| dans les réglages :", model.settings.excludedPaths.contains(item.path))
        scan()
        Swift.print("revient après analyse :", model.result?.all.contains { $0.path == item.path } ?? false)
        Swift.print("après relancement :", AppModel(home: home, defaults: defaults).settings.excludedPaths.contains(item.path))
    }

    /// Diagnostic puis réparation des accès d'un dossier d'essai, par le modèle de l'appli (sans mot de passe).
    private static func repair(_ dir: URL) {
        _ = NSApplication.shared
        let model = PermissionsModel()
        func settle() {
            let end = Date().addingTimeInterval(60)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            while (model.diagnosing || model.running) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        func show(_ d: AccessDiagnosis?) { Swift.print(d.map { "examinés \($0.examined) · autre propriétaire \($0.notOwned) · verrouillés \($0.locked) · inutilisables \($0.notUsable) · à réparer \($0.problems)" } ?? "aucun diagnostic") }
        model.add([dir.path])
        model.diagnose(); settle()
        Swift.print("avant :", terminator: " "); show(model.diagnosis)
        Swift.print("plan :", model.repairPlan.issues(home: FileManager.default.homeDirectoryForCurrentUser))
        model.repair(admin: false); settle()
        Swift.print("après :", terminator: " "); show(model.diagnosis)
        Swift.print("réparé :", model.repaired, "| mot de passe requis :", model.needsAdminRetry)
    }

    /// Surveillance FSEvents sur un dossier d'essai : un .DS_Store, un ._ et un __MACOSX créés après le départ disparaissent, le reste reste.
    private static func watch(_ dir: URL) {
        _ = NSApplication.shared
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let watcher = InvisibleWatcher()
        nonisolated(unsafe) var removed: [String] = []
        watcher.onRemoved = { removed += $0 }
        watcher.update(paths: [dir.path])
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        for name in ["sub/.DS_Store", "sub/._photo.jpg", "sub/photo.jpg", ".Trashes/x"] {
            let url = dir.appendingPathComponent(name)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(count: 1000))
        }
        try? fm.createDirectory(at: dir.appendingPathComponent("__MACOSX/inner"), withIntermediateDirectories: true)
        fm.createFile(atPath: dir.appendingPathComponent("__MACOSX/inner/._p").path, contents: Data(count: 10))
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        watcher.stop()
        for name in ["sub/.DS_Store", "sub/._photo.jpg", "__MACOSX", "sub/photo.jpg", ".Trashes"] {
            Swift.print(fm.fileExists(atPath: dir.appendingPathComponent(name).path) ? "reste  " : "supprimé", name)
        }
        Swift.print("signalés :", removed.map { ($0 as NSString).lastPathComponent }.sorted())
    }

    /// Une tâche d'entretien sans mot de passe, par l'exécuteur de l'appli (sortie en direct, code de sortie).
    private static func maint(_ id: String) {
        guard let task = MaintenanceTask(rawValue: id), !task.needsAdmin else { Swift.print("tâche inconnue ou avec mot de passe"); return }
        let result = ShellJob().run(task.script(uid: getuid())) { Swift.print($0, terminator: "") }
        Swift.print("\ncode :", result.exitCode, "annulé :", result.cancelled)
    }

    /// Applis installées (lecture seule) et, pour celle dont le nom contient l'argument, ses fichiers liés.
    private static func apps(_ query: String) {
        _ = NSApplication.shared
        let home = FileManager.default.homeDirectoryForCurrentUser
        let list = Uninstaller.listApps(dirs: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")])
        Swift.print("applis :", list.count)
        guard var app = list.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else { Swift.print("aucune appli « \(query) »"); return }
        app.size = DiskSize.bytes(of: URL(fileURLWithPath: app.path))
        Swift.print(app.name, app.bundleID, SizeFormat.text(app.size))
        for item in Uninstaller.items(for: app, home: home, running: false) { Swift.print(" ", item.path.replacingOccurrences(of: home.path, with: "~"), SizeFormat.text(item.size)) }
    }

    /// Analyse et nettoyage complets sur un faux dossier personnel.
    private static func endToEnd(_ home: URL) {
        _ = NSApplication.shared
        let model = AppModel(home: home)
        model.scan()
        wait(model)
        guard let r = model.result else { Swift.print("échec"); return }
        show(r)
        Swift.print("cochés :", model.selection.count, "sur", r.all.count)
        model.clean()
        wait(model)
        Swift.print("rapport :", model.report.map { "\($0)" } ?? "?")
    }

    /// Vraie mise à la Corbeille d'un fichier d'essai, retiré aussitôt.
    private static func trash(_ file: URL) {
        var landed: NSURL?
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: &landed)
            Swift.print("corbeille OK :", landed?.path ?? "?")
            if let landed { try FileManager.default.removeItem(at: landed as URL) }
        } catch { Swift.print("échec :", error) }
    }

    private static func save<V: View>(_ view: V, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Doublons, carte et rangement sur le faux dossier HDCLEANER_HOME : `--selftest tools <dossier> [dup|map|org]`.
    private static func tools(to dir: URL, only: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Socle.apply(.dark)
        Socle.brand("hdCLEANER", color: Brand.color)
        let home = ProcessInfo.processInfo.environment["HDCLEANER_HOME"].map { URL(fileURLWithPath: $0) } ?? dir
        let model = AppModel(home: home)
        func pause(_ seconds: Double = 2, until busy: () -> Bool) {
            let end = Date().addingTimeInterval(60 * seconds)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            while busy() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        let size = NSSize(width: 1080, height: 680)
        if only.isEmpty || only == "dup" {
            model.mode = .duplicates
            save(MainView().environmentObject(model), size: size, to: dir.appendingPathComponent("dup-empty.png"))
            Swift.print("dup vide OK")
            model.duplicates.root = home
            model.duplicates.minSize = 1_000
            model.duplicates.startScan(home: home)
            pause { model.duplicates.busy }
            save(MainView().environmentObject(model), size: size, to: dir.appendingPathComponent("dup.png"))
            Swift.print("dup OK", model.duplicates.scan?.groups.count ?? -1)
        }
        if only.isEmpty || only == "map" {
            model.mode = .map
            save(MainView().environmentObject(model), size: size, to: dir.appendingPathComponent("map-empty.png"))
            Swift.print("map vide OK")
            model.diskMap.root = home
            model.diskMap.startScan()
            pause { model.diskMap.busy }
            save(MainView().environmentObject(model), size: size, to: dir.appendingPathComponent("map.png"))
            Swift.print("map OK")
        }
        if only.isEmpty || only == "org" {
            model.mode = .organize
            save(MainView().environmentObject(model), size: size, to: dir.appendingPathComponent("org-empty.png"))
            Swift.print("org vide OK")
            model.organizer.root = home.appendingPathComponent("Downloads")
            model.organizer.startPlan()
            pause { model.organizer.busy }
            save(MainView().environmentObject(model), size: size, to: dir.appendingPathComponent("org.png"))
            Swift.print("org OK", model.organizer.plan?.moves.count ?? -1)
        }
    }

    /// Fenêtre et réglages sur le faux dossier indiqué par HDCLEANER_HOME.
    /// Historique inventé (30 jours de remplissage, deux relevés de dossiers) pour l'écran Chronologie.
    private static func seedTimeline(_ home: URL) {
        let GB: Int64 = 1_000_000_000, now = Date()
        var store = TimelineStore(url: TimelineStore.location(home: home))
        for i in 0..<720 {
            let t = now.addingTimeInterval(-Double(720 - i) * 3600)
            let drift: Int64 = Int64(i) * GB / 12
            let noise: Int64 = Int64(i % 7) * GB / 4
            store.add(sample: SpaceSample(date: t, available: 300 * GB - drift + noise, total: 500 * GB))
        }
        let h = home.path
        store.add(snapshot: SpaceSnapshot(date: now.addingTimeInterval(-30 * 86_400), sizes: [h: 100 * GB, h + "/Library": 40 * GB, h + "/Library/Containers": 10 * GB, h + "/Movies": 30 * GB]))
        store.add(snapshot: SpaceSnapshot(date: now, sizes: [h: 160 * GB, h + "/Library": 80 * GB, h + "/Library/Containers": 48 * GB, h + "/Movies": 51 * GB]))
        store.save()
    }

    private static func render(to dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited) // jamais de fenêtre ni d'icône pendant l'essai
        Socle.apply(.dark)
        Socle.brand("hdCLEANER", color: Brand.color)
        let home = ProcessInfo.processInfo.environment["HDCLEANER_HOME"].map { URL(fileURLWithPath: $0) } ?? dir
        seedTimeline(home)
        let model = AppModel(home: home)
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("welcome.png"))
        model.mode = .timeline
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("timeline.png"))
        model.mode = .security
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("security.png"))
        model.mode = .clean
        model.scan()
        wait(model)
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("main.png"))
        model.mode = .overview
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("overview.png"))
        model.mode = .clean
        for tab in SettingsTab.allCases { // fenêtre des réglages, chaque onglet
            save(SettingsView(tab: tab).environmentObject(model), size: NSSize(width: 520, height: 460), to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        // Splash : image de départ et image d'arrivée
        let splashConfig = Splash.Config(title: "hdCLEANER", accentLetters: 2, subtitle: L("splash.subtitle"), footer: "v1.0.0", iconView: AnyView(DiskMark(on: true, animated: false)), accent: Brand.color)
        save(Splash.previewView(splashConfig, arrived: true), size: Splash.size, to: dir.appendingPathComponent("splash.png"))
        let startConfig = Splash.Config(title: "hdCLEANER", accentLetters: 2, subtitle: L("splash.subtitle"), footer: "v1.0.0", iconView: AnyView(DiskMark(on: false, animated: false)), accent: Brand.color)
        save(DiskMark(on: false, animated: false), size: NSSize(width: 108, height: 108), to: dir.appendingPathComponent("diskmark-start.png"))
        _ = startConfig
        // Outils : entretien, permissions (plan rempli), fichiers invisibles (analyse du faux dossier)
        model.mode = .maintenance
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("maintenance.png"))
        model.mode = .permissions
        model.permissions.add([home.appendingPathComponent("Downloads").path, home.appendingPathComponent("Movies").path])
        model.permissions.fileMode = "644"
        model.permissions.directoryMode = "755"
        model.permissions.flags.hidden = .off
        model.permissions.flags.locked = .off
        model.permissions.clearQuarantine = true
        model.permissions.advanced = true
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("permissions-advanced.png"))
        model.permissions.advanced = false
        model.permissions.diagnose()
        let waitEnd = Date().addingTimeInterval(30)
        while model.permissions.diagnosing && Date() < waitEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("permissions.png"))
        model.mode = .invisibles
        model.invisibles.root = home
        model.invisibles.startScan()
        wait(model.invisibles)
        model.settings.watchedFolders = []
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("invisibles.png"))
        model.mode = .clean
        for tab in SettingsTab.allCases {
            save(SettingsView(tab: tab).environmentObject(model), size: NSSize(width: 480, height: 380), to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        Swift.print("OK", dir.path)
    }
}
#endif
