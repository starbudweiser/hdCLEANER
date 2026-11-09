import AppKit
import HdCleanerCore
import SwiftUI

extension Mode {
    /// Groupes de la barre latérale : le premier n'a pas de titre.
    static let groups: [(title: String?, modes: [Mode])] = [
        (nil, [.overview]),
        ("sidebar.clean", [.clean, .apps, .duplicates, .organize]),
        ("sidebar.analyze", [.map, .timeline, .security]),
        ("sidebar.tools", [.maintenance, .permissions, .invisibles]),
    ]

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .clean: "sparkles"
        case .apps: "macwindow"
        case .duplicates: "doc.on.doc"
        case .organize: "tray.2"
        case .map: "rectangle.split.3x3"
        case .timeline: "chart.xyaxis.line"
        case .security: "checkmark.shield"
        case .maintenance: "wrench.and.screwdriver"
        case .permissions: "lock.open"
        case .invisibles: "eye.slash"
        }
    }

    var title: String { L("mode.\(self)") }
    var subtitle: String {
        switch self {
        case .overview: L("page.overview")
        case .clean: L("page.clean")
        case .apps: L("page.apps")
        case .duplicates: L("page.duplicates")
        case .organize: L("page.organize")
        case .map: L("page.map")
        case .timeline: L("page.timeline")
        case .security: L("page.security")
        case .maintenance: L("page.maintenance")
        case .permissions: L("page.permissions")
        case .invisibles: L("page.invisibles")
        }
    }
}

/// Barre latérale : modes groupés, réglages, à propos et l'espace libre du disque.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                Text(branded: "hdCLEANER").socle(Socle.T.heading).padding(.horizontal, Socle.M.space2).padding(.top, Socle.M.space2).padding(.bottom, Socle.M.space3)
                ForEach(Array(Mode.groups.enumerated()), id: \.offset) { _, group in
                    if let key = group.title {
                        Text(L(key)).socle(Socle.T.caption).foregroundStyle(Socle.C.textSubtle)
                            .padding(.horizontal, Socle.M.space2).padding(.top, Socle.M.space3).padding(.bottom, Socle.M.space1)
                    }
                    ForEach(group.modes, id: \.self) { item($0) }
                }
                Spacer(minLength: Socle.M.space3)
                action("gearshape", L("settings.title")) { SettingsWindow.show(model: model) }
                action("info.circle", L("sidebar.about")) { About.show() }
                diskFooter.padding(.top, Socle.M.space2)
            }
            .padding(Socle.M.space2)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DiskWatermark())
            .clipShape(RoundedRectangle(cornerRadius: Socle.M.radius))
        }
    }

    private func item(_ mode: Mode) -> some View {
        let on = model.mode == mode
        return Button {
            model.mode = mode
            if mode == .apps { model.loadApps() }
        } label: {
            HStack(spacing: Socle.M.space2) {
                Image(systemName: mode.symbol).font(.system(size: 12)).frame(width: 16)
                Text(mode.title).socle(Socle.T.body).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? Socle.C.textStrong : Socle.C.textMuted)
            .padding(.horizontal, Socle.M.space2)
            .frame(height: 28)
            .background(on ? Socle.C.surfaceSelected : Color.clear, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func action(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: Socle.M.space2) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).socle(Socle.T.body).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Socle.C.textMuted)
            .padding(.horizontal, Socle.M.space2)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var diskFooter: some View {
        let disk = model.disk
        let ratio = disk.map { $0.total > 0 ? Double($0.used) / Double($0.total) : 0 } ?? 0
        return VStack(alignment: .leading, spacing: Socle.M.space1_5) {
            Rectangle().fill(Socle.C.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(SizeFormat.text(disk?.available ?? 0)).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
                Text(L("sidebar.free", disk?.name ?? "")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(1)
            }
            .padding(.top, Socle.M.space1_5)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Socle.C.control)
                    Rectangle().fill(model.belowThreshold ? Socle.C.danger : Socle.C.textSubtle).frame(width: geo.size.width * ratio)
                }
            }
            .frame(height: 4)
            if model.settings.monitorEnabled {
                HStack(spacing: Socle.M.space1_5) {
                    Circle().fill(model.belowThreshold ? Socle.C.danger : Socle.C.success).frame(width: 6, height: 6)
                    Text(L(model.belowThreshold ? "monitor.below" : "monitor.badge", model.monitoredDisk?.name ?? "–")).socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Socle.M.space2)
    }
}

/// En-tête commun à tous les panneaux : titre, une phrase, et les actions à droite.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: Socle.M.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                Text(subtitle).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Socle.M.space3)
            HStack(spacing: Socle.M.space2) { actions }.fixedSize()
        }
    }
}

