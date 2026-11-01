import Foundation

/// Fichiers invisibles que macOS sème dans les dossiers et sur les volumes.
public enum InvisibleKind: String, CaseIterable, Identifiable, Sendable {
    case dsStore, appleDouble, macosxFolder, tempItems, volumeSystem

    public var id: String { rawValue }
    public var title: String { L("invisible.\(rawValue)") }
    public var help: String { L("invisibleHelp.\(rawValue)") }

    /// Les dossiers système d'un volume appartiennent souvent à root : suppression avec le mot de passe.
    public var needsAdmin: Bool { self == .volumeSystem }

    /// Cochés d'office : ce que macOS recrée seul sans dommage. Le reste demande un geste.
    public var preselected: Bool {
        switch self {
        case .dsStore, .appleDouble, .macosxFolder: true
        case .tempItems, .volumeSystem: false
        }
    }

    /// Nettoyé tout seul par la surveillance (jamais ce qui touche à Spotlight, à l'historique ou à la Corbeille d'un volume).
    public var autoCleanable: Bool { preselected }

    static let volumeSystemNames: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", ".DocumentRevisions-V100", ".apdisk", ".com.apple.timemachine.donotpresent"]

    /// Quel fichier invisible est-ce ? `atRoot` : directement à la racine du dossier ou du volume analysé.
    public static func classify(name: String, isDirectory: Bool, atRoot: Bool) -> InvisibleKind? {
        if name == ".DS_Store", !isDirectory { return .dsStore }
        if name == ".AppleDouble", isDirectory { return .appleDouble }
        if name.hasPrefix("._"), name.count > 2, !isDirectory { return .appleDouble }
        if name == "__MACOSX", isDirectory { return .macosxFolder }
        if name == ".TemporaryItems", isDirectory { return .tempItems }
        if atRoot, volumeSystemNames.contains(name) { return .volumeSystem }
        return nil
    }
}

/// Fichiers AppleDouble (« ._nom ») : sur un disque non-Apple, c'est là que macOS range l'icône personnalisée d'un fichier ou d'un dossier.
public enum AppleDouble {
    static let magic: UInt32 = 0x0005_1607
    static let finderInfoEntry: UInt32 = 9
    static let hasCustomIconFlag: UInt16 = 0x0400

    private static func be32(_ d: Data, _ i: Int) -> UInt32 { d[d.startIndex + i..<d.startIndex + i + 4].reduce(0) { $0 << 8 | UInt32($1) } }

    /// Les « Finder Info » portent le drapeau « a une icône personnalisée » (kHasCustomIcon).
    public static func hasCustomIcon(_ data: Data) -> Bool {
        guard data.count >= 26, be32(data, 0) == magic else { return false }
        let entries = Int(data[data.startIndex + 24]) << 8 | Int(data[data.startIndex + 25])
        for i in 0..<min(entries, 32) {
            let at = 26 + i * 12
            guard data.count >= at + 12 else { break }
            guard be32(data, at) == finderInfoEntry else { continue }
            let offset = Int(be32(data, at + 4)), length = Int(be32(data, at + 8))
            guard length >= 10, data.count >= offset + 10 else { return false }
            let flags = UInt16(data[data.startIndex + offset + 8]) << 8 | UInt16(data[data.startIndex + offset + 9])
            return flags & hasCustomIconFlag != 0
        }
        return false
    }

    public static func hasCustomIcon(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return hasCustomIcon((try? handle.read(upToCount: 4096)) ?? Data())
    }
}

extension InvisibleKind {
    /// Ce qui porte une icône personnalisée n'est jamais proposé : le fichier « Icon\r », son double « ._Icon\r », les « ._ » dont les
    /// Finder Info portent le drapeau d'icône personnalisée, et un dossier « .AppleDouble » qui en contient.
    public static func keepsCustomIcon(path: String, isDirectory: Bool) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == "._Icon\r" || name == "Icon\r" { return true }
        if name.hasPrefix("._"), !isDirectory { return AppleDouble.hasCustomIcon(atPath: path) }
        if name == ".AppleDouble", isDirectory {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            return children.contains { AppleDouble.hasCustomIcon(atPath: (path as NSString).appendingPathComponent($0)) }
        }
        return false
    }
}

