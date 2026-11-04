import Foundation

/// Une menace trouvée par une règle YARA.
public struct Detection: Identifiable, Hashable, Sendable {
    public var id: String { path + "|" + rule }
    public let path: String
    public let rule: String
    public let detail: String

    public init(path: String, rule: String, detail: String = "") {
        self.path = path
        self.rule = rule
        self.detail = detail
    }
}

/// Version et date de la base de signatures (règles XProtect d'Apple, mises à jour par macOS).
public struct SignatureInfo: Sendable, Equatable {
    public var version = ""
    public var date: Date?
    public var ruleCount = 0
    public init() {}
}

/// Moteur d'analyse : le programme `yara` (BSD) embarqué dans l'appli, chargé des règles XProtect d'Apple et des règles propres à hdCLEANER.
public enum YaraEngine {
    public static let xprotectDirectory = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents"
    public static var xprotectRules: URL { URL(fileURLWithPath: xprotectDirectory + "/Resources/XProtect.yara") }

    public struct Config: Sendable {
        public let binary: URL
        public let ruleFiles: [URL]
        public init(binary: URL, ruleFiles: [URL]) {
            self.binary = binary
            self.ruleFiles = ruleFiles
        }

        /// Fichiers de règles qui existent réellement.
        var existingRules: [URL] { ruleFiles.filter { FileManager.default.fileExists(atPath: $0.path) } }
        public var isUsable: Bool { FileManager.default.isExecutableFile(atPath: binary.path) && !existingRules.isEmpty }
    }

