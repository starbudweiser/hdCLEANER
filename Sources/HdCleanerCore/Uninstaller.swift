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

    /// L'appli en premier, puis ses fichiers liés, tous cochables ; tout part à la Corbeille.
    public static func items(for app: AppEntry, home: URL, running: Bool, cancel: CancelFlag = CancelFlag()) -> [JunkItem] {
        var out = [JunkItem(path: app.path, size: app.size, category: .leftovers, inUse: running)]
        var seen: Set<String> = [app.path]
        for url in candidates(bundleID: app.bundleID, name: app.name, home: home) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path), PathGuard.isSafe(path, home: home) else { continue }
            seen.insert(path)
            let bytes = DiskSize.bytes(of: url, cancel: cancel)
            out.append(JunkItem(path: path, size: bytes, category: .leftovers, inUse: running))
        }
        return out
    }
}
