import AppKit
import Combine
import HdCleanerCore
import UserNotifications

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
    @Published private(set) var phase = Phase.idle
    @Published private(set) var result: ScanResult?
    @Published private(set) var report: CleanReport?
    @Published var selection = Set<String>()
    @Published var category = JunkCategory.appCaches

    let device = DeviceInfo.read()
    let home: URL
    var onMonitorChange: (() -> Void)?
    private var monitor = ThresholdMonitor()
    private var timer: Timer?
    private var cancel = CancelFlag()

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        settings = AppSettings.decode(UserDefaults.standard.data(forKey: Self.settingsKey))
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
        items.filter { $0.category.disposal == disposal }.reduce(0) { $0 + $1.size }
    }

    private func settingsChanged(_ old: AppSettings) {
        guard settings != old else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
        if settings.theme != old.theme { Socle.apply(socleTheme) }
        if settings.monitorEnabled != old.monitorEnabled || settings.thresholdPercent != old.thresholdPercent {
            monitor = ThresholdMonitor()
            startMonitoring()
        }
    }

    // MARK: Analyse

    private func context() -> ScanContext {
        var c = ScanContext(home: home)
        c.largeFileMinimum = Int64(settings.largeFileMinimumMB) * 1_000_000
        c.excluded = Set(settings.excludedPaths)
        let apps = NSWorkspace.shared.runningApplications
        c.running = Set(apps.compactMap { $0.bundleIdentifier?.lowercased() } + apps.compactMap { $0.localizedName?.lowercased() })
        c.installed = InstalledApps.bundleIDs()
        c.isRegistered = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            c.screenshotFolder = URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
        }
        return c
    }

    func scan() {
        guard !busy else { return }
        report = nil
        let flag = CancelFlag()
        cancel = flag
        phase = .scanning(.appCaches, 0)
        let context = context()
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Scanner.scan(context, cancel: flag) { category, part in
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
                Cleaner.clean(items, home: home, cancel: flag) { part in
                    Task { @MainActor [weak self] in
                        if case .cleaning = self?.phase { self?.phase = .cleaning(part) }
                    }
                }
            }.value
            phase = .idle
            report = done
            let failed = Set(done.failures)
            let gone = Set(items.map(\.path)).subtracting(failed).filter { !FileManager.default.fileExists(atPath: $0) }
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
        if settings.monitorEnabled, let disk, monitor.check(disk, percent: settings.thresholdPercent) { Notifier.lowDisk(disk) }
        onMonitorChange?()
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

    static func lowDisk(_ disk: DiskInfo) {
        let content = UNMutableNotificationContent()
        content.title = L("notify.title")
        content.body = L("notify.body", SizeFormat.text(disk.available), SizeFormat.text(disk.total))
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
