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
                window = w
            }
        }
        guard let window else { return }
        let wasVisible = window.isVisible
        if let view = window.contentViewController?.view { window.setContentSize(view.fittingSize) } // taille de l'onglet, connue avant le centrage
        if !wasVisible { window.socleCenter() }
        window.present()
        if !wasVisible { DispatchQueue.main.async { window.socleCenter() } }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State var tab: SettingsTab
    @State private var atLogin = LoginAgent.enabled

    init(tab: SettingsTab? = nil) {
        _tab = State(initialValue: tab ?? SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .general)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            SocleSegmented(options: SettingsTab.allCases, selection: tab, label: { $0.title }, onSelect: { tab = $0 })
            switch tab {
            case .general: general
            case .monitor: monitor
            case .exclusions: exclusions
            case .updates: updates
            }
        }
        .padding(Socle.M.space5)
        .frame(width: 520, alignment: .topLeading)
        .background(Socle.C.bg)
        .toggleStyle(.switch)
        .onAppear { model.refreshDisk() } // liste des volumes à jour (disque externe branché depuis)
    }

    /// Ligne de réglage : titre et aide à gauche, commande à droite (ou en dessous pour les curseurs).
    private func row<C: View>(_ title: String, help: String? = nil, stacked: Bool = false, @ViewBuilder _ control: () -> C) -> some View {
        let head = VStack(alignment: .leading, spacing: 2) {
            Text(title).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
            if let help { Text(help).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true) }
        }
        return Group {
            if stacked {
                VStack(alignment: .leading, spacing: Socle.M.space2) { head; control() }
            } else {
                HStack(alignment: .center, spacing: Socle.M.space4) { head; Spacer(minLength: Socle.M.space3); control() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Socle.M.space3)
    }

    /// Groupe de lignes dans une carte, séparées par un filet.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, Socle.M.space4)
            .background(Socle.C.surface)
            .overlay(Rectangle().stroke(Socle.C.border, lineWidth: 1))
    }

    private var rule: some View { Rectangle().fill(Socle.C.borderSubtle).frame(height: 1) }

    private var general: some View {
        card {
            row(L("settings.theme"), stacked: true) {
                SocleSegmented(options: ThemeChoice.allCases, selection: model.settings.theme, label: { L("theme.\($0.rawValue)") }, onSelect: { model.settings.theme = $0 })
            }
            rule
            row(L("settings.largeFiles", SizeFormat.text(Int64(model.settings.largeFileMinimumMB) * 1_000_000)), stacked: true) {
                Slider(value: Binding(get: { Double(model.settings.largeFileMinimumMB) }, set: { model.settings.largeFileMinimumMB = Int($0) }), in: 100...10000, step: 100)
                    .tint(Socle.C.accent)
            }
            rule
            row(L("sec.realtime"), help: L("sec.realtimeHelp")) {
                Toggle("", isOn: $model.settings.realtimeProtection).labelsHidden()
            }
            rule
            row(L("settings.loginApp"), help: L("settings.loginHelp")) {
                Toggle("", isOn: Binding(get: { atLogin }, set: { on in
                    if LoginAgent.set(on) { atLogin = on; model.onMonitorChange?() }
                })).labelsHidden()
            }
        }
    }

    private var monitor: some View {
        card {
            row(L("settings.monitorOn"), help: L("settings.monitorHelp")) {
                Toggle("", isOn: $model.settings.monitorEnabled).labelsHidden()
            }
            rule
            row(L("settings.volume")) {
                Picker("", selection: $model.settings.monitoredVolume) {
                    ForEach(model.volumes) { Text("\($0.name)\($0.path == "/" ? L("settings.volumeStartup") : "")").tag($0.path) }
                    if !model.volumes.contains(where: { $0.path == model.settings.monitoredVolume }) {
                        Text(URL(fileURLWithPath: model.settings.monitoredVolume).lastPathComponent + L("settings.volumeMissing")).tag(model.settings.monitoredVolume)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            .disabled(!model.settings.monitorEnabled)
            rule
            let limit = ThresholdMonitor.limit(total: model.monitoredDisk?.total ?? 0, percent: model.settings.thresholdPercent)
            row(L("settings.threshold", model.settings.thresholdPercent, SizeFormat.text(limit)), stacked: true) {
                Slider(value: Binding(get: { Double(model.settings.thresholdPercent) }, set: { model.settings.thresholdPercent = Int($0) }), in: 5...50, step: 1)
                    .tint(Socle.C.accent)
            }
            .disabled(!model.settings.monitorEnabled)
        }
    }

    private var updates: some View {
        card {
            row(L("updates.auto"), help: L("updates.autoHelp")) {
                Toggle("", isOn: $model.settings.autoUpdate).labelsHidden()
            }
            rule
            row(L("updates.current", model.updater.currentVersion), help: updateStatus, stacked: true) {
                HStack(spacing: Socle.M.space2) {
                    Button(L("updates.check")) { model.updater.checkNow() }
                        .buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize().disabled(model.updater.isBusy)
                    if case .available(let plan) = model.updater.state {
                        Button(L("updates.install")) { model.updater.present(plan) }.buttonStyle(SocleButtonStyle(.primary, height: 28)).fixedSize()
                    }
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
            HStack(alignment: .top, spacing: Socle.M.space4) {
                Text(L("settings.exclusionsHelp")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L("settings.add")) { addExclusions() }.buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize()
            }
            if model.settings.excludedPaths.isEmpty {
                Text(L("settings.exclusionsEmpty")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(Socle.C.surface).overlay(Rectangle().stroke(Socle.C.border, lineWidth: 1))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.settings.excludedPaths.enumerated()), id: \.element) { i, path in
                            if i > 0 { rule }
                            HStack(spacing: Socle.M.space3) {
                                Text(path).socle(Socle.T.monoSm).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Button(L("settings.remove")) { model.settings.excludedPaths.removeAll { $0 == path } }
                                    .buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize()
                            }
                            .padding(.vertical, Socle.M.space2)
                        }
                    }
                    .padding(.horizontal, Socle.M.space4)
                }
                .frame(height: 220)
                .background(Socle.C.surface).overlay(Rectangle().stroke(Socle.C.border, lineWidth: 1))
            }
        }
    }
}
