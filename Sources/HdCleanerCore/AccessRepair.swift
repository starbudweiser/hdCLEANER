import Darwin
import Foundation

/// Ce qui empêche de supprimer, déplacer ou modifier un élément après une copie ou un déplacement.
public struct AccessDiagnosis: Equatable, Sendable {
    public var examined = 0
    /// Éléments appartenant à un autre utilisateur (souvent root, ou le compte d'une autre machine).
    public var notOwned = 0
    /// Éléments verrouillés (cadenas du Finder : flags uchg ou uappnd).
    public var locked = 0
    /// Fichiers sans écriture pour leur propriétaire, dossiers sans lecture, écriture et accès pour lui.
    public var notUsable = 0
    /// Éléments qui cumulent au moins un de ces défauts.
    public var problems = 0
    public var sample: [String] = []
    public var cancelled = false

    public init() {}
}

public enum AccessRepair {
    static let lockFlags: UInt32 = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)

    /// Examine les cibles (et leur contenu si `recursive`) sans rien modifier. `uid` : le propriétaire attendu (l'utilisateur courant).
    public static func diagnose(targets: [String], recursive: Bool = true, uid: UInt32 = getuid(), cancel: CancelFlag = CancelFlag(), progress: (Int) -> Void = { _ in }) -> AccessDiagnosis {
        var d = AccessDiagnosis()
        for target in targets {
            if cancel.isCancelled { d.cancelled = true; break }
            TreeWalker.walk(target) { entry in
                if cancel.isCancelled { d.cancelled = true; return .stop }
                if !entry.isSymlink {
                    d.examined += 1
                    let notOwned = entry.uid != uid
                    let locked = entry.flags & lockFlags != 0
                    let usable = entry.isDirectory ? entry.mode & 0o700 == 0o700 : entry.mode & 0o600 == 0o600
                    if notOwned { d.notOwned += 1 }
                    if locked { d.locked += 1 }
                    if !usable { d.notUsable += 1 }
                    if notOwned || locked || !usable {
                        d.problems += 1
                        if d.sample.count < 8 { d.sample.append(entry.path) }
                    }
                    if d.examined % 500 == 0 { progress(d.examined) }
                }
                return recursive ? .descend : .stop
            }
        }
        progress(d.examined)
        return d
    }

    /// Le plan de réparation : l'utilisateur devient propriétaire, verrous et ACL tombent, il obtient lecture/écriture (accès complet pour les dossiers).
    /// Les droits des autres utilisateurs ne changent pas et le contenu des fichiers n'est jamais touché.
    public static func plan(targets: [String], user: String, recursive: Bool = true) -> PermissionPlan {
        var p = PermissionPlan()
        p.targets = targets
        p.recursive = recursive
        p.scope = .all
        p.flags.locked = .off
        p.flags.appendOnly = .off
        p.owner = user
        p.clearACL = true
        p.fileMode = "u+rw"
        p.directoryMode = "u+rwx"
        return p
    }

    /// La sortie du script dit-elle que des éléments ont résisté faute de mot de passe administrateur ?
    public static func needsAdmin(output: String) -> Bool {
        output.contains("Operation not permitted") || output.contains("Permission denied")
    }
}
