import XCTest
@testable import Browser_Setu

// MARK: Pure rules

final class FinalizationGateTests: XCTestCase {
    func testWhoeverArrivesFirstWins() {
        let early = FinalizationGate()
        XCTAssertTrue(early.cancel()); XCTAssertFalse(early.claim(), "cancelled first: nothing may be put in place")
        let late = FinalizationGate()
        XCTAssertTrue(late.claim()); XCTAssertFalse(late.cancel(), "claimed first: too late to cancel")
    }

    func testRepeatingEitherIsHarmless() {
        let a = FinalizationGate(); _ = a.cancel()
        XCTAssertTrue(a.cancel()); XCTAssertEqual(a.phase, .cancelled)
        let b = FinalizationGate(); _ = b.claim()
        XCTAssertTrue(b.claim()); XCTAssertFalse(b.cancel()); XCTAssertEqual(b.phase, .finalising)
    }

    func testPausingIsOnlyPossibleBeforeTheFileIsBeingPutInPlace() {
        let g = FinalizationGate()
        XCTAssertTrue(g.allowsPause)
        _ = g.claim()
        XCTAssertFalse(g.allowsPause)
    }

    func testARaceHasExactlyOneWinnerEveryTime() {
        for _ in 0..<2000 {
            let g = FinalizationGate()
            var claimed = false, cancelled = false
            let group = DispatchGroup()
            group.enter(); DispatchQueue.global().async { claimed = g.claim(); group.leave() }
            group.enter(); DispatchQueue.global().async { cancelled = g.cancel(); group.leave() }
            group.wait()
            XCTAssertNotEqual(claimed, cancelled, "one of them won, never both and never neither")
        }
    }
}

final class DownloadRecoveryRulesTests: XCTestCase {
    private func record(mode: String? = nil, total: Int64? = 1000, started: Date = Date(timeIntervalSince1970: 1_000_000)) -> DownloadTaskRecord {
        var r = DownloadTaskRecord(protocolID: .http, profile: "p", source: DownloadSourceRef(url: URL(string: "https://example.com/f.bin")), filename: "f.bin", now: started)
        r.startedAt = started
        r.transfer.totalBytes = total
        if let mode { r.engineMetadata["mode"] = mode }
        return r
    }
    private let after = Date(timeIntervalSince1970: 1_000_100)

    func testAFileOfTheRightSizeWrittenSinceTheTaskBeganIsComplete() {
        let facts = DownloadRecoveryFacts(destinationSize: 1000, destinationModified: after, hasSource: true)
        XCTAssertEqual(DownloadRecovery.assess(record(), facts: facts), .completeOnDisk)
    }

    func testAFileThatWasThereBeforeTheTaskStartedIsNeverClaimed() {
        let before = Date(timeIntervalSince1970: 999_000)
        let facts = DownloadRecoveryFacts(destinationSize: 1000, destinationModified: before, hasSource: true)
        XCTAssertNotEqual(DownloadRecovery.assess(record(), facts: facts), .completeOnDisk, "a user's own older file with the same name and size")
    }

    func testAFileStillBeingAssembledIsNotComplete() {
        let facts = DownloadRecoveryFacts(destinationSize: 1000, destinationModified: after, workingSize: 1000, hasSource: true)
        XCTAssertNotEqual(DownloadRecovery.assess(record(mode: "multipart"), facts: facts), .completeOnDisk)
    }

    func testTheWrongSizeIsNotComplete() {
        let facts = DownloadRecoveryFacts(destinationSize: 999, destinationModified: after, hasSource: true)
        XCTAssertNotEqual(DownloadRecovery.assess(record(), facts: facts), .completeOnDisk)
    }

    func testPiecesCountOnlyWhileTheirFileIsThereAtItsFullSize() {
        let intact = DownloadRecoveryFacts(workingSize: 1000, donePieces: 3, hasSource: true)
        XCTAssertEqual(DownloadRecovery.assess(record(mode: "multipart"), facts: intact), .recover(.resumable))
        let short = DownloadRecoveryFacts(workingSize: 400, donePieces: 3, hasSource: true)
        guard case .recover(.restartRequired) = DownloadRecovery.assess(record(mode: "multipart"), facts: short) else { return XCTFail("a short file is no checkpoint") }
        let missing = DownloadRecoveryFacts(workingSize: nil, donePieces: 3, hasSource: true)
        guard case .recover(.restartRequired) = DownloadRecovery.assess(record(mode: "multipart"), facts: missing) else { return XCTFail("no file, no checkpoint") }
        let none = DownloadRecoveryFacts(workingSize: 1000, donePieces: 0, hasSource: true)
        guard case .recover(.restartRequired) = DownloadRecovery.assess(record(mode: "multipart"), facts: none) else { return XCTFail("a file with no finished piece has nothing to keep") }
    }

    func testASingleTransferResumesOnlyWithResumeData() {
        XCTAssertEqual(DownloadRecovery.assess(record(mode: "single"), facts: DownloadRecoveryFacts(hasResumeData: true, hasSource: true)), .recover(.resumable))
        guard case .recover(.restartRequired) = DownloadRecovery.assess(record(mode: "single"), facts: DownloadRecoveryFacts(hasSource: true)) else { return XCTFail() }
    }

