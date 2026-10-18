import XCTest
@testable import Browser_Setu

final class ReliabilityTests: XCTestCase {
    func testDiagLogNeverKeepsAddresses() {
        XCTAssertEqual(DiagLog.sanitize("Failed https://secret.example.com/path?token=abc and more"), "Failed <address> and more")
        XCTAssertFalse(DiagLog.line("nav", "went to http://x.test/a b").contains("x.test"))
        XCTAssertEqual(DiagLog.sanitize("a\nb"), "a b")
        XCTAssertLessThanOrEqual(DiagLog.sanitize(String(repeating: "x", count: 500)).count, 200)
    }

    func testDiagLogWritesAndTrims() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        DiagLog.folder = folder
        defer { DiagLog.folder = nil }
        for i in 0..<(DiagLog.maxLines + 20) { DiagLog.record("test", "event \(i)") }
        let exp = expectation(description: "written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { exp.fulfill() }
        wait(for: [exp], timeout: 5)
        let lines = DiagLog.recent(limit: 1000)
        XCTAssertEqual(lines.count, DiagLog.maxLines)
        XCTAssertTrue(lines.last?.hasSuffix("event \(DiagLog.maxLines + 19)") ?? false)
    }

    func testCheckpointTakingRules() {
        let now = Date()
        XCTAssertTrue(CheckpointRules.shouldTake(lastKey: nil, lastDate: nil, newKey: "a", now: now))
        XCTAssertFalse(CheckpointRules.shouldTake(lastKey: "a", lastDate: now.addingTimeInterval(-3600), newKey: "a", now: now), "nothing changed")
        XCTAssertFalse(CheckpointRules.shouldTake(lastKey: "a", lastDate: now.addingTimeInterval(-60), newKey: "b", now: now), "too soon")
        XCTAssertTrue(CheckpointRules.shouldTake(lastKey: "a", lastDate: now.addingTimeInterval(-700), newKey: "b", now: now))
        XCTAssertFalse(CheckpointRules.shouldTake(lastKey: nil, lastDate: nil, newKey: "", now: now), "no pages, no checkpoint")
    }

    func testCheckpointPruningKeepsRecentAndThinsOlder() {
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 1800)   // half past an hour, so the test does not depend on the clock
        func cp(_ minutesAgo: Double, _ reason: String = "Automatic") -> SessionCheckpoint {
            SessionCheckpoint(date: now.addingTimeInterval(-minutesAgo * 60), reason: reason, tabs: [.init(url: "https://a.com", title: "", pinned: false, group: "", workspace: "")])
        }
        let list = [cp(10), cp(60), cp(150), cp(200), cp(230), cp(400), cp(410), cp(5000), cp(300, "Before closing other tabs"), cp(2000, "Before closing other tabs")]
        let kept = CheckpointRules.prune(list, now: now)
        XCTAssertTrue(kept.contains { $0.date == now.addingTimeInterval(-600) }, "recent kept")
        XCTAssertTrue(kept.contains { $0.date == now.addingTimeInterval(-60 * 150) })
        XCTAssertFalse(kept.contains { $0.date == now.addingTimeInterval(-5000 * 60) }, "older than three days dropped")
        XCTAssertEqual(kept.filter { $0.reason == "Automatic" && now.timeIntervalSince($0.date) > 3 * 3600 }.count, 3, "200, 230 and the pair at 400 and 410 minutes (one hour) leave three")
        XCTAssertTrue(kept.contains { $0.reason != "Automatic" && now.timeIntervalSince($0.date) < 24 * 3600 }, "a forced one stays a day")
        XCTAssertLessThanOrEqual(kept.count, CheckpointRules.maxCount)
    }

    func testMissingPagesAreOnlyThoseNotOpen() {
        let c = SessionCheckpoint(date: Date(), reason: "x", tabs: ["https://a.com", "https://b.com", "https://a.com"].map { .init(url: $0, title: "", pinned: false, group: "", workspace: "") })
        XCTAssertEqual(CheckpointRules.missing(c, openURLs: ["https://a.com"]).map(\.url), ["https://b.com"])
        XCTAssertEqual(CheckpointRules.missing(c, openURLs: []).count, 2, "a repeated page is reopened once")
    }

    func testCheckpointKeyIgnoresOrder() {
        let a = SessionCheckpoint(date: Date(), reason: "x", tabs: [.init(url: "https://a.com", title: "", pinned: false, group: "", workspace: ""), .init(url: "https://b.com", title: "", pinned: false, group: "", workspace: "")])
        var b = a; b.tabs.reverse()
        XCTAssertEqual(a.key, b.key)
    }

    func testDatabaseQuickCheck() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chk-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("garbage garbage garbage garbage garbage".utf8).write(to: file)
        XCTAssertNotEqual(DatabaseCheck.quickCheck(at: file), "ok")
        XCTAssertNotEqual(DatabaseCheck.quickCheck(at: file.appendingPathExtension("missing")), "ok")
    }

    @MainActor func testStatusReflectsRealCounts() {
        let stats = ReliabilityStats()
        XCTAssertEqual(stats.status(recovering: false, safeStart: false), .healthy)
        if case .attention(let r) = stats.status(recovering: true, safeStart: true) { XCTAssertEqual(r.count, 2) } else { XCTFail() }
        stats.noteTabCrash()
        if case .attention = stats.status(recovering: false, safeStart: false) {} else { XCTFail("a crash needs attention") }
        XCTAssertFalse(stats.report(tabs: 3, sleeping: 1, extensions: 0).contains("http"))
    }
}
