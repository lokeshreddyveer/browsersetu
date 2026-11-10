import XCTest
import AVFoundation
@testable import Browser_Setu

/// The optional media processing tool, with the real FFmpeg and FFprobe (a minimal LGPL build made by scripts/build-ffmpeg-minimal.sh, built for the tests by the scheme) and real WebM media (six-second VP9 picture
/// and Opus sound cut from Blender's open film, Tests/Fixtures/media). Nothing is simulated: outputs are probed independently with FFprobe and, where the system can read them, with AVFoundation.
final class DrainFlag: @unchecked Sendable { var done = false }

enum RealFFmpeg {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/media", isDirectory: true)
    static var video: URL { fixtures.appendingPathComponent("bbb-6s-video.webm") }
    static var audio: URL { fixtures.appendingPathComponent("bbb-6s-audio.webm") }
    private static var manifestFile: URL?

    /// Points the tool at the locally built copy, pinned by that copy's own digest (never a committed digest), the same way the app pins the installed one.
    static func use() throws {
        let bin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ThirdParty/ffmpeg/bin", isDirectory: true)
        let dir = bin.appendingPathComponent("ffmpeg", isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("ffmpeg").path) else {
            throw NSError(domain: "RealFFmpeg", code: 1, userInfo: [NSLocalizedDescriptionKey: "ThirdParty/ffmpeg/bin/ffmpeg is missing: run scripts/build-ffmpeg-minimal.sh (the scheme does it before each run)"])
        }
        let digest = try XCTUnwrap(ManagedTool.treeDigest(of: dir))
        let m = FileManager.default.temporaryDirectory.appendingPathComponent("bs-ffmpeg-pin-\(UUID().uuidString).json")
        let json: [String: Any] = ["name": "ffmpeg", "version": "9.0.2", "sha256": "x", "sourceURL": "https://example.com/x.zip", "executable": "ffmpeg", "layout": "flat", "treeSHA256": digest, "signaturePolicy": "adhoc"]
        try JSONSerialization.data(withJSONObject: json).write(to: m)
        manifestFile = m
        FFmpegTool.tool.manifestURL = m; FFmpegTool.tool.helpersFolder = bin; FFmpegTool.tool.forgetCache()
    }
    static func reset() {
        FFmpegTool.tool.manifestURL = nil; FFmpegTool.tool.helpersFolder = nil; FFmpegTool.tool.forgetCache()
        if let m = manifestFile { try? FileManager.default.removeItem(at: m) }
    }
}

@MainActor
final class FFmpegProcessingTests: XCTestCase {
    var work: URL!
    var programs: FFmpegTool.Programs!

