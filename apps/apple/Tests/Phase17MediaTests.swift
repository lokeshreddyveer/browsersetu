import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import UniformTypeIdentifiers
@testable import Browser_Setu

// Phase 17: HLS / DASH. The media here is original: generated in the test with AVAssetWriter (H.264 video, AAC audio), cut into fragmented-MP4 segments, and served by the local
// fixture server (port 18766). Nothing is downloaded from the internet.

// MARK: - Original media

final class SegmentCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var initData: Data?
    private(set) var segments: [(data: Data, duration: Double)] = []
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }
        if segmentType == .initialization { initData = segmentData }
        else { segments.append((segmentData, segmentReport?.trackReports.first?.duration.seconds ?? 1)) }
    }
}

struct FixtureTrack {
    var initData: Data
    var segments: [Data]
    var durations: [Double]
}

enum MediaFixtureFactory {
    static let width = 160, height = 120

    private static func writer(_ collector: SegmentCollector) -> AVAssetWriter {
        let w = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        w.outputFileTypeProfile = .mpeg4AppleHLS
        w.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        w.initialSegmentStartTime = .zero
        w.delegate = collector
        return w
    }

    static func video(seconds: Int) async throws -> FixtureTrack {
        let collector = SegmentCollector(), w = writer(collector)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 10, AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        w.add(input)
        guard w.startWriting() else { throw w.error ?? NSError(domain: "fixture", code: 1) }
        w.startSession(atSourceTime: .zero)
        for i in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "fixture", code: 2) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw NSError(domain: "fixture", code: 3) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { row[x * 4] = UInt8((x + i * 7) % 256); row[x * 4 + 1] = UInt8((y * 2 + i * 3) % 256); row[x * 4 + 2] = UInt8((i * 11) % 256); row[x * 4 + 3] = 255 }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 10)) else { throw w.error ?? NSError(domain: "fixture", code: 4) }
        }
        input.markAsFinished()
        await w.finishWriting()
        guard w.status == .completed, let initData = collector.initData else { throw w.error ?? NSError(domain: "fixture", code: 5) }
        return FixtureTrack(initData: initData, segments: collector.segments.map(\.data), durations: collector.segments.map(\.duration))
    }

    static func audio(seconds: Int) async throws -> FixtureTrack {
        let collector = SegmentCollector(), w = writer(collector)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        input.expectsMediaDataInRealTime = false
        w.add(input)
        guard w.startWriting() else { throw w.error ?? NSError(domain: "fixture", code: 10) }
        w.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let frames = 4410
        for chunk in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var samples = [Int16](repeating: 0, count: frames)
            for n in 0..<frames { samples[n] = Int16(8000 * sin(2 * Double.pi * 440 * Double(chunk * frames + n) / 44100)) }
            var block: CMBlockBuffer?
            let length = frames * 2
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let block else { throw NSError(domain: "fixture", code: 11) }
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format!, sampleCount: frames,
                                                                 presentationTimeStamp: CMTime(value: Int64(chunk * frames), timescale: 44100), packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample, input.append(sample) else { throw w.error ?? NSError(domain: "fixture", code: 12) }
        }
        input.markAsFinished()
        await w.finishWriting()
        guard w.status == .completed, let initData = collector.initData else { throw w.error ?? NSError(domain: "fixture", code: 13) }
        return FixtureTrack(initData: initData, segments: collector.segments.map(\.data), durations: collector.segments.map(\.duration))
    }

    /// Cached: building it takes a moment, and nothing changes it.
    nonisolated(unsafe) static var cachedVideo: FixtureTrack?
    nonisolated(unsafe) static var cachedAudio: FixtureTrack?
    static func tracks() async throws -> (video: FixtureTrack, audio: FixtureTrack) {
        if cachedVideo == nil { cachedVideo = try await video(seconds: 4) }
        if cachedAudio == nil { cachedAudio = try await audio(seconds: 4) }
        return (cachedVideo!, cachedAudio!)
    }
}

// MARK: - Test base

@MainActor
class MediaCase: XCTestCase {
    static let port = 18766
    var root: URL!, folder: URL!, downloads: URL!
    var savedOverride: URL?
    var c: DownloadCoordinator!
    var video: FixtureTrack!, audio: FixtureTrack!
    var videoTrack: FixtureTrack { video! }

