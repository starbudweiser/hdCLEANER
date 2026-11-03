import XCTest
@testable import HdCleanerCore

final class ToolsCoreTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hdcleaner-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    @discardableResult
    private func file(_ relative: String, fill: UInt8 = 0, kb: Int = 8) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: kb * 1024).write(to: url)
        return url
    }

    private func trash(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    // MARK: Garde-fous

    func testUserFileGuard() {
        XCTAssertTrue(PathGuard.isSafeUserFile(home.path + "/Documents/a.pdf", home: home))
        XCTAssertFalse(PathGuard.isSafeUserFile(home.path + "/Documents", home: home))
        XCTAssertFalse(PathGuard.isSafeUserFile("/System/Library/x", home: home))
        XCTAssertFalse(PathGuard.isSafeUserFile("/Volumes/Macintosh HD/Users/x/a.txt", home: home))
        XCTAssertFalse(PathGuard.isSafeUserFile("/Volumes", home: home))
        let volumes = home.path + "/Volumes"
        XCTAssertTrue(PathGuard.isSafeUserFile(volumes + "/Disk/a.txt", home: URL(fileURLWithPath: "/nonexistent"), volumesRoot: volumes))
        XCTAssertFalse(PathGuard.isSafeUserFile(volumes + "/Disk", home: URL(fileURLWithPath: "/nonexistent"), volumesRoot: volumes))
        XCTAssertFalse(PathGuard.isSafeUserFile(volumes + "/Disk/.Trashes/501/a", home: URL(fileURLWithPath: "/nonexistent"), volumesRoot: volumes))
    }

    // MARK: Doublons

    func testDuplicatesGroupedAndKeepsOldest() throws {
        let a = try file("a/one.bin", fill: 1)
        let b = try file("b/copy.bin", fill: 1)
        try file("c/other.bin", fill: 2)          // même taille, contenu différent
        try file("d/small.bin", fill: 1, kb: 1)   // taille différente
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: a.path)
        try FileManager.default.linkItem(at: a, to: home.appendingPathComponent("e/hard.bin").deletingLastPathComponent().createDir().appendingPathComponent("hard.bin"))
        let scan = DuplicateFinder.scan(roots: [home.path], home: home, minSize: 1_000)
        XCTAssertEqual(scan.groups.count, 1)
        XCTAssertEqual(scan.groups[0].files.count, 2) // le lien physique n'est pas un doublon
        XCTAssertEqual(scan.groups[0].files[0].path, a.path)
        XCTAssertEqual(scan.preselected, [b.path])
        XCTAssertEqual(scan.wasted, 8 * 1024)
    }

    func testDuplicatesSkipPackagesAndSmallFiles() throws {
        try file("x.app/Contents/r.bin", fill: 3)
        try file("y.app/Contents/r.bin", fill: 3)
        try file("p/s1.bin", fill: 4, kb: 1)
        try file("p/s2.bin", fill: 4, kb: 1)
        XCTAssertTrue(DuplicateFinder.scan(roots: [home.path], home: home, minSize: 2_000).groups.isEmpty)
    }

    func testDuplicateCleanerNeverEmptiesAGroup() throws {
        let a = try file("a/one.bin", fill: 1), b = try file("b/copy.bin", fill: 1)
        let group = DuplicateGroup(digest: "g", size: 8 * 1024, files: [DuplicateFile(path: a.path, modified: .distantPast), DuplicateFile(path: b.path, modified: .now)])
        let all = DuplicateCleaner.clean([a.path, b.path], groups: [group], home: home, toTrash: trash)
        XCTAssertEqual(all.count, 0)
        XCTAssertEqual(all.failures.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
        let one = DuplicateCleaner.clean([b.path], groups: [group], home: home, toTrash: trash)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.trashed, 8 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testDuplicateCleanerSkipsChangedFile() throws {
        let a = try file("a/one.bin", fill: 1), b = try file("b/copy.bin", fill: 1)
        let group = DuplicateGroup(digest: "g", size: 8 * 1024, files: [DuplicateFile(path: a.path, modified: .distantPast), DuplicateFile(path: b.path, modified: .now)])
        try Data(count: 10).write(to: b) // modifié depuis l'analyse
        let report = DuplicateCleaner.clean([b.path], groups: [group], home: home, toTrash: trash)
        XCTAssertEqual(report.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    // MARK: Carte du disque

    func testTreemapFillsRectangle() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        let rects = Treemap.layout([50, 30, 10, 5, 5], in: rect)
        XCTAssertEqual(rects.count, 5)
        XCTAssertEqual(rects.reduce(0) { $0 + $1.width * $1.height }, rect.width * rect.height, accuracy: 1)
        for r in rects { XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(r)) }
        XCTAssertGreaterThan(rects[0].width * rects[0].height, rects[1].width * rects[1].height)
        XCTAssertEqual(Treemap.layout([], in: rect), [])
        XCTAssertEqual(Treemap.layout([0, 0], in: rect), [.zero, .zero])
    }

    func testDiskMapAggregatesSizes() throws {
        try file("big/a.bin", kb: 5_000)
        try file("big/b.bin", kb: 100)
        try file("small/c.bin", kb: 10)
        let root = DiskMapper.scan(root: home.path, foldBelow: 0)
        XCTAssertEqual(root.children.map(\.name), ["big", "small"])
        let big = root.children[0]
        XCTAssertGreaterThan(big.size, 5_000 * 1024)
        XCTAssertEqual(big.children.map(\.name), ["a.bin"]) // b.bin est trop petit pour être listé
        XCTAssertGreaterThan(big.smallFiles, 0)
        XCTAssertGreaterThanOrEqual(root.size, big.size + root.children[1].size)
        XCTAssertEqual(big.children[0].trail.map(\.name), [home.lastPathComponent, "big", "a.bin"])
        let before = root.size, bigSize = big.size
        big.detach()
        XCTAssertEqual(root.children.map(\.name), ["small"])
        XCTAssertEqual(root.size, before - bigSize)
    }

    func testDiskMapFoldsSmallFolders() throws {
        try file("tiny/sub/a.bin", kb: 5_000)
        let root = DiskMapper.scan(root: home.path, foldBelow: 100_000_000)
        XCTAssertFalse(root.children.isEmpty)
        XCTAssertTrue(root.children[0].children.isEmpty)
    }

    // MARK: Organiseur

    func testOrganizerPlanAndApply() throws {
        try file("photo.JPG"); try file("note.pdf"); try file("film.mp4"); try file("data.xyz"); try file(".hidden.jpg"); try file("part.crdownload")
        try file("sub/inner.jpg")
        let plan = Organizer.plan(root: home.path, folderName: { $0.rawValue }, minimumAge: 0)
        XCTAssertEqual(Set(plan.moves.map(\.name)), ["photo.JPG", "note.pdf", "film.mp4"])
        XCTAssertEqual(plan.left, 3)
        // un nom déjà pris n'est jamais écrasé
        try file("images/photo.JPG", fill: 9)
        let (done, failed) = Organizer.apply(plan.moves, root: home.path)
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(done.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path + "/images/photo 2.JPG"))
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("images/photo.JPG")).first, 9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path + "/note.pdf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path + "/sub/inner.jpg")) // sous-dossiers intacts
        // annulation
        XCTAssertEqual(Organizer.undo(done), 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path + "/note.pdf"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path + "/documents"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path + "/images/photo.JPG")) // le fichier d'origine reste
    }

    func testOrganizerSkipsRecentAndMovedFiles() throws {
        try file("fresh.pdf")
        XCTAssertTrue(Organizer.plan(root: home.path, minimumAge: 3_600).moves.isEmpty)
        let plan = Organizer.plan(root: home.path, minimumAge: 0)
        try FileManager.default.removeItem(at: home.appendingPathComponent("fresh.pdf"))
        XCTAssertEqual(Organizer.apply(plan.moves, root: home.path).failed.count, 1)
        // un déplacement dont la source n'est pas dans le dossier choisi est refusé
        let rogue = OrganizerMove(source: "/etc/hosts", destination: home.path + "/x/hosts", kind: .documents, size: 1)
        XCTAssertEqual(Organizer.apply([rogue], root: home.path).failed, ["/etc/hosts"])
    }
}

private extension URL {
    func createDir() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
