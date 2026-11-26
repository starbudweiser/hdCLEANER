import AppKit
import HdCleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct SystemFixesView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: SystemFixesModel

    var body: some View {
        VStack(spacing: Socle.M.space3) {
            tabs
            ScrollView {
                VStack(spacing: Socle.M.space3) {
                    switch model.tab {
                    case .openWith: OpenWithHost(model: model)
                    case .extensions: ExtensionsPane(model: model)
                    case .services: ServicesPane(model: model)
                    case .caches: CachesPane(model: model)
                    case .disk: DiskPane(model: model)
                    case .quarantine: QuarantinePane(model: model)
                    }
                    if !model.message.isEmpty {
                        Text(model.message).socle(Socle.T.meta).foregroundStyle(Socle.C.success).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Panel {
                        HStack {
                            Text(L("fix.leftovers")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                            Spacer()
                            Button(L("fix.leftoversOpen")) { app.mode = .clean }.buttonStyle(.plain).socle(Socle.T.meta).foregroundStyle(Socle.C.accentText)
                        }
                        .padding(.horizontal, Socle.M.space3).frame(height: 36)
                    }
                }
                .padding(.bottom, Socle.M.space2)
            }
        }
        .onAppear { model.refresh() }
        .onChange(of: model.tab) { _, _ in model.message = ""; model.refresh() }
        .toggleStyle(.switch)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(FixTab.allCases) { t in
                Button { model.tab = t } label: {
                    Text(t.title).socle(Socle.T.label)
                        .foregroundStyle(model.tab == t ? Socle.C.textStrong : Socle.C.textMuted)
                        .padding(.horizontal, Socle.M.space3).frame(height: 30)
                        .overlay(alignment: .bottom) { Rectangle().fill(model.tab == t ? Socle.C.accent : Color.clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Socle.C.border).frame(height: 1) }
    }
}

// MARK: Éléments communs

private struct StatCard: View {
    let value: Int, label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").socle(Socle.T.display).monospacedDigit().foregroundStyle(Socle.C.textStrong)
            Text(label).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Socle.M.space3).frame(maxWidth: .infinity, alignment: .leading)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border))
    }
}

private struct Tag: View {
    let text: String
    var color: Color = Socle.C.textMuted
    var body: some View {
        Text(text).socle(Socle.T.caption).foregroundStyle(color)
            .padding(.horizontal, Socle.M.space2).padding(.vertical, 1)
            .background(Socle.C.bgSunken, in: Capsule())
    }
}

private struct Note: View {
    let text: String
    var body: some View { Text(text).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
}

/// Ligne : cases / interrupteur à gauche, titre + sous-titre, puis infos à droite.
private struct FixRow<Lead: View, Trail: View>: View {
    let title: String
    var detail: String?
    let lead: Lead
    let trail: Trail
    init(title: String, detail: String? = nil, lead: Lead, trail: Trail) { self.title = title; self.detail = detail; self.lead = lead; self.trail = trail }
    var body: some View {
        HStack(spacing: Socle.M.space3) {
            lead
            VStack(alignment: .leading, spacing: 1) {
                Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: Socle.M.space2)
            trail
        }
        .padding(.horizontal, Socle.M.space3).frame(minHeight: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Socle.C.borderSubtle).frame(height: 1) }
    }
}

private struct SummaryBar<Actions: View>: View {
    let text: String
    @ViewBuilder let actions: Actions
    var body: some View {
        Panel {
            HStack(spacing: Socle.M.space3) {
                Text(text).socle(Socle.T.body).foregroundStyle(Socle.C.text).frame(maxWidth: .infinity, alignment: .leading)
                actions.fixedSize()
            }
            .padding(.horizontal, Socle.M.space3).frame(minHeight: 44)
        }
    }
}

