import AppKit
import HdCleanerCore
import SwiftUI

/// Surveille les dossiers de démarrage automatique (FSEvents). Aucun calcul tant que rien n'y change : le système prévient l'appli.
final class SecurityWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "hdcleaner.security", qos: .utility)
    var onFiles: (@Sendable ([String]) -> Void)?

    deinit { stop() }

    func update(paths: [String], enabled: Bool) {
        stop()
        let live = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard enabled, !live.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SecurityWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []).prefix(count)
            let files = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).filter { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            }
            if !files.isEmpty { watcher.onFiles?(Array(files)) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &context, live as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}

/// Onglet Sécurité : analyse à la demande, protection en temps réel des éléments de démarrage, quarantaine, base de menaces d'Apple.
@MainActor
final class SecurityModel: ObservableObject {
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false
    @Published private(set) var current = ""
    @Published private(set) var results: [Detection] = []
    @Published private(set) var quarantined: [QuarantinedItem] = []
    @Published private(set) var info = SignatureInfo()
    @Published private(set) var updating = false
    @Published private(set) var note: String?

    let home: URL
    private let watcher = SecurityWatcher()
    private var cancel = CancelFlag()
    var onThreat: ((String, Bool) -> Void)?

    init(home: URL) {
        self.home = home
        watcher.onFiles = { [weak self] files in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scanRealtime(files) } }
        }
    }

    /// Moteur embarqué : le programme yara et les règles (Apple + hdCLEANER). Nil hors d'un paquet .app.
    var config: YaraEngine.Config? {
        guard let binary = Bundle.main.url(forResource: "yara", withExtension: nil) else { return nil }
        let ours = Bundle.main.url(forResource: "hd_rules", withExtension: "yar")
        let config = YaraEngine.Config(binary: binary, ruleFiles: [YaraEngine.xprotectRules] + (ours.map { [$0] } ?? []))
        return config.isUsable ? config : nil
    }

    func start(realtime: Bool) {
        refresh()
        apply(realtime: realtime)
    }

    func refresh() {
        quarantined = Quarantine.list(home: home)
        Task {
            let value = await Task.detached(priority: .utility) { YaraEngine.signatureInfo() }.value
            info = value
        }
    }

    func apply(realtime: Bool) {
        watcher.update(paths: PersistenceLocations.paths(home: home), enabled: realtime && config != nil)
    }

    // MARK: Analyse à la demande

    func quickScan() { scan(PersistenceLocations.quickScan(home: home), label: L("sec.quick")) }

    func scan(folder: URL) { scan([folder.path], label: folder.lastPathComponent) }

    private func scan(_ paths: [String], label: String) {
        guard !scanning, let config else { note = L("sec.engineMissing"); return }
        scanning = true
        scanned = false
        note = nil
        current = label
        results = []
        let flag = CancelFlag()
        cancel = flag
        Task {
            let found = await Task.detached(priority: .utility) { YaraEngine.scan(paths, config: config, cancel: flag) }.value
            scanning = false
            guard !flag.isCancelled else { return }
            let already = Set(Quarantine.list(home: home).map(\.originalPath))
            results = found.filter { !already.contains($0.path) }
            scanned = true
        }
    }

    func cancelScan() { cancel.cancel() }

    // MARK: Temps réel

    /// Un fichier vient d'apparaître ou de changer dans un dossier de démarrage : analyse, puis quarantaine si possible.
    private func scanRealtime(_ files: [String]) {
        guard let config else { return }
        Task {
            let found = await Task.detached(priority: .utility) { YaraEngine.scan(files, config: config, recursive: false) }.value
            for detection in found {
                let isolated = isolate(detection, notify: false)
                onThreat?(URL(fileURLWithPath: detection.path).lastPathComponent, isolated)
                if !isolated { results.append(detection); scanned = true }
            }
        }
    }

    // MARK: Quarantaine

    @discardableResult
    func isolate(_ detection: Detection, notify: Bool = true) -> Bool {
        guard Quarantine.canIsolate(detection.path, home: home) else { return false }
        Self.stopLaunchJob(at: detection.path)
        do {
            try Quarantine.add(detection.path, rule: detection.rule, home: home)
        } catch {
            if notify { note = L("sec.isolateFailed") }
            return false
        }
        results.removeAll { $0.path == detection.path }
        quarantined = Quarantine.list(home: home)
        return true
    }

    func isolateAll() {
        for detection in results where Quarantine.canIsolate(detection.path, home: home) { isolate(detection) }
    }

    func restore(_ item: QuarantinedItem) {
        do {
            try Quarantine.restore(item, home: home)
            note = nil
        } catch {
            note = L("sec.restoreFailed")
        }
        quarantined = Quarantine.list(home: home)
    }

    func delete(_ item: QuarantinedItem) {
        Quarantine.delete(item, home: home)
        quarantined = Quarantine.list(home: home)
    }

    /// Arrête la tâche de démarrage décrite par un fichier .plist de LaunchAgents avant de l'isoler (sans effet sur les autres fichiers).
    private static func stopLaunchJob(at path: String) {
        guard path.hasSuffix(".plist"), path.contains("/LaunchAgents/"),
              let label = NSDictionary(contentsOfFile: path)?["Label"] as? String, !label.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: Base de menaces

    /// Demande à macOS de rechercher une nouvelle version de la base XProtect (mot de passe administrateur).
    func updateDatabase() {
        guard !updating else { return }
        updating = true
        note = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { AdminRunner.runCapturing("/usr/bin/xprotect update") }.value
            updating = false
            let fresh = await Task.detached(priority: .utility) { YaraEngine.signatureInfo() }.value
            info = fresh
            note = result.ok ? L("sec.updated", fresh.version) : L("sec.updateFailed")
        }
    }
}

