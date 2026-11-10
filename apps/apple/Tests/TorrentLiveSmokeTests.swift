import XCTest
@testable import Browser_Setu

@MainActor
/// Opt-in (BS_TORRENT_LIVE=1, network): the app's own engine gets the file list of the official Ubuntu 24.04.3 desktop torrent (a legal, heavily seeded swarm) from a magnet link,
/// with trackers only and with the DHT. If this passes and someone's own magnet does not, the problem is that swarm (no active peers), not the engine.
final class TorrentLiveSmokeTests: XCTestCase {
    func testOfficialUbuntuMagnetDetailsArrive() async throws {
        guard ProcessInfo.processInfo.environment["BS_TORRENT_LIVE"] == "1" else { throw XCTSkip("live") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("torrent-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = DownloadCoordinator.directoryOverride; DownloadCoordinator.directoryOverride = folder
        defer { DownloadCoordinator.directoryOverride = saved; try? FileManager.default.removeItem(at: folder) }
        let link = "magnet:?xt=urn:btih:d160b8d8ea35a5b4e52837468fc8f03d55cef1f7&dn=ubuntu-24.04.3-desktop-amd64.iso&tr=https%3A%2F%2Ftorrent.ubuntu.com%2Fannounce&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce"
        for (label, dht) in [("trackers only", false), ("trackers + DHT", true)] {
            let c = DownloadCoordinator()
            c.torrentSettings.enabled = true; c.torrentSettings.dhtEnabled = dht
            let magnet = try MagnetLink.parse(link)
            let t0 = Date()
            do {
                let meta = try await c.torrents.fetchDetails(of: magnet, timeout: 75)
                XCTAssertEqual(meta.files.count, 1)
                print("TORRENT [\(label)] OK in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(meta.name) files \(meta.files.count)")
            } catch {
                XCTFail("[\(label)] \(error)")
                print("TORRENT [\(label)] FAILED after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
    }
}
