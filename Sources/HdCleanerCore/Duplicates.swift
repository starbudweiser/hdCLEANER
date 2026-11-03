import CryptoKit
import Foundation

public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let modified: Date

    public init(path: String, modified: Date) {
        self.path = path
        self.modified = modified
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// Fichiers au contenu identique (même taille, même empreinte SHA-256 complète).
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public var id: String { digest }
    public let digest: String
    public let size: Int64
    /// Du plus ancien au plus récent, puis chemin le plus court : le premier est celui qu'on garde d'office.
    public var files: [DuplicateFile]

    public init(digest: String, size: Int64, files: [DuplicateFile]) {
        self.digest = digest
        self.size = size
        self.files = files
    }

    /// Octets rendus si on ne garde qu'un exemplaire.
    public var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
}

public struct DuplicateScan: Sendable {
    public var groups: [DuplicateGroup] = []
    public var scanned = 0

    public init() {}

    public var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    /// Exemplaires supprimables d'office : tous sauf le premier de chaque groupe.
    public var preselected: Set<String> { Set(groups.flatMap { $0.files.dropFirst().map(\.path) }) }
}

public enum DuplicateFinder {
    public static let skippedFolders: Set<String> = [".git", ".svn", "node_modules", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", "System Volume Information", "$RECYCLE.BIN"]

    /// Cherche les doublons sous `roots`. Les paquets (.app, bibliothèques Photos…), `Library` du dossier personnel, les liens et les fichiers déjà liés entre eux (même inode) sont ignorés.
    public static func scan(roots: [String], home: URL, minSize: Int64 = 1_000_000, cancel: CancelFlag = CancelFlag(), progress: @escaping @Sendable (Int) -> Void = { _ in }) -> DuplicateScan {
        struct Candidate { let path: String; let modified: Date }
        var bySize: [Int64: [Candidate]] = [:]
        var seen = Set<String>() // inode + volume : un même fichier relié deux fois n'est pas un doublon
        var scanned = 0
        let library = home.standardizedFileURL.path + "/Library"
        for root in roots {
            TreeWalker.walk(root) { entry in
                if cancel.isCancelled { return .stop }
                let name = (entry.path as NSString).lastPathComponent
                if entry.isDirectory {
                    if entry.level > 0, skippedFolders.contains(name) || PathGuard.packageExtensions.contains((name as NSString).pathExtension.lowercased()) || entry.path == library { return .skip }
                    return .descend
                }
                guard !entry.isSymlink, entry.size >= minSize, !name.hasPrefix("._"), name != ".DS_Store" else { return .descend }
                scanned += 1
                if scanned % 500 == 0 { progress(scanned) }
                guard seen.insert("\(entry.device):\(entry.inode)").inserted else { return .descend }
                bySize[entry.size, default: []].append(Candidate(path: entry.path, modified: entry.modified))
                return .descend
            }
        }
        let sameSize = bySize.filter { $0.value.count > 1 }
        // Empreinte du début d'abord (rapide), complète seulement pour ceux qui se ressemblent.
        let jobs = sameSize.flatMap { size, list in list.map { (size, $0) } }
        let lock = NSLock()
        var byHead: [String: [(Int64, Candidate)]] = [:]
        var done = 0
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            if cancel.isCancelled { return }
            let (size, c) = jobs[i]
            guard let head = digest(of: c.path, limit: 65_536, cancel: cancel) else { return }
            lock.lock()
            byHead["\(size):\(head)", default: []].append((size, c))
            done += 1
            lock.unlock()
        }
        let candidates = byHead.values.filter { $0.count > 1 }.flatMap { $0 }
        var byFull: [String: [(Int64, Candidate)]] = [:]
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            if cancel.isCancelled { return }
            let (size, c) = candidates[i]
            guard let full = digest(of: c.path, limit: nil, cancel: cancel) else { return }
            lock.lock()
            byFull["\(size):\(full)", default: []].append((size, c))
            lock.unlock()
        }
        var result = DuplicateScan()
        result.scanned = scanned
        guard !cancel.isCancelled else { return result }
        for (key, list) in byFull where list.count > 1 {
            let files = list.map { DuplicateFile(path: $0.1.path, modified: $0.1.modified) }
                .sorted { ($0.modified, $0.path.count, $0.path) < ($1.modified, $1.path.count, $1.path) }
            result.groups.append(DuplicateGroup(digest: key, size: list[0].0, files: files))
        }
        result.groups.sort { ($0.wasted, $0.digest) > ($1.wasted, $1.digest) }
        return result
    }

    /// SHA-256 du fichier (ou de ses `limit` premiers octets) ; nil si illisible ou interrompu.
    static func digest(of path: String, limit: Int?, cancel: CancelFlag) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var left = limit ?? Int.max
        while left > 0 {
            if cancel.isCancelled { return nil }
            guard let chunk = try? handle.read(upToCount: min(1 << 20, left)), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            left -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum DuplicateCleaner {
    /// Met à la Corbeille les exemplaires choisis, sans jamais vider un groupe : l'exemplaire gardé doit exister encore avec la même taille.
    public static func clean(_ selection: Set<String>, groups: [DuplicateGroup], home: URL, cancel: CancelFlag = CancelFlag(),
                             toTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                             progress: (Double) -> Void = { _ in }) -> CleanReport {
        var report = CleanReport()
        var todo: [(path: String, size: Int64)] = []
        for group in groups {
            let chosen = group.files.filter { selection.contains($0.path) }
            guard !chosen.isEmpty else { continue }
            let kept = group.files.filter { !selection.contains($0.path) }.filter { file in
                (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) == group.size
            }
            guard !kept.isEmpty else { // tout le groupe serait perdu : on ne touche à rien
                report.failures += chosen.map(\.path)
                continue
            }
            for file in chosen {
                if (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) == group.size { todo.append((file.path, group.size)) } else { report.failures.append(file.path) }
            }
        }
        let done = FileTrasher.trash(todo, home: home, cancel: cancel, toTrash: toTrash, progress: progress)
        report.trashed += done.trashed
        report.count += done.count
        report.failures += done.failures
        return report
    }
}
