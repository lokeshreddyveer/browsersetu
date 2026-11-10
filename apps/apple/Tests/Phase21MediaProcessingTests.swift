import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import UniformTypeIdentifiers
@testable import Browser_Setu

// Phase 21: local media preview, inspection, thumbnails, remux, conversion, audio extraction, trimming, subtitles.
//
// Every file here is original and made in the test with AVAssetWriter. Video frames are flat colours whose brightness rises steadily over the clip, so "which moment is this
// frame from" can be read back from the picture; the audio is a sine tone. Outputs are checked by reading them again: tracks, codecs, length, a decoded picture, decoded sound.

func unwrapped<T>(_ value: T?, _ message: String = "unexpected nil", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { XCTFail(message, file: file, line: line); throw XCTSkip(message) }
    return value
}

// MARK: - Original media

struct LocalMovieSpec {
    var seconds = 6
    var fileType: AVFileType = .mp4
    var width = 160, height = 120
    var fps = 10
    var keyframeEvery = 10                     // frames
    var rotation: Int = 0                      // degrees clockwise stored in the track
    var audioLanguages: [String] = ["fra"]     // one AAC track each; empty means no audio
    var video = true
    var hevc = false
    var startOffset = 0.0                      // where the first sample sits on the timeline
    var faststart = true
    var subtitles: [(start: Double, duration: Double, text: String)] = []
}

enum LocalMovie {
    static func luma(_ image: CGImage) -> Double {
        var pixel: [UInt8] = [0]
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(pixel[0])
    }

    static func make(_ spec: LocalMovieSpec, at url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: spec.fileType)
        w.shouldOptimizeForNetworkUse = spec.faststart
        var videoInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if spec.video {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: spec.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: spec.keyframeEvery, AVVideoAverageBitRateKey: 800_000, AVVideoAllowFrameReorderingKey: false]])
            input.expectsMediaDataInRealTime = false
            if spec.rotation != 0 { input.transform = CGAffineTransform(rotationAngle: CGFloat(Double(spec.rotation) * .pi / 180)) }
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: spec.width, kCVPixelBufferHeightKey as String: spec.height])
            w.add(input); videoInput = input
        }
        var audioInputs: [AVAssetWriterInput] = []
        for language in spec.audioLanguages {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            input.expectsMediaDataInRealTime = false
            input.languageCode = language
            w.add(input); audioInputs.append(input)
        }
        var subInput: AVAssetWriterInput?
        var subFormat: CMFormatDescription?
        if !spec.subtitles.isEmpty {
            let extensions: [String: Any] = [
                kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
                kCMTextFormatDescriptionExtension_BackgroundColor as String: [kCMTextFormatDescriptionColor_Red as String: 0, kCMTextFormatDescriptionColor_Green as String: 0, kCMTextFormatDescriptionColor_Blue as String: 0, kCMTextFormatDescriptionColor_Alpha as String: 0],
                kCMTextFormatDescriptionExtension_DefaultTextBox as String: [kCMTextFormatDescriptionRect_Top as String: 0, kCMTextFormatDescriptionRect_Left as String: 0, kCMTextFormatDescriptionRect_Bottom as String: 0, kCMTextFormatDescriptionRect_Right as String: 0],
                kCMTextFormatDescriptionExtension_DefaultStyle as String: [
                    kCMTextFormatDescriptionStyle_StartChar as String: 0, kCMTextFormatDescriptionStyle_EndChar as String: 0, kCMTextFormatDescriptionStyle_Font as String: 1,
                    kCMTextFormatDescriptionStyle_FontFace as String: 0, kCMTextFormatDescriptionStyle_ForegroundColor as String: [kCMTextFormatDescriptionColor_Red as String: 255, kCMTextFormatDescriptionColor_Green as String: 255, kCMTextFormatDescriptionColor_Blue as String: 255, kCMTextFormatDescriptionColor_Alpha as String: 255],
                    kCMTextFormatDescriptionStyle_FontSize as String: 18],
                kCMTextFormatDescriptionExtension_HorizontalJustification as String: 0,
                kCMTextFormatDescriptionExtension_VerticalJustification as String: 0,
                kCMTextFormatDescriptionExtension_FontTable as String: [String(1): "Helvetica"]]
            CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Subtitle, mediaSubType: kCMTextFormatType_3GText, extensions: extensions as CFDictionary, formatDescriptionOut: &subFormat)
            let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: subFormat)
            input.languageCode = "eng"
            if w.canAdd(input) { w.add(input); subInput = input }
        }
        guard w.startWriting() else { throw w.error ?? NSError(domain: "fixture", code: 1) }
        let origin = CMTime(seconds: spec.startOffset, preferredTimescale: 600)
        w.startSession(atSourceTime: origin)
        // Everything is appended in step with the clock (a tenth of a second at a time): the writer interleaves its tracks and stops accepting one that runs far ahead of the others.
        precondition(spec.fps == 10, "the fixture steps in tenths of a second")
        let frames = spec.seconds * spec.fps
        var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let chunkFrames = 4410
        // Each track is fed on its own queue whenever the writer asks, the way the framework intends: feeding them one after another stalls it, because it holds back a track
        // that runs ahead of the others until they catch up.
        final class Counter: @unchecked Sendable { var n = 0 }
        func feed(_ input: AVAssetWriterInput, _ step: @escaping @Sendable () -> Bool) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.\(UUID().uuidString)")) {
                    while input.isReadyForMoreMediaData {
                        if !step() { input.markAsFinished(); c.resume(); return }
                    }
                }
            }
        }
        func audioSample(_ chunk: Int, pitch: Double) -> CMSampleBuffer? {
            var samples = [Int16](repeating: 0, count: chunkFrames)
            for k in 0..<chunkFrames { samples[k] = Int16(8000 * sin(2 * Double.pi * pitch * Double(chunk * chunkFrames + k) / 44100)) }
            var block: CMBlockBuffer?
            let length = chunkFrames * 2
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let block else { return nil }
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format!, sampleCount: chunkFrames,
                                                                 presentationTimeStamp: CMTimeAdd(origin, CMTime(value: Int64(chunk * chunkFrames), timescale: 44100)), packetDescriptions: nil, sampleBufferOut: &sample)
            return sample
        }
        let height = spec.height
        await withTaskGroup(of: Void.self) { group in
            if let input = videoInput, let adaptor {
                let counter = Counter()
                group.addTask {
                    await feed(input) {
                        let step = counter.n
                        guard step < frames, let pool = adaptor.pixelBufferPool else { return false }
                        var buffer: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                        guard let buffer else { return false }
                        CVPixelBufferLockBaseAddress(buffer, [])
                        let level = UInt8(min(255, 255 * step / max(1, frames - 1)))
                        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(level), CVPixelBufferGetBytesPerRow(buffer) * height) }
                        CVPixelBufferUnlockBaseAddress(buffer, [])
                        counter.n += 1
                        return adaptor.append(buffer, withPresentationTime: CMTimeAdd(origin, CMTime(value: Int64(step), timescale: 10)))
                    }
                }
            }
            for (n, input) in audioInputs.enumerated() {
                let counter = Counter()
                group.addTask {
                    await feed(input) {
                        let chunk = counter.n
                        guard chunk < frames, let sample = audioSample(chunk, pitch: 440.0 * Double(n + 1)) else { return false }
                        counter.n += 1
                        return input.append(sample)
                    }
                }
            }
            if let input = subInput, let subFormat {
                let counter = Counter()
                // A timed-text track states each moment, so the gaps between cues are empty samples.
                var cues: [(start: Double, duration: Double, text: String)] = []
                var cursor = 0.0
                for cue in spec.subtitles {
                    if cue.start > cursor + 0.001 { cues.append((cursor, cue.start - cursor, "")) }
                    cues.append(cue); cursor = cue.start + cue.duration
                }
                if cursor < Double(spec.seconds) - 0.001 { cues.append((cursor, Double(spec.seconds) - cursor, "")) }
                let timeline = cues
                group.addTask {
                    await feed(input) {
                        guard counter.n < timeline.count else { return false }
                        let cue = timeline[counter.n]; counter.n += 1
                        let text = Data(cue.text.utf8)
                        var payload = Data([UInt8(text.count >> 8), UInt8(text.count & 0xFF)]); payload.append(text)
                        var block: CMBlockBuffer?
                        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                        guard let block else { return false }
                        payload.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
                        var timing = CMSampleTimingInfo(duration: CMTime(seconds: cue.duration, preferredTimescale: 600), presentationTimeStamp: CMTimeAdd(origin, CMTime(seconds: cue.start, preferredTimescale: 600)), decodeTimeStamp: .invalid)
                        var size = payload.count
                        var sample: CMSampleBuffer?
                        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: subFormat, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
                        guard let sample else { return false }
                        return input.append(sample)
                    }
                }
            }
        }
        await w.finishWriting()
        guard w.status == .completed else { throw w.error ?? NSError(domain: "fixture", code: 5) }
    }

    nonisolated(unsafe) static var cache: [String: URL] = [:]
    static let cacheFolder = FileManager.default.temporaryDirectory.appendingPathComponent("phase21-fixtures-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// Built once per name and copied into each test's own folder.
    static func fixture(_ name: String, _ spec: LocalMovieSpec) async throws -> URL {
        // Keyed by the whole description, so two tests that reuse a name with different settings never share a file.
        let key = "\(name)|\(spec.seconds)|\(spec.fileType.rawValue)|\(spec.width)x\(spec.height)|\(spec.keyframeEvery)|\(spec.rotation)|\(spec.audioLanguages)|\(spec.video)|\(spec.hevc)|\(spec.startOffset)|\(spec.faststart)|\(spec.subtitles.map(\.text))"
        if let hit = cache[key], FileManager.default.fileExists(atPath: hit.path) { return hit }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let ext = spec.fileType == .mov ? "mov" : spec.fileType == .m4a ? "m4a" : "mp4"
        let folder = cacheFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).\(ext)")
        try await make(spec, at: url)
        cache[key] = url
        return url
    }
}

