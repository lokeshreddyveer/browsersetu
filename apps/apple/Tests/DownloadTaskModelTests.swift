import XCTest
@testable import Browser_Setu

/// The legal and illegal moves of a download task, and what each move does to its record.
final class DownloadStateMachineTests: XCTestCase {
    private func record(_ state: DownloadState = .created, resume: Bool = false) -> DownloadTaskRecord {
        var r = DownloadTaskRecord(protocolID: .webKit, profile: "default", source: DownloadSourceRef(url: URL(string: "https://a.test/f.zip")), filename: "f.zip")
        r.state = state
        r.transfer.resumeAvailable = resume
        return r
    }
    private let failure = DownloadFailureInfo(code: "x:1", reason: "It could not be downloaded.", retryable: false)

    func testTheNormalLifeOfADownload() throws {
        var r = record()
        for (event, expected) in [(DownloadEvent.queued, DownloadState.queued), (.started, .starting), (.running, .running), (.verifying, .verifying), (.completed(.verified), .completed)] {
            r = try r.applying(event)
            XCTAssertEqual(r.state, expected)
        }
        XCTAssertNotNil(r.completedAt)
        XCTAssertEqual(r.file.integrity, .verified)
        XCTAssertEqual(r.attempt, 1)
    }

    func testPauseAndResumeKeepTheTaskAndCountAnAttempt() throws {
        var r = record(.running)
        r.attempt = 1
        r = try r.applying(.pauseRequested)
        XCTAssertEqual(r.state, .pausing)
        r = try r.applying(.paused(resumeAvailable: true))
        XCTAssertEqual(r.state, .paused)
        XCTAssertTrue(r.transfer.resumeAvailable)
        let id = r.id
        r = try r.applying(.resumeRequested)
        XCTAssertEqual(r.state, .resuming)
        XCTAssertEqual(r.attempt, 2)
        r = try r.applying(.resumed)
        XCTAssertEqual(r.state, .running)
        XCTAssertEqual(r.id, id, "the identity never changes")
        XCTAssertFalse(r.transfer.resumeAvailable)
    }

    func testResumingNeedsSomethingToResumeFrom() {
        XCTAssertThrowsError(try record(.paused, resume: false).applying(.resumeRequested)) {
            XCTAssertEqual(($0 as? DownloadTransitionError)?.kind, .missingPrecondition("there is nothing to resume from"))
        }
    }

    func testFinalStatesNeverChange() {
        let events: [DownloadEvent] = [.resolveStarted, .resolved, .queued, .scheduled(at: nil), .started, .running, .pauseRequested, .paused(resumeAvailable: true), .resumeRequested,
                                       .resumed, .verifying, .completed(.verified), .failed(failure), .retryPlanned, .cancelled, .recoveryRequired(reason: "x")]
        for final in [DownloadState.completed, .cancelled] {
            for event in events { XCTAssertNil(DownloadStateMachine.next(from: final, on: event), "\(final) must not accept \(event.name)") }
        }
    }

    func testACompletedDownloadCannotBeCompletedTwice() throws {
        let done = try record(.verifying).applying(.completed(.unknown))
        XCTAssertThrowsError(try done.applying(.completed(.unknown)), "a duplicate completion event is refused, so it cannot fire completion twice")
    }

    func testACancelledDownloadDoesNotRestartByItself() {
        for event in [DownloadEvent.queued, .started, .running, .resumeRequested, .resumed] {
            XCTAssertNil(DownloadStateMachine.next(from: .cancelled, on: event))
        }
    }

    func testEveryStateIsCoveredAndEveryLegalMoveEndsInAKnownState() {
        let events: [DownloadEvent] = [.resolveStarted, .resolved, .queued, .scheduled(at: nil), .started, .running, .pauseRequested, .paused(resumeAvailable: true), .resumeRequested,
                                       .resumed, .verifying, .completed(.unknown), .failed(failure), .retryPlanned, .cancelled, .recoveryRequired(reason: "x")]
        var legal = 0
        for state in DownloadState.allCases { for event in events { if let next = DownloadStateMachine.next(from: state, on: event) { legal += 1; XCTAssertTrue(DownloadState.allCases.contains(next)) } } }
        XCTAssertGreaterThan(legal, 40)
    }

