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
        case "exclude": exclude(URL(fileURLWithPath: path))
        case "render": render(to: URL(fileURLWithPath: path))
        default: Swift.print("commande inconnue")
        }
        return true
    }

    private static func wait(_ model: AppModel) {
        let end = Date().addingTimeInterval(120)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        while model.busy && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
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

    /// Fenêtre et réglages sur le faux dossier indiqué par HDCLEANER_HOME.
    private static func render(to dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited) // jamais de fenêtre ni d'icône pendant l'essai
        Socle.apply(.dark)
        Socle.brand("hdCLEANER", color: Brand.color)
        let home = ProcessInfo.processInfo.environment["HDCLEANER_HOME"].map { URL(fileURLWithPath: $0) } ?? dir
        let model = AppModel(home: home)
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("welcome.png"))
        model.scan()
        wait(model)
        save(MainView().environmentObject(model), size: NSSize(width: 1080, height: 680), to: dir.appendingPathComponent("main.png"))
        for tab in SettingsTab.allCases {
            save(SettingsView(tab: tab).environmentObject(model), size: NSSize(width: 480, height: 380), to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        Swift.print("OK", dir.path)
    }
}
#endif
