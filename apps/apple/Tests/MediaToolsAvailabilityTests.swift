import XCTest
@testable import Browser_Setu

/// What the screens may offer. The 0.4.0 release offered "Install" for a yt-dlp package its own installer refuses before downloading (the manifest said "adhoc", a release build accepts only
/// the publisher's re-signed package), and the setup assistant started that install by itself. These tests keep "offered" and "can succeed here" the same question.
final class MediaToolsAvailabilityTests: XCTestCase {
    private func manifest(sourceURL: String = "https://github.com/lokeshreddyveer/browsersetu/releases/download/tools/yt-dlp.zip", sha256: String = String(repeating: "a", count: 64),
                          tree: String? = String(repeating: "b", count: 64), policy: String? = "teamID:X4MH29QNRS") throws -> BundledToolManifest {
        var json: [String: Any] = ["name": "yt-dlp", "version": "1", "sha256": sha256, "sourceURL": sourceURL]
        if let tree { json["treeSHA256"] = tree }
        if let policy { json["signaturePolicy"] = policy }
        return try JSONDecoder().decode(BundledToolManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testAHostedPublisherSignedPackageIsInstallableInEveryBuild() throws {
        let m = try manifest()
        XCTAssertTrue(m.hasPackage)
        XCTAssertTrue(m.signatureAcceptedByThisBuild)
        XCTAssertTrue(m.isInstallable)
    }

    func testAPackageThatIsNotHostedIsNeverInstallable() throws {
        XCTAssertFalse(try manifest(sourceURL: "").isInstallable, "no address")
        XCTAssertFalse(try manifest(sourceURL: "http://github.com/x.zip").isInstallable, "not https")
        XCTAssertFalse(try manifest(sha256: "").isInstallable, "no pinned digest")
        XCTAssertFalse(try manifest(tree: nil).isInstallable, "no pinned tree digest")
        XCTAssertFalse(try manifest(tree: "").isInstallable, "empty tree digest")
    }

    func testAnUnknownOrMalformedPolicyIsNeverAccepted() throws {
        for policy in ["bogus", "teamid:x4mh29qnrs", "publisher", "ADHOC "] {
            XCTAssertFalse(try manifest(policy: policy).signatureAcceptedByThisBuild, "\(policy) must not be accepted")
            XCTAssertFalse(try manifest(policy: policy).isInstallable)
        }
    }

    /// The unmodified upstream package ("adhoc") is for Debug fixtures only. This test runs in Debug, where it is allowed; in a Release build the same line must be false, which is what
    /// `scripts/check-media-tools.sh` verifies on the built app's own manifests.
    func testTheAdhocUpstreamPackageIsOnlyAcceptedByADebugBuild() throws {
        #if DEBUG
        XCTAssertTrue(try manifest(policy: "adhoc").signatureAcceptedByThisBuild)
        XCTAssertEqual(MediaToolsInstall.policyAllowed(.init(requiredSignature: "adhoc"), release: false), true)
        #else
        XCTAssertFalse(try manifest(policy: "adhoc").signatureAcceptedByThisBuild)
        #endif
        XCTAssertFalse(MediaToolsInstall.policyAllowed(.init(requiredSignature: "adhoc"), release: true), "the installer's own release rule")
    }

    /// The screen's question and the installer's question agree for every policy, so a button can never be shown for an install that the installer would then refuse.
    func testTheScreenAndTheInstallerAgreeForEveryPolicy() throws {
        for policy in ["teamID:X4MH29QNRS", "teamID:", "adhoc", "", "bogus"] {
            let screen = try manifest(policy: policy.isEmpty ? nil : policy).signatureAcceptedByThisBuild
            let installer = MediaToolsInstall.policyAllowed(.init(requiredSignature: policy), release: MediaToolsInstall.isReleaseBuild)
            // An absent policy is read as the Debug default ("adhoc") by the installer's caller; the screen treats it the same way.
            let expected = policy.isEmpty ? !MediaToolsInstall.isReleaseBuild : installer
            XCTAssertEqual(screen, expected, "policy '\(policy)'")
        }
    }

    func testTheShippedFFmpegManifestIsNotOfferedUntilItIsHosted() throws {
        let m = try XCTUnwrap(FFmpegTool.tool.manifest(), "the app carries the ffmpeg manifest")
        XCTAssertFalse(m.hasPackage, "Contents/Resources/BundledFFmpeg.json has no sourceURL or digests yet")
        XCTAssertFalse(m.isInstallable)
    }

    /// The app's own licence screen must name the optional tools and their licences before the packages are ever offered.
    func testTheAcknowledgementsNameEveryRedistributedTool() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        for needle in ["FFmpeg 9.0.2", "GNU Lesser General Public License 2.1 or later", "yt-dlp 2026.10.26", "GPL-3.0-or-later", "GNU General Public License 3 or later", "thinned", "re-signed", "LAME 3.100"] {
            XCTAssertTrue(text.contains(needle), "Acknowledgements.txt must mention: \(needle)")
        }
    }
}
