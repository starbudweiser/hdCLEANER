import AppKit
import HdCleanerCore
import SwiftUI

// Corrections système : modèle. Chaque correction montre d'abord ce qu'elle va changer, n'agit qu'après un clic, et passe par un garde-fou du cœur.

enum FixTab: String, CaseIterable, Identifiable {
    case openWith, extensions, services, caches, disk, quarantine
    var id: String { rawValue }
    var title: String { L("fix.tab.\(rawValue)") }
}

@MainActor
final class SystemFixesModel: ObservableObject {
    @Published var tab: FixTab = .openWith
    @Published private(set) var busy = false
    @Published var message = ""

    // Ouvrir avec
    @Published private(set) var diagnosis: LSRegistry.Diagnosis?
    @Published var selection = Set<String>()
    @Published private(set) var undoPaths: [String] = []
    // Extensions
    @Published private(set) var extensions: [SystemExtension] = []
    // Services
    @Published private(set) var services: [ServiceEntry] = []
    @Published private(set) var servicesChanged = false
    // Caches
    @Published private(set) var quickLookSize: Int64 = 0
    @Published private(set) var iconSize: Int64 = 0
    // Disque occupé
    @Published private(set) var volumes: [String] = []
    @Published var volume = ""
    @Published private(set) var holders: [OpenProcess]?
    @Published var holderSelection = Set<Int32>()
    // Quarantaine
    @Published private(set) var apps: [String] = []

    private let home: URL
    private var relaunchTask: Task<Void, Never>?
    private static let originalServicesKey = "fixServicesOriginal"
    private static let undoKey = "fixLSUndo"

    init(home: URL) {
        self.home = home
        undoPaths = UserDefaults.standard.stringArray(forKey: Self.undoKey) ?? []
    }

    /// Données d'exemple pour les rendus de contrôle (`--selftest render`) : jamais utilisé par l'appli.
    func seedDemo() {
        typealias F = LSRegistry.Finding
        var d = LSRegistry.Diagnosis()
        func make(_ range: Range<Int>, _ reason: LSRegistry.Reason, _ path: (Int) -> String) -> [F] { range.map { F(path: path($0), reason: reason, bundleID: nil, version: nil, keeping: nil) } }
        d.stale += make(0..<28, .cache) { "/Users/me/Library/Caches/mSLICE-release/1.\($0)/notarized/mSLICE.app" }
        d.stale += make(0..<12, .build) { "/Users/me/Library/Developer/Xcode/DerivedData/App-abc/Build/Products/Debug/A\($0).app" }
        d.stale += make(0..<9, .temporary) { "/private/tmp/x\($0)/T.app" }
        d.stale += make(0..<14, .trash) { "/Users/me/.Trash/Old\($0).app" }
        d.stale += make(0..<310, .missing) { "/Applications/Gone\($0).app" }
        d.duplicates = [F(path: "/Users/me/dev/mHUB/dist/mHUB.app", reason: .duplicate, bundleID: "m.hub", version: "1.5", keeping: "/Applications/mHUB.app"),
                        F(path: "/Users/me/dev/mHUB/build/mHUB.app", reason: .duplicate, bundleID: "m.hub", version: "1.5", keeping: "/Applications/mHUB.app"),
                        F(path: "/Volumes/Backup/Compressor.app", reason: .duplicate, bundleID: "c.comp", version: "5.0", keeping: "/Applications/Compressor.app")]
        d.keptGroups = [("org.python.IDLE", ["/Applications/Python 3.11/IDLE.app", "/Applications/Python 3.12/IDLE.app"])]
        d.droplets = [F(path: "/Users/me/Droplets/Compressor H.264.app", reason: .droplet, bundleID: "d.a", version: nil, keeping: nil),
                      F(path: "/Users/me/Droplets/Compressor ProRes.app", reason: .droplet, bundleID: "d.b", version: nil, keeping: nil)]
        diagnosis = d
        var all = d.stale.map(\.path)
        all += d.duplicates.map(\.path)
        all += d.droplets.map(\.path)
        selection = Set(all)
        func ext(_ id: String, _ name: String, _ path: String, _ kind: ExtensionKind, _ el: Character) -> SystemExtension { SystemExtension(identifier: id, name: name, path: path, kind: kind, elected: el, parentPath: "") }
        extensions = [ext("com.apple.share.AirDrop", "AirDrop", "/System/Library/X.appex", .share, "+"), ext("com.apple.share.System", "Ajouter à la liste de lecture", "/System/Library/Y.appex", .share, "-"),
                      ext("m.slice.finder", "mSLICE Finder (dev)", "/Users/me/DerivedData/Ex.appex", .finder, " "), ext("com.dropbox.ext", "Dropbox", "/Users/me/Gone/D.appex", .finder, "+")]
        services = [ServiceEntry(key: "com.apple.Terminal - New Terminal at Folder - n", title: "Ouvrir dans un nouveau terminal", owner: "com.apple.Terminal", contextMenu: true, servicesMenu: true),
                    ServiceEntry(key: "(null) - Convertir en Hiragana - c", title: "Convertir en Hiragana", owner: "", contextMenu: false, servicesMenu: true)]
        quickLookSize = 312_000_000; iconSize = 84_000_000
        volumes = ["/Volumes/SSD Editing"]; volume = volumes[0]
        holders = [OpenProcess(pid: 412, command: "mdworker_shared", uid: 0, fileCount: 3, sample: ""), OpenProcess(pid: 9031, command: "Adobe Media Encoder", uid: getuid(), fileCount: 12, sample: "")]
        holderSelection = [9031]
        apps = ["/Users/me/Downloads/Exemple.app"]
    }

