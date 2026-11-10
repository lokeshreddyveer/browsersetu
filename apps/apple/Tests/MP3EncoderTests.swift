import XCTest
import AVFoundation
@testable import Browser_Setu

final class MP3EncoderTests: XCTestCase {
    /// A stereo sine wave as a WAV file.
    func wav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-src-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(seconds * 44100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let p = buffer.int16ChannelData![0]
        for i in 0..<Int(frames) { let v = Int16(8000 * sin(2 * .pi * 440 * Double(i) / 44100)); p[2 * i] = v; p[2 * i + 1] = v }
        try file.write(from: buffer)
        return url
    }

    func testEncodesARealMP3ThatReadsBack() async throws {
        XCTAssertTrue(MP3Encoder.isAvailable)
        let src = try wav(seconds: 3)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-out-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: src) }
        try await MP3Encoder.encode(source: src, to: out, kbps: 192)
        let bytes = try Data(contentsOf: out)
        XCTAssertGreaterThan(bytes.count, 3 * 192_000 / 8 - 6_000); XCTAssertLessThan(bytes.count, 3 * 192_000 / 8 + 6_000, "about 192 kbit/s for 3 s")
        XCTAssertEqual(bytes[0], 0xFF)
        let asset = AVURLAsset(url: out)
        let seconds = try await asset.load(.duration).seconds
        XCTAssertEqual(seconds, 3, accuracy: 0.2)
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("dx08-keep"); try? FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: keep.appendingPathComponent("encoded.mp3")); try? FileManager.default.copyItem(at: out, to: keep.appendingPathComponent("encoded.mp3"))
        try? FileManager.default.removeItem(at: out)
    }

    func testCancelStopsAndRemovesThePartialFile() async throws {
        let src = try wav(seconds: 120)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-cancel-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: src) }
        let task = Task { try await MP3Encoder.encode(source: src, to: out, kbps: 320) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { try await task.value; XCTFail("should have been cancelled") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no partial file is left")
    }

    func testAFileWithNoAudioIsRefused() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-none-\(UUID().uuidString).txt"); try Data("x".utf8).write(to: empty)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-none.mp3")
        do { try await MP3Encoder.encode(source: empty, to: out); XCTFail() } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: out.path)) }
        XCTAssertTrue(LocalEncoders.mp3)
    }
}
