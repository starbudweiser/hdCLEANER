import Foundation

/// Ce que l'analyse doit savoir de la machine ; fourni par l'appli, simulé par les tests.
public struct ScanContext: Sendable {
    public var home: URL
    public var largeFileMinimum: Int64 = 500_000_000
    public var excluded: Set<String> = []
    /// Identifiants et noms (en minuscules) des applis ouvertes.
    public var running: Set<String> = []
    /// Identifiants des applis présentes ; complété par `isRegistered` (LaunchServices).
    public var installed: Set<String> = []
    public var isRegistered: @Sendable (String) -> Bool = { _ in false }
    public var screenshotFolder: URL?

    public init(home: URL) { self.home = home }
}

public enum Scanner {
    /// Ordre d'attribution : chaque chemin n'appartient qu'à la première catégorie qui le réclame.
    static let order: [JunkCategory] = [
        .trash, .browserData, .devCaches, .leftovers, .appCaches, .appLogs, .iosBackups, .iosPhotoCache, .musicCache, .iosUpdates,
        .mailDownloads, .installers, .screenshots, .downloads, .largeFiles,
    ]

    /// Caches de navigateurs seulement : jamais historique, cookies ni mots de passe.
    static let browsers: [(path: String, bundleID: String)] = [
        ("Library/Caches/com.apple.Safari", "com.apple.safari"),
        ("Library/Caches/Google/Chrome", "com.google.chrome"),
        ("Library/Caches/Firefox", "org.mozilla.firefox"),
        ("Library/Caches/Microsoft Edge", "com.microsoft.edgemac"),
        ("Library/Caches/BraveSoftware", "com.brave.browser"),
        ("Library/Caches/company.thebrowser.Browser", "company.thebrowser.browser"),
        ("Library/Caches/com.operasoftware.Opera", "com.operasoftware.opera"),
        ("Library/Caches/Vivaldi", "com.vivaldi.vivaldi"),
    ]

    static let devPaths: [(path: String, bundleID: String?)] = [
        ("Library/Developer/Xcode/DerivedData", "com.apple.dt.xcode"),
        ("Library/Developer/Xcode/iOS DeviceSupport", "com.apple.dt.xcode"),
        ("Library/Developer/Xcode/macOS DeviceSupport", "com.apple.dt.xcode"),
        ("Library/Developer/CoreSimulator/Caches", "com.apple.dt.xcode"),
        ("Library/Caches/Homebrew", nil),
        ("Library/Caches/pip", nil),
        ("Library/Caches/Yarn", nil),
        ("Library/Caches/CocoaPods", nil),
        ("Library/Caches/org.swift.swiftpm", nil),
        (".npm/_cacache", nil),
    ]

    /// Caches coûteux à refaire ou qui ne sont pas de vrais caches : jamais proposés.
    static let protectedCaches: Set<String> = ["ms-playwright", "huggingface", "torch", "whisper", "CloudKit", "FamilyCircle", "Google"]
    static let ignoredNames: Set<String> = [".DS_Store", ".localized", "Icon\r"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    static let screenshotExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
    static let screenshotPrefixes = ["capture d’écran", "capture d'écran", "screenshot", "screen shot", "captura de pantalla", "istantanea schermo", "bildschirmfoto"]
    static let vendorRoots: Set<String> = ["com", "org", "net", "io", "app", "co", "dev", "de", "fr", "uk", "jp", "ai", "me", "tv", "us"]

    public static func scan(_ context: ScanContext, cancel: CancelFlag = CancelFlag(), progress: @Sendable (JunkCategory, Double) -> Void = { _, _ in }) -> ScanResult {
        var walk = Walk(context: context, cancel: cancel)
        for (index, category) in order.enumerated() {
            if cancel.isCancelled { break }
            progress(category, Double(index) / Double(order.count))
            walk.run(category)
        }
        walk.result.items = walk.result.items.mapValues { $0.sorted { $0.size > $1.size } }
        return walk.result
    }

    /// Dossier à l'identifiant d'une appli disparue ? Prudent : le moindre lien avec une appli présente (même éditeur) l'écarte.
    public static func isLeftover(_ name: String, context: ScanContext, vendors: Set<String>) -> Bool {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count >= 3, name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return false }
        guard vendorRoots.contains(parts[0]), parts[1] != "apple" else { return false }
        if vendors.contains(parts[0...1].joined(separator: ".").lowercased()) { return false }
        for count in stride(from: parts.count, through: 2, by: -1) {
            let id = parts[0..<count].joined(separator: ".")
            if context.installed.contains(id.lowercased()) || context.running.contains(id.lowercased()) || context.isRegistered(id) { return false }
        }
        return true
    }
}

private struct Walk {
    let context: ScanContext
    let cancel: CancelFlag
    var result = ScanResult()
    var claimed = Set<String>()
    let fm = FileManager.default

    init(context: ScanContext, cancel: CancelFlag) {
        self.context = context
        self.cancel = cancel
    }

    private func at(_ relative: String) -> URL { context.home.appendingPathComponent(relative) }

    /// Contenu d'un dossier ; nil s'il est absent ou interdit, et dans ce cas la catégorie est signalée.
    private mutating func children(_ dir: URL, for category: JunkCategory) -> [URL]? {
        do {
            return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { !Scanner.ignoredNames.contains($0.lastPathComponent) }
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            result.denied.insert(category)
            return nil
        } catch {
            return nil
        }
    }

