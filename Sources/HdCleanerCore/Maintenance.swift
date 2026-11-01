import Foundation

/// Scripts d'entretien : chacun est un court script shell, avec ou sans mot de passe administrateur.
public enum MaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case flushDNS, reindexSpotlight, rebuildLaunchServices, periodicScripts, repairHomePermissions, verifyStartupDisk

    public var id: String { rawValue }
    public var title: String { L("maintenance.\(rawValue)") }
    public var help: String { L("maintenanceHelp.\(rawValue)") }

    public var needsAdmin: Bool {
        switch self {
        case .flushDNS, .reindexSpotlight, .periodicScripts, .repairHomePermissions: true
        case .rebuildLaunchServices, .verifyStartupDisk: false
        }
    }

    /// `uid` : l'utilisateur dont on répare les permissions (le script tourne en root quand il demande le mot de passe).
    public func script(uid: UInt32) -> String {
        switch self {
        case .flushDNS:
            "/usr/bin/dscacheutil -flushcache\n/usr/bin/killall -HUP mDNSResponder\necho OK\n"
        case .reindexSpotlight:
            "/usr/bin/mdutil -E /\n"
        case .rebuildLaunchServices:
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user\necho OK\n"
        case .periodicScripts:
            "/usr/sbin/periodic daily weekly monthly\necho OK\n"
        case .repairHomePermissions:
            "/usr/sbin/diskutil resetUserPermissions / \(uid)\n"
        case .verifyStartupDisk:
            "/usr/sbin/diskutil verifyVolume /\n"
        }
    }
}
