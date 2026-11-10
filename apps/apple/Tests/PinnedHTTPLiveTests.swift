import XCTest
@testable import Browser_Setu

/// A run of the real pinned HTTPS connection. Skipped unless DX01_LIVE_TLS=1 is given (pass it as TEST_RUNNER_DX01_LIVE_TLS=1); the self-signed server on 127.0.0.1:18795 is started by hand.
final class PinnedHTTPLiveTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipUnless(ProcessInfo.processInfo.environment["DX01_LIVE_TLS"] == "1") }

    func testASelfSignedCertificateIsRejected() async {
        do { _ = try await NWPinnedHTTP(timeout: 8).get(URL(string: "https://localhost:18795/announce")!, address: "127.0.0.1", maxBody: 4096, refuseExpensive: false, refuseConstrained: false); XCTFail("accepted an untrusted certificate") }
        catch { print("LIVE self-signed rejected:", error) }
    }

    func testAValidCertificateForTheRightNameIsAccepted() async throws {
        let addresses = await SystemHostResolver().addresses(for: "example.com") ?? []
        let v4 = try XCTUnwrap(addresses.first { $0.contains(".") })
        let r = try await NWPinnedHTTP(timeout: 12).get(URL(string: "https://example.com/")!, address: v4, maxBody: 2_000_000, refuseExpensive: false, refuseConstrained: false)
        print("LIVE example.com via", v4, "status", r.status, "bytes", r.body.count)
        XCTAssertTrue((200...399).contains(r.status))
    }

    func testTheSameAddressWithTheWrongNameIsRejected() async throws {
        let addresses = await SystemHostResolver().addresses(for: "example.com") ?? []
        let v4 = try XCTUnwrap(addresses.first { $0.contains(".") })
        do { _ = try await NWPinnedHTTP(timeout: 12).get(URL(string: "https://wrong-name.invalid/")!, address: v4, maxBody: 4096, refuseExpensive: false, refuseConstrained: false); XCTFail("accepted a certificate for another name") }
        catch { print("LIVE wrong name rejected:", error) }
    }
}
