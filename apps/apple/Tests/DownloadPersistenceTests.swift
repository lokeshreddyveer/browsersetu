import XCTest
@testable import Browser_Setu

@MainActor
final class DownloadPersistenceTests: XCTestCase {
    func testAnInterruptedDownloadSurvivesRestartAndIsForgottenOnceHandled() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = DownloadCoordinator()
        first.store = folder
        let started = first.begin(suggestedName: "big.zip", cancel: {})
        first.interrupt(started.id, resumeData: Data("resume-bytes".utf8), source: URL(string: "https://a.test/big.zip"))
        XCTAssertEqual(first.interrupted.count, 1)

        let second = DownloadCoordinator()          // the app was quit and opened again
        second.store = folder
        XCTAssertEqual(second.interrupted.count, 1)
        XCTAssertEqual(second.interrupted[started.id]?.filename, "big.zip")
        XCTAssertEqual(second.interrupted[started.id]?.resumeData, Data("resume-bytes".utf8))

        var resumedWith: Data?
        second.resumer = { resumedWith = $0 }
        second.resume(started.id)
        XCTAssertEqual(resumedWith, Data("resume-bytes".utf8))
        let third = DownloadCoordinator(); third.store = folder
        XCTAssertTrue(third.interrupted.isEmpty, "a resumed download is not offered again")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".resume") }.isEmpty)
    }

    func testRunningDownloadsHandBackTheirPlaceWhenAskedToStop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let c = DownloadCoordinator(); c.store = folder
        _ = c.begin(suggestedName: "a.bin", cancel: {}, suspend: { done in done(Data("place".utf8)) })
        _ = c.begin(suggestedName: "b.bin", cancel: {}, suspend: { done in done(nil) })    // one that has nothing to resume
        await withCheckedContinuation { cont in c.suspendAll { cont.resume() } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(c.interrupted.count, 1)
        let again = DownloadCoordinator(); again.store = folder
        XCTAssertEqual(again.interrupted.count, 1)
    }

    func testAHostileIndexCannotEscapeOrOverfillTheList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        try Data("x".utf8).write(to: folder.appendingPathComponent(id.uuidString + ".resume"))
        try Data("[{\"id\":\"\(id.uuidString)\",\"filename\":\"../../etc/passwd\",\"source\":null}]".utf8).write(to: folder.appendingPathComponent("interrupted.json"))
        let c = DownloadCoordinator(); c.store = folder
        XCTAssertEqual(c.interrupted[id]?.filename, "passwd", "only a plain file name is kept")
    }
}
