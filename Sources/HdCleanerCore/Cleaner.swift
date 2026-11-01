import Foundation

public struct CleanReport: Sendable, Equatable {
    /// Octets réellement rendus au disque.
    public var freed: Int64 = 0
    /// Octets partis à la Corbeille : rendus seulement quand elle sera vidée.
    public var trashed: Int64 = 0
    public var count = 0
    public var failures: [String] = []

    public init() {}
}

/// Dernier rempart avant toute suppression : quoi que dise l'analyse, rien hors du dossier personnel ni aucun dossier racine.
public enum PathGuard {
    static let protected: Set<String> = [
        "Library", "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences", "Library/Containers",
        "Library/Developer", "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies", "Applications", ".Trash",
    ]
    static let forbiddenPrefixes = ["Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail/", ".ssh", ".gnupg"]

    public static func isSafe(_ path: String, home: URL) -> Bool {
        let base = home.standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard target == path, target.hasPrefix(base + "/") else { return false }
        let relative = String(target.dropFirst(base.count + 1))
        guard relative.contains("/"), !protected.contains(relative) else { return false }
        return !forbiddenPrefixes.contains { relative == $0 || relative.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

public enum Cleaner {
    public static func clean(_ items: [JunkItem], home: URL, cancel: CancelFlag = CancelFlag(),
                             toTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                             progress: (Double) -> Void = { _ in }) -> CleanReport {
        var report = CleanReport()
        for (index, item) in items.enumerated() {
            if cancel.isCancelled { break }
            progress(Double(index) / Double(max(items.count, 1)))
            guard PathGuard.isSafe(item.path, home: home) else {
                report.failures.append(item.path)
                continue
            }
            do {
                switch item.category.disposal {
                case .delete:
                    try FileManager.default.removeItem(at: item.url)
                    report.freed += item.size
                case .trash:
                    try toTrash(item.url)
                    report.trashed += item.size
                }
                report.count += 1
            } catch {
                report.failures.append(item.path)
            }
        }
        progress(1)
        return report
    }
}