    // MARK: Exécution

    /// Script sans mot de passe, hors du fil principal.
    @discardableResult
    private func run(_ script: String) async -> ShellResult {
        await Task.detached(priority: .userInitiated) { ShellJob().run(script) { _ in } }.value
    }

    private func capture(_ launch: String, _ args: [String]) async -> String {
        await Task.detached(priority: .userInitiated) {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: launch)
            p.arguments = args
            p.standardOutput = pipe
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    func refresh() {
        switch tab {
        case .openWith: if diagnosis == nil { analyze() }
        case .extensions: loadExtensions()
        case .services: loadServices()
        case .caches: loadCaches()
        case .disk: loadVolumes()
        case .quarantine: break
        }
    }

    // MARK: Ouvrir avec

    func analyze() {
        guard !busy else { return }
        busy = true; message = ""
        let home = home
        Task {
            let dump = await capture(SystemTools.lsregister, ["-dump"])
            let d = await Task.detached(priority: .userInitiated) { LSRegistry.diagnose(paths: LSRegistry.parseDump(dump), context: .live(home: home)) }.value
            diagnosis = d
            selection = Set(d.stale.map(\.path) + d.duplicates.map(\.path) + d.droplets.map(\.path) + d.devBuilds.map(\.path))
            busy = false
        }
    }

    var selectedCount: Int { selection.count }

    func cleanOpenWith() {
        guard !busy, !selection.isEmpty, let d = diagnosis else { return }
        let all = d.stale + d.duplicates + d.droplets + d.devBuilds
        let paths = all.map(\.path).filter { selection.contains($0) }
        busy = true
        Task {
            await run(LSRegistry.unregisterScript(paths))
            undoPaths = paths.filter { FileManager.default.fileExists(atPath: $0) } // ce qui existe encore peut être réenregistré
            UserDefaults.standard.set(undoPaths, forKey: Self.undoKey)
            await run(SystemCaches.relaunchScript.replacingOccurrences(of: "/usr/bin/killall Dock 2>/dev/null\n", with: ""))
            message = L("fix.openWith.done", paths.count)
            busy = false
            diagnosis = nil
            analyze()
        }
    }

    func undoOpenWith() {
        guard !busy, !undoPaths.isEmpty else { return }
        busy = true
        let paths = undoPaths
        Task {
            await run(LSRegistry.reregisterScript(paths))
            undoPaths = []
            UserDefaults.standard.removeObject(forKey: Self.undoKey)
            message = L("fix.openWith.undone", paths.count)
            busy = false
            diagnosis = nil
            analyze()
        }
    }

    /// Range les droplets cochés dans une archive .zip du dossier choisi, puis met l'original à la Corbeille.
    func archiveDroplets(to folder: URL) {
        guard !busy, let d = diagnosis else { return }
        let targets = d.droplets.map(\.path).filter { selection.contains($0) }
        guard !targets.isEmpty else { return }
        busy = true
        let home = home
        Task {
            let archived = await Task.detached(priority: .userInitiated) { () -> [String] in
                var done: [String] = []
                for path in targets where PathGuard.isSafeUserFile(path, home: home) {
                    let name = (path as NSString).lastPathComponent
                    let zip = folder.appendingPathComponent(name + ".zip")
                    guard !FileManager.default.fileExists(atPath: zip.path) else { continue }
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    p.arguments = ["-c", "-k", "--keepParent", path, zip.path]
                    guard (try? p.run()) != nil else { continue }
                    p.waitUntilExit()
                    if p.terminationStatus == 0, FileManager.default.fileExists(atPath: zip.path),
                       (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil { done.append(path) }
                }
                return done
            }.value
            await run(LSRegistry.unregisterScript(archived))
            message = L("fix.droplets.archived", archived.count)
            busy = false
            diagnosis = nil
            analyze()
        }
    }

    // MARK: Extensions

    func loadExtensions() {
        Task {
            let out = await capture("/usr/bin/pluginkit", ["-mAvv"])
            extensions = PluginKit.parse(out).sorted { ($0.kind.rawValue, $0.name.lowercased()) < ($1.kind.rawValue, $1.name.lowercased()) }
        }
    }

    func setExtension(_ ext: SystemExtension, enabled: Bool) {
        guard let script = PluginKit.setScript(identifier: ext.identifier, enabled: enabled) else { return }
        Task { await run(script); loadExtensions() }
    }

    func removeExtension(_ ext: SystemExtension) {
        guard let script = PluginKit.removeScript(path: ext.path) else { return }
        Task { await run(script); message = L("fix.ext.removed", ext.name); loadExtensions() }
    }

    func enableAllExtensions() {
        let scripts = extensions.filter { !$0.enabled }.compactMap { PluginKit.setScript(identifier: $0.identifier, enabled: true) }
        guard !scripts.isEmpty else { return }
        Task { await run(scripts.joined()); loadExtensions() }
    }

    // MARK: Services

    func loadServices() {
        let discovered = ServicesPrefs.discoverKeys(in: ["/System/Library/Services", "/Library/Services", home.path + "/Library/Services", "/Applications/Utilities"])
        let status = ServicesPrefs.readStatus()
        if UserDefaults.standard.data(forKey: Self.originalServicesKey) == nil, let data = try? JSONEncoder().encode(status) {
            UserDefaults.standard.set(data, forKey: Self.originalServicesKey) // réglage d'origine, pris une seule fois
        }
        services = ServicesPrefs.entries(status: status, discovered: discovered)
    }

    func setService(_ entry: ServiceEntry, contextMenu: Bool) {
        ServicesPrefs.writeStatus(ServicesPrefs.setting(ServicesPrefs.readStatus(), key: entry.key, context: contextMenu, menu: nil))
        servicesChanged = true
        loadServices()
        scheduleFinderRelaunch()
    }

    func restoreServices() {
        guard let data = UserDefaults.standard.data(forKey: Self.originalServicesKey), let original = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) else { return }
        ServicesPrefs.writeStatus(original)
        loadServices()
        scheduleFinderRelaunch()
        message = L("fix.services.restored")
    }

    /// Une seule relance du Finder, un peu après le dernier changement.
    private func scheduleFinderRelaunch() {
        relaunchTask?.cancel()
        relaunchTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await run("#!/bin/sh\n\(SystemTools.pbs) -flush 2>/dev/null\n\(SystemTools.pbs) -update 2>/dev/null\n/usr/bin/killall Finder 2>/dev/null\nexit 0\n")
            servicesChanged = false
        }
    }

