import Foundation

extension PathGuard {
    static let volumeSystemFolders: Set<String> = [".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100", "System Volume Information", "$RECYCLE.BIN", ".Trash"]
    static let packageExtensions: Set<String> = ["app", "photoslibrary", "imovielibrary", "fcpbundle", "xcarchive", "bundle", "framework", "kext", "plugin", "pkg", "lrlibrary", "tvlibrary", "musiclibrary", "sparsebundle", "dmg"]

    /// Fichier de l'utilisateur qu'un outil peut mettre à la Corbeille : dossier personnel (hors dossiers racines et zones protégées) ou disque monté dans /Volumes.
    public static func isSafeUserFile(_ path: String, home: URL, volumesRoot: String = "/Volumes") -> Bool {
        if isSafe(path, home: home) { return true }
        guard URL(fileURLWithPath: path).standardizedFileURL.path == path, path.hasPrefix(volumesRoot + "/") else { return false }
        let parts = path.dropFirst(volumesRoot.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts.contains(""), !parts.contains(where: { volumeSystemFolders.contains($0) }) else { return false }
        // « Macintosh HD » est un lien vers la racine : le disque de démarrage passe par le dossier personnel.
        return URL(fileURLWithPath: volumesRoot + "/" + parts[0]).resolvingSymlinksInPath().path != "/"
    }

    /// Dossier qu'un outil peut parcourir : le dossier personnel (ou un de ses sous-dossiers) ou un disque monté.
    public static func isScannableRoot(_ path: String, home: URL, volumesRoot: String = "/Volumes") -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let h = home.standardizedFileURL.path
        if p == h || p.hasPrefix(h + "/") { return true }
        guard p.hasPrefix(volumesRoot + "/") else { return false }
        let name = String(p.dropFirst(volumesRoot.count + 1).split(separator: "/").first ?? "")
        return !name.isEmpty && URL(fileURLWithPath: volumesRoot + "/" + name).resolvingSymlinksInPath().path != "/"
    }
}

/// Mise à la Corbeille de fichiers choisis par l'utilisateur (doublons, carte du disque), derrière `PathGuard.isSafeUserFile`.
public enum FileTrasher {
    public static func trash(_ files: [(path: String, size: Int64)], home: URL, cancel: CancelFlag = CancelFlag(),
                             toTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                             progress: (Double) -> Void = { _ in }) -> CleanReport {
        var report = CleanReport()
        for (index, file) in files.enumerated() {
            if cancel.isCancelled { break }
            progress(Double(index) / Double(max(files.count, 1)))
            guard PathGuard.isSafeUserFile(file.path, home: home), FileManager.default.fileExists(atPath: file.path) else {
                report.failures.append(file.path)
                continue
            }
            do {
                try toTrash(URL(fileURLWithPath: file.path))
                report.trashed += file.size
                report.count += 1
            } catch {
                report.failures.append(file.path)
            }
        }
        progress(1)
        return report
    }
}
