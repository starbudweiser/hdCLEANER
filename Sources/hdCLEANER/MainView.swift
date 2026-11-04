import AppKit
import HdCleanerCore
import SwiftUI

/// Couleur fixe de chaque catégorie, commune à la liste et à la barre du disque.
private extension JunkCategory {
    var color: Color {
        let hex: UInt32 = switch self {
        case .appCaches: 0x2DD4BF
        case .appLogs: 0xFACC15
        case .browserData: 0xF97316
        case .devCaches: 0xF472B6
        case .trash: 0x38BDF8
        case .downloads: 0xA3A3A3
        case .mailDownloads: 0x818CF8
        case .largeFiles: 0xEC4899
        case .leftovers: 0xEF4444
        case .iosBackups: 0x4ADE80
        case .iosPhotoCache: 0xC084FC
        case .musicCache: 0xFB7185
        case .iosUpdates: 0x60A5FA
        case .installers: 0x8B5CF6
        case .screenshots: 0xFB923C
        case .systemCaches: 0x22D3EE
        case .systemLogs: 0xFDE047
        case .snapshots: 0x94A3B8
        case .languages: 0xF59E0B
        }
        return Color(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirming = false

    var body: some View {
        ZStack {
            HStack(spacing: Socle.M.space3) {
                DevicePanel().frame(width: 200)
                VStack(spacing: Socle.M.space3) {
                    DiskPanel(confirming: $confirming)
                    SocleSegmented(options: [Mode.clean, Mode.apps, Mode.timeline, Mode.duplicates, Mode.map, Mode.organize, Mode.maintenance, Mode.permissions, Mode.invisibles], selection: model.mode, label: { L("mode.\($0)") },
                                   onSelect: { model.mode = $0; if $0 == .apps { model.loadApps() } })
                        .frame(maxWidth: .infinity, alignment: .leading)
                    switch model.mode {
                    case .apps: AppsView()
                    case .maintenance: MaintenanceView(model: model.maintenance)
                    case .permissions: PermissionsView(model: model.permissions)
                    case .invisibles: InvisiblesView(model: model.invisibles)
                    case .duplicates: DuplicatesView(model: model.duplicates)
                    case .map: DiskMapView(model: model.diskMap)
                    case .timeline: TimelineView(model: model.timeline)
                    case .organize: OrganizerView(model: model.organizer)
                    case .clean:
                        if model.result == nil {
                            WelcomePanel()
                        } else {
                            HStack(spacing: Socle.M.space3) {
                                CategoryPanel().frame(width: 330)
                                ItemsPanel()
                            }
                        }
                    }
                    if model.mode == .clean || model.mode == .apps { FooterPanel(confirming: $confirming) }
                }
            }
            .padding(Socle.M.space3)
            if confirming {
                if model.mode == .apps {
                    ConfirmDialog(items: model.selectedRelated, title: L("confirm.uninstall", model.selectedApp?.name ?? ""), button: L("apps.uninstall"), shown: $confirming) { model.uninstall() }
                } else {
                    ConfirmDialog(items: model.selectedItems, title: L("confirm.title", model.selectedItems.count), button: L("clean.button"), shown: $confirming) { model.clean() }
                }
            }
        }
        .frame(minWidth: 980, minHeight: 600)
        .background(Socle.C.bg)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border))
    }
}

private struct DevicePanel: View {
    @EnvironmentObject private var model: AppModel

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
            Text(value).socle(Socle.T.label).foregroundStyle(Socle.C.text).multilineTextAlignment(.center)
        }
    }

    var body: some View {
        Panel {
            VStack(spacing: Socle.M.space4) {
                Text(branded: "hdCLEANER").socle(Socle.T.heading).padding(.top, Socle.M.space2)
                Image(systemName: model.device.symbol).font(.system(size: 64, weight: .light)).foregroundStyle(Socle.C.textMuted).padding(.vertical, Socle.M.space3)
                Text(model.device.model).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong).multilineTextAlignment(.center)
                fact(L("device.system"), model.device.system)
                fact(L("device.display"), model.device.display)
                fact(L("device.processor"), model.device.processor)
                fact(L("device.memory"), model.device.memory)
                Spacer()
            }
            .padding(Socle.M.space3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DiskWatermark())
            .clipShape(RoundedRectangle(cornerRadius: Socle.M.radius))
        }
    }
}