// MARK: - Test base

@MainActor
class MediaProcessingCase: XCTestCase {
    var root: URL!, downloads: URL!
    var service: MediaProcessingService!
    var savedOverride: URL?

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("phase21-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        savedOverride = DownloadCoordinator.directoryOverride
        DownloadCoordinator.directoryOverride = downloads
        service = MediaProcessingService(stagingRoot: downloads.appendingPathComponent(".Browser Setu Media Processing"), authorizedRoots: [downloads])
        MediaProcessingService.beforeRun = nil
        MediaProcessingService.freeSpaceOverride = nil
    }

    override func tearDown() async throws {
        service.cancelAll()
        MediaProcessingService.beforeRun = nil
        MediaProcessingService.freeSpaceOverride = nil
        DownloadCoordinator.directoryOverride = savedOverride
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    /// A copy of a fixture inside the test's Downloads folder.
    func copy(_ fixture: URL, as name: String? = nil) throws -> URL {
        let target = downloads.appendingPathComponent(name ?? fixture.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: fixture, to: target)
        return target
    }

    func hash(_ url: URL) -> String { SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined() }

    func waitFinal(_ id: UUID, seconds: Double = 90) async -> MediaJob? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let j = service.job(id), j.state.isFinal { return j }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return service.job(id)
    }

    func finalJob(_ id: UUID, seconds: Double = 90) async throws -> MediaJob { try unwrapped(await waitFinal(id, seconds: seconds)) }

    func run(_ source: URL, _ op: MediaOperation, destination: URL? = nil) async -> MediaJob? {
        let id = service.submit(source: source, operation: op, destination: destination, profileTag: "default", isPrivate: false)
        return await waitFinal(id)
    }

    func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        try await MediaThumbnailer().thumbnail(for: url, at: seconds, dimension: 64, isPrivate: true, tolerance: 0.04)
    }

    func stagingLeftovers() -> [String] {
        let staging = downloads.appendingPathComponent(".Browser Setu Media Processing")
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: staging.path) else { return [] }
        return profiles.flatMap { p in ((try? FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent(p).path)) ?? []).map { "\(p)/\($0)" } }
    }
}

// MARK: - Inspection

@MainActor
final class MediaFactsTests: MediaProcessingCase {
    func testVideoFileFacts() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let f = try await MediaFactsReader.read(src)
        XCTAssertEqual(f.container, "MP4"); XCTAssertTrue(f.isPlayable); XCTAssertFalse(f.isProtected)
        XCTAssertEqual(try XCTUnwrap(f.durationSeconds), 6, accuracy: 0.25)
        XCTAssertEqual(f.tracks.count, 2)
        let v = try XCTUnwrap(f.video.first), a = try XCTUnwrap(f.audio.first)
        XCTAssertEqual(v.codec, "H.264"); XCTAssertEqual(v.fourCC, "avc1"); XCTAssertEqual(v.width, 160); XCTAssertEqual(v.height, 120)
        XCTAssertEqual(try XCTUnwrap(v.frameRate), 10, accuracy: 0.6); XCTAssertNil(v.rotation); XCTAssertNotNil(v.bitsPerSecond)
        XCTAssertEqual(a.codec, "AAC"); XCTAssertEqual(a.channels, 1); XCTAssertEqual(a.sampleRate, 44100); XCTAssertEqual(a.language, "fra")
        XCTAssertEqual(f.fileSize, Int64((try FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int) ?? -1))
        XCTAssertTrue(f.subtitles.isEmpty); XCTAssertEqual(f.displaySize?.width, 160)
    }

    func testAudioOnlyFileHasNoVideoValuesAndMissingIsNilNotZero() async throws {
        let src = try copy(try await LocalMovie.fixture("tone", LocalMovieSpec(fileType: .m4a, video: false)))
        let f = try await MediaFactsReader.read(src)
        XCTAssertTrue(f.video.isEmpty); XCTAssertEqual(f.audio.count, 1); XCTAssertNil(f.displaySize)
        XCTAssertEqual(f.container, "MPEG-4 audio")
        XCTAssertNil(f.audio[0].width); XCTAssertNil(f.audio[0].frameRate); XCTAssertNil(f.audio[0].rotation)
    }

    func testContainerComesFromTheFirstBytesNotTheName() async throws {
        let basic = try await LocalMovie.fixture("basic", LocalMovieSpec())
        let renamed = try copy(basic, as: "looks-like-text.txt")
        let c1 = try await MediaFactsReader.read(renamed).container; XCTAssertEqual(c1, "MP4")
        let mov = try copy(try await LocalMovie.fixture("basicmov", LocalMovieSpec(fileType: .mov)), as: "really-quicktime.mp4")
        let c2 = try await MediaFactsReader.read(mov).container; XCTAssertEqual(c2, "QuickTime")
        XCTAssertEqual(MediaFactsReader.sniffContainer(Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0])), "Matroska/WebM")
        XCTAssertEqual(MediaFactsReader.sniffContainer(Data("RIFF....WAVEfmt ".utf8)), "WAV")
        XCTAssertEqual(MediaFactsReader.sniffContainer(Data("ID3\u{3}\u{0}".utf8)), "MP3")
        XCTAssertNil(MediaFactsReader.sniffContainer(Data("hello world".utf8)))
    }

    func testRotationAndDisplaySize() async throws {
        let src = try copy(try await LocalMovie.fixture("portrait", LocalMovieSpec(seconds: 2, rotation: 90, audioLanguages: [])))
        let f = try await MediaFactsReader.read(src)
        XCTAssertEqual(f.video.first?.rotation, 90)
        XCTAssertEqual(f.displaySize?.width, 120); XCTAssertEqual(f.displaySize?.height, 160, "a turned picture swaps its sides")
        XCTAssertEqual(MediaFactsReader.rotation(of: CGAffineTransform(rotationAngle: .pi)), 180)
        XCTAssertNil(MediaFactsReader.rotation(of: .identity)); XCTAssertNil(MediaFactsReader.rotation(of: CGAffineTransform(rotationAngle: 0.3)), "a tilt that is not a quarter turn is not reported as one")
    }

    func testMalformedAndUnsupportedFilesFailCleanly() async throws {
        let basic = try await LocalMovie.fixture("basic", LocalMovieSpec())
        let whole = try Data(contentsOf: basic)
        let endIndex = try Data(contentsOf: try await LocalMovie.fixture("endindex", LocalMovieSpec(audioLanguages: [], faststart: false)))
        let cases: [(String, Data)] = [("empty.mp4", Data()), ("text.mp4", Data("this is not media".utf8)), ("cut.mp4", endIndex.prefix(endIndex.count / 2)), ("cutstart.mp4", whole.prefix(200)),
                                       ("mkv.mkv", Data([0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 200))), ("garbage.mov", Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 131) }))]
        for (name, data) in cases {
            let url = downloads.appendingPathComponent(name); try data.write(to: url)
            do { let f = try await MediaFactsReader.read(url); XCTAssertTrue(f.tracks.isEmpty || !f.isPlayable, "\(name) must not look playable") }
            catch { XCTAssertTrue(error is MediaFactsError, "\(name): \(error)") }
        }
        do { _ = try await MediaFactsReader.read(downloads.appendingPathComponent("nope.mp4")); XCTFail() } catch { XCTAssertEqual(error as? MediaFactsError, .missing) }
        do { _ = try await MediaFactsReader.read(downloads); XCTFail() } catch { XCTAssertEqual(error as? MediaFactsError, .notAFile) }
    }

    func testAbsurdValuesAreHandledAsData() {
        XCTAssertNil(SubtitleText.parseTime("99999999999:00")); XCTAssertNil(SubtitleText.parseTime("00:61")); XCTAssertNil(SubtitleText.parseTime("-1:00")); XCTAssertNil(SubtitleText.parseTime("nan:00"))
        // A box that claims to be larger than the file, a 64-bit size that overflows, and a size smaller than a header never loop or crash.
        var head = Data([0xFF, 0xFF, 0xFF, 0xF0]); head.append(Data("moov".utf8)); head.append(Data(repeating: 0, count: 32))
        XCTAssertEqual(PartialPreview.topLevelBoxes(head, knownLength: 40).count, 1)
        var wide = Data([0, 0, 0, 1]); wide.append(Data("mdat".utf8)); wide.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertTrue(PartialPreview.topLevelBoxes(wide, knownLength: 100).isEmpty)
        XCTAssertTrue(PartialPreview.topLevelBoxes(Data([0, 0, 0, 4, 0x66, 0x72, 0x65, 0x65]), knownLength: 8).isEmpty)
    }

    func testCancellingAnInspectionEndsIt() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let task = Task { try await MediaFactsReader.read(src) }
        task.cancel()
        do { _ = try await task.value } catch { XCTAssertTrue(error is CancellationError || error is MediaFactsError) }
    }
}

