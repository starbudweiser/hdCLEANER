import AppKit
import HdCleanerCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, monitor, exclusions
    var title: String {
        switch self {
        case .general: L("settings.general")
        case .monitor: L("settings.monitor")
        case .exclusions: L("settings.exclusions")
        }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(model))
            hosting.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable]
            w.title = L("menu.settings")
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.present()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State var tab = SettingsTab.general
    @State private var atLogin = LoginAgent.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            SocleSegmented(options: SettingsTab.allCases, selection: tab, label: { $0.title }, onSelect: { tab = $0 })
            switch tab {
            case .general: general
            case .monitor: monitor
            case .exclusions: exclusions
            }
            Spacer(minLength: 0)
        }
        .padding(Socle.M.space5)
        .frame(width: 480, height: 380, alignment: .topLeading)
        .background(Socle.C.bg)
        .toggleStyle(.switch)
        .onAppear { model.refreshDisk() } // liste des volumes à jour (disque externe branché depuis)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Text(L("settings.theme")).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
            SocleSegmented(options: ThemeChoice.allCases, selection: model.settings.theme, label: { L("theme.\($0.rawValue)") }, onSelect: { model.settings.theme = $0 })
            Text(L("settings.largeFiles", SizeFormat.text(Int64(model.settings.largeFileMinimumMB) * 1_000_000))).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
            Slider(value: Binding(get: { Double(model.settings.largeFileMinimumMB) }, set: { model.settings.largeFileMinimumMB = Int($0) }), in: 100...10000, step: 100)
                .tint(Socle.C.accent)
        }
    }

    private var monitor: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Toggle(L("settings.monitorOn"), isOn: $model.settings.monitorEnabled).socle(Socle.T.label)
            Text(L("settings.monitorHelp")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            Text(L("settings.volume")).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
            Picker("", selection: $model.settings.monitoredVolume) {
                ForEach(model.volumes) { Text("\($0.name)\($0.path == "/" ? L("settings.volumeStartup") : "")").tag($0.path) }
                if !model.volumes.contains(where: { $0.path == model.settings.monitoredVolume }) {
                    Text(URL(fileURLWithPath: model.settings.monitoredVolume).lastPathComponent + L("settings.volumeMissing")).tag(model.settings.monitoredVolume)
                }
            }
            .labelsHidden().pickerStyle(.menu).disabled(!model.settings.monitorEnabled)
            let limit = ThresholdMonitor.limit(total: model.monitoredDisk?.total ?? 0, percent: model.settings.thresholdPercent)
            Text(L("settings.threshold", model.settings.thresholdPercent, SizeFormat.text(limit))).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
            Slider(value: Binding(get: { Double(model.settings.thresholdPercent) }, set: { model.settings.thresholdPercent = Int($0) }), in: 5...50, step: 1)
                .tint(Socle.C.accent).disabled(!model.settings.monitorEnabled)
            Toggle(L("settings.login"), isOn: Binding(get: { atLogin }, set: { on in
                if LoginAgent.set(on) { atLogin = on }
            }))
            .socle(Socle.T.label).disabled(!model.settings.monitorEnabled)
        }
    }

    private var exclusions: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            Text(L("settings.exclusionsHelp")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            if model.settings.excludedPaths.isEmpty {
                Text(L("settings.exclusionsEmpty")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            }
            ScrollView {
                VStack(spacing: Socle.M.space1) {
                    ForEach(model.settings.excludedPaths, id: \.self) { path in
                        HStack {
                            Text(path).socle(Socle.T.monoSm).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(L("settings.remove")) { model.settings.excludedPaths.removeAll { $0 == path } }
                                .buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize()
                        }
                    }
                }
            }
        }
    }
}
