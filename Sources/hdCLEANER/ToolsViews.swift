import AppKit
import HdCleanerCore
import SwiftUI
import UniformTypeIdentifiers

/// Fenêtre de confirmation commune aux outils : titre, lignes d'explication, un bouton d'action.
struct ToolConfirm: View {
    let title: String
    let lines: [(String, Bool)]
    let button: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Socle.C.scrim.ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: Socle.M.space3) {
                Text(title).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.0).socle(Socle.T.body).foregroundStyle(line.1 ? Socle.C.warning : Socle.C.text).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Socle.M.space2) {
                    Spacer()
                    Button(L("confirm.cancel"), action: onCancel).buttonStyle(SocleButtonStyle(.secondary)).fixedSize().keyboardShortcut(.cancelAction)
                    Button(button, action: onConfirm).buttonStyle(SocleButtonStyle(.action)).fixedSize()
                }
            }
            .padding(Socle.M.space5)
            .frame(width: 460)
            .background(Socle.C.surface)
            .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border))
        }
    }
}

/// Zone de texte à chasse fixe pour la sortie des scripts.
private struct LogView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? " " : text).socle(Socle.T.monoSm).foregroundStyle(Socle.C.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Socle.M.space2).id("end")
            }
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(Socle.C.bgSunken)
    }
}

func chooseURLs(files: Bool, multiple: Bool, directory: URL?) -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseFiles = files
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = multiple
    panel.showsHiddenFiles = true
    panel.directoryURL = directory
    return panel.runModal() == .OK ? panel.urls : []
}

// MARK: Entretien

struct MaintenanceView: View {
    @ObservedObject var model: MaintenanceModel

    var body: some View {
        VStack(spacing: Socle.M.space3) {
            Panel {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(MaintenanceTask.allCases) { row($0) } }
                }
            }
            Panel {
                VStack(spacing: 0) {
                    HStack {
                        Text(L("maintenance.log")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                        Spacer()
                        if model.running != nil { Button(L("scan.cancel")) { model.stop() }.buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize() }
                        else if !model.log.isEmpty { Button(L("maintenance.clear")) { model.clearLog() }.buttonStyle(SocleButtonStyle(.tertiary, height: 24)).fixedSize() }
                    }
                    .padding(.horizontal, Socle.M.space3).frame(height: 32).background(Socle.C.surfaceRaised)
                    LogView(text: model.log)
                }
            }
            .frame(height: 170)
        }
    }

    private func row(_ task: MaintenanceTask) -> some View {
        HStack(alignment: .top, spacing: Socle.M.space3) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Socle.M.space2) {
                    Text(task.title).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
                    if task.needsAdmin {
                        Text(L("maintenance.admin")).socle(Socle.T.caption).foregroundStyle(Socle.C.warning)
                            .padding(.horizontal, Socle.M.space1).background(Socle.C.bgSunken, in: RoundedRectangle(cornerRadius: 2))
                    }
                    if let ok = model.results[task] {
                        Image(systemName: ok ? "checkmark.circle" : "xmark.circle").font(.system(size: 12)).foregroundStyle(ok ? Socle.C.success : Socle.C.danger)
                    }
                }
                Text(task.help).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // « Lancer » en jaune Socle (action) ; la tâche en cours passe en bleu Socle (primaire), les autres s'estompent le temps qu'elle tourne.
            Button(model.running == task ? L("maintenance.running") : L("maintenance.run")) { model.run(task) }
                .buttonStyle(SocleButtonStyle(model.running == task ? .primary : .action, height: 28)).fixedSize()
                .disabled(model.running != nil && model.running != task)
        }
        .padding(.horizontal, Socle.M.space3).padding(.vertical, Socle.M.space2)
    }
}

// MARK: Permissions et flags