    override func setUp() async throws {
        try RealFFmpeg.use()
        let found = await FFmpegTool.programs()
        programs = try XCTUnwrap(found, "the media processing tool verifies against its pin")
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-ff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work); RealFFmpeg.reset() }

    /// The fixture's own length, read with the tool, so outputs are compared with their input and not with a number typed here.
    func inputLength(audioOnly: Bool = false) throws -> Double {
        let r = try runProbe(audioOnly ? RealFFmpeg.audio : RealFFmpeg.video)
        return r
    }
    func runProbe(_ url: URL) throws -> Double {
        let p = Process(); p.executableURL = programs.ffprobe; p.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; try p.run(); p.waitUntilExit()
        return Double(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    func leftovers() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).filter { $0.hasSuffix(".partial") || $0.contains("intermediate") } }
    func rep(_ role: NormalizedRepresentation.Role, _ ext: String, codecs: String, label: Int? = nil) -> NormalizedRepresentation {
        NormalizedRepresentation(role: role, url: URL(string: "https://c.example/\(role == .video ? "v" : "a").\(ext)")!, container: ext, codecs: codecs, height: label, formatID: "\(role)-\(ext)")
    }

    // MARK: Why the tool exists

    func testTheSystemMediaEngineCannotOpenWebMAtAll() async throws {
        let asset = AVURLAsset(url: RealFFmpeg.video)
        do { _ = try await asset.load(.tracks); XCTFail("AVFoundation opened a WebM file; the processing tool may no longer be needed") } catch { /* expected: "Cannot Open" */ }
    }

    // MARK: Planning

    func testWebMPictureAndSoundAreJoinedOnlyWhenTheToolIsThereAndAreExplainedWhenItIsNot() {
        let v = rep(.video, "webm", codecs: "vp9", label: 1080), a = rep(.audio, "webm", codecs: "opus")
        let src = NormalizedMediaSource(title: "t", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([v, a]))
        let without = DownloadPlanner.options(for: src, encoders: (true, true), processing: false)
        let joinNo = without.first { $0.option.title.hasPrefix("Video with sound") }
        XCTAssertNotNil(joinNo); XCTAssertNil(joinNo?.choice, "not executable without the tool"); XCTAssertEqual(joinNo?.requiresProcessingTool, true)
        XCTAssertEqual(joinNo?.option.unavailableReason, DownloadPlanner.needsProcessingTool)
        XCTAssertNotNil(without.first { $0.option.title.hasPrefix("Picture only") }, "the picture on its own stays available")
        let with = DownloadPlanner.options(for: src, encoders: (true, true), processing: true)
        let join = with.first { $0.option.title.hasPrefix("Video with sound") }
        XCTAssertEqual(join?.choice, .joinedFFmpeg(container: "webm")); XCTAssertTrue(join?.isExecutable == true); XCTAssertEqual(join?.representation, v); XCTAssertEqual(join?.audio, a, "the exact picture and sound chosen")
        // VP9 with AAC cannot go into WebM: Matroska, still without re-encoding.
        let mixed = NormalizedMediaSource(title: "t", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([v, rep(.audio, "m4a", codecs: "mp4a.40.2")]))
        XCTAssertEqual(DownloadPlanner.options(for: mixed, encoders: (true, true), processing: true).first { $0.option.title.hasPrefix("Video with sound") }?.choice, .joinedFFmpeg(container: "mkv"))
        // Sound from WebM/Opus: M4A and MP3 go through the tool; a MP4/M4A source is untouched by it.
        let audioOnly = NormalizedMediaSource(title: "t", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([a]))
        let ao = DownloadPlanner.options(for: audioOnly, encoders: (true, true), processing: true)
        XCTAssertEqual(ao.first { $0.option.kind == .audioM4A }?.choice, .audioM4AFFmpeg); XCTAssertEqual(ao.first { $0.option.kind == .audioMP3 }?.choice, .audioMP3FFmpeg(kbps: 192))
        let aoNo = DownloadPlanner.options(for: audioOnly, encoders: (true, true), processing: false)
        XCTAssertNil(aoNo.first { $0.option.kind == .audioM4A }?.choice); XCTAssertEqual(aoNo.first { $0.option.kind == .audioM4A }?.requiresProcessingTool, true)
        let mp4 = NormalizedMediaSource(title: "t", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([rep(.video, "mp4", codecs: "avc1.640028", label: 720), rep(.audio, "m4a", codecs: "mp4a.40.2")]))
        let o = DownloadPlanner.options(for: mp4, encoders: (true, true), processing: false)
        XCTAssertEqual(o.first { $0.option.title.hasPrefix("Video with sound") }?.choice, .joined, "the system engine still does what it can do"); XCTAssertFalse(o.contains { $0.requiresProcessingTool })
        // No option for something the engines cannot make: WebM → MP4 by copy gives an unreadable file, so it is never offered.
        XCTAssertFalse(with.contains { $0.option.title.contains("MP4") })
    }

    // MARK: Operations on real media, probed independently

    func testJoinCopiesTheStreamsIntoOneValidWebMWithoutReEncoding() async throws {
        let target = work.appendingPathComponent("joined.webm")
        try await FFmpegProcessing.join(video: RealFFmpeg.video, audio: RealFFmpeg.audio, to: target, container: "webm", programs: programs) { _ in }
        let out = try await FFmpegProcessing.probe(target, programs: programs)
        XCTAssertEqual(out.video.map(\.codec), ["vp9"]); XCTAssertEqual(out.audio.map(\.codec), ["opus"], "streams copied, not re-encoded")
        XCTAssertEqual(out.video.first?.height, 240); XCTAssertEqual(try XCTUnwrap(out.duration), try inputLength(), accuracy: 0.5)
        XCTAssertTrue(out.formatNames.contains("webm") || out.formatNames.contains("matroska"))
        XCTAssertEqual(leftovers(), [], "no partial file is left")
        // The same into Matroska.
        let mkv = work.appendingPathComponent("joined.mkv")
        try await FFmpegProcessing.join(video: RealFFmpeg.video, audio: RealFFmpeg.audio, to: mkv, container: "mkv", programs: programs) { _ in }
        let mkvOut = try await FFmpegProcessing.probe(mkv, programs: programs)
        XCTAssertEqual(mkvOut.streams.count, 2)
    }

    func testAudioIsTakenFromWebMAsM4AAndTheSystemCanReadIt() async throws {
        let target = work.appendingPathComponent("a.m4a")
        try await FFmpegProcessing.extractAudio(from: RealFFmpeg.audio, to: target, kind: .m4a(kbps: 192), programs: programs) { _ in }
        let out = try await FFmpegProcessing.probe(target, programs: programs)
        let want = try inputLength(audioOnly: true)
        XCTAssertEqual(out.audio.map(\.codec), ["aac"]); XCTAssertTrue(out.video.isEmpty); XCTAssertEqual(try XCTUnwrap(out.duration), want, accuracy: 0.5)
        let asset = AVURLAsset(url: target)                                         // a second, independent reader
        let playable = try await asset.load(.isPlayable), audioTracks = try await asset.loadTracks(withMediaType: .audio).count, seconds = try await asset.load(.duration).seconds
        XCTAssertTrue(playable); XCTAssertEqual(audioTracks, 1); XCTAssertEqual(seconds, want, accuracy: 0.5)
        XCTAssertEqual(leftovers(), [])
    }

    func testMP3FromWebMGoesThroughALosslessIntermediateIntoTheAppsOwnEncoder() async throws {
        let flac = work.appendingPathComponent("i.flac"), mp3 = work.appendingPathComponent("a.mp3")
        try await FFmpegProcessing.extractAudio(from: RealFFmpeg.audio, to: flac, kind: .flac, programs: programs) { _ in }
        let flacOut = try await FFmpegProcessing.probe(flac, programs: programs)
        XCTAssertEqual(flacOut.audio.first?.channels, 2, "stereo for the encoder")
        try await MP3Encoder.encode(source: flac, to: mp3, kbps: 192)
        let out = try await FFmpegProcessing.probe(mp3, programs: programs)
        let want = try inputLength(audioOnly: true)
        XCTAssertEqual(out.audio.map(\.codec), ["mp3"]); XCTAssertEqual(try XCTUnwrap(out.duration), want, accuracy: 0.7)
        let mp3Playable = try await AVURLAsset(url: mp3).load(.isPlayable)
        XCTAssertTrue(mp3Playable)
    }

    // MARK: Failure, cancellation, limits

    func testTheToolRemovedWhileAJobWaitsFailsTheJobCleanlyAndLeavesNothing() async throws {
        // The saver resolves the programs first, then downloads; removing the tool in between must end in a plain failure, not a half-made file or a hang.
        let gone = FFmpegTool.Programs(ffmpeg: work.appendingPathComponent("gone/ffmpeg"), ffprobe: work.appendingPathComponent("gone/ffprobe"), version: "0")
        let t = work.appendingPathComponent("y.webm")
        do { try await FFmpegProcessing.join(video: RealFFmpeg.video, audio: RealFFmpeg.audio, to: t, container: "webm", programs: gone) { _ in }; XCTFail("must fail") } catch { XCTAssertNotNil(error as? LocalizedError, "\(error)") }
        do { try await FFmpegProcessing.extractAudio(from: RealFFmpeg.audio, to: work.appendingPathComponent("y.m4a"), kind: .m4a(kbps: 128), programs: gone) { _ in }; XCTFail("must fail") } catch { XCTAssertNotNil(error as? LocalizedError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path)); XCTAssertEqual(leftovers(), [])
    }

    func testRemovalWaitsForEveryRunningJobAndNoNewJobStartsMeanwhile() async throws {
        let leases = ToolLeases()
        let a = try XCTUnwrap(leases.acquire()), b = try XCTUnwrap(leases.acquire())
        XCTAssertEqual(leases.activeCount, 2)
        leases.close()
        XCTAssertNil(leases.acquire(), "a tool being removed takes no new job")
        let drained = expectation(description: "drained")
        let flag = DrainFlag()
        Task { await leases.drain(); flag.done = true; drained.fulfill() }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(flag.done, "two jobs still hold the tool")
        a.release(); a.release()      // releasing twice counts once
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(flag.done, "one job still holds the tool")
        b.release()
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(leases.activeCount, 0)
        leases.reopen()
        XCTAssertNotNil(leases.acquire(), "after removal finished the gate opens again")
        // Two overlapping removals/updates: the gate opens only when both are done.
        let two = ToolLeases(); two.close(); two.close(); two.reopen()
        XCTAssertNil(two.acquire(), "one is still going: still closed"); two.reopen(); two.reopen()
        XCTAssertNotNil(two.acquire(), "all done: open (and an extra reopen never goes below open)")
        // A job that is dropped without releasing does not block removal forever.
        let l2 = ToolLeases(); var lost: ToolLeases.Lease? = l2.acquire(); XCTAssertNotNil(lost); lost = nil; XCTAssertEqual(l2.activeCount, 0)
    }

    func testDamagedAndWrongInputsFailCleanlyAndLeaveNothingBehind() async throws {
        let bad = work.appendingPathComponent("bad.webm"); try Data(repeating: 0x41, count: 4096).write(to: bad)
        let t1 = work.appendingPathComponent("x.webm")
        do { try await FFmpegProcessing.join(video: bad, audio: RealFFmpeg.audio, to: t1, container: "webm", programs: programs) { _ in }; XCTFail() } catch { XCTAssertNotNil(error as? LocalizedError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: t1.path)); XCTAssertEqual(leftovers(), [])
        // Sound given where a picture is needed, and the reverse.
        do { try await FFmpegProcessing.join(video: RealFFmpeg.audio, audio: RealFFmpeg.audio, to: t1, container: "webm", programs: programs) { _ in }; XCTFail() } catch { XCTAssertEqual(error as? FFmpegProcessingError, .badInput("the picture file has no picture")) }
        do { try await FFmpegProcessing.extractAudio(from: RealFFmpeg.video, to: work.appendingPathComponent("n.m4a"), kind: .m4a(kbps: 128), programs: programs) { _ in }; XCTFail() } catch { XCTAssertEqual(error as? FFmpegProcessingError, .badInput("there is no sound in this file")) }
        XCTAssertEqual(leftovers(), [])
    }

    func testCancellingStopsTheToolAndRemovesTheUnfinishedFile() async throws {
        // A large PCM WAV (about 230 MB of silence) takes the tool several seconds to encode as AAC: long enough to cancel in the middle.
        let wav = work.appendingPathComponent("big.wav")
        let payload = 2 * 2 * 48_000 * 1200
        var bytes: [UInt8] = Array("RIFF".utf8)
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xff) } }
        bytes += le32(36 + payload); bytes += Array("WAVEfmt ".utf8); bytes += le32(16); bytes += le16(1); bytes += le16(2)
        bytes += le32(48_000); bytes += le32(2 * 2 * 48_000); bytes += le16(4); bytes += le16(16); bytes += Array("data".utf8); bytes += le32(payload)
        let h = Data(bytes)
        FileManager.default.createFile(atPath: wav.path, contents: nil)
        let fh = try FileHandle(forWritingTo: wav); try fh.write(contentsOf: h)
        let chunk = Data(count: 1 << 22); var left = payload; while left > 0 { let n = min(left, chunk.count); try fh.write(contentsOf: chunk.prefix(n)); left -= n }
        try fh.close()
        let flac = work.appendingPathComponent("big.m4a")
        let t = Task { try await FFmpegProcessing.extractAudio(from: wav, to: flac, kind: .m4a(kbps: 192), programs: programs) { _ in } }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        t.cancel()
        let started = Date(); _ = await t.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "cancelling ends the tool promptly")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flac.path)); XCTAssertEqual(leftovers(), [], "the unfinished file was removed")
        let running = Process(); running.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); running.arguments = ["-f", programs.ffmpeg.path]
        let pipe = Pipe(); running.standardOutput = pipe; try running.run(); running.waitUntilExit()
        XCTAssertTrue(pipe.fileHandleForReading.readDataToEndOfFile().isEmpty, "no ffmpeg process is left")
    }

    func testLeftoversOfACrashedRunAreSweptAndNothingElseIsTouched() throws {
        let fm = FileManager.default
        func make(_ n: String, old: Bool = true) throws {
            let u = work.appendingPathComponent(n); try Data("x".utf8).write(to: u)
            if old { try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: u.path) }
        }
        let deadPid: pid_t = 99_999
        try XCTSkipIf(kill(deadPid, 0) == 0, "pid in use on this machine")
        let mine = getpid()
        try make(".Clip.mp4.bsproc-\(deadPid).partial")                       // a crashed join
        try make(".Song.intermediate.bsproc-\(deadPid).flac")                 // a crashed MP3 intermediate
        try make(".Song.intermediate.bsproc-\(deadPid).flac.bsproc-\(deadPid).partial")
        try make(".Song.intermediate.bsproc-\(deadPid).1.flac")               // a name that collided before it was written
        try make(".Old.mp4.bsproc-\(mine).partial")                           // this pid, from before this launch (pid reuse)
        try make(".Live.mp4.bsproc-\(mine).partial", old: false)              // this process's own, newer than launch: in use
        try make(".Other.mp4.bsproc-1.partial")                               // launchd: alive, not ours
        try make("Movie.mp4.partial"); try make(".hidden.partial"); try make("visible.bsproc-\(deadPid).partial")   // not ours
        try fm.createDirectory(at: work.appendingPathComponent(".Dir.bsproc-\(deadPid).partial"), withIntermediateDirectories: false)
        let removed = Set(FFmpegProcessing.sweepOrphans(in: work, launchedBefore: Date().addingTimeInterval(-60)))
        XCTAssertEqual(removed, [".Clip.mp4.bsproc-\(deadPid).partial", ".Song.intermediate.bsproc-\(deadPid).flac", ".Song.intermediate.bsproc-\(deadPid).flac.bsproc-\(deadPid).partial", ".Song.intermediate.bsproc-\(deadPid).1.flac", ".Old.mp4.bsproc-\(mine).partial"])
        let left = Set(try fm.contentsOfDirectory(atPath: work.path))
        XCTAssertEqual(left, [".Live.mp4.bsproc-\(mine).partial", ".Other.mp4.bsproc-1.partial", "Movie.mp4.partial", ".hidden.partial", "visible.bsproc-\(deadPid).partial", ".Dir.bsproc-\(deadPid).partial"])
    }

    func testTheProcessingToolIsOnlyReadyWhenFFprobeStartsToo() async throws {
        let v = await FFmpegTool.tool.verifyAsync(); let manifest = try XCTUnwrap(v?.manifest)
        try await MediaToolsInstall.ffmpegLaunchCheck(programs.ffmpeg, manifest)     // the real pair, started in place
        // A folder without FFprobe, and one whose FFprobe is another program, are both refused (nothing is copied or launched from the copy: only a script stands in).
        let dir = work.appendingPathComponent("half", isDirectory: true); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try await MediaToolsInstall.ffprobeCheck(next: dir.appendingPathComponent("ffmpeg"), manifest); XCTFail("no ffprobe must be refused") }
        catch { XCTAssertTrue("\(error)".contains("wontStart"), "\(error)") }
        try "#!/bin/sh\necho 'ffprobe version 0.0.1'\n".write(to: dir.appendingPathComponent("ffprobe"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("ffprobe").path)
        do { try await MediaToolsInstall.ffprobeCheck(next: dir.appendingPathComponent("ffmpeg"), manifest); XCTFail("another FFprobe version must be refused") }
        catch { XCTAssertTrue("\(error)".contains("wontStart"), "\(error)") }
    }

    func testASoundLongerThanThePictureStillJoinsAndTheNameCannotLeaveItsFolder() async throws {
        // A copy is as long as the longer input: a 3 s picture with the 9.9 s sound is a valid 9.9 s file, not a "length" failure.
        let short = work.appendingPathComponent("short.webm")
        let p = Process(); p.executableURL = programs.ffmpeg; p.arguments = ["-v", "error", "-y", "-t", "3", "-i", RealFFmpeg.video.path, "-c", "copy", short.path]; try p.run(); p.waitUntilExit()
        let target = work.appendingPathComponent("long-sound.webm")
        try await FFmpegProcessing.join(video: short, audio: RealFFmpeg.audio, to: target, container: "webm", programs: programs) { _ in }
        let out = try await FFmpegProcessing.probe(target, programs: programs)
        XCTAssertEqual(try XCTUnwrap(out.duration), 9.9, accuracy: 0.6)
        for hostile in ["../../escape", "a/b/c", "..", "/etc/passwd", "x\u{202E}gpj", String(repeating: "é", count: 400)] {
            let safe = SourceSaveOperation.safeName(hostile)
            XCTAssertFalse(safe.contains("/")); XCTAssertNotEqual(safe, ".."); XCTAssertLessThanOrEqual(safe.utf8.count, 180); XCTAssertFalse(safe.isEmpty)
        }
    }

    func testNotEnoughRoomStopsBeforeTheToolRunsAndAnUnknownAmountCountsAsNone() async throws {
        defer { FFmpegProcessing.freeSpaceForTests = nil }
        let t = work.appendingPathComponent("x.webm")
        FFmpegProcessing.freeSpaceForTests = 1_000
        do { try await FFmpegProcessing.join(video: RealFFmpeg.video, audio: RealFFmpeg.audio, to: t, container: "webm", programs: programs) { _ in }; XCTFail() }
        catch { if case .diskSpace = (error as? FFmpegProcessingError) ?? .unavailable {} else { XCTFail("\(error)") } }
        FFmpegProcessing.freeSpaceForTests = 0
        do { try await FFmpegProcessing.extractAudio(from: RealFFmpeg.audio, to: work.appendingPathComponent("y.m4a"), kind: .m4a(kbps: 128), programs: programs) { _ in }; XCTFail("unknown free space must not be treated as plenty") }
        catch { if case .diskSpace = (error as? FFmpegProcessingError) ?? .unavailable {} else { XCTFail("\(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path)); XCTAssertEqual(leftovers(), [])
    }

    func testAMissingToolIsReportedNotPretendedAndTheContainerChoiceNeedsNoGuessing() async {
        FFmpegTool.tool.helpersFolder = URL(fileURLWithPath: "/nonexistent"); FFmpegTool.tool.forgetCache()
        let none = await FFmpegTool.programs()
        XCTAssertNil(none)
        XCTAssertEqual(FFmpegProcessingError.unavailable.errorDescription?.contains("not installed"), true)
        XCTAssertEqual(FFmpegContainerChoice.family("vp09.00.40.08"), "vp9"); XCTAssertEqual(FFmpegContainerChoice.family("av01.0.08M.08"), "av1"); XCTAssertNil(FFmpegContainerChoice.family("avc1.640028"))
    }
}

/// The whole path through the app's own pieces: the coordinator downloads the separate picture and sound from the local fixture server, the tool joins them, the result is checked and named, and the two halves are removed.
@MainActor
final class FFmpegSaveFlowTests: MediaCase {
    override func setUp() async throws { try await super.setUp(); try RealFFmpeg.use() }
    override func tearDown() async throws { RealFFmpeg.reset(); try await super.tearDown() }

    func source(_ key: String) -> NormalizedMediaSource {
        let v = NormalizedRepresentation(role: .video, url: url("/media/\(key)/v.webm"), container: "webm", codecs: "vp9", height: 240, formatID: "v")
        let a = NormalizedRepresentation(role: .audio, url: url("/media/\(key)/a.webm"), container: "webm", codecs: "opus", formatID: "a")
        return NormalizedMediaSource(title: "Fixture", provider: nil, pageHost: nil, isPrivate: false, shape: .tracks([v, a]))
    }
    func run(_ op: SourceSaveOperation, seconds: Double = 60) async throws -> VideoSaveOperation.Stage {
        op.start(); let end = Date().addingTimeInterval(seconds)
        while Date() < end, !op.stage.isFinal { try await Task.sleep(nanoseconds: 200_000_000) }
        return op.stage
    }

    func testJoinThroughTheCoordinatorProducesAValidFileAndRemovesTheHalves() async throws {
        let key = "ffj\(Int(Date().timeIntervalSince1970))"
        try await put("\(key)/v.webm", try Data(contentsOf: RealFFmpeg.video)); try await put("\(key)/a.webm", try Data(contentsOf: RealFFmpeg.audio))
        let src = source(key)
        let planned = try XCTUnwrap(DownloadPlanner.options(for: src, encoders: (true, true), processing: true).first { $0.choice == .joinedFFmpeg(container: "webm") })
        let op = SourceSaveOperation(source: src, choice: try XCTUnwrap(planned.choice), name: "Joined clip", coordinator: c, profileTag: "t", origin: .user)
        op.pickVideo = planned.representation; op.pickAudio = planned.audio
        let stage = try await run(op)
        guard case .done(let file) = stage else { return XCTFail("\(stage)") }
        let foundPrograms = await FFmpegTool.programs()
        let programs = try XCTUnwrap(foundPrograms)
        let out = try await FFmpegProcessing.probe(file, programs: programs)
        XCTAssertEqual(file.pathExtension, "webm"); XCTAssertEqual(out.video.map(\.codec), ["vp9"]); XCTAssertEqual(out.audio.map(\.codec), ["opus"]); XCTAssertEqual(try XCTUnwrap(out.duration), 9.9, accuracy: 0.6, "as long as the fixtures")
        XCTAssertEqual(op.downloadIDs.count, 2, "the picture and the sound were both real coordinator downloads")
        for id in op.downloadIDs { XCTAssertNil(c.ledger.record(id), "the two halves were removed from disk, so they no longer show as completed downloads") }
        assertOneFinalRecord(for: file, named: "Joined clip")
        let siblings = (try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)).filter { $0.contains("Joined clip") }
        XCTAssertEqual(siblings.filter { $0.contains(".video.") || $0.contains(".audio.") }.count, 0, "the downloaded halves were removed: \(siblings)")
    }

    func testAudioAsM4AAndMP3ThroughTheCoordinator() async throws {
        let key = "ffa\(Int(Date().timeIntervalSince1970))"
        try await put("\(key)/v.webm", try Data(contentsOf: RealFFmpeg.video)); try await put("\(key)/a.webm", try Data(contentsOf: RealFFmpeg.audio))
        let src = source(key)
        let foundPrograms = await FFmpegTool.programs()
        let programs = try XCTUnwrap(foundPrograms)
        for (choice, ext, codec) in [(SourceSaveOperation.Choice.audioM4AFFmpeg, "m4a", "aac"), (.audioMP3FFmpeg(kbps: 192), "mp3", "mp3")] {
            let op = SourceSaveOperation(source: src, choice: choice, name: "Sound \(ext)", coordinator: c, profileTag: "t", origin: .user)
            op.pickAudio = src.reps.first { $0.role == .audio }
            guard case .done(let file) = try await run(op) else { return XCTFail("\(op.stage)") }
            let out = try await FFmpegProcessing.probe(file, programs: programs)
            XCTAssertEqual(file.pathExtension, ext); XCTAssertEqual(out.audio.map(\.codec), [codec]); XCTAssertTrue(out.video.isEmpty); XCTAssertEqual(try XCTUnwrap(out.duration), 9.9, accuracy: 0.8, "as long as the fixture sound")
            let leftovers = (try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)).filter { $0.contains("Sound \(ext)") && !$0.hasSuffix(".\(ext)") }
            XCTAssertEqual(leftovers, [], "the downloaded source and any intermediate were removed")
            for id in op.downloadIDs { XCTAssertNil(c.ledger.record(id), "the removed source no longer shows as a completed download") }
            assertOneFinalRecord(for: file, named: "Sound \(ext)")
        }
    }

    func testAPageAddressWithASignInIsNeverPassedToTheExtractorAndProcessingHasItsOwnPlaces() async throws {
        XCTAssertThrowsError(try ExternalExtractor.arguments(for: URL(string: "https://user:secret@example.com/watch?v=1")!))
        XCTAssertThrowsError(try ExternalExtractor.arguments(for: URL(string: "https://user@example.com/watch?v=1")!))
        XCTAssertNoThrow(try ExternalExtractor.arguments(for: URL(string: "https://example.com/watch?v=1")!))
        // Probing and processing use their own process places: a probe works while the extractor's two places are taken by long runs.
        let sleeper = URL(fileURLWithPath: "/bin/sleep")
        let busy = (0..<2).map { _ in Task { try? await ExternalExtractor.run(sleeper, arguments: ["3"], timeout: 10, maxBytes: 1024) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        let found = await FFmpegTool.programs()
        let programs = try XCTUnwrap(found)
        let media = try await FFmpegProcessing.probe(RealFFmpeg.audio, programs: programs)
        XCTAssertEqual(media.audio.count, 1, "a probe is not refused while two lookups run")
        busy.forEach { $0.cancel() }
        for t in busy { _ = await t.value }          // and they have really ended (their places are given back) before the next test starts
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testRecordingAProducedFileAndRetiringRecordsOnlyTouchWhatTheyShould() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(c.recordProducedFile(dir.appendingPathComponent("missing.mp3"), source: nil, isPrivate: false), "no file, no record")
        XCTAssertNil(c.recordProducedFile(dir, source: nil, isPrivate: false), "a folder is not a download")
        let kept = dir.appendingPathComponent("Kept clip.mp3"), gone = dir.appendingPathComponent("Gone clip.webm")
        try Data("abc".utf8).write(to: kept); try Data("abcdef".utf8).write(to: gone)
        let a = try XCTUnwrap(c.recordProducedFile(kept, source: URL(string: "https://example.com/watch?v=1"), isPrivate: false))
        let b = try XCTUnwrap(c.recordProducedFile(gone, source: nil, isPrivate: true))
        XCTAssertEqual(c.ledger.record(a)?.state, .completed); XCTAssertEqual(c.ledger.record(a)?.transfer.totalBytes, 3)
        XCTAssertEqual(c.ledger.record(a)?.source.host, "example.com"); XCTAssertEqual(c.ledger.record(b)?.isPrivate, true)
        c.retireRecords([a, b])
        XCTAssertNotNil(c.ledger.record(a), "its file is still there: kept")
        XCTAssertNotNil(c.ledger.record(b), "its file is still there: kept")
        try FileManager.default.removeItem(at: gone)
        c.retireRecords([a, b])
        XCTAssertNotNil(c.ledger.record(a)); XCTAssertNil(c.ledger.record(b), "its file is gone: the record leaves the list")
    }

    /// The history agrees with the disk: exactly one completed, verified record whose destination is the real final file, with its own name and extension; no completed record points at a missing file.
    func assertOneFinalRecord(for file: URL, named name: String, line: UInt = #line) {
        let mine = c.ledger.records.values.filter { $0.file.destinationPath == file.path }
        XCTAssertEqual(mine.count, 1, "one record for the final file", line: line)
        guard let r = mine.first else { return }
        XCTAssertEqual(r.state, .completed, line: line); XCTAssertEqual(r.file.integrity, .verified, line: line)
        XCTAssertEqual(r.file.filename, file.lastPathComponent, line: line); XCTAssertTrue(r.file.filename.hasPrefix(name), r.file.filename, line: line)
        XCTAssertEqual(r.transfer.totalBytes, (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1, "its size is the file's size", line: line)
        XCTAssertNotNil(r.completedAt, line: line)
        XCTAssertNotNil(r.source.url, "the record keeps where the media came from (retry, open page, host column)", line: line)
        for url in c.completed { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the recent list names a file that is gone: \(url.lastPathComponent)", line: line) }
        for other in c.ledger.records.values where other.state == .completed {
            if let p = other.file.destinationPath { XCTAssertTrue(FileManager.default.fileExists(atPath: p), "a completed record points at a missing file: \(p)", line: line) }
        }
    }

    func testAJobThatReachesProcessingWhileTheToolIsBeingRemovedFailsCleanlyAndKeepsNoHalves() async throws {
        let key = "ffr\(Int(Date().timeIntervalSince1970))"
        try await put("\(key)/v.webm", try Data(contentsOf: RealFFmpeg.video)); try await put("\(key)/a.webm", try Data(contentsOf: RealFFmpeg.audio))
        let src = source(key)
        let op = SourceSaveOperation(source: src, choice: .joinedFFmpeg(container: "webm"), name: "Removed mid-job", coordinator: c, profileTag: "t", origin: .user)
        op.pickVideo = src.reps.first { $0.role == .video }; op.pickAudio = src.reps.first { $0.role == .audio }
        FFmpegTool.leases.close(); defer { FFmpegTool.leases.reopen() }          // removal has begun
        guard case .failed(let why) = try await run(op, seconds: 20) else { return XCTFail("\(op.stage)") }
        XCTAssertTrue(why.contains("not installed"), why)
        let siblings = (try FileManager.default.contentsOfDirectory(atPath: DownloadCoordinator.directory.path)).filter { $0.contains("Removed mid-job") }
        XCTAssertEqual(siblings.filter { !$0.contains(".video.") && !$0.contains(".audio.") }, [], "no result was made")
        XCTAssertEqual(siblings.count, 2, "the two downloaded halves are kept as ordinary downloads, so nothing already fetched is lost: \(siblings)")
        XCTAssertEqual(FFmpegTool.leases.activeCount, 0)
    }

    func testWithoutTheToolTheOperationFailsClearlyAndMakesNoFile() async throws {
        FFmpegTool.tool.helpersFolder = URL(fileURLWithPath: "/nonexistent"); FFmpegTool.tool.forgetCache()
        let key = "ffn\(Int(Date().timeIntervalSince1970))"
        let src = source(key)
        let op = SourceSaveOperation(source: src, choice: .joinedFFmpeg(container: "webm"), name: "Nope", coordinator: c, profileTag: "t", origin: .user)
        op.pickVideo = src.reps.first { $0.role == .video }; op.pickAudio = src.reps.first { $0.role == .audio }
        guard case .failed(let why) = try await run(op, seconds: 10) else { return XCTFail("\(op.stage)") }
        XCTAssertTrue(why.contains("not installed"), why); XCTAssertEqual(op.downloadIDs.count, 0, "nothing was downloaded for an operation that cannot finish")
    }
}

extension NormalizedMediaSource {
    var reps: [NormalizedRepresentation] { if case .tracks(let r) = shape { return r }; return [] }
}