    func testASignedLinkWithNothingKeptNeedsAFreshOne() {
        var r = record(mode: "single")
        r.source = DownloadSourceRef(url: URL(string: "https://example.com/f.bin?X-Amz-Signature=abc&X-Amz-Expires=60")!)
        guard case .recover(.needsNewLink) = DownloadRecovery.assess(r, facts: DownloadRecoveryFacts(hasSource: true, sourceLooksSigned: true)) else { return XCTFail() }
    }

    func testNothingKeptAndNoAddressCannotBeRecovered() {
        guard case .recover(.cannotRecover) = DownloadRecovery.assess(record(mode: "single"), facts: DownloadRecoveryFacts()) else { return XCTFail() }
    }

    func testTheFourKindsOfPromiseAreWordedAndOfferedDifferently() {
        XCTAssertEqual(DownloadRecoveryClass.resumable.actionTitle, "Resume")
        XCTAssertEqual(DownloadRecoveryClass.restartRequired("x").actionTitle, "Start Over")
        XCTAssertNil(DownloadRecoveryClass.needsNewLink("x").actionTitle)
        XCTAssertNil(DownloadRecoveryClass.cannotRecover("x").actionTitle)
        XCTAssertTrue(DownloadRecoveryClass.resumable.summary.contains("if the website still allows it"), "never a promise of zero loss")
    }
}

final class Phase4PolicyTests: XCTestCase {
    private var saved = false
    override func setUp() { saved = HTTPRequestPolicy.untrustedRequestsEnabled }
    override func tearDown() { HTTPRequestPolicy.untrustedRequestsEnabled = saved }

    func testRequestsFromScriptsAndExtensionsAreRefusedByDefault() async {
        HTTPRequestPolicy.untrustedRequestsEnabled = false
        for origin in [DownloadRequestOrigin.automation, .browserExtension] {
            let policy = HTTPRequestPolicy(origin: origin)
            XCTAssertThrowsError(try policy.requireAllowedOrigin()) { XCTAssertEqual($0 as? HTTPRequestPolicy.Refusal, .untrustedRequestsDisabled) }
            do { try await policy.checkResolving(URL(string: "https://example.com/f")!); XCTFail("\(origin) must be refused") }
            catch { XCTAssertEqual(error as? HTTPRequestPolicy.Refusal, .untrustedRequestsDisabled) }
        }
        XCTAssertNoThrow(try HTTPRequestPolicy(origin: .user).requireAllowedOrigin(), "the person's own requests are not affected")
    }

    func testTheRefusalHappensBeforeAnyNameIsLookedUp() async {
        HTTPRequestPolicy.untrustedRequestsEnabled = false
        let resolver = CountingResolver()
        let savedResolver = HTTPRequestPolicy.resolver
        HTTPRequestPolicy.resolver = resolver
        defer { HTTPRequestPolicy.resolver = savedResolver }
        _ = try? await HTTPRequestPolicy(origin: .automation).checkResolving(URL(string: "https://rebind.example/f")!)
        XCTAssertEqual(resolver.calls, 0, "no lookup, no connection: nothing happens for a request that is not allowed")
    }

    func testTurningItOnLeavesTheOtherLayersInPlace() async {
        HTTPRequestPolicy.untrustedRequestsEnabled = true
        XCTAssertThrowsError(try HTTPRequestPolicy(origin: .automation).check(URL(string: "http://127.0.0.1/x")!))
        XCTAssertNoThrow(try HTTPRequestPolicy(origin: .automation).requireAllowedOrigin())
    }

    func testConnectionCountIsConfigurableUpToTheFixedCeiling() {
        let big: Int64 = 512 << 20
        XCTAssertEqual(MultipartPlanner.connections(total: big, configured: 4), 4)
        XCTAssertEqual(MultipartPlanner.connections(total: big, configured: 6), 6)
        XCTAssertEqual(MultipartPlanner.connections(total: big, configured: 8), 8)
        XCTAssertEqual(MultipartPlanner.connections(total: big, configured: 20), 8, "never past the ceiling")
        XCTAssertEqual(MultipartPlanner.connections(total: big, configured: 0), 1)
    }

    func testASlowFirstAnswerOnASmallFilePrefersOneTransfer() {
        XCTAssertTrue(MultipartPlanner.isCounterproductive(probeSeconds: 0.4, total: 24 << 20))
        XCTAssertFalse(MultipartPlanner.isCounterproductive(probeSeconds: 0.05, total: 24 << 20), "a fast answer keeps pieces")
        XCTAssertFalse(MultipartPlanner.isCounterproductive(probeSeconds: 0.4, total: 400 << 20), "a large file keeps pieces whatever the delay")
    }
}

private final class CountingResolver: HostAddressResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func addresses(for host: String) async -> [String]? { lock.lock(); count += 1; lock.unlock(); return ["93.184.216.34"] }
}
