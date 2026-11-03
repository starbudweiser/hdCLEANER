import AppKit
import HdCleanerCore
import SwiftUI

// MARK: Doublons

@MainActor
final class DuplicatesModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning(Int), cleaning(Double) }

    @Published var root: URL?
    @Published var minSize: Int64 = 1_000_000
    @Published private(set) var scan: DuplicateScan?
    /// Exemplaires à mettre à la Corbeille.
    @Published var selection = Set<String>()
    @Published private(set) var phase = Phase.idle
    @Published private(set) var report: CleanReport?
    private var cancel = CancelFlag()

    var busy: Bool { phase != .idle }
    var gain: Int64 { (scan?.groups ?? []).reduce(0) { $0 + $1.size * Int64($1.files.filter { selection.contains($0.path) }.count) } }

    func startScan(home: URL) {
        guard let root, !busy else { return }
        report = nil
        let flag = CancelFlag()
        cancel = flag
        phase = .scanning(0)
        let minSize = minSize
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.scan(roots: [root.path], home: home, minSize: minSize, cancel: flag) { n in Task { @MainActor in if case .scanning = self.phase { self.phase = .scanning(n) } } }
            }.value
            phase = .idle
            guard !flag.isCancelled else { return }
            scan = found
            selection = found.preselected
        }
    }

    func cancelWork() { cancel.cancel() }

    /// Cocher tout un groupe est refusé : un exemplaire reste toujours.
    func canSelect(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        group.files.contains { $0.path != file.path && !selection.contains($0.path) }
    }

    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        if selection.contains(file.path) { selection.remove(file.path) } else if canSelect(file, in: group) { selection.insert(file.path) }
    }

    /// Garde cet exemplaire et coche tous les autres du groupe.
    func keepOnly(_ file: DuplicateFile, in group: DuplicateGroup) {
        for other in group.files { if other.path == file.path { selection.remove(other.path) } else { selection.insert(other.path) } }
    }

    func clean(home: URL) {
        guard !busy, let groups = scan?.groups, !selection.isEmpty else { return }
        let flag = CancelFlag()
        cancel = flag
        phase = .cleaning(0)
        let chosen = selection
        Task {
            let done = await Task.detached(priority: .userInitiated) {
                DuplicateCleaner.clean(chosen, groups: groups, home: home, cancel: flag) { part in Task { @MainActor in if case .cleaning = self.phase { self.phase = .cleaning(part) } } }
            }.value
            phase = .idle
            report = done
            let failed = Set(done.failures)
            let gone = chosen.subtracting(failed)
            if var s = scan {
                s.groups = s.groups.compactMap { g in
                    var g = g
                    g.files.removeAll { gone.contains($0.path) }
                    return g.files.count > 1 ? g : nil
                }
                scan = s
            }
            selection.subtract(gone)
        }
    }
}

// MARK: Carte du disque

@MainActor
final class DiskMapModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning(Int, Int64), trashing }

    @Published var root: URL?
    @Published private(set) var tree: MapNode?
    /// Dossier affiché.
    @Published private(set) var current: MapNode?
    @Published var selected: MapNode?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var report: String?
    private var cancel = CancelFlag()

    var busy: Bool { phase != .idle }

    func startScan() {
        guard let root, !busy else { return }
        report = nil
        selected = nil
        let flag = CancelFlag()
        cancel = flag
        phase = .scanning(0, 0)
        Task {
            let built = await Task.detached(priority: .userInitiated) {
                DiskMapper.scan(root: root.path, cancel: flag) { n, bytes in Task { @MainActor in if case .scanning = self.phase { self.phase = .scanning(n, bytes) } } }
            }.value
            phase = .idle
            guard !flag.isCancelled else { return }
            tree = built
            current = built
        }
    }

    func cancelWork() { cancel.cancel() }

    func open(_ node: MapNode) {
        guard node.isDirectory else { return }
        current = node
        selected = nil
    }

    func trashSelected(home: URL) {
        guard let node = selected, !busy else { return }
        phase = .trashing
        let path = node.path, size = node.size, name = node.name
        Task {
            let done = await Task.detached(priority: .userInitiated) { FileTrasher.trash([(path, size)], home: home) }.value
            phase = .idle
            guard done.count == 1 else { report = L("map.protected"); return }
            report = L("map.done", name, SizeFormat.text(size))
            // L'arbre se met à jour sans relire le disque : la taille remonte chez tous les parents.
            node.detach()
            selected = nil
            objectWillChange.send()
        }
    }
}

// MARK: Rangement

@MainActor
final class OrganizerModel: ObservableObject {
    enum Phase: Equatable { case idle, planning, working(Double) }

    @Published var root: URL?
    @Published private(set) var plan: OrganizerPlan?
    @Published var selection = Set<String>()
    @Published var kind = OrganizerKind.images
    @Published private(set) var phase = Phase.idle
    @Published private(set) var report: String?
    /// Dernier rangement fait, pour l'annuler.
    @Published private(set) var last: [OrganizerMove] = []
    private var cancel = CancelFlag()

    var busy: Bool { phase != .idle }
    var selectedMoves: [OrganizerMove] { (plan?.moves ?? []).filter { selection.contains($0.source) } }

    func startPlan(keepReport: Bool = false) {
        guard let root, !busy else { return }
        if !keepReport { report = nil }
        phase = .planning
        Task {
            let made = await Task.detached(priority: .userInitiated) { Organizer.plan(root: root.path) }.value
            phase = .idle
            plan = made
            selection = Set(made.moves.map(\.source))
            kind = OrganizerKind.allCases.first { !made.moves($0).isEmpty } ?? .images
        }
    }

    func setSelected(_ on: Bool, kind: OrganizerKind) {
        let paths = (plan?.moves(kind) ?? []).map(\.source)
        if on { selection.formUnion(paths) } else { selection.subtract(paths) }
    }

    func setSelected(_ on: Bool, move: OrganizerMove) {
        if on { selection.insert(move.source) } else { selection.remove(move.source) }
    }

    func apply() {
        guard let root, !busy else { return }
        let moves = selectedMoves
        guard !moves.isEmpty else { return }
        let flag = CancelFlag()
        cancel = flag
        phase = .working(0)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Organizer.apply(moves, root: root.path, cancel: flag) { part in Task { @MainActor in if case .working = self.phase { self.phase = .working(part) } } }
            }.value
            phase = .idle
            last = result.done
            report = L("org.done", result.done.count) + (result.failed.isEmpty ? "" : " " + L("report.failed", result.failed.count))
            startPlan(keepReport: true)
        }
    }

    func undo() {
        guard !busy, !last.isEmpty else { return }
        let moves = last
        phase = .working(0)
        Task {
            let restored = await Task.detached(priority: .userInitiated) { Organizer.undo(moves) }.value
            phase = .idle
            last = []
            report = L("org.undone", restored)
            startPlan(keepReport: true)
        }
    }

    func cancelWork() { cancel.cancel() }
}
