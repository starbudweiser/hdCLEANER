import Foundation

/// Familles de fichiers de l'organiseur. `other` n'est jamais déplacé.
public enum OrganizerKind: String, CaseIterable, Identifiable, Sendable {
    case images, videos, audio, documents, sheets, archives, installers, other

    public var id: String { rawValue }

    public static let extensions: [OrganizerKind: Set<String>] = [
        .images: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "raw", "cr2", "nef", "arw", "dng", "psd", "ai", "eps", "ico", "icns"],
        .videos: ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "mts", "m2ts", "prores"],
        .audio: ["mp3", "wav", "aiff", "aif", "flac", "m4a", "aac", "ogg", "opus", "wma", "mid", "midi"],
        .documents: ["pdf", "doc", "docx", "txt", "rtf", "pages", "odt", "md", "epub", "mobi", "tex", "wps"],
        .sheets: ["xls", "xlsx", "csv", "numbers", "ods", "ppt", "pptx", "key", "odp", "tsv"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "cab"],
        .installers: ["dmg", "pkg", "iso", "exe", "msi", "mpkg", "appimage"],
    ]

    /// Extensions d'un téléchargement en cours : on n'y touche pas.
    public static let partial: Set<String> = ["crdownload", "part", "download", "opdownload", "tmp", "partial", "aria2", "!ut"]

    public static func of(_ name: String) -> OrganizerKind {
        let ext = (name as NSString).pathExtension.lowercased()
        return allCases.first { extensions[$0]?.contains(ext) == true } ?? .other
    }

    public var title: String { L("org.kind.\(rawValue)") }
    /// Nom du sous-dossier créé pour cette famille.
    public var folder: String { L("org.folder.\(rawValue)") }
}

public struct OrganizerMove: Identifiable, Hashable, Sendable {
    public var id: String { source }
    public let source: String
    public let destination: String
    public let kind: OrganizerKind
    public let size: Int64

    public init(source: String, destination: String, kind: OrganizerKind, size: Int64) {
        self.source = source
        self.destination = destination
        self.kind = kind
        self.size = size
    }

    public var name: String { (source as NSString).lastPathComponent }
}

public struct OrganizerPlan: Sendable {
    public var moves: [OrganizerMove] = []
    /// Fichiers laissés en place (famille inconnue, téléchargement en cours, caché).
    public var left = 0

    public init() {}

    public func moves(_ kind: OrganizerKind) -> [OrganizerMove] { moves.filter { $0.kind == kind } }
}

public enum Organizer {
    /// Classe les fichiers du dossier (sans descendre dans les sous-dossiers) dans un sous-dossier par famille. Rien n'est déplacé.
    public static func plan(root: String, folderName: (OrganizerKind) -> String = { $0.folder }, minimumAge: TimeInterval = 60, now: Date = Date()) -> OrganizerPlan {
        var plan = OrganizerPlan()
        let url = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        let names = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        for child in names.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            guard let v = try? child.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isPackage != true else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let kind = OrganizerKind.of(name)
            if name.hasPrefix(".") || kind == .other || OrganizerKind.partial.contains(ext) || now.timeIntervalSince(v.contentModificationDate ?? .distantPast) < minimumAge {
                plan.left += 1
                continue
            }
            let target = url.appendingPathComponent(folderName(kind)).appendingPathComponent(name)
            plan.moves.append(OrganizerMove(source: child.path, destination: target.path, kind: kind, size: Int64(v.fileSize ?? 0)))
        }
        return plan
    }

    /// Déplace les fichiers choisis ; un nom déjà pris reçoit un numéro (« photo 2.jpg »), rien n'est jamais écrasé. Renvoie les déplacements réellement faits, pour pouvoir les annuler.
    public static func apply(_ moves: [OrganizerMove], root: String, cancel: CancelFlag = CancelFlag(), progress: (Double) -> Void = { _ in }) -> (done: [OrganizerMove], failed: [String]) {
        var done: [OrganizerMove] = []
        var failed: [String] = []
        let fm = FileManager.default
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        for (index, move) in moves.enumerated() {
            if cancel.isCancelled { break }
            progress(Double(index) / Double(max(moves.count, 1)))
            // Le fichier doit toujours être directement dans le dossier choisi.
            guard URL(fileURLWithPath: (move.source as NSString).deletingLastPathComponent).standardizedFileURL.path == base, fm.fileExists(atPath: move.source) else { failed.append(move.source); continue }
            let folder = (move.destination as NSString).deletingLastPathComponent
            do {
                try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
                let target = freeName(move.destination)
                try fm.moveItem(atPath: move.source, toPath: target)
                done.append(OrganizerMove(source: move.source, destination: target, kind: move.kind, size: move.size))
            } catch {
                failed.append(move.source)
            }
        }
        progress(1)
        return (done, failed)
    }

    /// Remet les fichiers à leur place (annulation) ; les sous-dossiers devenus vides sont supprimés.
    public static func undo(_ moves: [OrganizerMove]) -> Int {
        let fm = FileManager.default
        var restored = 0
        for move in moves.reversed() where fm.fileExists(atPath: move.destination) && !fm.fileExists(atPath: move.source) {
            if (try? fm.moveItem(atPath: move.destination, toPath: move.source)) != nil { restored += 1 }
        }
        for folder in Set(moves.map { (($0.destination) as NSString).deletingLastPathComponent }) {
            if (try? fm.contentsOfDirectory(atPath: folder))?.isEmpty == true { try? fm.removeItem(atPath: folder) }
        }
        return restored
    }

    static func freeName(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let ns = path as NSString
        let base = (ns.lastPathComponent as NSString).deletingPathExtension, ext = ns.pathExtension, dir = ns.deletingLastPathComponent
        var n = 2
        while true {
            let candidate = dir + "/" + base + " \(n)" + (ext.isEmpty ? "" : "." + ext)
            if !fm.fileExists(atPath: candidate) { return candidate }
            n += 1
        }
    }
}
