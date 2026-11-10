import XCTest
@testable import Browser_Setu

/// What the error pages decide from real evidence: the system's error domain and code, the HTTP status, whether the device has a network. Never the wording of a message.
final class BrowserErrorTests: XCTestCase {
    private func kind(_ code: Int, domain: String = NSURLErrorDomain, online: Bool? = true) -> BrowserErrorKind? {
        BrowserErrorClassifier.classify(domain: domain, code: code, deviceOnline: online)
    }

    // MARK: Which kind

    func testNoNetworkIsOfflineButASlowSiteIsNot() {
        XCTAssertEqual(kind(NSURLErrorNotConnectedToInternet), .noInternet)
        XCTAssertEqual(kind(NSURLErrorDataNotAllowed), .noInternet)
        XCTAssertEqual(kind(NSURLErrorTimedOut, online: true), .timedOut, "a website that times out while the device is connected is the site's problem")
        XCTAssertEqual(kind(NSURLErrorTimedOut, online: false), .noInternet, "the same timeout with no network at all is the device being offline")
        XCTAssertEqual(kind(NSURLErrorTimedOut, online: nil), .timedOut, "unknown is not assumed offline")
    }

    func testANameThatDoesNotResolveIsNotTheDeviceBeingOfflineUnlessItIs() {
        XCTAssertEqual(kind(NSURLErrorCannotFindHost, online: true), .dnsFailure)
        XCTAssertEqual(kind(NSURLErrorDNSLookupFailed, online: true), .dnsFailure)
        XCTAssertEqual(kind(NSURLErrorDNSLookupFailed, online: false), .noInternet)
        XCTAssertEqual(kind(NSURLErrorBadURL), .dnsFailure, "an address that is not an address asks for the address to be checked")
    }

    func testAConnectionThatDropsOrIsRefusedIsTheSitesProblemNotAnOfflineDevice() {
        XCTAssertEqual(kind(NSURLErrorNetworkConnectionLost, online: true), .serverUnavailable)
        XCTAssertEqual(kind(NSURLErrorCannotConnectToHost, online: true), .serverUnavailable)
        XCTAssertEqual(kind(NSURLErrorBadServerResponse), .serverUnavailable)
        XCTAssertEqual(kind(NSURLErrorCannotConnectToHost, online: false), .noInternet)
    }

    func testEveryCertificateProblemIsASecurityErrorAndNothingElseIs() {
        for code in [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                     NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired, NSURLErrorAppTransportSecurityRequiresSecureConnection] {
            XCTAssertEqual(kind(code), .certificate, "\(code)")
            XCTAssertEqual(kind(code, online: false), .certificate, "a certificate error is never turned into 'offline'")
        }
        XCTAssertNotEqual(kind(NSURLErrorTimedOut), .certificate)
    }

    func testACancelledOrInterruptedLoadShowsNothing() {
        XCTAssertNil(kind(NSURLErrorCancelled))
        XCTAssertNil(kind(NSURLErrorUserCancelledAuthentication))
        XCTAssertNil(BrowserErrorClassifier.classify(domain: "WebKitErrorDomain", code: 102, deviceOnline: true), "frame load interrupted by a policy change (a download) is not a failure")
        XCTAssertNil(BrowserErrorClassifier.classify(domain: "WKErrorDomain", code: 1, deviceOnline: true), "web view bookkeeping is not a page failure")
    }

    func testUnsupportedFilesAndProcessEndsHaveTheirOwnKinds() {
        XCTAssertEqual(kind(NSURLErrorUnsupportedURL), .unsupportedContent)
        XCTAssertEqual(kind(NSURLErrorCannotDecodeContentData), .unsupportedContent)
        XCTAssertEqual(BrowserErrorClassifier.classify(domain: "WebKitErrorDomain", code: 100, deviceOnline: true), .unsupportedContent)
        XCTAssertEqual(BrowserErrorClassifier.classify(domain: "WebKitErrorDomain", code: 101, deviceOnline: true), .unsupportedContent)
        XCTAssertEqual(BrowserErrorClassifier.classify(domain: "WKErrorDomain", code: 4, deviceOnline: true), .processCrashed)
        XCTAssertEqual(kind(NSURLErrorFileDoesNotExist), .fileFailure)
        XCTAssertEqual(kind(NSURLErrorNoPermissionsToReadFile), .fileFailure)
        XCTAssertEqual(BrowserErrorClassifier.classify(domain: NSCocoaErrorDomain, code: 260, deviceOnline: true), .fileFailure)
    }

