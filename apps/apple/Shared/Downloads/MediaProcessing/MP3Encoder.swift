import Foundation
import AVFoundation
#if canImport(CLame)
import CLame
#endif

// MP3 output: a local conversion of audio already on this Mac, using LAME (a separate static library, see ThirdParty/lame). The audio is decoded to PCM with AVFoundation, encoded in
// chunks (so memory stays small and a cancel stops it between chunks), written beside the source and checked by reading the result back. Nothing here uses the network.

enum MP3Encoder {
    /// True when this build carries the encoder (the Mac build does; the iOS build does not).
    static var isAvailable: Bool {
        #if canImport(CLame)
        true
        #else
        false
        #endif
    }

    enum Failure: Error, LocalizedError, Equatable {
        case unavailable, noAudio, readFailed(String), encodeFailed(Int32), writeFailed(String), invalidResult(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "This build has no MP3 encoder."
            case .noAudio: "The file has no audio to convert."
            case .readFailed(let s): "The audio could not be read (\(s))."
            case .encodeFailed(let c): "The MP3 encoder stopped (code \(c))."
            case .writeFailed(let s): "The MP3 file could not be written (\(s))."
            case .invalidResult(let s): "The MP3 did not pass the check and was discarded (\(s))."
            }
        }
    }

    /// Constant bitrates offered (kbit/s). The output is re-encoded audio: it can never be better than the source, and a lossy source encoded again loses a little more.
    static let bitrates = [128, 192, 256, 320]

    /// Encodes the first audio track of `source` to MP3 at `target`. `progress` is 0…1. Throws CancellationError if the task is cancelled; a partly written target is removed.
    static func encode(source: URL, to target: URL, kbps: Int = 192, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        #if canImport(CLame)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        // The length of the audio itself (a video's picture may run longer or shorter than its sound).
        let trackSeconds = (try? await track.load(.timeRange).duration.seconds) ?? 0
        let wholeSeconds = try await asset.load(.duration).seconds
        let duration = trackSeconds.isFinite && trackSeconds > 0 ? trackSeconds : wholeSeconds
        let channels = max(1, min(2, Int((try? await track.load(.formatDescriptions))?.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2)))
        let rate = 44100
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.readFailed(error.localizedDescription) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                                       AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw Failure.readFailed("the track cannot be decoded") }
        reader.add(output)
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard reader.startReading() else { throw Failure.readFailed(reader.error?.localizedDescription ?? "unknown") }
        guard let lame = lame_init() else { throw Failure.encodeFailed(-1) }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(rate)); lame_set_num_channels(lame, Int32(channels)); lame_set_out_samplerate(lame, Int32(rate))
        lame_set_brate(lame, Int32(bitrates.contains(kbps) ? kbps : 192)); lame_set_VBR(lame, vbr_off); lame_set_quality(lame, 2)
        lame_set_write_id3tag_automatic(lame, 0)
        guard lame_init_params(lame) >= 0 else { throw Failure.encodeFailed(-2) }

        // Created exclusively: a file that appeared in the meantime is never overwritten.
        let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw Failure.writeFailed(fd < 0 && errno == EEXIST ? "a file with that name already exists" : "cannot open the file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var finished = false
        defer { try? handle.close(); if !finished { try? FileManager.default.removeItem(at: target) } }
        var out = [UInt8](repeating: 0, count: 1_000_000)
        var seconds = 0.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var pcm = [Int16](repeating: 0, count: length / 2)
            let status = pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw Failure.readFailed("a block could not be copied") }
            let frames = Int32(pcm.count / channels)
            guard frames > 0 else { continue }
            if out.count < Int(1.25 * Double(frames) + 7200) { out = [UInt8](repeating: 0, count: Int(1.25 * Double(frames) + 7200)) }
            let n: Int32 = pcm.withUnsafeBufferPointer { p in
                channels == 2 ? lame_encode_buffer_interleaved(lame, UnsafeMutablePointer(mutating: p.baseAddress), frames, &out, Int32(out.count))
                              : lame_encode_buffer(lame, UnsafeMutablePointer(mutating: p.baseAddress), nil, frames, &out, Int32(out.count))
            }
            guard n >= 0 else { throw Failure.encodeFailed(n) }
            if n > 0 { do { try handle.write(contentsOf: Data(out.prefix(Int(n)))) } catch { throw Failure.writeFailed(error.localizedDescription) } }
            seconds += Double(frames) / Double(rate)
            if duration > 0 { progress(min(0.99, seconds / duration)) }
        }
        if reader.status == .failed { throw Failure.readFailed(reader.error?.localizedDescription ?? "unknown") }
        let tail = lame_encode_flush(lame, &out, Int32(out.count))
        guard tail >= 0 else { throw Failure.encodeFailed(tail) }
        if tail > 0 { try handle.write(contentsOf: Data(out.prefix(Int(tail)))) }
        try handle.close()
        try await validate(target, expectedSeconds: duration)
        finished = true
        progress(1)
        #else
        throw Failure.unavailable
        #endif
    }

    /// The result reads back as MP3 audio of about the length of the audio that was encoded (within a second and a half: the encoder's padding and frame size), and is not empty.
    static func validate(_ url: URL, expectedSeconds: Double) async throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 417 else { throw Failure.invalidResult("it is empty") }
        // The first frame header: 11 set sync bits, MPEG-1 Layer III.
        let b = [UInt8](data.prefix(4))
        guard b[0] == 0xFF, b[1] & 0xE0 == 0xE0, (b[1] >> 1) & 0x03 == 0x01 else { throw Failure.invalidResult("it does not start with an MP3 frame") }
        // The file may still carry a working name (".partial") that tells AVFoundation nothing, so the type is stated: the bytes were just checked to start with an MP3 frame.
        let length = (try? await AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "audio/mpeg"]).load(.duration).seconds) ?? 0
        guard length > 0, abs(length - expectedSeconds) <= 1.5 || expectedSeconds <= 0 else { throw Failure.invalidResult(String(format: "its length is %.1f s, not about %.1f s", length, expectedSeconds)) }
    }
}
