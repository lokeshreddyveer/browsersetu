import XCTest
import Combine
@testable import Browser_Setu

/// What the Downloads list costs while the person scrolls it: how long one rebuild of a long list takes on the main actor, and that a rebuild that changes nothing publishes nothing (so SwiftUI has nothing to re-evaluate).
@MainActor
final class DownloadsScrollCostTests: XCTestCase {
    func testALongListRebuildsQuicklyAndAnUnchangedRebuildPublishesNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scrollcost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = folder
        let suite = "scrollcost-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        defer { DownloadCoordinator.directoryOverride = saved; defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let coordinator = DownloadCoordinator()
        for i in 0..<1000 {
            let r = coordinator.ledger.create(protocolID: .http, source: URL(string: "https://example.com/f\(i).bin"), filename: "file-\(i).bin", isPrivate: false, priority: .normal)
            for e: DownloadEvent in [.queued, .started, .running, .verifying, .completed(.verified)] { _ = coordinator.ledger.apply(e, to: r.id) }
        }
        let vm = DownloadsViewModel(coordinator: coordinator, performer: nil, defaults: defaults, changeDelay: 0, progressDelay: 0.05)
        vm.refreshNow()
        XCTAssertGreaterThanOrEqual(vm.rows.count, 500, "the list is capped (600 here), so this is the most a rebuild ever has to project")
        var times: [Double] = []
        for _ in 0..<15 { let t = CFAbsoluteTimeGetCurrent(); vm.refreshNow(); times.append((CFAbsoluteTimeGetCurrent() - t) * 1000) }
        let avg = times.reduce(0, +) / Double(times.count), worst = times.max() ?? 0
        print("SCROLLCOST rebuild of \(vm.rows.count) rows: average \(String(format: "%.1f", avg)) ms, worst \(String(format: "%.1f", worst)) ms (a 60 Hz frame is 16.7 ms)")
        XCTAssertLessThan(avg, 250, "a rebuild must not take a quarter of a second on the main actor")
        var published = 0
        let c = vm.$rows.dropFirst().sink { _ in published += 1 }
        vm.refreshNow(); vm.refreshNow()
        XCTAssertEqual(published, 0, "rows that did not change are not published again")
        c.cancel()
    }
}
