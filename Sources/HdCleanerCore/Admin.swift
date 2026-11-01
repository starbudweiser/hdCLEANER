import Foundation

/// Opérations qui demandent le mot de passe administrateur : le script est construit ici, exécuté par l'appli.
public enum AdminScript {
    /// Date d'un instantané Time Machine local, telle que `tmutil` la donne (AAAA-MM-JJ-HHMMSS).
    public static func isSnapshotDate(_ text: String) -> Bool {
        text.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil
    }

    /// « com.apple.TimeMachine.2026-11-01-120000.local » → « 2026-11-01-120000 » ; une ligne qui n'en est pas un est ignorée.
    public static func parseSnapshots(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ".").map(String.init)
            return parts.first(where: isSnapshotDate)
        }
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func build(removing paths: [String], snapshots: [String]) -> String {
        var lines = ["#!/bin/sh"]
        lines += paths.map { "/bin/rm -rf -- \(quote($0))" }
        lines += snapshots.filter(isSnapshotDate).map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }
}