// MARK: - Preview and thumbnails

@MainActor
final class MediaPreviewTests: MediaProcessingCase {
    func testWhatMayBePreviewedIsDecidedFromTheContents() async throws {
        let video = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        XCTAssertEqual(MediaPreviewPolicy.kind(of: video), .video)
        let audio = try copy(try await LocalMovie.fixture("tone", LocalMovieSpec(fileType: .m4a, video: false)))
        XCTAssertEqual(MediaPreviewPolicy.kind(of: audio), .audio)
        let mov = try copy(try await LocalMovie.fixture("basicmov", LocalMovieSpec(fileType: .mov)))
        XCTAssertEqual(MediaPreviewPolicy.kind(of: mov), .video)
        // An image made here: a PNG.
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let png = downloads.appendingPathComponent("pic.png")
        let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertEqual(MediaPreviewPolicy.kind(of: png), .image)
        let note = downloads.appendingPathComponent("note.txt"); try "hello".write(to: note, atomically: true, encoding: .utf8)
        XCTAssertEqual(MediaPreviewPolicy.kind(of: note), .document)
        let json = downloads.appendingPathComponent("d.json"); try "{}".write(to: json, atomically: true, encoding: .utf8)
        XCTAssertEqual(MediaPreviewPolicy.kind(of: json), .document)
    }

    func testUnsupportedAndDangerousFilesAreRefusedWithAReason() async throws {
        func unsupported(_ url: URL, _ line: UInt = #line) { if case .unsupported(let why) = MediaPreviewPolicy.kind(of: url) { XCTAssertFalse(why.isEmpty, line: line) } else { XCTFail("\(url.lastPathComponent) should be refused", line: line) } }
        let mkv = downloads.appendingPathComponent("a.mkv"); try Data([0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 60)).write(to: mkv); unsupported(mkv)
        let fake = downloads.appendingPathComponent("fake.mp4"); try "not video".write(to: fake, atomically: true, encoding: .utf8); unsupported(fake)
        let script = downloads.appendingPathComponent("run.sh"); try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path); unsupported(script)
        let app = downloads.appendingPathComponent("Thing.app"); try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true); unsupported(app)
        let zip = downloads.appendingPathComponent("a.zip"); try Data("PK".utf8).write(to: zip); unsupported(zip)
        let link = downloads.appendingPathComponent("link.mp4"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script); unsupported(link)
        unsupported(downloads.appendingPathComponent("absent.mp4"))
    }

    func testOnlyFilesInsideAuthorisedFoldersMayBePreviewed() throws {
        let inside = downloads.appendingPathComponent("ok.txt"); try "x".write(to: inside, atomically: true, encoding: .utf8)
        let outside = root.appendingPathComponent("elsewhere.txt"); try "x".write(to: outside, atomically: true, encoding: .utf8)
        let link = downloads.appendingPathComponent("escape.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertTrue(MediaPreviewPolicy.mayPreview(inside, roots: [downloads])); XCTAssertFalse(MediaPreviewPolicy.mayPreview(outside, roots: [downloads]))
        XCTAssertFalse(MediaPreviewPolicy.mayPreview(link, roots: [downloads]), "a link that leads out is not followed")
    }

    func testThumbnailIsUprightBoundedAndKeepsTheAspectRatio() async throws {
        let wide = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let t = MediaThumbnailer()
        let img = try await t.thumbnail(for: wide, dimension: 64)
        XCTAssertEqual(img.width, 64); XCTAssertEqual(img.height, 48, "160x120 keeps 4:3")
        let portrait = try copy(try await LocalMovie.fixture("portrait", LocalMovieSpec(seconds: 2, rotation: 90, audioLanguages: [])))
        let p = try await t.thumbnail(for: portrait, dimension: 64)
        XCTAssertEqual(p.width, 48); XCTAssertEqual(p.height, 64, "turned upright from the track's own transform")
        let big = try await t.thumbnail(for: wide, dimension: 99_999)
        XCTAssertLessThanOrEqual(max(big.width, big.height), MediaThumbnailer.maxDimension)
    }

    func testThumbnailTakesTheFrameFromTheMomentAsked() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let early = LocalMovie.luma(try await frame(src, at: 0.5)), late = LocalMovie.luma(try await frame(src, at: 5))
        XCTAssertLessThan(early, 60); XCTAssertGreaterThan(late, 170, "the clip brightens over time: early \(early) late \(late)")
    }

    func testCacheIsKeyedByFileIdentityAndNotKeptForPrivateDownloads() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let t = MediaThumbnailer()
        _ = try await t.thumbnail(for: src, dimension: 64, isPrivate: true)
        XCTAssertNil(t.cached(src, dimension: 64), "a private download is never cached")
        _ = try await t.thumbnail(for: src, dimension: 64)
        XCTAssertNotNil(t.cached(src, dimension: 64))
        // The file changes: the old picture is not reused.
        try Data(contentsOf: try await LocalMovie.fixture("portrait", LocalMovieSpec(seconds: 2, rotation: 90, audioLanguages: []))).write(to: src)
        XCTAssertNil(t.cached(src, dimension: 64), "an edited file asks again")
        let fresh = try await t.thumbnail(for: src, dimension: 64)
        XCTAssertEqual(fresh.height, 64)
    }

    func testMalformedOrSilentFilesGiveAnErrorNotACrash() async throws {
        let t = MediaThumbnailer()
        let junk = downloads.appendingPathComponent("junk.mp4"); try Data("nope".utf8).write(to: junk)
        do { _ = try await t.thumbnail(for: junk); XCTFail() } catch { XCTAssertTrue(error is MediaThumbnailError) }
        let tone = try copy(try await LocalMovie.fixture("tone", LocalMovieSpec(fileType: .m4a, video: false)))
        do { _ = try await t.thumbnail(for: tone); XCTFail() } catch { XCTAssertEqual(error as? MediaThumbnailError, .noVideo) }
    }

    func testCancelledThumbnailRequestsStop() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let task = Task { try await MediaThumbnailer().thumbnail(for: src, isPrivate: true) }
        task.cancel()
        do { _ = try await task.value } catch { XCTAssertTrue(error is CancellationError || error is MediaThumbnailError) }
    }

    func testAPartlyDownloadedFileIsPreviewedOnlyWhenItsIndexHasArrived() async throws {
        let fast = try copy(try await LocalMovie.fixture("faststart", LocalMovieSpec(audioLanguages: [])))
        let whole = try Data(contentsOf: fast)
        let part = whole.count * 6 / 10
        XCTAssertEqual(PartialPreview.evaluate(file: fast, contiguousBytes: Int64(part), isFinalizing: false, isPrivate: false), .allowed(bytes: Int64(part)))
        if case .refused = PartialPreview.evaluate(file: fast, contiguousBytes: 100, isFinalizing: false, isPrivate: false) {} else { XCTFail("index not there yet") }
        if case .refused = PartialPreview.evaluate(file: fast, contiguousBytes: nil, isFinalizing: false, isPrivate: false) {} else { XCTFail("pieces out of order") }
        if case .refused = PartialPreview.evaluate(file: fast, contiguousBytes: Int64(part), isFinalizing: true, isPrivate: false) {} else { XCTFail("being put in place") }
        let slow = try copy(try await LocalMovie.fixture("endindex", LocalMovieSpec(audioLanguages: [], faststart: false)))
        if case .refused(let why) = PartialPreview.evaluate(file: slow, contiguousBytes: Int64((try Data(contentsOf: slow)).count * 6 / 10), isFinalizing: false, isPrivate: false) { XCTAssertFalse(why.isEmpty) } else { XCTFail("index at the end") }
        let text = downloads.appendingPathComponent("x.mp4"); try Data(repeating: 65, count: 5000).write(to: text)
        if case .refused = PartialPreview.evaluate(file: text, contiguousBytes: 5000, isFinalizing: false, isPrivate: false) {} else { XCTFail("not a movie") }
        // What is shown is a read-only copy; the file being written is untouched, and the copy plays as far as it goes.
        let before = hash(fast)
        let snap = try PartialPreview.snapshot(of: fast, bytes: Int64(part), into: downloads.appendingPathComponent("preview"))
        XCTAssertEqual(hash(fast), before); XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: snap.path)[.size] as? Int), part)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: snap.path)[.posixPermissions] as? Int), 0o400)
        let picture = try await frame(snap, at: 0.5)
        XCTAssertLessThan(LocalMovie.luma(picture), 80, "the beginning of the movie decodes from the part that arrived")
    }
}

