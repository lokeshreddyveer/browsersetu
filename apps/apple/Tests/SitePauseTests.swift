import XCTest
@testable import Browser_Setu

@MainActor
final class SitePauseTests: XCTestCase {
    private func controller() throws -> (PrivacyController, BrowserCore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bs-pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let core = try BrowserCore.open(root: root.path, profile: "pause-test")
        let privacy = PrivacyController(engine: WebKitEngine(), cacheDirectory: root.appendingPathComponent("lists"))
        privacy.load(from: core)
        return (privacy, core, root)
    }

    func testPausingTurnsBlockingOffForTheSiteAndResumeTurnsItBack() throws {
        let (privacy, _, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        privacy.pause(host: "news.example.com", length: .hour)
        XCTAssertTrue(privacy.configuration.isException(host: "news.example.com"))
        XCTAssertNotNil(privacy.pause(forHost: "a.news.example.com"), "the pause covers the address and everything under it")
        XCTAssertNil(privacy.pause(forHost: "www.example.com"), "but not a sibling address")
        privacy.resume(host: "news.example.com")
        XCTAssertFalse(privacy.configuration.isException(host: "news.example.com"))
        XCTAssertNil(privacy.pause(forHost: "news.example.com"))
    }

    func testATimedPauseEndsByItselfWhenTheTimeIsUp() throws {
        let (privacy, _, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        privacy.pause(host: "example.com", length: .tenMinutes)
        privacy.expirePauses(now: Date().addingTimeInterval(300))
        XCTAssertTrue(privacy.configuration.isException(host: "example.com"), "still paused after five minutes")
        privacy.expirePauses(now: Date().addingTimeInterval(660))
        XCTAssertFalse(privacy.configuration.isException(host: "example.com"), "put back after eleven")
    }

    func testAPauseUntilQuitDoesNotSurviveARestart() throws {
        let (privacy, core, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        privacy.pause(host: "example.com", length: .untilQuit)
        XCTAssertTrue(privacy.configuration.isException(host: "example.com"))
        let next = PrivacyController(engine: WebKitEngine(), cacheDirectory: root.appendingPathComponent("lists2"))
        next.load(from: core)
        XCTAssertFalse(next.configuration.isException(host: "example.com"), "a new run starts with blocking back on")
        XCTAssertTrue(next.pauses.isEmpty)
    }

    func testTurningTheSiteOffForGoodIsNotTimed() throws {
        let (privacy, _, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        privacy.pause(host: "example.com", length: .always)
        XCTAssertTrue(privacy.configuration.isException(host: "example.com"))
        XCTAssertNil(privacy.pause(forHost: "example.com"), "no timer, so no pause record")
        privacy.expirePauses(now: Date().addingTimeInterval(86_400 * 30))
        XCTAssertTrue(privacy.configuration.isException(host: "example.com"))
    }

    func testTheSummaryReadsInPlainWords() {
        let now = Date()
        XCTAssertEqual(SitePause(domain: "a.com", until: nil).summary(now: now), "until you quit")
        XCTAssertEqual(SitePause(domain: "a.com", until: now.addingTimeInterval(600)).summary(now: now), "ends in 10 min")
        XCTAssertEqual(SitePause(domain: "a.com", until: now.addingTimeInterval(3720)).summary(now: now), "ends in 1 h 2 min")
    }
}