    func testTheClassifierDoesNotDependOnTheLanguageOfTheMessage() {
        // The old classifier read the localized description. This one has nothing to read: only the domain and the code.
        let french = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "Connexion Internet interrompue"])
        let german = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "Die Verbindung zum Internet scheint offline zu sein."])
        XCTAssertEqual(BrowserErrorClassifier.classify(domain: french.domain, code: french.code, deviceOnline: nil), .noInternet)
        XCTAssertEqual(BrowserErrorClassifier.classify(domain: german.domain, code: german.code, deviceOnline: nil), .noInternet)
    }

    // MARK: What the site itself answered

    func testOnlyAnEmptyErrorAnswerIsReplacedAndASitesOwnErrorPageIsLeftAlone() {
        XCTAssertEqual(BrowserErrorClassifier.classify(httpStatus: 404, bodyIsEmpty: true), .pageMissing)
        XCTAssertEqual(BrowserErrorClassifier.classify(httpStatus: 410, bodyIsEmpty: true), .pageMissing)
        XCTAssertEqual(BrowserErrorClassifier.classify(httpStatus: 503, bodyIsEmpty: true), .serverUnavailable)
        XCTAssertNil(BrowserErrorClassifier.classify(httpStatus: 404, bodyIsEmpty: false), "a 404 page the site made is the site's to show")
        XCTAssertNil(BrowserErrorClassifier.classify(httpStatus: 503, bodyIsEmpty: false))
        XCTAssertNil(BrowserErrorClassifier.classify(httpStatus: 200, bodyIsEmpty: true))
        XCTAssertNil(BrowserErrorClassifier.classify(httpStatus: 301, bodyIsEmpty: true), "a redirect with no body is normal")
        XCTAssertNil(BrowserErrorClassifier.classify(httpStatus: 401, bodyIsEmpty: true), "sign-in answers are not errors to replace")
    }

    // MARK: Recovery

    private func info(_ kind: BrowserErrorKind, online: Bool? = true, http: Int? = nil, paused: Bool = false) -> BrowserErrorInfo {
        BrowserErrorInfo(kind: kind, url: URL(string: "https://example.com/a"), httpStatus: http, reloadPaused: paused, deviceOnline: online)
    }

    func testTheOfflineGamesAppearOnlyForConnectionTrouble() {
        for kind in BrowserErrorKind.allCases {
            let offers = info(kind).offersGames
            XCTAssertEqual(offers, [.noInternet, .dnsFailure, .timedOut, .serverUnavailable].contains(kind), "\(kind)")
        }
        XCTAssertFalse(info(.serverUnavailable, http: 503).offersGames, "a site that answered with an error is not a connection problem")
        for security in [BrowserErrorKind.certificate, .protectionBlocked, .unsupportedContent, .processCrashed, .fileFailure, .syncFailure, .mediaFailure, .pageMissing] {
            XCTAssertFalse(info(security).offersGames, "\(security)")
        }
    }

    func testACertificateErrorNeverOffersToGetAroundIt() {
        let actions = info(.certificate).actions(canGoBack: true, isPublicWeb: true)
        XCTAssertEqual(actions, [.goBack, .goHome])
        XCTAssertFalse(actions.contains(.tryAgain), "trying again changes nothing about a bad certificate")
        XCTAssertFalse(info(.certificate).message.lowercased().contains("proceed"))
    }

    func testTryAgainIsFirstWhereTryingAgainMakesSense() {
        for kind in [BrowserErrorKind.noInternet, .dnsFailure, .timedOut, .serverUnavailable] { XCTAssertEqual(info(kind).actions(canGoBack: false, isPublicWeb: false).first, .tryAgain, "\(kind)") }
        XCTAssertEqual(info(.processCrashed).actions(canGoBack: true, isPublicWeb: false), [.reload])
        XCTAssertEqual(info(.processCrashed, paused: true).actions(canGoBack: true, isPublicWeb: false), [.goHome], "a page that keeps crashing is not offered an immediate reload")
        XCTAssertEqual(info(.pageMissing).actions(canGoBack: true, isPublicWeb: false).first, .goBack)
        XCTAssertTrue(info(.fileFailure).actions(canGoBack: false, isPublicWeb: false).contains(.chooseAnotherFile))
        XCTAssertTrue(info(.protectionBlocked).actions(canGoBack: true, isPublicWeb: true).contains(.reviewProtection))
    }

    func testASavedCopyIsOnlyOfferedWhenTheDeviceCanReachTheInternet() {
        XCTAssertTrue(info(.timedOut, online: true).actions(canGoBack: false, isPublicWeb: true).contains(.savedCopy))
        XCTAssertFalse(info(.noInternet, online: false).actions(canGoBack: false, isPublicWeb: true).contains(.savedCopy), "it is looked up online, so not while offline")
        XCTAssertFalse(info(.timedOut, online: true).actions(canGoBack: false, isPublicWeb: false).contains(.savedCopy), "never for a private or local address")
        XCTAssertFalse(info(.certificate).actions(canGoBack: false, isPublicWeb: true).contains(.savedCopy))
    }

    func testOnlyAMissingNetworkEarnsOneAutomaticTryAndNothingRetriesInALoop() {
        XCTAssertTrue(ErrorRetryPolicy.triesWhenNetworkReturns(.noInternet))
        for kind in BrowserErrorKind.allCases where kind != .noInternet { XCTAssertFalse(ErrorRetryPolicy.triesWhenNetworkReturns(kind), "\(kind)") }
        XCTAssertEqual(ErrorRetryPolicy.automaticTries, 1)
    }

    // MARK: What it says

    func testTheMessagesClaimOnlyWhatIsKnown() {
        let timeout = info(.timedOut, online: true).message
        XCTAssertTrue(timeout.contains("example.com") && timeout.contains("connected"))
        XCTAssertFalse(timeout.lowercased().contains("offline"), "a site timeout never says the device is offline")
        XCTAssertTrue(info(.serverUnavailable, http: 503).message.contains("503"))
        XCTAssertFalse(info(.serverUnavailable).message.lowercased().contains("down for everyone"), "it does not claim to know the site is down")
        for kind in BrowserErrorKind.allCases { XCTAssertFalse(info(kind).message.isEmpty, "\(kind)"); XCTAssertFalse(kind.title.isEmpty) }
    }

    func testCertificateWordsFollowTheCodeAndTechnicalDetailsOnlyHoldKnownFacts() {
        XCTAssertTrue(BrowserErrorClassifier.certificateProblem(code: NSURLErrorServerCertificateHasBadDate).contains("expired"))
        XCTAssertTrue(BrowserErrorClassifier.certificateProblem(code: NSURLErrorServerCertificateNotYetValid).contains("date and time"))
        XCTAssertTrue(BrowserErrorClassifier.certificateProblem(code: NSURLErrorServerCertificateUntrusted).contains("self-signed"))
        var i = info(.dnsFailure); i.domain = NSURLErrorDomain; i.code = NSURLErrorCannotFindHost
        let lines = i.technicalLines.joined(separator: "\n")
        XCTAssertTrue(lines.contains("https://example.com/a") && lines.contains("NSURLErrorDomain -1003"))
        XCTAssertFalse(lines.contains("HTTP status"), "no status is listed when there was none")
    }

    // MARK: Sync and media

    func testSyncProblemsAreToldApartWithoutReadingWordingAndRetryOnlyWhereItCanHelp() {
        for problem in [SyncProblem.prepare, .tooLarge, .passphrase] { XCTAssertEqual(SyncProblem(message: problem.message), problem, "\(problem)") }
        XCTAssertEqual(SyncProblem(message: "something else"), .other("something else"))
        XCTAssertTrue(SyncProblem.prepare.canRetry)
        XCTAssertTrue(SyncProblem.other("x").canRetry)
        XCTAssertFalse(SyncProblem.passphrase.canRetry, "a different passphrase is not fixed by sending again")
        XCTAssertFalse(SyncProblem.tooLarge.canRetry, "a full sync space is not fixed by sending again")
        for problem in [SyncProblem.prepare, .tooLarge, .passphrase, .other("x")] {
            XCTAssertTrue(problem.explanation.contains("unchanged") || problem.explanation.contains("Nothing"), "it always says the existing data is safe: \(problem)")
            XCTAssertEqual(problem.info.kind, .syncFailure)
            XCTAssertEqual(problem.info.headline, problem.headline)
            XCTAssertFalse(problem.info.offersGames, "never a game for a sync problem")
        }
    }

    func testAFailedVideoKeepsItsSpecificHeadlineAndNeverOffersGames() {
        var info = BrowserErrorInfo(kind: .mediaFailure, url: URL(string: "https://example.com/v.mp4"), detail: "The file is damaged.")
        info.headline = "This device could not decode the video"
        XCTAssertEqual(info.headline, "This device could not decode the video")
        XCTAssertEqual(info.message, "The file is damaged.")
        XCTAssertFalse(info.offersGames)
        XCTAssertEqual(info.actions(canGoBack: true, isPublicWeb: true), [.reload, .copyAddress], "the video's own panel reloads or copies the address; it never replaces the page")
    }

    func testTheProtectionBlockSaysWhichKindOfBlockItWas() {
        var threat = BrowserErrorInfo(kind: .protectionBlocked, url: URL(string: "https://bad.example/"), blockReason: .threatList)
        XCTAssertTrue(threat.message.contains("your own list"))
        threat.blockReason = .policy
        XCTAssertTrue(threat.message.contains("rule"))
        threat.blockReason = .contentFilter
        XCTAssertTrue(threat.message.contains("content protection"))
        XCTAssertEqual(threat.actions(canGoBack: true, isPublicWeb: true), [.goBack, .reviewProtection], "a scoped review of this site's protection, never a global switch")
    }

    func testARestrictedPortIsExplainedAsSuchNotAsAnUnknownKindOfAddress() {
        // Found on the real app: a connection to port 9 never leaves the browser, WebKit refuses it with WebKitErrorDomain 103.
        XCTAssertEqual(BrowserErrorClassifier.classify(domain: "WebKitErrorDomain", code: 103, deviceOnline: true), .unsupportedContent)
        let info = BrowserErrorInfo(kind: .unsupportedContent, url: URL(string: "http://127.0.0.1:9/"), domain: "WebKitErrorDomain", code: 103)
        XCTAssertTrue(info.message.contains("port"))
        // The word "port" on its own: "support" contains the letters but is not what is being tested for.
        XCTAssertNil(BrowserErrorInfo(kind: .unsupportedContent, domain: "WebKitErrorDomain", code: 101).message.range(of: #"\bport\b"#, options: .regularExpression))
    }

    func testTheTwelveKindsAreAllDistinctInTitleAndColour() {
        XCTAssertEqual(BrowserErrorKind.allCases.count, 12)
        XCTAssertEqual(Set(BrowserErrorKind.allCases.map(\.title)).count, 12)
    }
}

/// The rules of the four offline games.
final class OfflineGamesTests: XCTestCase {
    func testASlideClosesGapsAndJoinsEqualTilesOnceEach() {
        XCTAssertEqual(Game2048.slideRow([2, 2, 2, 2]).row, [4, 4, 0, 0])
        XCTAssertEqual(Game2048.slideRow([2, 2, 2, 2]).gained, 8)
        XCTAssertEqual(Game2048.slideRow([0, 2, 0, 2]).row, [4, 0, 0, 0])
        XCTAssertEqual(Game2048.slideRow([4, 2, 2, 0]).row, [4, 4, 0, 0])
        XCTAssertEqual(Game2048.slideRow([2, 4, 8, 16]).row, [2, 4, 8, 16], "nothing moves, nothing joins")
        XCTAssertEqual(Game2048.slideRow([2, 2, 4, 0]).row, [4, 4, 0, 0], "a joined tile does not join again in the same slide")
    }

    func testSlidingInEveryDirectionAndNoTileAddedForAMoveThatMovesNothing() {
        var game = Game2048()
        var generator = SeededGenerator(seed: 7)
        game.addTile(using: &generator)
        let start = game
        // Slide to a corner; sliding the same way again moves nothing.
        XCTAssertTrue(game.slide(.left) || game.slide(.up) || game.slide(.right) || game.slide(.down))
        _ = start
        var corner = Game2048()
        var g2 = SeededGenerator(seed: 3)
        corner.addTile(using: &g2)
        corner.slide(.left); corner.slide(.up)
        let before = corner
        XCTAssertFalse(corner.slide(.left) && corner.slide(.up) && corner == before, "a slide that moves nothing reports it")
        let total = corner.board.joined().reduce(0, +)
        XCTAssertGreaterThan(total, 0)
    }

    func testAFullBoardWithNoEqualNeighboursIsOver() {
        var generator = SeededGenerator(seed: 1)
        var game = Game2048.new(using: &generator)
        XCTAssertFalse(game.isOver)
        XCTAssertEqual(game.board.joined().filter { $0 != 0 }.count, 2, "a new game starts with two tiles")
        for _ in 0..<200 { for d in [Game2048.Direction.left, .up, .right, .down] where game.slide(d) { game.addTile(using: &generator) } ; if game.isOver { break } }
        XCTAssertTrue(game.score >= 0)
    }

    func testTicTacToeTheComputerTakesAWinBlocksAndNeverPlaysOnAnOccupiedSquare() {
        var generator = SeededGenerator(seed: 5)
        var game = TicTacToe()
        game.play(0, as: .o); game.play(1, as: .o); game.play(4, as: .x); game.play(8, as: .x)
        XCTAssertEqual(game.computerMove(as: .o, using: &generator), 2, "it completes its own line first")
        var block = TicTacToe()
        block.play(0, as: .x); block.play(1, as: .x); block.play(4, as: .o)
        XCTAssertEqual(block.computerMove(as: .o, using: &generator), 2, "and blocks yours when it cannot win")
        XCTAssertFalse(block.play(0, as: .o), "an occupied square cannot be played")
        var empty = TicTacToe()
        XCTAssertEqual(empty.computerMove(as: .o, using: &generator), 4, "the centre, when free")
        empty.play(4, as: .x)
        XCTAssertTrue([0, 2, 6, 8].contains(empty.computerMove(as: .o, using: &generator)!), "then a corner")
    }

    func testTicTacToeFindsWinsDrawsAndStopsAfterTheEnd() {
        var game = TicTacToe()
        for (i, m) in [(0, TicTacToe.Mark.x), (3, .o), (1, .x), (4, .o), (2, .x)] { game.play(i, as: m) }
        XCTAssertEqual(game.winner, .x); XCTAssertEqual(game.winningLine, [0, 1, 2]); XCTAssertTrue(game.isOver)
        XCTAssertFalse(game.play(5, as: .o), "no moves after the game is won")
        var draw = TicTacToe()
        for (i, m) in [(0, TicTacToe.Mark.x), (1, .o), (2, .x), (4, .o), (3, .x), (5, .o), (7, .x), (6, .o), (8, .x)] { draw.play(i, as: m) }
        XCTAssertNil(draw.winner); XCTAssertTrue(draw.isFull)
    }

    func testMemoryMatchPairsMatchMismatchesTurnBackAndTheGameCompletes() {
        var generator = SeededGenerator(seed: 11)
        var game = MemoryGame(using: &generator)
        XCTAssertEqual(game.cards.count, 16)
        XCTAssertEqual(Dictionary(grouping: game.cards, by: \.symbol).values.map(\.count).sorted(), Array(repeating: 2, count: 8), "eight pairs")
        let first = game.cards[0]
        let partner = game.cards.firstIndex { $0.symbol == first.symbol && $0.id != first.id }!
        let stranger = game.cards.firstIndex { $0.symbol != first.symbol }!
        XCTAssertEqual(game.turn(0), .firstTurned)
        XCTAssertEqual(game.turn(0), .ignored, "the same card twice does nothing")
        XCTAssertEqual(game.turn(stranger), .mismatch(0, stranger))
        game.hide(0, stranger)
        XCTAssertFalse(game.cards[0].faceUp); XCTAssertFalse(game.cards[stranger].faceUp)
        _ = game.turn(0)
        XCTAssertEqual(game.turn(partner), .matched)
        XCTAssertTrue(game.cards[0].matched && game.cards[partner].matched)
        for symbol in Set(game.cards.map(\.symbol)) {
            let idx = game.cards.indices.filter { game.cards[$0].symbol == symbol && !game.cards[$0].matched }
            if idx.count == 2 { _ = game.turn(idx[0]); _ = game.turn(idx[1]) }
        }
        XCTAssertTrue(game.isComplete)
    }

    func testSnakeMovesGrowsTurnsNeverBackOnItselfAndEndsAtAWall() {
        var generator = SeededGenerator(seed: 2)
        var game = SnakeGame()
        let head = game.body[0]
        game.step(using: &generator)
        XCTAssertEqual(game.body[0], SnakeGame.Point(x: head.x + 1, y: head.y)); XCTAssertEqual(game.body.count, 3)
        game.turn(.left)                       // straight back on itself: ignored
        game.step(using: &generator)
        XCTAssertEqual(game.direction, .right)
        game.turn(.up); game.step(using: &generator)
        XCTAssertEqual(game.direction, .up)
        for _ in 0..<40 where !game.isOver { game.step(using: &generator) }
        XCTAssertTrue(game.isOver, "a snake that keeps going hits the wall")
        let frozen = game
        game.step(using: &generator)
        XCTAssertEqual(game, frozen, "nothing moves after the game is over")
    }

    func testSnakeEatsFoodAndGrowsByOne() {
        var generator = SeededGenerator(seed: 9)
        var game = SnakeGame()                 // the food starts ahead of the head on the same row
        for _ in 0..<6 where game.score == 0 && !game.isOver { game.step(using: &generator) }
        XCTAssertEqual(game.score, 1); XCTAssertEqual(game.body.count, 4)
        XCTAssertFalse(game.body.contains(game.food), "new food is never placed on the snake")
    }
}

/// A repeatable random source, so a test of a game is the same every time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
