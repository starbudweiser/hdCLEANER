import XCTest
@testable import HdCleanerCore

final class SystemFixesTests: XCTestCase {
    private func context(existing: Set<String>, infos: [String: LSRegistry.BundleInfo], volumes: Set<String> = []) -> LSRegistry.Context {
        LSRegistry.Context(home: "/Users/me", exists: { existing.contains($0) }, info: { infos[$0] },
                           modified: { _ in Date(timeIntervalSince1970: 1000) }, mountedVolumes: volumes)
    }

    func testParseDumpStripsSuffixAndKeepsApps() {
        let dump = "path:   /Applications/Foo.app (0x1234)\nname: Foo\npath:   /Applications/Foo.app/Contents/Helper.framework (0x9)\npath: /Applications/Foo.app (0x1234)\n"
        XCTAssertEqual(LSRegistry.parseDump(dump), ["/Applications/Foo.app"])
    }

    func testStaleMissingAndCachePaths() {
        let paths = ["/Users/me/Library/Caches/mSLICE-release/1.0/notarized/mSLICE.app", "/private/tmp/x/T.app", "/Users/me/Library/Developer/Xcode/DerivedData/A/Build/Products/Debug/A.app",
                     "/Users/me/.Trash/Old.app", "/Applications/Gone.app", "/Applications/Here.app"]
        let ctx = context(existing: ["/Applications/Here.app", paths[0]], infos: ["/Applications/Here.app": .init(bundleID: "x.here")])
        let d = LSRegistry.diagnose(paths: paths, context: ctx)
        XCTAssertEqual(d.stale.count, 5)
        XCTAssertEqual(d.missingCount, 1)
        XCTAssertEqual(d.cacheCount, 4)
        XCTAssertFalse(d.stale.contains { $0.path == "/Applications/Here.app" })
    }

    func testUnmountedVolumeIsLeftAlone() {
        let ctx = context(existing: [], infos: [:], volumes: ["/Volumes/Mounted"])
        let d = LSRegistry.diagnose(paths: ["/Volumes/Absent/A.app", "/Volumes/Mounted/B.app"], context: ctx)
        XCTAssertEqual(d.stale.map(\.path), ["/Volumes/Mounted/B.app"])
    }

    func testDuplicateKeepsInstalledCopyAndNeverTouchesInstalledOnes() {
        let inst = "/Applications/mHUB.app", dev = "/Users/me/dev/mHUB/dist/mHUB.app", backup = "/Users/me/Backups/mHUB.app"
        let py1 = "/Applications/Python 3.11/IDLE.app", py2 = "/Applications/Python 3.12/IDLE.app"
        let infos: [String: LSRegistry.BundleInfo] = [inst: .init(bundleID: "m.hub", version: "1.4"), dev: .init(bundleID: "m.hub", version: "1.5"), backup: .init(bundleID: "m.hub", version: "1.3"),
                                                      py1: .init(bundleID: "org.python.IDLE", version: "3.11"), py2: .init(bundleID: "org.python.IDLE", version: "3.12")]
        let d = LSRegistry.diagnose(paths: Array(infos.keys), context: context(existing: Set(infos.keys), infos: infos))
        XCTAssertEqual(Set(d.duplicates.map(\.path)), [dev, backup])
        XCTAssertTrue(d.duplicates.allSatisfy { $0.keeping == inst })
        XCTAssertFalse(d.duplicates.contains { $0.path.contains("Python") })
    }

    func testNoInstalledCopyMeansNothingRemoved() {
        let a = "/Users/Shared/Epic/UE_5.3/Engine/UE.app", b = "/Users/Shared/Epic/UE_5.4/Engine/UE.app", c = "/Users/me/old/UE.app"
        let infos: [String: LSRegistry.BundleInfo] = [a: .init(bundleID: "ue", version: "5.3"), b: .init(bundleID: "ue", version: "5.4"), c: .init(bundleID: "ue", version: "5.4")]
        let d = LSRegistry.diagnose(paths: [a, b, c], context: context(existing: Set(infos.keys), infos: infos))
        XCTAssertTrue(d.duplicates.isEmpty) // aucune copie installée : rien n'est retiré
        XCTAssertEqual(d.keptGroups.count, 1)
    }

    func testDevelopmentBuildsOfInstalledApps() {
        let inst = "/Users/me/Applications/Applications Personnelles/mFONTS.app", dev = "/Volumes/Dev/mFONTS/mFONTS dev.app", orphan = "/Volumes/Dev/x/Other dev.app"
        let infos: [String: LSRegistry.BundleInfo] = [inst: .init(bundleID: "fr.s.mfonts", version: "1.0"), dev: .init(bundleID: "fr.s.mfonts.dev", version: "1.1"), orphan: .init(bundleID: "fr.s.other.dev")]
        let d = LSRegistry.diagnose(paths: Array(infos.keys), context: context(existing: Set(infos.keys), infos: infos, volumes: ["/Volumes/Dev"]))
        XCTAssertEqual(d.devBuilds.map(\.path), [dev]) // l'appli sans version installée n'est pas touchée
        XCTAssertEqual(d.devBuilds.first?.keeping, inst)
        XCTAssertTrue(d.duplicates.isEmpty)
    }

