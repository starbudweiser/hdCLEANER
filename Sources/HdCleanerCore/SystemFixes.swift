import Foundation

// Corrections système : menu « Ouvrir avec » (base Launch Services), extensions, services, caches, disque occupé, quarantaine.
// Aucun fichier n'est supprimé ici sans garde-fou ; tout ce qui touche au système est construit en commandes que l'appli exécute.

/// Chemins des outils système (injectables dans les tests par les fonctions pures plus bas).
public enum SystemTools {
    public static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    public static let pbs = "/System/Library/CoreServices/pbs"
}

// MARK: - Launch Services (« Ouvrir avec »)

public enum LSRegistry {
    public enum Reason: String, Sendable { case missing, cache, build, temporary, trash, duplicate, droplet, devBuild }

    public struct Finding: Identifiable, Hashable, Sendable {
        public var id: String { path }
        public let path: String
        public let reason: Reason
        public let bundleID: String?
        public let version: String?
        /// Pour un doublon : l'exemplaire conservé.
        public let keeping: String?
        public init(path: String, reason: Reason, bundleID: String?, version: String?, keeping: String?) {
            self.path = path; self.reason = reason; self.bundleID = bundleID; self.version = version; self.keeping = keeping
        }
    }

    public struct Diagnosis: Sendable {
        public var stale: [Finding] = []
        public var duplicates: [Finding] = []
        public var droplets: [Finding] = []
        /// Versions de développement (identifiant en « .dev » / « .test ») dont l'appli installée existe.
        public var devBuilds: [Finding] = []
        /// Groupes d'un même identifiant laissés tels quels (versions qui cohabitent).
        public var keptGroups: [(bundleID: String, paths: [String])] = []
        public init() {}
        public var total: Int { stale.count + duplicates.count + droplets.count + devBuilds.count }
        public var missingCount: Int { stale.filter { $0.reason == .missing }.count }
        public var cacheCount: Int { stale.filter { $0.reason != .missing }.count }
    }

    /// Ce que l'on lit dans `Contents/Info.plist` d'une application.
    public struct BundleInfo: Sendable {
        public var bundleID: String?
        public var version: String?
        public var documentTypeCount = 0
        public var signature: String?
        public var executable: String?
        public init(bundleID: String? = nil, version: String? = nil, documentTypeCount: Int = 0, signature: String? = nil, executable: String? = nil) {
            self.bundleID = bundleID; self.version = version; self.documentTypeCount = documentTypeCount; self.signature = signature; self.executable = executable
        }
    }

    /// Ce dont l'analyse a besoin ; remplaçable dans les tests.
    public struct Context: Sendable {
        public var home: String
        public var exists: @Sendable (String) -> Bool
        public var info: @Sendable (String) -> BundleInfo?
        public var modified: @Sendable (String) -> Date
        /// Volumes montés (`/Volumes/<nom>`).
        public var mountedVolumes: Set<String>
        public init(home: String, exists: @escaping @Sendable (String) -> Bool, info: @escaping @Sendable (String) -> BundleInfo?, modified: @escaping @Sendable (String) -> Date = { _ in .distantPast }, mountedVolumes: Set<String>) {
            self.home = home; self.exists = exists; self.info = info; self.modified = modified; self.mountedVolumes = mountedVolumes
        }

        public static func live(home: URL) -> Context {
            let volumes = Set((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []).map { "/Volumes/" + $0 }
            return Context(home: home.standardizedFileURL.path,
                           exists: { FileManager.default.fileExists(atPath: $0) },
                           info: { readInfo($0) },
                           modified: { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast },
                           mountedVolumes: Set(volumes))
        }
    }

