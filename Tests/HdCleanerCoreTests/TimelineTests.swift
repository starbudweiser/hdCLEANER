import XCTest
@testable import HdCleanerCore

final class TimelineTests: XCTestCase {
    private let GB: Int64 = 1_000_000_000
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func samples(_ values: [Int64], dayStep: Double = 1) -> [SpaceSample] {
        values.enumerated().map { i, v in
            SpaceSample(date: now.addingTimeInterval(-Double(values.count - 1 - i) * dayStep * Timeline.day), available: v * GB, total: 500 * GB)
        }
    }

    func testGrowthDescendsToTheResponsibleFolder() {
        let old = SpaceSnapshot(date: now, sizes: ["/h": 100 * GB, "/h/Library": 60 * GB, "/h/Library/Docker": 10 * GB, "/h/Library/Mail": 5 * GB, "/h/Movies": 40 * GB])
        let new = SpaceSnapshot(date: now, sizes: ["/h": 130 * GB, "/h/Library": 90 * GB, "/h/Library/Docker": 40 * GB, "/h/Library/Mail": 5 * GB, "/h/Movies": 40 * GB])
        let found = Timeline.growth(from: old, to: new)
        XCTAssertEqual(found.map(\.path), ["/h/Library/Docker"])
        XCTAssertEqual(found.first?.delta, 30 * GB)
    }

    func testGrowthKeepsParentWhenSeveralChildrenShareTheRise() {
        let old = SpaceSnapshot(date: now, sizes: ["/h": 50 * GB, "/h/A": 10 * GB, "/h/B": 10 * GB, "/h/C": 10 * GB])
        let new = SpaceSnapshot(date: now, sizes: ["/h": 80 * GB, "/h/A": 20 * GB, "/h/B": 20 * GB, "/h/C": 20 * GB])
        XCTAssertEqual(Set(Timeline.growth(from: old, to: new).map(\.path)), ["/h/A", "/h/B", "/h/C"])
    }

    func testGrowthIgnoresSmallChangesAndShrinking() {
        let old = SpaceSnapshot(date: now, sizes: ["/h": 100 * GB, "/h/A": 50 * GB])
        let new = SpaceSnapshot(date: now, sizes: ["/h": 100 * GB + 100_000_000, "/h/A": 40 * GB])
        XCTAssertTrue(Timeline.growth(from: old, to: new).isEmpty)
    }

    func testForecastFilling() {
        guard case .filling(let perDay, let left) = Timeline.forecast(samples([100, 90, 80, 70, 60]), now: now) else { return XCTFail("remplissage attendu") }
        XCTAssertEqual(Double(perDay) / Double(GB), 10, accuracy: 0.01)
        XCTAssertEqual(left, 6)
    }

    func testForecastStableFreeingAndUnknown() {
        XCTAssertEqual(Timeline.forecast(samples([100, 100, 100, 100]), now: now), .stable)
        guard case .freeing = Timeline.forecast(samples([50, 60, 70]), now: now) else { return XCTFail("libération attendue") }
        XCTAssertEqual(Timeline.forecast(samples([100]), now: now), .unknown)
        XCTAssertEqual(Timeline.forecast(samples([100, 99], dayStep: 0.2), now: now), .unknown) // moins d'un jour d'historique
    }

    func testAnomalyNeedsFastLoss() {
        var calm = samples([200, 199, 198, 197, 196, 195, 194, 193, 192, 191, 190, 189, 188, 187, 186])
        XCTAssertNil(Timeline.anomaly(calm, now: now))
        calm.append(contentsOf: [])
        let sudden = samples([200, 199, 198, 197, 196, 195, 194, 193, 192, 191, 190, 189, 160, 150, 140])
        let a = Timeline.anomaly(sudden, now: now)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.days, 3)
        XCTAssertGreaterThanOrEqual(a?.lost ?? 0, 30 * GB)
    }

    func testStoreRoundTripAndLimits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var store = TimelineStore(url: url)
        store.add(sample: SpaceSample(date: now, available: 10 * GB, total: 100 * GB))
        store.add(sample: SpaceSample(date: now.addingTimeInterval(60), available: 9 * GB, total: 100 * GB)) // trop proche : ignoré
        store.add(sample: SpaceSample(date: now.addingTimeInterval(3600), available: 8 * GB, total: 100 * GB))
        store.add(snapshot: SpaceSnapshot(date: now, sizes: ["/h": 5 * GB]))
        store.save()
        let back = TimelineStore(url: url)
        XCTAssertEqual(back.data.samples.count, 2)
        XCTAssertEqual(back.data.snapshots.first?.sizes["/h"], 5 * GB)
        XCTAssertEqual(back.lastSnapshotDate, now)
    }

    func testOldSamplesAreThinnedToOnePerDay() {
        var store = TimelineStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json"))
        let old = now.addingTimeInterval(-60 * Timeline.day)
        for h in 0..<10 { store.add(sample: SpaceSample(date: old.addingTimeInterval(Double(h) * 3600), available: GB, total: 10 * GB)) }
        store.add(sample: SpaceSample(date: now, available: GB, total: 10 * GB))
        XCTAssertLessThan(store.data.samples.count, 6)
    }

    func testNearestSnapshot() {
        let a = SpaceSnapshot(date: now.addingTimeInterval(-7 * Timeline.day), sizes: [:]), b = SpaceSnapshot(date: now, sizes: [:])
        XCTAssertEqual(Timeline.nearest([a, b], to: now.addingTimeInterval(-6 * Timeline.day)), a)
        XCTAssertEqual(Timeline.nearest([a, b], to: now, excluding: b), a)
    }
}
