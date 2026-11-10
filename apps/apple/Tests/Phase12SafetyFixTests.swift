import XCTest
import WebKit
@testable import Browser_Setu

// Phase 12 completion fixes: Save As file safety, profile / data-store ownership, context lifecycle. Real WebKit downloads run against the local fixture (127.0.0.1:18766).

private let base = "http://127.0.0.1:18766"

// MARK: - Store identity (pure)

final class StoreIdentityTests: XCTestCase {
    private let a = UUID(), b = UUID()
    private func hosts() -> [(host: String, store: DownloadStoreKey)] {
        [("privateOne", DownloadStoreKey(identifier: nil, isPersistent: false, session: a)),
         ("privateTwo", DownloadStoreKey(identifier: nil, isPersistent: false, session: b)),
         ("profileB", DownloadStoreKey(identifier: b, isPersistent: true)),
         ("default", DownloadStoreKey(identifier: nil, isPersistent: true))]
    }
    func testAnExactStoreIsUsed() { XCTAssertEqual(DownloadHostSelection.pick(hosts(), for: DownloadStoreKey(identifier: b, isPersistent: true)), "profileB") }
    func testAnotherProfileIsNeverSubstituted() { XCTAssertNil(DownloadHostSelection.pick(hosts(), for: DownloadStoreKey(identifier: UUID(), isPersistent: true))) }
    func testEachPrivateSessionIsItsOwnIdentity() {
        XCTAssertEqual(DownloadHostSelection.pick(hosts(), for: DownloadStoreKey(identifier: nil, isPersistent: false, session: a)), "privateOne")
        XCTAssertEqual(DownloadHostSelection.pick(hosts(), for: DownloadStoreKey(identifier: nil, isPersistent: false, session: b)), "privateTwo")
        XCTAssertNil(DownloadHostSelection.pick(hosts(), for: DownloadStoreKey(identifier: nil, isPersistent: false, session: UUID())), "a closed private session has no stand-in")
    }
    func testAnUnknownStoreGetsNoPageAtAll() { XCTAssertNil(DownloadHostSelection.pick(hosts(), for: nil)) }
    func testOnlyAProfilesStoreNameIsKeptAndPrivateIsNeverKept() {
        let profile = DownloadStoreKey(identifier: b, isPersistent: true)
        XCTAssertEqual(DownloadStoreKey(persisted: profile.persistedValue), profile)
        XCTAssertEqual(DownloadStoreKey(persisted: DownloadStoreKey(identifier: nil, isPersistent: true).persistedValue), DownloadStoreKey(identifier: nil, isPersistent: true))
        XCTAssertNil(DownloadStoreKey(identifier: nil, isPersistent: false, session: a).persistedValue)
        XCTAssertNil(DownloadStoreKey(persisted: "not-a-uuid"))
        XCTAssertNil(DownloadStoreKey(persisted: nil))
    }
    func testMenuOrderIsExplicitAndDeterministic() {
        let items = [BrowserMenuDownloads.Insertion(position: 3, rank: 0, kind: "link"), BrowserMenuDownloads.Insertion(position: 7, rank: 0, kind: "image"),
                     BrowserMenuDownloads.Insertion(position: 7, rank: 1, kind: "show")]
        let order = BrowserMenuDownloads.insertionOrder(items).map(\.kind)
        XCTAssertEqual(order, ["show", "image", "link"], "highest position first; at one position the higher rank goes in first so it ends up last")
        XCTAssertEqual(BrowserMenuDownloads.insertionOrder(items.reversed()).map(\.kind), order)
    }
}

// MARK: - Save As placement (pure, real files)

final class SaveAsPlacementTests: XCTestCase {
    private var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("p12-place-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func staged(_ bytes: [UInt8]) throws -> URL {
        let f = dir.appendingPathComponent("staged-\(UUID().uuidString)"); try Data(bytes).write(to: f); return f
    }

