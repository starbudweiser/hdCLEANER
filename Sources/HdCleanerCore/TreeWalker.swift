import Darwin
import Foundation

/// Parcours d'arborescence POSIX (`fts`). `FileManager.enumerator` cache les fichiers `._*` (AppleDouble), justement ceux qu'on cherche ;
/// `fts` voit tout, ne suit pas les liens et, par défaut, ne franchit pas un autre volume (comme `find -x`).
public enum TreeWalker {
    public struct Entry {
        public let path: String
        public let isDirectory: Bool
        public let isSymlink: Bool
        /// Octets réellement occupés sur le disque.
        public let allocated: Int64
        public let level: Int
    }

    public enum Action { case descend, skip, stop }

    /// Visite en pré-ordre ; la racine est la première entrée. Les éléments illisibles sont ignorés.
    public static func walk(_ root: String, crossVolumes: Bool = false, _ visit: (Entry) -> Action) {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(root), nil]
        defer { free(argv[0]) }
        let options = FTS_PHYSICAL | FTS_NOCHDIR | (crossVolumes ? 0 : FTS_XDEV)
        guard let fts = fts_open(&argv, options, nil) else { return }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_DP || info == FTS_DNR || info == FTS_ERR || info == FTS_NS || info == FTS_DC { continue }
            let entry = Entry(path: String(cString: ent.pointee.fts_path), isDirectory: info == FTS_D, isSymlink: info == FTS_SL || info == FTS_SLNONE,
                              allocated: ent.pointee.fts_statp.map { Int64($0.pointee.st_blocks) * 512 } ?? 0, level: Int(ent.pointee.fts_level))
            switch visit(entry) {
            case .descend: break
            case .skip: if entry.isDirectory { fts_set(fts, ent, FTS_SKIP) }
            case .stop: return
            }
        }
    }
}
