import Foundation

/// Sort d'un élément au nettoyage : supprimé (données régénérables), mis à la Corbeille (fichiers personnels),
/// supprimé avec le mot de passe administrateur (fichiers système) ou instantané Time Machine supprimé par `tmutil`.
public enum Disposal: Sendable {
    case delete, trash, admin, snapshot
}

public enum JunkCategory: String, CaseIterable, Identifiable, Sendable {
    case appCaches, appLogs, browserData, devCaches, trash, downloads, mailDownloads, largeFiles
    case leftovers, iosBackups, iosPhotoCache, musicCache, iosUpdates, installers, screenshots
    case systemCaches, systemLogs, snapshots, languages

    public var id: String { rawValue }
    public var title: String { L("category.\(rawValue)") }
    public var help: String { L("categoryHelp.\(rawValue)") }

    public var disposal: Disposal {
        switch self {
        case .appCaches, .appLogs, .browserData, .devCaches, .trash, .iosPhotoCache, .musicCache, .iosUpdates: .delete
        case .downloads, .mailDownloads, .largeFiles, .leftovers, .iosBackups, .installers, .screenshots: .trash
        case .systemCaches, .systemLogs, .languages: .admin
        case .snapshots: .snapshot
        }
    }

    /// Cochée d'office après l'analyse : uniquement ce qui se régénère seul et ne demande aucun mot de passe.
    public var preselected: Bool {
        switch self {
        case .appCaches, .appLogs, .browserData, .iosPhotoCache, .musicCache: true
        default: false
        }
    }
}

public struct JunkItem: Identifiable, Hashable, Sendable {
    public static let snapshotPrefix = "snapshot:"

    public var id: String { path }
    public let path: String
    public let size: Int64
    public let category: JunkCategory
    /// L'appli propriétaire tourne : jamais cochée d'office.
    public let inUse: Bool
    /// Supprimé avec le mot de passe administrateur, même si sa catégorie ne l'exige pas (installeur macOS appartenant à root).
    public let admin: Bool
    /// Éléments réellement supprimés quand l'entrée en regroupe plusieurs (les langues d'une appli).
    public let parts: [String]

    public init(path: String, size: Int64, category: JunkCategory, inUse: Bool = false, admin: Bool = false, parts: [String] = []) {
        self.path = path
        self.size = size
        self.category = category
        self.inUse = inUse
        self.admin = admin
        self.parts = parts
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { path.hasPrefix(Self.snapshotPrefix) ? String(path.dropFirst(Self.snapshotPrefix.count)) : url.lastPathComponent }
    public var preselected: Bool { category.preselected && !inUse }
    public var disposal: Disposal { admin && category.disposal != .snapshot ? .admin : category.disposal }
    public var removalPaths: [String] { parts.isEmpty ? [path] : parts }
}

public struct ScanResult: Sendable {
    public var items: [JunkCategory: [JunkItem]] = [:]
    /// Catégories dont un dossier est illisible faute d'autorisation (Accès complet au disque).
    public var denied: Set<JunkCategory> = []

    public init() {}

    public func total(_ category: JunkCategory) -> Int64 {
        (items[category] ?? []).reduce(0) { $0 + $1.size }
    }

    public var total: Int64 { JunkCategory.allCases.reduce(0) { $0 + total($1) } }
    public var all: [JunkItem] { JunkCategory.allCases.flatMap { items[$0] ?? [] } }
}

/// Drapeau d'annulation partagé avec le fil d'analyse ou de nettoyage.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}