    func testNestedAndLibraryAppsAreIgnored() {
        let nested = "/Applications/Adobe/Premiere.app/Contents/AdobeCrashReport.app", lib = "/Library/Application Support/Adobe/Uninstall/X.app"
        let ctx = context(existing: [], infos: [:])
        XCTAssertEqual(LSRegistry.diagnose(paths: [nested, lib], context: ctx).total, 0)
    }

    func testDropletDetectedAndSystemSkipped() {
        let drop = "/Users/me/Droplets/H264.app"
        let infos: [String: LSRegistry.BundleInfo] = [drop: .init(bundleID: "d.h264", documentTypeCount: 80, executable: "droplet")]
        let d = LSRegistry.diagnose(paths: [drop, "/System/Applications/Safari.app"], context: context(existing: [drop, "/System/Applications/Safari.app"], infos: infos))
        XCTAssertEqual(d.droplets.map(\.path), [drop])
        XCTAssertEqual(d.total, 1)
    }

    func testUnregisterScriptOnlyAppsAndNeverSystem() {
        let s = LSRegistry.unregisterScript(["/Users/me/x it's.app", "/System/Applications/Safari.app", "/etc/passwd"])
        XCTAssertTrue(s.contains("-u '/Users/me/x it'\\''s.app'"))
        XCTAssertFalse(s.contains("Safari"))
        XCTAssertFalse(s.contains("passwd"))
        XCTAssertTrue(s.contains("-gc"))
    }

    func testPluginKitParse() {
        let out = """
        +    com.example.share(1.0)
        \t            Path = /Applications/Ex.app/Contents/PlugIns/Share.appex
        \t             SDK = com.apple.share-services
        \t    Display Name = Ex Share

             com.example.finder(2.0)
        \t            Path = /Users/me/DerivedData/Ex.appex
        \t             SDK = com.apple.FinderSync
        \t    Display Name = Ex Finder

        -    com.example.widget(1.0)
        \t            Path = /Applications/W.app/W.appex
        \t             SDK = com.apple.widgetkit-extension

        """
        let list = PluginKit.parse(out)
        XCTAssertEqual(list.map(\.identifier), ["com.example.share", "com.example.finder"])
        XCTAssertEqual(list[0].kind, .share); XCTAssertTrue(list[0].enabled)
        XCTAssertEqual(list[1].kind, .finder); XCTAssertTrue(list[1].isDevelopmentCopy)
        XCTAssertNil(PluginKit.removeScript(path: "/System/Library/X.appex"))
        XCTAssertNotNil(PluginKit.removeScript(path: "/Users/me/X.appex"))
        XCTAssertNil(PluginKit.setScript(identifier: "a; rm -rf /", enabled: false))
    }

    func testServiceKeysAndSetting() {
        XCTAssertEqual(ServicesPrefs.split(key: "com.apple.Terminal - New Terminal at Folder - newTerminalAtFolder").title, "New Terminal at Folder")
        let status = ServicesPrefs.setting([:], key: "a - T - m", context: false, menu: nil)
        let entries = ServicesPrefs.entries(status: status, discovered: ["b - U - n"])
        XCTAssertEqual(entries.first { $0.key == "a - T - m" }?.contextMenu, false)
        XCTAssertEqual(entries.first { $0.key == "b - U - n" }?.contextMenu, true)
    }

    func testCacheGuardOnlyKnownPaths() {
        let dir = "/var/folders/ab/xyz/C/"
        XCTAssertTrue(SystemCaches.isSafe(dir + "com.apple.iconservices", cacheDir: dir))
        XCTAssertFalse(SystemCaches.isSafe(dir + "com.apple.Safari", cacheDir: dir))
        XCTAssertFalse(SystemCaches.isSafe("/Users/me/Documents", cacheDir: dir))
        XCTAssertFalse(SystemCaches.isSafe("/etc/com.apple.iconservices", cacheDir: "/etc/"))
        XCTAssertEqual(SystemCaches.clearScript(paths: ["/Users/me/Documents"], cacheDir: dir), "#!/bin/sh\n")
    }

