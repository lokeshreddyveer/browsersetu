import XCTest
@testable import Browser_Setu

/// How a tab moves in and out of an error page: what is shown for a failure, what clears it, and what must never show one.
@MainActor
final class ErrorFlowTests: XCTestCase {
    private func tab() -> TabController {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-errflow-\(UUID().uuidString)", profile: "default")
        return model.newTab()
    }

    private let failed = URL(string: "https://example.com/a")!

    func testAFailedLoadShowsAnErrorPageNamedFromTheEvidence() {
        let tab = tab()
        tab.engineLoadFailed(url: failed, domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, description: "ignored wording")
        let kind = tab.errorInfo?.kind
        // With a network this is a name that does not resolve; if this machine happens to be offline it is the device being offline. Never anything else.
        XCTAssertTrue(kind == .dnsFailure || kind == .noInternet, "\(String(describing: kind))")
        XCTAssertEqual(tab.errorInfo?.url, failed)
        XCTAssertEqual(tab.failedURL, failed)
    }

    func testACancelledLoadNeverShowsAnErrorPage() {
        let tab = tab()
        tab.engineLoadFailed(url: failed, domain: NSURLErrorDomain, code: NSURLErrorCancelled, description: "cancelled")
        XCTAssertNil(tab.errorInfo)
        tab.engineLoadFailed(url: failed, domain: "WebKitErrorDomain", code: 102, description: "Frame load interrupted")
        XCTAssertNil(tab.errorInfo, "a load turned into a download is not a failure")
    }

    func testAnotherPageBeingCommittedClearsTheErrorButTheFailedAddressDoesNot() {
        let tab = tab()
        tab.engineLoadFailed(url: failed, domain: NSURLErrorDomain, code: NSURLErrorTimedOut, description: "")
        XCTAssertNotNil(tab.errorInfo)
        tab.engineURLChanged(failed)
        XCTAssertNotNil(tab.errorInfo, "the address that failed is not a different page")
        tab.engineURLChanged(URL(string: "https://example.com/b")!)
        XCTAssertNil(tab.errorInfo, "history back or forward put a good page under the error, so the error goes")
    }

    func testANewNavigationStartingClearsTheError() {
        let tab = tab()
        tab.engineLoadFailed(url: failed, domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, description: "")
        XCTAssertNotNil(tab.errorInfo)
        tab.engineLoadingChanged(isLoading: true, canGoBack: true, canGoForward: false)
        XCTAssertNil(tab.errorInfo)
    }

    func testAnEmptyErrorAnswerShowsAPageButASitesOwnPageAndOkAnswersDoNot() {
        let tab = tab()
        tab.engineHTTPFailure(url: failed, status: 404)
        XCTAssertEqual(tab.errorInfo?.kind, .pageMissing); XCTAssertEqual(tab.errorInfo?.httpStatus, 404)
        let other = self.tab()
        other.engineHTTPFailure(url: failed, status: 200)
        XCTAssertNil(other.errorInfo)
        other.engineHTTPFailure(url: failed, status: 401)
        XCTAssertNil(other.errorInfo, "a sign-in answer is not an error to replace")
    }

    func testAProtectionBlockNamesItsReasonAndAPageThatKeepsCrashingPausesReloading() {
        let tab = tab()
        tab.showProtectionBlock(for: failed, reason: .threatList)
        XCTAssertEqual(tab.errorInfo?.kind, .protectionBlocked); XCTAssertEqual(tab.errorInfo?.blockReason, .threatList)
        tab.engineLoadFailed(url: failed, domain: "WebKitErrorDomain", code: 104, description: "The URL was blocked by a content blocker")
        XCTAssertEqual(tab.errorInfo?.kind, .protectionBlocked)
        XCTAssertEqual(tab.errorInfo?.blockReason, .contentFilter, "the real WebKit error for a content-blocked load")
    }

    func testReloadingFromAnErrorLoadsTheFailedAddressAgainAndClearsTheError() {
        let tab = tab()
        tab.engineLoadFailed(url: failed, domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, description: "")
        XCTAssertNotNil(tab.errorInfo)
        tab.reload()
        XCTAssertNil(tab.errorInfo, "loading starts, so the old error goes")
        XCTAssertEqual(tab.url, failed, "and it is the address that failed that is tried")
    }

    func testLeavingAnErrorOnATabWithNothingBehindItStaysSafe() {
        let tab = tab()
        tab.engineLoadFailed(url: failed, domain: NSURLErrorDomain, code: NSURLErrorTimedOut, description: "")
        tab.leaveError()                       // must not crash with no page behind
        XCTAssertNil(tab.errorInfo)
    }
}
