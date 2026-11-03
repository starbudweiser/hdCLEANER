import AppKit
import HdCleanerCore
import SwiftUI

/// Chronologie de l'espace : relevé léger de l'espace libre (30 min), relevé quotidien des dossiers du dossier personnel,
/// et ce qui a grossi entre deux relevés. Les relevés ne tournent que tant que l'appli tourne (fenêtre ou icône de la barre de menus).
@MainActor
final class TimelineModel: ObservableObject {
    @Published private(set) var data: TimelineData
    @Published private(set) var running = false
    /// Durée affichée, en jours.
    @Published var range = 30
    /// Point de départ de la comparaison choisi sur la courbe ; par défaut le plus ancien relevé de la période.
    @Published var since: Date?
    /// Remplissage anormal détecté après un relevé : l'appli prévient (une fois par jour au plus).
    var onAnomaly: ((Anomaly, Growth?) -> Void)?

    private var store: TimelineStore
    private let home: URL
    private var timer: Timer?
    private var snapshotCancel = CancelFlag()
    private static let alertKey = "timeline.alerted"

    init(home: URL) {
        self.home = home
        store = TimelineStore(url: TimelineStore.location(home: home))
        data = store.data
    }

    func start() {
        recordSample()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordSample(); self?.snapshotIfDue() }
        }
        timer?.tolerance = 120
        // Premier relevé de dossiers un peu après le lancement : il ne doit pas gêner l'ouverture de la fenêtre.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.snapshotIfDue() }
    }

    func recordSample() {
        guard let disk = DiskInfo.read(home) else { return }
        store.add(sample: SpaceSample(date: Date(), available: disk.available, total: disk.total))
        store.save()
        data = store.data
    }

    func snapshotIfDue() {
        if let last = store.lastSnapshotDate, Date().timeIntervalSince(last) < 20 * 3600 { return }
        snapshotNow()
    }

    func snapshotNow() {
        guard !running else { return }
        running = true
        let flag = CancelFlag()
        snapshotCancel = flag
        let root = home.path
        Task {
            let sizes = await Task.detached(priority: .utility) { () -> [String: Int64]? in
                let tree = DiskMapper.scan(root: root, foldBelow: Timeline.minimumEntry, cancel: flag)
                return flag.isCancelled ? nil : Timeline.flatten(tree)
            }.value
            running = false
            guard let sizes else { return }
            store.add(snapshot: SpaceSnapshot(date: Date(), sizes: sizes))
            recordSample()
            store.save()
            data = store.data
            checkAnomaly()
        }
    }

    private func checkAnomaly() {
        guard let anomaly = Timeline.anomaly(data.samples) else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.alertKey) as? Date, Date().timeIntervalSince(last) < Timeline.day { return }
        defaults.set(Date(), forKey: Self.alertKey)
        let sorted = data.snapshots.sorted { $0.date < $1.date }
        var cause: Growth?
        if let latest = sorted.last, let old = Timeline.nearest(sorted, to: Date().addingTimeInterval(-Double(anomaly.days) * Timeline.day), excluding: latest) {
            cause = Timeline.growth(from: old, to: latest).first
        }
        onAnomaly?(anomaly, cause)
    }

    // MARK: Lecture pour l'écran

    var forecast: Forecast { Timeline.forecast(data.samples) }

    var visibleSamples: [SpaceSample] {
        let start = Date().addingTimeInterval(-Double(range) * Timeline.day)
        return data.samples.filter { $0.date >= start }.sorted { $0.date < $1.date }
    }

    var snapshots: [SpaceSnapshot] { data.snapshots.sorted { $0.date < $1.date } }

    /// Relevés comparés : le plus ancien relevé de la période (ou le plus proche du point choisi) et le dernier.
    var comparison: (from: SpaceSnapshot, to: SpaceSnapshot)? {
        let all = snapshots
        guard all.count >= 2, let latest = all.last else { return nil }
        let target = since ?? Date().addingTimeInterval(-Double(range) * Timeline.day)
        guard let from = Timeline.nearest(all, to: target, excluding: latest), from.date < latest.date else { return nil }
        return (from, latest)
    }

    var causes: [Growth] {
        guard let c = comparison else { return [] }
        return Timeline.growth(from: c.from, to: c.to)
    }
}

// MARK: - Écran