public struct InvisibleItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let kind: InvisibleKind
    public let isDirectory: Bool

    public init(path: String, size: Int64, kind: InvisibleKind, isDirectory: Bool) {
        self.path = path
        self.size = size
        self.kind = kind
        self.isDirectory = isDirectory
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct InvisibleScan: Sendable {
    public var items: [InvisibleKind: [InvisibleItem]] = [:]
    public var scanned = 0
    public var cancelled = false
    /// Fichiers `._` laissés parce qu'ils portent une icône personnalisée.
    public var keptCustomIcons = 0

    public init() {}

    public func total(_ kind: InvisibleKind) -> Int64 { (items[kind] ?? []).reduce(0) { $0 + $1.size } }
    public var all: [InvisibleItem] { InvisibleKind.allCases.flatMap { items[$0] ?? [] } }
}

public enum InvisibleScanner {
    /// Parcourt `roots` (un volume ou un dossier) sans quitter leur volume ni suivre les liens.
    public static func scan(roots: [URL], cancel: CancelFlag = CancelFlag(), progress: (Int) -> Void = { _ in }) -> InvisibleScan {
        var result = InvisibleScan()
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            TreeWalker.walk(rootPath) { entry in
                if cancel.isCancelled { result.cancelled = true; return .stop }
                result.scanned += 1
                if result.scanned % 2000 == 0 { progress(result.scanned) }
                guard entry.level > 0, !entry.isSymlink else { return .descend }
                let atRoot = (entry.path as NSString).deletingLastPathComponent == rootPath
                guard let kind = InvisibleKind.classify(name: (entry.path as NSString).lastPathComponent, isDirectory: entry.isDirectory, atRoot: atRoot) else { return .descend }
                if kind == .appleDouble, InvisibleKind.keepsCustomIcon(path: entry.path, isDirectory: entry.isDirectory) {
                    result.keptCustomIcons += 1
                    return entry.isDirectory ? .skip : .descend
                }
                let bytes = entry.isDirectory ? DiskSize.bytes(of: URL(fileURLWithPath: entry.path), cancel: cancel) : entry.allocated
                result.items[kind, default: []].append(InvisibleItem(path: entry.path, size: bytes, kind: kind, isDirectory: entry.isDirectory))
                return .skip // un dossier invisible est compté en bloc
            }
            if result.cancelled { break }
        }
        progress(result.scanned)
        result.items = result.items.mapValues { $0.sorted { $0.size > $1.size } }
        return result
    }
}

public enum InvisibleCleaner {
    /// Un élément n'est supprimé que s'il est dans une des racines, porte toujours un nom d'invisible connu et n'est pas la racine elle-même.
    public static func isSafe(_ item: InvisibleItem, roots: [URL]) -> Bool {
        let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
        guard path == item.path else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        for root in roots {
            let base = root.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let atRoot = parent == base
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            guard exists, isDir.boolValue == item.isDirectory, !InvisibleKind.keepsCustomIcon(path: path, isDirectory: item.isDirectory) else { return false }
            return InvisibleKind.classify(name: (path as NSString).lastPathComponent, isDirectory: item.isDirectory, atRoot: atRoot) == item.kind
        }
        return false
    }

    public static func clean(_ items: [InvisibleItem], roots: [URL], cancel: CancelFlag = CancelFlag(), runAdmin: (String) -> Bool = { _ in false },
                             progress: (Double) -> Void = { _ in }) -> CleanReport {
        var report = CleanReport()
        var admin: [InvisibleItem] = []
        for (index, item) in items.enumerated() {
            if cancel.isCancelled { break }
            progress(Double(index) / Double(max(items.count, 1)))
            guard isSafe(item, roots: roots) else {
                report.failures.append(item.path)
                continue
            }
            if item.kind.needsAdmin {
                admin.append(item)
                continue
            }
            do {
                try FileManager.default.removeItem(at: item.url)
                report.freed += item.size
                report.count += 1
            } catch {
                report.failures.append(item.path)
            }
        }
        if !admin.isEmpty, !cancel.isCancelled {
            if runAdmin(AdminScript.build(removing: admin.map(\.path), snapshots: [])) {
                for item in admin {
                    if FileManager.default.fileExists(atPath: item.path) { report.failures.append(item.path) } else {
                        report.freed += item.size
                        report.count += 1
                    }
                }
            } else {
                report.adminCancelled = true
                report.failures += admin.map(\.path)
            }
        }
        progress(1)
        return report
    }

    /// Surveillance : supprime au passage les chemins signalés par le système de fichiers, seulement s'ils sont de la catégorie `autoCleanable`.
    public static func cleanReported(paths: [String], roots: [URL]) -> [String] {
        var removed: [String] = []
        // FSEvents rend les chemins réels (« /private/tmp/… ») ; les racines sont normalisées (« /tmp/… ») : on aligne les deux.
        for path in Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }) {
            let name = (path as NSString).lastPathComponent
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let parent = (path as NSString).deletingLastPathComponent
            let atRoot = roots.contains { $0.standardizedFileURL.path == parent }
            guard let kind = InvisibleKind.classify(name: name, isDirectory: isDir.boolValue, atRoot: atRoot), kind.autoCleanable else { continue }
            let item = InvisibleItem(path: path, size: 0, kind: kind, isDirectory: isDir.boolValue)
            if isSafe(item, roots: roots), (try? FileManager.default.removeItem(atPath: path)) != nil { removed.append(path) }
        }
        return removed.sorted()
    }
}