/// Aperçu : où va l'espace du disque, ce qui se nettoie sans risque et ce qui demande un coup d'œil.
struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var confirming: Bool

    private var busy: Bool { if case .idle = model.phase { false } else { true } }

    private var rows: [(JunkCategory, Int64)] {
        JunkCategory.allCases.compactMap { c in
            let bytes = model.result?.total(c) ?? 0
            return bytes > 0 && c != .snapshots ? (c, bytes) : nil
        }
        .sorted { $0.1 > $1.1 }
    }

    private var found: Int64 { rows.reduce(0) { $0 + $1.1 } }
    private var safeGain: Int64 { model.selectedItems.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            PageHeader(title: Mode.overview.title, subtitle: model.result == nil ? L("ov.notScanned") : L("ov.scanned")) {
                Button(L("ov.scan")) { model.scan() }.buttonStyle(SocleButtonStyle(.secondary)).disabled(busy)
                Button(L("ov.cleanSafe", SizeFormat.text(safeGain))) { model.mode = .clean; confirming = true }
                    .buttonStyle(SocleButtonStyle(.action)).disabled(busy || model.selection.isEmpty)
            }
            if case .scanning(let category, let part) = model.phase {
                VStack(alignment: .leading, spacing: Socle.M.space1_5) {
                    Text(L("scan.running", category.title)).socle(Socle.T.label).foregroundStyle(Socle.C.text).lineLimit(1)
                    ProgressView(value: part).tint(Socle.C.accent)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Socle.M.space2) {
                Text(SizeFormat.text(model.disk?.used ?? 0)).font(.system(size: 28, weight: .medium)).foregroundStyle(Socle.C.textStrong)
                Text(L("ov.usedOf", SizeFormat.text(model.disk?.total ?? 0))).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                Spacer()
            }
            usageBar
            ScrollView {
                VStack(spacing: Socle.M.space3) {
                    if model.result != nil {
                        Panel { VStack(spacing: 0) { ForEach(Array(rows.enumerated()), id: \.offset) { i, r in categoryRow(r.0, r.1, last: i == rows.count - 1) } } }
                    }
                    Panel {
                        VStack(spacing: 0) {
                            line("ellipsis.circle", Socle.C.textSubtle, L("ov.other"), L("ov.otherHelp"), SizeFormat.text(max((model.disk?.used ?? 0) - found, 0)), last: false)
                            purgeableRow
                            line("circle.dotted", Socle.C.borderControl, L("ov.free"), L("ov.freeHelp"), SizeFormat.text(model.disk?.available ?? 0), last: true)
                        }
                    }
                    if let trash = model.result?.total(.trash), trash > 0 {
                        Text(L("ov.trashNote", SizeFormat.text(trash))).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.result == nil {
                        Text(L("scan.welcomeHelp")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var usageBar: some View {
        let disk = model.disk
        let junk = rows.map { (color: $0.0.color, bytes: $0.1) }
        let segments = junk + [(color: Socle.C.textSubtle, bytes: max((disk?.used ?? 0) - found, 0)), (color: Socle.C.control, bytes: disk?.available ?? 0)]
        let total = max(segments.reduce(0) { $0 + $1.bytes }, 1)
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(s.color).frame(width: max(CGFloat(Double(s.bytes) / Double(total)) * geo.size.width - 1, 1))
                }
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func categoryRow(_ c: JunkCategory, _ bytes: Int64, last: Bool) -> some View {
        let safe = c.preselected
        return Button {
            model.category = c
            model.mode = .clean
        } label: {
            line("circle.fill", c.color, c.title, detail(c), SizeFormat.text(bytes), last: last, badge: safe ? L("ov.safe") : L("ov.review"), safe: safe)
        }
        .buttonStyle(.plain)
    }

    private func detail(_ c: JunkCategory) -> String {
        let tag: String = switch c.disposal {
        case .delete: L("list.deleteTag")
        case .trash: L("list.trashTag")
        case .admin: L("list.adminTag")
        case .snapshot: L("list.snapshotTag")
        }
        return L("ov.items", model.result?.items[c]?.count ?? 0) + " · " + tag
    }

    @ViewBuilder private var purgeableRow: some View {
        let purgeable = model.disk?.purgeable ?? 0
        if purgeable > 0 {
            HStack(spacing: Socle.M.space3) {
                iconBox("clock.arrow.circlepath", Socle.C.textSubtle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("ov.purgeable")).socle(Socle.T.body).foregroundStyle(Socle.C.text)
                    Text(L("ov.purgeableHelp")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(1)
                }
                Spacer()
                if let snaps = model.result?.items[.snapshots], !snaps.isEmpty {
                    Button(L("disk.free.button")) {
                        model.selection = Set(snaps.map(\.path))
                        model.category = .snapshots
                        model.mode = .clean
                        confirming = true
                    }
                    .buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize()
                }
                Text(SizeFormat.text(purgeable)).socle(Socle.T.label).monospacedDigit().foregroundStyle(Socle.C.textStrong)
            }
            .padding(.horizontal, Socle.M.space3).frame(height: 44)
            .overlay(alignment: .bottom) { Rectangle().fill(Socle.C.borderSubtle).frame(height: 1) }
        }
    }

    private func iconBox(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: Socle.M.radius))
    }

    private func line(_ symbol: String, _ color: Color, _ title: String, _ help: String, _ size: String, last: Bool, badge: String? = nil, safe: Bool = false) -> some View {
        HStack(spacing: Socle.M.space3) {
            iconBox(symbol, color)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Socle.M.space1_5) {
                    Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1)
                    if let badge {
                        Text(badge).socle(Socle.T.caption).foregroundStyle(safe ? Socle.C.success : Socle.C.warning)
                            .padding(.horizontal, Socle.M.space1_5).padding(.vertical, 1)
                            .background(safe ? Socle.C.successBg : Socle.C.warningBg, in: RoundedRectangle(cornerRadius: Socle.M.radius))
                    }
                }
                Text(help).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(1)
            }
            Spacer()
            Text(size).socle(Socle.T.label).monospacedDigit().foregroundStyle(Socle.C.textStrong)
        }
        .padding(.horizontal, Socle.M.space3).frame(height: 44)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Socle.C.borderSubtle).frame(height: 1) } }
    }
}