struct SecurityView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: SecurityModel

    var body: some View {
        VStack(spacing: Socle.M.space3) {
            statusPanel
            HStack(spacing: Socle.M.space3) {
                threats
                quarantine
            }
        }
        .onAppear { model.refresh() }
    }

    private var statusPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Socle.M.space3) {
                HStack(alignment: .top, spacing: Socle.M.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("sec.realtime")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                        Text(L("sec.realtimeHelp")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Socle.M.space3)
                    Toggle("", isOn: $app.settings.realtimeProtection).labelsHidden()
                }
                Rectangle().fill(Socle.C.borderSubtle).frame(height: 1)
                HStack(spacing: Socle.M.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(databaseLine).socle(Socle.T.label).foregroundStyle(Socle.C.text)
                        Text(L("sec.dbHelp")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Socle.M.space3)
                    Button(model.updating ? L("sec.updating") : L("sec.update")) { model.updateDatabase() }
                        .buttonStyle(SocleButtonStyle(.secondary)).fixedSize().disabled(model.updating)
                }
                Rectangle().fill(Socle.C.borderSubtle).frame(height: 1)
                HStack(spacing: Socle.M.space3) {
                    if model.scanning {
                        Text(L("sec.scanning", model.current)).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted).lineLimit(1)
                        Spacer()
                        Button(L("scan.cancel")) { model.cancelScan() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    } else {
                        Button(L("sec.quick")) { model.quickScan() }.buttonStyle(SocleButtonStyle(.primary)).fixedSize()
                        Button(L("sec.folder")) {
                            if let url = chooseURLs(files: false, multiple: false, directory: app.home).first { model.scan(folder: url) }
                        }
                        .buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                        if let note = model.note { Text(note).socle(Socle.T.meta).foregroundStyle(Socle.C.warning).lineLimit(2) }
                        Spacer()
                    }
                }
            }
            .padding(Socle.M.space3)
        }
    }

    private var databaseLine: String {
        guard model.config != nil else { return L("sec.engineMissing") }
        let date = model.info.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "–"
        return L("sec.db", model.info.version.isEmpty ? "–" : model.info.version, model.info.ruleCount, date)
    }

    private var threats: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(title: L("sec.threats"), trailing: model.scanned ? "\(model.results.count)" : "")
                if model.results.isEmpty {
                    Text(model.scanned ? L("sec.none") : L("sec.notScanned")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) { ForEach(model.results) { threatRow($0) } }
                    }
                    HStack {
                        Spacer()
                        Button(L("sec.isolateAll")) { model.isolateAll() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    }
                    .padding(Socle.M.space2)
                }
            }
        }
    }

    private func title(_ d: Detection) -> String {
        switch d.rule {
        case "HD_Launch_TempExecutable": return L("sec.rule.HD_Launch_TempExecutable")
        case "HD_Launch_RemoteShell": return L("sec.rule.HD_Launch_RemoteShell")
        case "HD_Launch_ScriptPayload": return L("sec.rule.HD_Launch_ScriptPayload")
        default: break
        }
        return L("sec.apple") + (d.detail.isEmpty ? "" : " · " + d.detail)
    }

    private func threatRow(_ d: Detection) -> some View {
        let url = URL(fileURLWithPath: d.path)
        return HStack(spacing: Socle.M.space2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: d.path)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1)
                Text(title(d)).socle(Socle.T.caption).foregroundStyle(Socle.C.warning).lineLimit(1)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: app.home.path, with: "~")).socle(Socle.T.caption)
                    .foregroundStyle(Socle.C.textMuted).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if Quarantine.canIsolate(d.path, home: app.home) {
                Button(L("sec.isolate")) { model.isolate(d) }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
            } else {
                Button(L("sec.show")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    .help(L("sec.needsAdmin"))
            }
        }
        .padding(.horizontal, Socle.M.space3).frame(height: 48)
    }

    private var quarantine: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(title: L("sec.quarantine"), trailing: model.quarantined.isEmpty ? "" : "\(model.quarantined.count)")
                if model.quarantined.isEmpty {
                    Text(L("sec.quarantineEmpty")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) { ForEach(model.quarantined) { quarantineRow($0) } }
                    }
                }
            }
        }
    }

    private func quarantineRow(_ item: QuarantinedItem) -> some View {
        let url = URL(fileURLWithPath: item.originalPath)
        return HStack(spacing: Socle.M.space2) {
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1)
                Text(item.date.formatted(date: .abbreviated, time: .shortened)).socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted)
            }
            Spacer()
            Button(L("sec.restore")) { model.restore(item) }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
            Button(L("sec.delete")) { model.delete(item) }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
        }
        .padding(.horizontal, Socle.M.space3).frame(height: 40)
    }
}