struct PermissionsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: PermissionsModel
    @State private var confirming = false

    private var issues: [PermissionPlan.Issue] { model.advanced ? model.issues(home: app.home) : model.repairPlan.issues(home: app.home).filter { $0 != .nothingToDo } }
    /// « Rien à faire » ne s'affiche pas tant qu'aucune cible n'est choisie : une seule consigne à la fois.
    private var visibleIssues: [PermissionPlan.Issue] { issues.contains(.noTarget) ? [.noTarget] : issues }

    var body: some View {
        ZStack {
            VStack(spacing: Socle.M.space3) {
                HStack(spacing: Socle.M.space3) {
                    targets.frame(width: 300)
                    if model.advanced { options } else { simplePanel }
                }
                if model.advanced { bottom } else { simpleBottom }
            }
            if confirming { confirm }
        }
    }

    // Cibles

    private var targets: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(title: L("perm.targets"), trailing: "\(model.targets.count)")
                if model.targets.isEmpty {
                    Text(L("perm.drop")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(Socle.M.space3)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.targets, id: \.self) { path in
                                HStack(spacing: Socle.M.space2) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
                                    Text(path.replacingOccurrences(of: app.home.path, with: "~")).socle(Socle.T.meta).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle).help(path)
                                    Spacer()
                                    Button { model.remove(path) } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Socle.C.textMuted) }
                                        .buttonStyle(.plain).help(L("perm.remove"))
                                }
                                .padding(.horizontal, Socle.M.space3).frame(height: 26)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Socle.M.space2) {
                    HStack(spacing: Socle.M.space2) {
                        Button(L("perm.add")) { model.add(chooseURLs(files: true, multiple: true, directory: app.home).map(\.path)) }
                            .buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize()
                        Menu(L("perm.volume")) {
                            ForEach(app.volumes) { v in Button(v.name) { model.add([v.path == "/" ? app.home.path : v.path]) } }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    Toggle(L("perm.recursive"), isOn: $model.recursive).socle(Socle.T.body).toggleStyle(.switch)
                    if model.advanced {
                        Text(L("perm.scope")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                        SocleSegmented(options: PermissionPlan.Scope.allCases, selection: model.scope, label: { L("scope.\($0.rawValue)") }, onSelect: { model.scope = $0 })
                    }
                }
                .padding(Socle.M.space3)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.add(urls.map(\.path)); return true }
    }

    // Options

    private func flagRow(_ title: String, _ keyPath: WritableKeyPath<PermissionPlan.Flags, FlagChange>) -> some View {
        HStack {
            Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text)
            Spacer()
            SocleSegmented(options: FlagChange.allCases, selection: model.flags[keyPath: keyPath], label: { L("change.\($0.rawValue)") }, onSelect: { model.flags[keyPath: keyPath] = $0 })
                .frame(width: 270)
        }
    }

    private func modeRow(_ title: String, _ binding: Binding<String>, presets: [String]) -> some View {
        HStack(spacing: Socle.M.space2) {
            Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text)
            Spacer()
            Menu(L("perm.presets")) {
                Button(L("change.keep")) { binding.wrappedValue = "" }
                ForEach(presets, id: \.self) { m in Button(m) { binding.wrappedValue = m } }
            }
            .menuStyle(.borderlessButton).fixedSize()
            TextField(L("perm.modeHint"), text: binding).socleField().frame(width: 190)
        }
    }

    private var modeSwitch: some View {
        SocleSegmented(options: [false, true], selection: model.advanced, label: { L($0 ? "perm.mode.advanced" : "perm.mode.simple") }, onSelect: { model.advanced = $0 })
    }

    // Mode simple

    private func bullet(_ key: String, symbol: String = "checkmark", tint: Color = Socle.C.success) -> some View {
        HStack(alignment: .top, spacing: Socle.M.space2) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint).frame(width: 14).padding(.top, 2)
            Text(L(key)).socle(Socle.T.body).foregroundStyle(Socle.C.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func count(_ n: Int, _ key: String) -> some View {
        HStack(spacing: Socle.M.space2) {
            Text("\(n)").socle(Socle.T.stat).monospacedDigit().foregroundStyle(n > 0 ? Socle.C.warning : Socle.C.textMuted).frame(minWidth: 40, alignment: .trailing)
            Text(L(key)).socle(Socle.T.body).foregroundStyle(Socle.C.text)
        }
    }

    private var diagnosisCard: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            if model.diagnosing {
                Text(L("perm.diagnosing", model.diagnosingCount)).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            } else if let d = model.diagnosis {
                if d.problems == 0 {
                    Text(L("perm.noProblem", d.examined)).socle(Socle.T.label).foregroundStyle(Socle.C.success)
                } else {
                    Text(L("perm.problems", d.problems, d.examined)).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.warning)
                    count(d.notOwned, "perm.notOwned")
                    count(d.locked, "perm.locked")
                    count(d.notUsable, "perm.notUsable")
                    ForEach(d.sample.prefix(5), id: \.self) { path in
                        Text(path.replacingOccurrences(of: app.home.path, with: "~")).socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted).lineLimit(1).truncationMode(.middle)
                    }
                }
            } else {
                Text(L("perm.diagnoseHint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Socle.M.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Socle.C.bgInset, in: RoundedRectangle(cornerRadius: Socle.M.radius))
    }

    private var simplePanel: some View {
        Panel {
            ScrollView {
                VStack(alignment: .leading, spacing: Socle.M.space3) {
                    modeSwitch
                    Text(L("perm.simpleTitle")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                    Text(L("perm.simpleIntro")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: Socle.M.space1_5) {
                        Text(L("perm.simpleDoes")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                        bullet("perm.simpleOwner")
                        bullet("perm.simpleLocks")
                        bullet("perm.simpleACL")
                        bullet("perm.simpleRights")
                        bullet("perm.simpleKeeps", symbol: "lock.shield", tint: Socle.C.accent)
                    }
                    diagnosisCard
                }
                .padding(Socle.M.space3)
            }
        }
    }

    private var simpleBottom: some View {
        Panel {
            VStack(alignment: .leading, spacing: Socle.M.space2) {
                if !model.log.isEmpty, model.diagnosis?.problems ?? 0 > 0 {
                    LogView(text: model.log).frame(height: 60).overlay(RoundedRectangle(cornerRadius: 2).stroke(Socle.C.border))
                }
                HStack(spacing: Socle.M.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message).socle(Socle.T.meta).foregroundStyle(issue == .noTarget ? Socle.C.textMuted : Socle.C.danger).lineLimit(2)
                        }
                        if model.running {
                            Text(L("perm.repairing")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                        } else if model.repaired {
                            Text(L("perm.repaired")).socle(Socle.T.label).foregroundStyle(Socle.C.success)
                        } else if model.needsAdminRetry {
                            Text(L("perm.needsAdmin")).socle(Socle.T.meta).foregroundStyle(Socle.C.warning).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if model.needsAdminRetry && !model.running {
                        Button(L("perm.retryAdmin")) { model.repair(admin: true) }.buttonStyle(SocleButtonStyle(.primary)).fixedSize()
                    }
                    if model.diagnosing {
                        Button(L("scan.cancel")) { model.cancelDiagnosis() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    } else {
                        Button(L("perm.diagnose")) { model.diagnose() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize().disabled(!issues.isEmpty || model.running)
                    }
                    if model.running {
                        Button(L("scan.cancel")) { model.stop() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    } else {
                        Button(L("perm.repair")) { confirming = true }.buttonStyle(SocleButtonStyle(.action)).fixedSize().disabled(!issues.isEmpty || model.diagnosing)
                    }
                }
            }
            .padding(Socle.M.space3)
        }
    }

    // Mode avancé

    private var options: some View {
        Panel {
            ScrollView {
                VStack(alignment: .leading, spacing: Socle.M.space3) {
                    modeSwitch
                    Group {
                        Text(L("perm.flags")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                        flagRow(L("perm.flag.hidden"), \.hidden)
                        flagRow(L("perm.flag.locked"), \.locked)
                        flagRow(L("perm.flag.noDump"), \.noDump)
                        flagRow(L("perm.flag.opaque"), \.opaque)
                        flagRow(L("perm.flag.appendOnly"), \.appendOnly)
                        Toggle(L("perm.flagClearAll"), isOn: $model.flags.clearAll).socle(Socle.T.body).toggleStyle(.switch)
                    }
                    Divider().overlay(Socle.C.border)
                    Group {
                        Text(L("perm.modes")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                        modeRow(L("perm.fileMode"), $model.fileMode, presets: ["644", "600", "664", "666", "755", "u+rw,go-w", "a+x"])
                        modeRow(L("perm.dirMode"), $model.directoryMode, presets: ["755", "700", "750", "775", "777", "u+rwx,go+rx"])
                        HStack(spacing: Socle.M.space2) {
                            Text(L("perm.owner")).socle(Socle.T.body).foregroundStyle(Socle.C.text)
                            Spacer()
                            Picker("", selection: $model.ownerChoice) {
                                Text(L("change.keep")).tag("")
                                Text(L("perm.ownerMe", model.user)).tag("me")
                                Text(L("perm.ownerCustom")).tag("custom")
                            }
                            .labelsHidden().pickerStyle(.menu).fixedSize()
                            if model.ownerChoice == "custom" { TextField(L("perm.ownerHint"), text: $model.ownerCustom).socleField().frame(width: 150) }
                        }
                    }
                    Divider().overlay(Socle.C.border)
                    Group {
                        Text(L("perm.extras")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                        Toggle(L("perm.acl"), isOn: $model.clearACL).socle(Socle.T.body).toggleStyle(.switch)
                        Toggle(L("perm.quarantine"), isOn: $model.clearQuarantine).socle(Socle.T.body).toggleStyle(.switch)
                        Toggle(L("perm.xattrs"), isOn: $model.clearAllExtendedAttributes).socle(Socle.T.body).toggleStyle(.switch)
                    }
                }
                .padding(Socle.M.space3)
            }
        }
    }

    // Bas : consignes, aperçu, journal, boutons

    private var bottom: some View {
        Panel {
            VStack(alignment: .leading, spacing: Socle.M.space2) {
                if !model.log.isEmpty {
                    LogView(text: model.log).frame(height: 72).overlay(RoundedRectangle(cornerRadius: 2).stroke(Socle.C.border))
                }
                HStack(spacing: Socle.M.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(visibleIssues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message).socle(Socle.T.meta).foregroundStyle(issue == .nothingToDo || issue == .noTarget ? Socle.C.textMuted : Socle.C.danger)
                                .lineLimit(2)
                        }
                        if model.previewing {
                            Text(L("perm.previewing", model.previewCount)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                        } else if let p = model.preview {
                            Text(L("perm.previewResult", p.files, p.directories)).socle(Socle.T.meta).foregroundStyle(Socle.C.text)
                        }
                    }
                    Spacer()
                    Toggle(L("perm.useAdmin"), isOn: $model.useAdmin).socle(Socle.T.body).toggleStyle(.switch).fixedSize()
                    if model.previewing {
                        Button(L("scan.cancel")) { model.cancelPreview() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    } else {
                        Button(L("perm.preview")) { model.runPreview() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize().disabled(!issues.isEmpty || model.running)
                    }
                    if model.running {
                        Button(L("scan.cancel")) { model.stop() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    } else {
                        Button(L("perm.apply")) { confirming = true }.buttonStyle(SocleButtonStyle(.action)).fixedSize().disabled(!issues.isEmpty || model.previewing)
                    }
                }
            }
            .padding(Socle.M.space3)
        }
    }

    private var confirm: some View {
        if !model.advanced {
            var lines: [(String, Bool)] = [(L("perm.repairConfirmBody", model.targets.count), false)]
            if let d = model.diagnosis, d.problems > 0 { lines.append((L("perm.problems", d.problems, d.examined), false)) }
            lines.append((L("perm.simpleKeeps"), false))
            return ToolConfirm(title: L("perm.repairConfirmTitle"), lines: lines, button: L("perm.repair"), onCancel: { confirming = false }, onConfirm: { confirming = false; model.repair(admin: false) })
        }
        var lines: [(String, Bool)] = [(L("perm.confirmBody", model.targets.count, L("scope.\(model.scope.rawValue)")), false)]
        if let p = model.preview { lines.append((L("perm.confirmCount", p.total), false)) }
        if model.recursive { lines.append((L("perm.confirmRecursive"), true)) }
        lines.append((L("perm.confirmIrreversible"), true))
        return ToolConfirm(title: L("perm.confirmTitle"), lines: lines, button: L("perm.apply"), onCancel: { confirming = false }, onConfirm: { confirming = false; model.apply() })
    }
}

// MARK: Fichiers invisibles

struct InvisiblesView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: InvisiblesModel
    @State private var confirming = false

    var body: some View {
        ZStack {
            VStack(spacing: Socle.M.space3) {
                header
                HStack(spacing: Socle.M.space3) {
                    VStack(spacing: Socle.M.space3) {
                        kindsPanel
                        watchPanel
                    }
                    .frame(width: 330)
                    itemsPanel
                }
                footer
            }
            if confirming { confirm }
        }
    }

    private var header: some View {
        Panel {
            HStack(spacing: Socle.M.space3) {
                Text(model.root?.path.replacingOccurrences(of: app.home.path, with: "~") ?? L("invisibles.none")).socle(Socle.T.label)
                    .foregroundStyle(model.root == nil ? Socle.C.textMuted : Socle.C.text).lineLimit(1).truncationMode(.middle)
                Spacer()
                Menu(L("invisibles.choose")) {
                    ForEach(app.volumes) { v in Button(v.name) { model.root = URL(fileURLWithPath: v.path == "/" ? app.home.path : v.path) } }
                    Divider()
                    Button(L("invisibles.folder")) { if let url = chooseURLs(files: false, multiple: false, directory: app.home).first { model.root = url } }
                }
                .menuStyle(.borderlessButton).fixedSize()
                if case .scanning(let n) = model.phase {
                    Text(L("invisibles.scanning", n)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                    Button(L("scan.cancel")) { model.cancelWork() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                } else {
                    Button(L("invisibles.scan")) { model.startScan() }.buttonStyle(SocleButtonStyle(.primary)).fixedSize().disabled(model.root == nil || model.busy)
                }
            }
            .padding(Socle.M.space3).frame(minHeight: 52)
        }
    }

    private func state(_ kind: InvisibleKind) -> CheckBox.State {
        let items = model.scan?.items[kind] ?? []
        let chosen = items.filter { model.selection.contains($0.path) }.count
        return chosen == 0 ? .off : chosen == items.count ? .on : .mixed
    }

    private var kindsPanel: some View {
        Panel {
            VStack(spacing: 0) {
                PanelHeader(title: L("invisibles.kinds"), trailing: L("list.size"))
                ForEach(InvisibleKind.allCases) { kind in
                    let items = model.scan?.items[kind] ?? []
                    HStack(spacing: Socle.M.space2) {
                        CheckBox(state: state(kind)) { model.setSelected(state(kind) == .off, kind: kind) }.disabled(items.isEmpty)
                        HStack(spacing: Socle.M.space2) {
                            Text(kind.title).socle(Socle.T.body).foregroundStyle(items.isEmpty ? Socle.C.textMuted : Socle.C.text).lineLimit(1)
                            if kind.needsAdmin { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Socle.C.warning) }
                            Spacer()
                            Text(items.isEmpty ? "–" : "\(items.count) · \(SizeFormat.text(model.scan?.total(kind) ?? 0))").socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.kind = kind }
                    }
                    .padding(.horizontal, Socle.M.space3).frame(height: 30)
                    .background(model.kind == kind ? Socle.C.surfaceSelected : .clear)
                }
                if let kept = model.scan?.keptCustomIcons, kept > 0 {
                    Text(L("invisibles.keptIcons", kept)).socle(Socle.T.meta).foregroundStyle(Socle.C.accentText)
                        .padding(.horizontal, Socle.M.space3).padding(.vertical, Socle.M.space1_5)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var watchPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Socle.M.space2) {
                HStack {
                    Text(L("watch.title")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                    Spacer()
                    if app.watching { Circle().fill(Socle.C.success).frame(width: 8, height: 8) }
                    Menu(L("watch.add")) {
                        ForEach(app.volumes) { v in Button(v.name) { addWatch(v.path == "/" ? app.home.path : v.path) } }
                        Divider()
                        Button(L("invisibles.folder")) { if let url = chooseURLs(files: false, multiple: false, directory: app.home).first { addWatch(url.path) } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Text(L("watch.help")).socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                if app.settings.watchedFolders.isEmpty {
                    Text(L("watch.none")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                }
                ForEach(app.settings.watchedFolders, id: \.self) { path in
                    HStack {
                        Text(path.replacingOccurrences(of: app.home.path, with: "~")).socle(Socle.T.meta).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { app.settings.watchedFolders.removeAll { $0 == path } } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Socle.C.textMuted) }
                            .buttonStyle(.plain).help(L("perm.remove"))
                    }
                }
                if model.watchRemoved > 0 {
                    Text(L("watch.removed", model.watchRemoved)).socle(Socle.T.meta).foregroundStyle(Socle.C.success)
                }
                Spacer(minLength: 0)
            }
            .padding(Socle.M.space3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func addWatch(_ path: String) {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        if !app.settings.watchedFolders.contains(p) { app.settings.watchedFolders.append(p) }
    }

    private var itemsPanel: some View {
        let items = model.scan?.items[model.kind] ?? []
        let base = model.root?.standardizedFileURL.path ?? ""
        return Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(title: model.kind.title, trailing: L(model.kind.needsAdmin ? "list.adminTag" : "list.deleteTag"))
                Text(model.kind.help).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Socle.M.space3).padding(.vertical, Socle.M.space2)
                if model.scan == nil {
                    Text(L("scan.welcomeHelp")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    Text(L("invisibles.empty")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                let chosen = model.selection.contains(item.path)
                                HStack(spacing: Socle.M.space2) {
                                    CheckBox(state: chosen ? .on : .off) { model.setSelected(!chosen, item: item) }
                                    Text(item.path.hasPrefix(base + "/") ? String(item.path.dropFirst(base.count + 1)) : item.path).socle(Socle.T.meta)
                                        .foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle).help(item.path)
                                    Spacer()
                                    Text(SizeFormat.text(item.size)).socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Socle.C.textMuted) }
                                        .buttonStyle(.plain).help(L("list.reveal"))
                                }
                                .padding(.horizontal, Socle.M.space3).frame(height: 28)
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        Panel {
            HStack(spacing: Socle.M.space3) {
                if case .cleaning(let part) = model.phase {
                    ProgressView(value: part).tint(Socle.C.accent)
                    Button(L("scan.cancel")) { model.cancelWork() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                } else {
                    if let r = model.report {
                        let parts = [r.freed > 0 ? L("report.freed", SizeFormat.text(r.freed)) : (r.count > 0 ? L("invisibles.removed", r.count) : nil),
                                     r.adminCancelled ? L("report.adminCancelled") : nil,
                                     r.failures.isEmpty || r.adminCancelled ? nil : L("report.failed", r.failures.count)]
                        Text(parts.compactMap { $0 }.joined(separator: " ")).socle(Socle.T.label).foregroundStyle(r.failures.isEmpty ? Socle.C.success : Socle.C.warning)
                    }
                    Spacer()
                    if model.scan != nil {
                        Text(L("clean.gain", SizeFormat.text(model.selectedItems.reduce(0) { $0 + $1.size }))).socle(Socle.T.label).foregroundStyle(Socle.C.text)
                        Button(L("invisibles.clean")) { confirming = true }.buttonStyle(SocleButtonStyle(.action)).fixedSize().disabled(model.selection.isEmpty || model.busy)
                    }
                }
            }
            .padding(Socle.M.space3).frame(minHeight: 52)
        }
    }

    private var confirm: some View {
        let items = model.selectedItems
        var lines: [(String, Bool)] = [(L("invisibles.confirmBody", SizeFormat.text(items.reduce(0) { $0 + $1.size })), false)]
        if items.contains(where: { $0.kind.needsAdmin }) { lines.append((L("invisibles.confirmAdmin"), true)) }
        return ToolConfirm(title: L("invisibles.confirmTitle", items.count), lines: lines, button: L("invisibles.clean"), onCancel: { confirming = false }, onConfirm: { confirming = false; model.clean() })
    }
}
