import Foundation

/// Espace libre à un instant donné (relevé léger, toutes les 30 minutes environ).
public struct SpaceSample: Codable, Equatable, Sendable {
    public var date: Date
    public var available: Int64
    public var total: Int64
    public init(date: Date, available: Int64, total: Int64) { self.date = date; self.available = available; self.total = total }
}

/// Taille des dossiers et gros fichiers (≥ 50 Mo) du dossier personnel à un instant donné (relevé quotidien).
public struct SpaceSnapshot: Codable, Equatable, Sendable {
    public var date: Date
    public var sizes: [String: Int64]
    public init(date: Date, sizes: [String: Int64]) { self.date = date; self.sizes = sizes }
}

public struct TimelineData: Codable, Equatable, Sendable {
    public var samples: [SpaceSample] = []
    public var snapshots: [SpaceSnapshot] = []
    public init() {}
}

/// Un dossier ou fichier qui a grossi entre deux relevés.
public struct Growth: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let before: Int64
    public let after: Int64
    public var delta: Int64 { after - before }
}

public enum Forecast: Equatable, Sendable {
    case unknown
    case stable
    /// Octets perdus par jour et nombre de jours avant disque plein au même rythme.
    case filling(perDay: Int64, daysLeft: Int)
    case freeing(perDay: Int64)
}

/// Remplissage anormalement rapide : octets perdus sur les derniers jours.
public struct Anomaly: Equatable, Sendable {
    public let lost: Int64
    public let days: Int
}

public enum Timeline {
    public static let minimumEntry: Int64 = 50_000_000
    public static let day: TimeInterval = 86_400

    /// Aplatit l'arbre de la carte en `chemin → taille` (dossiers et fichiers listés ≥ `minSize`).
    public static func flatten(_ root: MapNode, minSize: Int64 = minimumEntry) -> [String: Int64] {
        var out: [String: Int64] = [:]
        func visit(_ node: MapNode) {
            guard node.size >= minSize else { return }
            out[node.path] = node.size
            for child in node.children { visit(child) }
        }
        visit(root)
        return out
    }

    // MARK: Causes

    /// Ce qui a grossi entre deux relevés, en descendant jusqu'au dossier (ou fichier) responsable de la hausse.
    public static func growth(from old: SpaceSnapshot, to new: SpaceSnapshot, minDelta: Int64 = 200_000_000, limit: Int = 12) -> [Growth] {
        let paths = Set(old.sizes.keys).union(new.sizes.keys)
        var children: [String: [String]] = [:]
        for p in paths { children[(p as NSString).deletingLastPathComponent, default: []].append(p) }
        func delta(_ p: String) -> Int64 { (new.sizes[p] ?? 0) - (old.sizes[p] ?? 0) }
        func growth(_ p: String) -> Growth { Growth(path: p, before: old.sizes[p] ?? 0, after: new.sizes[p] ?? 0) }
        func explain(_ p: String) -> [Growth] {
            let d = delta(p)
            guard d >= minDelta else { return [] }
            let kids = (children[p] ?? []).filter { delta($0) >= minDelta }.sorted { delta($0) > delta($1) }
            let explained = kids.reduce(Int64(0)) { $0 + delta($1) }
            guard Double(explained) >= 0.6 * Double(d) else { return [growth(p)] } // la hausse vient de fichiers directs, pas d'un sous-dossier
            return kids.prefix(4).flatMap(explain)
        }
        // Racines : les chemins dont le parent n'est pas dans les relevés.
        let roots = paths.filter { !paths.contains(($0 as NSString).deletingLastPathComponent) }
        let found = roots.flatMap(explain).sorted { $0.delta > $1.delta }
        return Array(found.prefix(limit))
    }

    // MARK: Prévision

