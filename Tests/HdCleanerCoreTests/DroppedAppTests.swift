import XCTest
@testable import HdCleanerCore

final class DroppedAppTests: XCTestCase {
    func testDroppedAppPlaces() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertTrue(PathGuard.isSafeDroppedApp("/Users/test/Downloads/Foo.app", home: home))
        XCTAssertTrue(PathGuard.isSafeDroppedApp("/Applications/Adobe/Foo.app", home: home))
        XCTAssertFalse(PathGuard.isSafeDroppedApp("/System/Applications/Mail.app", home: home))
        XCTAssertFalse(PathGuard.isSafeDroppedApp("/Users/test/Downloads/Foo.app/Contents/Bar.app", home: home))
        XCTAssertFalse(PathGuard.isSafeDroppedApp("/Users/test/Downloads/Foo.txt", home: home))
        XCTAssertFalse(PathGuard.isSafeDroppedApp("/usr/local/Foo.app", home: home))
    }

    func testEntryReadsDroppedBundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("Zed Thing.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.x.zed</string></dict></plist>"
            .write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        // /tmp n'est pas un emplacement permis : refusé ; sous le dossier personnel simulé : accepté.
        XCTAssertNil(Uninstaller.entry(at: dir.appendingPathComponent("Zed Thing.app"), home: URL(fileURLWithPath: "/Users/nobody")))
        let e = Uninstaller.entry(at: dir.appendingPathComponent("Zed Thing.app"), home: dir.deletingLastPathComponent())
        XCTAssertEqual(e?.bundleID, "com.x.zed")
        XCTAssertEqual(e?.name, "Zed Thing")
    }
}
