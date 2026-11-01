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
        var c = ScanContext(home: view)
        c.installed = InstalledApps.bundleIDs()
        c.isRegistered = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        let start = Date()
        let r = Scanner.scan(c)
        show(r)
        Swift.print("applis :", c.installed.count, "durée :", String(format: "%.1f s", Date().timeIntervalSince(start)))
        for item in (r.items[.leftovers] ?? []).prefix(12) { Swift.print(" reste :", item.name, SizeFormat.text(item.size)) }
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
            save(SettingsView(tab: tab).environmentObject(model), size: NSSize(width: 480, height: 340), to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        Swift.print("OK", dir.path)
    }
}
#endif
