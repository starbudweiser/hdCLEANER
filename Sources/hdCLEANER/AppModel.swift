import AppKit
import Combine
import HdCleanerCore
import UserNotifications

enum Mode: Hashable { case clean, apps, maintenance, permissions, invisibles, duplicates, map, organize, timeline }

enum Phase: Equatable {
    case idle
    case scanning(JunkCategory, Double)
    case cleaning(Double)
}

@MainActor
final class AppModel: ObservableObject {
    private static let settingsKey = "settings"

    @Published var settings: AppSettings { didSet { settingsChanged(oldValue) } }
    @Published private(set) var disk = DiskInfo.read()
    /// Le volume choisi pour la surveillance (le disque de démarrage par défaut) ; nil s'il n'est plus monté.
    @Published private(set) var monitoredDisk: DiskInfo?
    @Published private(set) var volumes: [Volume] = []
    @Published private(set) var phase = Phase.idle
    @Published private(set) var result: ScanResult?
    @Published private(set) var report: CleanReport?
    @Published var selection = Set<String>()
    @Published var category = JunkCategory.appCaches
    @Published var mode = Mode.clean
    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var loadingApps = false
    @Published private(set) var sizesReady = false
    @Published private(set) var selectedApp: AppEntry?
    @Published private(set) var related: [JunkItem] = []
    @Published var relatedSelection = Set<String>()

    let maintenance = MaintenanceModel()
    let permissions = PermissionsModel()
    let invisibles = InvisiblesModel()
    let duplicates = DuplicatesModel()
    let diskMap = DiskMapModel()
    let timeline: TimelineModel
    let organizer = OrganizerModel()
    private let watcher = InvisibleWatcher()

    let device = DeviceInfo.read()
    let home: URL
    var onMonitorChange: (() -> Void)?
    private var monitor = ThresholdMonitor()
    private var timer: Timer?
    private var cancel = CancelFlag()

    nonisolated static var defaultHome: URL {
        #if HDCLEANER_SELFTEST
        if let path = ProcessInfo.processInfo.environment["HDCLEANER_HOME"] { return URL(fileURLWithPath: path) }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private let defaults: UserDefaults
    let updater = UpdateEngine.shared  // mise à jour automatique commune (_tools/shared/Updater.swift)
    private var bag = Set<AnyCancellable>()

    init(home: URL = AppModel.defaultHome, defaults: UserDefaults = .standard) {
        self.home = home
        self.defaults = defaults
        timeline = TimelineModel(home: home)
        settings = AppSettings.decode(defaults.data(forKey: Self.settingsKey))
        watcher.onRemoved = { [weak self] removed in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.invisibles.noteWatched(removed); self?.onMonitorChange?() } }
        }
        timeline.onAnomaly = { anomaly, cause in Notifier.fastFilling(anomaly, cause: cause) }
        timeline.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        updater.configure(repo: "hdCLEANER", lang: { Bundle.main.preferredLocalizations.first ?? "en" })
        updater.autoCheck = { [weak self] in self?.settings.autoUpdate ?? true }
        updater.canInstall = { [weak self] in self?.phase == .idle }
        updater.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    var socleTheme: Socle.Theme {
        switch settings.theme {
        case .dark: .dark
        case .light: .light
        case .system: .system
        }
    }

    var belowThreshold: Bool { monitor.alerted }

    var busy: Bool { phase != .idle }

    var selectedItems: [JunkItem] { (result?.all ?? []).filter { selection.contains($0.path) } }

    func total(ofSelected items: [JunkItem], _ disposal: Disposal) -> Int64 {
        items.filter { $0.disposal == disposal }.reduce(0) { $0 + $1.size }
    }

    private func settingsChanged(_ old: AppSettings) {
        guard settings != old else { return }
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
        if settings.theme != old.theme { Socle.apply(socleTheme) }
        if settings.watchedFolders != old.watchedFolders { applyWatcher() }
        if settings.monitorEnabled != old.monitorEnabled || settings.thresholdPercent != old.thresholdPercent || settings.monitoredVolume != old.monitoredVolume {
            monitor = ThresholdMonitor()
            startMonitoring()
        }
    }

    // MARK: Analyse