    func testChoosingAPlaceChangesNothingOnDisk() throws {
        let existing = dir.appendingPathComponent("mine.bin"); try Data([1, 2]).write(to: existing)
        let choice = SaveAsDestination.resolve(existing)
        XCTAssertTrue(choice.replaceExisting)
        XCTAssertEqual(try Data(contentsOf: existing), Data([1, 2]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["mine.bin"])
    }
    func testAFreePlaceReceivesTheFile() throws {
        let s = try staged([9])
        let target = dir.appendingPathComponent("new.bin")
        XCTAssertEqual(SaveAsDestination.place(staged: s, choice: .init(target: target, replaceExisting: false)), .placed(target))
        XCTAssertEqual(try Data(contentsOf: target), Data([9])); XCTAssertFalse(FileManager.default.fileExists(atPath: s.path))
    }
    func testReplacingSwapsInOneStepAndTheOldFileGoesToTheTrashAfterwards() throws {
        let target = dir.appendingPathComponent("a.bin"); try Data([1]).write(to: target)
        let s = try staged([2])
        var disposed: URL?
        let result = SaveAsDestination.place(staged: s, choice: SaveAsDestination.resolve(target), dispose: {
            // At this moment the new file is already at the chosen name, and the old content is the backup being disposed of.
            XCTAssertEqual(try? Data(contentsOf: target), Data([2]))
            let t = self.dir.appendingPathComponent("trash-a.bin"); try? FileManager.default.moveItem(at: $0, to: t); disposed = t; return true
        })
        XCTAssertEqual(result, .placed(target))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(disposed)), Data([1]), "the original is recoverable")
    }
    func testAFailedSwapLeavesTheOriginalWhereItWas() throws {
        let target = dir.appendingPathComponent("a.bin"); try Data([1]).write(to: target)
        let missing = dir.appendingPathComponent("not-there")          // staging vanished: nothing can be swapped
        let result = SaveAsDestination.place(staged: missing, choice: SaveAsDestination.resolve(target), dispose: { _ in XCTFail("nothing to dispose of"); return false })
        guard case .failed = result else { return XCTFail("expected a failure, got \(result)") }
        XCTAssertEqual(try Data(contentsOf: target), Data([1]))
    }
    func testAnInterruptionRightAfterTheSwapLosesNeitherVersion() throws {
        // The app "stops" between the swap and the disposal of the backup: the new file is in place and the old content is still on disk beside it.
        let target = dir.appendingPathComponent("a.bin"); try Data([1]).write(to: target)
        struct Stop: Error {}
        let result = SaveAsDestination.place(staged: try staged([2]), choice: SaveAsDestination.resolve(target), dispose: { _ in XCTFail("the app stopped before this"); return true }, afterSwap: { throw Stop() })
        XCTAssertEqual(result, .placed(target))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".a.bin.replaced-") }
        XCTAssertEqual(try Data(contentsOf: target), Data([2]), "the new file is in place")
        XCTAssertEqual(leftovers.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(leftovers[0])), Data([1]), "and the old content is still on disk")
    }
    func testAnInterruptionBeforeTheSwapLeavesTheOldFileAndTheNewOne() throws {
        let target = dir.appendingPathComponent("a.bin"); try Data([1]).write(to: target)
        let s = try staged([2])
        // Nothing has been done yet: both exist, in their own places.
        XCTAssertEqual(try Data(contentsOf: target), Data([1])); XCTAssertEqual(try Data(contentsOf: s), Data([2]))
    }
    func testAFileThatAppearedAfterThePanelIsNotReplaced() throws {
        let target = dir.appendingPathComponent("late.bin")
        let choice = SaveAsDestination.resolve(target)                  // free when chosen
        XCTAssertFalse(choice.replaceExisting)
        try Data([5]).write(to: target)                                 // someone else made it meanwhile
        let result = SaveAsDestination.place(staged: try staged([6]), choice: choice, dispose: { _ in XCTFail("nothing may be disposed of"); return false })
        guard case .keptBoth(let other) = result else { return XCTFail("expected both kept, got \(result)") }
        XCTAssertNotEqual(other, target)
        XCTAssertEqual(try Data(contentsOf: target), Data([5])); XCTAssertEqual(try Data(contentsOf: other), Data([6]))
    }
    func testWhenTheBackupCannotBeTrashedItStaysBesideTheNewFile() throws {
        let target = dir.appendingPathComponent("a.bin"); try Data([1]).write(to: target)
        let result = SaveAsDestination.place(staged: try staged([2]), choice: SaveAsDestination.resolve(target), dispose: { _ in false })
        guard case .placedKeepingOld(let url, let old) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(url, target); XCTAssertEqual(try Data(contentsOf: target), Data([2]))
        XCTAssertFalse(old.lastPathComponent.hasPrefix("."), "the old content has a visible name, not a hidden one")
        XCTAssertEqual(try Data(contentsOf: old), Data([1]), "the old content was not thrown away")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".a.bin.replaced-") }.isEmpty)
    }
    func testAHostileNameStaysInTheChosenFolder() {
        let c = SaveAsDestination.resolve(dir.appendingPathComponent("..%2F..%2Fx"))
        XCTAssertEqual(c.target.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
    }
}

