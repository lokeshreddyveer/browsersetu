import XCTest
import AVFoundation
@testable import Browser_Setu

// DX-08: downloads that really run against the local fixture server (port 18766, started by the BrowserSetuMac scheme) with original media generated in Phase17MediaTests.
// Every finished file is checked with the system's own player and reader, and copied to `dx08-keep` in the test temp folder so scripts/mp4_probe.py (which shares no code with the app)
// can read it again.

final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ s: String) { lock.lock(); entries.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

@MainActor
final class DX08InteropTests: MediaCase {
    // MARK: Helpers

    func ms(_ d: Double) -> Int { Int((d * 1000).rounded()) }
    func putTrack(_ p: String, _ dir: String, _ t: FixtureTrack) async throws {
        try await put("\(p)/\(dir)/init.mp4", t.initData)
        for (i, s) in t.segments.enumerated() { try await put("\(p)/\(dir)/seg\(i).m4s", s) }
    }
    func timeline(_ t: FixtureTrack) -> String { t.durations.map { "<S d=\"\(ms($0))\"/>" }.joined() }
    func seconds(_ t: FixtureTrack) -> String { String(format: "PT%.3fS", t.durations.reduce(0, +)) }

    /// Keeps a copy of a finished file for the independent probe.
    func keep(_ file: URL, as name: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dx08-keep")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name + "." + file.pathExtension)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: file, to: target)
    }

    /// Inspect, choose, plan, start; returns the task and its final record.
    func download(_ manifestURL: URL, name: String, request: MediaSelectionRequest = .init(), allowFallback: Bool = false, seconds: Double = 60) async throws -> (id: UUID, record: DownloadTaskRecord?, manifest: MediaManifest) {
        let manifest = try await c.media.inspect(manifestURL)
        let r = manifest.select(request)
        let plan = try await c.media.plan(for: manifest, selection: r.choice, title: name, allowFallback: allowFallback, fallbacks: r.fallbacks, sourceURL: manifestURL)
        let id = try await c.media.add(plan, name: name, source: manifestURL)
        return (id, await wait(id, for: [.completed, .failed], seconds: seconds), manifest)
    }

    func output(_ record: DownloadTaskRecord?) throws -> URL { URL(fileURLWithPath: try XCTUnwrap(record?.file.destinationPath)) }

    /// The first and last sample times of each track agree (within what two audio frames and a video frame allow), read with the system's own reader.
    func assertInSync(_ file: URL, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: file)
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        guard let v = video.first else { return XCTFail("no video track", line: line) }
        let vr = try await v.load(.timeRange)
        let tol = MediaTimeline.syncTolerance(frameRate: 10)
        for a in audio {
            let ar = try await a.load(.timeRange)
            XCTAssertEqual(ar.start.seconds, vr.start.seconds, accuracy: tol, "sound and picture start together", line: line)
            XCTAssertEqual(ar.end.seconds, vr.end.seconds, accuracy: tol, "sound and picture end together", line: line)
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
        reader.add(out); XCTAssertTrue(reader.startReading(), line: line)
        var frames = 0
        while out.copyNextSampleBuffer() != nil { frames += 1 }
        XCTAssertGreaterThanOrEqual(frames, Int((vr.duration.seconds * 10).rounded()) - 3, "no frame is lost: every one can be read back", line: line)
    }

    func assertPlays(_ file: URL, line: UInt = #line) async throws {
        let item = AVPlayerItem(url: file)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        for _ in 0..<100 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(item.status, .readyToPlay, "\(String(describing: item.error))", line: line)
        player.play()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertGreaterThan(player.currentTime().seconds, 0.6, "it plays", line: line)
        player.pause()
    }

    func audioLanguages(_ file: URL) async throws -> [String] {
        let tracks = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio)
        var out: [String] = []
        for t in tracks { out.append((try await t.load(.extendedLanguageTag)) ?? "und") }
        return out
    }

    // MARK: HLS: languages, discontinuities, subtitles

    func testHLSWithTwoLanguagesDownloadsBothAndTheyPlayInSync() async throws {
        let master = try await publishHLS("dx8-lang")
        let (_, record, manifest) = try await download(master, name: "Two languages", request: .init(quality: .highest, audioLanguages: ["es", "en"]))
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let file = try output(record)
        XCTAssertEqual(manifest.audios.count, 2)
        let langs = try await audioLanguages(file)
        XCTAssertEqual(Set(langs.map { MediaLanguage.primary($0) ?? $0 }), ["es", "en"], "\(langs)")
        try await assertPlayable(file, seconds: 4)
        try await assertInSync(file)
        try await assertPlays(file)
        keep(file, as: "hls-two-languages")
        XCTAssertEqual(segmentFolders(), [])
    }

    // MARK: The Download sheet's save flow (VideoSaveOperation)

    /// A real muxed MP4 (picture and sound) served by the fixture, made by the HLS engine itself.
    func publishDirectClip(_ key: String) async throws -> URL {
        let master = try await publishHLS(key + "-src")
        let (_, record, _) = try await download(master, name: key)
        let file = try output(record)
        try await put("\(key)/clip.mp4", try Data(contentsOf: file))
        return url("/media/\(key)/clip.mp4")
    }

    func finish(_ op: VideoSaveOperation, seconds: Double = 60) async -> VideoSaveOperation.Stage {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !op.stage.isFinal { try? await Task.sleep(nanoseconds: 200_000_000) }
        return op.stage
    }

    func testSavingADirectVideoAsM4AAndMP3MakesValidAudioFiles() async throws {
        let clip = try await publishDirectClip("save-direct")
        // Audio as M4A (the existing local processing), keeping the video.
        let m4a = VideoSaveOperation(url: clip, name: "Clip M4A", output: .m4a, keepOriginal: true, isPrivate: false, coordinator: c, processing: MediaProcessingService(stagingRoot: FileManager.default.temporaryDirectory.appendingPathComponent("vs-stage-\(UUID().uuidString)"), authorizedRoots: [DownloadCoordinator.directory]), profileTag: "t", origin: .user)
        m4a.start()
        guard case .done(let audioFile) = await finish(m4a) else { return XCTFail("M4A: \(m4a.stage)") }
        XCTAssertEqual(audioFile.pathExtension, "m4a")
        let a1 = AVURLAsset(url: audioFile)
        let videoTracks1 = try await a1.loadTracks(withMediaType: .video).count, audioTracks1 = try await a1.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(videoTracks1, 0); XCTAssertEqual(audioTracks1, 1)
        keep(audioFile, as: "direct-to-m4a")
        // The same clip as MP3, discarding the downloaded video.
        let mp3 = VideoSaveOperation(url: clip, name: "Clip MP3", output: .mp3(kbps: 192), keepOriginal: false, isPrivate: false, coordinator: c, profileTag: "t", origin: .user)
        mp3.start()
        guard case .done(let mp3File) = await finish(mp3) else { return XCTFail("MP3: \(mp3.stage)") }
        XCTAssertEqual(mp3File.pathExtension, "mp3")
        let length = try await AVURLAsset(url: mp3File).load(.duration).seconds
        XCTAssertEqual(length, 4, accuracy: 0.6)
        let id = try XCTUnwrap(mp3.downloadID)
        // The video downloaded only to make the audio was moved to the Trash, and its record left the list with it (no completed download points at a missing file).
        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadCoordinator.directory.appendingPathComponent("Clip MP3.mp4").path), "the downloaded video is gone")
        XCTAssertNil(c.ledger.record(id), "and no longer listed as a completed download")
        XCTAssertEqual(c.ledger.records.values.filter { $0.file.destinationPath == mp3File.path }.count, 1, "the MP3 is the one completed download for this save")
        keep(mp3File, as: "direct-to-mp3")
    }

    func testSaveOriginalAndDoubleStartAndCancel() async throws {
        let clip = try await publishDirectClip("save-orig")
        let op = VideoSaveOperation(url: clip, name: "Original clip", output: .original, keepOriginal: true, isPrivate: false, coordinator: c, profileTag: "t", origin: .user)
        let before = c.ledger.records.count
        op.start(); op.start()                                              // a second click starts nothing
        XCTAssertEqual(c.ledger.records.count, before + 1)
        guard case .done(let file) = await finish(op) else { return XCTFail("\(op.stage)") }
        let probeAsset = AVURLAsset(url: file)
        let hasVideo = try await probeAsset.loadTracks(withMediaType: .video).count, hasAudio = try await probeAsset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(hasVideo, 1); XCTAssertEqual(hasAudio, 1)
        // Cancelling a request that has only just started ends it and leaves no finished file.
        let slow = VideoSaveOperation(url: url("/throttle/4000000?bps=100000"), name: "Slow", output: .original, keepOriginal: true, isPrivate: false, coordinator: c, profileTag: "t", origin: .user)
        slow.start()
        try await Task.sleep(nanoseconds: 800_000_000)
        slow.cancel()
        XCTAssertEqual(slow.stage, .cancelled)
        try await Task.sleep(nanoseconds: 600_000_000)
        let id = try XCTUnwrap(slow.downloadID)
        XCTAssertNotEqual(c.ledger.record(id)?.state, .completed)
    }

    // MARK: Normalized sources: every source type through the same picker contract and engines

    func finishSource(_ op: SourceSaveOperation, seconds: Double = 90) async -> VideoSaveOperation.Stage {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !op.stage.isFinal { try? await Task.sleep(nanoseconds: 250_000_000) }
        return op.stage
    }
    func rep(_ role: NormalizedRepresentation.Role, _ u: URL, _ ext: String, height: Int? = nil) -> NormalizedRepresentation { NormalizedRepresentation(role: role, url: u, container: ext, height: height) }

    /// Picture-only and sound-only files, made by the stream engine and served as plain files.
    func publishSeparateTracks(_ key: String) async throws -> (video: URL, audio: URL) {
        let master = try await publishHLS(key + "-src")
        let m = try await c.media.inspect(master)
        let v = try XCTUnwrap(m.videos.first(where: { $0.kind != .muxed && $0.isDownloadable })), a = try XCTUnwrap(m.audios.first(where: \.isDownloadable))
        func fetch(_ choice: MediaChoice, _ name: String) async throws -> Data {
            let plan = try await c.media.plan(for: m, selection: choice, title: name, allowFallback: false, fallbacks: [], sourceURL: master)
            let id = try await c.media.add(plan, name: name, source: master)
            let rec = await wait(id, for: [.completed, .failed], seconds: 60)
            XCTAssertEqual(rec?.state, .completed, rec?.failure?.reason ?? "")
            return try Data(contentsOf: try output(rec))
        }
        try await put("\(key)/v.mp4", try await fetch(MediaChoice(video: v.id, audio: nil, subtitles: [], extraAudios: []), key + "-v"))
        try await put("\(key)/a.m4a", try await fetch(MediaChoice(video: nil, audio: a.id, subtitles: [], extraAudios: []), key + "-a"))
        return (url("/media/\(key)/v.mp4"), url("/media/\(key)/a.m4a"))
    }

    func testMatrixSeparateTracksJoinIntoOneValidMP4() async throws {
        let (v, a) = try await publishSeparateTracks("mx-sep")
        let src = NormalizedMediaSource(title: "Separate", provider: nil, pageHost: "x.org", isPrivate: false, shape: .tracks([rep(.video, v, "mp4", height: 120), rep(.audio, a, "m4a")]))
        let opts = src.options(encoders: (true, true))
        XCTAssertTrue(opts.contains { $0.kind == .video && $0.isAvailable && $0.provenance.contains("joined") })
        XCTAssertTrue(opts.contains { $0.kind == .audioMP3 && $0.isAvailable })
        let op = SourceSaveOperation(source: src, choice: .joined, name: "Joined clip", coordinator: c, profileTag: "t", origin: .user)
        op.start()
        guard case .done(let file) = await finishSource(op) else { return XCTFail("\(op.stage)") }
        let asset = AVURLAsset(url: file)
        let vt = try await asset.loadTracks(withMediaType: .video).count, at = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(vt, 1); XCTAssertEqual(at, 1)
        try await assertInSync(file); try await assertPlays(file)
        keep(file, as: "matrix-separate-joined")
    }

    func testMatrixDirectWithAndWithoutAudioAndMissingAudioIsHonest() async throws {
        let (v, a) = try await publishSeparateTracks("mx-dir")
        // Picture only: the original saves; sound cannot be made from it and the failure says so.
        let silent = NormalizedMediaSource(title: "Silent", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([rep(.muxed, v, "mp4", height: 120)]))
        let o = SourceSaveOperation(source: silent, choice: .original, name: "Silent clip", coordinator: c, profileTag: "t", origin: .user); o.start()
        guard case .done(let f) = await finishSource(o) else { return XCTFail("\(o.stage)") }
        let vt = try await AVURLAsset(url: f).loadTracks(withMediaType: .video).count, at = try await AVURLAsset(url: f).loadTracks(withMediaType: .audio).count
        XCTAssertEqual(vt, 1); XCTAssertEqual(at, 0)
        let ask = SourceSaveOperation(source: silent, choice: .audioMP3(kbps: 128), name: "Silent mp3", coordinator: c, profileTag: "t", origin: .user); ask.start()
        let r = await finishSource(ask)
        if case .failed = r {} else { XCTFail("sound from a silent file must fail, got \(r)") }
        // Sound only, to MP3.
        let sound = NormalizedMediaSource(title: "Sound", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([rep(.audio, a, "m4a")]))
        let m = SourceSaveOperation(source: sound, choice: .audioMP3(kbps: 192), name: "Sound mp3", coordinator: c, profileTag: "t", origin: .user); m.start()
        guard case .done(let mp3) = await finishSource(m) else { return XCTFail("\(m.stage)") }
        let length = try await AVURLAsset(url: mp3).load(.duration).seconds
        XCTAssertEqual(length, 4, accuracy: 0.8); keep(mp3, as: "matrix-audio-to-mp3")
    }

    func testMatrixHLSStreamToVideoToM4AAndToMP3() async throws {
        let master = try await publishHLS("mx-hls")
        let src = NormalizedMediaSource(title: "Stream", provider: nil, pageHost: "x.org", isPrivate: false, shape: .manifest(master))
        for (choice, ext) in [(SourceSaveOperation.Choice.original, "mp4"), (.audioM4A, "m4a"), (.audioMP3(kbps: 192), "mp3")] {
            let op = SourceSaveOperation(source: src, choice: choice, name: "Stream \(ext)", coordinator: c, profileTag: "t", origin: .user); op.start()
            guard case .done(let f) = await finishSource(op) else { XCTFail("\(choice) \(op.stage)"); continue }
            XCTAssertEqual(f.pathExtension, ext)
            let asset = AVURLAsset(url: f)
            let seconds = try await asset.load(.duration).seconds
            XCTAssertEqual(seconds, 4, accuracy: 1.2, "\(ext)")
            let videoCount = try await asset.loadTracks(withMediaType: .video).count
            XCTAssertEqual(videoCount, ext == "mp4" ? 1 : 0, ext)
            keep(f, as: "matrix-hls-\(ext)")
        }
    }

    func testReviewPrivateStreamIsPrivateAndChosenTrackIsUsedAndCancelBeforeStartStaysCancelled() async throws {
        let master = try await publishHLS("mx-priv")
        let priv = NormalizedMediaSource(title: "P", provider: nil, pageHost: nil, isPrivate: true, shape: .manifest(master))
        let op = SourceSaveOperation(source: priv, choice: .original, name: "Private stream", coordinator: c, profileTag: "t", origin: .user); op.start()
        guard case .done = await finishSource(op) else { return XCTFail("\(op.stage)") }
        let id = try XCTUnwrap(op.downloadIDs.first)
        XCTAssertEqual(c.ledger.record(id)?.isPrivate, true, "a private tab's stream save is private in the ledger")
        // The chosen audio is the one downloaded (not just the first listed).
        let (v, a) = try await publishSeparateTracks("mx-pick")
        let other = a.deletingLastPathComponent().appendingPathComponent("a.m4a?other=1")
        let reps = [rep(.video, v, "mp4", height: 120), rep(.audio, URL(string: other.absoluteString)!, "m4a"), rep(.audio, a, "m4a")]
        let src = NormalizedMediaSource(title: "Pick", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks(reps))
        let pick = SourceSaveOperation(source: src, choice: .joined, name: "Picked", coordinator: c, profileTag: "t", origin: .user)
        pick.pickAudio = reps[2]
        pick.start()
        guard case .done = await finishSource(pick) else { return XCTFail("\(pick.stage)") }
        let sources = pick.fetchedURLs.map(\.absoluteString)
        XCTAssertTrue(sources.contains(a.absoluteString)); XCTAssertFalse(sources.contains(other.absoluteString))
        // Cancelled before it starts: starting later does nothing.
        let late = SourceSaveOperation(source: src, choice: .joined, name: "Late", coordinator: c, profileTag: "t", origin: .user)
        late.cancel(); late.start()
        XCTAssertEqual(late.stage, .cancelled); XCTAssertTrue(late.downloadIDs.isEmpty)
    }

    // MARK: Extractor → formats → coordinator → file (the whole chain, with the stand-in extractor)

    func extractorSource(_ key: String, _ word: String) async throws -> NormalizedMediaSource {
        let script = TestExtractorScript.path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "the stand-in script is not installed")
        return try await ExternalExtractor.lookup(page: URL(string: "http://127.0.0.1:18766/media/\(key)/page.html?\(word)")!, path: script, isPrivate: false, allowLocal: true)
    }

    func testExtractorMuxedFormatDownloadsThroughTheCoordinatorAndIsValidated() async throws {
        _ = try await publishDirectClip("ext-mux")
        let src = try await extractorSource("ext-mux", "muxed")
        let op = SourceSaveOperation(source: src, choice: .original, name: "Extracted clip", coordinator: c, profileTag: "t", origin: .user); op.start()
        let seen = Date().addingTimeInterval(5)
        while Date() < seen, op.downloadIDs.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        let taskID = try XCTUnwrap(op.downloadIDs.first, "the click created a coordinator task")
        XCTAssertNotNil(c.ledger.record(taskID))
        guard case .done(let f) = await finishSource(op) else { return XCTFail("\(op.stage)") }
        let rec = try XCTUnwrap(c.ledger.record(try XCTUnwrap(op.downloadIDs.first)))
        XCTAssertEqual(rec.state, .completed); XCTAssertGreaterThan(rec.transfer.completedBytes, 10_000); XCTAssertEqual(rec.file.destinationPath, f.path)
        let size = (try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 10_000)
        let asset = AVURLAsset(url: f)
        let v = try await asset.loadTracks(withMediaType: .video).count, a = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(v, 1); XCTAssertEqual(a, 1); try await assertPlays(f)
        keep(f, as: "extractor-muxed")
        // A second rapid click on the same operation starts nothing more.
        let count = c.ledger.records.count; op.start(); XCTAssertEqual(c.ledger.records.count, count)
    }

    func testExtractorSeparateTracksJoinIntoOneValidMP4AndAudioBecomesMP3() async throws {
        _ = try await publishSeparateTracks("ext-sep")
        let src = try await extractorSource("ext-sep", "separate")
        let join = SourceSaveOperation(source: src, choice: .joined, name: "Extracted joined", coordinator: c, profileTag: "t", origin: .user); join.start()
        guard case .done(let f) = await finishSource(join) else { return XCTFail("\(join.stage)") }
        let asset = AVURLAsset(url: f)
        let v = try await asset.loadTracks(withMediaType: .video).count, a = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(v, 1); XCTAssertEqual(a, 1); try await assertInSync(f); keep(f, as: "extractor-joined")
        let mp3 = SourceSaveOperation(source: src, choice: .audioMP3(kbps: 192), name: "Extracted audio", coordinator: c, profileTag: "t", origin: .user); mp3.start()
        guard case .done(let m) = await finishSource(mp3) else { return XCTFail("\(mp3.stage)") }
        XCTAssertEqual(m.pathExtension, "mp3"); keep(m, as: "extractor-audio-mp3")
    }

    /// Picking the 360p format downloads the 360p file, not the 720p one; and a join whose second half cannot be fetched removes the first half it already downloaded.
    func testReviewPickedQualityIsDownloadedAndFailedJoinLeavesNoHalves() async throws {
        let clip = try await publishDirectClip("ext-two")
        try await put("ext-two/clip2.mp4", try Data(contentsOf: try output(try XCTUnwrap(c.ledger.records.values.first { $0.file.filename.hasPrefix("ext-two") && $0.state == .completed }))))
        let src = try await extractorSource("ext-two", "two")
        guard case .tracks(let reps) = src.shape, let sd = reps.first(where: { $0.formatID == "sd" }) else { return XCTFail() }
        let op = SourceSaveOperation(source: src, choice: .original, name: "Picked sd", coordinator: c, profileTag: "t", origin: .user); op.pickVideo = sd; op.start()
        guard case .done = await finishSource(op) else { return XCTFail("\(op.stage)") }
        let urls = op.downloadIDs.compactMap { c.ledger.record($0)?.source.asURL?.lastPathComponent }
        XCTAssertEqual(urls, ["clip2.mp4"], "the format shown is the format fetched"); _ = clip
        // Failed join: picture exists, the sound does not.
        let (v, _) = try await publishSeparateTracks("ext-half")
        let ghost = url("/media/ext-half/does-not-exist.m4a")
        let half = NormalizedMediaSource(title: "H", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([rep(.video, v, "mp4", height: 120), rep(.audio, ghost, "m4a")]))
        let j = SourceSaveOperation(source: half, choice: .joined, name: "Half join", coordinator: c, profileTag: "t", origin: .user); j.start()
        let r = await finishSource(j)
        if case .failed = r {} else { XCTFail("\(r)") }
        for id in j.downloadIDs { if let path = c.ledger.record(id)?.file.destinationPath { XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the first half was removed: \(path)") } }
    }

    func testExtractorFormatsThatCannotBeFetchedFailVisiblyNotSilently() async throws {
        // The stand-in points at files that were never published: the extraction succeeds, the transfer does not, and the operation says so.
        let src = try await extractorSource("ext-gone", "muxed")
        let op = SourceSaveOperation(source: src, choice: .original, name: "Gone", coordinator: c, profileTag: "t", origin: .user); op.start()
        let r = await finishSource(op)
        if case .failed(let why) = r { XCTAssertFalse(why.isEmpty) } else { XCTFail("listing a format is not a download: \(r)") }
    }

    func testMatrixMissingExpiredAndUnsafeSourcesAreRefusedWithReasons() {
        func fails(_ s: NormalizedMediaSource, _ expected: NormalizedFailure) { XCTAssertThrowsError(try s.validate()) { XCTAssertEqual($0 as? NormalizedFailure, expected) } }
        fails(NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([])), .noMedia)
        let past = Date(timeIntervalSinceNow: -5)
        fails(NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([NormalizedRepresentation(role: .muxed, url: URL(string: "https://x.org/a.mp4")!, container: "mp4", expires: past)])), .expired)
        fails(NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([NormalizedRepresentation(role: .muxed, url: URL(string: "https://x.org/t.jpg")!, container: "jpg")])), .notMedia("a picture"))
        fails(NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([NormalizedRepresentation(role: .muxed, url: URL(string: "http://192.168.1.4/a.mp4")!, container: "mp4")])), .unsafeAddress("192.168.1.4"))
        // A provider's identity does not matter: the same plain file from any provider passes.
        for p in [MediaProviderID.youtube, .instagram, .reddit, .vimeo, .generic] {
            XCTAssertNoThrow(try NormalizedMediaSource(title: "", provider: p, pageHost: nil, isPrivate: false, shape: .tracks([NormalizedRepresentation(role: .muxed, url: URL(string: "https://cdn.example/a.mp4")!, container: "mp4")])).validate(), "\(p)")
        }
        // WebM is carried as it is; joining or taking sound from it is listed unavailable, with the reason, not invented.
        let webm = NormalizedMediaSource(title: "", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([NormalizedRepresentation(role: .video, url: URL(string: "https://x.org/v.webm")!, container: "webm", height: 1080), NormalizedRepresentation(role: .audio, url: URL(string: "https://x.org/a.webm")!, container: "webm")]))
        // Without the optional media processing tool (stated explicitly: the answer must not depend on whether it happens to be installed on this Mac).
        let off = DownloadPlanner.options(for: webm, encoders: (true, true), processing: false)
        XCTAssertEqual(off.first { $0.option.title.hasPrefix("Picture only") }?.option.title, "Picture only · 1080p · WEBM", "a WebM picture cannot be joined with WebM sound by the system engine; it is offered on its own")
        XCTAssertNil(off.first { $0.option.title.hasPrefix("Picture only") }?.option.unavailableReason)
        XCTAssertEqual(off.first { $0.option.title.hasPrefix("Video with sound") }?.option.unavailableReason, DownloadPlanner.needsProcessingTool, "joining is listed, unavailable, and says what it needs")
        XCTAssertNotNil(off.first { $0.option.kind == .audioMP3 }?.option.unavailableReason)
        // With it, the join is carried out by the tool (no codecs are declared here, so it goes into Matroska, which holds anything).
        let on = DownloadPlanner.options(for: webm, encoders: (true, true), processing: true)
        XCTAssertEqual(on.first { $0.option.title.hasPrefix("Video with sound") }?.choice, .joinedFFmpeg(container: "mkv"))
    }

    /// A download started from a page list in a private tab is private in the ledger (never in history); one from a normal tab is not.
    func testPageListedDownloadFromAPrivateTabIsPrivateInTheLedger() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18766/media/private-check/a.bin"))
        let priv = try XCTUnwrap(c.scheduleDownload(url: url, at: Date.distantFuture, origin: .page, isPrivate: true))
        let normal = try XCTUnwrap(c.scheduleDownload(url: url, at: Date.distantFuture, origin: .page))
        XCTAssertEqual(c.ledger.record(priv)?.isPrivate, true)
        XCTAssertEqual(c.ledger.record(normal)?.isPrivate, false)
        c.cancel(priv); c.cancel(normal)
    }

    /// Audio only: the stream's own audio saved as an M4A, with no picture, validated with the system reader.
    func testAudioOnlyChoiceMakesAnM4AWithNoPicture() async throws {
        let master = try await publishHLS("dx8-m4a")
        let manifest = try await c.media.inspect(master)
        let audio = try XCTUnwrap(manifest.audios.first(where: \.isDownloadable))
        let choice = MediaChoice(video: nil, audio: audio.id, subtitles: [], extraAudios: [])
        XCTAssertTrue(manifest.problems(with: choice).isEmpty)
        let plan = try await c.media.plan(for: manifest, selection: choice, title: "Audio only", allowFallback: false, fallbacks: [], sourceURL: master)
        XCTAssertEqual(plan.outputExtension, "m4a")
        let id = try await c.media.add(plan, name: "Audio only", source: master)
        let record = await wait(id, for: [.completed, .failed], seconds: 60)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let file = try output(record)
        XCTAssertEqual(file.pathExtension, "m4a")
        let asset = AVURLAsset(url: file)
        let v = try await asset.loadTracks(withMediaType: .video).count, a = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(v, 0); XCTAssertEqual(a, 1)
        let length = try await asset.load(.duration).seconds
        XCTAssertEqual(length, 4, accuracy: 1.0)
        keep(file, as: "hls-audio-only-m4a")
    }

    func testAnHLSDiscontinuityKeepsBothHalvesInOrder() async throws {
        let p = "dx8-disc"
        try await putTrack(p, "v", video); try await putTrack(p, "a", audio)
        func list(_ t: FixtureTrack) -> String {
            var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"init.mp4\"\n"
            for half in 0..<2 {
                if half == 1 { s += "#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init.mp4\"\n" }
                for (i, d) in t.durations.enumerated() { s += "#EXTINF:\(String(format: "%.5f", d)),\nseg\(i).m4s\n" }
            }
            return s + "#EXT-X-ENDLIST\n"
        }
        try await put("\(p)/v/index.m3u8", text: list(video)); try await put("\(p)/a/index.m3u8", text: list(audio))
        try await put("\(p)/master.m3u8", text: "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",LANGUAGE=\"en\",DEFAULT=YES,URI=\"a/index.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=160x120,CODECS=\"avc1.42c01e,mp4a.40.2\",AUDIO=\"aud\"\nv/index.m3u8\n")
        let (_, record, _) = try await download(url("/media/\(p)/master.m3u8"), name: "Discontinuity")
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let file = try output(record)
        let asset = AVURLAsset(url: file)
        let length = try await asset.load(.duration).seconds
        let videoCount = try await asset.loadTracks(withMediaType: .video).count, audioCount = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(length, 8, accuracy: 1.0, "both halves, one after the other")
        XCTAssertEqual(videoCount, 1); XCTAssertEqual(audioCount, 1)
        try await assertInSync(file)
        // The second half is really the picture of the second half: a frame near the end can be drawn.
        let gen = AVAssetImageGenerator(asset: asset)
        let image = try await gen.image(at: CMTime(seconds: 6.5, preferredTimescale: 600)).image
        XCTAssertEqual(image.width, MediaFixtureFactory.width)
        keep(file, as: "hls-discontinuity")
    }

    func testSegmentedWebVTTWithATimestampMapIsPutOnOneClockWithoutRepeats() async throws {
        let p = "dx8-vtt"
        _ = try await publishHLS(p)
        try await put("\(p)/s/0.vtt", text: "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n00:00:00.500 --> 00:00:01.500\nHello\n\n00:00:01.800 --> 00:00:02.500\nLong cue\n")
        try await put("\(p)/s/1.vtt", text: "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:990000,LOCAL:00:00:00.000\n\n00:00:00.800 --> 00:00:01.500\nLong cue\n\n00:00:02.000 --> 00:00:02.500\nWorld\n")
        try await put("\(p)/s/index.m3u8", text: "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:2,\n0.vtt\n#EXTINF:2,\n1.vtt\n#EXT-X-ENDLIST\n")
        try await put("\(p)/master.m3u8", text: """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="a/index.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="s/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=160x120,CODECS="avc1.42c01e,mp4a.40.2",AUDIO="aud",SUBTITLES="subs"
        v/index.m3u8
        """)
        let (_, record, manifest) = try await download(url("/media/\(p)/master.m3u8"), name: "Subbed", request: .init(subtitleLanguages: ["en"]))
        XCTAssertEqual(manifest.subtitles.count, 1)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let file = try output(record)
        let side = file.deletingLastPathComponent().appendingPathComponent("Subbed.en.vtt")
        let text = try String(contentsOf: side, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "WEBVTT").count, 2)
        XCTAssertEqual(text.components(separatedBy: "Long cue").count, 2, "the cue HLS repeats in the next segment is written once")
        XCTAssertTrue(text.contains("00:00:00.500 --> 00:00:01.500\nHello"))
        XCTAssertTrue(text.contains("00:00:03.000 --> 00:00:03.500\nWorld"), text)
        XCTAssertEqual(record?.engineMetadata["mediaSubtitleFiles"], "Subbed.en.vtt")
        try await assertPlayable(file)
        keep(file, as: "hls-subtitled"); keep(side, as: "hls-subtitled-en")
    }

    // MARK: DASH: periods, timeline, subtitles

    func testDASHWithTwoPeriodsAndANegativeRepeatPlaysAsOneFile() async throws {
        let p = "dx8-periods"
        for n in ["p1", "p2"] { try await putTrack(p, "\(n)v", video); try await putTrack(p, "\(n)a", audio) }
        let vd = ms(video.durations[0])
        func period(_ n: String, start: String) -> String {
            """
            <Period id="\(n)" start="\(start)" duration="\(seconds(video))">
              <AdaptationSet mimeType="video/mp4" codecs="avc1.42c01e" width="160" height="120">
                <SegmentTemplate timescale="1000" startNumber="0" initialization="\(n)v/init.mp4" media="\(n)v/seg$Number$.m4s"><SegmentTimeline><S t="0" d="\(vd)" r="-1"/></SegmentTimeline></SegmentTemplate>
                <Representation id="v1" bandwidth="800000"/>
              </AdaptationSet>
              <AdaptationSet mimeType="audio/mp4" lang="en" codecs="mp4a.40.2">
                <SegmentTemplate timescale="1000" startNumber="0" initialization="\(n)a/init.mp4" media="\(n)a/seg$Number$.m4s"><SegmentTimeline>\(timeline(audio))</SegmentTimeline></SegmentTemplate>
                <Representation id="a1" bandwidth="64000"/>
              </AdaptationSet>
            </Period>
            """
        }
        let total = video.durations.reduce(0, +) * 2
        try await put("\(p)/manifest.mpd", text: """
        <?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT\(String(format: "%.3f", total))S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011">
        \(period("p1", start: "PT0S"))\(period("p2", start: seconds(video)))
        </MPD>
        """)
        let (_, record, manifest) = try await download(url("/media/\(p)/manifest.mpd"), name: "Periods")
        XCTAssertNil(manifest.unsupported); XCTAssertEqual(manifest.videos[0].segments.count, video.segments.count * 2); XCTAssertEqual(MediaParts.expand(manifest.videos[0]).count, 2)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let file = try output(record)
        let length = try await AVURLAsset(url: file).load(.duration).seconds
        XCTAssertEqual(length, total, accuracy: 1.0)
        try await assertInSync(file)
        try await assertPlays(file)
        keep(file, as: "dash-two-periods")
    }

    func testDASHRepresentationsPickedByPolicyAndTTMLBecomesAVTTFile() async throws {
        let p = "dx8-dash"
        try await putTrack(p, "v", video); try await putTrack(p, "v2", video); try await putTrack(p, "a", audio)
        try await put("\(p)/subs/fr.xml", text: #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="00:00:01.000" end="00:00:02.000">Bonjour</p></div></body></tt>"#)
        try await put("\(p)/manifest.mpd", text: """
        <?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="\(seconds(video))">
         <Period>
          <AdaptationSet mimeType="video/mp4" codecs="avc1.42c01e" width="160" height="120">
            <SegmentTemplate timescale="1000" startNumber="0" initialization="v/init.mp4" media="v/seg$Number$.m4s"><SegmentTimeline>\(timeline(video))</SegmentTimeline></SegmentTemplate>
            <Representation id="hi" bandwidth="800000" width="160" height="120"/>
          </AdaptationSet>
          <AdaptationSet mimeType="video/mp4" codecs="avc1.42c01e">
            <SegmentTemplate timescale="1000" startNumber="0" initialization="v2/init.mp4" media="v2/seg$Number$.m4s"><SegmentTimeline>\(timeline(video))</SegmentTimeline></SegmentTemplate>
            <Representation id="lo" bandwidth="200000" width="80" height="60"/>
          </AdaptationSet>
          <AdaptationSet mimeType="audio/mp4" lang="en" codecs="mp4a.40.2"><Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
            <SegmentTemplate timescale="1000" startNumber="0" initialization="a/init.mp4" media="a/seg$Number$.m4s"><SegmentTimeline>\(timeline(audio))</SegmentTimeline></SegmentTemplate>
            <Representation id="a1" bandwidth="64000"/>
          </AdaptationSet>
          <AdaptationSet contentType="text" mimeType="application/ttml+xml" lang="fr"><Representation id="fr" bandwidth="1"><BaseURL>subs/fr.xml</BaseURL></Representation></AdaptationSet>
         </Period>
        </MPD>
        """)
        let (_, record, manifest) = try await download(url("/media/\(p)/manifest.mpd"), name: "Policy", request: .init(quality: .lowest, subtitleLanguages: ["fr"]))
        XCTAssertEqual(manifest.videos.count, 2); XCTAssertEqual(manifest.subtitles.count, 1)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let file = try output(record)
        let size = try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first?.load(.naturalSize)
        XCTAssertEqual(size?.width, CGFloat(MediaFixtureFactory.width), "the lowest advertised bitrate was taken (the fixture's two pictures are the same size; the lowest representation's files were fetched)")
        let hit = await hits()
        XCTAssertGreaterThan(hit["\(p)/v2/seg0.m4s"] ?? 0, 0); XCTAssertNil(hit["\(p)/v/seg0.m4s"], "the higher representation was not fetched")
        let text = try String(contentsOf: file.deletingLastPathComponent().appendingPathComponent("Policy.fr.vtt"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("WEBVTT")); XCTAssertTrue(text.contains("00:00:01.000 --> 00:00:02.000\nBonjour"))
        try await assertPlayable(file)
        keep(file, as: "dash-policy")
    }

    // MARK: Order, progress, integrity, resume

    func testTracksAreFetchedSideBySideAndShowTheirOwnProgress() async throws {
        let master = try await publishHLS("dx8-order")
        let log = OrderLog(), gate = AsyncGate()
        MediaDownloader.beforeFetch = { stream, index in log.add("\(stream):\(index)"); if stream == 0, index == 3 { await gate.wait() } }
        defer { MediaDownloader.beforeFetch = nil }
        let manifest = try await c.media.inspect(master)
        let plan = try await c.media.plan(for: manifest, selection: manifest.defaultSelection(), title: "Order")
        let id = try await c.media.add(plan, name: "Order", source: master)
        for _ in 0..<200 where (c.media.live(id)?.done ?? 0) < 6 { try await Task.sleep(for: .milliseconds(30)) }
        let line = c.media.trackProgress(id)
        XCTAssertTrue(line?.contains("Audio (en)") == true && line?.contains(" of ") == true, line ?? "nil")
        MediaDownloader.beforeFetch = nil; await gate.open()
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let order = log.all
        XCTAssertLessThan(order.firstIndex(of: "1:0") ?? Int.max, order.firstIndex(of: "0:3") ?? 0, "the audio begins before the picture has finished")
        XCTAssertTrue(Set(order.prefix(3)).isSuperset(of: ["0:-1", "1:-1"]), "initialization segments are asked for first")
    }

    func testAnErrorPageServedAsASegmentIsNotAccepted() async throws {
        let master = try await publishHLS("dx8-html")
        try await put("dx8-html/v/seg1.m4s", text: "<html><body>Access denied by the CDN</body></html>")
        let (_, record, _) = try await download(master, name: "Denied")
        XCTAssertEqual(record?.state, .failed)
        XCTAssertTrue(record?.failure?.reason.contains("not what it should be") == true, record?.failure?.reason ?? "")
        XCTAssertEqual(visibleFiles(), [], "nothing is presented as the result")
    }

    func testAKeptSegmentThatWasChangedIsFetchedAgainOnResume() async throws {
        let master = try await publishHLS("dx8-tamper")
        let gate = AsyncGate()
        MediaDownloader.beforeFetch = { stream, index in if stream == 0, index == 3 { await gate.wait() } }
        defer { MediaDownloader.beforeFetch = nil }
        let manifest = try await c.media.inspect(master)
        let plan = try await c.media.plan(for: manifest, selection: manifest.defaultSelection(), title: "Tamper")
        let id = try await c.media.add(plan, name: "Tamper", source: master)
        for _ in 0..<200 where (c.media.live(id)?.done ?? 0) < 5 { try await Task.sleep(for: .milliseconds(30)) }
        c.pause(id)
        MediaDownloader.beforeFetch = nil; await gate.open()
        _ = await wait(id, for: [.paused])
        let dir = MediaStore.folder(profile: c.ledger.profile, task: id)
        let kept = MediaStore.segmentFile(in: dir, stream: 0, index: 1)
        var bytes = try Data(contentsOf: kept)
        bytes[bytes.count / 2] ^= 0xFF                                  // one byte changed; the size is exactly what it was
        try bytes.write(to: kept)
        let before = await hits()["dx8-tamper/v/seg1.m4s"] ?? 0
        c.resume(id)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let after = await hits()["dx8-tamper/v/seg1.m4s"] ?? 0
        XCTAssertEqual(after, before + 1, "the changed segment was fetched again; a file is not trusted for having the right size")
        try await assertPlayable(try output(record))
    }

    func testAMissingFolderAndAJournalOfGarbageDoNotCrashAResume() async throws {
        let master = try await publishHLS("dx8-garbage")
        let gate = AsyncGate()
        MediaDownloader.beforeFetch = { stream, index in if stream == 0, index == 3 { await gate.wait() } }
        defer { MediaDownloader.beforeFetch = nil }
        let manifest = try await c.media.inspect(master)
        let plan = try await c.media.plan(for: manifest, selection: manifest.defaultSelection(), title: "Garbage")
        let id = try await c.media.add(plan, name: "Garbage", source: master)
        for _ in 0..<200 where (c.media.live(id)?.done ?? 0) < 5 { try await Task.sleep(for: .milliseconds(30)) }
        c.pause(id)
        MediaDownloader.beforeFetch = nil; await gate.open()
        _ = await wait(id, for: [.paused])
        let dir = MediaStore.folder(profile: c.ledger.profile, task: id)
        try Data("{not json\n\u{0}\u{1}garbage\n".utf8).write(to: MediaStore.journalFile(in: dir))
        c.resume(id)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, "a journal nobody can read just means everything is fetched again: \(record?.failure?.reason ?? "")")
    }

    // MARK: Expiry, fallback

    /// A presentation whose segment links carry a signature; `bad` makes the server refuse them (as an expired signature is), `dropLast` makes it a different presentation.
    func publishSigned(_ p: String, bad: Bool, dropLast: Bool = false) async throws -> URL {
        for (dir, t) in [("v", video!), ("a", audio!)] {
            try await put("\(p)/\(dir)/init.mp4", t.initData)
            for (i, seg) in t.segments.enumerated() { try await put("\(p)/\(dir)/seg\(i).m4s", seg) }
            var list = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"init.mp4\"\n"
            for (i, d) in t.durations.enumerated() where !(dropLast && i == t.durations.count - 1) {
                list += "#EXTINF:\(String(format: "%.5f", d)),\nseg\(i).m4s?token=\(bad ? "old" : "new")\(bad ? "&status=403" : "")\n"
            }
            try await put("\(p)/\(dir)/index.m3u8", text: list + "#EXT-X-ENDLIST\n")
        }
        try await put("\(p)/master.m3u8", text: "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",LANGUAGE=\"en\",DEFAULT=YES,URI=\"a/index.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=160x120,CODECS=\"avc1.42c01e,mp4a.40.2\",AUDIO=\"aud\"\nv/index.m3u8\n")
        return url("/media/\(p)/master.m3u8")
    }

    func testAnExpiredLinkIsRenewedFromTheManifestAndTheDownloadFinishes() async throws {
        let master = try await publishSigned("dx8-exp", bad: true)
        let manifest = try await c.media.inspect(master)
        let plan = try await c.media.plan(for: manifest, selection: manifest.defaultSelection(), title: "Expired", sourceURL: master)
        XCTAssertTrue(plan.streams[0].segments[0].url.contains("status=403"))
        _ = try await publishSigned("dx8-exp", bad: false)            // the page now hands out working links for the very same video
        let id = try await c.media.add(plan, name: "Expired", source: master)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(record?.engineMetadata["mediaRefreshes"], "1")
        try await assertPlayable(try output(record))
    }

    func testARenewedManifestThatIsADifferentVideoStopsTheDownloadAndKeepsThePieces() async throws {
        let master = try await publishSigned("dx8-exp2", bad: true)
        let manifest = try await c.media.inspect(master)
        let plan = try await c.media.plan(for: manifest, selection: manifest.defaultSelection(), title: "Changed", sourceURL: master)
        _ = try await publishSigned("dx8-exp2", bad: false, dropLast: true)
        let id = try await c.media.add(plan, name: "Changed", source: master)
        let record = await wait(id, for: [.failed, .completed])
        XCTAssertEqual(record?.state, .failed)
        XCTAssertTrue(record?.failure?.reason.contains("different video") == true, record?.failure?.reason ?? "")
        XCTAssertEqual(visibleFiles(), [])
        XCTAssertEqual(segmentFolders().count, 1, "what was downloaded is kept, not mixed with the new version")
    }

    func testTheQualityFallbackIsUsedOnlyWhenTheChoiceAllowsIt() async throws {
        let p = "dx8-fb"
        _ = try await publishHLS(p)
        try await put("\(p)/master.m3u8", text: """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="a/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=160x120,CODECS="avc1.42c01e,mp4a.40.2",AUDIO="aud"
        v/gone.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=80x60,CODECS="avc1.42c01e,mp4a.40.2",AUDIO="aud"
        v2/index.m3u8
        """)
        let master = url("/media/\(p)/master.m3u8")
        let manifest = try await c.media.inspect(master)
        let r = manifest.select(.init(quality: .highest))
        XCTAssertEqual(r.fallbacks.count, 1)
        do { _ = try await c.media.plan(for: manifest, selection: r.choice, title: "x", allowFallback: false); XCTFail("a different quality was used without being allowed") } catch {}
        let plan = try await c.media.plan(for: manifest, selection: r.choice, title: "x", allowFallback: true, fallbacks: r.fallbacks)
        XCTAssertEqual(plan.streams[0].height, 60)
        XCTAssertTrue(plan.warnings?.contains { $0.contains("could not be read") } == true, "the person is told")
        // Another language is never a fallback.
        let lang = manifest.select(.init(quality: .highest, audioLanguages: ["es"]))
        XCTAssertTrue(lang.notes.contains { $0.contains("es audio") })
    }
}