    func scan() {
        guard !busy else { return }
        report = nil
        let flag = CancelFlag()
        cancel = flag
        phase = .scanning(.appCaches, 0)
        let home = home, settings = settings, running = ScanContext.runningNames()
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                // Lecture des applis installées et des instantanés : hors du fil principal pour ne pas figer la fenêtre.
                Scanner.scan(ScanContext.live(home: home, settings: settings, running: running), cancel: flag) { category, part in
                    Task { @MainActor [weak self] in
                        if case .scanning = self?.phase { self?.phase = .scanning(category, part) }
                    }
                }
            }.value
            phase = .idle
            disk = DiskInfo.read()
            guard !flag.isCancelled else { return }
            result = found
            selection = Set(found.all.filter(\.preselected).map(\.path))
            category = JunkCategory.allCases.first { found.total($0) > 0 } ?? .appCaches
        }
    }

    func cancelWork() { cancel.cancel() }

    // MARK: Nettoyage

    func clean() {
        guard !busy else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }
        let flag = CancelFlag()
        cancel = flag
        phase = .cleaning(0)
        let home = home
        Task {
            let done = await Task.detached(priority: .userInitiated) {
                Cleaner.clean(items, home: home, cancel: flag, runAdmin: AdminRunner.run) { part in
                    Task { @MainActor [weak self] in
                        if case .cleaning = self?.phase { self?.phase = .cleaning(part) }
                    }
                }
            }.value
            phase = .idle
            report = done
            let failed = Set(done.failures)
            let gone = Set(items.map(\.path)).subtracting(failed)
            if var r = result {
                for key in Array(r.items.keys) { r.items[key]?.removeAll { gone.contains($0.path) } }
                result = r
            }
            selection.subtract(gone)
            refreshDisk()
        }
    }

    func exclude(_ item: JunkItem) {
        settings.excludedPaths.append(item.path)
        selection.remove(item.path)
        if var r = result {
            r.items[item.category]?.removeAll { $0.path == item.path }
            result = r
        }
    }

    func setSelected(_ on: Bool, category: JunkCategory) {
        let paths = (result?.items[category] ?? []).map(\.path)
        if on { selection.formUnion(paths) } else { selection.subtract(paths) }
    }

    func setSelected(_ on: Bool, item: JunkItem) {
        if on { selection.insert(item.path) } else { selection.remove(item.path) }
    }

    // MARK: Surveillance des fichiers invisibles

    /// Applique la liste des dossiers surveillés (au lancement et à chaque changement).
    func applyWatcher() {
        watcher.update(paths: settings.watchedFolders)
        onMonitorChange?()
    }

    var watching: Bool { !settings.watchedFolders.isEmpty }

    /// Fermer la fenêtre ne quitte pas l'appli quand elle surveille le disque ou des dossiers.
    var keepsRunningWithoutWindow: Bool { settings.monitorEnabled || watching || LoginAgent.enabled }

    // MARK: Seuil

    func startMonitoring() {
        timer?.invalidate()
        timer = nil
        refreshDisk()
        guard settings.monitorEnabled else { return }
        Notifier.requestAuthorization()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisk() }
        }
    }

    func refreshDisk() {
        disk = DiskInfo.read()
        volumes = Volume.mounted()
        monitoredDisk = DiskInfo.read(URL(fileURLWithPath: settings.monitoredVolume))
        if settings.monitorEnabled, let watched = monitoredDisk, monitor.check(watched, percent: settings.thresholdPercent) { Notifier.lowDisk(watched) }
        onMonitorChange?()
    }
}

// MARK: Applications

extension AppModel {
    /// Les noms s'affichent aussitôt ; les tailles arrivent au fil de l'eau (8 calculs en parallèle), puis la liste se trie par taille.
    func loadApps() {
        guard !loadingApps, apps.isEmpty else { return }
        loadingApps = true
        let dirs = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        Task {
            let list = await Task.detached(priority: .userInitiated) { Uninstaller.listApps(dirs: dirs) }.value
            apps = list
            await withTaskGroup(of: (String, Int64).self) { group in
                var next = list.makeIterator()
                func launch() {
                    guard let app = next.next() else { return }
                    group.addTask(priority: .utility) { (app.path, DiskSize.bytes(of: URL(fileURLWithPath: app.path))) }
                }
                for _ in 0..<8 { launch() }
                while let (path, size) = await group.next() {
                    if let i = apps.firstIndex(where: { $0.path == path }) { apps[i].size = size }
                    launch()
                }
            }
            sizesReady = true
            loadingApps = false
        }
    }

