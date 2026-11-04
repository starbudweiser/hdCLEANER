import Foundation

public struct CleanReport: Sendable, Equatable {
    /// Octets réellement rendus au disque.
    public var freed: Int64 = 0
    /// Octets partis à la Corbeille : rendus seulement quand elle sera vidée.
    public var trashed: Int64 = 0
    public var count = 0
    public var failures: [String] = []
    /// Le mot de passe administrateur a été refusé : les éléments système n'ont pas été traités.
    public var adminCancelled = false

    public init() {}
}

/// Dernier rempart avant toute suppression : quoi que dise l'analyse, rien hors des emplacements prévus.
public enum PathGuard {
    static let protected: Set<String> = [
        "Library", "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences", "Library/Containers",
        "Library/Developer", "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies", "Applications", ".Trash",
    ]
    static let forbiddenPrefixes = ["Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail/", ".ssh", ".gnupg"]
    static let systemLogFolders: Set<String> = ["DiagnosticReports", "CrashReporter"]

    /// Fichier ou dossier du dossier personnel, jamais un dossier racine.
    public static func isSafe(_ path: String, home: URL) -> Bool {
        let base = home.standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard target == path, target.hasPrefix(base + "/") else { return false }
        let relative = String(target.dropFirst(base.count + 1))
        guard relative.contains("/"), !protected.contains(relative) else { return false }
        return !forbiddenPrefixes.contains { relative == $0 || relative.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Une appli entière, directement dans /Applications ou ~/Applications (désinstallation).
    public static func isSafeAppBundle(_ path: String, home: URL, root: URL = URL(fileURLWithPath: "/")) -> Bool {
        guard URL(fileURLWithPath: path).standardizedFileURL.path == path else { return false }
        return [prefix(root) + "/Applications", home.standardizedFileURL.path + "/Applications"].contains {
            relative(path, to: $0).map { !$0.contains("/") && $0.hasSuffix(".app") && $0 != ".app" } ?? false
        }
    }

    /// Une appli déposée par l'utilisateur, hors des dossiers Applications : dossier personnel, /Applications (sous-dossiers compris) ou disque monté.
    /// Jamais le système, ni une appli à l'intérieur d'une autre appli.
    public static func isSafeDroppedApp(_ path: String, home: URL, root: URL = URL(fileURLWithPath: "/"), volumesRoot: String = "/Volumes") -> Bool {
        guard URL(fileURLWithPath: path).standardizedFileURL.path == path, path.hasSuffix(".app"), URL(fileURLWithPath: path).lastPathComponent != ".app" else { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard !parent.contains(".app/"), !parent.hasSuffix(".app") else { return false }
        if relative(path, to: prefix(root) + "/Applications") != nil { return true }
        return isSafeUserFile(path, home: home, volumesRoot: volumesRoot)
    }

    /// Emplacements système où la suppression avec mot de passe est permise.
    public static func isSafeAdmin(_ path: String, home: URL, root: URL = URL(fileURLWithPath: "/")) -> Bool {
        guard URL(fileURLWithPath: path).standardizedFileURL.path == path else { return false }
        let r = prefix(root)
        if let rel = relative(path, to: r + "/Library/Caches") { return !rel.hasPrefix("com.apple.") }
        if let rel = relative(path, to: r + "/Library/Logs") { return !systemLogFolders.contains(rel) }
        if let rel = relative(path, to: r + "/var/log") { return !rel.contains("/") && Scanner.isRotatedLog(rel) }
        for apps in [r + "/Applications", home.standardizedFileURL.path + "/Applications"] {
            guard let rel = relative(path, to: apps) else { continue }
            if !rel.contains("/"), rel.hasPrefix("Install "), rel.hasSuffix(".app") { return true }
            let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 4, parts[0].hasSuffix(".app"), parts[1] == "Contents", parts[2] == "Resources", parts[3].hasSuffix(".lproj") { return true }
        }
        return false
    }

    private static func prefix(_ root: URL) -> String {
        let p = root.standardizedFileURL.path
        return p == "/" ? "" : p
    }

    /// Chemin sous `base` (au moins un niveau) ; nil s'il n'est pas dedans.
    private static func relative(_ path: String, to base: String) -> String? {
        guard path.hasPrefix(base + "/"), path.count > base.count + 1 else { return nil }
        return String(path.dropFirst(base.count + 1))
    }
}

public enum Cleaner {
    /// `runAdmin` exécute le script avec le mot de passe administrateur et dit si la demande a abouti.
    public static func clean(_ items: [JunkItem], home: URL, systemRoot: URL = URL(fileURLWithPath: "/"), cancel: CancelFlag = CancelFlag(),
                             toTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                             runAdmin: (String) -> Bool = { _ in false },
                             progress: (Double) -> Void = { _ in }) -> CleanReport {
        var report = CleanReport()
        var admin: [JunkItem] = []
        for (index, item) in items.enumerated() {
            if cancel.isCancelled { break }
            progress(Double(index) / Double(max(items.count, 1)))
            switch item.disposal {
            case .delete, .trash:
                let allowed = PathGuard.isSafe(item.path, home: home) || (item.disposal == .trash && (PathGuard.isSafeAppBundle(item.path, home: home, root: systemRoot) || PathGuard.isSafeDroppedApp(item.path, home: home, root: systemRoot)))
                guard allowed else {
                    report.failures.append(item.path)
                    continue
                }
                do {
                    if item.disposal == .delete {
                        try FileManager.default.removeItem(at: item.url)
                        report.freed += item.size
                    } else {
                        try toTrash(item.url)
                        report.trashed += item.size
                    }
                    report.count += 1
                } catch {
                    // Une appli qu'on ne peut pas mettre à la Corbeille (propriété de root) passe par le mot de passe.
                    if item.disposal == .trash, PathGuard.isSafeAppBundle(item.path, home: home, root: systemRoot) {
                        admin.append(JunkItem(path: item.path, size: item.size, category: item.category, admin: true))
                    } else {
                        report.failures.append(item.path)
                    }
                }
            case .admin:
                if item.removalPaths.allSatisfy({ PathGuard.isSafeAdmin($0, home: home, root: systemRoot) || PathGuard.isSafeAppBundle($0, home: home, root: systemRoot) }) {
                    admin.append(item)
                } else {
                    report.failures.append(item.path)
                }
            case .snapshot:
                if AdminScript.isSnapshotDate(item.name) { admin.append(item) } else { report.failures.append(item.path) }
            }
        }
        if !admin.isEmpty, !cancel.isCancelled {
            let removals = admin.filter { $0.disposal == .admin }.flatMap(\.removalPaths)
            let snapshots = admin.filter { $0.disposal == .snapshot }.map(\.name)
            if runAdmin(AdminScript.build(removing: removals, snapshots: snapshots)) {
                for item in admin {
                    if item.disposal == .snapshot {
                        report.count += 1
                    } else if item.removalPaths.allSatisfy({ !FileManager.default.fileExists(atPath: $0) }) {
                        report.freed += item.size
                        report.count += 1
                    } else {
                        report.failures.append(item.path)
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
}
