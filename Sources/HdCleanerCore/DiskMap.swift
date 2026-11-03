import CoreGraphics
import Foundation

/// Un dossier ou un fichier de la carte. Les petits dossiers sont repliés (leurs enfants ne sont pas gardés) pour borner la mémoire.
public final class MapNode: Identifiable, @unchecked Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public internal(set) var size: Int64
    /// Octets des petits fichiers de ce dossier, regroupés au lieu d'être listés un à un.
    public internal(set) var smallFiles: Int64 = 0
    public internal(set) var children: [MapNode] = []
    public internal(set) weak var parent: MapNode?

    init(name: String, path: String, isDirectory: Bool, size: Int64 = 0) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }

    /// Retire ce nœud de l'arbre (après suppression sur le disque) : sa taille est déduite chez tous les parents.
    public func detach() {
        var up = parent
        parent?.children.removeAll { $0 === self }
        while let p = up { p.size -= size; up = p.parent }
        parent = nil
    }

    /// Chemin des dossiers depuis la racine jusqu'à ce nœud.
    public var trail: [MapNode] {
        var out: [MapNode] = []
        var node: MapNode? = self
        while let n = node { out.insert(n, at: 0); node = n.parent }
        return out
    }
}

public enum DiskMapper {
    /// Dossiers repliés sous ce seuil (leurs enfants ne sont pas conservés) et fichiers regroupés sous ce seuil.
    public static let foldBelow: Int64 = 32_000_000 // valeur par défaut de `scan`
    public static let listFilesAbove: Int64 = 4_000_000

    /// Parcourt `root` une fois et construit l'arbre des tailles occupées sur le disque.
    public static func scan(root: String, foldBelow: Int64 = DiskMapper.foldBelow, cancel: CancelFlag = CancelFlag(), progress: @escaping @Sendable (Int, Int64) -> Void = { _, _ in }) -> MapNode {
        let rootNode = MapNode(name: (root as NSString).lastPathComponent, path: root, isDirectory: true)
        var stack: [MapNode] = []
        var count = 0
        func close(to depth: Int) {
            while stack.count > depth {
                let node = stack.removeLast()
                node.children.sort { $0.size > $1.size }
                if node.size < foldBelow, node !== rootNode { node.children = [] }
                if let parent = stack.last { parent.size += node.size }
            }
        }
        TreeWalker.walk(root) { entry in
            if cancel.isCancelled { return .stop }
            close(to: entry.level)
            count += 1
            if count % 2000 == 0 { progress(count, rootNode.size) }
            if entry.isDirectory {
                let node = entry.level == 0 ? rootNode : MapNode(name: (entry.path as NSString).lastPathComponent, path: entry.path, isDirectory: true, size: entry.allocated)
                if entry.level > 0 { node.parent = stack.last; stack.last?.children.append(node) } else { node.size = entry.allocated }
                stack.append(node)
            } else if let dir = stack.last {
                dir.size += entry.allocated
                if entry.allocated >= listFilesAbove {
                    let file = MapNode(name: (entry.path as NSString).lastPathComponent, path: entry.path, isDirectory: false, size: entry.allocated)
                    file.parent = dir
                    dir.children.append(file)
                } else {
                    dir.smallFiles += entry.allocated
                }
            }
            return .descend
        }
        close(to: 0)
        return rootNode
    }
}

/// Disposition « treemap » (algorithme squarified) : chaque taille reçoit un rectangle de surface proportionnelle.
public enum Treemap {
    /// `sizes` triées par ordre décroissant ; renvoie un rectangle par taille, dans le même ordre.
    public static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = sizes.map { $0 * scale }
        var rects: [CGRect] = []
        var free = rect
        var row: [Double] = []
        var index = 0
        func worst(_ row: [Double], _ side: Double) -> Double {
            let sum = row.reduce(0, +), maxA = row.max() ?? 0, minA = row.min() ?? 0
            guard sum > 0, minA > 0 else { return .infinity }
            return max(side * side * maxA / (sum * sum), sum * sum / (side * side * minA))
        }
        func place(_ row: [Double]) {
            let sum = row.reduce(0, +)
            if free.width >= free.height { // colonne à gauche
                let w = CGFloat(sum / Double(free.height))
                var y = free.minY
                for a in row { let h = CGFloat(a) / w; rects.append(CGRect(x: free.minX, y: y, width: w, height: h)); y += h }
                free = CGRect(x: free.minX + w, y: free.minY, width: max(free.width - w, 0), height: free.height)
            } else { // ligne en haut
                let h = CGFloat(sum / Double(free.width))
                var x = free.minX
                for a in row { let w = CGFloat(a) / h; rects.append(CGRect(x: x, y: free.minY, width: w, height: h)); x += w }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: max(free.height - h, 0))
            }
        }
        while index < areas.count {
            let side = Double(min(free.width, free.height))
            let next = areas[index]
            if row.isEmpty || worst(row + [next], side) <= worst(row, side) {
                row.append(next)
                index += 1
            } else {
                place(row)
                row = []
            }
        }
        if !row.isEmpty { place(row) }
        return rects
    }
}