    public static func readInfo(_ appPath: String) -> BundleInfo? {
        guard let data = FileManager.default.contents(atPath: appPath + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let types = (plist["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
        let count = types.reduce(0) { $0 + ((($1["LSItemContentTypes"] as? [String])?.count) ?? 0) + ((($1["CFBundleTypeExtensions"] as? [String])?.count) ?? 0) }
        return BundleInfo(bundleID: plist["CFBundleIdentifier"] as? String, version: plist["CFBundleShortVersionString"] as? String,
                          documentTypeCount: count, signature: plist["CFBundleSignature"] as? String, executable: plist["CFBundleExecutable"] as? String)
    }

    /// Chemins `path:` d'un `lsregister -dump` (le suffixe « (0x…) » est retiré).
    public static func parseDump(_ text: String) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for line in text.split(separator: "\n") where line.hasPrefix("path:") {
            var p = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let r = p.range(of: #" \(0x[0-9a-fA-F]+\)$"#, options: .regularExpression) { p.removeSubrange(r) }
            if p.hasSuffix(".app"), seen.insert(p).inserted { result.append(p) }
        }
        return result
    }

    static func location(of path: String, home: String) -> Reason? {
        if path.contains("/.Trash/") || path.contains("/.Trashes/") { return .trash }
        if path.contains("/DerivedData/") { return .build }
        if path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") || path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/") { return .temporary }
        if path.contains("/Library/Caches/") { return .cache }
        return nil
    }

    /// « Installé » : dans /Applications ou ~/Applications (à n'importe quelle profondeur), hors dossiers de développement.
    static func isInstalledLocation(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") else { return false }
        return !["/dist/", "/build/", "/Build/Products/", "/notarized/", "/Test/"].contains { path.contains($0) }
    }

    /// Application à l'intérieur d'une autre application (assistant, outil de plantage, désinstalleur) ou gérée par un éditeur dans /Library : jamais proposée.
    static func isIgnored(_ path: String) -> Bool {
        let inner = path.dropLast(4)
        return inner.contains(".app/") || path.hasPrefix("/Library/") || path.hasPrefix("/opt/") || path.hasPrefix("/usr/") || path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/")
    }

    static func versionKey(_ v: String?) -> [Int] { (v ?? "").split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
    static func isNewer(_ a: String?, than b: String?) -> Bool { versionKey(a).lexicographicallyPrecedes(versionKey(b)) == false && versionKey(a) != versionKey(b) }

    /// Un droplet : paquet signé « dplt » ou exécutable « droplet », qui déclare un grand nombre de formats (il s'ajoute à « Ouvrir avec » pour chacun).
    /// « fr.stephan.mfonts.dev » → « fr.stephan.mfonts » ; nil si l'identifiant n'est pas celui d'une version de développement.
    static func devBase(of id: String) -> String? {
        for suffix in [".dev", ".test", ".debug", ".beta-dev"] where id.hasSuffix(suffix) && id.count > suffix.count { return String(id.dropLast(suffix.count)) }
        return nil
    }

    public static func isDroplet(_ info: BundleInfo, path: String, home: String) -> Bool {
        (info.signature == "dplt" || info.executable == "droplet") && info.documentTypeCount >= 20
    }

    public static func diagnose(paths: [String], context c: Context) -> Diagnosis {
        var d = Diagnosis()
        var byID: [String: [(path: String, info: BundleInfo)]] = [:]
        var devCandidates: [(path: String, info: BundleInfo, base: String)] = []
        for path in paths {
            // Disque non monté : on n'y touche pas. Système : jamais.
            if path.hasPrefix("/Volumes/") {
                let parts = path.split(separator: "/")
                if parts.count > 1, !c.mountedVolumes.contains("/Volumes/" + parts[1]) { continue }
            }
            if isIgnored(path) { continue }
            if let reason = location(of: path, home: c.home) {
                d.stale.append(Finding(path: path, reason: reason, bundleID: nil, version: nil, keeping: nil)); continue
            }
            guard c.exists(path) else {
                d.stale.append(Finding(path: path, reason: .missing, bundleID: nil, version: nil, keeping: nil)); continue
            }
            guard let info = c.info(path) else { continue }
            if isDroplet(info, path: path, home: c.home) {
                d.droplets.append(Finding(path: path, reason: .droplet, bundleID: info.bundleID, version: info.version, keeping: nil)); continue
            }
            if let id = info.bundleID, !id.hasPrefix("com.apple.") { byID[id, default: []].append((path, info)) }
            if let id = info.bundleID, let base = devBase(of: id) { devCandidates.append((path, info, base)) }
        }
        for dev in devCandidates where !isInstalledLocation(dev.path, home: c.home) {
            if let installed = byID[dev.base]?.first(where: { isInstalledLocation($0.path, home: c.home) }) {
                d.devBuilds.append(Finding(path: dev.path, reason: .devBuild, bundleID: dev.info.bundleID, version: dev.info.version, keeping: installed.path))
            }
        }
        let devPaths = Set(d.devBuilds.map(\.path))
        byID = byID.mapValues { $0.filter { !devPaths.contains($0.path) } }
        for (id, list) in byID.sorted(by: { $0.key < $1.key }) where list.count > 1 {
            let installed = list.filter { isInstalledLocation($0.path, home: c.home) }
            if !installed.isEmpty {
                // Les copies installées ne sont jamais retirées (Python, Cinema 4D…) ; les autres sont des doublons.
                let keep = installed.sorted { c.modified($0.path) > c.modified($1.path) }[0].path
                for item in list where !isInstalledLocation(item.path, home: c.home) {
                    d.duplicates.append(Finding(path: item.path, reason: .duplicate, bundleID: id, version: item.info.version, keeping: keep))
                }
                if installed.count > 1 { d.keptGroups.append((id, installed.map(\.path))) }
            } else {
                // Aucune copie installée : on ne retire rien (versions d'un moteur comme Unreal, outils d'un éditeur) ; on signale seulement la cohabitation.
                d.keptGroups.append((id, list.map(\.path)))
            }
        }
        d.stale.sort { ($0.reason.rawValue, $0.path) < ($1.reason.rawValue, $1.path) }
        d.duplicates.sort { ($0.bundleID ?? "", $0.path) < ($1.bundleID ?? "", $1.path) }
        d.droplets.sort { $0.path < $1.path }
        d.devBuilds.sort { $0.path < $1.path }
        return d
    }

    private static func q(_ s: String) -> String { AdminScript.quote(s) }

    /// Script : désenregistre les chemins demandés (rien n'est supprimé), puis ramasse-miettes. Les chemins non retenus par le garde-fou sont ignorés.
    public static func unregisterScript(_ paths: [String]) -> String {
        var lines = ["#!/bin/sh", "LS=\(q(SystemTools.lsregister))"]
        lines += paths.filter { $0.hasSuffix(".app") && !$0.hasPrefix("/System/") && !$0.contains("\n") }.map { "\"$LS\" -u \(q($0)) 2>/dev/null" }
        lines.append("\"$LS\" -gc 2>/dev/null")
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Script d'annulation : réenregistre ceux qui existent encore.
    public static func reregisterScript(_ paths: [String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        var lines = ["#!/bin/sh", "LS=\(q(SystemTools.lsregister))"]
        lines += paths.filter { $0.hasSuffix(".app") && exists($0) }.map { "\"$LS\" -f \(q($0)) 2>/dev/null" }
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Extensions (pluginkit)

public enum ExtensionKind: String, CaseIterable, Sendable { case share, finder, quickAction
    static func kind(sdk: String) -> ExtensionKind? {
        switch sdk {
        case "com.apple.share-services": .share
        case "com.apple.FinderSync": .finder
        case "com.apple.services", "com.apple.ui-services", "com.apple.finder.quick-action": .quickAction
        default: nil
        }
    }
}

public struct SystemExtension: Identifiable, Hashable, Sendable {
    public var id: String { identifier + "|" + path }
    public let identifier: String
    public let name: String
    public let path: String
    public let kind: ExtensionKind
    /// `+` activée, `-` masquée, sinon par défaut.
    public let elected: Character
    public let parentPath: String
    public init(identifier: String, name: String, path: String, kind: ExtensionKind, elected: Character, parentPath: String) {
        self.identifier = identifier; self.name = name; self.path = path; self.kind = kind; self.elected = elected; self.parentPath = parentPath
    }
    public var enabled: Bool { elected != "-" }
    public var fileMissing: Bool { !FileManager.default.fileExists(atPath: path) }
    public var isApple: Bool { identifier.hasPrefix("com.apple.") }
    public var isDevelopmentCopy: Bool {
        ["/DerivedData/", "/Build/Products/", "/dist/", "/build/"].contains { path.contains($0) } || path.contains("/private/tmp/")
    }
}

public enum PluginKit {
    /// Sortie de `pluginkit -mAvv`.
    public static func parse(_ text: String) -> [SystemExtension] {
        var result: [SystemExtension] = []
        var flag: Character = " ", ident = "", fields: [String: String] = [:]
        func flush() {
            guard !ident.isEmpty, let path = fields["Path"], let sdk = fields["SDK"], let kind = ExtensionKind.kind(sdk: sdk) else { return }
            result.append(SystemExtension(identifier: ident, name: fields["Display Name"] ?? fields["Short Name"] ?? ident, path: path, kind: kind, elected: flag, parentPath: fields["Parent Bundle"] ?? ""))
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
                if parts.count >= 2 { fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts.dropFirst().joined(separator: " = ").trimmingCharacters(in: .whitespaces) }
            } else if let r = line.range(of: #"^[+\-!?= ]\s+[^\s(]+\("#, options: .regularExpression) {
                flush()
                flag = line.first == " " ? " " : line.first!
                var head = String(line[r]).dropFirst().trimmingCharacters(in: .whitespaces)
                head.removeLast() // « ( »
                ident = head
                fields = [:]
            }
        }
        flush()
        return result
    }

    public static func setScript(identifier: String, enabled: Bool) -> String? {
        guard identifier.range(of: #"^[A-Za-z0-9._\-]+$"#, options: .regularExpression) != nil else { return nil }
        return "/usr/bin/pluginkit -e \(enabled ? "use" : "ignore") -i \(identifier)\n"
    }

    /// Retrait d'une extension dont le fichier a disparu, ou d'un exemplaire de développement : seulement hors du système.
    public static func removeScript(path: String) -> String? {
        guard path.hasSuffix(".appex"), !path.hasPrefix("/System/"), !path.hasPrefix("/usr/"), !path.contains("\n") else { return nil }
        return "/usr/bin/pluginkit -r \(AdminScript.quote(path))\n"
    }
}

// MARK: - Services du menu contextuel (pbs)

public struct ServiceEntry: Identifiable, Hashable, Sendable {
    public var id: String { key }
    /// Clé de `NSServicesStatus` : « <bundle> - <menu> - <message> ».
    public let key: String
    public let title: String
    public let owner: String
    public var contextMenu: Bool
    public var servicesMenu: Bool
    public init(key: String, title: String, owner: String, contextMenu: Bool, servicesMenu: Bool) {
        self.key = key; self.title = title; self.owner = owner; self.contextMenu = contextMenu; self.servicesMenu = servicesMenu
    }
}

public enum ServicesPrefs {
    public static let domain = "pbs"
    public static let statusKey = "NSServicesStatus"
    public static let contextKey = "enabled_context_menu"
    public static let menuKey = "enabled_services_menu"

    /// « com.apple.Terminal - New Terminal at Folder - newTerminalAtFolder » → (propriétaire, titre).
    public static func split(key: String) -> (owner: String, title: String) {
        let parts = key.components(separatedBy: " - ")
        guard parts.count >= 3 else { return ("", key) }
        return (parts[0], parts[1])
    }

    /// Fusionne l'état enregistré et les services trouvés dans les dossiers Services.
    public static func entries(status: [String: [String: Bool]], discovered: [String]) -> [ServiceEntry] {
        var keys = Set(status.keys); keys.formUnion(discovered)
        return keys.sorted { split(key: $0).title.localizedCaseInsensitiveCompare(split(key: $1).title) == .orderedAscending }.map { key in
            let st = status[key] ?? [:], s = split(key: key)
            return ServiceEntry(key: key, title: s.title, owner: s.owner == "(null)" ? "" : s.owner, contextMenu: st[contextKey] ?? true, servicesMenu: st[menuKey] ?? true)
        }
    }

    /// Clés construites d'après les `NSServices` des paquets (.service, .workflow).
    public static func discoverKeys(in folders: [String]) -> [String] {
        var keys: [String] = []
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".service") || name.hasSuffix(".workflow") {
                let plistPath = folder + "/" + name + "/Contents/Info.plist"
                guard let data = FileManager.default.contents(atPath: plistPath),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let services = plist["NSServices"] as? [[String: Any]] else { continue }
                let id = (plist["CFBundleIdentifier"] as? String) ?? "(null)"
                for s in services {
                    guard let item = (s["NSMenuItem"] as? [String: String])?["default"], let message = s["NSMessage"] as? String else { continue }
                    keys.append("\(id) - \(item) - \(message)")
                }
            }
        }
        return keys
    }

    public static func readStatus() -> [String: [String: Bool]] {
        guard let raw = CFPreferencesCopyAppValue(statusKey as CFString, domain as CFString) as? [String: Any] else { return [:] }
        return raw.compactMapValues { ($0 as? [String: Any])?.compactMapValues { $0 as? Bool } }
    }

    /// Enregistre l'état complet ; `original` sert à « Rétablir ».
    public static func writeStatus(_ status: [String: [String: Bool]]) {
        CFPreferencesSetAppValue(statusKey as CFString, status as CFDictionary, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    public static func setting(_ status: [String: [String: Bool]], key: String, context: Bool?, menu: Bool?) -> [String: [String: Bool]] {
        var s = status
        var e = s[key] ?? [:]
        if let context { e[contextKey] = context }
        if let menu { e[menuKey] = menu }
        s[key] = e
        return s
    }
}

// MARK: - Caches (Quick Look, icônes) et relance

public enum SystemCaches {
    public struct Item: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public let name: String
        public let paths: [String]
    }

    /// Dossier de cache utilisateur (`getconf DARWIN_USER_CACHE_DIR`).
    public static func userCacheDir() -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        p.arguments = ["DARWIN_USER_CACHE_DIR"]
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let iconNames = ["com.apple.iconservices", "com.apple.iconservices.store", "com.apple.dock.iconcache"]
    public static let quickLookNames = ["com.apple.QuickLook.thumbnailcache"]

    public static func iconPaths(cacheDir: String) -> [String] { iconNames.map { cacheDir + $0 } }
    public static func quickLookPaths(cacheDir: String) -> [String] { quickLookNames.map { cacheDir + $0 } }

    /// Garde-fou : un chemin n'est supprimable que s'il est exactement un des caches connus sous `cacheDir`.
    public static func isSafe(_ path: String, cacheDir: String) -> Bool {
        guard cacheDir.hasPrefix("/var/folders/") || cacheDir.hasPrefix("/private/var/folders/"), cacheDir.hasSuffix("/C/") else { return false }
        return (iconPaths(cacheDir: cacheDir) + quickLookPaths(cacheDir: cacheDir)).contains(path)
    }

    public static func size(of paths: [String]) -> Int64 {
        paths.reduce(0) { $0 + (FileManager.default.fileExists(atPath: $1) ? TreeSizer.size(of: $1) : 0) }
    }

    public static func clearScript(paths: [String], cacheDir: String) -> String {
        var lines = ["#!/bin/sh"]
        lines += paths.filter { isSafe($0, cacheDir: cacheDir) }.map { "/bin/rm -rf -- \(AdminScript.quote($0))" }
        return lines.joined(separator: "\n") + "\n"
    }

    public static let quickLookResetScript = "#!/bin/sh\n/usr/bin/qlmanage -r cache >/dev/null 2>&1\n/usr/bin/qlmanage -r >/dev/null 2>&1\nexit 0\n"
    public static let relaunchScript = "#!/bin/sh\n/usr/bin/killall Finder 2>/dev/null\n/usr/bin/killall Dock 2>/dev/null\nexit 0\n"
}

/// Taille cumulée d'un dossier (sans dépendre de l'analyse complète).
public enum TreeSizer {
    public static func size(of path: String) -> Int64 {
        var total: Int64 = 0
        TreeWalker.walk(path) { entry in
            if !entry.isDirectory { total += entry.allocated }
            return .descend
        }
        return total
    }
}

// MARK: - Disque occupé (lsof)

public struct OpenProcess: Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let command: String
    public let uid: UInt32
    public var fileCount: Int
    public var sample: String
    public init(pid: Int32, command: String, uid: UInt32, fileCount: Int, sample: String) {
        self.pid = pid; self.command = command; self.uid = uid; self.fileCount = fileCount; self.sample = sample
    }
    /// Seuls les processus de l'utilisateur, hors outils système connus, peuvent être quittés.
    public func canQuit(me: UInt32) -> Bool { uid == me && !OpenProcess.systemCommands.contains(command) && pid > 1 }
    public static let systemCommands: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "fseventsd", "launchd", "Finder", "diskarbitrationd", "fskitd", "kernel_task", "cloudd", "revisiond", "backupd", "TimeMachine"]
}

public enum OpenFiles {
    /// Sortie de `lsof -F pcun -- <volume>` : champs p (pid), c (commande), u (uid), n (nom).
    public static func parse(_ text: String) -> [OpenProcess] {
        var byPID: [Int32: OpenProcess] = [:], order: [Int32] = []
        var pid: Int32 = 0, command = "", uid: UInt32 = 0
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0; command = ""; uid = 0
            case "c": command = value
            case "u": uid = UInt32(value) ?? 0
            case "n":
                guard pid > 0 else { continue }
                if var p = byPID[pid] { p.fileCount += 1; byPID[pid] = p }
                else { byPID[pid] = OpenProcess(pid: pid, command: command, uid: uid, fileCount: 1, sample: value); order.append(pid) }
            default: break
            }
        }
        return order.compactMap { byPID[$0] }.sorted { $0.fileCount > $1.fileCount }
    }

    public static func isVolume(_ path: String, volumesRoot: String = "/Volumes") -> Bool {
        let parts = path.split(separator: "/")
        return path.hasPrefix(volumesRoot + "/") && parts.count == volumesRoot.split(separator: "/").count + 1 && !path.contains("..")
    }
}

// MARK: - Quarantaine

public enum QuarantineFix {
    public static let attribute = "com.apple.quarantine"

    /// Seules les applications modifiables par l'utilisateur (dossier personnel, /Applications, volume monté) sont acceptées.
    public static func isAllowed(_ path: String, home: URL, volumesRoot: String = "/Volumes") -> Bool {
        guard path.hasSuffix(".app"), !path.contains(".."), !path.contains("\n"), !path.hasPrefix("/System/"), !path.hasPrefix("/usr/") else { return false }
        return PathGuard.isSafeDroppedApp(path, home: home, volumesRoot: volumesRoot) || path.hasPrefix("/Applications/")
    }

    public static func hasQuarantine(_ path: String) -> Bool { getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }

    /// « 0083;5f…;Safari;UUID » → « Safari ».
    public static func origin(_ path: String) -> String? {
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(path, attribute, &buf, size, 0, XATTR_NOFOLLOW) > 0 else { return nil }
        let parts = String(decoding: buf, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        return parts.count > 2 ? String(parts[2]) : nil
    }

    public static func script(_ path: String) -> String {
        "#!/bin/sh\n/usr/bin/xattr -dr \(attribute) \(AdminScript.quote(path))\n"
    }
}

// MARK: - Associations type de fichier ↔ applications

import UniformTypeIdentifiers

public enum FileAssociations {
    public enum Strength: String, Sendable { case legit, secondary, generic }

    public struct AppEntry: Identifiable, Hashable, Sendable {
        public var id: String { path }
        public let path: String
        public let name: String
        public let bundleID: String
        public let strength: Strength
        public let isDefault: Bool
        public let isSystem: Bool
        public let isDevBuild: Bool
        /// Nombre de types déclarés par l'appli : ce qu'elle perd en étant masquée.
        public let typeCount: Int
        public let role: String
        public init(path: String, name: String, bundleID: String, strength: Strength, isDefault: Bool, isSystem: Bool, isDevBuild: Bool, typeCount: Int, role: String) {
            self.path = path; self.name = name; self.bundleID = bundleID; self.strength = strength; self.isDefault = isDefault; self.isSystem = isSystem; self.isDevBuild = isDevBuild; self.typeCount = typeCount; self.role = role
        }
        /// Retirable : jamais le système, jamais l'appli par défaut.
        public var removable: Bool { !isSystem && !isDefault }
        /// Cochée d'office : ce qui n'est pas un vrai éditeur du type, ni le système, ni l'appli par défaut.
        public var preselected: Bool { removable && (strength != .legit || isDevBuild) }
    }

    public struct Analysis: Sendable {
        public let ext: String
        public let typeID: String
        public let typeName: String
        public var apps: [AppEntry]
        public init(ext: String, typeID: String, typeName: String, apps: [AppEntry]) { self.ext = ext; self.typeID = typeID; self.typeName = typeName; self.apps = apps }
        public var legitCount: Int { apps.filter { $0.strength == .legit }.count }
        public var secondaryCount: Int { apps.filter { $0.strength == .secondary }.count }
        public var genericCount: Int { apps.filter { $0.strength == .generic }.count }
    }

    static let genericTypes: Set<String> = ["public.data", "public.item", "public.content", "public.composite-content"]

    /// Relation d'une appli (son `Info.plist`) avec un type : nil si elle n'en déclare rien.
    public static func classify(plist: [String: Any], ext: String, typeID: String, supertypes: Set<String>) -> (strength: Strength, role: String, typeCount: Int)? {
        let docs = (plist["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
        var best: (rank: Int, strength: Strength, role: String)?
        var total = 0
        for d in docs {
            let ids = (d["LSItemContentTypes"] as? [String]) ?? [], exts = ((d["CFBundleTypeExtensions"] as? [String]) ?? []).map { $0.lowercased() }
            total += ids.count + exts.count
            let role = (d["CFBundleTypeRole"] as? String) ?? "", rank = (d["LSHandlerRank"] as? String) ?? "Default"
            let strongRank = rank == "Owner" || rank == "Default" || role == "Editor"
            var candidate: (Int, Strength)?
            if ids.contains(typeID) || exts.contains(ext.lowercased()) { candidate = (strongRank ? 4 : 3, strongRank ? .legit : .secondary) }
            else if ids.contains(where: { supertypes.contains($0) && !genericTypes.contains($0) }) { candidate = (strongRank ? 2 : 1, strongRank ? .legit : .secondary) }
            else if exts.contains("*") || ids.contains(where: { genericTypes.contains($0) && supertypes.contains($0) }) { candidate = (0, .generic) }
            if let c = candidate, best == nil || c.0 > best!.rank { best = (c.0, c.1, role) }
        }
        guard let b = best else { return nil }
        return (b.strength, b.role, total)
    }

    public static func analyze(ext rawExt: String, appPaths: [String], defaultPath: String?, read: (String) -> [String: Any]? = { path in
        FileManager.default.contents(atPath: path + "/Contents/Info.plist").flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } }) -> Analysis? {
        let ext = rawExt.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        guard !ext.isEmpty, ext.range(of: #"^[a-z0-9_\-+]+$"#, options: .regularExpression) != nil, let type = UTType(filenameExtension: ext) else { return nil }
        let supers = Set(type.supertypes.map(\.identifier))
        var apps: [AppEntry] = []
        for path in appPaths {
            guard let plist = read(path), let rel = classify(plist: plist, ext: ext, typeID: type.identifier, supertypes: supers) else { continue }
            let id = (plist["CFBundleIdentifier"] as? String) ?? ""
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let system = path.hasPrefix("/System/") || id.hasPrefix("com.apple.")
            apps.append(AppEntry(path: path, name: name, bundleID: id, strength: rel.strength, isDefault: path == defaultPath, isSystem: system,
                                 isDevBuild: LSRegistry.devBase(of: id) != nil, typeCount: rel.typeCount, role: rel.role))
        }
        apps.sort { ($0.isDefault ? 0 : 1, $0.strength == .legit ? 0 : 1, $0.name.lowercased()) < ($1.isDefault ? 0 : 1, $1.strength == .legit ? 0 : 1, $1.name.lowercased()) }
        return Analysis(ext: ext, typeID: type.identifier, typeName: type.localizedDescription ?? ext, apps: apps)
    }
}