private struct DiskPanel: View {
    @Binding var confirming: Bool
    @EnvironmentObject private var model: AppModel

    private var segments: [(color: Color, bytes: Int64)] {
        guard let disk = model.disk else { return [] }
        let junk = JunkCategory.allCases.compactMap { c -> (Color, Int64)? in
            let bytes = model.result?.total(c) ?? 0
            return bytes > 0 ? (c.color, bytes) : nil
        }
        let found = junk.reduce(0) { $0 + $1.1 }
        return junk + [(Socle.C.textSubtle, max(disk.used - found, 0)), (Socle.C.control, disk.available)]
    }

    var body: some View {
        Panel {
            HStack(spacing: Socle.M.space4) {
                Image(systemName: "internaldrive").font(.system(size: 34, weight: .light)).foregroundStyle(Socle.C.textMuted)
                VStack(alignment: .leading, spacing: Socle.M.space2) {
                    HStack {
                        Text(model.disk?.name ?? "").socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
                        Text(SizeFormat.text(model.disk?.total ?? 0)).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                        Spacer()
                        if model.settings.monitorEnabled { monitorBadge }
                    }
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            let total = max(segments.reduce(0) { $0 + $1.bytes }, 1)
                            ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                                Rectangle().fill(s.color).frame(width: max(CGFloat(Double(s.bytes) / Double(total)) * geo.size.width - 1, 1))
                            }
                        }
                    }
                    .frame(height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    HStack(spacing: Socle.M.space4) {
                        Text(L("disk.used", SizeFormat.text(model.disk?.used ?? 0)))
                        Text(L("disk.free", SizeFormat.text(model.disk?.available ?? 0))).socleValue()
                    }
                    .socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(1)
                    // Deuxième ligne : chaque mesure est suivie de son bouton ; elle passe à la ligne si la fenêtre est étroite.
                    if model.result != nil || (model.disk?.purgeable ?? 0) > 0 {
                        ViewThatFits(in: .horizontal) {
                            actions(stacked: false)
                            actions(stacked: true)
                        }
                    }
                }
            }
            .padding(Socle.M.space3)
        }
    }

    private func actions(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Socle.M.space2)) : AnyLayout(HStackLayout(spacing: Socle.M.space5))
        return layout {
            if model.result != nil {
                HStack(spacing: Socle.M.space2) {
                    Text(L("disk.junk", SizeFormat.text(model.result?.total ?? 0)))
                    if case .idle = model.phase { reclaimButton }
                }
            }
            if let purgeable = model.disk?.purgeable, purgeable > 0 {
                HStack(spacing: Socle.M.space2) {
                    Text(L("disk.purgeable", SizeFormat.text(purgeable)))
                    if case .idle = model.phase, model.result != nil { freeButton }
                }
            }
        }
        .socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }

    /// Récupère ce qui est coché (par défaut les éléments sûrs) : même confirmation que le bouton « Nettoyer » du bas.
    private var reclaimButton: some View {
        let gain = model.selectedItems.reduce(0) { $0 + $1.size }
        return Button(L("disk.reclaim", SizeFormat.text(gain))) {
            model.mode = .clean
            confirming = true
        }
        .buttonStyle(SocleButtonStyle(.action, height: 24)).fixedSize().disabled(model.selection.isEmpty)
    }

    /// L'espace purgeable vient surtout des instantanés Time Machine locaux : on les propose seuls à la confirmation (mot de passe administrateur).
    @ViewBuilder private var freeButton: some View {
        let snapshots = model.result?.items[.snapshots] ?? []
        if !snapshots.isEmpty {
            Button(L("disk.free.button")) {
                model.selection = Set(snapshots.map(\.path))
                model.category = .snapshots
                model.mode = .clean
                confirming = true
            }
            .buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize()
        }
    }

    private var monitorBadge: some View {
        HStack(spacing: Socle.M.space1_5) {
            Circle().fill(model.belowThreshold ? Socle.C.danger : Socle.C.success).frame(width: 8, height: 8)
            Text(L(model.belowThreshold ? "monitor.below" : "monitor.badge", model.monitoredDisk?.name ?? "–")).socle(Socle.T.meta).foregroundStyle(Socle.C.text)
        }
        .padding(.horizontal, Socle.M.space2).frame(height: 22)
        .background(Socle.C.bgSunken, in: RoundedRectangle(cornerRadius: Socle.M.radius))
    }
}