// MARK: - Remux, convert, extract, trim

@MainActor
final class MediaProcessingTests: MediaProcessingCase {
    func testRemuxToQuickTimeCopiesTheTracksAndIsVerifiedLossless() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let before = hash(src)
        let job = try unwrapped(await run(src, .remux(.mov)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        let out = try XCTUnwrap(job.output)
        XCTAssertEqual(out.lastPathComponent, "basic remuxed.mov"); XCTAssertEqual(job.lossless, true)
        let a = try await MediaFactsReader.read(src), b = try await MediaFactsReader.read(out)
        XCTAssertEqual(b.container, "QuickTime")
        XCTAssertEqual(b.video.first?.fourCC, a.video.first?.fourCC); XCTAssertEqual(b.audio.first?.fourCC, a.audio.first?.fourCC)
        XCTAssertEqual(try XCTUnwrap(b.durationSeconds), try XCTUnwrap(a.durationSeconds), accuracy: 0.15)
        XCTAssertEqual(b.video.first?.width, 160); XCTAssertEqual(b.audio.first?.language, "fra")
        // Audio and video still end together, and the picture at the end is the end of the clip.
        XCTAssertEqual(try XCTUnwrap(b.video.first?.durationSeconds), try XCTUnwrap(b.audio.first?.durationSeconds), accuracy: 0.2, "audio/video length drift")
        let endLuma = LocalMovie.luma(try await frame(out, at: 5.5)); XCTAssertGreaterThan(endLuma, 180)
        XCTAssertEqual(hash(src), before, "the source is never changed"); XCTAssertTrue(stagingLeftovers().isEmpty)
    }

    func testRemuxBackToMP4AndOrientationIsKept() async throws {
        let mov = try copy(try await LocalMovie.fixture("portraitmov", LocalMovieSpec(seconds: 3, fileType: .mov, rotation: 90, audioLanguages: ["eng"])))
        let job = try unwrapped(await run(mov, .remux(.mp4)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        let f = try await MediaFactsReader.read(try XCTUnwrap(job.output))
        XCTAssertEqual(f.container, "MP4"); XCTAssertEqual(f.video.first?.rotation, 90); XCTAssertEqual(job.lossless, true)
        let p = try await frame(try XCTUnwrap(job.output), at: 1)
        XCTAssertLessThan(p.width, p.height, "still upright")
    }

    func testRemuxRefusesWhatCannotBeCopiedAndNeverEncodesInstead() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let facts = try await MediaFactsReader.read(src)
        for (op, why) in [(MediaOperation.remux(.wav), "WAV"), (.remux(.m4a), "audio only")] {
            do { _ = try await MediaProcessor.plan(op, facts: facts); XCTFail("\(op)") } catch let e as MediaProcessError { XCTAssertTrue(e.localizedDescription.contains(why), e.localizedDescription) }
        }
        XCTAssertEqual(MediaProcessor.canHold(.mp4, video: "apcn", audio: nil)?.contains("Apple ProRes"), true)
        XCTAssertNotNil(MediaProcessor.canHold(.mp4, video: nil, audio: "lpcm")); XCTAssertNil(MediaProcessor.canHold(.mp4, video: "avc1", audio: "mp4a"))
        XCTAssertNotNil(MediaProcessor.canHold(.m4a, video: nil, audio: ".mp3"))
        let jobWav = try unwrapped(await run(src, .remux(.wav)))
        if case .failed = jobWav.state {} else { XCTFail("refused: \(jobWav.state)") }
        XCTAssertNil(jobWav.output); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).filter { !$0.hasPrefix(".") }, ["basic.mp4"])
    }

    func testChoosingAudioTracksCarriesOnlyThose() async throws {
        let src = try copy(try await LocalMovie.fixture("twoaudio", LocalMovieSpec(seconds: 3, audioLanguages: ["eng", "fra"])))
        let facts = try await MediaFactsReader.read(src)
        XCTAssertEqual(facts.audio.compactMap(\.language), ["eng", "fra"])
        let second = try XCTUnwrap(facts.audio.last)
        let plan = try await MediaProcessor.plan(.remux(.mov), facts: facts, audioTracks: [second.id])
        XCTAssertEqual(plan.audioTrackIDs, [second.id])
        let id = service.submit(source: src, operation: .remux(.mov), profileTag: "default", isPrivate: false, audioTracks: [second.id])
        let job = try await finalJob(id)
        XCTAssertEqual(job.state, .completed, job.state.title)
        let out = try await MediaFactsReader.read(try XCTUnwrap(job.output))
        XCTAssertEqual(out.audio.count, 1); XCTAssertEqual(out.audio.first?.language, "fra")
    }

    func testConversionToH264ChangesTheEncodingAndIsNeverCalledLossless() async throws {
        let big = try copy(try await LocalMovie.fixture("hd", LocalMovieSpec(seconds: 3, width: 1280, height: 720, keyframeEvery: 15, audioLanguages: ["eng"])))
        let job = try unwrapped(await run(big, .convert(codec: .h264, resolution: .p480, container: .mp4)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        let f = try await MediaFactsReader.read(try XCTUnwrap(job.output))
        XCTAssertEqual(f.video.first?.fourCC, "avc1"); XCTAssertLessThanOrEqual(f.video.first?.width ?? 9999, 640)
        XCTAssertEqual(f.audio.first?.codec, "AAC"); XCTAssertEqual(job.lossless, false)
        XCTAssertEqual(try XCTUnwrap(f.durationSeconds), 3, accuracy: 0.3)
        XCTAssertEqual(Double(f.video.first?.width ?? 0) / Double(f.video.first?.height ?? 1), 16.0 / 9.0, accuracy: 0.05, "aspect ratio kept")
        let lateLuma = LocalMovie.luma(try await frame(try unwrapped(job.output), at: 2.7)); XCTAssertGreaterThan(lateLuma, 150)
    }

    func testEnlargingAndUnavailableSettingsAreRefusedWithReasons() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let facts = try await MediaFactsReader.read(src)
        for op in [MediaOperation.convert(codec: .h264, resolution: .p720, container: .mp4), .convert(codec: .hevc, resolution: .p480, container: .mp4), .convert(codec: .h264, resolution: .original, container: .m4a)] {
            do { _ = try await MediaProcessor.plan(op, facts: facts); XCTFail("\(op)") } catch let e as MediaProcessError { XCTAssertFalse(e.localizedDescription.isEmpty) }
        }
        let tone = try await MediaFactsReader.read(try copy(try await LocalMovie.fixture("tone", LocalMovieSpec(fileType: .m4a, video: false))))
        do { _ = try await MediaProcessor.plan(.convert(codec: .h264, resolution: .original, container: .mp4), facts: tone); XCTFail() } catch { XCTAssertTrue(error is MediaProcessError) }
    }

    func testHEVCIsOfferedOnlyWhereTheSystemSaysSo() async throws {
        let src = try copy(try await LocalMovie.fixture("hd", LocalMovieSpec(seconds: 3, width: 1280, height: 720, keyframeEvery: 15, audioLanguages: ["eng"])))
        let asset = AVURLAsset(url: src)
        let offered = await MediaProcessor.systemAllows(preset: AVAssetExportPresetHEVCHighestQuality, asset: asset, fileType: .mp4)
        let job = try unwrapped(await run(src, .convert(codec: .hevc, resolution: .original, container: .mp4)))
        if offered {
            XCTAssertEqual(job.state, .completed, job.state.title)
            let hevcCodec = try await MediaFactsReader.read(try unwrapped(job.output)).video.first?.fourCC; XCTAssertEqual(hevcCodec, "hvc1")
        } else {
            if case .failed(let why) = job.state { XCTAssertFalse(why.isEmpty) } else { XCTFail("must be refused where HEVC is not available") }
            XCTAssertNil(job.output)
        }
        let bogus = await MediaProcessor.systemAllows(preset: "AVAssetExportPresetDoesNotExist", asset: asset, fileType: .mp4); XCTAssertFalse(bogus)
    }

    func testExtractingAudioCopiesAACAndDecodesToWAV() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let m4a = try unwrapped(await run(src, .extractAudio(.m4a, trackID: nil)))
        XCTAssertEqual(m4a.state, .completed, m4a.state.title)
        let a = try await MediaFactsReader.read(try XCTUnwrap(m4a.output))
        XCTAssertTrue(a.video.isEmpty); XCTAssertTrue(["aac ", "mp4a"].contains(a.audio.first?.fourCC ?? ""), "AAC"); XCTAssertEqual(m4a.lossless, true, "AAC into M4A is a copy")
        XCTAssertEqual(try XCTUnwrap(a.durationSeconds), 6, accuracy: 0.2); XCTAssertEqual(a.container, "MPEG-4 audio")
        let wav = try unwrapped(await run(src, .extractAudio(.wav, trackID: nil)))
        XCTAssertEqual(wav.state, .completed, wav.state.title)
        let w = try await MediaFactsReader.read(try XCTUnwrap(wav.output))
        XCTAssertEqual(w.container, "WAV"); XCTAssertEqual(w.audio.first?.codec, "PCM"); XCTAssertEqual(w.audio.first?.sampleRate, 44100); XCTAssertEqual(w.audio.first?.channels, 1)
        XCTAssertEqual(try XCTUnwrap(w.durationSeconds), 6, accuracy: 0.2); XCTAssertEqual(wav.lossless, false)
        let missing = try unwrapped(await run(src, .extractAudio(.m4a, trackID: 999)))
        if case .failed = missing.state {} else { XCTFail("no such track") }
        let silent = try copy(try await LocalMovie.fixture("silent", LocalMovieSpec(seconds: 2, audioLanguages: [])))
        let none = try unwrapped(await run(silent, .extractAudio(.m4a, trackID: nil)))
        if case .failed(let why) = none.state { XCTAssertTrue(why.contains("no audio")) } else { XCTFail() }
    }