    /// The whole table, written out: any change to the rules has to change this on purpose.
    func testTheLegalMovesAreExactlyTheDocumentedOnes() {
        let expected: [DownloadState: Set<String>] = [
            .created: ["resolveStarted", "queued", "scheduled", "cancelled"],
            .resolving: ["resolved", "scheduled", "retryPlanned", "failed", "cancelled", "recoveryRequired"],
            .queued: ["scheduled", "started", "failed", "cancelled"],
            .scheduled: ["queued", "scheduled", "failed", "cancelled"],
            .starting: ["running", "paused", "retryPlanned", "failed", "cancelled", "recoveryRequired"],
            .running: ["pauseRequested", "paused", "verifying", "retryPlanned", "failed", "cancelled", "recoveryRequired"],
            .pausing: ["paused", "verifying", "failed", "cancelled", "recoveryRequired"],
            .paused: ["resumeRequested", "failed", "cancelled"],
            .resuming: ["resumed", "paused", "verifying", "retryPlanned", "failed", "cancelled", "recoveryRequired"],
            .verifying: ["completed", "failed", "cancelled", "recoveryRequired"],
            .retrying: ["queued", "failed", "cancelled", "recoveryRequired"],       // Phase 5: a retry planned when the app ended is shown, not left invisible
            .completed: [],
            .failed: ["queued"],
            .cancelled: [],
            .recoveryRequired: ["queued", "resumeRequested", "verifying", "failed", "cancelled"]
        ]
        let events: [DownloadEvent] = [.resolveStarted, .resolved, .queued, .scheduled(at: nil), .started, .running, .pauseRequested, .paused(resumeAvailable: true), .resumeRequested,
                                       .resumed, .verifying, .completed(.unknown), .failed(failure), .retryPlanned, .cancelled, .recoveryRequired(reason: "x")]
        for state in DownloadState.allCases {
            let actual = Set(events.filter { DownloadStateMachine.canApply($0, to: state) }.map(\.name))
            XCTAssertEqual(actual, expected[state], "moves out of \(state)")
        }
    }

    func testADownloadThatFinishesWhileAPauseIsPendingStillCompletes() throws {
        var r = record(.running); r.attempt = 1
        r = try r.applying(.pauseRequested)
        r = try r.applying(.verifying)
        r = try r.applying(.completed(.verified))
        XCTAssertEqual(r.state, .completed, "the last byte arrived as Pause was pressed: it is done, not lost")
    }

    func testRapidPauseResumeCancelIsDeterministic() throws {
        var r = record(.running); r.attempt = 1
        r = try r.applying(.pauseRequested)
        XCTAssertThrowsError(try r.applying(.resumeRequested), "a resume asked for before the pause has been answered is refused, not half-applied")
        XCTAssertEqual(r.state, .pausing)
        r = try r.applying(.cancelled)
        XCTAssertEqual(r.state, .cancelled)
        XCTAssertFalse(r.transfer.resumeAvailable)
    }

    func testAReportFromAnEarlierAttemptIsIgnored() throws {
        var r = record(.running); r.attempt = 3
        XCTAssertThrowsError(try r.applying(.verifying, attempt: 2)) {
            XCTAssertEqual(($0 as? DownloadTransitionError)?.kind, .staleGeneration(expected: 3, got: 2))
        }
        XCTAssertNoThrow(try r.applying(.verifying, attempt: 3))
    }

    func testRetryCountsAndAFailedTaskCanBeTriedAgain() throws {
        var r = record(.running)
        r = try r.applying(.retryPlanned)
        XCTAssertEqual(r.retryCount, 1)
        r = try r.applying(.queued)
        XCTAssertEqual(r.state, .queued)
        r = record(.running)
        r = try r.applying(.failed(failure))
        XCTAssertEqual(r.failure, failure)
        r = try r.applying(.queued)
        XCTAssertNil(r.failure, "trying again clears the old failure")
    }

