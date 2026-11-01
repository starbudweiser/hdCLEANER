import Foundation

/// Langues d'une appli : lesquelles garder, lesquelles peuvent partir.
public enum Languages {
    static let legacy = ["english": "en", "french": "fr", "german": "de", "spanish": "es", "italian": "it", "dutch": "nl", "japanese": "ja",
                         "swedish": "sv", "danish": "da", "norwegian": "no", "finnish": "fi", "portuguese": "pt"]
    static let neutral: Set<String> = ["und", "mul", "zxx"]

    /// Codes de langue (« fr », « en ») des langues préférées du système ; l'anglais est toujours gardé.
    public static func kept(preferred: [String]) -> Set<String> {
        var codes: Set<String> = ["en"]
        for tag in preferred {
            if let base = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first { codes.insert(String(base)) }
        }
        return codes
    }

    /// Un dossier « xx.lproj » peut-il être supprimé ? Les noms qu'on ne reconnaît pas comme une langue sont gardés.
    public static func isRemovable(_ folder: String, kept: Set<String>) -> Bool {
        guard folder.hasSuffix(".lproj") else { return false }
        let raw = String(folder.dropLast(".lproj".count)).lowercased()
        guard !raw.isEmpty, raw != "base" else { return false }
        let base = legacy[raw] ?? raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? raw
        guard base.count == 2 || base.count == 3, !neutral.contains(base) else { return false }
        return !kept.contains(base)
    }
}