    /// Applis déposées dans la fenêtre : ajoutées à la liste (sans doublon), la dernière est sélectionnée. Renvoie le nombre refusé.
    @discardableResult
    func addDroppedApps(_ urls: [URL]) async -> Int {
        let home = home
        let found = await Task.detached(priority: .userInitiated) { urls.map { Uninstaller.entry(at: $0, home: home) } }.value
        var last: AppEntry?
        for entry in found.compactMap({ $0 }) {
            if let i = apps.firstIndex(where: { $0.path == entry.path }) { apps[i].size = entry.size; last = apps[i] } else { apps.append(entry); last = entry }
        }
        if let last { select(last) }
        return found.filter { $0 == nil }.count
    }

    func isRunning(_ app: AppEntry) -> Bool {
        !app.bundleID.isEmpty && !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    func select(_ app: AppEntry) {
        selectedApp = app
        related = []
        relatedSelection = []
        let home = home
        let running = isRunning(app)
        Task {
            let found = await Task.detached(priority: .userInitiated) { Uninstaller.items(for: app, home: home, running: running) }.value
            guard selectedApp?.path == app.path else { return }
            related = found
            relatedSelection = Set(found.map(\.path))
        }
    }

    var selectedRelated: [JunkItem] { related.filter { relatedSelection.contains($0.path) } }

    func uninstall() {
        guard !busy, let app = selectedApp else { return }
        let items = selectedRelated
        guard !items.isEmpty else { return }
        phase = .cleaning(0)
        report = nil
        let home = home
        Task {
            let done = await Task.detached(priority: .userInitiated) {
                Cleaner.clean(items, home: home, runAdmin: AdminRunner.run)
            }.value
            phase = .idle
            report = done
            if !FileManager.default.fileExists(atPath: app.path) {
                apps.removeAll { $0.path == app.path }
                selectedApp = nil
                related = []
            } else {
                select(app)
            }
            refreshDisk()
        }
    }
}

extension ScanContext {
    /// Contexte réel : applis ouvertes et installées, instantanés Time Machine, langues du système.
    @MainActor static func runningNames() -> Set<String> {
        let apps = NSWorkspace.shared.runningApplications
        return Set(apps.compactMap { $0.bundleIdentifier?.lowercased() } + apps.compactMap { $0.localizedName?.lowercased() })
    }

    static func live(home: URL, settings: AppSettings, running: Set<String>) -> ScanContext {
        var c = ScanContext(home: home)
        c.largeFileMinimum = Int64(settings.largeFileMinimumMB) * 1_000_000
        c.excluded = Set(settings.excludedPaths)
        c.running = running
        c.installed = InstalledApps.bundleIDs()
        c.isRegistered = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        c.keptLanguages = Languages.kept(preferred: Locale.preferredLanguages)
        c.snapshots = { TimeMachine.localSnapshots() }
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            c.screenshotFolder = URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
        }
        return c
    }
}

enum TimeMachine {
    static func localSnapshots() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return AdminScript.parseSnapshots(String(decoding: data, as: UTF8.self))
    }
}

/// Résultat d'un script : refusé (mot de passe annulé), code de sortie et texte affiché.
struct ShellResult {
    var cancelled = false
    var exitCode: Int32 = 0
    var output = ""
    var ok: Bool { !cancelled && exitCode == 0 }
}

/// Exécute un script avec le mot de passe administrateur (boîte de dialogue du système) ; faux si la demande est refusée.
enum AdminRunner {
    static func run(_ script: String) -> Bool {
        !execute(script, capture: false).cancelled
    }

    /// Comme `run`, avec la sortie du script (erreurs comprises) et son code de sortie.
    static func runCapturing(_ script: String) -> ShellResult {
        execute(script + "\nprintf '\\n[exit %s]\\n' \"$?\"\nexit 0\n", capture: true)
    }

