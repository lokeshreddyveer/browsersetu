import XCTest
import CryptoKit
@testable import Browser_Setu

/// Regression tests for the defects found by the Downloads retrospective audit. Temporary folders only.
@MainActor
final class RetrospectiveFixTests: XCTestCase {
    private var folder: URL!
    private var downloads: URL!
    private var savedOverride: URL?

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retro-\(UUID().uuidString)")
        folder = root.appendingPathComponent("store")
        downloads = root.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
    }

    override func tearDown() {
        DownloadTaskStore.close(folder: folder)
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        DownloadCoordinator.directoryOverride = savedOverride
        super.tearDown()
    }

    private func coordinator() -> DownloadCoordinator {
        let c = DownloadCoordinator(); c.profileName = "default"; c.store = folder; return c
    }
    private let source = URL(string: "https://files.test/f.bin")!

    // D6: the diagnostics are pasted into bug reports, so a private download is not named in them.
    func testDiagnosticsDoNotNameAPrivateDownload() {
        let c = coordinator()
        _ = c.begin(suggestedName: "secret-plan.pdf", sourceHost: "private.example", sourceURL: source, isPrivate: true, cancel: {})
        _ = c.begin(suggestedName: "ordinary.pdf", sourceHost: "public.example", sourceURL: URL(string: "https://files.test/o.pdf"), cancel: {})
        let text = c.diagnostics
        XCTAssertFalse(text.contains("secret-plan"), text)
        XCTAssertFalse(text.contains("private.example"), text)
        XCTAssertTrue(text.contains("ordinary.pdf"), "an ordinary download is still named")
    }

    // D1: a file of the right size is not a file with the right checksum.
    private func interruptedWithFile(checksum: String, content: Data) -> (DownloadCoordinator, UUID, URL) {
        let first = coordinator()
        let started = first.begin(suggestedName: "f.bin", sourceURL: source, protocolID: .http, cancel: {})
        let second = coordinator()
        XCTAssertEqual(second.ledger.record(started.id)?.state, .recoveryRequired)
        second.ledger.update(started.id) { $0.engineMetadata["sha256"] = checksum; $0.transfer.totalBytes = Int64(content.count) }
        try? content.write(to: started.destination)
        return (second, started.id, started.destination)
    }
    private func waitFor(_ ok: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 { if ok() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return false
    }

    func testARecoveredFileWithTheWrongChecksumIsDeletedNotMarkedVerified() async {
        let content = Data(repeating: 7, count: 4096)
        let (c, id, path) = interruptedWithFile(checksum: String(repeating: "0", count: 64), content: content)
        HTTPRecovery.reconcile(c.ledger)
        let gone = await waitFor { !FileManager.default.fileExists(atPath: path.path) }
        XCTAssertTrue(gone, "the file that does not match is not kept under the real name")
        XCTAssertNotEqual(c.ledger.record(id)?.state, .completed)
    }

    func testARecoveredFileWithTheRightChecksumIsVerified() async {
        let content = Data(repeating: 9, count: 4096)
        let sum = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let (c, id, path) = interruptedWithFile(checksum: sum, content: content)
        HTTPRecovery.reconcile(c.ledger)
        let done = await waitFor { c.ledger.record(id)?.state == .completed }
        XCTAssertTrue(done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testAPastedChecksumWithAPrefixAndCapitalsStillVerifies() async {
        let content = Data(repeating: 5, count: 4096)
        let sum = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let (c, id, path) = interruptedWithFile(checksum: "SHA256:" + sum.uppercased(), content: content)
        HTTPRecovery.reconcile(c.ledger)
        let done = await waitFor { c.ledger.record(id)?.state == .completed }
        XCTAssertTrue(done, "the file is right: it must not be deleted because of how the checksum was typed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testANoteNeverNamesAPrivateDownloadWhichCodeWroteIt() {
        let c = coordinator()
        _ = c.begin(suggestedName: "secret-plan.pdf", sourceURL: source, isPrivate: true, cancel: {})
        c.note("Resumed secret-plan.pdf from the start")
        XCTAssertFalse(c.diagnostics.contains("secret-plan"), c.diagnostics)
        XCTAssertTrue(c.diagnostics.contains("a private download"))
    }

    // D5: the staged name is swept like the other hidden working names.
    func testTheStagedNameIsOneThePartSweepKnows() {
        let id = UUID()
        let url = HTTPTransferEngine.stagedURL(for: id, in: downloads)
        XCTAssertEqual(url.lastPathComponent, ".\(id.uuidString.prefix(8)).bsetu-staged")
    }
}