    override func setUp() async throws {
        try await super.setUp()
        let reachable = (try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(Self.port)/")!)) != nil
        XCTAssertTrue(reachable, "the download fixture server is not running on port \(Self.port): run these tests through the BrowserSetuMac scheme")
        guard reachable else { throw XCTSkip("fixture server not running") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("phase17-\(UUID().uuidString)")
        folder = root.appendingPathComponent("store")
        downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
        MediaDownloader.backoffScale = 0.02
        c = makeCoordinator()
        _ = try? await get("/_media_reset")
        (video, audio) = try await MediaFixtureFactory.tracks()
    }

    override func tearDown() async throws {
        MediaDownloader.beforeFetch = nil
        MediaDownloader.backoffScale = 1
        if let c {
            for (id, record) in c.ledger.records where !record.state.isFinal && record.state != .failed { c.cancel(id) }
            // Whatever a test left holding a connection (a task to an unreachable host, say) gives it back: the budget is shared by every test in the process.
            for id in c.ledger.records.keys { ConnectionBudget.shared.release(task: id) }
        }
        try? await Task.sleep(for: .milliseconds(200))
        if let folder { DownloadTaskStore.close(folder: folder) }
        if let root { try? FileManager.default.removeItem(at: root) }
        DownloadCoordinator.directoryOverride = savedOverride
        try await super.tearDown()
    }

    func makeCoordinator() -> DownloadCoordinator {
        let coordinator = DownloadCoordinator()
        coordinator.profileName = "default"
        coordinator.store = folder
        coordinator.hasHost = { true }
        return coordinator
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(Self.port)\(path)")! }
    func get(_ path: String) async throws -> Data { try await URLSession(configuration: .ephemeral).data(from: url(path)).0 }
    func put(_ path: String, _ data: Data) async throws {
        var r = URLRequest(url: url("/_media/\(path)")); r.httpMethod = "PUT"
        _ = try await URLSession(configuration: .ephemeral).upload(for: r, from: data)
    }
    func put(_ path: String, text: String) async throws { try await put(path, Data(text.utf8)) }
    func hits() async -> [String: Int] {
        guard let data = try? await get("/_media_hits"), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json["hits"] as? [String: Int] ?? [:]
    }
    func lastHeaders(_ key: String) async -> [String: String] {
        guard let data = try? await get("/_media_hits"), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = json["headers"] as? [String: [String: String]] else { return [:] }
        return all[key] ?? [:]
    }

    /// Uploads an HLS presentation: a master with two video variants and two audio renditions, and the media playlists and segments they name. Returns the master's address.
    @discardableResult
    func publishHLS(_ p: String = "hls", extraSegmentTag: String = "", failSegment: Int? = nil, failCount: Int = 0) async throws -> URL {
        func mediaPlaylist(_ t: FixtureTrack, segPrefix: String) -> String {
            var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n\(extraSegmentTag)#EXT-X-MAP:URI=\"init.mp4\"\n"
            for (i, d) in t.durations.enumerated() {
                s += "#EXTINF:\(String(format: "%.5f", d)),\n\(segPrefix)\(i).m4s\(failSegment == i ? "?fail=\(failCount)" : "")\n"
            }
            return s + "#EXT-X-ENDLIST\n"
        }
        for (dir, track) in [("v", video!), ("v2", video!), ("a", audio!), ("a2", audio!)] {
            try await put("\(p)/\(dir)/init.mp4", track.initData)
            for (i, seg) in track.segments.enumerated() { try await put("\(p)/\(dir)/seg\(i).m4s", seg) }
            try await put("\(p)/\(dir)/index.m3u8", text: mediaPlaylist(track, segPrefix: "seg"))
        }
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="a/index.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Spanish",LANGUAGE="es",DEFAULT=NO,URI="a2/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=160x120,CODECS="avc1.42c01e,mp4a.40.2",AUDIO="aud"
        v/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=80x60,CODECS="avc1.42c01e,mp4a.40.2",AUDIO="aud"
        v2/index.m3u8
        """
        try await put("\(p)/master.m3u8", text: master)
        return url("/media/\(p)/master.m3u8")
    }

    func wait(_ id: UUID, for states: Set<DownloadState>, seconds: Double = 60) async -> DownloadTaskRecord? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let r = c.ledger.record(id), states.contains(r.state) { return r }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return c.ledger.record(id)
    }

    /// Inspects, plans with the default choice (or `choice`), and starts.
    func start(_ master: URL, name: String = "Clip", choice: ((MediaManifest) -> MediaChoice)? = nil) async throws -> UUID {
        let manifest = try await c.media.inspect(master)
        let plan = try await c.media.plan(for: manifest, selection: choice?(manifest) ?? manifest.defaultSelection(), title: name)
        return try await c.media.add(plan, name: name, source: master)
    }

    func segmentFolders() -> [String] {
        let root = downloads.appendingPathComponent(".Browser Setu Media")
        guard let tags = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return tags.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent($0).path)) ?? [] }
    }
    func visibleFiles() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted() }

    /// The file really is media: tracks, a length, a frame that can be drawn.
    func assertPlayable(_ media: URL, video wantsVideo: Bool = true, audio wantsAudio: Bool = true, seconds: Double = 4, file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: media)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "the system can play it", file: file, line: line)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, seconds, accuracy: 0.6, "the length of the original", file: file, line: line)
        let v = try await asset.loadTracks(withMediaType: .video), a = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(!v.isEmpty, wantsVideo, "video track", file: file, line: line)
        XCTAssertEqual(!a.isEmpty, wantsAudio, "audio track", file: file, line: line)
        if wantsVideo {
            let gen = AVAssetImageGenerator(asset: asset); gen.appliesPreferredTrackTransform = true
            let image = try await gen.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image
            XCTAssertEqual(image.width, MediaFixtureFactory.width, "a frame of the original size can be decoded", file: file, line: line)
        }
    }
}

// MARK: - Parsing (no network)

final class HLSParserTests: XCTestCase {
    let base = URL(string: "https://cdn.example.com/show/master.m3u8")!

    func testAMasterListsVariantsAndRenditionsWithRelativeAddressesResolved() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="audio/en.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="English",LANGUAGE="en",URI="subs/en.m3u8"
        #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="c",NAME="CC",INSTREAM-ID="CC1"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="a"
        720/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="a"
        /abs/1080/index.m3u8
        """
        let m = try HLSParser.parse(text, base: base)
        XCTAssertEqual(m.format, .hls)
        XCTAssertEqual(m.videos.map(\.height), [1080, 720], "sorted best first")
        XCTAssertEqual(m.videos[0].playlistURL, "https://cdn.example.com/abs/1080/index.m3u8")
        XCTAssertEqual(m.videos[1].playlistURL, "https://cdn.example.com/show/720/index.m3u8")
        XCTAssertEqual(m.videos[0].kind, .video, "its sound is a separate stream")
        XCTAssertEqual(m.audios.map(\.language), ["en"])
        XCTAssertEqual(m.subtitles.count, 1)
        XCTAssertEqual(m.videos[0].codecs, "avc1.640028,mp4a.40.2")
        XCTAssertEqual(m.videos[0].resolutionText, "1920×1080")
        XCTAssertNil(m.unsupported)
        XCTAssertEqual(m.defaultSelection().video, m.videos[0].id)
        XCTAssertEqual(m.defaultSelection().audio, m.audios[0].id)
    }

    func testAMediaPlaylistGivesInitSegmentByteRangesAndDiscontinuities() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:1000@720
        media.mp4
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:2000
        media.mp4
        #EXT-X-DISCONTINUITY
        #EXTINF:2.5,
        other/seg.m4s
        #EXT-X-ENDLIST
        """
        let s = try HLSParser.parseStream(text, base: base, label: "x")
        XCTAssertNil(s.unsupported)
        XCTAssertEqual(s.container, .fragmentedMP4)
        XCTAssertEqual(s.initSegment?.offset, 0); XCTAssertEqual(s.initSegment?.length, 720)
        XCTAssertEqual(s.segments.count, 3)
        XCTAssertEqual(s.segments[0].offset, 720); XCTAssertEqual(s.segments[0].length, 1000)
        XCTAssertEqual(s.segments[1].offset, 1720, "an omitted offset continues where the previous range ended"); XCTAssertEqual(s.segments[1].length, 2000)
        XCTAssertTrue(s.segments[2].discontinuity)
        XCTAssertNil(s.segments[2].offset)
        XCTAssertEqual(s.segments[2].url, "https://cdn.example.com/show/other/seg.m4s")
        XCTAssertEqual(s.duration ?? 0, 10.5, accuracy: 0.001)
    }

    func testLiveAndEncryptedPlaylistsAreRefusedWithAReason() throws {
        let live = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"i.mp4\"\n#EXTINF:4,\ns1.m4s\n#EXTINF:4,\ns2.m4s\n"
        XCTAssertTrue(try HLSParser.parse(live, base: base).unsupported?.hasPrefix("Live") == true)
        let aes = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\ns1.ts\n#EXT-X-ENDLIST\n"
        XCTAssertTrue(try HLSParser.parseStream(aes, base: base, label: "x").unsupported?.contains("Encrypted") == true)
        let sample = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://x\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n#EXTINF:4,\ns1.ts\n#EXT-X-ENDLIST\n"
        XCTAssertNotNil(try HLSParser.parseStream(sample, base: base, label: "x").unsupported)
        let none = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:4,\ns1.ts\n#EXT-X-ENDLIST\n"
        XCTAssertNil(try HLSParser.parseStream(none, base: base, label: "x").unsupported, "METHOD=NONE is not encryption")
        let masterKey = "#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"skd://x\"\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n"
        XCTAssertNotNil(try HLSParser.parse(masterKey, base: base).unsupported)
    }

    func testMalformedAndUnsafePlaylistsAreRefused() {
        XCTAssertThrowsError(try HLSParser.parse("<html>nope</html>", base: base))
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXT-X-ENDLIST\n", base: base, label: "x"), "no segments")
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\ns1.ts\n#EXT-X-ENDLIST\n", base: base, label: "x"), "an address with no duration")
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXTINF:abc,\ns1.ts\n#EXT-X-ENDLIST\n", base: base, label: "x"))
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXTINF:4,\nfile:///etc/passwd\n#EXT-X-ENDLIST\n", base: base, label: "x"), "only http(s) is ever followed")
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXTINF:4,\ndata:text/plain,hi\n#EXT-X-ENDLIST\n", base: base, label: "x"))
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXTINF:4,\nhttp://cdn.example.com/s.ts\n#EXT-X-ENDLIST\n", base: base, label: "x"), "a secure playlist does not hand over to an insecure address")
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n", base: base, label: "x"), "a playlist that points at another master playlist is not followed")
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXT-X-MAP:BYTERANGE=\"1@0\"\n#EXTINF:4,\ns.m4s\n#EXT-X-ENDLIST\n", base: base, label: "x"))
    }

    func testBoundsStopAHugePlaylist() {
        var many = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"i.mp4\"\n"
        for i in 0...MediaLimits.maxSegmentsPerStream { many += "#EXTINF:1,\ns\(i).m4s\n" }
        XCTAssertThrowsError(try HLSParser.parseStream(many + "#EXT-X-ENDLIST\n", base: base, label: "x")) { XCTAssertEqual($0 as? MediaError, .tooManySegments) }
        XCTAssertThrowsError(try HLSParser.parse(String(repeating: "#EXTM3U\n", count: MediaLimits.maxManifestBytes / 8 + 10), base: base)) { XCTAssertEqual($0 as? MediaError, .tooLarge) }
        var variants = "#EXTM3U\n"
        for i in 0...MediaLimits.maxStreams { variants += "#EXT-X-STREAM-INF:BANDWIDTH=\(i)\nv\(i).m3u8\n" }
        XCTAssertThrowsError(try HLSParser.parse(variants, base: base))
        let reference = String(repeating: "a", count: MediaLimits.maxURLLength + 1)
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXTINF:4,\n\(reference).m4s\n#EXT-X-ENDLIST\n", base: base, label: "x"))
    }

    func testTransportStreamsAndWebVTTAreRecognised() throws {
        let ts = try HLSParser.parseStream("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:4,\ns0.ts\n#EXT-X-ENDLIST\n", base: base, label: "x")
        XCTAssertEqual(ts.container, .mpegTS); XCTAssertNil(ts.unsupported)
        let vtt = try HLSParser.parseStream("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:4,\ns0.vtt\n#EXT-X-ENDLIST\n", base: base, label: "x")
        XCTAssertEqual(vtt.container, .webVTT)
        let noInit = try HLSParser.parseStream("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:4,\ns0.m4s\n#EXT-X-ENDLIST\n", base: base, label: "x")
        XCTAssertNotNil(noInit.unsupported, "fragments with no initialization segment cannot be played")
    }

    func testAttributesHandleQuotedCommas() {
        let a = HLSParser.attributes("BANDWIDTH=100,CODECS=\"avc1.4d401f,mp4a.40.2\",NAME=\"a=b\"")
        XCTAssertEqual(a["CODECS"], "avc1.4d401f,mp4a.40.2"); XCTAssertEqual(a["NAME"], "a=b"); XCTAssertEqual(a["BANDWIDTH"], "100")
    }
}

final class DASHParserTests: XCTestCase {
    let base = URL(string: "https://cdn.example.com/dash/manifest.mpd")!
    func mpd(_ body: String, attrs: String = "type=\"static\" mediaPresentationDuration=\"PT10S\"") -> Data {
        Data("<?xml version=\"1.0\"?><MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" \(attrs)>\(body)</MPD>".utf8)
    }

    func testTimelineAndNumberTemplatesBecomeSegmentLists() throws {
        let body = """
        <Period><BaseURL>media/</BaseURL>
        <AdaptationSet mimeType="video/mp4" codecs="avc1.4d401f" width="1280" height="720">
          <SegmentTemplate timescale="1000" initialization="$RepresentationID$/init.mp4" media="$RepresentationID$/t$Time$.m4s">
            <SegmentTimeline><S t="0" d="4000" r="1"/><S d="2000"/></SegmentTimeline></SegmentTemplate>
          <Representation id="v1" bandwidth="1500000"/></AdaptationSet>
        <AdaptationSet mimeType="audio/mp4" lang="en" codecs="mp4a.40.2">
          <Representation id="a1" bandwidth="64000"><SegmentTemplate timescale="1" duration="5" startNumber="1" initialization="a/init.mp4" media="a/s$Number%03d$.m4s"/></Representation></AdaptationSet>
        </Period>
        """
        let m = try DASHParser.parse(mpd(body), base: base)
        XCTAssertNil(m.unsupported)
        let v = try XCTUnwrap(m.videos.first)
        XCTAssertEqual(v.segments.map(\.url), ["https://cdn.example.com/dash/media/v1/t0.m4s", "https://cdn.example.com/dash/media/v1/t4000.m4s", "https://cdn.example.com/dash/media/v1/t8000.m4s"])
        XCTAssertEqual(v.initSegment?.url, "https://cdn.example.com/dash/media/v1/init.mp4")
        XCTAssertEqual(v.segments.map(\.duration), [4, 4, 2])
        XCTAssertEqual(v.height, 720); XCTAssertEqual(v.container, .fragmentedMP4)
        let a = try XCTUnwrap(m.audios.first)
        XCTAssertEqual(a.segments.map(\.url), ["https://cdn.example.com/dash/media/a/s001.m4s", "https://cdn.example.com/dash/media/a/s002.m4s"])
        XCTAssertEqual(a.language, "en")
        XCTAssertEqual(m.duration ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(m.defaultSelection().audio, a.id)
    }

    func testWhatIsNotSupportedIsSaidPlainly() throws {
        XCTAssertTrue(try DASHParser.parse(mpd("<Period/>", attrs: "type=\"dynamic\""), base: base).unsupported?.hasPrefix("Live") == true)
        // DX-08: several periods are read now (see DX08DASHTests); a manifest of periods with nothing in them still says plainly that there is nothing to download.
        let two = try DASHParser.parse(mpd("<Period id=\"1\"/><Period id=\"2\"/>"), base: base)
        XCTAssertNotNil(two.unsupported)
        let drm = try DASHParser.parse(mpd("""
        <Period><AdaptationSet mimeType="video/mp4"><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
        <SegmentTemplate timescale="1" duration="5" initialization="i.mp4" media="s$Number$.m4s"/><Representation id="v" bandwidth="1"/></AdaptationSet></Period>
        """), base: base)
        XCTAssertNotNil(drm.unsupported, "protected media is refused as a whole")
        XCTAssertTrue(drm.videos.allSatisfy { !$0.isDownloadable })
        let list = try DASHParser.parse(mpd("""
        <Period><AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1"><SegmentList duration="5"><SegmentURL media="a.m4s"/></SegmentList></Representation></AdaptationSet></Period>
        """), base: base)
        // DX-08: SegmentList is read now (see DX08DASHTests).
        XCTAssertEqual(list.videos.first?.segments.count, 1)
    }

    func testXMLCannotDefineEntitiesOrLoadAnything() {
        let bomb = Data("""
        <?xml version="1.0"?><!DOCTYPE MPD [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]><MPD type="static"><Period>&b;</Period></MPD>
        """.utf8)
        XCTAssertThrowsError(try DASHParser.parse(bomb, base: base))
        let external = Data("<?xml version=\"1.0\"?><!DOCTYPE MPD SYSTEM \"file:///etc/passwd\"><MPD type=\"static\"><Period/></MPD>".utf8)
        XCTAssertThrowsError(try DASHParser.parse(external, base: base))
        XCTAssertThrowsError(try DASHParser.parse(Data("<MPD><Period></MPD>".utf8), base: base), "not well-formed")
        XCTAssertThrowsError(try DASHParser.parse(Data("<html/>".utf8), base: base))
        XCTAssertThrowsError(try DASHParser.parse(Data(count: MediaLimits.maxManifestBytes + 1), base: base))
        var deep = "<MPD type=\"static\">"; for _ in 0..<(MediaLimits.maxXMLDepth + 5) { deep += "<X>" }
        XCTAssertThrowsError(try DASHParser.parse(Data((deep).utf8), base: base), "nesting is bounded")
    }

    func testBoundsAndUnsafeAddresses() {
        let huge = """
        <Period><AdaptationSet mimeType="video/mp4"><SegmentTemplate timescale="1" initialization="i.mp4" media="s$Time$.m4s"><SegmentTimeline><S t="0" d="1" r="\(MediaLimits.maxSegmentsPerStream + 5)"/></SegmentTimeline></SegmentTemplate>
        <Representation id="v" bandwidth="1"/></AdaptationSet></Period>
        """
        XCTAssertThrowsError(try DASHParser.parse(mpd(huge), base: base)) { XCTAssertEqual($0 as? MediaError, .tooManySegments) }
        let unsafe = "<Period><BaseURL>file:///etc/</BaseURL><AdaptationSet mimeType=\"video/mp4\"><Representation id=\"v\" bandwidth=\"1\"/></AdaptationSet></Period>"
        XCTAssertThrowsError(try DASHParser.parse(mpd(unsafe), base: base))
        let unknownVariable = """
        <Period><AdaptationSet mimeType="video/mp4"><SegmentTemplate timescale="1" duration="5" initialization="i.mp4" media="$Bogus$.m4s"/><Representation id="v" bandwidth="1"/></AdaptationSet></Period>
        """
        XCTAssertThrowsError(try DASHParser.parse(mpd(unknownVariable), base: base))
    }

    func testISODurations() {
        XCTAssertEqual(DASHParser.isoDuration("PT1H2M3.5S"), 3723.5)
        XCTAssertEqual(DASHParser.isoDuration("PT30S"), 30)
        XCTAssertEqual(DASHParser.isoDuration("P1DT1H"), 90000)
        XCTAssertNil(DASHParser.isoDuration("1:00")); XCTAssertNil(DASHParser.isoDuration("PT5")); XCTAssertNil(DASHParser.isoDuration("PTxS")); XCTAssertNil(DASHParser.isoDuration(nil))
    }

    func testTheKindOfManifestComesFromItsContent() {
        XCTAssertEqual(MediaManifestReader.sniff(Data("#EXTM3U\n".utf8)), .hls)
        XCTAssertEqual(MediaManifestReader.sniff(Data("<?xml version=\"1.0\"?><MPD/>".utf8)), .dash)
        XCTAssertNil(MediaManifestReader.sniff(Data("<html></html>".utf8)))
    }
}

// MARK: - The engine, against real segments

@MainActor
final class MediaEngineIntegrationTests: MediaCase {
    func testAnOriginalHLSStreamDownloadsToOnePlayableMP4() async throws {
        let master = try await publishHLS()
        let manifest = try await c.media.inspect(master)
        XCTAssertEqual(manifest.videos.count, 2); XCTAssertEqual(manifest.audios.count, 2)
        XCTAssertEqual(try? segmentFolders().count, 0, "inspecting fetched only the manifest and made nothing")
        let before = await hits()
        XCTAssertNil(before["hls/v/seg0.m4s"], "no media was fetched to show the choices")

        let id = try await start(master)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let file = try XCTUnwrap(record?.file.destinationPath.map { URL(fileURLWithPath: $0) })
        XCTAssertEqual(file.pathExtension, "mp4")
        try await assertPlayable(file)

        let after = await hits()
        XCTAssertEqual(after["hls/v/seg0.m4s"], 1); XCTAssertEqual(after["hls/a/seg3.m4s"], 1)
        XCTAssertNil(after["hls/v2/seg0.m4s"], "the other quality was not downloaded")
        XCTAssertNil(after["hls/a2/seg0.m4s"], "the other language was not downloaded")
        XCTAssertEqual(segmentFolders(), [], "the working folder is gone")
        XCTAssertEqual(visibleFiles(), [file.lastPathComponent], "one file, not a folder of segments")
        XCTAssertEqual(record?.protocolID, .media)
    }

    func testTheChosenQualityAndLanguageAreWhatIsDownloaded() async throws {
        let master = try await publishHLS("pick")
        let id = try await start(master, name: "Small Spanish") { m in
            MediaChoice(video: m.videos.last!.id, audio: m.audios.first(where: { $0.language == "es" })!.id)
        }
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let after = await hits()
        XCTAssertEqual(after["pick/v2/seg0.m4s"], 1); XCTAssertEqual(after["pick/a2/seg0.m4s"], 1)
        XCTAssertNil(after["pick/v/seg0.m4s"]); XCTAssertNil(after["pick/a/seg0.m4s"])
        XCTAssertEqual(record?.file.filename, "Small Spanish.mp4")
        try await assertPlayable(URL(fileURLWithPath: record!.file.destinationPath!))
    }

    func testASegmentThatFailsOnceIsRetriedAndTheDownloadStillCompletes() async throws {
        let master = try await publishHLS("flaky", failSegment: 1, failCount: 2)
        let id = try await start(master)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let after = await hits()
        XCTAssertGreaterThanOrEqual(after["flaky/v/seg1.m4s"] ?? 0, 3, "two refusals, then success")
        try await assertPlayable(URL(fileURLWithPath: record!.file.destinationPath!))
    }

    func testAPermanentErrorFailsWithAReasonAndLeavesNothingBehind() async throws {
        let master = try await publishHLS("gone")
        _ = try await get("/_media_reset")                                  // the media vanishes after the manifest was read
        try await put("gone/master.m3u8", text: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=160x120\nv/index.m3u8\n")
        try await put("gone/v/index.m3u8", text: "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:1,\nseg0.m4s\n#EXT-X-ENDLIST\n")
        let id = try await start(master)
        let record = await wait(id, for: [.failed, .completed])
        XCTAssertEqual(record?.state, .failed)
        XCTAssertNotNil(record?.failure?.reason)
        XCTAssertEqual(visibleFiles(), [], "no partial file is presented")
        XCTAssertEqual(segmentFolders(), [], "a failure that cannot be retried cleans up")
    }

    func testPauseKeepsTheSegmentsAndResumeFetchesOnlyTheRest() async throws {
        let master = try await publishHLS("pause")
        let gate = AsyncGate()
        MediaDownloader.beforeFetch = { stream, index in if stream == 0, index == 3 { await gate.wait() } }
        let id = try await start(master)
        for _ in 0..<200 where (c.media.live(id)?.done ?? 0) < 4 { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertGreaterThanOrEqual(c.media.live(id)?.done ?? 0, 4)
        XCTAssertTrue(c.canPause(id))
        c.pause(id)
        MediaDownloader.beforeFetch = nil
        await gate.open()
        let paused = await wait(id, for: [.paused])
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertEqual(segmentFolders().count, 1, "what was fetched is kept")
        XCTAssertEqual(visibleFiles(), [])
        let firstRound = await hits()
        c.resume(id)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let second = await hits()
        XCTAssertEqual(second["pause/v/seg0.m4s"], firstRound["pause/v/seg0.m4s"], "a finished segment is not fetched again")
        try await assertPlayable(URL(fileURLWithPath: record!.file.destinationPath!))
        XCTAssertEqual(segmentFolders(), [])
    }

    func testARelaunchGoesOnFromTheKeptSegments() async throws {
        let master = try await publishHLS("relaunch")
        let gate = AsyncGate()
        MediaDownloader.beforeFetch = { stream, index in if stream == 0, index == 3 { await gate.wait() } }
        let id = try await start(master)
        for _ in 0..<200 where (c.media.live(id)?.done ?? 0) < 4 { try await Task.sleep(for: .milliseconds(30)) }
        c.pause(id)
        MediaDownloader.beforeFetch = nil
        await gate.open()
        _ = await wait(id, for: [.paused])
        let firstRound = await hits()
        c.ledger.flush()
        DownloadTaskStore.close(folder: folder)

        c = makeCoordinator()                                       // a new launch, same profile and folders
        let item = try XCTUnwrap(c.interrupted[id], "the paused download is listed again")
        XCTAssertEqual(item.filename, "Clip.mp4")
        c.resume(id)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let second = await hits()
        XCTAssertEqual(second["relaunch/v/seg0.m4s"], firstRound["relaunch/v/seg0.m4s"])
        try await assertPlayable(URL(fileURLWithPath: record!.file.destinationPath!))
    }

    func testCancelRemovesTheWorkingFolderAndLeavesNoFile() async throws {
        let master = try await publishHLS("cancel")
        let gate = AsyncGate()
        MediaDownloader.beforeFetch = { stream, index in if stream == 0, index == 2 { await gate.wait() } }
        let id = try await start(master)
        for _ in 0..<200 where (c.media.live(id)?.done ?? 0) < 2 { try await Task.sleep(for: .milliseconds(30)) }
        c.cancel(id)
        MediaDownloader.beforeFetch = nil
        await gate.open()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(segmentFolders(), [])
        XCTAssertEqual(visibleFiles(), [])
        XCTAssertNotEqual(c.ledger.record(id)?.state, .completed)
    }

    func testAnExistingFileIsNeverOverwritten() async throws {
        try Data("precious".utf8).write(to: downloads.appendingPathComponent("Clip.mp4"))
        let master = try await publishHLS("keep")
        let id = try await start(master)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("Clip.mp4")), "precious")
        XCTAssertNotEqual(record?.file.destinationPath, downloads.appendingPathComponent("Clip.mp4").path)
        try await assertPlayable(URL(fileURLWithPath: record!.file.destinationPath!))
    }

    func testStreamingDownloadsShareThePlaceLimitWithEveryOtherDownload() async throws {
        c.maxConcurrent = 1
        let master = try await publishHLS("queue")
        let gate = AsyncGate()
        MediaDownloader.beforeFetch = { stream, index in if stream == 0, index == 1 { await gate.wait() } }
        let first = try await start(master, name: "One")
        let manifest = try await c.media.inspect(master)
        let plan = try await c.media.plan(for: manifest, selection: manifest.defaultSelection(), title: "Two")
        let secondTask = Task { try await c.media.add(plan, name: "Two", source: master) }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(c.ledger.record(first)?.state, .running)
        XCTAssertEqual(c.active.count, 1, "one place, one download")
        MediaDownloader.beforeFetch = nil
        await gate.open()
        let second = try await secondTask.value
        let a = await wait(first, for: [.completed, .failed]), b = await wait(second, for: [.completed, .failed], seconds: 90)
        XCTAssertEqual(a?.state, .completed); XCTAssertEqual(b?.state, .completed, b?.failure?.reason ?? "")
    }

    func testAFinishedDownloadCarriesWhatTheInspectorShows() async throws {
        let master = try await publishHLS("meta")
        let id = try await start(master)
        let tracks = c.ledger.record(id)?.engineMetadata["mediaTracks"]
        XCTAssertEqual(tracks, "160×120, 800 kbit/s + Audio (en)")
        XCTAssertEqual(c.ledger.record(id)?.engineMetadata["mediaSegments"], String(video.segments.count + audio.segments.count + 2), "every segment and both initialization segments")
        _ = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(c.ledger.record(id)?.transfer.resumeAvailable, false)
    }
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if isOpen { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

// MARK: - DASH, byte ranges, other containers

@MainActor
final class MediaFormatsIntegrationTests: MediaCase {
    func publishDASH(_ p: String = "dash") async throws -> URL {
        for (dir, track) in [("v", video!), ("a", audio!)] {
            try await put("\(p)/\(dir)/init.mp4", track.initData)
            for (i, seg) in track.segments.enumerated() { try await put("\(p)/\(dir)/seg\(i).m4s", seg) }
        }
        func timeline(_ t: FixtureTrack) -> String { t.durations.map { "<S d=\"\(Int(($0 * 1000).rounded()))\"/>" }.joined() }
        let mpd = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT4S" minBufferTime="PT1S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011">
          <Period>
            <AdaptationSet mimeType="video/mp4" codecs="avc1.42c01e" width="160" height="120">
              <SegmentTemplate timescale="1000" startNumber="0" initialization="v/init.mp4" media="v/seg$Number$.m4s"><SegmentTimeline>\(timeline(video))</SegmentTimeline></SegmentTemplate>
              <Representation id="v1" bandwidth="800000"/>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4" lang="en" codecs="mp4a.40.2">
              <SegmentTemplate timescale="1000" startNumber="0" initialization="a/init.mp4" media="a/seg$Number$.m4s"><SegmentTimeline>\(timeline(audio))</SegmentTimeline></SegmentTemplate>
              <Representation id="a1" bandwidth="64000"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        try await put("\(p)/manifest.mpd", text: mpd)
        return url("/media/\(p)/manifest.mpd")
    }

    func testAnOriginalDASHStreamDownloadsToOnePlayableMP4() async throws {
        let mpd = try await publishDASH()
        let manifest = try await c.media.inspect(mpd)
        XCTAssertEqual(manifest.format, .dash); XCTAssertEqual(manifest.videos.count, 1); XCTAssertEqual(manifest.audios.count, 1)
        let id = try await start(mpd, name: "Dash clip")
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let file = URL(fileURLWithPath: record!.file.destinationPath!)
        XCTAssertEqual(file.pathExtension, "mp4")
        try await assertPlayable(file)
        XCTAssertEqual(segmentFolders(), [])
    }

    func testByteRangeSegmentsAreRequestedAsRangesFromOneFile() async throws {
        var whole = video.initData, ranges: [(Int, Int)] = []
        for seg in video.segments { ranges.append((whole.count, seg.count)); whole.append(seg) }
        try await put("br/media.mp4", whole)
        var list = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"media.mp4\",BYTERANGE=\"\(video.initData.count)@0\"\n"
        for (i, r) in ranges.enumerated() { list += "#EXTINF:\(video.durations[i]),\n#EXT-X-BYTERANGE:\(r.1)@\(r.0)\nmedia.mp4\n" }
        try await put("br/index.m3u8", text: list + "#EXT-X-ENDLIST\n")
        let id = try await start(url("/media/br/index.m3u8"), name: "Ranged")
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let header = (await lastHeaders("br/media.mp4"))["range"]
        XCTAssertTrue(header?.hasPrefix("bytes=") == true, "a segment that is part of a file is asked for as a part")
        try await assertPlayable(URL(fileURLWithPath: record!.file.destinationPath!), audio: false)
    }

    func testAServerThatIgnoresARangeIsRefusedNotAccepted() async throws {
        try await put("ign/media.mp4", Data(repeating: 1, count: 5000))
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: .user), network: DownloadNetworkSetup())
        // ?status=200 answers the whole thing with 200 for a ranged request.
        let seg = MediaSegment(url: url("/media/ign/media.mp4?status=200").absoluteString, offset: 0, length: 100, duration: 1)
        do { _ = try await fetcher.segment(seg, to: root.appendingPathComponent("x.seg")); XCTFail("accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("x.seg").path))
    }

    func testATransportStreamIsKeptInOrderAsDotTSAndSaidToBeOne() async throws {
        func packets(_ n: UInt8) -> Data { var d = Data(); for i in 0..<4 { var p = [UInt8](repeating: n &+ UInt8(i), count: 188); p[0] = 0x47; d.append(contentsOf: p) }; return d }
        var list = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for i in 0..<3 { try await put("ts/s\(i).ts", packets(UInt8(i * 10))); list += "#EXTINF:2,\ns\(i).ts\n" }
        try await put("ts/index.m3u8", text: list + "#EXT-X-ENDLIST\n")
        let id = try await start(url("/media/ts/index.m3u8"), name: "Transport")
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let file = URL(fileURLWithPath: record!.file.destinationPath!)
        XCTAssertEqual(file.pathExtension, "ts")
        XCTAssertEqual(try Data(contentsOf: file), packets(0) + packets(10) + packets(20), "segments joined in playlist order, byte for byte")
        XCTAssertTrue(c.ledger.record(id)?.engineMetadata["mediaNote"]?.contains("not an MP4") == true)
    }

    func testWebVTTSubtitlesDownloadAsOneFileWithOneHeader() async throws {
        let cues = ["WEBVTT\n\n00:00.000 --> 00:01.000\nOne\n", "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n00:01.000 --> 00:02.000\nTwo\n"]
        var list = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for (i, c) in cues.enumerated() { try await put("vtt/s\(i).vtt", text: c); list += "#EXTINF:1,\ns\(i).vtt\n" }
        try await put("vtt/en.m3u8", text: list + "#EXT-X-ENDLIST\n")
        try await put("vtt/master.m3u8", text: "#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"s\",NAME=\"English\",LANGUAGE=\"en\",URI=\"en.m3u8\"\n")
        let m = try await c.media.inspect(url("/media/vtt/master.m3u8"))
        XCTAssertEqual(m.subtitles.count, 1)
        let plan = try await c.media.plan(for: m, selection: MediaChoice(subtitles: [m.subtitles[0].id]), title: "Subs")
        XCTAssertEqual(plan.outputExtension, "vtt")
        let id = try await c.media.add(plan, name: "Subs", source: url("/media/vtt/master.m3u8"))
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let text = try String(contentsOfFile: record!.file.destinationPath!)
        XCTAssertEqual(text.components(separatedBy: "WEBVTT").count - 1, 1, "one header")
        XCTAssertTrue(text.contains("One") && text.contains("Two") && text.range(of: "One")!.lowerBound < text.range(of: "Two")!.lowerBound)
    }

    func testASubtitleChosenWithVideoIsSavedBesideIt() async throws {
        let master = try await publishHLS("withsubs")
        try await put("withsubs/s.vtt", text: "WEBVTT\n\n00:00.000 --> 00:01.000\nHello\n")
        try await put("withsubs/sub.m3u8", text: "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:4,\ns.vtt\n#EXT-X-ENDLIST\n")
        var text = String(decoding: try await get("/media/withsubs/master.m3u8"), as: UTF8.self)
        text = text.replacingOccurrences(of: "#EXT-X-STREAM-INF", with: "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"s\",NAME=\"English\",LANGUAGE=\"en\",URI=\"sub.m3u8\"\n#EXT-X-STREAM-INF", options: [], range: text.range(of: "#EXT-X-STREAM-INF"))
        try await put("withsubs/master.m3u8", text: text)
        let id = try await start(master, name: "Movie") { m in var s = m.defaultSelection(); s.subtitles = [m.subtitles[0].id]; return s }
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(visibleFiles(), ["Movie.en.vtt", "Movie.mp4"])
        try await assertPlayable(downloads.appendingPathComponent("Movie.mp4"))
    }
}

// MARK: - Security and protection

@MainActor
final class MediaSecurityTests: MediaCase {
    func testProtectedHLSIsRefusedBeforeAnySegmentIsFetched() async throws {
        try await put("drm/master.m3u8", text: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=160x120\nv.m3u8\n")
        try await put("drm/v.m3u8", text: "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n#EXT-X-MAP:URI=\"i.mp4\"\n#EXTINF:4,\ns0.m4s\n#EXT-X-ENDLIST\n")
        try await put("drm/s0.m4s", Data(repeating: 9, count: 100))
        let master = url("/media/drm/master.m3u8")
        let manifest = try await c.media.inspect(master)
        do { _ = try await c.media.plan(for: manifest, selection: manifest.defaultSelection(), title: "x"); XCTFail("planned a protected stream") }
        catch { XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("Encrypted") == true, "\(error)") }
        let h = await hits()
        XCTAssertNil(h["drm/s0.m4s"], "no segment was requested"); XCTAssertNil(h["drm/i.mp4"])
        XCTAssertTrue(c.ledger.records.isEmpty, "no task was made")
        XCTAssertEqual(visibleFiles(), [])
    }

    func testProtectedDASHIsRefused() async throws {
        try await put("drmd/manifest.mpd", text: """
        <MPD type="static" mediaPresentationDuration="PT4S"><Period><AdaptationSet mimeType="video/mp4"><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
        <SegmentTemplate timescale="1" duration="2" initialization="i.mp4" media="s$Number$.m4s"/><Representation id="v" bandwidth="1"/></AdaptationSet></Period></MPD>
        """)
        let m = try await c.media.inspect(url("/media/drmd/manifest.mpd"))
        XCTAssertNotNil(m.unsupported); XCTAssertFalse(m.hasDownloadableStream)
        do { _ = try await c.media.plan(for: m, selection: m.defaultSelection(), title: "x"); XCTFail() } catch {}
        let h = await hits()
        XCTAssertNil(h["drmd/s1.m4s"])
    }

    func testALiveStreamIsRefusedWithAnExplanation() async throws {
        try await put("live/index.m3u8", text: "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:100\n#EXT-X-MAP:URI=\"i.mp4\"\n#EXTINF:2,\ns100.m4s\n#EXTINF:2,\ns101.m4s\n")
        let m = try await c.media.inspect(url("/media/live/index.m3u8"))
        XCTAssertTrue(m.unsupported?.hasPrefix("Live") == true)
        do { _ = try await c.media.plan(for: m, selection: m.defaultSelection(), title: "x"); XCTFail() } catch { XCTAssertTrue("\(error)".contains("Live") || (error as? LocalizedError)?.errorDescription?.hasPrefix("Live") == true) }
    }

    func testARequestThatIsNotThePersonsOwnIsRefused() async throws {
        let master = try await publishHLS("untrusted")
        do { _ = try await c.media.inspect(master, origin: .automation); XCTFail("fetched for an untrusted origin") } catch {}
        let h = await hits()
        XCTAssertNil(h["untrusted/master.m3u8"], "nothing was requested")
    }

    func testNoCookiesOrCredentialsAreSentWithSegments() async throws {
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "session", .value: "TOPSECRET", .originURL: url("/")])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let master = try await publishHLS("cookie")
        let id = try await start(master)
        _ = await wait(id, for: [.completed, .failed])
        for key in ["cookie/master.m3u8", "cookie/v/seg0.m4s", "cookie/a/seg0.m4s", "cookie/v/index.m3u8"] {
            let headers = await lastHeaders(key)
            XCTAssertFalse(headers.isEmpty, key)
            XCTAssertNil(headers["cookie"], "\(key): no cookie"); XCTAssertNil(headers["authorization"], "\(key): no credentials")
            XCTAssertNil(headers["referer"])
        }
    }

    func testARedirectToANonWebAddressIsRefusedAndAnOrdinaryOneIsFollowed() async throws {
        try await put("redir/real.m4s", video.segments[0])
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: .user), network: DownloadNetworkSetup())
        let bad = MediaSegment(url: url("/media/redir/real.m4s?redirect=file:///etc/hosts").absoluteString, duration: 1)
        let out = root.appendingPathComponent("bad.seg")
        do { _ = try await fetcher.segment(bad, to: out); XCTFail("followed a file: redirect") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        let good = MediaSegment(url: url("/media/redir/other.m4s?redirect=" + url("/media/redir/real.m4s").absoluteString).absoluteString, duration: 1)
        let ok = root.appendingPathComponent("good.seg")
        let n = try await fetcher.segment(good, to: ok)
        XCTAssertEqual(Int(n), video.segments[0].count)
    }

    func testASignedAddressNeverAppearsInAFailureOrTheEventLog() async throws {
        try await put("sig/master.m3u8", text: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=160x120\nv.m3u8?token=SECRETVALUE\n")
        try await put("sig/v.m3u8", text: "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"i.mp4?token=SECRETVALUE\"\n#EXTINF:4,\ns0.m4s?token=SECRETVALUE&status=403\n#EXT-X-ENDLIST\n")
        try await put("sig/i.mp4", Data(repeating: 1, count: 50))
        let id = try await start(url("/media/sig/master.m3u8"))
        let record = await wait(id, for: [.failed, .completed])
        XCTAssertEqual(record?.state, .failed)
        XCTAssertFalse((record?.failure?.reason ?? "").contains("SECRETVALUE"))
        XCTAssertFalse((record?.failure?.code ?? "").contains("SECRETVALUE"))
        XCTAssertFalse(c.events.joined(separator: "\n").contains("SECRETVALUE"))
        XCTAssertFalse(c.diagnostics.contains("SECRETVALUE"))
        XCTAssertFalse(c.failures.contains { $0.reason.contains("SECRETVALUE") })
        // The ledger holds the address that was added (so a retry is possible), and the plan with the segment addresses lives only in the task's folder.
        let ledgerJSON = String(describing: record)
        XCTAssertFalse(ledgerJSON.contains("s0.m4s"), "segment addresses are not in the ledger")
    }

    func testTheWorkingFolderBelongsToItsProfile() async throws {
        let master = try await publishHLS("profile")
        let gate = AsyncGate()
        MediaDownloader.beforeFetch = { _, index in if index == 2 { await gate.wait() } }
        let id = try await start(master)
        for _ in 0..<200 where (c.media.live(id)?.done ?? 0) < 2 { try await Task.sleep(for: .milliseconds(30)) }
        // Another profile's start-up clean-up keeps nothing of this profile's, and removes none of its.
        MediaStore.sweep(profile: "someone-else", keep: [])
        XCTAssertEqual(segmentFolders().count, 1)
        XCTAssertTrue(MediaStore.folder(profile: "default", task: id).path != MediaStore.folder(profile: "someone-else", task: id).path)
        MediaStore.sweep(profile: "default", keep: [UUID()])
        XCTAssertEqual(segmentFolders(), [], "this profile's folder for a task it no longer has is removed")
        MediaDownloader.beforeFetch = nil
        await gate.open()
    }

    func testOnlyFoldersTheModuleMadeAreEverDeleted() {
        let outside = downloads.appendingPathComponent("Holiday Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        MediaStore.remove(outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertFalse(MediaStore.isTaskFolder(downloads))
        XCTAssertTrue(MediaStore.isTaskFolder(MediaStore.folder(profile: "default", task: UUID())))
    }
}

// MARK: - LinkGrabber, the preview, the inspector, retry and clean-up

@MainActor
final class MediaIntegrationTests: MediaCase {
    func testPlaylistAddressesAreRecognisedAndRoutedToThePreviewNeverStartedByThemselves() {
        for text in ["https://cdn.example.com/show/master.m3u8", "https://cdn.example.com/a/manifest.mpd?token=abc"] {
            let r = LinkClassifier.classify(text)
            XCTAssertEqual(r.kind, .streamManifest, text)
            XCTAssertFalse(r.display.contains("token"), "a signed query is never displayed")
        }
        XCTAssertEqual(LinkClassifier.classify("https://cdn.example.com/video.mp4").kind, .httpResource, "an ordinary file is unchanged")
        let s = LinkGrabberStore(profile: "p", isPrivate: false)
        s.add(text: "https://cdn.example.com/show/master.m3u8", provenance: .pasted)
        XCTAssertEqual(s.items.first?.kind.label, "Stream playlist")
        XCTAssertEqual(LinkRouter.route(s.items[0]), .mediaPreview(URL(string: "https://cdn.example.com/show/master.m3u8")!))
        s.selectAllAddable()
        var previewed: LinkRoute?
        let out = s.addSelected(to: c, openPreview: { previewed = $0 })
        XCTAssertEqual(out.started, 0, "choosing a playlist starts no transfer"); XCTAssertNotNil(out.previewed)
        XCTAssertEqual(previewed, .mediaPreview(URL(string: "https://cdn.example.com/show/master.m3u8")!))
        XCTAssertTrue(c.ledger.records.isEmpty)
    }

    func testPlaylistsFromThePrivateSessionOrYourOwnNetworkOrAProgramNeverOpenAPreview() {
        let priv = LinkGrabberStore(profile: "p", isPrivate: true)
        priv.add(text: "https://cdn.example.com/a.m3u8", provenance: .pasted); priv.selectAllAddable()
        var opened = 0
        let out = priv.addSelected(to: c, openPreview: { _ in opened += 1 })
        XCTAssertEqual(opened, 0); XCTAssertEqual(out.refused, 1)
        let local = LinkGrabberStore(profile: "p", isPrivate: false)
        local.add(text: "http://192.168.1.5/a.m3u8", provenance: .pasted)
        if case .refused = LinkRouter.route(local.items[0]) {} else { XCTFail("an address on the local network is refused from the collection") }
        let ext = LinkGrabberStore(profile: "p", isPrivate: false)
        ext.add(text: "https://cdn.example.com/a.mpd", provenance: .extensionSuggestion)
        if case .refused = LinkRouter.route(ext.items[0]) {} else { XCTFail("an extension's suggestion cannot be previewed from here") }
    }

    func testThePreviewReadsOnlyThePlaylistThenStartsOnlyTheChosenTracks() async throws {
        let master = try await publishHLS("preview")
        let model = MediaAddModel(coordinator: c, url: master, name: nil)
        XCTAssertEqual(model.name, "preview", "a generic file name (master.m3u8) is named after a more telling part of the address: here its folder")
        model.load()
        for _ in 0..<200 where model.phase == .loading { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(model.phase, .ready)
        let before = await hits()
        XCTAssertEqual(before.filter { $0.key.hasSuffix(".m4s") }.count, 0, "showing the choices fetched no media")
        XCTAssertNotNil(model.video); XCTAssertNotNil(model.audio)
        XCTAssertTrue(model.needsAudioChoice)
        model.video = model.manifest!.videos.last!.id
        model.audio = nil                                                         // video only, the lower quality
        var finished = false
        model.start { finished = true }
        for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(finished)
        let id = try XCTUnwrap(c.ledger.records.keys.first)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let after = await hits()
        XCTAssertNotNil(after["preview/v2/seg0.m4s"]); XCTAssertNil(after["preview/a/seg0.m4s"], "no audio was chosen"); XCTAssertNil(after["preview/v/seg0.m4s"])
        try await assertPlayable(URL(fileURLWithPath: record!.file.destinationPath!), audio: false)
    }

    func testThePreviewSaysWhyAProtectedOrLiveStreamCannotBeDownloaded() async throws {
        try await put("pv/live.m3u8", text: "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MAP:URI=\"i.mp4\"\n#EXTINF:2,\ns1.m4s\n")
        let model = MediaAddModel(coordinator: c, url: url("/media/pv/live.m3u8"), name: nil)
        model.load()
        for _ in 0..<200 where model.phase == .loading { try await Task.sleep(for: .milliseconds(30)) }
        guard case .failed(let why) = model.phase else { return XCTFail("expected a refusal, got \(model.phase)") }
        XCTAssertTrue(why.hasPrefix("Live"), why)
        XCTAssertFalse(model.canDownload)
        let notAPlaylist = MediaAddModel(coordinator: c, url: url("/media/pv/missing.m3u8"), name: nil)
        notAPlaylist.load()
        for _ in 0..<200 where notAPlaylist.phase == .loading { try await Task.sleep(for: .milliseconds(30)) }
        if case .failed = notAPlaylist.phase {} else { XCTFail("a missing playlist is reported") }
    }

    func testTheInspectorHasWhatItNeedsAndNothingForOtherDownloads() async throws {
        let master = try await publishHLS("insp")
        let vm = DownloadsViewModel(coordinator: c, defaults: UserDefaults(suiteName: "p17-\(UUID().uuidString)")!, changeDelay: 0, progressDelay: 5)
        let id = try await start(master)
        let info = try XCTUnwrap(vm.mediaInfo(for: id))
        XCTAssertEqual(info.format, "HLS"); XCTAssertEqual(info.tracks, "160×120, 800 kbit/s + Audio (en)")
        XCTAssertGreaterThan(info.segments, 0)
        _ = await wait(id, for: [.completed, .failed])
        XCTAssertNil(vm.mediaInfo(for: UUID()))
    }

    func testAFailedStreamIsRetriedFromTheSegmentsItKept() async throws {
        let master = try await publishHLS("retry", failSegment: 2, failCount: 3)      // three refusals in a row: every try in one run fails
        let id = try await start(master)
        let failed = await wait(id, for: [.failed, .completed], seconds: 30)
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.failure?.retryable, true)
        XCTAssertEqual(segmentFolders().count, 1, "a failure that can be retried keeps what it fetched")
        let seg0Hits = (await hits())["retry/v/seg0.m4s"]
        XCTAssertTrue(c.failures.contains { $0.id == id && $0.canRetry })
        c.retryFailure(id)
        let record = await wait(id, for: [.completed], seconds: 60)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let seg0After = (await hits())["retry/v/seg0.m4s"]
        XCTAssertEqual(seg0After, seg0Hits, "finished segments were not fetched again")
        try await assertPlayable(URL(fileURLWithPath: record!.file.destinationPath!))
    }

    func testLeftOverWorkingFoldersAreCleanedUpAtLaunchButKnownOnesAreKept() async throws {
        let master = try await publishHLS("sweep")
        let gate = AsyncGate()
        MediaDownloader.beforeFetch = { _, index in if index == 3 { await gate.wait() } }
        let id = try await start(master)
        for _ in 0..<200 where (c.media.live(id)?.done ?? 0) < 3 { try await Task.sleep(for: .milliseconds(30)) }
        c.pause(id); MediaDownloader.beforeFetch = nil; await gate.open()
        _ = await wait(id, for: [.paused])
        let orphan = MediaStore.folder(profile: "default", task: UUID())
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphan.appendingPathComponent("s0-0.seg"))
        XCTAssertEqual(segmentFolders().count, 2)
        c.ledger.flush(); DownloadTaskStore.close(folder: folder)
        c = makeCoordinator()
        XCTAssertEqual(segmentFolders(), [id.uuidString], "the orphan went; the paused download's folder stayed")
        XCTAssertNotNil(c.interrupted[id])
    }

    func testTheEngineIsDescribedHonestly() {
        let caps = DownloadEngineRegistry().capabilities(of: .media)
        XCTAssertTrue(caps.contains(.pause)); XCTAssertTrue(caps.contains(.resume))
        XCTAssertFalse(caps.contains(.enforcesSpeedLimit), "the limit is held between segments, not at the transport, so it is not claimed")
        XCTAssertFalse(caps.contains(.upload))
        XCTAssertFalse(caps.contains(.multiFile))
    }
}

// MARK: - Review fixes

final class MediaReviewFixParserTests: XCTestCase {
    let pub = URL(string: "https://cdn.example.com/a/index.m3u8")!
    func mpd(_ body: String, attrs: String = "type=\"static\" mediaPresentationDuration=\"PT10S\"") -> Data { Data("<MPD \(attrs)>\(body)</MPD>".utf8) }
    func template(_ t: String, rep: String = "<Representation id=\"v\" bandwidth=\"1\"/>") -> Data {
        mpd("<Period><AdaptationSet mimeType=\"video/mp4\">\(t)\(rep)</AdaptationSet></Period>")
    }

    func testAPlaylistOnTheInternetCannotAimTheDownloadInsideYourNetwork() {
        for target in ["http://192.168.1.1/x.m4s", "http://localhost:8080/x.m4s", "http://10.0.0.5/x.m4s", "http://[::1]/x.m4s"] {
            XCTAssertThrowsError(try MediaURL.resolve(target, against: URL(string: "http://public.example.com/a.m3u8")!), target)
        }
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"http://127.0.0.1/i.mp4\"\n#EXTINF:1,\ns.m4s\n#EXT-X-ENDLIST\n", base: URL(string: "http://public.example.com/a.m3u8")!, label: "x"))
        XCTAssertNoThrow(try MediaURL.resolve("seg.m4s", against: URL(string: "http://192.168.1.2/a.m3u8")!), "a playlist on your own network may use it")
        XCTAssertNoThrow(try MediaURL.resolve("http://192.168.1.3/seg.m4s", against: URL(string: "http://192.168.1.2/a.m3u8")!))
    }

    func testHostileNumbersAreRefusedNotTrapped() {
        let base = pub
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"i.mp4\"\n#EXTINF:1,\n#EXT-X-BYTERANGE:10@9223372036854775807\ns.m4s\n#EXT-X-ENDLIST\n", base: base, label: "x"))
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"i.mp4\"\n#EXTINF:1,\n#EXT-X-BYTERANGE:10\ns.m4s\n#EXT-X-ENDLIST\n", base: base, label: "x"), "no previous range to continue from")
        XCTAssertThrowsError(try HLSParser.parseStream("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"i.mp4\"\n#EXTINF:1,\n#EXT-X-BYTERANGE:10@-5\ns.m4s\n#EXT-X-ENDLIST\n", base: base, label: "x"))
        let b = URL(string: "https://cdn.example.com/m.mpd")!
        for t in [
            "<SegmentTemplate timescale=\"1\" initialization=\"i.mp4\" media=\"$$s$Number$.m4s\" duration=\"5\"/>",
            "<SegmentTemplate timescale=\"1\" initialization=\"i.mp4\" media=\"s$Time$.m4s\"><SegmentTimeline><S t=\"0\" d=\"1\" r=\"9223372036854775807\"/></SegmentTimeline></SegmentTemplate>",
            "<SegmentTemplate timescale=\"1\" initialization=\"i.mp4\" media=\"s$Time$.m4s\"><SegmentTimeline><S t=\"9223372036854775807\" d=\"5\" r=\"1\"/></SegmentTimeline></SegmentTemplate>",
            "<SegmentTemplate timescale=\"1\" startNumber=\"9223372036854775807\" initialization=\"i.mp4\" media=\"s$Number$.m4s\" duration=\"5\"/>",
            "<SegmentTemplate timescale=\"1\" initialization=\"i.mp4\" media=\"s$Number$.m4s\" duration=\"0.0000000001\"/>",
        ] {
            // Whatever the answer is (a refusal or a manifest that says why), it must come back rather than crash.
            _ = try? DASHParser.parse(template(t), base: b)
        }
        let m = try? DASHParser.parse(template("<SegmentTemplate timescale=\"1\" initialization=\"i.mp4\" media=\"a$$b$Number$.m4s\" duration=\"5\"/>"), base: b)
        XCTAssertEqual(m?.videos.first?.segments.first?.url, "https://cdn.example.com/a$b1.m4s", "$$ is a literal dollar")
    }

    func testOneProtectedStreamRefusesTheWholePresentation() throws {
        let b = URL(string: "https://cdn.example.com/m.mpd")!
        let m = try DASHParser.parse(mpd("""
        <Period>
        <AdaptationSet mimeType="video/mp4"><SegmentTemplate timescale="1" duration="5" initialization="v/i.mp4" media="v/s$Number$.m4s"/><Representation id="v" bandwidth="1"/></AdaptationSet>
        <AdaptationSet mimeType="audio/mp4"><ContentProtection schemeIdUri="urn:uuid:x"/><SegmentTemplate timescale="1" duration="5" initialization="a/i.mp4" media="a/s$Number$.m4s"/><Representation id="a" bandwidth="1"/></AdaptationSet>
        </Period>
        """), base: b)
        XCTAssertNotNil(m.unsupported, "clear video with protected audio is not offered as silent video")
        let nested = try DASHParser.parse(mpd("""
        <Period><AdaptationSet mimeType="video/mp4"><SegmentTemplate timescale="1" duration="5" initialization="i.mp4" media="s$Number$.m4s"/>
        <Representation id="v" bandwidth="1"><SubRepresentation level="0"><ContentProtection schemeIdUri="urn:uuid:x"/></SubRepresentation></Representation></AdaptationSet></Period>
        """), base: b)
        XCTAssertNotNil(nested.unsupported, "protection nested deeper is found")
    }

    func testAnInitializationSegmentThatChangesPartWayIsKeptInParts() throws {
        let s = try HLSParser.parseStream("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"i1.mp4\"\n#EXTINF:1,\na.m4s\n#EXT-X-MAP:URI=\"i2.mp4\"\n#EXTINF:1,\nb.m4s\n#EXT-X-ENDLIST\n", base: pub, label: "x")
        // DX-08: a changed initialization segment is no longer refused; the stream is kept in parts, each with its own (see DX08HLSTests).
        XCTAssertNil(s.unsupported)
        XCTAssertEqual(MediaParts.expand(s).count, 2)
    }

    func testAnEncodingOrPlacementThatCouldHideADocumentTypeIsRefused() {
        let b = URL(string: "https://cdn.example.com/m.mpd")!
        let late = "<?xml version=\"1.0\"?><!--" + String(repeating: "x", count: 70_000) + "--><!DOCTYPE MPD [<!ENTITY a \"b\">]><MPD type=\"static\"><Period/></MPD>"
        XCTAssertThrowsError(try DASHParser.parse(Data(late.utf8), base: b), "a declaration after a long comment is still found")
        XCTAssertThrowsError(try DASHParser.parse("<MPD type=\"static\"><Period/></MPD>".data(using: .utf16)!, base: b), "UTF-16 is refused")
    }

    func testRepeatedRepresentationIdsAcrossSetsStayDistinct() throws {
        let b = URL(string: "https://cdn.example.com/m.mpd")!
        let m = try DASHParser.parse(mpd("""
        <Period>
        <AdaptationSet mimeType="video/mp4"><SegmentTemplate timescale="1" duration="5" initialization="i.mp4" media="s$Number$.m4s"/><Representation id="1" bandwidth="5"/></AdaptationSet>
        <AdaptationSet mimeType="video/mp4"><SegmentTemplate timescale="1" duration="5" initialization="j.mp4" media="t$Number$.m4s"/><Representation id="1" bandwidth="9"/></AdaptationSet>
        </Period>
        """), base: b)
        XCTAssertEqual(Set(m.videos.map(\.id)).count, 2)
    }
}

@MainActor
final class MediaReviewFixIntegrationTests: MediaCase {
    func testABodyThatIsTooLargeIsStoppedAndLeavesNoFile() async throws {
        try await put("big/x.m4s", Data(repeating: 7, count: 200_000))
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: .user), network: DownloadNetworkSetup(), maxSegmentBytes: 50_000)
        let out = root.appendingPathComponent("big.seg")
        do { _ = try await fetcher.segment(MediaSegment(url: url("/media/big/x.m4s").absoluteString, duration: 1), to: out); XCTFail("accepted an oversize body") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: out.path + ".part"))
    }

    func testAnUnfinishedPartialFileIsNotMistakenForADoneSegment() async throws {
        let master = try await publishHLS("partial")
        let manifest = try await c.media.inspect(master)
        let plan = try await c.media.plan(for: manifest, selection: manifest.defaultSelection(), title: "x")
        let dir = root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 10).write(to: MediaStore.segmentFile(in: dir, stream: 0, index: 0).appendingPathExtension("part"))
        let dl = MediaDownloader(fetcher: try MediaFetcher(policy: HTTPRequestPolicy(origin: .user), network: DownloadNetworkSetup()), plan: plan, dir: dir, taskID: UUID(), concurrency: 2)
        XCTAssertFalse(dl.isDone(dl.items.first { $0.index == 0 && $0.stream == 0 }!))
        try await dl.run()
        XCTAssertTrue(dl.items.allSatisfy(dl.isDone))
    }

    func testWebVTTWithWindowsLineEndingsKeepsEverySegment() async throws {
        let cues = ["WEBVTT\r\n\r\n00:00.000 --> 00:01.000\r\nOne\r\n", "WEBVTT\r\n\r\n00:01.000 --> 00:02.000\r\nTwo\r\n"]
        var list = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for (i, t) in cues.enumerated() { try await put("crlf/s\(i).vtt", text: t); list += "#EXTINF:1,\ns\(i).vtt\n" }
        try await put("crlf/index.m3u8", text: list + "#EXT-X-ENDLIST\n")
        let id = try await start(url("/media/crlf/index.m3u8"), name: "Crlf")
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        let text = try String(contentsOfFile: record!.file.destinationPath!)
        XCTAssertTrue(text.contains("One") && text.contains("Two"))
        XCTAssertEqual(text.components(separatedBy: "WEBVTT").count - 1, 1)
    }

    func testDismissingAFailedStreamRemovesWhatItKept() async throws {
        let master = try await publishHLS("dismiss", failSegment: 2, failCount: 3)
        let id = try await start(master)
        let failed = await wait(id, for: [.failed, .completed], seconds: 30)
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(segmentFolders().count, 1)
        c.dismissFailure(id)
        XCTAssertEqual(segmentFolders(), [])
    }

    func testAFinishedStreamIsMarkedAsFromTheInternet() async throws {
        let master = try await publishHLS("quarantine")
        let id = try await start(master)
        let record = await wait(id, for: [.completed, .failed])
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertTrue(DownloadQuarantine.isQuarantined(URL(fileURLWithPath: record!.file.destinationPath!)))
    }

    func testTooLittleFreeSpaceStopsTheDownloadWithAReasonAndKeepsWhatItHas() async throws {
        MediaDownloader.minimumFreeSpace = Int64.max
        defer { MediaDownloader.minimumFreeSpace = 200 * 1024 * 1024 }
        let master = try await publishHLS("space")
        let id = try await start(master)
        let record = await wait(id, for: [.failed, .completed], seconds: 30)
        XCTAssertEqual(record?.state, .failed)
        XCTAssertTrue(record?.failure?.reason.contains("free space") == true)
        XCTAssertEqual(visibleFiles(), [])
    }
}