    // MARK: Caches

    func loadCaches() {
        Task {
            let (ql, icons) = await Task.detached(priority: .utility) { () -> (Int64, Int64) in
                let dir = SystemCaches.userCacheDir()
                return (SystemCaches.size(of: SystemCaches.quickLookPaths(cacheDir: dir)), SystemCaches.size(of: SystemCaches.iconPaths(cacheDir: dir)))
            }.value
            quickLookSize = ql; iconSize = icons
        }
    }

    func clearQuickLook() {
        guard !busy else { return }
        busy = true
        Task {
            let dir = await Task.detached { SystemCaches.userCacheDir() }.value
            await run(SystemCaches.quickLookResetScript)
            await run(SystemCaches.clearScript(paths: SystemCaches.quickLookPaths(cacheDir: dir), cacheDir: dir))
            message = L("fix.caches.quicklookDone")
            busy = false; loadCaches()
        }
    }

    func clearIcons() {
        guard !busy else { return }
        busy = true
        Task {
            let dir = await Task.detached { SystemCaches.userCacheDir() }.value
            await run(SystemCaches.clearScript(paths: SystemCaches.iconPaths(cacheDir: dir), cacheDir: dir) + SystemCaches.relaunchScript.replacingOccurrences(of: "#!/bin/sh\n", with: ""))
            message = L("fix.caches.iconsDone")
            busy = false; loadCaches()
        }
    }