    func testLsofParseAndRules() {
        let out = "p100\ncAdobe Media Encoder\nu501\nn/Volumes/SSD/a.mov\nn/Volumes/SSD/b.mov\np55\ncmds\nu0\nn/Volumes/SSD/.x\n"
        let list = OpenFiles.parse(out)
        XCTAssertEqual(list.map(\.pid), [100, 55])
        XCTAssertEqual(list[0].fileCount, 2)
        XCTAssertTrue(list[0].canQuit(me: 501))
        XCTAssertFalse(list[1].canQuit(me: 501))
        XCTAssertTrue(OpenFiles.isVolume("/Volumes/SSD")); XCTAssertFalse(OpenFiles.isVolume("/Volumes/SSD/sub")); XCTAssertFalse(OpenFiles.isVolume("/Users/me"))
    }

    func testQuarantineGuard() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertTrue(QuarantineFix.isAllowed("/Applications/Foo.app", home: home))
        XCTAssertTrue(QuarantineFix.isAllowed("/Users/me/Downloads/Foo.app", home: home))
        XCTAssertFalse(QuarantineFix.isAllowed("/System/Applications/Safari.app", home: home))
        XCTAssertFalse(QuarantineFix.isAllowed("/Users/me/Downloads/Foo.txt", home: home))
        XCTAssertTrue(QuarantineFix.script("/Users/me/it's.app").contains("'/Users/me/it'\\''s.app'"))
    }
}

final class MaintenanceScriptTests: XCTestCase {
    func testRebuildLaunchServicesDoesNotUseRemovedKillOption() {
        let script = MaintenanceTask.rebuildLaunchServices.script(uid: 501)
        XCTAssertFalse(script.contains("-kill"))
        XCTAssertTrue(script.contains("-gc") && script.contains("-apps system,local,user") && script.hasPrefix("/"))
    }
}

final class FileAssociationsTests: XCTestCase {
    private func plist(types: [[String: Any]]) -> [String: Any] { ["CFBundleDocumentTypes": types, "CFBundleIdentifier": "x.app"] }

    func testExactSecondaryAndGeneric() {
        let supers: Set<String> = ["public.data", "public.item", "public.content", "public.composite-content"]
        let editor = plist(types: [["CFBundleTypeExtensions": ["pdf"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Default"]])
        let viewerAlt = plist(types: [["CFBundleTypeExtensions": ["psd", "pdf", "ai"], "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate"]])
        let generic = plist(types: [["LSItemContentTypes": ["public.data"], "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate"]])
        let unrelated = plist(types: [["CFBundleTypeExtensions": ["mp3"], "CFBundleTypeRole": "Viewer"]])
        XCTAssertEqual(FileAssociations.classify(plist: editor, ext: "pdf", typeID: "com.adobe.pdf", supertypes: supers)?.strength, .legit)
        let alt = FileAssociations.classify(plist: viewerAlt, ext: "pdf", typeID: "com.adobe.pdf", supertypes: supers)
        XCTAssertEqual(alt?.strength, .secondary); XCTAssertEqual(alt?.typeCount, 3)
        XCTAssertEqual(FileAssociations.classify(plist: generic, ext: "pdf", typeID: "com.adobe.pdf", supertypes: supers)?.strength, .generic)
        XCTAssertNil(FileAssociations.classify(plist: unrelated, ext: "pdf", typeID: "com.adobe.pdf", supertypes: supers))
    }

    func testAnalyzePreselectsOnlyNonSystemNonDefaultSecondary() {
        let docs: [String: [String: Any]] = [
            "/Applications/mPDF.app": ["CFBundleIdentifier": "fr.s.mpdf", "CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["pdf"], "CFBundleTypeRole": "Editor"]]],
            "/Applications/mFONTS.app": ["CFBundleIdentifier": "fr.s.mfonts", "CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["pdf", "psd"], "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate"]]],
            "/System/Applications/Preview.app": ["CFBundleIdentifier": "com.apple.Preview", "CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["pdf"], "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate"]]],
            "/Volumes/D/mFONTS dev.app": ["CFBundleIdentifier": "fr.s.mfonts.dev", "CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["pdf"], "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate"]]],
        ]
        let a = FileAssociations.analyze(ext: ".PDF", appPaths: Array(docs.keys), defaultPath: "/Applications/mPDF.app", read: { docs[$0] })
        XCTAssertEqual(a?.ext, "pdf")
        XCTAssertEqual(Set(a!.apps.filter(\.preselected).map(\.name)), ["mFONTS", "mFONTS dev"])
        XCTAssertFalse(a!.apps.first { $0.name == "Preview" }!.removable)
        XCTAssertFalse(a!.apps.first { $0.name == "mPDF" }!.removable)
        XCTAssertEqual(a!.apps.first?.name, "mPDF") // l'appli par défaut en tête
        XCTAssertNil(FileAssociations.analyze(ext: "a b", appPaths: [], defaultPath: nil))
    }
}
