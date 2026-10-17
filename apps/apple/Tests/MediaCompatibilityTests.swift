import XCTest
@testable import Browser_Setu

final class MediaCompatibilityTests: XCTestCase {
    private let quiet = ProtectedOutput(screenCaptured: false, mirrored: false, externalDisplays: 0)

    func testReportReadsFairPlayAndCodecs() {
        let raw: [String: Any] = [
            "eme": ["fairplay": "supported", "widevine": "NotSupportedError"],
            "hls": "maybe", "mse": ["h264": true], "managedMse": true,
            "decoding": ["h264": ["supported": true, "smooth": true, "powerEfficient": true], "av1": ["supported": false, "smooth": false, "powerEfficient": false]],
            "fullscreen": ["video": true], "pip": ["webkit": true], "airplay": ["picker": true],
        ]
        let report = MediaCapabilityReport.build(from: raw, output: quiet)
        func status(_ id: String) -> MediaFeature.Status? { report.features.first { $0.id == id }?.status }
        XCTAssertEqual(status("fairplay"), .supported)
        XCTAssertEqual(status("other-drm"), .unsupported)
        XCTAssertEqual(status("hls"), .supported)
        XCTAssertEqual(status("mse"), .supported)
        XCTAssertEqual(status("codec-h264"), .supported)
        XCTAssertEqual(status("codec-av1"), .unsupported)
        XCTAssertEqual(status("hardware"), .supported)
        XCTAssertEqual(status("pip"), .supported)
        XCTAssertEqual(status("airplay"), .supported)
    }

    func testEmptyProbeIsUnknownNotUnsupported() {
        let report = MediaCapabilityReport.build(from: [:], output: quiet)
        XCTAssertEqual(report.features.first { $0.id == "fairplay" }?.status, .unknown)
        XCTAssertEqual(report.features.first { $0.id == "codec-h264" }?.status, .unknown)
        XCTAssertFalse(report.plainText.isEmpty)
    }

    func testScreenSharingBlocksProtectedVideoAndSaysWhy() {
        let sharing = ProtectedOutput(screenCaptured: true, mirrored: false, externalDisplays: 0)
        XCTAssertTrue(sharing.blocksProtectedVideo)
        let result = MediaProblemExplainer.explain(errorCode: 4, errorMessage: "key system", hasMediaKeys: true, isBlob: true, readyState: 0, networkState: 3, fairplayAvailable: true, output: sharing)
        XCTAssertTrue(result.isProblem)
        XCTAssertTrue(result.headline.contains("screen"))
    }

    func testMissingFairPlayIsExplained() {
        let result = MediaProblemExplainer.explain(errorCode: 4, errorMessage: nil, hasMediaKeys: true, isBlob: true, readyState: 0, networkState: 3, fairplayAvailable: false, output: quiet)
        XCTAssertTrue(result.headline.contains("copy protection"))
    }

    func testPlainErrorsAndHealthyPlayer() {
        XCTAssertEqual(MediaProblemExplainer.explain(errorCode: 2, errorMessage: nil, hasMediaKeys: false, isBlob: false, readyState: 0, networkState: 3, fairplayAvailable: true, output: quiet).headline, "The network interrupted the video")
        XCTAssertEqual(MediaProblemExplainer.explain(errorCode: 3, errorMessage: nil, hasMediaKeys: false, isBlob: false, readyState: 0, networkState: 3, fairplayAvailable: true, output: quiet).headline, "This device could not decode the video")
        let ok = MediaProblemExplainer.explain(errorCode: nil, errorMessage: nil, hasMediaKeys: false, isBlob: false, readyState: 4, networkState: 1, fairplayAvailable: true, output: quiet)
        XCTAssertFalse(ok.isProblem)
    }
}
