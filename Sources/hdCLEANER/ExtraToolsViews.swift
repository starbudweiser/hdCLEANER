import AppKit
import HdCleanerCore
import SwiftUI

/// En-tête commun : dossier ou volume choisi, menu de choix, puis les commandes propres à l'outil.
private struct ToolHeader<Trailing: View>: View {
    @EnvironmentObject private var app: AppModel
    @Binding var root: URL?
    var shortcuts: [(String, URL)] = []
    @ViewBuilder let trailing: Trailing

    var body: some View {
        Panel {
            HStack(spacing: Socle.M.space3) {
                Text(root?.path.replacingOccurrences(of: app.home.path, with: "~") ?? L("invisibles.none")).socle(Socle.T.label)
                    .foregroundStyle(root == nil ? Socle.C.textMuted : Socle.C.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Socle.M.space2)
                Menu(L("invisibles.choose")) {
                    ForEach(shortcuts, id: \.0) { name, url in Button(name) { root = url } }
                    if !shortcuts.isEmpty { Divider() }
                    Button(L("watch.home")) { root = app.home }
                    ForEach(app.volumes.filter { $0.path != "/" }) { v in Button(v.name) { root = URL(fileURLWithPath: v.path) } }
                    Divider()
                    Button(L("invisibles.folder")) { if let url = chooseURLs(files: false, multiple: false, directory: app.home).first { root = url } }
                }
                .menuStyle(.borderlessButton).fixedSize()
                trailing
            }
            .padding(Socle.M.space3).frame(minHeight: 52)
        }
    }
}

private struct ToolFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Panel {
            HStack(spacing: Socle.M.space3) { content }
                .padding(Socle.M.space3).frame(minHeight: 52)
        }
    }
}

private func empty(_ text: String) -> some View {
    Text(text).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).multilineTextAlignment(.center)
        .padding(Socle.M.space5).frame(maxWidth: .infinity, maxHeight: .infinity)
}

private func hint(_ text: String) -> some View {
    Text(text).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Socle.M.space3).padding(.vertical, Socle.M.space2)
}

private func revealButton(_ path: String) -> some View {
    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Socle.C.textMuted) }
        .buttonStyle(.plain).help(L("list.reveal"))
}

// MARK: Doublons