private struct WelcomePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(spacing: Socle.M.space3) {
                Text(L("scan.welcome")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                Text(L("scan.welcomeHelp")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Case à cocher plate Socle, à trois états.
struct CheckBox: View {
    enum State { case off, on, mixed }
    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(state == .off ? Color.clear : Socle.C.accentFill)
                RoundedRectangle(cornerRadius: 2).stroke(state == .off ? Socle.C.borderControl : Socle.C.accentFill)
                if state != .off {
                    Image(systemName: state == .on ? "checkmark" : "minus").font(.system(size: 10, weight: .bold)).foregroundStyle(Socle.C.onAccentFill)
                }
            }
            .frame(width: Socle.M.sizeChoice, height: Socle.M.sizeChoice)
            .frame(width: 28, height: 28) // zone cliquable plus large que la case
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PanelHeader: View {
    let title: String
    let trailing: String

    var body: some View {
        HStack {
            Text(title).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong).lineLimit(1)
            Spacer()
            Text(trailing).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
        }
        .padding(.horizontal, Socle.M.space3)
        .frame(height: 32)
        .background(Socle.C.surfaceRaised)
    }
}

private struct CategoryPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(spacing: 0) {
                PanelHeader(title: L("list.categories"), trailing: L("list.size"))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(JunkCategory.allCases) { row($0) }
                    }
                }
            }
        }
    }

    private func state(_ c: JunkCategory) -> CheckBox.State {
        let items = model.result?.items[c] ?? []
        let chosen = items.filter { model.selection.contains($0.path) }.count
        return chosen == 0 ? .off : chosen == items.count ? .on : .mixed
    }

    private func row(_ c: JunkCategory) -> some View {
        let items = model.result?.items[c] ?? []
        let total = model.result?.total(c) ?? 0
        let denied = model.result?.denied.contains(c) == true
        return HStack(spacing: Socle.M.space2) {
            CheckBox(state: state(c)) { model.setSelected(state(c) == .off, category: c) }.disabled(items.isEmpty)
            HStack(spacing: Socle.M.space2) {
                Circle().fill(c.color).frame(width: 9, height: 9)
                Text(c.title).socle(Socle.T.body).foregroundStyle(items.isEmpty ? Socle.C.textMuted : Socle.C.text).lineLimit(1)
                if denied { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Socle.C.warning) }
                Spacer()
                Text(total > 0 ? SizeFormat.text(total) : items.isEmpty ? "–" : L("list.count", items.count)).socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.category = c }
        }
        .padding(.horizontal, Socle.M.space3)
        .frame(height: 30)
        .background(model.category == c ? Socle.C.surfaceSelected : .clear)
    }
}

private struct ItemsPanel: View {
    @EnvironmentObject private var model: AppModel

    private var items: [JunkItem] { model.result?.items[model.category] ?? [] }

    private static func tag(_ disposal: Disposal) -> String {
        switch disposal {
        case .delete: "list.deleteTag"
        case .trash: "list.trashTag"
        case .admin: "list.adminTag"
        case .snapshot: "list.snapshotTag"
        }
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(title: model.category.title, trailing: L(Self.tag(model.category.disposal)))
                Text(model.category.help).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Socle.M.space3).padding(.vertical, Socle.M.space2)
                if model.result?.denied.contains(model.category) == true { accessCallout }
                if items.isEmpty {
                    Text(L("list.empty")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { row($0) }
                        }
                    }
                }
            }
        }
    }

    private var accessCallout: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            Text(L("access.title")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
            Text(branded: L("access.body")).socle(Socle.T.meta).foregroundStyle(Socle.C.text).fixedSize(horizontal: false, vertical: true)
            Button(L("access.open")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize()
        }
        .padding(Socle.M.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Socle.C.bgInset)
    }

    private func row(_ item: JunkItem) -> some View {
        let chosen = model.selection.contains(item.path)
        return HStack(spacing: Socle.M.space2) {
            CheckBox(state: chosen ? .on : .off) { model.setSelected(!chosen, item: item) }
            if item.category == .snapshots {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundStyle(Socle.C.textMuted).frame(width: 16, height: 16)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 16, height: 16)
            }
            Text(item.name).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle).help(item.path)
            if item.inUse {
                Text(L("list.inUse")).socle(Socle.T.caption).foregroundStyle(Socle.C.warning)
                    .padding(.horizontal, Socle.M.space1).background(Socle.C.bgSunken, in: RoundedRectangle(cornerRadius: 2))
            }
            Spacer()
            Text(item.size > 0 ? SizeFormat.text(item.size) : "–").socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
            if item.category != .snapshots {
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Socle.C.textMuted)
                }
                .buttonStyle(.plain).help(L("list.reveal"))
            }
            Button { model.exclude(item) } label: {
                Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(Socle.C.textMuted)
            }
            .buttonStyle(.plain).help(L("list.exclude"))
        }
        .padding(.horizontal, Socle.M.space3)
        .frame(height: 28)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("list.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button(L("list.exclude")) { model.exclude(item) }
        }
    }
}