    func relaunchFinderAndDock() {
        guard !busy else { return }
        Task { await run(SystemCaches.relaunchScript); message = L("fix.caches.relaunched") }
    }

    // MARK: Disque occupé

    func loadVolumes() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        volumes = names.map { "/Volumes/" + $0 }.filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != "/" }.sorted()
        if !volumes.contains(volume) { volume = volumes.first ?? "" }
    }

    func searchHolders() {
        guard !busy, OpenFiles.isVolume(volume) else { return }
        busy = true
        let volume = volume
        Task {
            let out = await capture("/usr/sbin/lsof", ["-F", "pcun", "--", volume])
            let list = OpenFiles.parse(out)
            holders = list
            holderSelection = Set(list.filter { $0.canQuit(me: getuid()) }.map(\.pid))
            busy = false
        }
    }

    func quitSelectedHolders() {
        guard let list = holders else { return }
        let me = getuid()
        let targets = list.filter { holderSelection.contains($0.pid) && $0.canQuit(me: me) }
        for p in targets { kill(p.pid, SIGTERM) }
        message = L("fix.disk.quit", targets.count)
        Task { try? await Task.sleep(nanoseconds: 1_000_000_000); searchHolders() }
    }

    // MARK: Quarantaine

    func addApps(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            guard QuarantineFix.isAllowed(path, home: home), !apps.contains(path) else { message = L("fix.quarantine.refused", url.lastPathComponent); continue }
            apps.append(path)
        }
    }

    func liftQuarantine(_ path: String) {
        guard QuarantineFix.isAllowed(path, home: home) else { return }
        Task {
            await run(QuarantineFix.script(path))
            message = QuarantineFix.hasQuarantine(path) ? L("fix.quarantine.failed", (path as NSString).lastPathComponent) : L("fix.quarantine.done", (path as NSString).lastPathComponent)
            apps = apps.map { $0 } // rafraîchit la ligne
        }
    }
}
