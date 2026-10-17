import XCTest
@testable import Browser_Setu

/// Registered as the test bundle's principal class. After every test it closes the pages of every model that test made, so web processes do not pile up over
/// a run of hundreds of tests (which used to end with the system too busy to start another one).
@objc(TestCleanup)
final class TestCleanup: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        MainActor.assumeIsolated {
            for model in BrowserModel.liveModels.allObjects { model.closeAllPagesForTests() }
        }
    }
}
