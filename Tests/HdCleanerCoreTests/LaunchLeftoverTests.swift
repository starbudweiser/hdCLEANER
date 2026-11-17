import XCTest
@testable import HdCleanerCore

/// Restes d'applis disparues hors des dossiers habituels : agents et services de démarrage, assistants privilégiés.
final class LaunchLeftoverTests: XCTestCase {
    private var home: URL!
    private var sys: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hdcleaner-launch-\(UUID().uuidString)").resolvingSymlinksInPath()
        home = base.appendingPathComponent("home")
        sys = base.appendingPathComponent("sys")
        for dir in [home!, sys!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    @discardableResult
    private func file(_ root: URL, _ relative: String, kb: Int = 4) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: kb * 1024).write(to: url)
        return url
    }

    @discardableResult
    private func plist(_ root: URL, _ relative: String, label: String, program: String, bundleIDs: [String]? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var dict: [String: Any] = ["Label": label, "ProgramArguments": [program, "--flag"]]
        if let bundleIDs { dict["AssociatedBundleIdentifiers"] = bundleIDs }
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        return url
    }

    private func context() -> ScanContext {
        var c = ScanContext(home: home)
        c.systemRoot = sys
        c.installed = ["com.present.app"]
        return c
    }

    func testOrphanLaunchItemsAndHelpers() throws {
        // Agent de l'utilisateur dont le programme a disparu (Overlord, serveur RLM).
        try plist(home, "Library/LaunchAgents/Overlord.plist", label: "Overlord", program: "/Applications/Overlord.app/Contents/MacOS/Overlord")
        // Outil en ligne de commande encore présent : jamais signalé, même sans appli connue.
        try file(sys, "usr/local/bin/tool")
        try plist(home, "Library/LaunchAgents/com.local.tool.plist", label: "com.local.tool", program: "/opt/tool/run")
        try file(sys, "opt/tool/run")
        // Programme sur un disque externe peut-être débranché : jamais signalé.
        try plist(home, "Library/LaunchAgents/com.gone.ext.plist", label: "com.gone.ext", program: "/Volumes/Ext/run")
        // Service système + assistant privilégié d'un éditeur disparu (CleanMyMac).
        try plist(sys, "Library/LaunchDaemons/com.macpaw.CleanMyMac5.Agent.plist", label: "com.macpaw.CleanMyMac5.Agent", program: "/Library/PrivilegedHelperTools/com.macpaw.CleanMyMac5.Agent")
        try file(sys, "Library/PrivilegedHelperTools/com.macpaw.CleanMyMac5.Agent")
        // Service d'une appli présente : gardé.
        try plist(sys, "Library/LaunchDaemons/com.present.app.helper.plist", label: "com.present.app.helper", program: "/Library/PrivilegedHelperTools/com.present.app.helper", bundleIDs: ["com.present.app"])
        try file(sys, "Library/PrivilegedHelperTools/com.present.app.helper")
        // Service Apple : jamais.
        try plist(sys, "Library/LaunchDaemons/com.apple.thing.plist", label: "com.apple.thing", program: "/Library/Gone/thing")
        // Préférences préfixées par l'identifiant d'équipe, dossier système à l'identifiant d'une appli disparue.
        try file(home, "Library/Preferences/S8EX82NJP6.com.macpaw.CleanMyMac5.plist")
        try file(sys, "Library/Application Support/com.gone.vendor.app/data")

        let result = Scanner.scan(context())
        let items = result.items[.leftovers] ?? []
        let found = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.admin) })
        XCTAssertEqual(found[home.appendingPathComponent("Library/LaunchAgents/Overlord.plist").path], false)
        XCTAssertEqual(found[home.appendingPathComponent("Library/Preferences/S8EX82NJP6.com.macpaw.CleanMyMac5.plist").path], false)
        XCTAssertEqual(found[sys.appendingPathComponent("Library/LaunchDaemons/com.macpaw.CleanMyMac5.Agent.plist").path], true)
        XCTAssertEqual(found[sys.appendingPathComponent("Library/PrivilegedHelperTools/com.macpaw.CleanMyMac5.Agent").path], true)
        XCTAssertEqual(found[sys.appendingPathComponent("Library/Application Support/com.gone.vendor.app").path], true)
        XCTAssertEqual(items.count, 5, items.map(\.path).joined(separator: "\n"))
        XCTAssertTrue(items.allSatisfy { !$0.preselected }, "jamais cochés d'office")
        // Le dernier rempart accepte ces chemins système, mais rien d'Apple ni de plus profond.
        for item in items where item.admin { XCTAssertTrue(PathGuard.isSafeAdmin(item.path, home: home, root: sys), item.path) }
        XCTAssertFalse(PathGuard.isSafeAdmin(sys.appendingPathComponent("Library/LaunchDaemons/com.apple.thing.plist").path, home: home, root: sys))
        XCTAssertFalse(PathGuard.isSafeAdmin(sys.appendingPathComponent("Library/Application Support/Apple").path, home: home, root: sys))
        XCTAssertFalse(PathGuard.isSafeAdmin(sys.appendingPathComponent("Library/PrivilegedHelperTools/x/y").path, home: home, root: sys))
    }

    func testCleaningStopsLaunchItemsFirst() throws {
        let agent = try plist(home, "Library/LaunchAgents/Overlord.plist", label: "Overlord", program: "/Applications/Gone.app/x")
        let daemon = try plist(sys, "Library/LaunchDaemons/com.gone.agent.plist", label: "com.gone.agent", program: "/Library/PrivilegedHelperTools/com.gone.agent")
        var unloaded: [String] = []
        var script = ""
        let report = Cleaner.clean([JunkItem(path: agent.path, size: 1, category: .leftovers), JunkItem(path: daemon.path, size: 1, category: .leftovers, admin: true)],
                                   home: home, systemRoot: sys, toTrash: { _ in }, runAdmin: { script = $0; return false }, unloadAgent: { unloaded.append($0) })
        XCTAssertEqual(unloaded, [agent.path])
        XCTAssertTrue(script.contains("/bin/launchctl bootout system '\(daemon.path)'"), script)
        let bootout = script.range(of: "launchctl bootout")!.lowerBound
        let rm = script.range(of: "/bin/rm -rf")!.lowerBound
        XCTAssertLessThan(bootout, rm, "arrêté avant d'être supprimé")
        XCTAssertTrue(report.adminCancelled)
    }

    func testUninstallFindsSystemServicesOfTheApp() throws {
        let app = home.appendingPathComponent("Applications/Tool.app")
        try plist(home, "Library/LaunchAgents/com.vendor.tool.updater.plist", label: "com.vendor.tool.updater", program: app.path + "/Contents/MacOS/updater")
        try plist(sys, "Library/LaunchDaemons/com.vendor.helperd.plist", label: "com.vendor.helperd", program: "/Library/PrivilegedHelperTools/com.vendor.helperd", bundleIDs: ["com.vendor.tool"])
        try file(sys, "Library/PrivilegedHelperTools/com.vendor.helperd")
        try plist(sys, "Library/LaunchDaemons/com.other.d.plist", label: "com.other.d", program: "/Library/PrivilegedHelperTools/com.other.d")
        try file(sys, "Library/PrivilegedHelperTools/com.other.d")
        try file(home, "Library/Preferences/ABCDE12345.com.vendor.tool.plist")
        let entry = AppEntry(name: "Tool", bundleID: "com.vendor.tool", path: app.path)
        let items = Uninstaller.items(for: entry, home: home, running: false, systemRoot: sys)
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.admin) })
        XCTAssertEqual(byPath[home.appendingPathComponent("Library/LaunchAgents/com.vendor.tool.updater.plist").path], false)
        XCTAssertEqual(byPath[home.appendingPathComponent("Library/Preferences/ABCDE12345.com.vendor.tool.plist").path], false)
        XCTAssertEqual(byPath[sys.appendingPathComponent("Library/LaunchDaemons/com.vendor.helperd.plist").path], true)
        XCTAssertEqual(byPath[sys.appendingPathComponent("Library/PrivilegedHelperTools/com.vendor.helperd").path], true)
        XCTAssertNil(byPath[sys.appendingPathComponent("Library/LaunchDaemons/com.other.d.plist").path])
        XCTAssertNil(byPath[sys.appendingPathComponent("Library/PrivilegedHelperTools/com.other.d").path])
    }
}
