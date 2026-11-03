import AppKit
import HdCleanerCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, monitor, exclusions, updates
    var title: String {
        switch self {
        case .general: L("settings.general")
        case .monitor: L("settings.monitor")
        case .exclusions: L("settings.exclusions")
        case .updates: L("settings.updates")
        }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(model: AppModel, tab: SettingsTab? = nil) {
        // L'onglet voulu est lu par SettingsView à sa création ; une fenêtre déjà ouverte est reconstruite pour le prendre en compte.
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") } else { UserDefaults.standard.removeObject(forKey: "settingsTab") }
        if window == nil || tab != nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(model))
            hosting.sizingOptions = .preferredContentSize
            if let window { window.contentViewController = hosting } else {
                let w = NSWindow(contentViewController: hosting)
                w.styleMask = [.titled, .closable]
                w.title = L("settings.title")
                w.isReleasedWhenClosed = false
                w.center()
                window = w
            }
        }
        window?.present()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State var tab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .general
    @State private var atLogin = LoginAgent.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            SocleSegmented(options: SettingsTab.allCases, selection: tab, label: { $0.title }, onSelect: { tab = $0 })
            switch tab {
            case .general: general
            case .monitor: monitor
            case .exclusions: exclusions
            case .updates: updates
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
            .socle(Socle.T.label).disabled(!model.keepsRunningWithoutWindow)
        }
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            Toggle(L("updates.auto"), isOn: $model.settings.autoUpdate).socle(Socle.T.label)
            Text(L("updates.autoHelp")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            Text(L("updates.current", model.updater.currentVersion)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
            Text(updateStatus).socle(Socle.T.body).foregroundStyle(updateIsError ? Socle.C.danger : Socle.C.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Socle.M.space2) {
                Button(L("updates.check")) { model.updater.checkNow() }
                    .buttonStyle(SocleButtonStyle(.secondary)).disabled(model.updater.isBusy)
                if case .available(let plan) = model.updater.state {
                    Button(L("updates.install")) { model.updater.present(plan) }.buttonStyle(SocleButtonStyle(.primary))
                }
            }
        }
    }

    private var updateIsError: Bool { if case .failed = model.updater.state { true } else { false } }

    private var updateStatus: String {
        switch model.updater.state {
        case .idle: L("updates.idle")
        case .checking: L("updates.checking")
        case .upToDate: L("updates.upToDate")
        case .available(let plan): L("updates.available", plan.target.version)
        case .downloading: L("updates.downloading", model.updater.plan?.target.version ?? "")
        case .verifying: model.updater.message(for: "verifying")
        case .installing: L("updates.installing")
        case .failed(let key): model.updater.message(for: key)
        }
    }

    private func addExclusions() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.directoryURL = model.home
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !model.settings.excludedPaths.contains(url.standardizedFileURL.path) { model.settings.excludedPaths.append(url.standardizedFileURL.path) }
    }

    private var exclusions: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            HStack(alignment: .top) {
                Text(L("settings.exclusionsHelp")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("settings.add")) { addExclusions() }.buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize()
            }
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