struct DuplicatesView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: DuplicatesModel
    @State private var confirming = false

    var body: some View {
        ZStack {
            VStack(spacing: Socle.M.space3) {
                ToolHeader(root: $model.root) {
                    Menu(L("dup.minSize") + " " + SizeFormat.text(model.minSize)) {
                        ForEach([100_000, 1_000_000, 10_000_000, 100_000_000] as [Int64], id: \.self) { v in Button(SizeFormat.text(v)) { model.minSize = v } }
                    }
                    .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                    if case .scanning(let n) = model.phase {
                        Text(L("dup.scanning", n)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                        Button(L("scan.cancel")) { model.cancelWork() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    } else {
                        Button(L("dup.scan")) { model.startScan(home: app.home) }.buttonStyle(SocleButtonStyle(.primary)).fixedSize().disabled(model.root == nil || model.busy)
                    }
                }
                list
                footer
            }
            .onAppear { if model.root == nil { model.root = app.home } }
            if confirming {
                ToolConfirm(title: L("dup.confirmTitle", model.selection.count), lines: [(L("dup.confirmBody", SizeFormat.text(model.gain)), false)], button: L("dup.trash"),
                            onCancel: { confirming = false }, onConfirm: { confirming = false; model.clean(home: app.home) })
            }
        }
    }

    private var list: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(title: model.scan.map { L("dup.summary", $0.groups.count, SizeFormat.text($0.wasted)) } ?? L("mode.duplicates"), trailing: L("list.size"))
                hint(L("dup.help"))
                if let scan = model.scan {
                    if scan.groups.isEmpty {
                        empty(L("dup.empty"))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(scan.groups) { group in
                                    HStack {
                                        Text(L("dup.group", group.files.count, group.files.first?.name ?? "")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong).lineLimit(1)
                                        Spacer()
                                        Text(SizeFormat.text(group.size)).socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
                                    }
                                    .padding(.horizontal, Socle.M.space3).frame(height: 30).background(Socle.C.surfaceRaised)
                                    ForEach(group.files) { file in row(file, group) }
                                }
                            }
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func row(_ file: DuplicateFile, _ group: DuplicateGroup) -> some View {
        let chosen = model.selection.contains(file.path)
        let locked = !chosen && !model.canSelect(file, in: group)
        return HStack(spacing: Socle.M.space2) {
            CheckBox(state: chosen ? .on : .off) { model.toggle(file, in: group) }.disabled(locked).help(locked ? L("dup.mustKeep") : "")
            Text(file.path.replacingOccurrences(of: app.home.path, with: "~")).socle(Socle.T.meta).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle).help(file.path)
            Spacer()
            if !chosen { Text(L("dup.keep")).socle(Socle.T.meta).foregroundStyle(Socle.C.success) }
            else { Button(L("dup.keepThis")) { model.keepOnly(file, in: group) }.buttonStyle(SocleButtonStyle(.tertiary, height: 22)).fixedSize() }
            Text(file.modified.formatted(date: .abbreviated, time: .omitted)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
            revealButton(file.path)
        }
        .padding(.horizontal, Socle.M.space3).frame(height: 28)
    }

    private var footer: some View {
        ToolFooter {
            if case .cleaning(let part) = model.phase {
                ProgressView(value: part).tint(Socle.C.accent)
            } else {
                if let r = model.report {
                    Text(L("dup.done", r.count, SizeFormat.text(r.trashed)) + (r.failures.isEmpty ? "" : " " + L("report.failed", r.failures.count)))
                        .socle(Socle.T.label).foregroundStyle(r.failures.isEmpty ? Socle.C.success : Socle.C.warning)
                }
                Spacer()
                if model.scan?.groups.isEmpty == false {
                    Text(L("clean.gain", SizeFormat.text(model.gain))).socle(Socle.T.label).foregroundStyle(Socle.C.text)
                    Button(L("dup.trash")) { confirming = true }.buttonStyle(SocleButtonStyle(.action)).fixedSize().disabled(model.selection.isEmpty || model.busy)
                }
            }
        }
    }
}

// MARK: Carte du disque

struct DiskMapView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: DiskMapModel
    @State private var confirming = false

    private static let palette: [Color] = [Socle.C.accent, Socle.C.action, Socle.C.success, Socle.C.bubbleAi, Socle.C.warning, Socle.C.danger]

    private struct Tile: Identifiable {
        let id: String
        let node: MapNode?
        let title: String
        let size: Int64
        let rect: CGRect
        let color: Color
    }

    var body: some View {
        ZStack {
            VStack(spacing: Socle.M.space3) {
                ToolHeader(root: $model.root) {
                    if case .scanning(let n, let bytes) = model.phase {
                        Text(L("map.scanning", n, SizeFormat.text(bytes))).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                        Button(L("scan.cancel")) { model.cancelWork() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    } else {
                        Button(L("map.scan")) { model.startScan() }.buttonStyle(SocleButtonStyle(.primary)).fixedSize().disabled(model.root == nil || model.busy)
                    }
                }
                mapPanel
                footer
            }
            .onAppear { if model.root == nil { model.root = app.home } }
            if confirming, let node = model.selected {
                ToolConfirm(title: L("map.confirmTitle", node.name), lines: [(L("map.confirmBody", SizeFormat.text(node.size)), false)], button: L("map.trash"),
                            onCancel: { confirming = false }, onConfirm: { confirming = false; model.trashSelected(home: app.home) })
            }
        }
    }

    private var mapPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                if let current = model.current {
                    breadcrumb(current)
                    GeometryReader { geo in
                        let tiles = tiles(of: current, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 1, dy: 1))
                        if tiles.isEmpty {
                            empty(L("map.folded"))
                        } else {
                            ZStack(alignment: .topLeading) {
                                ForEach(tiles) { tile in tileView(tile) }
                            }
                        }
                    }
                } else {
                    PanelHeader(title: L("mode.map"), trailing: "")
                    hint(L("map.help"))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func breadcrumb(_ current: MapNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Socle.M.space1) {
                ForEach(Array(current.trail.enumerated()), id: \.offset) { index, node in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Socle.C.textSubtle) }
                    Button(node.name.isEmpty ? "/" : node.name) { model.open(node) }
                        .buttonStyle(.plain).socle(index == current.trail.count - 1 ? Socle.T.labelStrong : Socle.T.label)
                        .foregroundStyle(index == current.trail.count - 1 ? Socle.C.textStrong : Socle.C.accentText)
                }
                Text(SizeFormat.text(current.size)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).padding(.leading, Socle.M.space2)
            }
            .padding(.horizontal, Socle.M.space3)
        }
        .frame(height: 32).background(Socle.C.surfaceRaised)
    }

    private func tiles(of node: MapNode, in rect: CGRect) -> [Tile] {
        var items: [(MapNode?, String, Int64)] = node.children.prefix(60).map { ($0, $0.name, $0.size) }
        let rest = node.children.dropFirst(60).reduce(0) { $0 + $1.size }
        if node.smallFiles > 0 { items.append((nil, L("map.small"), node.smallFiles)) }
        if rest > 0 { items.append((nil, L("map.other"), rest)) }
        items = items.filter { $0.2 > 0 }.sorted { $0.2 > $1.2 }
        let rects = Treemap.layout(items.map { Double($0.2) }, in: rect)
        return zip(items.indices, zip(items, rects)).map { index, pair in
            let (item, r) = pair
            let color = item.0 == nil ? Socle.C.textSubtle : Self.palette[index % Self.palette.count]
            return Tile(id: item.0?.path ?? item.1, node: item.0, title: item.1, size: item.2, rect: r.insetBy(dx: 0.5, dy: 0.5), color: color)
        }
    }

    private func tileView(_ tile: Tile) -> some View {
        let chosen = tile.node != nil && model.selected === tile.node
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(tile.color.opacity(tile.node?.isDirectory == false ? 0.45 : 0.78))
            Rectangle().stroke(chosen ? Socle.C.textStrong : Socle.C.bg, lineWidth: chosen ? 2 : 1)
            if tile.rect.width > 64, tile.rect.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.title).socle(Socle.T.meta).fontWeight(.semibold).lineLimit(1)
                    Text(SizeFormat.text(tile.size)).socle(Socle.T.caption).lineLimit(1)
                }
                .foregroundStyle(Socle.C.bg).padding(Socle.M.space1_5)
            }
        }
        .frame(width: max(tile.rect.width, 0), height: max(tile.rect.height, 0))
        .offset(x: tile.rect.minX, y: tile.rect.minY)
        .contentShape(Rectangle())
        .help("\(tile.title) · \(SizeFormat.text(tile.size))")
        .onTapGesture(count: 2) { if let node = tile.node { model.open(node) } }
        .onTapGesture { if let node = tile.node { model.selected = node } }
    }

    private var footer: some View {
        ToolFooter {
            if let node = model.selected {
                Text(node.path.replacingOccurrences(of: app.home.path, with: "~")).socle(Socle.T.meta).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle)
                Text(SizeFormat.text(node.size)).socle(Socle.T.label).foregroundStyle(Socle.C.text)
                Spacer()
                if node.isDirectory { Button(L("map.open")) { model.open(node) }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize() }
                Button(L("list.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)]) }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                let allowed = PathGuard.isSafeUserFile(node.path, home: app.home)
                Button(L("map.trash")) { confirming = true }.buttonStyle(SocleButtonStyle(.action)).fixedSize().disabled(!allowed || model.busy).help(allowed ? "" : L("map.protected"))
            } else {
                Text(model.report ?? (model.tree == nil ? "" : L("map.help"))).socle(Socle.T.meta).foregroundStyle(model.report == nil ? Socle.C.textMuted : Socle.C.success)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }
}

// MARK: Rangement

struct OrganizerView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: OrganizerModel
    @State private var confirming = false

    var body: some View {
        ZStack {
            VStack(spacing: Socle.M.space3) {
                ToolHeader(root: $model.root, shortcuts: [(L("org.downloads"), app.home.appendingPathComponent("Downloads")), (L("org.desktop"), app.home.appendingPathComponent("Desktop")),
                                                          (L("org.documents"), app.home.appendingPathComponent("Documents"))]) {
                    if model.phase == .planning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L("org.scan")) { model.startPlan() }.buttonStyle(SocleButtonStyle(.primary)).fixedSize().disabled(model.root == nil || model.busy)
                    }
                }
                HStack(spacing: Socle.M.space3) {
                    kindsPanel.frame(width: 330)
                    movesPanel
                }
                footer
            }
            .onAppear { if model.root == nil { model.root = app.home.appendingPathComponent("Downloads") } }
            if confirming {
                ToolConfirm(title: L("org.confirmTitle", model.selectedMoves.count), lines: [(L("org.confirmBody"), false)], button: L("org.apply", model.selectedMoves.count),
                            onCancel: { confirming = false }, onConfirm: { confirming = false; model.apply() })
            }
        }
    }

    private func state(_ kind: OrganizerKind) -> CheckBox.State {
        let moves = model.plan?.moves(kind) ?? []
        let chosen = moves.filter { model.selection.contains($0.source) }.count
        return chosen == 0 ? .off : chosen == moves.count ? .on : .mixed
    }

    private var kindsPanel: some View {
        Panel {
            VStack(spacing: 0) {
                PanelHeader(title: L("org.kinds"), trailing: L("list.size"))
                ForEach(OrganizerKind.allCases.filter { $0 != .other }) { kind in
                    let moves = model.plan?.moves(kind) ?? []
                    HStack(spacing: Socle.M.space2) {
                        CheckBox(state: state(kind)) { model.setSelected(state(kind) == .off, kind: kind) }.disabled(moves.isEmpty)
                        HStack {
                            Text(kind.title).socle(Socle.T.body).foregroundStyle(moves.isEmpty ? Socle.C.textMuted : Socle.C.text).lineLimit(1)
                            Spacer()
                            Text(moves.isEmpty ? "–" : "\(moves.count) · \(SizeFormat.text(moves.reduce(0) { $0 + $1.size }))").socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.kind = kind }
                    }
                    .padding(.horizontal, Socle.M.space3).frame(height: 30)
                    .background(model.kind == kind ? Socle.C.surfaceSelected : .clear)
                }
                if let left = model.plan?.left, left > 0 {
                    Text(L("org.left", left)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).padding(.horizontal, Socle.M.space3).padding(.vertical, Socle.M.space1_5)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var movesPanel: some View {
        let moves = model.plan?.moves(model.kind) ?? []
        return Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(title: model.kind.title, trailing: L("list.size"))
                hint(L("org.help"))
                if model.plan == nil {
                    Spacer(minLength: 0)
                } else if moves.isEmpty {
                    empty(L("org.empty"))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(moves) { move in
                                let chosen = model.selection.contains(move.source)
                                HStack(spacing: Socle.M.space2) {
                                    CheckBox(state: chosen ? .on : .off) { model.setSelected(!chosen, move: move) }
                                    Text(move.name).socle(Socle.T.meta).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle).help(move.source)
                                    Spacer()
                                    Text(L("org.into", (move.destination as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? "")).socle(Socle.T.meta).foregroundStyle(Socle.C.accentText).lineLimit(1)
                                    Text(SizeFormat.text(move.size)).socle(Socle.T.meta).monospacedDigit().foregroundStyle(Socle.C.textMuted)
                                    revealButton(move.source)
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
        ToolFooter {
            if case .working(let part) = model.phase {
                ProgressView(value: part).tint(Socle.C.accent)
            } else {
                if let r = model.report { Text(r).socle(Socle.T.label).foregroundStyle(Socle.C.success).lineLimit(2) }
                Spacer()
                if !model.last.isEmpty { Button(L("org.undo")) { model.undo() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize().disabled(model.busy) }
                if model.plan?.moves.isEmpty == false {
                    Button(L("org.apply", model.selectedMoves.count)) { confirming = true }.buttonStyle(SocleButtonStyle(.action)).fixedSize().disabled(model.selection.isEmpty || model.busy)
                }
            }
        }
    }
}
