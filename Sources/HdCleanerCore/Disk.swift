import Foundation

public struct DiskInfo: Equatable, Sendable {
    public var name: String
    public var total: Int64
    public var available: Int64
    /// Part de `available` que macOS libère de lui-même au besoin (instantanés locaux, caches) : déjà comptée comme disponible.
    public var purgeable: Int64

    public init(name: String, total: Int64, available: Int64, purgeable: Int64 = 0) {
        self.name = name
        self.total = total
        self.available = available
        self.purgeable = purgeable
    }

    public var used: Int64 { max(total - available, 0) }

    /// Espace disponible tel que l'affiche le Finder (espace purgeable compris).
    public static func read(_ url: URL = URL(fileURLWithPath: "/")) -> DiskInfo? {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity,
              let available = v.volumeAvailableCapacityForImportantUsage else { return nil }
        let strict = v.volumeAvailableCapacity.map(Int64.init) ?? available
        return DiskInfo(name: v.volumeLocalizedName ?? "", total: Int64(total), available: available, purgeable: max(available - strict, 0))
    }
}

/// Un volume monté, proposé au choix pour la surveillance.
public struct Volume: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    /// Volumes locaux visibles dans le Finder (disque de démarrage, disques externes) ; le démarrage vient en premier.
    public static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let list = urls.compactMap { url -> Volume? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true else { return nil }
            return Volume(name: v.volumeLocalizedName ?? url.lastPathComponent, path: url.standardizedFileURL.path)
        }
        return list.sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }
}

/// Alerte de seuil : une seule notification par franchissement, réarmée quand l'espace repasse 1 point au-dessus.
public struct ThresholdMonitor: Equatable, Sendable {
    public private(set) var alerted = false

    public init() {}

    public static func limit(total: Int64, percent: Int) -> Int64 { total / 100 * Int64(percent) }

    /// Renvoie vrai s'il faut prévenir maintenant.
    public mutating func check(_ disk: DiskInfo, percent: Int) -> Bool {
        let limit = Self.limit(total: disk.total, percent: percent)
        if disk.available < limit {
            defer { alerted = true }
            return !alerted
        }
        if disk.available >= limit + disk.total / 100 { alerted = false }
        return false
    }
}
