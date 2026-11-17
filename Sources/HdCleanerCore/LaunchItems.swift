import Foundation

/// Agent ou service de démarrage (fichier .plist de LaunchAgents / LaunchDaemons).
public struct LaunchItem: Sendable, Equatable {
    public let plist: String
    public let label: String
    /// Programme lancé (Program, sinon premier élément de ProgramArguments).
    public let program: String?
    /// Applis auxquelles macOS rattache l'élément (AssociatedBundleIdentifiers).
    public let bundleIDs: [String]

    public init(plist: String, label: String, program: String?, bundleIDs: [String] = []) {
        self.plist = plist
        self.label = label
        self.program = program
        self.bundleIDs = bundleIDs
    }

    public static func read(_ url: URL) -> LaunchItem? {
        guard url.pathExtension == "plist", let data = try? Data(contentsOf: url),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let label = dict["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        var ids: [String] = []
        if let one = dict["AssociatedBundleIdentifiers"] as? String { ids = [one] }
        if let many = dict["AssociatedBundleIdentifiers"] as? [String] { ids = many }
        return LaunchItem(plist: url.standardizedFileURL.path, label: label, program: program, bundleIDs: ids)
    }

    /// Tous les éléments lisibles d'un dossier LaunchAgents / LaunchDaemons.
    public static func list(in dir: URL) -> [LaunchItem] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).compactMap(read)
    }
}

public enum LaunchItems {
    static let helperFolder = "/Library/PrivilegedHelperTools/"

    /// Élément d'une appli disparue : son programme n'existe plus, ou c'est l'assistant privilégié d'un éditeur qui n'a plus aucune appli.
    /// Prudent : un programme sur un disque externe (peut-être débranché) ou un outil en ligne de commande encore présent n'est jamais signalé.
    public static func isOrphan(_ item: LaunchItem, context: ScanContext, vendors: Set<String>) -> Bool {
        guard !item.label.hasPrefix("com.apple.") else { return false }
        guard let program = item.program, program.hasPrefix("/"), !program.hasPrefix("/System/"), !program.hasPrefix("/usr/") else { return false }
        if program.hasPrefix("/Volumes/") { return false }
        let local = resolve(program, context: context)
        guard FileManager.default.fileExists(atPath: local) else { return true }
        guard program.hasPrefix(helperFolder) else { return false }
        if !item.bundleIDs.isEmpty { return item.bundleIDs.allSatisfy { Scanner.isLeftover($0, context: context, vendors: vendors) } }
        return Scanner.isLeftover(item.label, context: context, vendors: vendors)
    }

    /// Chemin réel d'un programme : ceux du dossier personnel tels quels, les autres sous la racine système (remplacée dans les tests).
    static func resolve(_ program: String, context: ScanContext) -> String {
        let home = context.home.standardizedFileURL.path
        if program.hasPrefix(home + "/") { return program }
        let root = context.systemRoot.standardizedFileURL.path
        return root == "/" ? program : root + program
    }

    /// Commande qui arrête un élément avant sa suppression : `system` pour LaunchDaemons, la session de l'utilisateur sinon.
    public static func bootoutCommand(for plist: String) -> String? {
        guard plist.hasSuffix(".plist") else { return nil }
        if plist.contains("/Library/LaunchDaemons/") { return "/bin/launchctl bootout system \(AdminScript.quote(plist)) 2>/dev/null" }
        if plist.contains("/Library/LaunchAgents/") { return "/bin/launchctl bootout gui/$(/usr/bin/stat -f %u /dev/console) \(AdminScript.quote(plist)) 2>/dev/null" }
        return nil
    }

    /// Arrête un agent de l'utilisateur (sans mot de passe) avant de le mettre à la Corbeille.
    public static func bootoutUserAgent(_ plist: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())", plist]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}
