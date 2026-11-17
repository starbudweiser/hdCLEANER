import Foundation

public struct AppEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let bundleID: String
    public let path: String
    public var size: Int64

    public init(name: String, bundleID: String, path: String, size: Int64 = 0) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.size = size
    }
}

/// Désinstallation : l'appli et les fichiers qu'elle a laissés dans la Bibliothèque.
public enum Uninstaller {
    /// Applis de /Applications et ~/Applications (un niveau de sous-dossier compris, comme Utilitaires), tailles non calculées.
    public static func listApps(dirs: [URL]) -> [AppEntry] {
        let fm = FileManager.default
        var apps: [AppEntry] = []
        func visit(_ dir: URL, depth: Int) {
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                if url.pathExtension == "app" {
                    let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                    let id = info?["CFBundleIdentifier"] as? String ?? ""
                    let named = [info?["CFBundleDisplayName"] as? String, info?["CFBundleName"] as? String].compactMap { $0 }.first { !$0.isEmpty }
                    let name = named ?? url.deletingPathExtension().lastPathComponent
                    apps.append(AppEntry(name: name, bundleID: id, path: url.standardizedFileURL.path))
                } else if depth == 0, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    visit(url, depth: 1)
                }
            }
        }
        dirs.forEach { visit($0, depth: 0) }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Fiche d'une appli choisie à la main (glisser-déposer) ; nil si ce n'est pas une appli que l'on peut désinstaller.
    public static func entry(at url: URL, home: URL) -> AppEntry? {
        let u = url.standardizedFileURL
        guard u.pathExtension == "app", (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              PathGuard.isSafeDroppedApp(u.path, home: home) else { return nil }
        let info = NSDictionary(contentsOf: u.appendingPathComponent("Contents/Info.plist"))
        let id = info?["CFBundleIdentifier"] as? String ?? ""
        guard !id.hasPrefix("com.apple.") else { return nil }
        let named = [info?["CFBundleDisplayName"] as? String, info?["CFBundleName"] as? String].compactMap { $0 }.first { !$0.isEmpty }
        return AppEntry(name: named ?? u.deletingPathExtension().lastPathComponent, bundleID: id, path: u.path, size: DiskSize.bytes(of: u))
    }

    /// Chemins que l'appli a pu laisser dans la Bibliothèque ; ceux qui n'existent pas sont écartés par l'appelant.
    static func candidates(bundleID: String, name: String, home: URL) -> [URL] {
        let fm = FileManager.default
        let lib = home.appendingPathComponent("Library")
        var urls: [URL] = []
        func add(_ relative: String) { urls.append(lib.appendingPathComponent(relative)) }
        func children(_ relative: String, where match: (String) -> Bool) {
            for url in (try? fm.contentsOfDirectory(at: lib.appendingPathComponent(relative), includingPropertiesForKeys: nil)) ?? [] where match(url.lastPathComponent) {
                urls.append(url)
            }
        }
        let id = bundleID
        if !id.isEmpty {
            for folder in ["Application Support", "Caches", "Containers", "HTTPStorages", "WebKit", "Application Scripts"] { add("\(folder)/\(id)") }
            add("Preferences/\(id).plist")
            add("Saved Application State/\(id).savedState")
            add("Cookies/\(id).binarycookies")
            add("Logs/\(id)")
            children("Preferences") { $0.hasPrefix(id + ".") && $0.hasSuffix(".plist") }
            // Préférences préfixées par l'identifiant d'équipe : « TEAMID1234.com.x.y.plist ».
            children("Preferences") { $0.hasSuffix(".plist") && Scanner.bundleName(fromContainer: String($0.dropLast(".plist".count))) == id && !$0.hasPrefix(id) }
            children("Preferences/ByHost") { $0.hasPrefix(id + ".") }
            children("LaunchAgents") { $0.hasPrefix(id) && $0.hasSuffix(".plist") }
            children("Group Containers") { Scanner.bundleName(fromContainer: $0) == id || $0.hasSuffix("." + id) }
        }
        // Un nom trop court (« Mail », « Notes ») se confond avec d'autres dossiers : on ne s'y fie qu'à partir de 5 lettres.
        if name.count >= 5 {
            for folder in ["Application Support", "Caches", "Logs"] { add("\(folder)/\(name)") }
        }
        return urls
    }

    /// Agents et services de démarrage de l'appli (son identifiant, ses applis associées ou un programme dans son paquet),
    /// où qu'ils soient, et les assistants privilégiés qu'ils lancent.
    static func launchCandidates(for app: AppEntry, home: URL, systemRoot: URL) -> (user: [URL], system: [URL]) {
        let id = app.bundleID.lowercased()
        func belongs(_ item: LaunchItem) -> Bool {
            let file = URL(fileURLWithPath: item.plist).lastPathComponent.lowercased()
            if !id.isEmpty, file.hasPrefix(id) || item.label.lowercased().hasPrefix(id) || item.bundleIDs.contains(where: { $0.lowercased() == id }) { return true }
            return item.program?.hasPrefix(app.path + "/") ?? false
        }
        let user = LaunchItem.list(in: home.appendingPathComponent("Library/LaunchAgents")).filter(belongs).map { URL(fileURLWithPath: $0.plist) }
        let lib = systemRoot.appendingPathComponent("Library")
        let daemons = (LaunchItem.list(in: lib.appendingPathComponent("LaunchDaemons")) + LaunchItem.list(in: lib.appendingPathComponent("LaunchAgents"))).filter(belongs)
        var system = daemons.map { URL(fileURLWithPath: $0.plist) }
        let programs = Set(daemons.compactMap(\.program))
        for url in (try? FileManager.default.contentsOfDirectory(at: lib.appendingPathComponent("PrivilegedHelperTools"), includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            if programs.contains(LaunchItems.helperFolder + name) || (!id.isEmpty && name.lowercased().hasPrefix(id)) { system.append(url) }
        }
        if !id.isEmpty { system.append(lib.appendingPathComponent("Application Support/\(app.bundleID)")) }
        return (user, system)
    }

    /// L'appli en premier, puis ses fichiers liés, tous cochables ; ceux de l'utilisateur partent à la Corbeille,
    /// ceux du système (services, assistants privilégiés) sont supprimés avec le mot de passe administrateur après avoir été arrêtés.
    public static func items(for app: AppEntry, home: URL, running: Bool, systemRoot: URL = URL(fileURLWithPath: "/"), cancel: CancelFlag = CancelFlag()) -> [JunkItem] {
        var out = [JunkItem(path: app.path, size: app.size, category: .leftovers, inUse: running)]
        var seen: Set<String> = [app.path]
        let launch = launchCandidates(for: app, home: home, systemRoot: systemRoot)
        for url in candidates(bundleID: app.bundleID, name: app.name, home: home) + launch.user {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path), PathGuard.isSafe(path, home: home) else { continue }
            seen.insert(path)
            let bytes = DiskSize.bytes(of: url, cancel: cancel)
            out.append(JunkItem(path: path, size: bytes, category: .leftovers, inUse: running))
        }
        for url in launch.system {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path), PathGuard.isSafeAdmin(path, home: home, root: systemRoot) else { continue }
            seen.insert(path)
            out.append(JunkItem(path: path, size: DiskSize.bytes(of: url, cancel: cancel), category: .leftovers, inUse: running, admin: true))
        }
        return out
    }
}