struct TimelineView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: TimelineModel

    var body: some View {
        VStack(spacing: Socle.M.space3) {
            summary
            chartPanel
            causesPanel
        }
    }

    private func perDay(_ bytes: Int64) -> String { SizeFormat.text(bytes) }

    private var summary: some View {
        Panel {
            HStack(alignment: .center, spacing: Socle.M.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    switch model.forecast {
                    case .unknown:
                        line(L("tl.unknown.title"), L("tl.unknown.body"), Socle.C.textStrong)
                    case .stable:
                        line(L("tl.stable.title"), L("tl.stable.body"), Brand.color)
                    case .filling(let rate, let days):
                        line(L("tl.filling.title", perDay(rate)), L("tl.filling.body", days), days < 14 ? Socle.C.danger : Socle.C.warning)
                    case .freeing(let rate):
                        line(L("tl.freeing.title", perDay(rate)), L("tl.freeing.body"), Brand.color)
                    }
                }
                Spacer(minLength: Socle.M.space3)
                VStack(alignment: .trailing, spacing: Socle.M.space1) {
                    Button(model.running ? L("tl.snapshotRunning") : L("tl.snapshotNow")) { model.snapshotNow() }
                        .buttonStyle(SocleButtonStyle(.primary)).fixedSize().disabled(model.running)
                    Text(model.snapshots.last.map { L("tl.last", $0.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())) } ?? L("tl.never"))
                        .socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                }
            }
            .padding(Socle.M.space4)
        }
    }

    private func line(_ title: String, _ body: String, _ color: Color) -> some View {
        Group {
            Text(title).socle(Socle.T.heading).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Text(body).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Courbe

    private var chartPanel: some View {
        Panel {
            VStack(spacing: 0) {
                HStack {
                    Text(L("tl.chart")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                    Spacer()
                    SocleSegmented(options: [7, 30, 90], selection: model.range, label: { L("tl.range", $0) }, onSelect: { model.range = $0; model.since = nil })
                }
                .padding(.horizontal, Socle.M.space3)
                .frame(height: 40)
                .background(Socle.C.surfaceRaised)
                SpaceChart(samples: model.visibleSamples, range: model.range, snapshots: model.snapshots.map(\.date), marker: model.comparison?.from.date) { model.since = $0 }
                    .frame(height: 150)
                    .padding(Socle.M.space3)
            }
        }
    }

    // MARK: Causes

    private var causesPanel: some View {
        Panel {
            VStack(spacing: 0) {
                PanelHeader(title: L("tl.causes"), trailing: model.comparison.map { L("tl.since", $0.from.date.formatted(.dateTime.day().month(.abbreviated))) } ?? "")
                if model.comparison == nil {
                    message(L("tl.empty"))
                } else if model.causes.isEmpty {
                    message(L("tl.noGrowth"))
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            let top = model.causes.first?.delta ?? 1
                            ForEach(Array(model.causes.enumerated()), id: \.element.id) { i, g in
                                if i > 0 { Rectangle().fill(Socle.C.borderSubtle).frame(height: 1) }
                                row(g, top: top)
                            }
                        }
                    }
                    Text(L("tl.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Socle.M.space3)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        Text(text).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(Socle.M.space5)
    }

    /// Éléments du dernier nettoyage proposé qui se trouvent dans ce dossier.
    private func cleanable(_ g: Growth) -> [JunkItem] {
        (app.result?.all ?? []).filter { $0.path == g.path || $0.path.hasPrefix(g.path + "/") || g.path.hasPrefix($0.path + "/") }
    }

    private func row(_ g: Growth, top: Int64) -> some View {
        let url = URL(fileURLWithPath: g.path)
        let items = cleanable(g)
        return HStack(spacing: Socle.M.space3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong).lineLimit(1).truncationMode(.middle)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: app.home.path, with: "~")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: Socle.M.space2)
            ZStack(alignment: .leading) {
                Rectangle().fill(Socle.C.bgSunken)
                Rectangle().fill(Socle.C.warning).frame(width: 90 * CGFloat(Double(g.delta) / Double(max(top, 1))))
            }
            .frame(width: 90, height: 6)
            Text("+" + SizeFormat.text(g.delta)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.text).frame(width: 78, alignment: .trailing)
            Button(L("tl.map")) { app.diskMap.root = url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : url.deletingLastPathComponent(); app.mode = .map; app.diskMap.startScan() }
                .buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize()
            if let first = items.first {
                Button(L("tl.clean", SizeFormat.text(items.reduce(0) { $0 + $1.size }))) {
                    app.category = first.category
                    app.selection = Set(items.filter { !$0.inUse }.map(\.path))
                    app.mode = .clean
                }
                .buttonStyle(SocleButtonStyle(.action, height: 26)).fixedSize()
            } else {
                Button(L("tl.finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize()
            }
        }
        .padding(.horizontal, Socle.M.space3).padding(.vertical, Socle.M.space2)
    }
}

/// Courbe de l'espace libre ; un clic choisit le point de départ de la comparaison.
private struct SpaceChart: View {
    let samples: [SpaceSample]
    let range: Int
    let snapshots: [Date]
    let marker: Date?
    let onPick: (Date) -> Void

    var body: some View {
        GeometryReader { geo in chart(geo.size) }
    }

    private func chart(_ size: CGSize) -> some View {
        let geo = (size: size, 0)
        let start = Date().addingTimeInterval(-Double(range) * Timeline.day), end = Date()
            let values = samples.map(\.available)
            let low = Double(values.min() ?? 0), high = Double(values.max() ?? 1)
            let pad = max((high - low) * 0.15, 1_000_000_000)
            let lo = max(low - pad, 0), hi = high + pad
            let plot = CGRect(x: 70, y: 6, width: max(geo.size.width - 78, 1), height: max(geo.size.height - 24, 1))
            func x(_ d: Date) -> CGFloat { plot.minX + plot.width * CGFloat(d.timeIntervalSince(start) / end.timeIntervalSince(start)) }
            func y(_ v: Int64) -> CGFloat { plot.maxY - plot.height * CGFloat((Double(v) - lo) / max(hi - lo, 1)) }
        return ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for i in 0...2 { // repères d'échelle
                        let v = lo + (hi - lo) * Double(i) / 2
                        let yy = plot.maxY - plot.height * CGFloat(i) / 2
                        context.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: yy)); $0.addLine(to: CGPoint(x: plot.maxX, y: yy)) }, with: .color(Socle.C.borderSubtle), lineWidth: 1)
                        context.draw(Text(SizeFormat.text(Int64(v))).font(.system(size: 10)).foregroundColor(Socle.C.textMuted), at: CGPoint(x: plot.minX - 6, y: yy), anchor: .trailing)
                    }
                    for (i, label) in [start, start.addingTimeInterval(end.timeIntervalSince(start) / 2), end].enumerated() {
                        context.draw(Text(label.formatted(.dateTime.day().month(.abbreviated))).font(.system(size: 10)).foregroundColor(Socle.C.textMuted),
                                     at: CGPoint(x: [plot.minX, plot.midX, plot.maxX][i], y: plot.maxY + 12), anchor: i == 0 ? .leading : i == 2 ? .trailing : .center)
                    }
                    for d in snapshots where d >= start { // relevés de dossiers
                        context.stroke(Path { $0.move(to: CGPoint(x: x(d), y: plot.maxY - 6)); $0.addLine(to: CGPoint(x: x(d), y: plot.maxY)) }, with: .color(Socle.C.textMuted), lineWidth: 1)
                    }
                    guard samples.count > 1 else { return }
                    var line = Path()
                    for (i, s) in samples.enumerated() { let p = CGPoint(x: x(s.date), y: y(s.available)); i == 0 ? line.move(to: p) : line.addLine(to: p) }
                    var area = line
                    area.addLine(to: CGPoint(x: x(samples.last!.date), y: plot.maxY)); area.addLine(to: CGPoint(x: x(samples[0].date), y: plot.maxY)); area.closeSubpath()
                    context.fill(area, with: .color(Brand.color.opacity(0.15)))
                    context.stroke(line, with: .color(Brand.color), lineWidth: 1.5)
                    if let marker, marker >= start {
                        context.stroke(Path { $0.move(to: CGPoint(x: x(marker), y: plot.minY)); $0.addLine(to: CGPoint(x: x(marker), y: plot.maxY)) }, with: .color(Socle.C.warning), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                if samples.count < 2 {
                    Text(L("tl.chartEmpty")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let t = min(max((value.location.x - plot.minX) / plot.width, 0), 1)
                onPick(start.addingTimeInterval(Double(t) * end.timeIntervalSince(start)))
            })
    }
}
