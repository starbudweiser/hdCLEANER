import AppKit
import CoreServices
import HdCleanerCore
import SwiftUI

// MARK: Entretien

@MainActor
final class MaintenanceModel: ObservableObject {
    @Published private(set) var running: MaintenanceTask?
    @Published private(set) var results: [MaintenanceTask: Bool] = [:]
    @Published private(set) var log = ""
    private var job = ShellJob()

    func run(_ task: MaintenanceTask) {
        guard running == nil else { return }
        running = task
        log += (log.isEmpty ? "" : "\n") + "▶ \(task.title)\n"
        let script = task.script(uid: getuid())
        let job = ShellJob()
        self.job = job
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ShellResult in
                task.needsAdmin ? AdminRunner.runCapturing(script) : job.run(script) { text in Task { @MainActor in self.append(text) } }
            }.value
            if task.needsAdmin, !result.output.isEmpty { append(result.output + "\n") }
            if result.cancelled { append(L(task.needsAdmin ? "maintenance.refused" : "maintenance.stopped") + "\n") }
            else { append(L(result.exitCode == 0 ? "maintenance.ok" : "maintenance.failed", Int(result.exitCode)) + "\n") }
            results[task] = result.ok
            running = nil
        }
    }

    func stop() { job.cancel() }
    func clearLog() { log = ""; results = [:] }
    private func append(_ text: String) { log += text }
}

// MARK: Permissions et flags

@MainActor
final class PermissionsModel: ObservableObject {
    enum ModeChoice: String, CaseIterable { case keep = "", custom = "custom" }

    @Published var targets: [String] = []
    @Published var recursive = true
    @Published var scope = PermissionPlan.Scope.all
    @Published var flags = PermissionPlan.Flags()
    @Published var fileMode = ""
    @Published var directoryMode = ""
    @Published var ownerChoice = "" // "" inchangé, "me", "custom"
    @Published var ownerCustom = ""
    @Published var clearACL = false
    @Published var clearQuarantine = false
    @Published var clearAllExtendedAttributes = false
    @Published var useAdmin = false
    @Published private(set) var preview: PermissionPlan.Preview?
    @Published private(set) var previewing = false
    @Published private(set) var previewCount = 0
    @Published private(set) var running = false
    @Published private(set) var log = ""
    private var cancel = CancelFlag()
    private var job = ShellJob()

    let user = NSUserName()

    var plan: PermissionPlan {
        var p = PermissionPlan()
        p.targets = targets
        p.recursive = recursive
        p.scope = scope
        p.flags = flags
        p.fileMode = fileMode.trimmingCharacters(in: .whitespaces)
        p.directoryMode = directoryMode.trimmingCharacters(in: .whitespaces)
        p.owner = ownerChoice == "me" ? user : ownerChoice == "custom" ? ownerCustom.trimmingCharacters(in: .whitespaces) : ""
        p.clearACL = clearACL
        p.clearQuarantine = clearQuarantine
        p.clearAllExtendedAttributes = clearAllExtendedAttributes
        return p
    }

    func issues(home: URL) -> [PermissionPlan.Issue] { plan.issues(home: home) }

    func add(_ paths: [String]) {
        for path in paths { let p = URL(fileURLWithPath: path).standardizedFileURL.path; if !targets.contains(p) { targets.append(p) } }
        preview = nil
    }

    func remove(_ path: String) { targets.removeAll { $0 == path }; preview = nil }

    func runPreview() {
        guard !previewing else { return }
        previewing = true
        previewCount = 0
        preview = nil
        let flag = CancelFlag()
        cancel = flag
        let plan = plan
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                plan.preview(cancel: flag) { n in Task { @MainActor in self.previewCount = n } }
            }.value
            previewing = false
            preview = found.cancelled ? nil : found
        }
    }

    func cancelPreview() { cancel.cancel() }

    func apply() {
        guard !running else { return }
        running = true
        log = ""
        let plan = plan, admin = useAdmin
        let job = ShellJob()
        self.job = job
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ShellResult in
                admin ? AdminRunner.runCapturing(plan.script()) : job.run(plan.script()) { text in Task { @MainActor in self.log += text } }
            }.value
            if admin, !result.output.isEmpty { log += result.output + "\n" }
            log += (result.cancelled ? L(admin ? "maintenance.refused" : "maintenance.stopped") : L(result.exitCode == 0 ? "perm.done" : "maintenance.failed", Int(result.exitCode))) + "\n"
            running = false
            preview = nil
        }
    }

    func stop() { job.cancel() }
}

