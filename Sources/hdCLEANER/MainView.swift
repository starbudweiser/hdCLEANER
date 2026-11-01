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
                    DiskPanel()
                    if model.result == nil {
                        WelcomePanel()
                    } else {
                        HStack(spacing: Socle.M.space3) {
                            CategoryPanel().frame(width: 330)
                            ItemsPanel()
                        }
                    }
                    FooterPanel(confirming: $confirming)
                }
            }
            .padding(Socle.M.space3)
            if confirming { ConfirmDialog(shown: $confirming) }
        }
        .frame(minWidth: 980, minHeight: 600)
        .background(Socle.C.bg)
    }
}

private struct Panel<Content: View>: View {
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
        }
    }
}

private struct DiskPanel: View {
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
                        if let r = model.result { Text(L("disk.junk", SizeFormat.text(r.total))) }
                    }
                    .socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                }
            }
            .padding(Socle.M.space3)
        }
    }

    private var monitorBadge: some View {
        HStack(spacing: Socle.M.space1_5) {
            Circle().fill(model.belowThreshold ? Socle.C.danger : Socle.C.success).frame(width: 8, height: 8)
            Text(L(model.belowThreshold ? "monitor.below" : "monitor.badge")).socle(Socle.T.meta).foregroundStyle(Socle.C.text)
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
private struct CheckBox: View {
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
        }
        .buttonStyle(.plain)
    }
}

private struct PanelHeader: View {
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
        let total = model.result?.total(c) ?? 0
        let denied = model.result?.denied.contains(c) == true
        return HStack(spacing: Socle.M.space2) {
            CheckBox(state: state(c)) { model.setSelected(state(c) == .off, category: c) }.disabled(total == 0)
            Circle().fill(c.color).frame(width: 9, height: 9)
            Text(c.title).socle(Socle.T.body).foregroundStyle(total > 0 ? Socle.C.text : Socle.C.textMuted).lineLimit(1)
            if denied { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Socle.C.warning) }
            Spacer()
            Text(total > 0 ? SizeFormat.text(total) : "–").socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
        }
        .padding(.horizontal, Socle.M.space3)
        .frame(height: 30)
        .background(model.category == c ? Socle.C.surfaceSelected : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.category = c }
    }
}

private struct ItemsPanel: View {
    @EnvironmentObject private var model: AppModel

    private var items: [JunkItem] { model.result?.items[model.category] ?? [] }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(title: model.category.title, trailing: L(model.category.disposal == .delete ? "list.deleteTag" : "list.trashTag"))
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
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 16, height: 16)
            Text(item.name).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle).help(item.path)
            if item.inUse {
                Text(L("list.inUse")).socle(Socle.T.caption).foregroundStyle(Socle.C.warning)
                    .padding(.horizontal, Socle.M.space1).background(Socle.C.bgSunken, in: RoundedRectangle(cornerRadius: 2))
            }
            Spacer()
            Text(SizeFormat.text(item.size)).socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Socle.C.textMuted)
            }
            .buttonStyle(.plain).help(L("list.reveal"))
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

    var body: some View {
        Panel {
            HStack(spacing: Socle.M.space3) {
                switch model.phase {
                case .idle:
                    Button(L(model.result == nil ? "scan.start" : "scan.again")) { model.scan() }
                        .buttonStyle(SocleButtonStyle(.primary)).fixedSize()
                    message
                    Spacer()
                    if model.result != nil {
                        Text(L("clean.gain", SizeFormat.text(gain))).socle(Socle.T.label).foregroundStyle(Socle.C.text)
                        Button(L("clean.button")) { confirming = true }
                            .buttonStyle(SocleButtonStyle(.action)).fixedSize().disabled(model.selection.isEmpty)
                    }
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

    @ViewBuilder private var message: some View {
        if let r = model.report {
            let parts = [r.freed > 0 ? L("report.freed", SizeFormat.text(r.freed)) : nil,
                         r.trashed > 0 ? L("report.trashed", SizeFormat.text(r.trashed)) : nil,
                         r.failures.isEmpty ? nil : L("report.failed", r.failures.count)]
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

/// Dernier contrôle : dit ce qui sera effacé pour de bon et ce qui partira à la Corbeille.
private struct ConfirmDialog: View {
    @EnvironmentObject private var model: AppModel
    @Binding var shown: Bool

    var body: some View {
        let items = model.selectedItems
        let deleted = model.total(ofSelected: items, .delete)
        let trashed = model.total(ofSelected: items, .trash)
        ZStack {
            Socle.C.scrim.ignoresSafeArea().onTapGesture { shown = false }
            VStack(alignment: .leading, spacing: Socle.M.space3) {
                Text(L("confirm.title", items.count)).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                if deleted > 0 { Text(L("confirm.delete", SizeFormat.text(deleted))).socle(Socle.T.body).foregroundStyle(Socle.C.text).fixedSize(horizontal: false, vertical: true) }
                if trashed > 0 { Text(L("confirm.trash", SizeFormat.text(trashed))).socle(Socle.T.body).foregroundStyle(Socle.C.text).fixedSize(horizontal: false, vertical: true) }
                if items.contains(where: \.inUse) { Text(L("confirm.inUse")).socle(Socle.T.body).foregroundStyle(Socle.C.warning).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: Socle.M.space2) {
                    Spacer()
                    Button(L("confirm.cancel")) { shown = false }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize().keyboardShortcut(.cancelAction)
                    Button(L("clean.button")) { shown = false; model.clean() }.buttonStyle(SocleButtonStyle(.action)).fixedSize()
                }
            }
            .padding(Socle.M.space5)
            .frame(width: 440)
            .background(Socle.C.surface)
            .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border))
        }
    }
}
