import Foundation

public enum ThemeChoice: String, Codable, CaseIterable {
    case dark, light, system
}

/// Réglages de l'appli, enregistrés en JSON dans UserDefaults.
public struct AppSettings: Codable, Equatable {
    public var theme = ThemeChoice.dark
    public var largeFileMinimumMB = 500
    public var monitorEnabled = false
    public var thresholdPercent = 15
    /// Point de montage du volume surveillé ; « / » est le disque de démarrage.
    public var monitoredVolume = "/"
    public var excludedPaths: [String] = []
    /// Dossiers et volumes où les fichiers invisibles de macOS sont supprimés dès qu'ils apparaissent.
    public var watchedFolders: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decode(ThemeChoice.self, forKey: .theme)) ?? d.theme
        largeFileMinimumMB = (try? c.decode(Int.self, forKey: .largeFileMinimumMB)) ?? d.largeFileMinimumMB
        monitorEnabled = (try? c.decode(Bool.self, forKey: .monitorEnabled)) ?? d.monitorEnabled
        thresholdPercent = (try? c.decode(Int.self, forKey: .thresholdPercent)) ?? d.thresholdPercent
        monitoredVolume = (try? c.decode(String.self, forKey: .monitoredVolume)) ?? d.monitoredVolume
        excludedPaths = (try? c.decode([String].self, forKey: .excludedPaths)) ?? d.excludedPaths
        watchedFolders = (try? c.decode([String].self, forKey: .watchedFolders)) ?? d.watchedFolders
    }

    /// Ramène les valeurs dans les plages de l'interface.
    public func normalized() -> AppSettings {
        var s = self
        s.largeFileMinimumMB = min(max(largeFileMinimumMB, 100), 10_000)
        s.thresholdPercent = min(max(thresholdPercent, 5), 50)
        return s
    }

    public static func decode(_ data: Data?) -> AppSettings {
        guard let data, let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s.normalized()
    }
}