// MARK: - Save As through the coordinator

@MainActor
final class SaveAsCoordinatorTests: XCTestCase {
    private var scratch: URL!, chosenDir: URL!
    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("p12-sa-\(UUID().uuidString)", isDirectory: true)
        chosenDir = FileManager.default.temporaryDirectory.appendingPathComponent("p12-sa-out-\(UUID().uuidString)", isDirectory: true)
        for d in [scratch!, chosenDir!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        DownloadCoordinator.directoryOverride = scratch
    }
    override func tearDown() async throws {
        DownloadCoordinator.directoryOverride = nil
        for d in [scratch!, chosenDir!] { try? FileManager.default.removeItem(at: d) }
    }

    private func start(_ c: DownloadCoordinator, _ name: String, replace: Bool = false) -> (id: UUID, staging: URL, target: URL) {
        let target = chosenDir.appendingPathComponent(name)
        let choice = replace ? SaveAsDestination.resolve(target) : SaveAsDestination.Choice(target: target, replaceExisting: false)
        let s = c.begin(suggestedName: "x", sourceURL: URL(string: "https://a.org/\(name)"), saveAs: choice, cancel: {})
        return (s.id, s.destination, target)
    }

    func testWebKitWritesToATaskOwnedStagingPlaceNeverTheChosenOne() throws {
        let c = DownloadCoordinator()
        let t = start(c, "out.bin")
        XCTAssertNotEqual(t.staging, t.target)
        XCTAssertTrue(t.staging.path.hasPrefix(DownloadCoordinator.saveAsRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.staging.path), "WebKit is given a file that does not exist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.target.path))
    }

    func testTheOriginalSurvivesATransferThatIsCancelled() throws {
        let c = DownloadCoordinator()
        let original = chosenDir.appendingPathComponent("keep.bin"); try Data([7, 7]).write(to: original)
        let t = start(c, "keep.bin", replace: true)
        try Data([1]).write(to: t.staging)
        c.cancel(t.id)
        XCTAssertEqual(try Data(contentsOf: original), Data([7, 7]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.staging.deletingLastPathComponent().path), "the staging folder goes with it")
    }

    func testTheOriginalSurvivesATransferThatFails() throws {
        let c = DownloadCoordinator()
        let original = chosenDir.appendingPathComponent("keep.bin"); try Data([7, 7]).write(to: original)
        let t = start(c, "keep.bin", replace: true)
        try Data([1]).write(to: t.staging)
        c.fail(t.id, source: nil, error: URLError(.networkConnectionLost), willRetry: false)
        XCTAssertEqual(try Data(contentsOf: original), Data([7, 7]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.staging.path))
    }

    func testAFinishedTransferReplacesTheOriginalOnlyAtTheEnd() throws {
        let c = DownloadCoordinator()
        let original = chosenDir.appendingPathComponent("r.bin"); try Data([7]).write(to: original)
        let t = start(c, "r.bin", replace: true)
        try Data([1, 2, 3]).write(to: t.staging)
        XCTAssertEqual(try Data(contentsOf: original), Data([7]), "untouched while it is running")
        c.finish(t.id, source: nil)
        XCTAssertEqual(try Data(contentsOf: original), Data([1, 2, 3]))
        XCTAssertEqual(c.completed.first, t.target)
        XCTAssertEqual(c.ledger.record(t.id)?.file.destinationPath, t.target.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.staging.path))
    }

