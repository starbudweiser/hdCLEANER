import Foundation

public enum DiskSize {
    /// Taille occupée sur le disque, liens symboliques non suivis ; les dossiers illisibles comptent pour ce qui se lit.
    public static func bytes(of url: URL, cancel: CancelFlag = CancelFlag()) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        func size(_ v: URLResourceValues) -> Int64 { Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        if values.isSymbolicLink == true || values.isDirectory != true { return size(values) }
        var total: Int64 = 0
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let child as URL in walker {
            if cancel.isCancelled { break }
            if let v = try? child.resourceValues(forKeys: keys), v.isDirectory != true { total += size(v) }
        }
        return total
    }
}
