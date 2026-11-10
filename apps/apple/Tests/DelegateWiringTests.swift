import XCTest
import WebKit
@testable import Browser_Setu

/// A delegate method whose name is a little off is never called, and the compiler only warns. These check that the methods that carry a safety decision are really the ones the system calls.
final class DelegateWiringTests: XCTestCase {
    func testTheTrackerRedirectGuardIsTheMethodURLSessionCalls() {
        let guardObject = HTTPTrackerClient.RedirectGuard(authorized: { _ in false })
        XCTAssertTrue(guardObject.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:))),
                      "a tracker's redirect is checked by the guard (it was never called when the method had a slightly different name)")
    }

    func testTheCameraAndMicrophoneDecisionIsTheMethodWebKitCalls() {
        XCTAssertTrue(WebKitTab.instancesRespond(to: NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")),
                      "the browser's per-site camera and microphone choice is what WebKit asks (with the old Swift name this was false: WebKit never called it)")
    }
}
