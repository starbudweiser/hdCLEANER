import Foundation

public struct DiskInfo: Equatable, Sendable {
    public var name: String
    public var total: Int64
    public var available: Int64

    public init(name: String, total: Int64, available: Int64) {
        self.name = name
        self.total = total
        self.available = available
    }

    public var used: Int64 { max(total - available, 0) }

    /// Espace disponible tel que l'affiche le Finder (espace purgeable compris).
    public static func read(_ url: URL = URL(fileURLWithPath: "/")) -> DiskInfo? {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity,
              let available = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskInfo(name: v.volumeLocalizedName ?? "", total: Int64(total), available: available)
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