private struct FooterPanel: View {
    @EnvironmentObject private var model: AppModel
    @Binding var confirming: Bool

    private var gain: Int64 { model.selectedItems.reduce(0) { $0 + $1.size } }
    private var uninstallGain: Int64 { model.selectedRelated.reduce(0) { $0 + $1.size } }

    var body: some View {
        Panel {
            HStack(spacing: Socle.M.space3) {
                switch model.phase {
                case .idle:
                    if model.mode == .apps { appsControls } else { cleanControls }
                case .scanning(let category, let part):
                    work(L("scan.running", category.title), part)
                case .cleaning(let part):
                    work(L("clean.running"), part)
                }
            }
            .padding(Socle.M.space3)
            .frame(minHeight: 60)
        }
    }

    @ViewBuilder private var cleanControls: some View {
        Button(L(model.result == nil ? "scan.start" : "scan.again")) { model.scan() }
            .buttonStyle(SocleButtonStyle(.primary)).fixedSize()
        message
        Spacer()
        if model.result != nil {
            Text(L("clean.gain", SizeFormat.text(gain))).socle(Socle.T.label).foregroundStyle(Socle.C.text)
            Button(L("clean.button")) { confirming = true }
                .buttonStyle(SocleButtonStyle(.action)).fixedSize().disabled(model.selection.isEmpty)
        }
    }

    @ViewBuilder private var appsControls: some View {
        message
        Spacer()
        if let app = model.selectedApp {
            if model.isRunning(app) { Text(L("apps.running")).socle(Socle.T.label).foregroundStyle(Socle.C.warning) }
            Text(L("clean.gain", SizeFormat.text(uninstallGain))).socle(Socle.T.label).foregroundStyle(Socle.C.text)
            Button(L("apps.uninstall")) { confirming = true }
                .buttonStyle(SocleButtonStyle(.action)).fixedSize().disabled(model.selectedRelated.isEmpty || model.isRunning(app))
        }
    }

    @ViewBuilder private var message: some View {
        if let r = model.report {
            let parts = [r.freed > 0 ? L("report.freed", SizeFormat.text(r.freed)) : nil,
                         r.trashed > 0 ? L("report.trashed", SizeFormat.text(r.trashed)) : nil,
                         r.adminCancelled ? L("report.adminCancelled") : nil,
                         r.failures.isEmpty || r.adminCancelled ? nil : L("report.failed", r.failures.count)]
            Text(parts.compactMap { $0 }.joined(separator: " ")).socle(Socle.T.label).foregroundStyle(r.failures.isEmpty ? Socle.C.success : Socle.C.warning)
        }
    }

    private func work(_ text: String, _ part: Double) -> some View {
        Group {
            VStack(alignment: .leading, spacing: Socle.M.space1_5) {
                Text(text).socle(Socle.T.label).foregroundStyle(Socle.C.text).lineLimit(1)
                ProgressView(value: part).tint(Socle.C.accent)
            }
            Button(L("scan.cancel")) { model.cancelWork() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
        }
    }
}

/// Dernier contrôle : dit ce qui sera effacé pour de bon, ce qui partira à la Corbeille et ce qui demandera le mot de passe.
private struct ConfirmDialog: View {
    @EnvironmentObject private var model: AppModel
    let items: [JunkItem]
    let title: String
    let button: String
    @Binding var shown: Bool
    let onConfirm: () -> Void