    private static func execute(_ script: String, capture: Bool) -> ShellResult {
        var result = ShellResult()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hdcleaner-\(UUID().uuidString).sh")
        do { try script.write(to: file, atomically: true, encoding: .utf8) } catch { result.cancelled = true; return result }
        defer { try? FileManager.default.removeItem(at: file) }
        func escaped(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let command = "/bin/sh '\(file.path)' 2>&1"
        let apple = "do shell script \"\(escaped(command))\" with administrator privileges with prompt \"\(escaped(L("admin.prompt")))\""
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", apple]
        process.standardOutput = capture ? pipe : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { result.cancelled = true; return result }
        let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { result.cancelled = true; return result }
        var text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n")
        if let range = text.range(of: #"\[exit (-?\d+)\]\s*$"#, options: .regularExpression) {
            result.exitCode = Int32(text[range].filter { $0.isNumber || $0 == "-" }) ?? 0
            text.removeSubrange(range)
        }
        result.output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}

/// Exécute un script sans mot de passe, en renvoyant la sortie au fur et à mesure ; annulable (le script et ses commandes).
final class ShellJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        let kill = Process() // les commandes lancées par le script (find, chmod…) d'abord, puis le script
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-TERM", "-P", String(p.processIdentifier)]
        try? kill.run()
        kill.waitUntilExit()
        p.terminate()
    }

    func run(_ script: String, onOutput: @escaping @Sendable (String) -> Void) -> ShellResult {
        var result = ShellResult()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hdcleaner-\(UUID().uuidString).sh")
        do { try script.write(to: file, atomically: true, encoding: .utf8) } catch { result.exitCode = -1; return result }
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [file.path]
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { onOutput(String(decoding: data, as: UTF8.self)) }
        }
        lock.lock(); process = p; lock.unlock()
        guard (try? p.run()) != nil else { result.exitCode = -1; return result }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { onOutput(String(decoding: rest, as: UTF8.self)) }
        result.exitCode = p.terminationStatus
        result.cancelled = isCancelled
        return result
    }
}

/// Notifications système.
@MainActor
enum Notifier {
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current() // absent hors d'un paquet .app
    }

    static func requestAuthorization() {
        center?.requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func fastFilling(_ anomaly: Anomaly, cause: Growth?) {
        let content = UNMutableNotificationContent()
        content.title = L("notify.fast.title")
        let lost = SizeFormat.text(anomaly.lost)
        content.body = cause.map { L("notify.fast.body", lost, anomaly.days, URL(fileURLWithPath: $0.path).lastPathComponent) } ?? L("notify.fast.bodyNoCause", lost, anomaly.days)
        requestAuthorization()
        center?.add(UNNotificationRequest(identifier: "fast-filling", content: content, trigger: nil))
    }

    static func lowDisk(_ disk: DiskInfo) {
        let content = UNMutableNotificationContent()
        content.title = L("notify.title")
        content.body = L("notify.body", SizeFormat.text(disk.available), disk.name)
        center?.add(UNNotificationRequest(identifier: "low-disk", content: content, trigger: nil))
    }
}

/// Applis présentes dans les dossiers habituels, y compris ~/Applications et leurs sous-dossiers.
enum InstalledApps {
    static func bundleIDs() -> Set<String> {
        let fm = FileManager.default
        var roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? [] {
            roots.append(volume.appendingPathComponent("Applications"))
        }
        var ids = Set<String>()
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walker where url.pathExtension == "app" {
                if let id = Bundle(url: url)?.bundleIdentifier { ids.insert(id.lowercased()) }
            }
        }
        return ids
    }
}

/// Description de la machine pour le panneau de gauche.
struct DeviceInfo {
    var model: String
    var system: String
    var display: String
    var processor: String
    var memory: String
    var symbol: String

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    /// Nom commercial (« MacBook Pro (16 pouces, 2023) ») lu dans l'arbre matériel, sinon l'identifiant.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    static func read() -> DeviceInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let model = productName() ?? sysctl("hw.model") ?? "Mac"
        let lower = model.lowercased()
        let symbol = lower.contains("macbook") ? "laptopcomputer" : lower.contains("mini") ? "macmini" : lower.contains("studio") ? "macstudio" : lower.contains("pro") ? "macpro.gen3" : "desktopcomputer"
        let screen = NSScreen.main.map { "\(Int($0.frame.width * $0.backingScaleFactor)) × \(Int($0.frame.height * $0.backingScaleFactor))" } ?? "?"
        return DeviceInfo(model: model, system: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", display: screen,
                          processor: sysctl("machdep.cpu.brand_string") ?? "?", memory: SizeFormat.text(Int64(ProcessInfo.processInfo.physicalMemory)), symbol: symbol)
    }
}