    /// Tendance de l'espace libre sur les `window` derniers jours (régression linéaire).
    public static func forecast(_ samples: [SpaceSample], now: Date = Date(), window days: Int = 14) -> Forecast {
        let recent = samples.filter { $0.date >= now.addingTimeInterval(-Double(days) * day) }.sorted { $0.date < $1.date }
        guard let first = recent.first, let last = recent.last, last.date.timeIntervalSince(first.date) >= day else { return .unknown }
        let xs = recent.map { $0.date.timeIntervalSince(first.date) / day }
        let ys = recent.map { Double($0.available) }
        let n = Double(recent.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let denominator = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard denominator > 0 else { return .unknown }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / denominator // octets par jour
        let threshold = 100_000_000.0
        if slope <= -threshold {
            let left = Double(last.available) / -slope
            return .filling(perDay: Int64(-slope), daysLeft: left > 9999 ? 9999 : Int(left.rounded(.down)))
        }
        return slope >= threshold ? .freeing(perDay: Int64(slope)) : .stable
    }

    /// Perte nette sur les `recent` derniers jours nettement plus rapide que d'habitude (au moins 5 Go et 2 fois le rythme des 30 jours précédents).
    public static func anomaly(_ samples: [SpaceSample], now: Date = Date(), recent days: Int = 3) -> Anomaly? {
        let sorted = samples.sorted { $0.date < $1.date }
        guard let last = sorted.last, let past = sorted.last(where: { $0.date <= now.addingTimeInterval(-Double(days) * day) }) else { return nil }
        let lost = past.available - last.available
        guard lost >= 5_000_000_000 else { return nil }
        let baselineStart = now.addingTimeInterval(-Double(days + 30) * day)
        var baselineRate = 0.0
        if let start = sorted.first(where: { $0.date >= baselineStart }), start.date < past.date {
            let span = past.date.timeIntervalSince(start.date) / day
            baselineRate = max(Double(start.available - past.available) / span, 0)
        }
        let recentRate = Double(lost) / (last.date.timeIntervalSince(past.date) / day)
        return recentRate >= 2 * max(baselineRate, 1_000_000_000) ? Anomaly(lost: lost, days: days) : nil
    }

    // MARK: Choix des relevés à comparer

    /// Relevé le plus proche de `date`, en excluant `excluding`.
    public static func nearest(_ snapshots: [SpaceSnapshot], to date: Date, excluding: SpaceSnapshot? = nil) -> SpaceSnapshot? {
        snapshots.filter { $0 != excluding }.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

/// Historique enregistré en JSON ; borné (relevés d'espace libre ramenés à un par jour au-delà de 30 jours, 2 ans au plus ; 120 relevés de dossiers).
public struct TimelineStore {
    public let url: URL
    public var data: TimelineData

    public static func location(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/hdCLEANER/timeline.json")
    }

    public init(url: URL) {
        self.url = url
        if let raw = try? Data(contentsOf: url), let decoded = try? JSONDecoder.timeline.decode(TimelineData.self, from: raw) { data = decoded } else { data = TimelineData() }
    }

    public mutating func add(sample: SpaceSample, minimumGap: TimeInterval = 1800) {
        if let last = data.samples.last, sample.date.timeIntervalSince(last.date) < minimumGap { return }
        data.samples.append(sample)
        prune(now: sample.date)
    }

    public mutating func add(snapshot: SpaceSnapshot) {
        data.snapshots.append(snapshot)
        data.snapshots = Array(data.snapshots.sorted { $0.date < $1.date }.suffix(120))
    }

    public var lastSnapshotDate: Date? { data.snapshots.map(\.date).max() }

    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-730 * Timeline.day), thin = now.addingTimeInterval(-30 * Timeline.day)
        var keptDays = Set<Int>()
        let calendar = Calendar.current
        data.samples = data.samples.sorted { $0.date < $1.date }.filter { s in
            guard s.date >= cutoff else { return false }
            guard s.date < thin else { return true }
            let key = calendar.ordinality(of: .day, in: .era, for: s.date) ?? 0
            return keptDays.insert(key).inserted
        }
    }

    public func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let raw = try? JSONEncoder.timeline.encode(data) { try? raw.write(to: url, options: .atomic) }
    }
}

extension JSONEncoder {
    static var timeline: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
}

extension JSONDecoder {
    static var timeline: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}