    func testTwoDownloadsToTheSameFreePlaceNeverShareIt() throws {
        let c = DownloadCoordinator()
        let one = start(c, "same.bin"), two = start(c, "same.bin")
        try Data([1]).write(to: one.staging); try Data([2]).write(to: two.staging)
        c.finish(one.id, source: nil); c.finish(two.id, source: nil)
        XCTAssertEqual(c.completed.count, 2)
        XCTAssertEqual(Set(c.completed).count, 2, "two different files")
        XCTAssertEqual(try Data(contentsOf: chosenDir.appendingPathComponent("same.bin")), Data([1]))
        XCTAssertEqual(Set(c.completed.map { try! Data(contentsOf: $0) }), [Data([1]), Data([2])])
    }

    func testAPlaceThatCannotBeWrittenKeepsTheFileInDownloadsAndSaysSo() throws {
        let c = DownloadCoordinator()
        let gone = chosenDir.appendingPathComponent("vanished", isDirectory: true).appendingPathComponent("x.bin")      // folder does not exist (permission ended, folder removed)
        let s = c.begin(suggestedName: "x", sourceURL: URL(string: "https://a.org/x.bin"), saveAs: .init(target: gone, replaceExisting: false), cancel: {})
        try Data([4, 4]).write(to: s.destination)
        c.finish(s.id, source: nil)
        let final = try XCTUnwrap(c.completed.first)
        XCTAssertEqual(final.deletingLastPathComponent().standardizedFileURL.path, DownloadCoordinator.directory.standardizedFileURL.path, "the visible Downloads folder, not a hidden place")
        XCTAssertEqual(try Data(contentsOf: final), Data([4, 4]))
        XCTAssertEqual(c.ledger.record(s.id)?.engineMetadata["saveAsPlacement"], "failed")
        XCTAssertEqual(c.failures.first?.canRetry, false)
        XCTAssertTrue(c.failures.first?.reason.contains("Downloads folder") == true, "the person is told, not left to find it")
    }

    func testTheChosenPlaceSurvivesARelaunchInTheLedger() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p12-led-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = DownloadCoordinator(); first.store = folder
        let t = start(first, "relaunch.bin", replace: false)
        first.interrupt(t.id, resumeData: Data([1, 2]), source: URL(string: "https://a.org/relaunch.bin"))
        let second = DownloadCoordinator(); second.store = folder
        XCTAssertEqual(second.ledger.record(t.id)?.engineMetadata[DownloadCoordinator.saveAsTargetKey], t.target.path)
        XCTAssertTrue(t.staging.path.hasPrefix(DownloadCoordinator.saveAsRoot.path), "a resume writes to a place that is always authorized")
        XCTAssertEqual(second.ledger.record(t.id)?.file.destinationPath, t.staging.path)
    }

    func testASessionThatCannotBeRestoredMarksRecoveryRequiredAndKeepsTheResumeData() throws {
        let c = DownloadCoordinator()
        let source = URL(string: "https://a.org/r.bin")!
        let s = c.begin(suggestedName: "r.bin", sourceURL: source, cancel: {})
        c.interrupt(s.id, resumeData: Data([9]), source: source)
        c.sessionGate = { _, _ in "open a page of the profile it came from first" }
        c.hasHost = { true }
        var resumed = false
        c.resumerWithID = { _, _ in resumed = true }
        c.resume(s.id)
        XCTAssertFalse(resumed, "no page was borrowed")
        XCTAssertNotNil(c.interrupted[s.id], "the resume data and the Resume button are kept")
        XCTAssertEqual(c.interrupted[s.id]?.resumeData, Data([9]))
    }
}

// MARK: - Real WebKit: ownership, same-address downloads, lifecycle

@MainActor
final class StoreOwnershipWebKitTests: XCTestCase {
    private var scratch: URL!
    private var coordinator: DownloadCoordinator!
    private var delegate: WebKitDownloads!
    private var handler: Policy!