    var body: some View {
        let deleted = model.total(ofSelected: items, .delete)
        let trashed = model.total(ofSelected: items, .trash)
        let admin = model.total(ofSelected: items, .admin)
        let snapshots = items.filter { $0.disposal == .snapshot }.count
        ZStack {
            Socle.C.scrim.ignoresSafeArea().onTapGesture { shown = false }
            VStack(alignment: .leading, spacing: Socle.M.space3) {
                Text(title).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong).fixedSize(horizontal: false, vertical: true)
                if deleted > 0 { line(L("confirm.delete", SizeFormat.text(deleted))) }
                if trashed > 0 { line(L("confirm.trash", SizeFormat.text(trashed))) }
                if admin > 0 { line(L("confirm.admin", SizeFormat.text(admin))) }
                if snapshots > 0 { line(L("confirm.snapshots", snapshots)) }
                if items.contains(where: { $0.category == .languages }) { line(L("confirm.languages"), warning: true) }
                if items.contains(where: \.inUse) { line(L("confirm.inUse"), warning: true) }
                HStack(spacing: Socle.M.space2) {
                    Spacer()
                    Button(L("confirm.cancel")) { shown = false }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize().keyboardShortcut(.cancelAction)
                    Button(button) { shown = false; onConfirm() }.buttonStyle(SocleButtonStyle(.action)).fixedSize()
                }
            }
            .padding(Socle.M.space5)
            .frame(width: 440)
            .background(Socle.C.surface)
            .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border))
        }
    }

    private func line(_ text: String, warning: Bool = false) -> some View {
        Text(text).socle(Socle.T.body).foregroundStyle(warning ? Socle.C.warning : Socle.C.text).fixedSize(horizontal: false, vertical: true)
    }
}

/// Onglet Applications : liste des applis, puis l'appli choisie avec les fichiers qu'elle a laissés.
private struct AppsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var dropTargeted = false
    @State private var rejected = 0

    private var shown: [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? model.apps : model.apps.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
        return model.sizesReady ? list.sorted { $0.size > $1.size } : list
    }

    var body: some View {
        HStack(spacing: Socle.M.space3) {
            Panel {
                VStack(spacing: 0) {
                    TextField(L("apps.search"), text: $query).socleField().padding(Socle.M.space2)
                    if model.apps.isEmpty {
                        Text(L("apps.loading")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) { ForEach(shown) { row($0) } }
                        }
                    }
                }
            }
            .frame(width: 330)
            Panel {
                VStack(alignment: .leading, spacing: 0) {
                    if let app = model.selectedApp {
                        PanelHeader(title: app.name, trailing: L("list.trashTag"))
                        Text(L("apps.help")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Socle.M.space3).padding(.vertical, Socle.M.space2)
                        ScrollView {
                            LazyVStack(spacing: 0) { ForEach(model.related) { relatedRow($0) } }
                        }
                    } else {
                        Text(L("apps.select") + "\n" + L("apps.dropHint")).multilineTextAlignment(.center).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Socle.C.surfaceSelected.opacity(0.4))
                    .overlay(Text(L("apps.drop")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if rejected > 0 {
                Text(L("apps.dropRejected")).socle(Socle.T.meta).foregroundStyle(Socle.C.warning)
                    .padding(Socle.M.space2).background(Socle.C.surfaceRaised, in: RoundedRectangle(cornerRadius: Socle.M.radius))
                    .padding(Socle.M.space2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task {
                rejected = await model.addDroppedApps(urls)
                if rejected > 0 { try? await Task.sleep(nanoseconds: 4_000_000_000); rejected = 0 }
            }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private func row(_ app: AppEntry) -> some View {
        HStack(spacing: Socle.M.space2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 18, height: 18)
            Text(app.name).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1)
            Spacer()
            Text(app.size > 0 || model.sizesReady ? SizeFormat.text(app.size) : "…").socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
        }
        .padding(.horizontal, Socle.M.space3)
        .frame(height: 30)
        .background(model.selectedApp?.path == app.path ? Socle.C.surfaceSelected : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.select(app) }
    }

    private func relatedRow(_ item: JunkItem) -> some View {
        let chosen = model.relatedSelection.contains(item.path)
        let isApp = item.path == model.selectedApp?.path
        return HStack(spacing: Socle.M.space2) {
            CheckBox(state: chosen ? .on : .off) {
                if chosen { model.relatedSelection.remove(item.path) } else { model.relatedSelection.insert(item.path) }
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle)
                if !isApp {
                    Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: model.home.path, with: "~")).socle(Socle.T.caption)
                        .foregroundStyle(Socle.C.textMuted).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            Text(SizeFormat.text(item.size)).socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
        }
        .padding(.horizontal, Socle.M.space3)
        .frame(height: 36)
        .help(item.path)
    }
}