    func testTheSelectedAudioTrackIsTheOneExtracted() async throws {
        let src = try copy(try await LocalMovie.fixture("twoaudio", LocalMovieSpec(seconds: 3, audioLanguages: ["eng", "fra"])))
        let facts = try await MediaFactsReader.read(src)
        let job = try unwrapped(await run(src, .extractAudio(.m4a, trackID: facts.audio[1].id)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        let lang = try await MediaFactsReader.read(try unwrapped(job.output)).audio.first?.language; XCTAssertEqual(lang, "fra")
    }

    func testFastTrimCutsAtAKeyframeAndKeepsTheStartedPicture() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let job = try unwrapped(await run(src, .trim(start: 2, end: 4, mode: .fast, container: .mp4)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        let f = try await MediaFactsReader.read(try XCTUnwrap(job.output))
        XCTAssertEqual(try XCTUnwrap(f.durationSeconds), 2, accuracy: 0.35, "a cut on a keyframe is the length asked")
        let first = LocalMovie.luma(try await frame(try XCTUnwrap(job.output), at: 0.1))
        XCTAssertEqual(first, 255 * 2.0 / 6.0, accuracy: 35, "the first picture is from about 2 s into the source")
        XCTAssertEqual(job.lossless, true)
        XCTAssertEqual(try XCTUnwrap(f.video.first?.durationSeconds), try XCTUnwrap(f.audio.first?.durationSeconds), accuracy: 0.35)
    }

    func testAFastTrimStartingBetweenKeyframesMayStartEarlierAndNeverLater() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let job = try unwrapped(await run(src, .trim(start: 2.5, end: 4.5, mode: .fast, container: .mp4)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        let f = try await MediaFactsReader.read(try XCTUnwrap(job.output))
        let d = try XCTUnwrap(f.durationSeconds)
        NSLog("MEASURED fast trim 2.5-4.5s (asked 2.0 s) gave %.3f s", d)
        // Measured on this system; the contract is "not shorter than asked, and at most a keyframe interval (1 s here) longer".
        XCTAssertGreaterThanOrEqual(d, 1.85); XCTAssertLessThanOrEqual(d, 3.15, "measured duration \(d)")
    }

    func testAnExactTrimStartsWhereAskedAndEndsWhereAsked() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let job = try unwrapped(await run(src, .trim(start: 2.5, end: 4, mode: .accurate, container: .mp4)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        let out = try XCTUnwrap(job.output)
        let f = try await MediaFactsReader.read(out)
        XCTAssertEqual(try XCTUnwrap(f.durationSeconds), 1.5, accuracy: 0.25)
        let exactLuma = LocalMovie.luma(try await frame(out, at: 0.05)); XCTAssertEqual(exactLuma, 255 * 2.5 / 6, accuracy: 30)
        XCTAssertEqual(job.lossless, false, "an exact trim encodes again and is not called lossless")
    }

    func testATrimOfAFileThatDoesNotStartAtZeroUsesItsOwnTimeline() async throws {
        let src = try copy(try await LocalMovie.fixture("offset", LocalMovieSpec(seconds: 6, startOffset: 5)))
        let job = try unwrapped(await run(src, .trim(start: 1, end: 3, mode: .accurate, container: .mp4)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        let out = try XCTUnwrap(job.output)
        let offsetDuration = try unwrapped(try await MediaFactsReader.read(out).durationSeconds); XCTAssertEqual(offsetDuration, 2, accuracy: 0.3)
        let offsetLuma = LocalMovie.luma(try await frame(out, at: 0.05)); XCTAssertEqual(offsetLuma, 255 * 1.0 / 6, accuracy: 35, "second 1 of the clip, not second 6 of the timeline")
    }

    func testInvalidTimeRangesAreRefusedBeforeAnythingIsWritten() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let facts = try await MediaFactsReader.read(src)
        let bad: [(Double, Double)] = [(3, 3), (4, 2), (-1, 2), (0, .nan), (.infinity, 5), (7, 9), (1, 1.05)]
        for (s, e) in bad {
            do { _ = try await MediaProcessor.plan(.trim(start: s, end: e, mode: .fast, container: .mp4), facts: facts); XCTFail("\(s)–\(e)") }
            catch let err as MediaProcessError { XCTAssertTrue(err.localizedDescription.count > 5) }
        }
        // An end past the file's end is cut to the end.
        let ok = try await MediaProcessor.plan(.trim(start: 4, end: 100, mode: .fast, container: .mp4), facts: facts)
        XCTAssertTrue(ok.passthrough)
        XCTAssertTrue(stagingLeftovers().isEmpty)
    }
}

// MARK: - Subtitles

@MainActor
final class SubtitleTests: MediaProcessingCase {
    func testSRTBecomesWebVTTWithTheSameTimes() throws {
        let srt = "1\r\n00:00:01,500 --> 00:00:03,000\r\nHello <i>there</i>\r\n\r\n2\r\n00:01:02,250 --> 00:01:04,000\r\nSecond\r\nline\r\n"
        let cues = try SubtitleText.parse(srt)
        XCTAssertEqual(cues.count, 2); XCTAssertEqual(cues[0].start, 1.5); XCTAssertEqual(cues[0].end, 3.0); XCTAssertEqual(cues[1].start, 62.25)
        XCTAssertEqual(cues[1].text, "Second\nline")
        let vtt = SubtitleText.webVTT(cues, language: "fr")
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\nLanguage: fr\n")); XCTAssertTrue(vtt.contains("00:00:01.500 --> 00:00:03.000\nHello <i>there</i>"))
        XCTAssertTrue(vtt.contains("00:01:02.250 --> 00:01:04.000\nSecond\nline"))
        // The same cues read back from the VTT.
        XCTAssertEqual(try SubtitleText.parse(vtt), cues)
    }

    func testTimeOffsetsShiftEveryCueAndNeverBelowZero() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nA\n\n00:00:05.000 --> 00:00:06.000\nB\n"
        let later = try SubtitleText.parse(vtt, offset: 2.5)
        XCTAssertEqual(later.map(\.start), [3.5, 7.5])
        let earlier = try SubtitleText.parse(vtt, offset: -1.5)
        XCTAssertEqual(earlier.map(\.start), [0, 3.5], "a cue is not moved before the start")
        XCTAssertEqual(earlier[0].end, 0.5)
        XCTAssertEqual(try SubtitleText.parse(vtt, offset: -5.5).count, 1, "a cue wholly before the start is dropped")
    }

    func testMarkupIsReducedToWhatWebVTTDefines() throws {
        let hostile = "00:00:01.000 --> 00:00:02.000\n<script>alert(1)</script><b>ok</b> {\\an8}a < b & c <font color=red>x</font> --> y\n"
        let cue = try XCTUnwrap(try SubtitleText.parse("WEBVTT\n\n" + hostile).first)
        XCTAssertFalse(cue.text.contains("<script")); XCTAssertFalse(cue.text.contains("<font")); XCTAssertFalse(cue.text.contains("{\\an8}"))
        XCTAssertTrue(cue.text.contains("<b>ok</b>")); XCTAssertTrue(cue.text.contains("&lt;")); XCTAssertTrue(cue.text.contains("&amp;"))
        XCTAssertFalse(cue.text.contains("-->"), "a cue cannot forge the next cue's timing line")
    }

    func testEncodingsAndLimits() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nCafé 日本\n"
        XCTAssertEqual(try SubtitleText.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)), text)
        var utf16 = Data([0xFF, 0xFE]); utf16.append(text.data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try SubtitleText.decode(utf16), text)
        XCTAssertEqual(try SubtitleText.parse(try SubtitleText.decode(utf16)).first?.text, "Café 日本")
        do { _ = try SubtitleText.decode(Data([0xFF, 0xFE, 0x41])) ; _ = try SubtitleText.decode(Data([0xC3, 0x28])); XCTFail("not text") } catch { XCTAssertTrue(error is SubtitleError) }
        do { _ = try SubtitleText.decode(Data(count: SubtitleText.maxBytes + 1)); XCTFail() } catch { XCTAssertEqual(error as? SubtitleError, .tooLarge) }
        do { _ = try SubtitleText.parse("nothing here"); XCTFail() } catch { XCTAssertEqual(error as? SubtitleError, .noCues) }
        XCTAssertEqual(try SubtitleText.parse("00:00:05,000 --> 00:00:04,000\nbackwards\n\n00:00:01,000 --> 00:00:02,000\nfine\n").count, 1)
    }

    func testFileNamesAreSafeAndCarryTheLanguage() {
        XCTAssertEqual(SubtitleText.fileName(base: "Movie", language: "fra"), "Movie.fra.vtt")
        XCTAssertEqual(SubtitleText.fileName(base: "Movie", language: "../../etc"), "Movie.vtt", "an odd language tag is dropped, not used in a path")
        XCTAssertFalse(SubtitleText.fileName(base: "../../evil", language: nil).contains("/"))
    }

    func testASubtitleFileBecomesAVTTBesideItWithoutTouchingTheOriginal() async throws {
        let srt = downloads.appendingPathComponent("talk.srt")
        try "1\n00:00:01,500 --> 00:00:03,000\nHello\n".write(to: srt, atomically: true, encoding: .utf8)
        let before = hash(srt)
        let job = try unwrapped(await run(srt, .convertSubtitleFile(offset: 1)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        let out = try XCTUnwrap(job.output)
        XCTAssertEqual(out.lastPathComponent, "talk.vtt")
        let body = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(body.contains("00:00:02.500 --> 00:00:04.000\nHello")); XCTAssertEqual(hash(srt), before)
        let bad = downloads.appendingPathComponent("bad.srt"); try "no cues".write(to: bad, atomically: true, encoding: .utf8)
        let failed = try unwrapped(await run(bad, .convertSubtitleFile(offset: 0)))
        if case .failed = failed.state {} else { XCTFail() }
    }

    func testTimedTextSamplesAreReadAndOtherSubtitleKindsAreRefused() async throws {
        XCTAssertEqual(SubtitleText.text(fromTimedTextSample: Data([0, 5]) + Data("Hello".utf8) + Data([0, 0, 0, 12])), "Hello", "style boxes after the text are ignored")
        XCTAssertNil(SubtitleText.text(fromTimedTextSample: Data([0, 50]) + Data("short".utf8)))
        XCTAssertNil(SubtitleText.text(fromTimedTextSample: Data([0])))
        let plain = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let job = try unwrapped(await run(plain, .extractSubtitles(trackID: nil)))
        if case .failed(let why) = job.state { XCTAssertTrue(why.contains("no subtitle track"), why) } else { XCTFail("a file with no subtitles") }
        do { _ = try await SubtitleText.cues(fromTrack: 1, of: plain); XCTFail("a video track is not a subtitle track") } catch { XCTAssertTrue(error is SubtitleError) }
    }

    func testAnEmbeddedTimedTextTrackIsListedAndExtractedWithItsTiming() async throws {
        let cues: [(start: Double, duration: Double, text: String)] = [(0.5, 1.5, "First line"), (3, 1, "Second line")]
        let movie = try await LocalMovie.fixture("subbed", LocalMovieSpec(seconds: 5, audioLanguages: [], subtitles: cues))
        let src = try copy(movie)
        let facts = try await MediaFactsReader.read(src)
        let track = try XCTUnwrap(facts.subtitles.first, "the timed-text track is listed")
        XCTAssertEqual(track.codec, "Timed text (3GPP)"); XCTAssertEqual(track.language, "eng")
        let job = try unwrapped(await run(src, .extractSubtitles(trackID: track.id)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        let out = try XCTUnwrap(job.output)
        XCTAssertEqual(out.lastPathComponent, "subbed.eng.vtt")
        let parsed = try SubtitleText.parse(try String(contentsOf: out, encoding: .utf8))
        XCTAssertEqual(parsed.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(parsed[0].start, 0.5, accuracy: 0.01); XCTAssertEqual(parsed[0].end, 2.0, accuracy: 0.01); XCTAssertEqual(parsed[1].start, 3, accuracy: 0.01)
    }
}

// MARK: - Jobs, files, profiles

@MainActor
final class MediaJobTests: MediaProcessingCase {
    func testTwoJobsForTheSameNameNeverOverwriteEachOtherOrAnExistingFile() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let existing = downloads.appendingPathComponent("basic remuxed.mov"); try Data("precious".utf8).write(to: existing)
        let a = service.submit(source: src, operation: .remux(.mov), profileTag: "default", isPrivate: false)
        let b = service.submit(source: src, operation: .remux(.mov), profileTag: "default", isPrivate: false)
        let ja = try await finalJob(a), jb = try await finalJob(b)
        XCTAssertEqual(ja.state, .completed, ja.state.title); XCTAssertEqual(jb.state, .completed, jb.state.title)
        XCTAssertNotEqual(ja.output, jb.output); XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "precious")
        XCTAssertNotEqual(ja.output, existing); XCTAssertNotEqual(jb.output, existing)
        for out in [ja.output, jb.output] { XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: try XCTUnwrap(out).path)[.size] as? Int ?? 0, 1000) }
    }

    func testCancellingARunningJobLeavesNoOutputAndTheSourceIntact() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let before = hash(src)
        MediaProcessingService.beforeRun = { _, _ in while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) } }
        let id = service.submit(source: src, operation: .convert(codec: .h264, resolution: .original, container: .mp4), profileTag: "default", isPrivate: false)
        for _ in 0..<400 where service.job(id)?.state != .inspecting { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        service.cancel(id)
        let job = try await finalJob(id, seconds: 20)
        XCTAssertEqual(job.state, .cancelled); XCTAssertNil(job.output)
        XCTAssertEqual(hash(src), before); XCTAssertTrue(stagingLeftovers().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).filter { !$0.hasPrefix(".") }, ["basic.mp4"])
    }