    final class Policy: NSObject, WKNavigationDelegate {
        let downloads: WebKitDownloads
        init(_ d: WebKitDownloads) { downloads = d }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if let http = navigationResponse.response as? HTTPURLResponse, (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") { return .download }
            return navigationResponse.canShowMIMEType ? .allow : .download
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { downloads.adopt(download) }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { downloads.adopt(download) }
    }

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("p12-own-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DownloadCoordinator.directoryOverride = scratch
        coordinator = DownloadCoordinator()
        delegate = WebKitDownloads(coordinator: coordinator)
        handler = Policy(delegate)
        _ = try await URLSession.shared.data(from: URL(string: base + "/_reset")!)
    }
    override func tearDown() async throws { DownloadCoordinator.directoryOverride = nil; try? FileManager.default.removeItem(at: scratch) }

    private func view(_ config: WKWebViewConfiguration = WKWebViewConfiguration()) -> WKWebView {
        let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), configuration: config); v.navigationDelegate = handler; return v
    }
    private func privateConfig() -> WKWebViewConfiguration { let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); return c }
    private func profileConfig(_ id: UUID) -> WKWebViewConfiguration { let c = WKWebViewConfiguration(); c.websiteDataStore = WKWebsiteDataStore(forIdentifier: id); return c }
    private func wait(_ what: String, timeout: TimeInterval = 25, _ ok: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !ok() { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(ok(), what)
    }
    private func attachment(_ path: String, name: String) -> URL { URL(string: base + path + (path.contains("?") ? "&" : "?") + "cd=attachment;%20filename%3D%22\(name)%22")! }

    func testEveryPrivateStoreIsItsOwnSessionAndAProfileKeepsItsName() {
        let p1 = view(privateConfig()), p2 = view(privateConfig())
        let k1 = WebKitDownloads.storeKey(of: p1), k2 = WebKitDownloads.storeKey(of: p2)
        XCTAssertNotEqual(k1, k2, "two private sessions are different identities")
        XCTAssertEqual(WebKitDownloads.storeKey(of: p1), k1, "stable for one session")
        let id = UUID()
        let a = WebKitDownloads.storeKey(of: view(profileConfig(id))), b = WebKitDownloads.storeKey(of: view(profileConfig(id))), other = WebKitDownloads.storeKey(of: view(profileConfig(UUID())))
        XCTAssertEqual(a, b); XCTAssertNotEqual(a, other)
        XCTAssertTrue(a.isPersistent); XCTAssertEqual(a.identifier, id)
    }

    func testTheSameAddressInTwoProfilesKeepsTwoSeparateOwnersAndNoLeaks() async throws {
        let idA = UUID(), idB = UUID()
        let va = view(profileConfig(idA)), vb = view(profileConfig(idB)), vp = view(privateConfig())
        let url = attachment("/slow/400000?ms=20", name: "same.bin")
        va.load(URLRequest(url: url)); vb.load(URLRequest(url: url)); vp.load(URLRequest(url: url))
        await wait("three tasks are running") { self.coordinator.ledger.records.count == 3 && self.coordinator.active.count == 3 }
        let records = coordinator.ledger.records.values
        let stores = Set(records.compactMap { delegate.store(forTask: $0.id) })
        XCTAssertEqual(stores.count, 3, "each task is tied to its own store, not to its address")
        XCTAssertEqual(Set(records.compactMap { $0.engineMetadata[DownloadStoreKey.metadataKey] }), [idA.uuidString, idB.uuidString], "only the profiles' names are kept; the private one is not")
        XCTAssertEqual(records.filter(\.isPrivate).count, 1)
        await wait("all finish", timeout: 60) { self.coordinator.completed.count == 3 }
        XCTAssertEqual(coordinator.ledger.records.count, 3)
        XCTAssertEqual(delegate.liveContextCount, 0, "nothing is left behind once the downloads are over")
    }

    func testARetryNeverBorrowsAnotherSessionsPage() async throws {
        let idA = UUID()
        let va = view(profileConfig(idA)), vp = view(privateConfig())
        va.load(URLRequest(url: attachment("/file/20000", name: "o.bin")))
        await wait("done") { self.coordinator.completed.count == 1 }
        let id = try XCTUnwrap(coordinator.ledger.records.keys.first)
        let key = try XCTUnwrap(delegate.store(forTask: id))
        let candidates: [(host: WKWebView, store: DownloadStoreKey)] = [(vp, WebKitDownloads.storeKey(of: vp)), (va, WebKitDownloads.storeKey(of: va))]
        XCTAssertTrue(DownloadHostSelection.pick(candidates, for: key) === va)
        XCTAssertNil(DownloadHostSelection.pick([candidates[0]], for: key), "with only a private page open there is no page for it")
        XCTAssertNil(delegate.store(forTask: UUID()), "an unknown task gets no store, and so no page")
    }

    func testTheStoreNameSurvivesARelaunchThroughTheLedger() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p12-relaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let c1 = DownloadCoordinator(); c1.store = folder
        let d1 = WebKitDownloads(coordinator: c1)
        let id = UUID()
        _ = await c1.admitTicket(filename: "a.bin", source: URL(string: "https://a.org/a.bin"))      // creates a record under a fresh id
        let taskID = try XCTUnwrap(c1.ledger.records.keys.first)
        let profile = DownloadStoreKey(identifier: UUID(), isPersistent: true)
        d1.remember(taskID, profile)
        _ = id
        let c2 = DownloadCoordinator(); c2.store = folder
        let d2 = WebKitDownloads(coordinator: c2)
        XCTAssertEqual(d2.store(forTask: taskID), profile, "restored from its plain name")
        // A task recorded without a store (older, or private) is not guessed at.
        let bare = c2.begin(suggestedName: "b.bin", sourceURL: URL(string: "https://a.org/b.bin"), cancel: {})
        XCTAssertNil(d2.store(forTask: bare.id))
        // The ledger holds the name of the store and nothing from the session.
        let meta = try XCTUnwrap(c2.ledger.record(taskID)?.engineMetadata)
        XCTAssertEqual(Set(meta.keys), [DownloadStoreKey.metadataKey])
    }

    func testARedirectedAttachmentIsOneCompletedTaskWithOneFinalRequest() async throws {
        let final = base + "/file/30000?cd=attachment;%20filename%3D%22redir.bin%22"
        let encoded = final.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
        let page = view(profileConfig(UUID()))
        page.load(URLRequest(url: URL(string: base + "/redirect-to?url=" + encoded)!))
        defer { _ = page }
        await wait("completes") { self.coordinator.completed.count == 1 }
        let id = try XCTUnwrap(coordinator.ledger.records.keys.first)
        XCTAssertEqual(coordinator.ledger.records.count, 1)
        XCTAssertEqual(coordinator.ledger.record(id)?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(coordinator.completed.first)).count, 30000)
        XCTAssertEqual(coordinator.completed.first?.lastPathComponent, "redir.bin")
        let log = try JSONSerialization.jsonObject(with: try await URLSession.shared.data(from: URL(string: base + "/_log")!).0) as? [[String: Any]] ?? []
        XCTAssertEqual(log.filter { ($0["path"] as? String)?.hasPrefix("/file/30000") == true }.count, 1, "the final file was requested once")
        XCTAssertEqual(delegate.liveContextCount, 0)
    }

    func testClosingThePageMidDownloadReleasesThePageAndKeepsThePrivateTaskPrivate() async throws {
        weak var weakView: WKWebView?
        do {
            let v = view(privateConfig())
            weakView = v
            v.load(URLRequest(url: attachment("/slow/1500000?ms=30", name: "gone.bin")))
            await wait("it is running") { !self.coordinator.active.isEmpty }
        }
        // The page is closed; the delegate and the coordinator must not be what keeps it alive.
        for _ in 0..<40 where weakView != nil { try await Task.sleep(for: .milliseconds(100)) }
        let id = try XCTUnwrap(coordinator.ledger.records.keys.first)
        XCTAssertNil(weakView, "the download does not retain the tab it came from")
        XCTAssertEqual(coordinator.ledger.record(id)?.isPrivate, true)
        await wait("the task reaches an end", timeout: 40) { self.coordinator.ledger.record(id)?.state.isFinal == true || self.coordinator.ledger.record(id)?.state == .failed }
        XCTAssertTrue(coordinator.failures.isEmpty, "a private download leaves no failure record")
        XCTAssertEqual(delegate.liveContextCount, 0, "no context, observer or id is left once it ended")
        XCTAssertNil(coordinator.ledger.record(id)?.engineMetadata[DownloadStoreKey.metadataKey], "a private session is never written to the ledger")
    }

    func testSaveLinkAsStagesThenPlacesAndNeverTouchesTheExistingFileMeanwhile() async throws {
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("p12-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let existing = outDir.appendingPathComponent("mine.bin"); try Data([7, 7, 7]).write(to: existing)
        let choice = SaveAsDestination.resolve(existing)
        XCTAssertTrue(choice.replaceExisting)
        delegate.saveAs(URL(string: base + "/slow/300000?ms=30")!, in: view(profileConfig(UUID())), chosen: choice)
        await wait("it is running") { !self.coordinator.active.isEmpty }
        XCTAssertEqual(try Data(contentsOf: existing), Data([7, 7, 7]), "untouched while the transfer runs")
        let id = try XCTUnwrap(coordinator.ledger.records.keys.first)
        XCTAssertTrue(try XCTUnwrap(coordinator.destination(of: id)).path.hasPrefix(DownloadCoordinator.saveAsRoot.path))
        await wait("completes", timeout: 40) { self.coordinator.completed.count == 1 }
        XCTAssertEqual(coordinator.completed.first, existing)
        XCTAssertEqual(try Data(contentsOf: existing).count, 300000, "replaced only after it finished")
        XCTAssertEqual(coordinator.ledger.records.count, 1)
    }

    func testCancellingASaveAsLeavesTheOriginalAndNoStagingBehind() async throws {
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("p12-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let existing = outDir.appendingPathComponent("mine.bin"); try Data([7]).write(to: existing)
        delegate.saveAs(URL(string: base + "/slow/3000000?ms=40")!, in: view(profileConfig(UUID())), chosen: SaveAsDestination.resolve(existing))
        await wait("it is running") { !self.coordinator.active.isEmpty }
        let id = try XCTUnwrap(coordinator.active.keys.first)
        let staging = try XCTUnwrap(coordinator.destination(of: id))
        coordinator.cancel(id)
        await wait("it stops") { self.coordinator.active.isEmpty }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(try Data(contentsOf: existing), Data([7]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(coordinator.ledger.record(id)?.state, .cancelled)
        XCTAssertEqual(delegate.liveContextCount, 0)
    }
}

// MARK: - Wiring (source scans)

final class Phase12FixScopeTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative), encoding: .utf8)
    }
    func testNothingTrashesOrReplacesAFileWhenTheSavePanelCloses() throws {
        let text = try source("Shared/Downloads/Browser/BrowserDownloadIntegration.swift")
        let resolve = try XCTUnwrap(text.range(of: "static func resolve"))
        let place = try XCTUnwrap(text.range(of: "static func place"))
        let body = String(text[resolve.lowerBound..<place.lowerBound])
        XCTAssertFalse(body.contains("trashItem")); XCTAssertFalse(body.contains("removeItem")); XCTAssertFalse(body.contains("moveItem"))
    }
    func testNoAddressKeyedStoreLookupRemains() throws {
        let engine = try source("Engines/WebKit/WebKitEngine.swift")
        XCTAssertFalse(engine.contains("storesByAddress"))
        XCTAssertTrue(engine.contains("peekReservedID"))
    }
    func testShowDownloadsGoesThroughTheOwningWindowNotABroadcast() throws {
        XCTAssertFalse(try source("Engines/WebKit/WebKitEngine.swift").contains("NotificationCenter.default.post(name: .browserShowDownloads"))
        XCTAssertFalse(try source("macOS/MacRootView.swift").contains("browserShowDownloads"))
        XCTAssertTrue(try source("Shared/TabController.swift").contains("func engineShowDownloads()"))
    }
    func testTheLedgerGetsNoSessionMaterial() throws {
        let engine = try source("Engines/WebKit/WebKitEngine.swift")
        for word in ["httpCookieStore", "allHTTPHeaderFields", "httpBody"] {
            let start = try XCTUnwrap(engine.range(of: "final class WebKitDownloads"))
            XCTAssertFalse(String(engine[start.lowerBound...]).contains("engineMetadata[\"" + word), word)
        }
    }
}
