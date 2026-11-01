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
        XCTAssertEqual(Set(Scanner.order), Set(JunkCategory.allCases))
    }
}