// MARK: Fichiers invisibles

@MainActor
final class InvisiblesModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning(Int), cleaning(Double) }

    @Published var root: URL?
    @Published private(set) var scan: InvisibleScan?
    @Published var selection = Set<String>()
    @Published var kind = InvisibleKind.dsStore
    @Published private(set) var phase = Phase.idle
    @Published private(set) var report: CleanReport?
    /// Surveillance : ce qui a été supprimé depuis le lancement.
    @Published private(set) var watchRemoved = 0
    @Published private(set) var watchRecent: [String] = []
    private var cancel = CancelFlag()

    var busy: Bool { phase != .idle }
    var selectedItems: [InvisibleItem] { (scan?.all ?? []).filter { selection.contains($0.path) } }

    func startScan() {
        guard let root, !busy else { return }
        report = nil
        let flag = CancelFlag()
        cancel = flag
        phase = .scanning(0)
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                InvisibleScanner.scan(roots: [root], cancel: flag) { n in Task { @MainActor in if case .scanning = self.phase { self.phase = .scanning(n) } } }
            }.value
            phase = .idle
            guard !flag.isCancelled else { return }
            scan = found
            selection = Set(found.all.filter { $0.kind.preselected }.map(\.path))
            kind = InvisibleKind.allCases.first { !(found.items[$0] ?? []).isEmpty } ?? .dsStore
        }
    }

    func cancelWork() { cancel.cancel() }

    func clean() {
        guard let root, !busy else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }
        let flag = CancelFlag()
        cancel = flag
        phase = .cleaning(0)
        Task {
            let done = await Task.detached(priority: .userInitiated) {
                InvisibleCleaner.clean(items, roots: [root], cancel: flag, runAdmin: AdminRunner.run) { part in Task { @MainActor in if case .cleaning = self.phase { self.phase = .cleaning(part) } } }
            }.value
            phase = .idle
            report = done
            let failed = Set(done.failures)
            let gone = Set(items.map(\.path)).subtracting(failed)
            if var s = scan {
                for key in Array(s.items.keys) { s.items[key]?.removeAll { gone.contains($0.path) } }
                scan = s
            }
            selection.subtract(gone)
        }
    }

    func setSelected(_ on: Bool, kind: InvisibleKind) {
        let paths = (scan?.items[kind] ?? []).map(\.path)
        if on { selection.formUnion(paths) } else { selection.subtract(paths) }
    }

    func setSelected(_ on: Bool, item: InvisibleItem) {
        if on { selection.insert(item.path) } else { selection.remove(item.path) }
    }

    func noteWatched(_ removed: [String]) {
        watchRemoved += removed.count
        watchRecent = Array((removed.sorted() + watchRecent).prefix(8))
    }
}

// MARK: Surveillance (FSEvents)

/// Supprime au passage les fichiers invisibles sûrs (.DS_Store, ._*, __MACOSX) qui apparaissent dans les dossiers surveillés.
final class InvisibleWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var roots: [URL] = []
    private let queue = DispatchQueue(label: "hdcleaner.watcher", qos: .utility)
    var onRemoved: (@Sendable ([String]) -> Void)?

    deinit { stop() }

    func update(paths: [String]) {
        stop()
        let live = paths.filter { FileManager.default.fileExists(atPath: $0) } // un volume démonté reprendra à son retour (relecture à chaque réglage)
        guard !live.isEmpty else { return }
        roots = live.map { URL(fileURLWithPath: $0).standardizedFileURL }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<InvisibleWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.handle(Array(paths.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &context, live as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0, flags) else { return }
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

    private func handle(_ paths: [String]) {
        let removed = InvisibleCleaner.cleanReported(paths: paths, roots: roots)
        if !removed.isEmpty { onRemoved?(removed) }
    }
}
