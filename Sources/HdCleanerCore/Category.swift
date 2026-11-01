import Foundation

/// Sort d'un élément au nettoyage : supprimé (données régénérables) ou mis à la Corbeille (fichiers personnels).
public enum Disposal: Sendable {
    case delete, trash
}

public enum JunkCategory: String, CaseIterable, Identifiable, Sendable {
    case appCaches, appLogs, browserData, devCaches, trash, downloads, mailDownloads, largeFiles
    case leftovers, iosBackups, iosPhotoCache, musicCache, iosUpdates, installers, screenshots

    public var id: String { rawValue }
    public var title: String { L("category.\(rawValue)") }
    public var help: String { L("categoryHelp.\(rawValue)") }

    public var disposal: Disposal {
        switch self {
        case .appCaches, .appLogs, .browserData, .devCaches, .trash, .iosPhotoCache, .musicCache, .iosUpdates: .delete
        case .downloads, .mailDownloads, .largeFiles, .leftovers, .iosBackups, .installers, .screenshots: .trash
        }
    }

    /// Cochée d'office après l'analyse : uniquement ce qui se régénère seul.
    public var preselected: Bool {
        switch self {
        case .appCaches, .appLogs, .browserData, .iosPhotoCache, .musicCache: true
        default: false
        }
    }
}

public struct JunkItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let category: JunkCategory
    /// L'appli propriétaire tourne : jamais cochée d'office.
    public let inUse: Bool

    public init(path: String, size: Int64, category: JunkCategory, inUse: Bool = false) {
        self.path = path
        self.size = size
        self.category = category
        self.inUse = inUse
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
    public var preselected: Bool { category.preselected && !inUse }
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
