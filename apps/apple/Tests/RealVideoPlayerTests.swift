import WebKit
import XCTest
@testable import Browser_Setu

/// The player controls against a real video (a 90-second, 10-pictures-a-second H.264 clip with a subtitle track and three chapters), in a real web view: what they do to a playing page, and what they
/// honestly cannot do.
@MainActor
final class RealVideoPlayerTests: XCTestCase {
    private var folder: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/video", isDirectory: true) }

    private func openClip() async throws -> (WKWebView, Int) {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        web.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
        var ready = false
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(150))
            ready = (try await web.callAsyncJavaScript("const v = document.getElementById('v'); return !!v && v.readyState >= 1 && v.seekable.length > 0 && v.textTracks.length >= 1;", contentWorld: .page) as? Bool) == true
            if ready { break }
        }
        // The sandboxed process that runs these tests has no media service: the video element reports "no source" and never loads. That is the test host, not the player, so the
        // test says so and stops; the same checks run against the same clip in the iOS simulator, where video plays: `scripts/player-selftest.sh`.
        try XCTSkipUnless(ready, "This test host cannot load media (the video reports no source). Run scripts/player-selftest.sh for the real-playback checks.")
        let why = try await web.callAsyncJavaScript("const v = document.getElementById('v'); return v ? ['ready=' + v.readyState, 'net=' + v.networkState, 'seekable=' + v.seekable.length, 'error=' + (v.error ? v.error.code + ' ' + v.error.message : 'none'), 'src=' + v.currentSrc].join(' ') : 'no video';", contentWorld: .page) as? String
        print("CLIP STATE: \(why ?? "?")")
        try await Task.sleep(for: .milliseconds(500))
        let list = try await web.callAsyncJavaScript(MediaScripts.list(), contentWorld: .defaultClient) as? [[String: Any]] ?? []
        let id = try XCTUnwrap((list.first?["id"] as? NSNumber)?.intValue, "the clip was found")
        return (web, id)
    }

    private func act(_ web: WKWebView, _ id: Int, _ action: String, _ value: Double = 0) async throws -> String? {
        try await web.callAsyncJavaScript(MediaScripts.control, arguments: ["id": id, "action": action, "value": value], contentWorld: .defaultClient) as? String
    }

    private func state(_ web: WKWebView) async throws -> [String: Any] {
        try await web.callAsyncJavaScript("const v = document.getElementById('v'); return { t: v.currentTime, paused: v.paused, rate: v.playbackRate, loop: v.loop, dur: v.duration };", contentWorld: .page) as? [String: Any] ?? [:]
    }

    func testTheListReadsARealVideo() async throws {
        let (web, _) = try await openClip()
        let list = try await web.callAsyncJavaScript(MediaScripts.list(), contentWorld: .defaultClient) as? [[String: Any]] ?? []
        let v = DetectedVideo(raw: try XCTUnwrap(list.first))
        XCTAssertTrue(v.canSeek, "it can be moved through")
        XCTAssertEqual(v.duration, 90, accuracy: 1)
        XCTAssertEqual(v.seekEnd ?? 0, 90, accuracy: 1)
        XCTAssertEqual(v.width, 320); XCTAssertEqual(v.height, 180)
        XCTAssertEqual(v.tracks.count, 1, "the English subtitles")
        XCTAssertEqual(v.chapters.map(\.title), ["Start", "Middle", "End"])
        XCTAssertEqual(v.chapters.map(\.start), [0, 30, 60])
        XCTAssertTrue(v.visible); XCTAssertFalse(v.protected); XCTAssertFalse(v.isLive)
    }

    func testSkippingSpeedLoopAndSeekingWorkOnRealMedia() async throws {
        let (web, id) = try await openClip()
        let skip = try await act(web, id, "seekBy", 10)
        XCTAssertNil(skip)
        let afterSkip = try await state(web)
        XCTAssertEqual(afterSkip["t"] as? Double ?? -1, 10, accuracy: 0.6)
        let back = try await act(web, id, "seekBy", -30)
        XCTAssertNil(back)
        let atStart = try await state(web)
        XCTAssertEqual(atStart["t"] as? Double ?? -1, 0, accuracy: 0.2, "it stops at the start of what can be reached")
        let faster = try await act(web, id, "speedBy", 0.25)
        XCTAssertNil(faster)
        let afterFaster = try await state(web)
        XCTAssertEqual(afterFaster["rate"] as? Double ?? 0, 1.25, accuracy: 0.001)
        let loop = try await act(web, id, "loop", 1)
        XCTAssertNil(loop)
        let looping = try await state(web)
        XCTAssertEqual(looping["loop"] as? Bool, true)
    }

    /// The clip has ten pictures a second, so a step of a thirtieth of a second is a third of a picture: the step is a fixed time, NOT one frame. The panel must not call it one.
    func testAFrameStepIsAThirtiethOfASecondNotARealFrame() async throws {
        let (web, id) = try await openClip()
        _ = try await act(web, id, "seekBy", 20)
        let before = try await state(web)
        let step = try await act(web, id, "frame", 1)
        XCTAssertNil(step)
        let after = try await state(web)
        XCTAssertEqual(after["paused"] as? Bool, true, "stepping pauses")
        let delta = (after["t"] as? Double ?? 0) - (before["t"] as? Double ?? 0)
        XCTAssertEqual(delta, 1.0 / 30.0, accuracy: 0.02, "a thirtieth of a second")
        XCTAssertLessThan(delta, 0.1, "which is less than the clip's own picture length of 0.1 s, so it is not frame-accurate")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/EnhancedPlayer.swift"), encoding: .utf8)
        XCTAssertFalse(source.lowercased().contains("one picture"), "the panel does not call a time step a picture")
        XCTAssertTrue(source.contains("thirtieth of a second"), "and says what the step really is")
    }

    func testARepeatBetweenTwoPointsKeepsPlaybackInsideThem() async throws {
        let (web, id) = try await openClip()
        _ = try await act(web, id, "seekBy", 5)
        let a = try await act(web, id, "markA")
        XCTAssertNil(a)
        _ = try await act(web, id, "seekBy", 3)
        let b = try await act(web, id, "markB")
        XCTAssertNil(b)
        _ = try await web.callAsyncJavaScript("document.getElementById('v').muted = true; document.getElementById('v').play().catch(() => {}); return true;", contentWorld: .page)
        var wrapped = false
        var maxSeen = 0.0
        var last = 0.0
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(150))
            let t = try await state(web)["t"] as? Double ?? 0
            maxSeen = max(maxSeen, t)
            if t < last - 1 { wrapped = true }
            last = t
        }
        XCTAssertTrue(wrapped, "playback went back to A at least once (position \(last))")
        XCTAssertLessThan(maxSeen, 8.6, "and never ran far past B")
        _ = try await act(web, id, "clearAB")
    }

    func testSubtitlesTranscriptAndTimingWork() async throws {
        let (web, id) = try await openClip()
        _ = try await web.callAsyncJavaScript("document.getElementById('v').textTracks[0].mode = 'showing'; return true;", contentWorld: .page)
        try await Task.sleep(for: .milliseconds(600))
        let transcript = try await web.callAsyncJavaScript(MediaScripts.transcript, arguments: ["id": id], contentWorld: .defaultClient) as? [String: Any]
        let cues = transcript?["cues"] as? [[String: Any]] ?? []
        XCTAssertEqual(cues.count, 4, "all four lines: \(String(describing: transcript?["error"]))")
        XCTAssertEqual(cues.first?["text"] as? String, "First line of the clip")
        let shift = try await act(web, id, "subtitleShift", 0.5)
        XCTAssertNil(shift)
        let start = try await web.callAsyncJavaScript("return document.getElementById('v').textTracks[0].cues[0].startTime;", contentWorld: .page) as? Double
        XCTAssertEqual(start ?? 0, 2.5, accuracy: 0.01, "the line now comes half a second later")
    }

    func testTheaterFocusFitAndPictureChangeOnlyTheVideoAndComeBack() async throws {
        let (web, id) = try await openClip()
        let original = try await web.callAsyncJavaScript("return document.getElementById('v').getAttribute('style');", contentWorld: .page) as? String
        for action in ["theater", "focus"] { let r = try await act(web, id, action, 1); XCTAssertNil(r); let off = try await act(web, id, action, 0); XCTAssertNil(off) }
        let fit = try await act(web, id, "fit", 1); XCTAssertNil(fit)
        let tone = try await act(web, id, "adjust:contrast", 0.2); XCTAssertNil(tone)
        let during = try await web.callAsyncJavaScript("const s = document.getElementById('v').style; return [s.objectFit, s.filter];", contentWorld: .page) as? [String]
        XCTAssertEqual(during?[0], "cover"); XCTAssertTrue(during?[1].contains("contrast(1.2)") == true)
        _ = try await act(web, id, "fit", -1); _ = try await act(web, id, "adjust:reset")
        let after = try await web.callAsyncJavaScript("return document.getElementById('v').getAttribute('style');", contentWorld: .page) as? String
        XCTAssertEqual(after, original, "its own style is exactly as it was")
        let page = try await web.callAsyncJavaScript("return [document.documentElement.style.overflow, document.querySelector('h2').getAttribute('style')];", contentWorld: .page) as? [String]
        XCTAssertEqual(page?[0], "", "the page scrolls as before")
    }

    func testCopyingAPictureEitherGivesAPNGOrSaysWhyNot() async throws {
        let (web, id) = try await openClip()
        let result = try await web.callAsyncJavaScript(MediaScripts.capture, arguments: ["id": id], contentWorld: .defaultClient) as? [String: Any]
        if let data = result?["data"] as? String { XCTAssertTrue(data.hasPrefix("data:image/png;base64,"), "a PNG") }
        else { XCTAssertEqual(result?["error"] as? String, "This video comes from another site, which does not let its pictures be copied.", "refused, and said so (a file page counts as another origin)") }
    }
}
