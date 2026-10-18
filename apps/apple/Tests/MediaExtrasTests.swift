import XCTest
@testable import Browser_Setu

final class MediaExtrasTests: XCTestCase {
    func testHistoryIsNewestFirstAndMergesQuickRepeats() {
        let t0 = Date()
        var list: [MediaHistoryEntry] = []
        list = MediaHistoryRules.adding(MediaHistoryEntry(date: t0, title: "A", url: "https://a.com/1", site: "a.com"), to: list)
        list = MediaHistoryRules.adding(MediaHistoryEntry(date: t0.addingTimeInterval(5), title: "B", url: "https://b.com/1", site: "b.com"), to: list)
        list = MediaHistoryRules.adding(MediaHistoryEntry(date: t0.addingTimeInterval(60), title: "A again", url: "https://a.com/1", site: "a.com"), to: list)
        XCTAssertEqual(list.map(\.title), ["A again", "B"])
        list = MediaHistoryRules.adding(MediaHistoryEntry(date: t0.addingTimeInterval(4000), title: "A later", url: "https://a.com/1", site: "a.com"), to: list)
        XCTAssertEqual(list.map(\.title), ["A later", "A again", "B"], "a replay long after is its own entry")
    }

    func testHistoryIsCapped() {
        var list: [MediaHistoryEntry] = []
        for i in 0..<(MediaHistoryRules.limit + 30) { list = MediaHistoryRules.adding(MediaHistoryEntry(title: "\(i)", url: "https://x.com/\(i)", site: "x.com"), to: list) }
        XCTAssertEqual(list.count, MediaHistoryRules.limit)
        XCTAssertEqual(list.first?.title, "\(MediaHistoryRules.limit + 29)")
    }

    func testSleepTimerEnds() {
        let now = Date()
        XCTAssertEqual(SleepTimerChoice.thirty.end(from: now).timeIntervalSince(now), 1800)
    }

    func testDetectedVideoReadsQualityTracksAndNowPlaying() {
        let raw: [String: Any] = ["tag": "video", "src": "blob:x", "currentTime": 3.0, "duration": 100.0, "paused": false, "rate": 1.0, "hasMediaKeys": false,
                                  "volume": 0.5, "muted": true, "width": 1920, "height": 1080, "dropped": 2, "frames": 3200,
                                  "sessionTitle": "Song", "sessionArtist": "Band", "pageTitle": "Page",
                                  "tracks": [["label": "English", "mode": "showing"], ["label": "French", "mode": "disabled"]], "canAirPlay": true]
        let v = DetectedVideo(index: 0, raw: raw)
        XCTAssertEqual(v.qualityText, "1920 × 1080 · 2 of 3200 frames dropped")
        XCTAssertEqual(v.nowPlaying, "Song · Band")
        XCTAssertEqual(v.tracks.map(\.label), ["English", "French"])
        XCTAssertEqual(v.tracks.map(\.showing), [true, false])
        XCTAssertTrue(v.muted)
        XCTAssertTrue(v.canAirPlay)
        XCTAssertNil(DetectedVideo(index: 1, raw: ["tag": "audio"]).qualityText)
        XCTAssertEqual(DetectedVideo(index: 1, raw: ["tag": "audio", "pageTitle": "Only page"]).nowPlaying, "Only page")
    }
}