    func testCancellingARealExportStopsIt() async throws {
        let src = try copy(try await LocalMovie.fixture("hd", LocalMovieSpec(seconds: 3, width: 1280, height: 720, keyframeEvery: 15, audioLanguages: ["eng"])))
        let id = service.submit(source: src, operation: .convert(codec: .h264, resolution: .original, container: .mp4), profileTag: "default", isPrivate: false)
        service.cancel(id)
        let job = try await finalJob(id, seconds: 30)
        XCTAssertEqual(job.state, .cancelled)
        XCTAssertTrue(stagingLeftovers().isEmpty); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).filter { !$0.hasPrefix(".") }.count, 1)
    }

    func testNotEnoughDiskSpaceFailsBeforeWritingAnythingAndKeepsTheSource() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        MediaProcessingService.freeSpaceOverride = { 1024 }
        let job = try unwrapped(await run(src, .remux(.mov)))
        if case .failed(let why) = job.state { XCTAssertTrue(why.contains("free space"), why) } else { XCTFail("\(job.state)") }
        XCTAssertNil(job.output); XCTAssertTrue(stagingLeftovers().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).filter { !$0.hasPrefix(".") }, ["basic.mp4"])
    }

    func testFilesAndFoldersOutsideTheAuthorisedPlacesAreRefused() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        let outside = root.appendingPathComponent("Elsewhere"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let foreign = outside.appendingPathComponent("movie.mp4"); try FileManager.default.copyItem(at: src, to: foreign)
        let j1 = try unwrapped(await run(foreign, .remux(.mov)))
        let j2 = try unwrapped(await run(src, .remux(.mov), destination: outside))
        let link = downloads.appendingPathComponent("escape"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let j3 = try unwrapped(await run(src, .remux(.mov), destination: link))
        let j4 = try unwrapped(await run(link.appendingPathComponent("movie.mp4"), .remux(.mov)))
        for j in [j1, j2, j3, j4] { if case .failed(let why) = j.state { XCTAssertTrue(why.contains("not one the app may use"), why) } else { XCTFail("\(j.state)") } }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["movie.mp4"], "nothing was written outside")
    }

    func testAtMostTheLimitRunAtOnceAndAFailureDoesNotStopTheOthers() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec(seconds: 2, audioLanguages: ["eng"])))
        final class Gauge: @unchecked Sendable { let lock = NSLock(); var now = 0, peak = 0
            func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }; func leave() { lock.lock(); now -= 1; lock.unlock() } }
        let gauge = Gauge()
        MediaProcessingService.beforeRun = { _, _ in gauge.enter(); try? await Task.sleep(nanoseconds: 120_000_000); gauge.leave() }
        let bad = downloads.appendingPathComponent("broken.mp4"); try Data("not media".utf8).write(to: bad)
        let package = UUID()
        var sources: [URL] = []
        for i in 0..<4 { sources.append(try copy(src, as: "clip\(i).mp4")) }
        sources.insert(bad, at: 2)
        let ids = service.submit(sources: sources, operation: .remux(.mov), profileTag: "default", isPrivate: false, packageID: package)
        var jobs: [MediaJob] = []
        for id in ids { jobs.append(try await finalJob(id)) }
        XCTAssertLessThanOrEqual(gauge.peak, 2, "peak concurrency \(gauge.peak)")
        XCTAssertEqual(jobs.filter { $0.state == .completed }.count, 4)
        if case .failed = jobs[2].state {} else { XCTFail("the broken file fails alone: \(jobs[2].state)") }
        XCTAssertTrue(jobs.allSatisfy { $0.packageID == package })
    }

    func testAnInterruptedJobIsListedForRecoveryAndRestartsOnlyOnRequest() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec(seconds: 2, audioLanguages: ["eng"])))
        // What a crash leaves: a work folder with its journal and a half-written file.
        let id = UUID()
        let folder = downloads.appendingPathComponent(".Browser Setu Media Processing/default/\(id.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal: [String: Any] = ["id": id.uuidString, "source": src.path, "destination": downloads.path, "profileTag": "default", "operation": try JSONSerialization.jsonObject(with: JSONEncoder().encode(MediaOperation.remux(.mov)))]
        try JSONSerialization.data(withJSONObject: journal).write(to: folder.appendingPathComponent("job.json"))
        try Data(repeating: 1, count: 1000).write(to: folder.appendingPathComponent("out.mov"))
        let before = hash(src)
        XCTAssertEqual(service.recoverInterrupted(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the half-written output is gone")
        let job = try XCTUnwrap(service.job(id))
        if case .recoveryRequired = job.state {} else { XCTFail("\(job.state)") }
        XCTAssertEqual(job.operation, .remux(.mov)); XCTAssertEqual(hash(src), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).filter { !$0.hasPrefix(".") }, ["basic.mp4"], "nothing started by itself")
        service.retry(id)
        let done = try await finalJob(id)
        XCTAssertEqual(done.state, .completed, done.state.title)
        // A folder that is not a job's (or has no readable journal) is cleaned, never read as a job.
        let stray = downloads.appendingPathComponent(".Browser Setu Media Processing/default/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true); try Data("{".utf8).write(to: stray.appendingPathComponent("job.json"))
        XCTAssertEqual(service.recoverInterrupted(), 0); XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    func testProfilesWorkInTheirOwnFoldersAndPrivateJobsKeepNoRecord() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec(seconds: 2, audioLanguages: ["eng"])))
        final class Seen: @unchecked Sendable { let lock = NSLock(); var folders: [UUID: URL] = [:]; var journals: [UUID: Bool] = [:]
            func note(_ id: UUID, _ url: URL) { lock.lock(); folders[id] = url; journals[id] = FileManager.default.fileExists(atPath: url.appendingPathComponent("job.json").path); lock.unlock() } }
        let seen = Seen()
        MediaProcessingService.beforeRun = { id, work in seen.note(id, work) }
        let a = service.submit(source: src, operation: .remux(.mov), profileTag: "alice", isPrivate: false)
        let b = service.submit(source: src, operation: .remux(.mov), profileTag: "bob", isPrivate: false)
        let p = service.submit(source: src, operation: .remux(.mov), profileTag: "alice", isPrivate: true)
        for id in [a, b, p] { let j = try await finalJob(id); XCTAssertEqual(j.state, .completed, j.state.title) }
        XCTAssertTrue(seen.folders[a]!.path.contains("/alice/")); XCTAssertTrue(seen.folders[b]!.path.contains("/bob/")); XCTAssertNotEqual(seen.folders[a], seen.folders[b])
        XCTAssertEqual(seen.journals[a], true); XCTAssertEqual(seen.journals[b], true)
        XCTAssertEqual(seen.journals[p], false, "a private job writes no journal")
        XCTAssertFalse(seen.folders[p]!.path.hasPrefix(downloads.path), "a private job works in the temporary folder, not the downloads folder")
        XCTAssertTrue(stagingLeftovers().isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: seen.folders[p]!.path))
        service.forgetPrivateJobs()
        XCTAssertNil(service.job(p)); XCTAssertNotNil(service.job(a))
    }

    func testTheQuarantineMarkOfTheSourceIsCarriedToTheResult() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec(seconds: 2, audioLanguages: ["eng"])))
        DownloadQuarantine.apply(to: src, sourceOrigin: "https://example.com")
        XCTAssertTrue(DownloadQuarantine.isQuarantined(src), "the source carries the mark")
        let job = try unwrapped(await run(src, .remux(.mov)))
        XCTAssertEqual(job.state, .completed, job.state.title)
        XCTAssertTrue(DownloadQuarantine.isQuarantined(try XCTUnwrap(job.output)))
    }

    func testRetryOfAFinishedOrRunningJobDoesNothingAndAFailedOneRestartsFromTheStart() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec(seconds: 2, audioLanguages: ["eng"])))
        MediaProcessingService.freeSpaceOverride = { 1 }
        let id = service.submit(source: src, operation: .remux(.mov), profileTag: "default", isPrivate: false)
        let failed = try await finalJob(id)
        if case .failed = failed.state {} else { XCTFail() }
        MediaProcessingService.freeSpaceOverride = nil
        service.retry(id)
        let again = try await finalJob(id)
        XCTAssertEqual(again.state, .completed, again.state.title)
        service.retry(id)
        XCTAssertEqual(service.job(id)?.state, .completed, "a completed job is not run twice")
    }

    func testTheSourceIsNeverModifiedByAnyOperation() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec(seconds: 3, audioLanguages: ["eng"])))
        let before = hash(src)
        let attrs = try FileManager.default.attributesOfItem(atPath: src.path)[.modificationDate] as? Date
        for op: MediaOperation in [.remux(.mov), .extractAudio(.m4a, trackID: nil), .extractAudio(.wav, trackID: nil), .trim(start: 0.5, end: 2, mode: .fast, container: .mp4), .convert(codec: .h264, resolution: .original, container: .mov)] {
            let job = try unwrapped(await run(src, op)); XCTAssertEqual(job.state, .completed, "\(op): \(job.state.title)")
        }
        XCTAssertEqual(hash(src), before); XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: src.path)[.modificationDate] as? Date, attrs)
    }
}