    /// Lit la sortie de `yara -m` : « Règle [meta=…] chemin » ou « Règle chemin ».
    public static func parse(_ output: String) -> [Detection] {
        var found: [Detection] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard !line.hasPrefix("error"), !line.hasPrefix("warning"), let space = line.firstIndex(of: " ") else { continue }
            let rule = String(line[..<space])
            var rest = String(line[line.index(after: space)...])
            var detail = ""
            if rest.hasPrefix("["), let close = rest.range(of: "] /") {
                let meta = String(rest[rest.index(after: rest.startIndex)..<close.lowerBound])
                if let d = meta.range(of: #"description="([^"]*)""#, options: .regularExpression) {
                    detail = String(meta[d]).replacingOccurrences(of: "description=\"", with: "").dropLast().description
                }
                rest = String(rest[rest.index(close.upperBound, offsetBy: -1)...])
            }
            guard rest.hasPrefix("/") else { continue }
            found.append(Detection(path: rest, rule: rule, detail: detail))
        }
        return found
    }

    /// Analyse des fichiers ou dossiers (récursif). Une même menace trouvée par plusieurs règles est regroupée par chemin.
    public static func scan(_ paths: [String], config: Config, recursive: Bool = true, cancel: CancelFlag = CancelFlag()) -> [Detection] {
        var all: [Detection] = []
        let rules = config.existingRules
        // yara accepte plusieurs fichiers de règles (un espace de noms chacun) mais une seule cible : un appel par chemin.
        for target in paths where FileManager.default.fileExists(atPath: target) {
            if cancel.isCancelled { break }
            var args = ["-w", "-m", "-N", "-z", "300"]
            if recursive { args.append(contentsOf: ["-r", "-p", "2"]) }
            args.append(contentsOf: rules.enumerated().map { "r\($0.offset):\($0.element.path)" })
            args.append(target)
            guard let out = run(config.binary, args, cancel: cancel) else { continue }
            all.append(contentsOf: parse(out))
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    private static func run(_ binary: URL, _ args: [String], cancel: CancelFlag) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = binary
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        let box = OutputBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { box.append(chunk) }
        }
        guard (try? process.run()) != nil else { return nil }
        while process.isRunning {
            if cancel.isCancelled { process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        box.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return cancel.isCancelled ? nil : box.text
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// Version de la base d'Apple, date de dernière mise à jour et nombre de règles.
    public static func signatureInfo(rules: URL = xprotectRules, infoPlist: String = xprotectDirectory + "/Info.plist") -> SignatureInfo {
        var info = SignatureInfo()
        if let plist = NSDictionary(contentsOfFile: infoPlist) { info.version = plist["CFBundleShortVersionString"] as? String ?? "" }
        info.date = (try? FileManager.default.attributesOfItem(atPath: rules.path))?[.modificationDate] as? Date
        if let data = try? Data(contentsOf: rules, options: .mappedIfSafe) {
            let text = String(decoding: data, as: UTF8.self)
            info.ruleCount = text.components(separatedBy: "\nrule ").count - 1
        }
        return info
    }
}

/// Emplacements où un logiciel malveillant s'installe pour redémarrer avec le Mac : surveillés en temps réel.
public enum PersistenceLocations {
    public static func paths(home: URL) -> [String] {
        [home.appendingPathComponent("Library/LaunchAgents").path, "/Library/LaunchAgents", "/Library/LaunchDaemons"]
    }

    /// Emplacements de l'analyse rapide : persistance, applis et téléchargements.
    public static func quickScan(home: URL) -> [String] {
        paths(home: home) + ["/Applications", home.appendingPathComponent("Applications").path, home.appendingPathComponent("Downloads").path]
    }
}

public struct QuarantinedItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let originalPath: String
    public let rule: String
    public let date: Date
}

/// Quarantaine : le fichier est déplacé hors de son emplacement, privé de ses droits d'exécution, et peut être remis en place.
public enum Quarantine {
    public enum Failure: Error { case refused, missing, occupied }

    public static func folder(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/hdCLEANER/Quarantine")
    }

    /// Fichiers que l'on peut isoler sans mot de passe : dossier personnel ou applis.
    public static func canIsolate(_ path: String, home: URL) -> Bool {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standard == path, !path.hasPrefix(folder(home: home).path + "/") else { return false }
        return PathGuard.isSafe(path, home: home) || PathGuard.isSafeDroppedApp(path, home: home)
    }

    @discardableResult
    public static func add(_ path: String, rule: String, home: URL) throws -> QuarantinedItem {
        guard canIsolate(path, home: home) else { throw Failure.refused }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw Failure.missing }
        let id = UUID().uuidString
        let dir = folder(home: home).appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let item = QuarantinedItem(id: id, originalPath: path, rule: rule, date: Date())
        do {
            try fm.moveItem(atPath: path, toPath: dir.appendingPathComponent("payload").path)
        } catch {
            try? fm.removeItem(at: dir)
            throw Failure.refused
        }
        neutralize(dir.appendingPathComponent("payload"))
        try JSONEncoder().encode(item).write(to: dir.appendingPathComponent("info.json"))
        return item
    }

    /// Retire les droits d'exécution de tout ce que contient l'élément isolé.
    private static func neutralize(_ url: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        try? fm.setAttributes([.posixPermissions: isDir.boolValue ? 0o700 : 0o600], ofItemAtPath: url.path)
        if isDir.boolValue {
            for child in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] { neutralize(child) }
        }
    }

    public static func list(home: URL) -> [QuarantinedItem] {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        let items = ((try? fm.contentsOfDirectory(at: folder(home: home), includingPropertiesForKeys: nil)) ?? []).compactMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("info.json"))).flatMap { try? decoder.decode(QuarantinedItem.self, from: $0) }
        }
        return items.sorted { $0.date > $1.date }
    }

    /// Remet l'élément à sa place d'origine ; refuse d'écraser un fichier qui l'occuperait.
    public static func restore(_ item: QuarantinedItem, home: URL) throws {
        let fm = FileManager.default
        let dir = folder(home: home).appendingPathComponent(item.id)
        let payload = dir.appendingPathComponent("payload")
        guard fm.fileExists(atPath: payload.path) else { throw Failure.missing }
        guard !fm.fileExists(atPath: item.originalPath) else { throw Failure.occupied }
        guard canIsolate(item.originalPath, home: home) else { throw Failure.refused }
        try fm.createDirectory(at: URL(fileURLWithPath: item.originalPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: payload, to: URL(fileURLWithPath: item.originalPath))
        try? fm.removeItem(at: dir)
    }

    /// Supprime définitivement la copie isolée (le seul endroit où l'appli efface sans Corbeille : son propre dossier de quarantaine).
    public static func delete(_ item: QuarantinedItem, home: URL) {
        let dir = folder(home: home).appendingPathComponent(item.id)
        guard dir.standardizedFileURL.path.hasPrefix(folder(home: home).standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
