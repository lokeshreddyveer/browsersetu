import XCTest
@testable import Browser_Setu

/// Real fragmented-MP4 segments (H.264 picture and AAC sound, 4 s) for the native UI tests of HLS and DASH downloads, made by the same factory the integration tests use and committed under
/// Tests/Fixtures/stream/{v,a}: the sandboxed UI test runner serves them to the fixture server. To regenerate: BS_WRITE_STREAM_FIXTURES=1 (TEST_RUNNER_ prefix under xcodebuild).
final class StreamFixtureTests: XCTestCase {
    static var folder: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/stream", isDirectory: true) }

    func testRegenerateTheStreamFixturesWhenAsked() async throws {
        guard ProcessInfo.processInfo.environment["BS_WRITE_STREAM_FIXTURES"] == "1" else { throw XCTSkip("opt-in generator: set BS_WRITE_STREAM_FIXTURES=1 to rewrite Tests/Fixtures/stream") }
        let fm = FileManager.default
        try? fm.removeItem(at: Self.folder)
        var info: [String: [Double]] = [:]
        for (dir, track) in [("v", try await MediaFixtureFactory.video(seconds: 4)), ("a", try await MediaFixtureFactory.audio(seconds: 4))] {
            let d = Self.folder.appendingPathComponent(dir, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try track.initData.write(to: d.appendingPathComponent("init.mp4"))
            for (i, seg) in track.segments.enumerated() { try seg.write(to: d.appendingPathComponent("seg\(i).m4s")) }
            info[dir] = track.durations
        }
        try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .prettyPrinted]).write(to: Self.folder.appendingPathComponent("durations.json"))
    }

    func testTheCommittedStreamFixturesArePresentAndFormAPlayableTrack() throws {
        let fm = FileManager.default
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.folder.appendingPathComponent("durations.json"))) as? [String: [Double]], "Tests/Fixtures/stream/durations.json is missing: regenerate with BS_WRITE_STREAM_FIXTURES=1")
        for dir in ["v", "a"] {
            let durations = try XCTUnwrap(info[dir])
            XCTAssertFalse(durations.isEmpty)
            let d = Self.folder.appendingPathComponent(dir, isDirectory: true)
            XCTAssertGreaterThan(try Data(contentsOf: d.appendingPathComponent("init.mp4")).count, 100, "\(dir)/init.mp4")
            for i in durations.indices { XCTAssertTrue(fm.fileExists(atPath: d.appendingPathComponent("seg\(i).m4s").path), "\(dir)/seg\(i).m4s") }
        }
    }
}
