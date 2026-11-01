import Foundation

/// Une seule instance : l'app ouverte à la main et l'agent d'ouverture de session sont le même programme, et chacun posait son icône.
/// Le premier lancement garde un verrou sur un fichier ; un second lancement demande au premier d'afficher sa fenêtre, puis s'arrête.
enum SingleInstance {
    static let showWindow = Notification.Name("com.stephan.hdcleaner.showWindow")
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        #if HDCLEANER_SELFTEST
        return true // les essais pilotent leur propre instance, à côté de l'appli installée
        #else
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/hdCLEANER")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true } // pas de verrou possible : mieux vaut deux icônes qu'une appli qui ne s'ouvre pas
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd // gardé ouvert jusqu'à la fin du processus : le système relâche le verrou même après un plantage
        return true
        #endif
    }

    /// Demande à l'instance déjà lancée d'ouvrir sa fenêtre.
    static func askRunningInstanceToShowWindow() {
        DistributedNotificationCenter.default().postNotificationName(showWindow, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