    private func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        func bytes(_ v: URLResourceValues) -> Int64 { Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        if values.isSymbolicLink == true || values.isDirectory != true { return bytes(values) }
        var total: Int64 = 0
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let child as URL in walker {
            if cancel.isCancelled { break }
            if let v = try? child.resourceValues(forKeys: keys), v.isDirectory != true { total += bytes(v) }
        }
        return total
    }

    private func running(_ names: String...) -> Bool {
        names.contains { context.running.contains($0.lowercased()) }
    }

    private mutating func add(_ url: URL, _ category: JunkCategory, inUse: Bool = false, knownSize: Int64? = nil) {
        let path = url.standardizedFileURL.path
        guard !cancel.isCancelled, !claimed.contains(path), !context.excluded.contains(path) else { return }
        let bytes = knownSize ?? size(of: url)
        guard bytes > 0 else { return }
        claimed.insert(path)
        result.items[category, default: []].append(JunkItem(path: path, size: bytes, category: category, inUse: inUse))
    }

    mutating func run(_ category: JunkCategory) {
        switch category {
        case .trash: addChildren(at(".Trash"), category)
        case .browserData: Scanner.browsers.forEach { add(at($0.path), category, inUse: running($0.bundleID)) }
        case .devCaches: Scanner.devPaths.forEach { add(at($0.path), category, inUse: $0.bundleID.map { running($0) } ?? false) }
        case .leftovers: leftovers()
        case .appCaches: appFolder("Library/Caches", category)
        case .appLogs: appFolder("Library/Logs", category)
        case .iosBackups: addChildren(at("Library/Application Support/MobileSync/Backup"), category)
        case .iosPhotoCache:
            add(at("Pictures/iPod Photo Cache"), category)
            add(at("Pictures/iPhoto Library/iPod Photo Cache"), category)
        case .musicCache:
            add(at("Library/Caches/com.apple.Music"), category, inUse: running("com.apple.music"))
            add(at("Library/Caches/com.apple.iTunes"), category, inUse: running("com.apple.itunes"))
        case .iosUpdates:
            addChildren(at("Library/iTunes/iPhone Software Updates"), category)
            addChildren(at("Library/iTunes/iPad Software Updates"), category)
        case .mailDownloads: addChildren(at("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"), category)
        case .installers: installers()
        case .screenshots: screenshots()
        case .downloads: addChildren(at("Downloads"), category)
        case .largeFiles: largeFiles()
        }
    }

    private mutating func addChildren(_ dir: URL, _ category: JunkCategory) {
        children(dir, for: category)?.forEach { add($0, category) }
    }

    /// Dossiers par appli : ni Apple, ni navigateurs (catégorie à part), ni caches protégés.
    private mutating func appFolder(_ relative: String, _ category: JunkCategory) {
        let known = Set(Scanner.browsers.map(\.path) + Scanner.devPaths.map(\.path)).map { ($0 as NSString).lastPathComponent }
        for url in children(at(relative), for: category) ?? [] {
            let name = url.lastPathComponent
            if name.hasPrefix("com.apple.") || Scanner.protectedCaches.contains(name) || known.contains(name) { continue }
            let lower = name.lowercased()
            add(url, category, inUse: context.running.contains(lower))
        }
    }

    private mutating func leftovers() {
        let vendors = Set((context.installed.union(context.running)).compactMap { id -> String? in
            let parts = id.split(separator: ".")
            return parts.count >= 3 ? parts[0...1].joined(separator: ".") : nil
        })
        let roots = ["Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Saved Application State", "Library/Logs", "Library/HTTPStorages", "Library/WebKit", "Library/Cookies"]
        for root in roots {
            for url in children(at(root), for: .leftovers) ?? [] {
                var name = url.lastPathComponent
                for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
                if Scanner.isLeftover(name, context: context, vendors: vendors) { add(url, .leftovers) }
            }
        }
    }

    private mutating func installers() {
        for root in ["Downloads", "Desktop", "Documents"] {
            guard children(at(root), for: .installers) != nil,
                  let walker = fm.enumerator(at: at(root), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in true })
            else { continue }
            for case let url as URL in walker {
                if cancel.isCancelled { return }
                if walker.level >= 3 { walker.skipDescendants() }
                if Scanner.installerExtensions.contains(url.pathExtension.lowercased()) { add(url, .installers); walker.skipDescendants() }
            }
        }
    }

    private mutating func screenshots() {
        let folders = [at("Desktop"), at("Pictures/Screenshots")] + (context.screenshotFolder.map { [$0] } ?? [])
        for folder in Set(folders.map(\.standardizedFileURL)) {
            for url in children(folder, for: .screenshots) ?? [] {
                let name = url.lastPathComponent.lowercased()
                if Scanner.screenshotExtensions.contains(url.pathExtension.lowercased()), Scanner.screenshotPrefixes.contains(where: name.hasPrefix) {
                    add(url, .screenshots)
                }
            }
        }
    }

    private mutating func largeFiles() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let walker = fm.enumerator(at: context.home, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in true }) else { return }
        for case let url as URL in walker {
            if cancel.isCancelled { return }
            if walker.level == 1, ["Library", "Downloads", "Applications"].contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if url.lastPathComponent == "node_modules" { walker.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let bytes = Int64(v.totalFileAllocatedSize ?? 0)
            if bytes >= context.largeFileMinimum { add(url, .largeFiles, knownSize: bytes) }
        }
    }
}
