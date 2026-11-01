import XCTest
@testable import HdCleanerCore

final class CoreTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hdcleaner-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func file(_ relative: String, kb: Int = 8) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: kb * 1024).write(to: url)
        return url
    }

    private func paths(_ r: ScanResult, _ c: JunkCategory) -> [String] {
        (r.items[c] ?? []).map { String($0.path.dropFirst(home.path.count + 1)) }.sorted()
    }

    private func context() -> ScanContext {
        var c = ScanContext(home: home)
        c.systemRoot = home // jamais le vrai système dans un essai
        c.largeFileMinimum = 100_000
        return c
    }

    func testAppCachesSkipAppleBrowsersAndProtected() throws {
        try file("Library/Caches/org.videolan.vlc/a")
        try file("Library/Caches/com.apple.Safari/a")
        try file("Library/Caches/com.apple.helpd/a")
        try file("Library/Caches/ms-playwright/chromium")
        try file("Library/Caches/Google/Chrome/a")
        try file("Library/Caches/Google/Other/a")
        try file("Library/Caches/Homebrew/a")
        var c = context()
        c.installed = ["org.videolan.vlc"]
        let r = Scanner.scan(c)
        XCTAssertEqual(paths(r, .appCaches), ["Library/Caches/org.videolan.vlc"])
        XCTAssertEqual(paths(r, .browserData), ["Library/Caches/Google/Chrome", "Library/Caches/com.apple.Safari"])
        XCTAssertEqual(paths(r, .devCaches), ["Library/Caches/Homebrew"])
    }

    func testRunningAppIsMarkedAndNotPreselected() throws {
        try file("Library/Caches/org.videolan.vlc/a")
        try file("Library/Caches/Firefox/a")
        var c = context()
        c.running = ["org.videolan.vlc", "org.mozilla.firefox"]
        let r = Scanner.scan(c)
        XCTAssertTrue(r.all.allSatisfy(\.inUse))
        XCTAssertFalse(r.all.contains(where: \.preselected))
    }

    func testEachPathBelongsToOneCategory() throws {
        try file("Downloads/setup.dmg", kb: 300)
        try file("Downloads/notes.txt")
        try file("Desktop/Capture d’écran 2026.png")
        try file("Desktop/photo.png")
        try file("Documents/film.mov", kb: 300)
        try file("Documents/petit.txt")
        let r = Scanner.scan(context())
        XCTAssertEqual(paths(r, .installers), ["Downloads/setup.dmg"])
        XCTAssertEqual(paths(r, .downloads), ["Downloads/notes.txt"])
        XCTAssertEqual(paths(r, .screenshots), ["Desktop/Capture d’écran 2026.png"])
        XCTAssertEqual(paths(r, .largeFiles), ["Documents/film.mov"])
        XCTAssertEqual(Set(r.all.map(\.path)).count, r.all.count)
    }

    func testLargeFilesSkipLibraryAndHidden() throws {
        try file("Library/big.bin", kb: 300)
        try file(".cache/big.bin", kb: 300)
        try file("code/node_modules/big.bin", kb: 300)
        XCTAssertEqual(paths(Scanner.scan(context()), .largeFiles), [])
    }

    func testExclusionsAreHonoured() throws {
        let kept = try file("Downloads/garde.zip")
        var c = context()
        c.excluded = [kept.path]
        XCTAssertEqual(paths(Scanner.scan(c), .downloads), [])
    }

    func testLeftoversAreConservative() {
        var c = context()
        c.installed = ["com.acme.editor"]
        let vendors: Set<String> = ["com.acme"]
        XCTAssertTrue(Scanner.isLeftover("com.gone.app", context: c, vendors: vendors))
        XCTAssertFalse(Scanner.isLeftover("com.acme.helper", context: c, vendors: vendors), "même éditeur")
        XCTAssertFalse(Scanner.isLeftover("com.apple.mail", context: c, vendors: vendors))
        XCTAssertFalse(Scanner.isLeftover("Adobe", context: c, vendors: vendors), "pas un identifiant")
        XCTAssertFalse(Scanner.isLeftover("My.Folder.Name", context: c, vendors: vendors))
        c.isRegistered = { $0 == "com.other.app" }
        XCTAssertFalse(Scanner.isLeftover("com.other.app.helper", context: c, vendors: vendors), "connue du système")
    }

    func testLeftoverFoldersFound() throws {
        try file("Library/Application Support/com.gone.app/data")
        try file("Library/Preferences/com.gone.app.plist")
        try file("Library/Application Support/Adobe/data")
        let r = Scanner.scan(context())
        XCTAssertEqual(paths(r, .leftovers), ["Library/Application Support/com.gone.app", "Library/Preferences/com.gone.app.plist"])
        XCTAssertFalse(r.all.contains(where: \.preselected))
    }

    func testNoPermissionIsReported() throws {
        let dir = try file("Downloads/a").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertTrue(Scanner.scan(context()).denied.contains(.downloads))
    }

    func testPathGuard() {
        let h = URL(fileURLWithPath: "/Users/x")
        XCTAssertTrue(PathGuard.isSafe("/Users/x/Library/Caches/foo", home: h))
        XCTAssertTrue(PathGuard.isSafe("/Users/x/Downloads/a.zip", home: h))
        for bad in ["/Users/x", "/Users/x/Library", "/Users/x/Library/Caches", "/Users/x/Downloads", "/Users/xy/Downloads/a", "/etc/passwd",
                    "/Users/x/Library/Caches/../Keychains/a", "/Users/x/Library/Keychains/login.keychain-db", "/Users/x/.ssh/id_rsa",
                    "/Users/x/Library/Mobile Documents/foo", "/Users/x/Documents"] {
            XCTAssertFalse(PathGuard.isSafe(bad, home: h), bad)
        }
    }

    func testCleanDeletesRegenerableAndTrashesPersonal() throws {
        let cache = try file("Library/Caches/foo/a").deletingLastPathComponent()
        let doc = try file("Downloads/a.zip")
        var trashed: [URL] = []
        let report = Cleaner.clean([
            JunkItem(path: cache.path, size: 100, category: .appCaches),
            JunkItem(path: doc.path, size: 200, category: .downloads),
            JunkItem(path: "/etc/hosts", size: 300, category: .appCaches),
        ], home: home, toTrash: { trashed.append($0) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(trashed, [doc])
        XCTAssertTrue(FileManager.default.fileExists(atPath: doc.path), "le rappel décide, rien n'est supprimé")
        XCTAssertEqual(report.freed, 100)
        XCTAssertEqual(report.trashed, 200)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report.failures, ["/etc/hosts"])
    }

    func testThresholdNotifiesOncePerCrossing() {
        var m = ThresholdMonitor()
        let total: Int64 = 1000 * 100
        func disk(_ free: Int64) -> DiskInfo { DiskInfo(name: "", total: total, available: free) }
        XCTAssertFalse(m.check(disk(20000), percent: 15))
        XCTAssertTrue(m.check(disk(14000), percent: 15))
        XCTAssertFalse(m.check(disk(13000), percent: 15))
        XCTAssertFalse(m.check(disk(15500), percent: 15), "pas encore réarmé")
        XCTAssertFalse(m.check(disk(14500), percent: 15))
        XCTAssertFalse(m.check(disk(16000), percent: 15))
        XCTAssertTrue(m.check(disk(14000), percent: 15))
    }

    func testSettingsTolerantDecoding() {
        let s = AppSettings.decode(#"{"thresholdPercent": 99, "theme": "?"}"#.data(using: .utf8))
        XCTAssertEqual(s.thresholdPercent, 50)
        XCTAssertEqual(s.theme, .dark)
        XCTAssertEqual(AppSettings.decode(nil), AppSettings())
    }

    func testEveryCategoryHasADisposalAndOnlyRegenerableIsPreselected() {
        for c in JunkCategory.allCases where c.preselected { XCTAssertEqual(c.disposal, .delete, c.rawValue) }
        for c in [JunkCategory.systemCaches, .systemLogs, .snapshots, .languages] { XCTAssertFalse(c.preselected, c.rawValue) }
        XCTAssertEqual(Set(Scanner.order), Set(JunkCategory.allCases))
    }

    // MARK: Système, instantanés, langues, désinstallation

    private func app(_ name: String, id: String, in root: String = "Applications", langs: [String] = [], mas: Bool = false) throws {
        let base = home.appendingPathComponent("\(root)/\(name).app/Contents")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try (["CFBundleIdentifier": id] as NSDictionary).write(to: base.appendingPathComponent("Info.plist"))
        if mas { try FileManager.default.createDirectory(at: base.appendingPathComponent("_MASReceipt"), withIntermediateDirectories: true) }
        for l in langs { try file("\(root)/\(name).app/Contents/Resources/\(l).lproj/Localizable.strings", kb: 40) }
    }

    func testSystemCachesAndLogsAreAdminAndSkipApple() throws {
        for f in ["Library/Caches/com.vendor.tool/a", "Library/Caches/com.apple.bird/a", "Library/Logs/DiagnosticReports/crash.ips", "Library/Logs/Vendor/log.txt",
                  "var/log/system.log", "var/log/system.log.0.gz", "var/log/old.5"] { try file("sys/" + f) }
        var c = context()
        c.systemRoot = home.appendingPathComponent("sys") // distinct de la Bibliothèque de l'utilisateur
        let r = Scanner.scan(c)
        XCTAssertEqual(paths(r, .systemCaches), ["sys/Library/Caches/com.vendor.tool"])
        XCTAssertEqual(paths(r, .systemLogs), ["sys/Library/Logs/DiagnosticReports/crash.ips", "sys/Library/Logs/Vendor", "sys/var/log/old.5", "sys/var/log/system.log.0.gz"])
        XCTAssertTrue((r.items[.systemCaches] ?? []).allSatisfy { $0.disposal == .admin && !$0.preselected })
        XCTAssertTrue(r.items[.appCaches] == nil, "la Bibliothèque de l'utilisateur est vide")
    }

    func testLanguagesKeepWantedSkipAppleAndAppStore() throws {
        try app("Tool", id: "com.vendor.tool", langs: ["en", "fr", "de", "ja", "Base", "zh-Hans", "English"])
        try app("Safari", id: "com.apple.Safari", langs: ["en", "de"])
        try app("Store", id: "com.vendor.store", langs: ["en", "de"], mas: true)
        try app("Only", id: "com.vendor.only", langs: ["fr", "en"])
        var c = context()
        c.keptLanguages = Languages.kept(preferred: ["fr-FR"])
        let r = Scanner.scan(c)
        let items = r.items[.languages] ?? []
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].path, home.appendingPathComponent("Applications/Tool.app").path)
        XCTAssertEqual(items[0].parts.map { ($0 as NSString).lastPathComponent }, ["de.lproj", "ja.lproj", "zh-Hans.lproj"])
        XCTAssertEqual(items[0].size, 3 * 40 * 1024)
    }

    func testLanguageNames() {
        let kept = Languages.kept(preferred: ["fr-FR", "es_ES"])
        XCTAssertEqual(kept, ["en", "fr", "es"])
        for keep in ["en.lproj", "fr_CA.lproj", "Base.lproj", "English.lproj", "French.lproj", "Localizable.lproj", "und.lproj", "es-419.lproj"] { XCTAssertFalse(Languages.isRemovable(keep, kept: kept), keep) }
        for drop in ["de.lproj", "pt_BR.lproj", "German.lproj", "zh-Hant.lproj", "ja.lproj"] { XCTAssertTrue(Languages.isRemovable(drop, kept: kept), drop) }
        XCTAssertFalse(Languages.isRemovable("de", kept: kept))
    }

    func testSnapshotsParsedAndScanned() throws {
        let out = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-01-120000.local\ncom.apple.TimeMachine.2026-10-31-090102.local\nrubbish.line\n"
        XCTAssertEqual(AdminScript.parseSnapshots(out), ["2026-11-01-120000", "2026-10-31-090102"])
        var c = context()
        c.snapshots = { ["2026-11-01-120000", "../etc"] }
        let items = Scanner.scan(c).items[.snapshots] ?? []
        XCTAssertEqual(items.map(\.name), ["2026-11-01-120000"])
        XCTAssertEqual(items[0].disposal, .snapshot)
    }

    func testContainersAndMacInstallers() throws {
        try file("Library/Containers/com.gone.app/Data/x")
        try file("Library/Group Containers/group.com.gone.app/x")
        try file("Library/Group Containers/ABCDE12345.com.gone.app/x")
        try file("Library/Group Containers/UBF8T346G9.Office/x")
        try file("Applications/Install macOS Sequoia.app/Contents/x", kb: 300)
        let r = Scanner.scan(context())
        XCTAssertEqual(paths(r, .leftovers), ["Library/Containers/com.gone.app", "Library/Group Containers/ABCDE12345.com.gone.app", "Library/Group Containers/group.com.gone.app"])
        XCTAssertEqual(paths(r, .installers), ["Applications/Install macOS Sequoia.app"])
        XCTAssertEqual(r.items[.installers]?.first?.disposal, .admin)
    }

    func testAdminGuard() {
        let h = URL(fileURLWithPath: "/Users/x"), root = URL(fileURLWithPath: "/")
        for ok in ["/Library/Caches/com.vendor.tool", "/Library/Logs/Vendor", "/Library/Logs/DiagnosticReports/a.ips", "/var/log/system.log.0.gz",
                   "/Applications/Install macOS Sequoia.app", "/Applications/Tool.app/Contents/Resources/de.lproj", "/Users/x/Applications/Tool.app/Contents/Resources/de.lproj"] {
            XCTAssertTrue(PathGuard.isSafeAdmin(ok, home: h, root: root), ok)
        }
        for bad in ["/", "/Library", "/Library/Caches", "/Library/Caches/com.apple.bird", "/Library/Logs/DiagnosticReports", "/var/log/system.log", "/var/log/sub/x.gz",
                    "/System/Library/Caches/x", "/Applications/Tool.app", "/Applications/Tool.app/Contents/Resources", "/Applications/Tool.app/Contents/MacOS/Tool",
                    "/Applications/Tool.app/Contents/Resources/../MacOS", "/etc/hosts", "/Library/Caches/../Keychains/x", "/Users/x/Library/Caches/foo"] {
            XCTAssertFalse(PathGuard.isSafeAdmin(bad, home: h, root: root), bad)
        }
        XCTAssertTrue(PathGuard.isSafeAppBundle("/Applications/Tool.app", home: h))
        XCTAssertFalse(PathGuard.isSafeAppBundle("/Applications/Utilities/Tool.app", home: h))
        XCTAssertFalse(PathGuard.isSafeAppBundle("/Applications", home: h))
        XCTAssertFalse(PathGuard.isSafeAppBundle("/Applications/.app", home: h))
    }

    func testScriptQuotesAndValidatesSnapshots() {
        let script = AdminScript.build(removing: ["/Library/Caches/it's mine"], snapshots: ["2026-11-01-120000", "x; rm -rf /"])
        XCTAssertTrue(script.contains("/bin/rm -rf -- '/Library/Caches/it'\\''s mine'"))
        XCTAssertTrue(script.contains("tmutil deletelocalsnapshots 2026-11-01-120000"))
        XCTAssertFalse(script.contains("rm -rf /\n"))
        XCTAssertFalse(script.contains("x; rm"))
    }

    func testCleanerRunsAdminOnceAndVerifies() throws {
        let cache = try file("Library/Caches/com.vendor.tool/a").deletingLastPathComponent()
        let item = JunkItem(path: cache.path, size: 500, category: .systemCaches, admin: true)
        let snap = JunkItem(path: JunkItem.snapshotPrefix + "2026-11-01-120000", size: 0, category: .snapshots)
        var scripts: [String] = []
        let ok = Cleaner.clean([item, snap], home: home, systemRoot: home, runAdmin: { script in
            scripts.append(script)
            try? FileManager.default.removeItem(at: cache) // simule le script
            return true
        })
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains(cache.path) && scripts[0].contains("deletelocalsnapshots"))
        XCTAssertEqual(ok.freed, 500)
        XCTAssertEqual(ok.count, 2)
        XCTAssertTrue(ok.failures.isEmpty)

        let other = try file("Library/Caches/com.vendor.two/a").deletingLastPathComponent()
        let refused = Cleaner.clean([JunkItem(path: other.path, size: 5, category: .systemCaches, admin: true)], home: home, systemRoot: home, runAdmin: { _ in false })
        XCTAssertTrue(refused.adminCancelled)
        XCTAssertEqual(refused.failures, [other.path])
        XCTAssertEqual(refused.freed, 0)

        let outside = Cleaner.clean([JunkItem(path: "/etc/hosts", size: 5, category: .systemCaches, admin: true)], home: home, systemRoot: home, runAdmin: { _ in XCTFail("jamais"); return true })
        XCTAssertEqual(outside.failures, ["/etc/hosts"])
    }

    func testUninstallerFindsRelatedFilesAndTrashesThem() throws {
        try app("Tool Pro", id: "com.vendor.toolpro", langs: ["en"])
        try file("Library/Application Support/com.vendor.toolpro/db", kb: 10)
        try file("Library/Application Support/Tool Pro/prefs", kb: 10)
        try file("Library/Preferences/com.vendor.toolpro.plist", kb: 4)
        try file("Library/Preferences/com.vendor.toolpro.helper.plist", kb: 4)
        try file("Library/Containers/com.vendor.toolpro/Data/x", kb: 4)
        try file("Library/Group Containers/group.com.vendor.toolpro/x", kb: 4)
        try file("Library/Caches/com.other.app/x", kb: 4)
        let entries = Uninstaller.listApps(dirs: [home.appendingPathComponent("Applications")])
        XCTAssertEqual(entries.map(\.bundleID), ["com.vendor.toolpro"])
        var entry = entries[0]
        entry.size = DiskSize.bytes(of: URL(fileURLWithPath: entry.path))
        let items = Uninstaller.items(for: entry, home: home, running: false)
        let rel = items.map { String($0.path.dropFirst(home.path.count + 1)) }
        XCTAssertEqual(rel.first, "Applications/Tool Pro.app")
        XCTAssertEqual(Set(rel.dropFirst()), ["Library/Application Support/com.vendor.toolpro", "Library/Application Support/Tool Pro", "Library/Preferences/com.vendor.toolpro.plist",
                                               "Library/Preferences/com.vendor.toolpro.helper.plist", "Library/Containers/com.vendor.toolpro", "Library/Group Containers/group.com.vendor.toolpro"])
        var trashed: [String] = []
        let report = Cleaner.clean(items, home: home, systemRoot: home, toTrash: { trashed.append($0.path) })
        XCTAssertEqual(Set(trashed), Set(items.map(\.path)))
        XCTAssertTrue(report.failures.isEmpty)
    }

    /// Le script produit est du vrai shell : un chemin avec apostrophe et espaces est supprimé, ses voisins restent.
    func testScriptRunsInShell() throws {
        let target = try file("it's a cache/data file")
        let neighbour = try file("keep/me")
        let script = home.appendingPathComponent("run.sh")
        try AdminScript.build(removing: [target.deletingLastPathComponent().path], snapshots: []).write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
    }

    func testMountedVolumesStartWithStartupDisk() {
        let volumes = Volume.mounted()
        XCTAssertEqual(volumes.first?.path, "/")
        XCTAssertFalse(volumes.first?.name.isEmpty ?? true)
        XCTAssertEqual(AppSettings().monitoredVolume, "/")
        XCTAssertEqual(AppSettings.decode(#"{"monitoredVolume": "/Volumes/X"}"#.data(using: .utf8)).monitoredVolume, "/Volumes/X")
    }

    func testMaintenanceScripts() {
        XCTAssertEqual(Set(MaintenanceTask.allCases.map(\.id)).count, MaintenanceTask.allCases.count)
        XCTAssertTrue(MaintenanceTask.repairHomePermissions.script(uid: 501).contains("resetUserPermissions / 501"))
        XCTAssertTrue(MaintenanceTask.flushDNS.needsAdmin)
        XCTAssertFalse(MaintenanceTask.verifyStartupDisk.needsAdmin)
        for t in MaintenanceTask.allCases { XCTAssertTrue(t.script(uid: 501).hasPrefix("/"), t.rawValue) } // commandes en chemin absolu
    }

    func testExcludedFolderExcludesItsContent() throws {
        try file("Library/Caches/org.keep.me/a")
        try file("Downloads/Projet/a.zip")
        try file("Downloads/Projet/sub/b.zip")
        try file("Downloads/autre.zip")
        var c = context()
        c.excluded = [home.appendingPathComponent("Library/Caches/org.keep.me").path, home.appendingPathComponent("Downloads/Projet").path]
        let r = Scanner.scan(c)
        XCTAssertEqual(paths(r, .appCaches), [])
        XCTAssertEqual(paths(r, .downloads), ["Downloads/autre.zip"])
    }

    // MARK: Permissions par lot

    private func runShell(_ script: String) throws -> String {
        let file = home.appendingPathComponent("plan-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [file.path]
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    func testPlanValidation() {
        let h = URL(fileURLWithPath: "/Users/x")
        var plan = PermissionPlan()
        XCTAssertEqual(plan.issues(home: h), [.noTarget, .nothingToDo])
        plan.targets = ["/Volumes/Data/projet"]
        plan.fileMode = "644"
        plan.directoryMode = "755"
        plan.owner = "stephan:staff"
        XCTAssertEqual(plan.issues(home: h), [])
        plan.fileMode = "9x"
        plan.owner = "a b; rm -rf /"
        plan.directoryMode = "644"
        XCTAssertEqual(plan.issues(home: h), [.badMode("9x"), .badOwner("a b; rm -rf /"), .unusableDirectoryMode("644")])
        for ok in ["644", "0755", "u+rw,go-w", "a=rX", "+x"] { XCTAssertTrue(ModeSpec.isValid(ok), ok) }
        for bad in ["", "8", "64", "u+rw; id", "rwx", "$(id)", "755 /"] { XCTAssertFalse(ModeSpec.isValid(bad), bad) }
    }

    func testForbiddenTargets() throws {
        let h = URL(fileURLWithPath: "/Users/stephan")
        for bad in ["/", "/System", "/System/Library", "/usr", "/usr/bin", "/bin", "/sbin", "/private", "/private/etc", "/etc", "/var", "/Library", "/Applications", "/Users", "/Volumes",
                    "/Volumes/Macintosh HD"] {
            XCTAssertFalse(PermissionGuard.isAllowedTarget(bad, home: h), bad)
        }
        for ok in [h.path, "/Users/stephan/Documents", "/Users/autre", "/Volumes/SKYRIM", "/Volumes/SKYRIM/dossier", "/Applications/Tool.app", "/usr/local/bin"] {
            XCTAssertTrue(PermissionGuard.isAllowedTarget(ok, home: h), ok)
        }
    }

    func testPlanScriptOrderAndQuoting() {
        var plan = PermissionPlan()
        plan.targets = ["/Volumes/Data/it's mine"]
        plan.flags.locked = .off
        plan.flags.hidden = .on
        plan.fileMode = "644"
        plan.directoryMode = "755"
        plan.clearQuarantine = true
        let lines = plan.script().split(separator: "\n").map(String.init)
        let unlock = lines.firstIndex { $0.contains("nouchg") }!, chmodFiles = lines.firstIndex { $0.contains("-type f") && $0.contains("chmod 644") }!
        let hide = lines.firstIndex { $0.contains("chflags -h hidden") }!
        XCTAssertLessThan(unlock, chmodFiles)
        XCTAssertLessThan(chmodFiles, hide)
        XCTAssertTrue(plan.script().contains("'/Volumes/Data/it'\\''s mine'"))
        XCTAssertTrue(plan.script().contains("-x"))
        plan.scope = .files
        XCTAssertFalse(plan.script().contains("chmod 755"))
        plan.recursive = false
        XCTAssertTrue(plan.script().contains("-maxdepth 0"))
    }

    func testPlanActuallyChangesModesFlagsAndOnlyWhereAsked() throws {
        let f = try file("proj/a.txt"), g = try file("proj/sub/b.txt"), outside = try file("other/c.txt")
        let dir = f.deletingLastPathComponent(), sub = g.deletingLastPathComponent()
        var plan = PermissionPlan()
        plan.targets = [dir.path]
        plan.fileMode = "600"
        plan.directoryMode = "750"
        plan.flags.hidden = .on
        let out = try runShell(plan.script())
        XCTAssertTrue(out.contains("FIN"), out)
        XCTAssertEqual(try mode(f), 0o600)
        XCTAssertEqual(try mode(g), 0o600)
        XCTAssertEqual(try mode(sub), 0o750)
        XCTAssertEqual(try mode(dir), 0o750)
        XCTAssertEqual(try f.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
        XCTAssertNotEqual(try mode(outside), 0o600, "rien hors de la cible")

        // Verrou puis déverrouillage ; le nom d'un fichier verrouillé ne se supprime plus.
        plan.flags = PermissionPlan.Flags()
        plan.flags.locked = .on
        _ = try runShell(plan.script())
        XCTAssertThrowsError(try FileManager.default.removeItem(at: f))
        plan.flags = PermissionPlan.Flags()
        plan.flags.clearAll = true
        _ = try runShell(plan.script())
        XCTAssertNoThrow(try FileManager.default.removeItem(at: f))
    }

    func testNonRecursivePlanOnlyTouchesTheTarget() throws {
        let f = try file("proj/a.txt"), dir = f.deletingLastPathComponent()
        var plan = PermissionPlan()
        plan.targets = [dir.path]
        plan.recursive = false
        plan.directoryMode = "700"
        plan.fileMode = "600"
        _ = try runShell(plan.script())
        XCTAssertEqual(try mode(dir), 0o700)
        XCTAssertNotEqual(try mode(f), 0o600)
    }

    func testPreviewCountsByScope() throws {
        try file("proj/a.txt"); try file("proj/sub/b.txt"); try file("proj/sub/c.txt")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("proj/link"), withDestinationURL: home.appendingPathComponent("proj/a.txt"))
        var plan = PermissionPlan()
        plan.targets = [home.appendingPathComponent("proj").path]
        var p = plan.preview()
        XCTAssertEqual(p.files, 3)
        XCTAssertEqual(p.directories, 2, "proj et sub ; le lien n'est pas compté")
        plan.scope = .files
        p = plan.preview()
        XCTAssertEqual(p.total, 3)
        plan.recursive = false
        plan.scope = .all
        XCTAssertEqual(plan.preview().total, 1)
        let flag = CancelFlag(); flag.cancel()
        XCTAssertTrue(plan.preview(cancel: flag).cancelled)
    }

    // MARK: Fichiers invisibles

    func testInvisibleClassification() {
        XCTAssertEqual(InvisibleKind.classify(name: ".DS_Store", isDirectory: false, atRoot: false), .dsStore)
        XCTAssertNil(InvisibleKind.classify(name: ".DS_Store", isDirectory: true, atRoot: false))
        XCTAssertEqual(InvisibleKind.classify(name: "._photo.jpg", isDirectory: false, atRoot: false), .appleDouble)
        XCTAssertEqual(InvisibleKind.classify(name: ".AppleDouble", isDirectory: true, atRoot: false), .appleDouble)
        XCTAssertEqual(InvisibleKind.classify(name: "__MACOSX", isDirectory: true, atRoot: false), .macosxFolder)
        XCTAssertEqual(InvisibleKind.classify(name: ".Trashes", isDirectory: true, atRoot: true), .volumeSystem)
        XCTAssertNil(InvisibleKind.classify(name: ".Trashes", isDirectory: true, atRoot: false), "seulement à la racine du volume")
        for keep in [".git", ".ssh", ".zshrc", ".localized", "._", ".gitignore", "Icon\r", ".env"] {
            XCTAssertNil(InvisibleKind.classify(name: keep, isDirectory: false, atRoot: true), keep)
            XCTAssertNil(InvisibleKind.classify(name: keep, isDirectory: true, atRoot: true), keep)
        }
    }

    func testInvisibleScanAndClean() throws {
        try file("vol/a/.DS_Store"); try file("vol/a/._photo.jpg"); try file("vol/a/photo.jpg"); try file("vol/__MACOSX/x/._y")
        try file("vol/.Spotlight-V100/Store-V2/db", kb: 30); try file("vol/b/.TemporaryItems/t"); try file("vol/.gitignore"); try file("vol/.git/config")
        let root = home.appendingPathComponent("vol")
        let scan = InvisibleScanner.scan(roots: [root])
        func rel(_ k: InvisibleKind) -> [String] { (scan.items[k] ?? []).map { String($0.path.dropFirst(root.path.count + 1)) }.sorted() }
        XCTAssertEqual(rel(.dsStore), ["a/.DS_Store"])
        XCTAssertEqual(rel(.appleDouble), ["a/._photo.jpg"], "__MACOSX est compté en bloc, pas fichier par fichier")
        XCTAssertEqual(rel(.macosxFolder), ["__MACOSX"])
        XCTAssertEqual(rel(.tempItems), ["b/.TemporaryItems"])
        XCTAssertEqual(rel(.volumeSystem), [".Spotlight-V100"])
        XCTAssertGreaterThan(scan.total(.volumeSystem), 0)

        // Nettoyage : ce qui est coché part ; le reste, les voisins et les fichiers cachés personnels restent.
        let picked = (scan.items[.dsStore] ?? []) + (scan.items[.appleDouble] ?? []) + (scan.items[.macosxFolder] ?? [])
        let report = Cleaner_like(picked, root)
        XCTAssertEqual(report.count, 3)
        XCTAssertTrue(report.failures.isEmpty)
        for gone in ["vol/a/.DS_Store", "vol/a/._photo.jpg", "vol/__MACOSX"] { XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(gone).path), gone) }
        for kept in ["vol/a/photo.jpg", "vol/.gitignore", "vol/.git/config", "vol/.Spotlight-V100/Store-V2/db", "vol/b/.TemporaryItems/t"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(kept).path), kept)
        }
    }

    private func Cleaner_like(_ items: [InvisibleItem], _ root: URL) -> CleanReport { InvisibleCleaner.clean(items, roots: [root]) }

    func testInvisibleCleanerRefusesForeignOrChangedItems() throws {
        let kept = try file("vol/notes.txt"), ds = try file("vol/.DS_Store")
        let root = home.appendingPathComponent("vol")
        let other = try file("autre/.DS_Store")
        XCTAssertFalse(InvisibleCleaner.isSafe(InvisibleItem(path: kept.path, size: 1, kind: .dsStore, isDirectory: false), roots: [root]), "mauvais nom")
        XCTAssertFalse(InvisibleCleaner.isSafe(InvisibleItem(path: other.path, size: 1, kind: .dsStore, isDirectory: false), roots: [root]), "hors racine")
        XCTAssertFalse(InvisibleCleaner.isSafe(InvisibleItem(path: root.path, size: 1, kind: .dsStore, isDirectory: true), roots: [root]), "la racine elle-même")
        XCTAssertFalse(InvisibleCleaner.isSafe(InvisibleItem(path: ds.path, size: 1, kind: .dsStore, isDirectory: true), roots: [root]), "dossier à la place d'un fichier")
        XCTAssertTrue(InvisibleCleaner.isSafe(InvisibleItem(path: ds.path, size: 1, kind: .dsStore, isDirectory: false), roots: [root]))
    }

    func testVolumeSystemItemsGoThroughAdmin() throws {
        try file("vol/.Trashes/501/x")
        let root = home.appendingPathComponent("vol")
        let items = InvisibleScanner.scan(roots: [root]).items[.volumeSystem] ?? []
        var script = ""
        let refused = InvisibleCleaner.clean(items, roots: [root], runAdmin: { script = $0; return false })
        XCTAssertTrue(refused.adminCancelled)
        XCTAssertTrue(script.contains(".Trashes"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].path))
    }

    func testWatcherReportedPathsOnlyAutoCleanSafeKinds() throws {
        let ds = try file("vol/sub/.DS_Store"), ad = try file("vol/._x"), trashes = try file("vol/.Trashes/501/x").deletingLastPathComponent().deletingLastPathComponent()
        let keep = try file("vol/sub/data.txt"), temp = try file("vol/sub/.TemporaryItems/t").deletingLastPathComponent()
        let root = home.appendingPathComponent("vol")
        let removed = InvisibleCleaner.cleanReported(paths: [ds.path, ad.path, trashes.path, keep.path, temp.path, "/etc/hosts"], roots: [root])
        XCTAssertEqual(Set(removed), [ds.path, ad.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashes.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    // MARK: Icônes personnalisées

    /// Un fichier AppleDouble minimal avec des Finder Info dont le drapeau d'icône personnalisée est (ou non) posé.
    private func appleDouble(customIcon: Bool) -> Data {
        var d = Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]) + Data(count: 16) + Data([0x00, 0x01])
        d += Data([0, 0, 0, 9, 0, 0, 0, 38, 0, 0, 0, 32]) // une entrée : Finder Info (id 9), à l'octet 38, 32 octets
        var info = Data(count: 32)
        if customIcon { info[8] = 0x04 }
        return d + info
    }

    func testAppleDoubleCustomIconFlag() {
        XCTAssertTrue(AppleDouble.hasCustomIcon(appleDouble(customIcon: true)))
        XCTAssertFalse(AppleDouble.hasCustomIcon(appleDouble(customIcon: false)))
        XCTAssertFalse(AppleDouble.hasCustomIcon(Data(count: 8000)))
        XCTAssertFalse(AppleDouble.hasCustomIcon(Data()))
    }

    func testCustomIconsAreKeptByScanAndCleaner() throws {
        let root = home.appendingPathComponent("vol")
        for (name, icon) in [("vol/._dossier", true), ("vol/._vide", false)] {
            let url = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try appleDouble(customIcon: icon).write(to: url)
        }
        try file("vol/Icon\r"); try file("vol/._Icon\r"); try file("vol/.DS_Store")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/.AppleDouble"), withIntermediateDirectories: true)
        try appleDouble(customIcon: true).write(to: root.appendingPathComponent("sub/.AppleDouble/x"))
        let scan = InvisibleScanner.scan(roots: [root])
        XCTAssertEqual((scan.items[.appleDouble] ?? []).map { ($0.path as NSString).lastPathComponent }, ["._vide"])
        XCTAssertEqual(scan.keptCustomIcons, 3, "._dossier, ._Icon\\r et sub/.AppleDouble")
        // Même si un élément « ._dossier » est présenté au nettoyeur, il est refusé.
        let forced = InvisibleItem(path: root.appendingPathComponent("._dossier").path, size: 1, kind: .appleDouble, isDirectory: false)
        XCTAssertFalse(InvisibleCleaner.isSafe(forced, roots: [root]))
        let report = InvisibleCleaner.clean((scan.items[.appleDouble] ?? []) + (scan.items[.dsStore] ?? []) + [forced], roots: [root])
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report.failures.count, 1)
        for kept in ["vol/._dossier", "vol/Icon\r", "vol/._Icon\r", "vol/sub/.AppleDouble/x"] { XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(kept).path), kept) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("vol/._vide").path))
        // La surveillance applique la même règle.
        let again = InvisibleCleaner.cleanReported(paths: [root.appendingPathComponent("._dossier").path], roots: [root])
        XCTAssertEqual(again, [])
    }

    // MARK: Réparation des accès

    func testDiagnoseAndRepairAccess() throws {
        let a = try file("proj/a.txt"), b = try file("proj/sub/b.txt"), c = try file("proj/ok.txt")
        let dir = a.deletingLastPathComponent(), sub = b.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: a.path) // lecture seule
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sub.path) // dossier sans écriture
        XCTAssertEqual(try runShell("/usr/bin/chflags uchg '\(b.path)'\n"), "")
        let before = AccessRepair.diagnose(targets: [dir.path])
        XCTAssertEqual(before.examined, 5, "proj, a, ok, sub, b")
        XCTAssertEqual(before.notOwned, 0)
        XCTAssertEqual(before.locked, 1)
        XCTAssertEqual(before.notUsable, 2, "a.txt et sub")
        XCTAssertEqual(before.problems, 3, "a, sub et b (b est verrouillé et sa mère est en lecture seule)")
        XCTAssertEqual(Set(before.sample), [a.path, sub.path, b.path])
        // Comme si tout appartenait à un autre compte :
        XCTAssertEqual(AccessRepair.diagnose(targets: [dir.path], uid: 0).notOwned, 5)

        let plan = AccessRepair.plan(targets: [dir.path], user: NSUserName())
        XCTAssertEqual(plan.issues(home: URL(fileURLWithPath: "/Users/x")).filter { if case .forbiddenTarget = $0 { return false }; return true }, [])
        let out = try runShell(plan.script())
        XCTAssertTrue(out.contains("FIN"), out)
        let after = AccessRepair.diagnose(targets: [dir.path])
        XCTAssertEqual(after.problems, 0, "\(after)")
        XCTAssertNoThrow(try FileManager.default.removeItem(at: dir), "tout est de nouveau supprimable")
        _ = c
    }

    func testAccessRepairNeverTouchesContentOrOthersRights() throws {
        let f = try file("proj/a.txt")
        try "contenu".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: f.path)
        _ = try runShell(AccessRepair.plan(targets: [f.deletingLastPathComponent().path], user: NSUserName()).script())
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "contenu")
        XCTAssertEqual(try mode(f), 0o640, "u+rw ajoute seulement le droit du propriétaire ; groupe et autres inchangés")
        XCTAssertTrue(AccessRepair.needsAdmin(output: "chown: /x: Operation not permitted"))
        XCTAssertFalse(AccessRepair.needsAdmin(output: "FIN"))
    }
}