private func shortPath(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

// MARK: 1 · Ouvrir avec (deux vues : déchets de la base, par type de fichier)

private struct OpenWithHost: View {
    @ObservedObject var model: SystemFixesModel
    var body: some View {
        VStack(spacing: Socle.M.space3) {
            HStack {
                SocleSegmented(options: SystemFixesModel.OpenView.allCases, selection: model.openView, label: { $0.title }, onSelect: { model.openView = $0 })
                Spacer()
            }
            switch model.openView {
            case .junk: OpenWithPane(model: model)
            case .byType: ByTypePane(model: model)
            }
        }
    }
}

private struct ByTypePane: View {
    @ObservedObject var model: SystemFixesModel
    private let common = ["pdf", "mp4", "png", "txt", "zip"]

    private func state(_ paths: [String]) -> CheckBox.State {
        let n = paths.filter { model.typeSelection.contains($0) }.count
        return n == 0 ? .off : (n == paths.count ? .on : .mixed)
    }
    private func toggle(_ path: String) { if model.typeSelection.contains(path) { model.typeSelection.remove(path) } else { model.typeSelection.insert(path) } }
    private func tag(_ a: FileAssociations.AppEntry) -> (String, Color) {
        if a.isSystem { return (L("fix.type.system"), Socle.C.success) }
        switch a.strength {
        case .legit: return (L("fix.type.legit"), Socle.C.success)
        case .secondary: return (a.isDevBuild ? L("fix.reason.devBuild") : L("fix.type.secondary"), Socle.C.warning)
        case .generic: return (L("fix.type.generic"), Socle.C.warning)
        }
    }
    private func why(_ a: FileAssociations.AppEntry) -> String {
        var parts: [String] = []
        switch a.strength {
        case .legit: parts.append(L("fix.type.whyLegit", a.role.isEmpty ? "—" : a.role))
        case .secondary: parts.append(L("fix.type.whySecondary"))
        case .generic: parts.append(L("fix.type.whyGeneric"))
        }
        if a.isDefault { parts.append(L("fix.type.isDefault")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: Socle.M.space3) {
            Note(text: L("fix.type.help"))
            Panel {
                VStack(spacing: 0) {
                    HStack(spacing: Socle.M.space2) {
                        Text(L("fix.type.field")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                        TextField("pdf", text: $model.typeInput).textFieldStyle(.roundedBorder).frame(width: 110).onSubmit { model.analyzeType() }
                        Button(L("fix.analyze")) { model.analyzeType() }.buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize().disabled(model.busy)
                        if let a = model.typeAnalysis { Tag(text: "\(a.typeName) · \(a.typeID)") }
                        Spacer()
                        ForEach(common, id: \.self) { e in Button(".\(e)") { model.analyzeType(e) }.buttonStyle(SocleButtonStyle(.tertiary, height: 24)).fixedSize() }
                        Button(L("fix.type.chooseFile")) { model.chooseFileForType() }.buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize()
                    }
                    .padding(.horizontal, Socle.M.space3).frame(height: 40).background(Socle.C.surfaceRaised)
                    if let a = model.typeAnalysis {
                        FixRow(title: L("fix.type.defaultApp"), detail: L("fix.type.defaultHelp", a.ext), lead: Color.clear.frame(width: 0, height: 0),
                               trail: HStack(spacing: Socle.M.space3) {
                                   Text(model.typeDefault.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "—").socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                                   Button(L("fix.type.change")) { model.chooseDefault() }.buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize()
                               })
                    }
                }
            }
            if let a = model.typeAnalysis {
                HStack(spacing: Socle.M.space2) {
                    StatCard(value: a.apps.count, label: L("fix.type.stat.total", a.ext))
                    StatCard(value: a.legitCount, label: L("fix.type.stat.legit"))
                    StatCard(value: a.secondaryCount, label: L("fix.type.stat.secondary"))
                    StatCard(value: a.genericCount, label: L("fix.type.stat.generic"))
                }
                Panel {
                    VStack(spacing: 0) {
                        HStack(spacing: Socle.M.space2) {
                            Text(L("fix.type.listTitle", a.ext)).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                            Spacer()
                            Text(L("fix.type.listHint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                            Button(L("fix.type.uncheckAll")) { model.typeSelection = [] }.buttonStyle(SocleButtonStyle(.tertiary, height: 24)).fixedSize()
                        }
                        .padding(.horizontal, Socle.M.space3).frame(height: 32).background(Socle.C.surfaceRaised)
                        ForEach(a.apps) { app in
                            let t = tag(app)
                            FixRow(title: app.name, detail: why(app),
                                   lead: app.removable ? AnyView(CheckBox(state: state([app.path])) { toggle(app.path) }) : AnyView(Color.clear.frame(width: 28, height: 28)),
                                   trail: HStack(spacing: Socle.M.space3) {
                                       Tag(text: t.0, color: t.1)
                                       Text(app.removable && app.typeCount > 1 ? L("fix.type.loses", app.typeCount) : "").socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).frame(minWidth: 90, alignment: .trailing)
                                   })
                        }
                    }
                }
                Panel { Note(text: L("fix.type.how")).padding(Socle.M.space3) }
                let n = a.apps.filter { $0.removable && model.typeSelection.contains($0.path) }.count
                SummaryBar(text: n == 0 ? L("fix.openWith.none") : L("fix.type.summary", n)) {
                    if !model.undoPaths.isEmpty { Button(L("fix.openWith.undo")) { model.undoOpenWith() }.buttonStyle(SocleButtonStyle(.secondary)).disabled(model.busy) }
                    Button(L("fix.type.remove")) { model.removeTypeSelection() }.buttonStyle(SocleButtonStyle(.action)).disabled(model.busy || n == 0)
                }
            } else {
                Panel { Text(model.busy ? L("fix.analyzing") : L("fix.type.empty")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, minHeight: 120) }
            }
        }
        .onAppear { if model.typeAnalysis == nil { model.analyzeType() } }
    }
}

// MARK: Déchets de la base Launch Services

private struct StaleGroup: Identifiable {
    let id: String, title: String, sample: String, reason: LSRegistry.Reason, paths: [String]
}

private struct OpenWithPane: View {
    @ObservedObject var model: SystemFixesModel

    private func groups(_ items: [LSRegistry.Finding]) -> [StaleGroup] {
        var order: [String] = [], map: [String: [LSRegistry.Finding]] = [:]
        for f in items {
            let key: String
            switch f.reason {
            case .missing: key = "missing"
            case .trash: key = "trash"
            case .cache: key = "cache:" + (f.path.components(separatedBy: "/Library/Caches/").last?.split(separator: "/").first.map(String.init) ?? "")
            case .build: key = "build:" + (f.path.components(separatedBy: "/DerivedData/").last?.split(separator: "/").first.map(String.init) ?? "")
            default: key = "temp:" + f.path.split(separator: "/").prefix(2).joined(separator: "/")
            }
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(f)
        }
        return order.map { key in
            let list = map[key]!
            let reason = list[0].reason
            let name = key.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let title: String
            switch reason {
            case .missing: title = L("fix.group.missing", list.count)
            case .trash: title = L("fix.group.trash", list.count)
            case .cache: title = L("fix.group.cache", name, list.count)
            case .build: title = L("fix.group.build", name, list.count)
            default: title = L("fix.group.temp", list.count)
            }
            return StaleGroup(id: key, title: title, sample: shortPath(list[0].path), reason: reason, paths: list.map(\.path))
        }
    }

    private func state(_ paths: [String]) -> CheckBox.State {
        let n = paths.filter { model.selection.contains($0) }.count
        return n == 0 ? .off : (n == paths.count ? .on : .mixed)
    }

    private func toggle(_ paths: [String]) {
        if state(paths) == .on { model.selection.subtract(paths) } else { model.selection.formUnion(paths) }
    }

    private func reasonLabel(_ r: LSRegistry.Reason) -> String { L("fix.reason.\(r.rawValue)") }

    var body: some View {
        VStack(spacing: Socle.M.space3) {
            Note(text: L("fix.openWith.help"))
            if let d = model.diagnosis {
                HStack(spacing: Socle.M.space2) {
                    StatCard(value: d.missingCount, label: L("fix.stat.missing"))
                    StatCard(value: d.cacheCount, label: L("fix.stat.cache"))
                    StatCard(value: d.duplicates.count + d.devBuilds.count, label: L("fix.stat.duplicates"))
                    StatCard(value: d.droplets.count, label: L("fix.stat.droplets"))
                }
                if !d.stale.isEmpty {
                    let all = d.stale.map(\.path)
                    Panel {
                        VStack(spacing: 0) {
                            HStack(spacing: Socle.M.space2) {
                                CheckBox(state: state(all)) { toggle(all) }
                                Text(L("fix.stale.title")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                                Spacer()
                                Text(L("fix.stale.hint", d.stale.count)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                            }
                            .padding(.horizontal, Socle.M.space3 - 6).frame(height: 32).background(Socle.C.surfaceRaised)
                            ForEach(groups(d.stale)) { g in
                                FixRow(title: g.title, detail: g.sample, lead: CheckBox(state: state(g.paths)) { toggle(g.paths) }, trail: Tag(text: reasonLabel(g.reason), color: g.reason == .missing ? Socle.C.textMuted : Socle.C.warning))
                            }
                        }
                    }
                }
                if !d.duplicates.isEmpty || !d.keptGroups.isEmpty {
                    let dups = d.duplicates.map(\.path)
                    Panel {
                        VStack(spacing: 0) {
                            HStack(spacing: Socle.M.space2) {
                                CheckBox(state: state(dups)) { toggle(dups) }
                                Text(L("fix.dup.title")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                                Spacer()
                                Text(L("fix.dup.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                            }
                            .padding(.horizontal, Socle.M.space3 - 6).frame(height: 32).background(Socle.C.surfaceRaised)
                            ForEach(Dictionary(grouping: d.duplicates, by: { $0.bundleID ?? "" }).sorted { $0.key < $1.key }, id: \.key) { id, list in
                                let paths = list.map(\.path)
                                let keep = list[0].keeping ?? ""
                                FixRow(title: L("fix.dup.row", ((keep as NSString).lastPathComponent as NSString).deletingPathExtension, list.count + 1),
                                       detail: L("fix.dup.keep", shortPath(keep)) + " · " + L("fix.dup.remove", list.map { shortPath($0.path) }.joined(separator: ", ")),
                                       lead: CheckBox(state: state(paths)) { toggle(paths) },
                                       trail: Tag(text: L("fix.dup.kept", (try? readVersion(keep)) ?? ""), color: Socle.C.success))
                            }
                            ForEach(d.keptGroups, id: \.bundleID) { g in
                                FixRow(title: L("fix.coexist.row", ((g.paths[0] as NSString).lastPathComponent as NSString).deletingPathExtension, g.paths.count), detail: L("fix.coexist.help"),
                                       lead: Color.clear.frame(width: 28, height: 28), trail: Tag(text: L("fix.coexist.tag")))
                            }
                        }
                    }
                }
                if !d.devBuilds.isEmpty {
                    let devs = d.devBuilds.map(\.path)
                    Panel {
                        VStack(spacing: 0) {
                            HStack(spacing: Socle.M.space2) {
                                CheckBox(state: state(devs)) { toggle(devs) }
                                Text(L("fix.dev.title")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                                Spacer()
                                Text(L("fix.dev.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                            }
                            .padding(.horizontal, Socle.M.space3 - 6).frame(height: 32).background(Socle.C.surfaceRaised)
                            ForEach(d.devBuilds) { f in
                                FixRow(title: ((f.path as NSString).lastPathComponent as NSString).deletingPathExtension, detail: shortPath(f.path),
                                       lead: CheckBox(state: state([f.path])) { toggle([f.path]) }, trail: Tag(text: L("fix.reason.devBuild"), color: Socle.C.warning))
                            }
                        }
                    }
                }
                if !d.droplets.isEmpty {
                    Panel {
                        VStack(spacing: 0) {
                            PanelHeader(title: L("fix.droplets.title"), trailing: L("fix.droplets.hint"))
                            ForEach(d.droplets) { f in
                                FixRow(title: (f.path as NSString).lastPathComponent, detail: L("fix.droplets.detail"),
                                       lead: CheckBox(state: state([f.path])) { toggle([f.path]) }, trail: Tag(text: L("fix.reason.droplet"), color: Socle.C.warning))
                            }
                            HStack(spacing: Socle.M.space3) {
                                Note(text: L("fix.droplets.note"))
                                Button(L("fix.droplets.archive")) {
                                    if let folder = chooseURLs(files: false, multiple: false, directory: nil).first { model.archiveDroplets(to: folder) }
                                }
                                .buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize()
                                .disabled(!d.droplets.contains { model.selection.contains($0.path) } || model.busy)
                            }
                            .padding(Socle.M.space3)
                        }
                    }
                }
                SummaryBar(text: model.selectedCount == 0 ? L("fix.openWith.none") : L("fix.openWith.summary", model.selectedCount)) {
                    Button(L("fix.openWith.rebuild")) { app.mode = .maintenance }.buttonStyle(.plain).socle(Socle.T.meta).foregroundStyle(Socle.C.accentText)
                    if !model.undoPaths.isEmpty { Button(L("fix.openWith.undo")) { model.undoOpenWith() }.buttonStyle(SocleButtonStyle(.secondary)).disabled(model.busy) }
                    Button(L("fix.analyze")) { model.analyze() }.buttonStyle(SocleButtonStyle(.secondary)).disabled(model.busy)
                    Button(L("fix.clean")) { model.cleanOpenWith() }.buttonStyle(SocleButtonStyle(.action)).disabled(model.busy || model.selectedCount == 0)
                }
            } else {
                Panel {
                    Text(model.busy ? L("fix.analyzing") : L("fix.openWith.empty")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
    }

    @EnvironmentObject private var app: AppModel
    private func readVersion(_ path: String) throws -> String { LSRegistry.readInfo(path)?.version ?? "" }
}

// MARK: 2 · Extensions

private struct ExtensionsPane: View {
    @ObservedObject var model: SystemFixesModel
    private func title(_ k: ExtensionKind) -> String { L("fix.ext.kind.\(k.rawValue)") }

    var body: some View {
        VStack(spacing: Socle.M.space3) {
            Note(text: L("fix.ext.help"))
            HStack(spacing: Socle.M.space2) {
                StatCard(value: model.extensions.count, label: L("fix.ext.stat.total"))
                StatCard(value: model.extensions.filter(\.enabled).count, label: L("fix.ext.stat.active"))
                StatCard(value: model.extensions.filter(\.fileMissing).count, label: L("fix.ext.stat.missing"))
                StatCard(value: model.extensions.filter { $0.isDevelopmentCopy && !$0.fileMissing }.count, label: L("fix.ext.stat.dev"))
            }
            ForEach(ExtensionKind.allCases, id: \.self) { kind in
                let list = model.extensions.filter { $0.kind == kind }
                if !list.isEmpty {
                    Panel {
                        VStack(spacing: 0) {
                            PanelHeader(title: title(kind), trailing: "\(list.count)")
                            ForEach(list) { ext in row(ext) }
                        }
                    }
                }
            }
            SummaryBar(text: L("fix.ext.summary")) {
                Button(L("fix.ext.enableAll")) { model.enableAllExtensions() }.buttonStyle(SocleButtonStyle(.secondary))
            }
        }
    }

    private func row(_ ext: SystemExtension) -> some View {
        FixRow(title: ext.name, detail: ext.fileMissing ? shortPath(ext.path) + " — " + L("fix.ext.fileMissing") : ext.identifier,
               lead: Color.clear.frame(width: 0, height: 0),
               trail: HStack(spacing: Socle.M.space2) {
                   if ext.fileMissing { Tag(text: L("fix.reason.missing"), color: Socle.C.warning) }
                   else if ext.isDevelopmentCopy { Tag(text: L("fix.ext.dev"), color: Socle.C.warning) }
                   if (ext.fileMissing || ext.isDevelopmentCopy) && !ext.isApple && PluginKit.removeScript(path: ext.path) != nil {
                       Button(L("fix.ext.remove")) { model.removeExtension(ext) }.buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize()
                   } else {
                       Toggle("", isOn: Binding(get: { ext.enabled }, set: { model.setExtension(ext, enabled: $0) })).labelsHidden()
                   }
               })
    }
}

// MARK: 3 · Services

private struct ServicesPane: View {
    @ObservedObject var model: SystemFixesModel
    var body: some View {
        VStack(spacing: Socle.M.space3) {
            Note(text: L("fix.services.help"))
            Panel {
                VStack(spacing: 0) {
                    PanelHeader(title: L("fix.services.title"), trailing: L("fix.services.count", model.services.count, model.services.filter { !$0.contextMenu }.count))
                    ForEach(model.services) { s in
                        FixRow(title: s.title, detail: s.owner.isEmpty ? nil : s.owner, lead: Color.clear.frame(width: 0, height: 0),
                               trail: Toggle("", isOn: Binding(get: { s.contextMenu }, set: { model.setService(s, contextMenu: $0) })).labelsHidden())
                    }
                }
            }
            SummaryBar(text: L("fix.services.summary")) {
                Button(L("fix.services.restore")) { model.restoreServices() }.buttonStyle(SocleButtonStyle(.secondary))
            }
        }
    }
}

// MARK: 4 · Vignettes et icônes

private struct CachesPane: View {
    @ObservedObject var model: SystemFixesModel
    var body: some View {
        VStack(spacing: Socle.M.space3) {
            Note(text: L("fix.caches.help"))
            Panel {
                VStack(spacing: 0) {
                    FixRow(title: L("fix.caches.quicklook"), detail: L("fix.caches.quicklookHelp"), lead: Color.clear.frame(width: 0, height: 0),
                           trail: HStack(spacing: Socle.M.space3) {
                               Text(SizeFormat.text(model.quickLookSize)).socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
                               Button(L("fix.caches.empty")) { model.clearQuickLook() }.buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize().disabled(model.busy)
                           })
                    FixRow(title: L("fix.caches.icons"), detail: L("fix.caches.iconsHelp"), lead: Color.clear.frame(width: 0, height: 0),
                           trail: HStack(spacing: Socle.M.space3) {
                               Text(SizeFormat.text(model.iconSize)).socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
                               Button(L("fix.caches.empty")) { model.clearIcons() }.buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize().disabled(model.busy)
                           })
                    FixRow(title: L("fix.caches.relaunch"), detail: L("fix.caches.relaunchHelp"), lead: Color.clear.frame(width: 0, height: 0),
                           trail: Button(L("fix.caches.relaunchButton")) { model.relaunchFinderAndDock() }.buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize().disabled(model.busy))
                }
            }
        }
    }
}

// MARK: 5 · Disque occupé

private struct DiskPane: View {
    @ObservedObject var model: SystemFixesModel
    var body: some View {
        VStack(spacing: Socle.M.space3) {
            Note(text: L("fix.disk.help"))
            Panel {
                VStack(spacing: 0) {
                    HStack(spacing: Socle.M.space3) {
                        Text(L("fix.disk.volume")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                        Picker("", selection: $model.volume) {
                            ForEach(model.volumes, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: 240)
                        Spacer()
                        Button(L("fix.disk.search")) { model.searchHolders() }.buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize().disabled(model.busy || model.volume.isEmpty)
                    }
                    .padding(.horizontal, Socle.M.space3).frame(height: 40).background(Socle.C.surfaceRaised)
                    if let list = model.holders {
                        if list.isEmpty {
                            Text(L("fix.disk.none")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity, minHeight: 60)
                        }
                        ForEach(list) { p in
                            let canQuit = p.canQuit(me: getuid())
                            FixRow(title: p.command, detail: L("fix.disk.detail", Int(p.pid), p.fileCount),
                                   lead: canQuit ? AnyView(CheckBox(state: model.holderSelection.contains(p.pid) ? .on : .off) {
                                       if model.holderSelection.contains(p.pid) { model.holderSelection.remove(p.pid) } else { model.holderSelection.insert(p.pid) }
                                   }) : AnyView(Color.clear.frame(width: 28, height: 28)),
                                   trail: canQuit ? AnyView(EmptyView()) : AnyView(Tag(text: L("fix.disk.system"))))
                        }
                    }
                }
            }
            SummaryBar(text: L("fix.disk.summary")) {
                Button(L("fix.disk.quitSelected")) { model.quitSelectedHolders() }.buttonStyle(SocleButtonStyle(.action)).disabled(model.holderSelection.isEmpty)
            }
        }
    }
}

// MARK: 6 · Quarantaine

private struct QuarantinePane: View {
    @ObservedObject var model: SystemFixesModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: Socle.M.space3) {
            Note(text: L("fix.quarantine.help"))
            Button {
                model.addApps(chooseURLs(files: true, multiple: true, directory: URL(fileURLWithPath: "/Applications")))
            } label: {
                Text(L("fix.quarantine.drop")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .background(Socle.C.bgInset, in: RoundedRectangle(cornerRadius: Socle.M.radius))
                    .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).strokeBorder(hovering ? Socle.C.accent : Socle.C.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
                for p in providers {
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        Task { @MainActor in model.addApps([url]) }
                    }
                }
                return true
            }
            if !model.apps.isEmpty {
                Panel {
                    VStack(spacing: 0) {
                        ForEach(model.apps, id: \.self) { path in
                            let has = QuarantineFix.hasQuarantine(path)
                            FixRow(title: (path as NSString).lastPathComponent,
                                   detail: shortPath(path) + (has ? " — " + L("fix.quarantine.from", QuarantineFix.origin(path) ?? "?") : " — " + L("fix.quarantine.clear")),
                                   lead: Color.clear.frame(width: 0, height: 0),
                                   trail: Button(L("fix.quarantine.lift")) { model.liftQuarantine(path) }.buttonStyle(SocleButtonStyle(.action, height: 24)).fixedSize().disabled(!has))
                        }
                    }
                }
            }
        }
    }
}