// MARK: - Review fixes

@MainActor
final class Phase21ReviewFixTests: MediaProcessingCase {
    func testHugeOrInfiniteTimesNeverTrap() {
        for v in [Double.infinity, -.infinity, .nan, 1e30, 1e300] { XCTAssertFalse(SubtitleText.formatTime(v).isEmpty) }
        XCTAssertFalse(MediaOperation.trim(start: 0, end: .infinity, mode: .fast, container: .mp4).title.isEmpty)
        XCTAssertFalse(MediaOperation.convertSubtitleFile(offset: 1e16).title.isEmpty)
    }

    func testAnOversizedBoxInAPartialFileIsRefusedNotTrapped() throws {
        var head = Data([0, 0, 0, 16]); head.append(Data("ftypisom".utf8)); head.append(Data([0, 0, 0, 0]))
        head.append(Data([0, 0, 0, 1])); head.append(Data("moov".utf8)); head.append(Data([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        head.append(Data(repeating: 0, count: 64))
        let file = downloads.appendingPathComponent("evil.mp4"); try head.write(to: file)
        if case .refused = PartialPreview.evaluate(file: file, contiguousBytes: Int64(head.count), isFinalizing: false, isPrivate: false) {} else { XCTFail("must refuse") }
    }

    func testAHostileSubtitleBodyIsSanitizedInBoundedTime() {
        let start = Date()
        _ = SubtitleText.sanitize(String(repeating: "<a", count: 4_000_000))
        _ = SubtitleText.sanitize(String(repeating: "{", count: 4_000_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "work is bounded by the cue limit")
    }

    func testTagAttributesAndBlankLinesDoNotSurvive() throws {
        XCTAssertEqual(SubtitleText.sanitize("<b onclick=\"x\">hi</b>"), "<b>hi</b>")
        XCTAssertEqual(SubtitleText.sanitize("<v Alice>hi</v> <c.yellow>x</c>"), "<v Alice>hi</v> <c.yellow>x</c>")
        XCTAssertFalse(SubtitleText.sanitize("one\n\n\ntwo").contains("\n\n"))
        let vtt = SubtitleText.webVTT([SubtitleCue(start: 0, end: 1, text: SubtitleText.sanitize("one\n\ntwo"))])
        XCTAssertEqual(try SubtitleText.parse(vtt).count, 1, "a cue with an empty line inside stays one cue")
    }

    func testAFailedSnapshotLeavesNothingBehind() throws {
        let folder = downloads.appendingPathComponent("snap")
        XCTAssertThrowsError(try PartialPreview.snapshot(of: downloads.appendingPathComponent("absent.mp4"), bytes: 10, into: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testRecoveryNeverTouchesTheFolderOfARunningJob() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec()))
        MediaProcessingService.beforeRun = { _, _ in try? await Task.sleep(nanoseconds: 400_000_000) }
        let id = service.submit(source: src, operation: .remux(.mov), profileTag: "default", isPrivate: false)
        try await Task.sleep(nanoseconds: 150_000_000)
        _ = service.recoverInterrupted()
        let job = try await finalJob(id)
        XCTAssertEqual(job.state, .completed, job.state.title)
    }

    func testAnAudioExtractionOfAShorterAudioTrackIsNotRejectedForItsLength() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec(seconds: 3)))
        let job = try await run(src, .extractAudio(.m4a, trackID: nil))
        XCTAssertEqual(job?.state, .completed, job?.state.title ?? "")
    }

    func testCancelStaysCancelling() async throws {
        let src = try copy(try await LocalMovie.fixture("basic", LocalMovieSpec(seconds: 3)))
        MediaProcessingService.beforeRun = { _, _ in try? await Task.sleep(nanoseconds: 300_000_000) }
        let id = service.submit(source: src, operation: .remux(.mov), profileTag: "default", isPrivate: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        service.cancel(id)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotEqual(service.job(id)?.state, .processing)
        let end = try await finalJob(id).state; XCTAssertEqual(end, .cancelled)
    }
}

// MARK: - Phase 20 follow-ups

final class Phase21ZipTailTests: XCTestCase {
    private func tail(of archive: Data, bytes: Int) -> Data { archive.suffix(bytes) }
    private var entry: ZipFixtureEntry { ZipFixtureEntry(name: "a.txt", data: Data("hello".utf8)) }

    func testTheLongestPermittedCommentIsFoundFromTheTailAlone() throws {
        for zip64 in [false, true] {
            let comment = String(repeating: "c", count: 65_535)
            let archive = ZipFixture.build([entry], comment: comment, zip64End: zip64).data
            let window = Data(archive.suffix(ZipFormat.tailSize))
            let end = try ZipFormat.findEnd(tail: window, archiveSize: UInt64(archive.count))
            XCTAssertEqual(end.recordOffset, UInt64(archive.count - 22 - 65_535), "zip64=\(zip64)")
            XCTAssertEqual(end.zip64RecordOffset != nil, zip64)
            // The first kilobyte is not enough, and says so in a way the caller retries.
            do { _ = try ZipFormat.findEnd(tail: Data(archive.suffix(1024)), archiveSize: UInt64(archive.count)); XCTFail("must not be found in 1 KiB") }
            catch let e as ZipError { XCTAssertTrue(e == .notAZip || e == .zip64Missing) }
        }
    }

    func testAmbiguousOrMalformedEndRecordsAreRefused() throws {
        let good = ZipFixture.build([entry], comment: "").data
        // A comment length that does not reach the end of the file.
        var lying = good; lying[lying.count - 2] = 9
        XCTAssertThrowsError(try ZipFormat.findEnd(tail: lying, archiveSize: UInt64(lying.count)))
        // Bytes after the record.
        XCTAssertThrowsError(try ZipFormat.findEnd(tail: good + Data([0, 0, 0]), archiveSize: UInt64(good.count + 3)))
        // A fake record inside a long comment is not taken for the real one; there is no real one.
        var fake = Data(repeating: 0x20, count: 60_000); fake.replaceSubrange(100..<122, with: Data([0x50, 0x4B, 5, 6] + [UInt8](repeating: 0, count: 14) + [0xF0, 0xE9, 0, 0]))
        XCTAssertThrowsError(try ZipFormat.findEnd(tail: fake, archiveSize: UInt64(fake.count)))
        // Several disks.
        var multi = good; multi.replaceSubrange((multi.count - 22 + 4)..<(multi.count - 22 + 6), with: Data([1, 0]))
        XCTAssertThrowsError(try ZipFormat.findEnd(tail: multi, archiveSize: UInt64(multi.count))) { XCTAssertEqual($0 as? ZipError, .multiVolume) }
        // Too short to hold a record.
        XCTAssertThrowsError(try ZipFormat.findEnd(tail: Data(repeating: 0, count: 10), archiveSize: 10))
    }
}

@MainActor
final class Phase21ZipFetchTests: MediaCase {
    private func publish(_ name: String, _ data: Data) async throws -> URL { try await put("z21/\(name)", data); return url("/media/z21/\(name)") }
    private func bytes(_ name: String) async -> Int {
        guard let d = try? await get("/_media_hits"), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return -1 }
        return (j["bytes"] as? [String: Int])?["z21/\(name)"] ?? 0
    }

    func testAnArchiveWithTheLongestCommentIsListedWithoutFetchingTheArchive() async throws {
        let payload = ZipFixture.noise(2 << 20)
        for (name, zip64) in [("long.zip", false), ("long64.zip", true)] {
            let data = ZipFixture.build([ZipFixtureEntry(name: "keep.bin", data: payload, method: 0), ZipFixtureEntry(name: "x.txt", data: Data("x".utf8))], comment: String(repeating: "c", count: 65_535), zip64End: zip64).data
            let listing = try await c.remoteZip.inspect(try await publish(name, data))
            XCTAssertEqual(listing.entries.map(\.name), ["keep.bin", "x.txt"], name)
            let fetched = await bytes(name)
            XCTAssertLessThan(fetched, 140_000, "\(name): \(fetched) bytes of a \(data.count) byte archive")
        }
    }

    func testAnArchiveWhoseCommentLengthLiesIsRefusedAndNotFetchedWhole() async throws {
        var data = ZipFixture.build([ZipFixtureEntry(name: "a.bin", data: ZipFixture.noise(1 << 20), method: 0)], comment: "short").data
        data[data.count - 5 - 2] = 0x40                  // the comment-length field (just before the 5-byte comment) claims a longer comment than the file has
        do { _ = try await c.remoteZip.inspect(try await publish("lies.zip", data)); XCTFail() } catch { XCTAssertNotNil(error as? RemoteZipError) }
        let fetched = await bytes("lies.zip")
        XCTAssertLessThan(fetched, 140_000, "\(fetched)")
        XCTAssertTrue(c.ledger.records.isEmpty)
    }

    func testCancellingAnInspectionLeavesNothingBehind() async throws {
        let data = ZipFixture.build([ZipFixtureEntry(name: "a.bin", data: ZipFixture.noise(1 << 20), method: 0)], comment: "c").data
        let u = try await publish("cancel.zip", data)
        let task = Task { try await self.c.remoteZip.inspect(u) }
        task.cancel()
        do { _ = try await task.value } catch { /* cancelled, or finished first: both are fine */ }
        XCTAssertTrue(c.ledger.records.isEmpty)
    }
}

@MainActor
final class Phase21MirrorRecoveryTests: MediaCase {
    static let big: Data = { var b = [UInt8](repeating: 0, count: 20 << 20); for i in 0..<b.count { b[i] = UInt8(truncatingIfNeeded: (i &* 29 &+ 3) % 251) }; return Data(b) }()
    static let bigHash = SHA256.hash(data: big).map { String(format: "%02x", $0) }.joined()
    private func hashOf(_ path: String?) -> String? {
        guard let path, let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    func testAMismatchDeletesOnlyTheTasksOwnFileAndKeepsTheUsersFilesAndTheTask() async throws {
        try await put("m21/a.bin", Self.big)
        var wrong = Self.big
        for i in stride(from: 4096, to: wrong.count, by: 1 << 20) { wrong[i] ^= 0x5A }
        try await put("m21/b.bin", wrong)
        // The person already has files with the same name, and a neighbour.
        let mine = downloads.appendingPathComponent("a.bin"); try Data("my own a.bin".utf8).write(to: mine)
        let neighbour = downloads.appendingPathComponent("a (1).bin"); try Data("neighbour".utf8).write(to: neighbour)
        c.segmentedEnabled = true
        let id = try XCTUnwrap(c.scheduleDownload(url: url("/media/m21/a.bin"), at: Date(), expectedSHA256: Self.bigHash, origin: .user))
        c.mirrors.add([url("/media/m21/b.bin").absoluteString], to: id)
        let record = await wait(id, for: [.completed, .failed], seconds: 120)
        XCTAssertEqual(record?.state, .completed, record?.failure?.reason ?? "")
        XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "my own a.bin"); XCTAssertEqual(try String(contentsOf: neighbour, encoding: .utf8), "neighbour")
        XCTAssertEqual(hashOf(record?.file.destinationPath), Self.bigHash, "the right bytes, from one source")
        XCTAssertNotEqual(record?.file.destinationPath, mine.path); XCTAssertNotEqual(record?.file.destinationPath, neighbour.path)
        XCTAssertEqual(c.ledger.records.count, 1, "the same task throughout"); XCTAssertEqual(record?.id, id)
        XCTAssertEqual(record?.engineMetadata["mirrorsDisabled"], "1", "kept, so a relaunch does not combine again: \(record?.engineMetadata ?? [:]) events \(c.events)")
        XCTAssertNil(record?.engineMetadata["mirrorBytes"], "the unverified contribution is forgotten")
        XCTAssertEqual(record?.engineMetadata["origin"], "user")
        XCTAssertEqual(ConnectionBudget.shared.holding(task: id), 0, "every lease given back")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: downloads.path).filter { $0.hasSuffix(".part") || $0.contains("multipart") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }
}
