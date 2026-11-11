import XCTest
@testable import Browser_Setu

/// Opt-in, network: the manifests of a BUILT app (BS_APP) are installed through the app's own installer and real HTTPS transport from the real hosted addresses, into fresh temporary folders
/// (nothing touches the person's profile). Run with BS_LIVE_HOSTED=1 BS_APP=<Browser Setu.app>. Skipped otherwise.
@MainActor
final class HostedPackagesLiveTests: XCTestCase {
    func testTheHostedPackagesInstallThroughTheRealInstaller() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BS_LIVE_HOSTED"] == "1", let app = env["BS_APP"] else { throw XCTSkip("set BS_LIVE_HOSTED=1 and BS_APP to run") }
        for resource in ["BundledTools", "BundledFFmpeg"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/\(resource).json"))
            let m = try JSONDecoder().decode(BundledToolManifest.self, from: data)
            XCTAssertTrue(m.sourceURL.hasPrefix("https://github.com/lokeshreddyveer/browsersetu/releases/download/media-tools-"), m.sourceURL)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-live-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            var last = ""
            try await MediaToolsInstall.install(m, root: root, transport: HTTPSMediaToolsTransport(), policy: .init(requiredSignature: "teamID:X4MH29QNRS"),
                                                  launchCheck: resource == "BundledFFmpeg" ? MediaToolsInstall.ffmpegLaunchCheck : nil) { _, phase in last = phase }
            XCTAssertEqual(MediaToolsInstall.activeVersion(root: root), m.version, "\(resource) did not become the active version (last phase: \(last))")
        }
    }
}
