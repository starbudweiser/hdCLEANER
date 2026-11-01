import Foundation

public enum FlagChange: String, CaseIterable, Sendable {
    case keep, on, off
}

/// Changement par lot de flags BSD, permissions, propriétaire, ACL et attributs étendus.
/// Le plan ne fait que décrire : `script()` produit le shell, `issues(home:)` dit s'il est permis.
public struct PermissionPlan: Equatable, Sendable {
    public enum Scope: String, CaseIterable, Sendable { case all, files, directories }

    public struct Flags: Equatable, Sendable {
        public var hidden = FlagChange.keep
        public var locked = FlagChange.keep      // uchg
        public var noDump = FlagChange.keep      // nodump
        public var opaque = FlagChange.keep
        public var appendOnly = FlagChange.keep  // uappnd
        /// `chflags 0` : retire tous les flags avant le reste.
        public var clearAll = false

        public init() {}

        static let names: [(KeyPath<Flags, FlagChange>, String, String)] = [
            (\.hidden, "hidden", "nohidden"), (\.locked, "uchg", "nouchg"), (\.noDump, "nodump", "dump"),
            (\.opaque, "opaque", "noopaque"), (\.appendOnly, "uappnd", "nouappnd"),
        ]

        var toClear: [String] { Self.names.compactMap { self[keyPath: $0.0] == .off ? $0.2 : nil } }
        var toSet: [String] { Self.names.compactMap { self[keyPath: $0.0] == .on ? $0.1 : nil } }
        public var isEmpty: Bool { !clearAll && toClear.isEmpty && toSet.isEmpty }
    }

    public var targets: [String] = []
    public var recursive = true
    public var scope = Scope.all
    public var flags = Flags()
    /// Octal (« 644 ») ou symbolique (« u+rw,go-w ») ; vide = inchangé.
    public var fileMode = ""
    public var directoryMode = ""
    /// « utilisateur » ou « utilisateur:groupe » ; vide = inchangé.
    public var owner = ""
    public var clearACL = false
    public var clearQuarantine = false
    public var clearAllExtendedAttributes = false

    public init() {}

    var touchesFiles: Bool { scope != .directories }
    var touchesDirectories: Bool { scope != .files }

    public var isEmpty: Bool {
        flags.isEmpty && fileMode.isEmpty && directoryMode.isEmpty && owner.isEmpty && !clearACL && !clearQuarantine && !clearAllExtendedAttributes
    }

    // MARK: Contrôles

    public enum Issue: Equatable, Sendable {
        case noTarget, nothingToDo
        case forbiddenTarget(String)
        case badMode(String)
        case badOwner(String)
        /// Un dossier sans lecture ni accès pour son propriétaire devient inutilisable.
        case unusableDirectoryMode(String)

        public var message: String {
            switch self {
            case .noTarget: L("issue.noTarget")
            case .nothingToDo: L("issue.nothingToDo")
            case .forbiddenTarget(let p): L("issue.forbiddenTarget", p)
            case .badMode(let m): L("issue.badMode", m)
            case .badOwner(let o): L("issue.badOwner", o)
            case .unusableDirectoryMode(let m): L("issue.unusableDirectoryMode", m)
            }
        }
    }

    public func issues(home: URL) -> [Issue] {
        var out: [Issue] = []
        if targets.isEmpty { out.append(.noTarget) }
        if isEmpty { out.append(.nothingToDo) }
        for t in targets where !PermissionGuard.isAllowedTarget(t, home: home) { out.append(.forbiddenTarget(t)) }
        for m in [fileMode, directoryMode] where !m.isEmpty && !ModeSpec.isValid(m) { out.append(.badMode(m)) }
        if !owner.isEmpty && !OwnerSpec.isValid(owner) { out.append(.badOwner(owner)) }
        if !directoryMode.isEmpty, ModeSpec.isValid(directoryMode), !ModeSpec.keepsDirectoryUsable(directoryMode) { out.append(.unusableDirectoryMode(directoryMode)) }
        return out
    }

    // MARK: Script

    private func find(_ target: String, types: String) -> String {
        "/usr/bin/find -x \(AdminScript.quote(target)) \(recursive ? "" : "-maxdepth 0 ")\(types)"
    }

    private var bothTypes: String? {
        switch scope {
        case .all: "\\( -type f -o -type d \\)"
        case .files: "-type f"
        case .directories: "-type d"
        }
    }