    func testAFoundLiveTaskNeedsADecisionAndNeverRestartsByItself() throws {
        let live = record(.running)
        let found = try live.applying(.recoveryRequired(reason: "Browser Setu was closed before this finished."))
        XCTAssertEqual(found.state, .recoveryRequired)
        XCTAssertTrue(found.failure?.retryable == true)
        XCTAssertNil(DownloadStateMachine.next(from: .recoveryRequired, on: .started))
        XCTAssertNil(DownloadStateMachine.next(from: .recoveryRequired, on: .running))
        XCTAssertNil(DownloadStateMachine.next(from: .queued, on: .recoveryRequired(reason: "x")), "a task holding nothing is not found live")
    }

    func testNoAmbiguousCombinations() {
        // One state value, so "running and paused" cannot be written down.
        XCTAssertEqual(Set(DownloadState.allCases.map(\.rawValue)).count, DownloadState.allCases.count)
        XCTAssertTrue(DownloadState.running.holdsResources && !DownloadState.paused.holdsResources && !DownloadState.queued.holdsResources)
    }
}

final class DownloadTaskModelTests: XCTestCase {
    func testASourceKeepsNoPasswordOrFragment() {
        let ref = DownloadSourceRef(url: URL(string: "https://user:secret@files.test/a.zip?x=1#frag"))
        XCTAssertEqual(ref.url, "https://files.test/a.zip?x=1")
        XCTAssertEqual(ref.host, "files.test")
        XCTAssertFalse((ref.url ?? "").contains("secret"))
    }

    func testEngineMetadataIsBoundedAndPlain() {
        var big: [String: String] = [:]
        for i in 0..<40 { big["k\(i)"] = "v" }
        XCTAssertEqual(DownloadEngineMetadata.validated(big).count, DownloadEngineMetadata.maxEntries)
        XCTAssertTrue(DownloadEngineMetadata.validated(["bad key!": "x"]).isEmpty)
        XCTAssertTrue(DownloadEngineMetadata.validated(["long": String(repeating: "a", count: 300)]).isEmpty)
        XCTAssertEqual(DownloadEngineMetadata.validated(["segments": "6"]), ["segments": "6"])
    }

    func testPathsOutsideAnAuthorisedFolderAreNotBelieved() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dl-root-\(UUID().uuidString)")
        XCTAssertTrue(DownloadPathPolicy.isAuthorized(root.appendingPathComponent("a/b.zip").path, roots: [root]))
        XCTAssertFalse(DownloadPathPolicy.isAuthorized(root.appendingPathComponent("../elsewhere.zip").path, roots: [root]))
        XCTAssertFalse(DownloadPathPolicy.isAuthorized("/etc/passwd", roots: [root]))
        XCTAssertFalse(DownloadPathPolicy.isAuthorized("relative/path", roots: [root]))
        XCTAssertFalse(DownloadPathPolicy.isAuthorized(nil, roots: [root]))
        XCTAssertFalse(DownloadPathPolicy.isAuthorized(root.path + "-sibling/x", roots: [root]), "a folder that only shares a prefix is not inside")
    }

    func testProtocolIdsAreValidatedAndEnginesDeclareCapabilities() {
        XCTAssertTrue(DownloadProtocolID.webKit.isValid)
        XCTAssertFalse(DownloadProtocolID(rawValue: "Bad Id").isValid)
        XCTAssertFalse(DownloadProtocolID(rawValue: "").isValid)
        let engines = MainActor.assumeIsolated { DownloadEngineRegistry() }
        MainActor.assumeIsolated {
            XCTAssertTrue(engines.can(.pause, .webKit))
            XCTAssertFalse(engines.can(.pause, .httpPieces), "pieces cannot be paused, so no pause control is offered")
            XCTAssertFalse(engines.can(.pause, "unknown-engine"))
        }
    }
}
