import XCTest
@testable import Browser_Setu

/// A download started by a click in a page is written to a hidden place of its own and given its real name only when it is complete.
@MainActor
final class StagedBrowserDownloadTests: XCTestCase {
    private var folder: URL!
    private var coordinator: DownloadCoordinator!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        DownloadCoordinator.directoryOverride = folder
        coordinator = DownloadCoordinator()
        coordinator.profileFolder = nil
    }

    override func tearDownWithError() throws {
        DownloadCoordinator.directoryOverride = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func visibleFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func testTheUnfinishedFileIsNotUnderTheFinalNameAndAppearsWholeWhenFinished() throws {
        let started = coordinator.begin(suggestedName: "report.bin", staged: true, cancel: {})
        XCTAssertTrue(DownloadCoordinator.isStagedFile(started.destination), "written to the task's own hidden place")
        try Data("half".utf8).write(to: started.destination)
        XCTAssertEqual(visibleFiles(), [], "nothing is visible while the transfer runs")
        try Data("the whole file".utf8).write(to: started.destination)
        coordinator.finish(started.id, source: nil)
        XCTAssertEqual(visibleFiles(), ["report.bin"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("report.bin")), "the whole file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.destination.deletingLastPathComponent().path), "the hidden place goes with it")
        XCTAssertEqual(coordinator.ledger.record(started.id)?.file.destinationPath, folder.appendingPathComponent("report.bin").path, "the record points at the published file")
    }

    func testAFileThatWasAlreadyThereIsNeverOverwritten() throws {
        try Data("mine".utf8).write(to: folder.appendingPathComponent("a.bin"))
        let started = coordinator.begin(suggestedName: "a.bin", staged: true, cancel: {})
        try Data("downloaded".utf8).write(to: started.destination)
        coordinator.finish(started.id, source: nil)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.bin")), "mine")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a (1).bin")), "downloaded")
    }

    func testAFileThatAppearsAtTheNameWhileTheTransferRunsIsKept() throws {
        let started = coordinator.begin(suggestedName: "b.bin", staged: true, cancel: {})
        try Data("downloaded".utf8).write(to: started.destination)
        try Data("appeared meanwhile".utf8).write(to: folder.appendingPathComponent("b.bin"))
        coordinator.finish(started.id, source: nil)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("b.bin")), "appeared meanwhile")
        XCTAssertEqual(visibleFiles().count, 2, "both are kept")
    }

    func testTwoDownloadsOfTheSameNameGetDifferentFinalNames() throws {
        let one = coordinator.begin(suggestedName: "same.bin", staged: true, cancel: {})
        let two = coordinator.begin(suggestedName: "same.bin", staged: true, cancel: {})
        try Data("1".utf8).write(to: one.destination); try Data("2".utf8).write(to: two.destination)
        coordinator.finish(one.id, source: nil); coordinator.finish(two.id, source: nil)
        XCTAssertEqual(visibleFiles(), ["same (1).bin", "same.bin"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("same.bin")), "1")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("same (1).bin")), "2")
    }

    func testCancellingLeavesNothingVisibleAndNothingHidden() throws {
        let started = coordinator.begin(suggestedName: "c.bin", staged: true, cancel: {})
        try Data("partial".utf8).write(to: started.destination)
        coordinator.discard(started.id)
        XCTAssertEqual(visibleFiles(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.destination.deletingLastPathComponent().path))
    }

    func testTheWayItWasBeforeIsUnchangedForOtherCallers() throws {
        let started = coordinator.begin(suggestedName: "d.bin", cancel: {})
        XCTAssertEqual(started.destination.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertFalse(DownloadCoordinator.isStagedFile(started.destination))
        coordinator.discard(started.id)
    }

    func testTheStagedTargetIsKeptWithTheTaskSoARelaunchCanFinishIt() throws {
        let started = coordinator.begin(suggestedName: "e.bin", staged: true, cancel: {})
        let meta = coordinator.ledger.record(started.id)?.engineMetadata
        XCTAssertEqual(meta?[DownloadCoordinator.saveAsTargetKey], folder.appendingPathComponent("e.bin").path)
        XCTAssertEqual(meta?[DownloadCoordinator.saveAsReplaceKey], "0", "never replaces anything")
        coordinator.discard(started.id)
    }

    func testPlacementAcrossVolumesIsNotStaged() {
        XCTAssertTrue(DownloadCoordinator.isOnSameVolume(folder, as: folder))
        XCTAssertFalse(DownloadCoordinator.isOnSameVolume(folder, as: URL(fileURLWithPath: "/nonexistent-volume-check")))
    }
}