    /// Ordre voulu : on lève d'abord les verrous (flags à retirer), on change permissions et propriétaire, on pose les flags à la fin.
    public func script() -> String {
        var lines = ["#!/bin/sh"]
        guard let both = bothTypes else { return "" }
        for target in targets {
            let q = AdminScript.quote(target)
            if flags.clearAll { lines.append("\(find(target, types: both)) -exec /usr/bin/chflags -h 0 {} +") }
            else if !flags.toClear.isEmpty { lines.append("\(find(target, types: both)) -exec /usr/bin/chflags -h \(flags.toClear.joined(separator: ",")) {} +") }
            if !owner.isEmpty { lines.append("\(find(target, types: both)) -exec /usr/sbin/chown -h \(owner) {} +") }
            if !fileMode.isEmpty, touchesFiles { lines.append("\(find(target, types: "-type f")) -exec /bin/chmod \(fileMode) {} +") }
            if !directoryMode.isEmpty, touchesDirectories { lines.append("\(find(target, types: "-type d")) -exec /bin/chmod \(directoryMode) {} +") }
            if clearACL { lines.append("\(find(target, types: both)) -exec /bin/chmod -N {} +") }
            if clearQuarantine { lines.append("/usr/bin/xattr \(recursive ? "-rd" : "-d") com.apple.quarantine \(q) 2>&1 | /usr/bin/grep -v 'No such xattr'") }
            if clearAllExtendedAttributes { lines.append("/usr/bin/xattr \(recursive ? "-cr" : "-c") \(q)") }
            if !flags.toSet.isEmpty { lines.append("\(find(target, types: both)) -exec /usr/bin/chflags -h \(flags.toSet.joined(separator: ",")) {} +") }
        }
        lines.append("echo FIN")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Aperçu

    public struct Preview: Equatable, Sendable {
        public var files = 0
        public var directories = 0
        public var sample: [String] = []
        public var cancelled = false
        public var total: Int { files + directories }
    }

    /// Compte ce que le plan toucherait (fichiers et dossiers, jamais les liens ni un autre volume), sans rien modifier.
    public func preview(cancel: CancelFlag = CancelFlag(), progress: (Int) -> Void = { _ in }) -> Preview {
        var result = Preview()
        for target in targets {
            if cancel.isCancelled { result.cancelled = true; break }
            TreeWalker.walk(target) { entry in
                if cancel.isCancelled { result.cancelled = true; return .stop }
                if !entry.isSymlink, entry.isDirectory ? touchesDirectories : touchesFiles {
                    if entry.isDirectory { result.directories += 1 } else { result.files += 1 }
                    if result.sample.count < 12 { result.sample.append(entry.path) }
                    if result.total % 500 == 0 { progress(result.total) }
                }
                return recursive ? .descend : .stop
            }
        }
        progress(result.total)
        return result
    }
}

public enum ModeSpec {
    public static func isValid(_ text: String) -> Bool {
        text.range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) != nil
            || text.range(of: #"^[ugoa]*[-+=][rwxXst]*(,[ugoa]*[-+=][rwxXst]*)*$"#, options: .regularExpression) != nil
    }

    /// Octal : le propriétaire garde lecture et accès (r-x). Symbolique : on ne juge pas, `chmod` fait foi.
    public static func keepsDirectoryUsable(_ text: String) -> Bool {
        guard text.range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) != nil, let value = Int(text, radix: 8) else { return true }
        return value & 0o500 == 0o500
    }
}

public enum OwnerSpec {
    public static func isValid(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]*)?$"#, options: .regularExpression) != nil
    }
}

/// Cibles permises : jamais le système ni la racine d'un dossier partagé ; le dossier personnel et les volumes de données, oui.
public enum PermissionGuard {
    static let forbiddenRoots: Set<String> = ["/", "/Library", "/Applications", "/Users", "/Volumes", "/Network", "/home", "/opt", "/usr/local"]
    static let forbiddenTrees = ["/System", "/bin", "/sbin", "/usr", "/dev", "/cores", "/private", "/etc", "/var", "/tmp"]

    public static func isAllowedTarget(_ path: String, home: URL) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix("/"), !resolved.contains("/../") else { return false }
        if forbiddenRoots.contains(resolved) { return false }
        if resolved == "/usr/local" || resolved.hasPrefix("/usr/local/") { return true }
        for tree in forbiddenTrees where resolved == tree || resolved.hasPrefix(tree + "/") { return false }
        // Le dossier personnel lui-même est permis ; /Users/<autre> aussi, mais pas /Users.
        _ = home
        return true
    }
}
