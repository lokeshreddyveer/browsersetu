import Foundation
import AVFoundation
import CoreMedia

// The operations that change a local media file: remux, convert, extract audio, trim, and take subtitles out.
//
// Three different things are kept apart, and the result says which one happened:
//   remux      a different container around the same encoded tracks. No decoding. Lossless, and only claimed so after the output was read back and its codecs matched the source's.
//   convert    decode and encode again (H.264 or HEVC), at the size chosen. Never lossless.
//   extract    the audio alone: copied as it is when the target can hold its codec, otherwise encoded again (AAC) or decoded to PCM (WAV).
// A request the system cannot do is refused with the reason; it is never quietly done another way.

enum OutputContainer: String, Codable, Sendable, CaseIterable {
    case mp4, mov, m4v, m4a, wav
    var fileType: AVFileType {
        switch self { case .mp4: .mp4; case .mov: .mov; case .m4v: .m4v; case .m4a: .m4a; case .wav: .wav }
    }
    var fileExtension: String { rawValue }
    var title: String { switch self { case .mp4: "MP4"; case .mov: "QuickTime (MOV)"; case .m4v: "M4V"; case .m4a: "M4A (audio)"; case .wav: "WAV (audio)" } }
    var isAudioOnly: Bool { self == .m4a || self == .wav }
}

enum MediaVideoCodec: String, Codable, Sendable { case h264, hevc }
enum MediaResolution: String, Codable, Sendable, CaseIterable {
    case original, p1080, p720, p480
    var height: Int? { switch self { case .original: nil; case .p1080: 1080; case .p720: 720; case .p480: 480 } }
    var title: String { switch self { case .original: "Same size"; case .p1080: "1080p"; case .p720: "720p"; case .p480: "480p" } }
}
enum MediaTrimMode: String, Codable, Sendable {
    /// Cuts at the nearest keyframe boundaries the container allows; the video is not decoded. The cut can start before the time asked.
    case fast
    /// Decodes and encodes again so the cut is where it was asked, to within a frame.
    case accurate
}

enum MediaOperation: Codable, Equatable, Sendable {
    case remux(OutputContainer)
    case convert(codec: MediaVideoCodec, resolution: MediaResolution, container: OutputContainer)
    case extractAudio(OutputContainer, trackID: Int32?)
    case trim(start: Double, end: Double, mode: MediaTrimMode, container: OutputContainer)
    /// An embedded text track as WebVTT. A nil track takes the first readable one.
    case extractSubtitles(trackID: Int32?)
    /// An SRT or WebVTT file as WebVTT, moved by `offset` seconds.
    case convertSubtitleFile(offset: Double)

    var title: String {
        switch self {
        case .remux(let c): return "Change container to \(c.title)"
        case .convert(let codec, let res, let c): return "Convert to \(codec == .h264 ? "H.264" : "HEVC") \(res.title) in \(c.title)"
        case .extractAudio(let c, _): return "Extract audio as \(c.title)"
        case .trim(let s, let e, let m, _): return "Trim \(SubtitleText.formatTime(s))–\(SubtitleText.formatTime(e)) (\(m == .fast ? "fast" : "exact"))"
        case .extractSubtitles: return "Extract subtitles"
        case .convertSubtitleFile: return "Convert subtitles to WebVTT"
        }
    }
    var outputExtension: String {
        switch self {
        case .remux(let c), .convert(_, _, let c), .extractAudio(let c, _), .trim(_, _, _, let c): return c.fileExtension
        case .extractSubtitles, .convertSubtitleFile: return "vtt"
        }
    }
    /// A short word for the output name: "converted", "audio" …
    var nameSuffix: String {
        switch self {
        case .remux: return "remuxed"
        case .convert(_, let r, _): return r == .original ? "converted" : "converted \(r.title)"
        case .extractAudio: return "audio"
        case .trim: return "trimmed"
        case .extractSubtitles, .convertSubtitleFile: return ""
        }
    }
}

/// What a request will do with a given file, worked out before anything is written.
struct ProcessingPlan: Equatable, Sendable {
    var preset: String
    var container: OutputContainer
    /// The audio and video tracks that will be carried.
    var videoTrackIDs: [Int32]
    var audioTrackIDs: [Int32]
    var passthrough: Bool
    var droppedNote: String?
    /// True only for what is copied without being decoded.
    var expectsLossless: Bool
    var expectedCodecs: [String]
}

enum MediaProcessError: Error, Equatable, LocalizedError {
    case unsupported(String)
    case invalid(String)
    case diskSpace(needed: Int64, available: Int64)
    case failed(String)
    case outputInvalid(String)
    case cancelled
    case notAuthorized
    var errorDescription: String? {
        switch self {
        case .unsupported(let why): return why
        case .invalid(let why): return why
        case .diskSpace(let needed, let available): return "There is not enough free space: about \(DownloadStats.bytes(needed)) is needed and \(DownloadStats.bytes(available)) is free."
        case .failed(let why): return "The conversion did not finish: \(why)"
        case .outputInvalid(let why): return "The result did not pass the check and was discarded (\(why))."
        case .cancelled: return "Cancelled."
        case .notAuthorized: return "That file or folder is not one the app may use."
        }
    }
}

enum MediaProcessor {
    // MARK: Rules

    /// Which codecs each container can hold when the tracks are copied.
    static func canHold(_ container: OutputContainer, video: String?, audio: String?) -> String? {
        switch container {
        case .mp4, .m4v:
            if let v = video, !["avc1", "avc3", "hvc1", "hev1", "mp4v"].contains(v) { return "\(MediaFactsReader.codecName(fourCC(v))) video cannot be put in \(container.title) without encoding it again." }
            if let a = audio, !["aac ", "mp4a", "ac-3", "ec-3", ".mp3", "alac"].contains(a) { return "\(MediaFactsReader.codecName(fourCC(a))) audio cannot be put in \(container.title) without encoding it again." }
            return nil
        case .mov:
            return nil          // QuickTime takes what AVFoundation can read; the system check below has the last word
        case .m4a:
            if video != nil { return "M4A holds audio only." }
            if let a = audio, !["aac ", "mp4a", "alac"].contains(a) { return "\(MediaFactsReader.codecName(fourCC(a))) audio cannot be put in M4A without encoding it again." }
            return nil
        case .wav:
            return "WAV is made by decoding the audio, not by copying it."
        }
    }
    private static func fourCC(_ s: String) -> FourCharCode { var v: UInt32 = 0; for b in s.utf8.prefix(4) { v = v << 8 | UInt32(b) }; return v }

    private static func presetName(_ codec: MediaVideoCodec, _ resolution: MediaResolution) -> String {
        switch (codec, resolution) {
        case (.h264, .original): return AVAssetExportPresetHighestQuality
        case (.h264, .p1080): return AVAssetExportPreset1920x1080
        case (.h264, .p720): return AVAssetExportPreset1280x720
        case (.h264, .p480): return AVAssetExportPreset640x480
        case (.hevc, .original): return AVAssetExportPresetHEVCHighestQuality
        case (.hevc, .p1080): return AVAssetExportPresetHEVC1920x1080
        case (.hevc, .p720), (.hevc, .p480): return ""          // the system has no HEVC setting below 1080p
        }
    }

    /// The tracks a request carries, by id. A nil audio choice carries every enabled audio track.
    private static func carried(_ facts: MediaFacts, audioChoice: Set<Int32>?) -> (video: [MediaTrackFacts], audio: [MediaTrackFacts]) {
        (facts.video.filter { $0.isEnabled && $0.isDecodable }, facts.audio.filter { $0.isEnabled && $0.isDecodable && (audioChoice?.contains($0.id) ?? true) })
    }

    // MARK: Planning

    /// Works out, from the file's facts and the system's own export table, whether the request can be done and how. Nothing is written.
    static func plan(_ operation: MediaOperation, facts: MediaFacts, audioTracks: Set<Int32>? = nil) async throws -> ProcessingPlan {
        guard !facts.isProtected else { throw MediaProcessError.unsupported("This media is protected. It is never processed.") }
        guard facts.isPlayable else { throw MediaProcessError.unsupported("The system cannot play this file, so it cannot process it either.") }
        let (video, audio) = carried(facts, audioChoice: audioTracks)
        switch operation {
        case .remux(let container):
            guard !container.isAudioOnly || video.isEmpty else { throw MediaProcessError.unsupported("\(container.title) holds audio only, and this file has video.") }
            guard container != .wav else { throw MediaProcessError.unsupported("WAV is not a container change: use Extract Audio.") }
            guard !video.isEmpty || !audio.isEmpty else { throw MediaProcessError.unsupported("There is no video or audio to carry.") }
            if let why = canHold(container, video: video.first?.fourCC, audio: audio.first?.fourCC) { throw MediaProcessError.unsupported(why) }
            for v in video.dropFirst() { if let why = canHold(container, video: v.fourCC, audio: nil) { throw MediaProcessError.unsupported(why) } }
            for a in audio.dropFirst() { if let why = canHold(container, video: nil, audio: a.fourCC) { throw MediaProcessError.unsupported(why) } }
            let dropped = facts.tracks.count - video.count - audio.count
            return ProcessingPlan(preset: AVAssetExportPresetPassthrough, container: container, videoTrackIDs: video.map(\.id), audioTrackIDs: audio.map(\.id), passthrough: true,
                             droppedNote: dropped > 0 ? "\(dropped) other track\(dropped == 1 ? "" : "s") (subtitles or data) will not be carried over." : nil,
                             expectsLossless: true, expectedCodecs: (video + audio).compactMap(\.fourCC))
        case .convert(let codec, let resolution, let container):
            guard !video.isEmpty else { throw MediaProcessError.unsupported("There is no video to convert. For audio use Extract Audio.") }
            guard [.mp4, .mov, .m4v].contains(container) else { throw MediaProcessError.unsupported("Video can be converted into MP4, MOV or M4V.") }
            if let h = resolution.height, let src = video.first?.height, h > src, resolution != .original { throw MediaProcessError.unsupported("The picture is only \(src) pixels high, so \(resolution.title) would enlarge it.") }
            let preset = presetName(codec, resolution)
            guard !preset.isEmpty else { throw MediaProcessError.unsupported("The system offers HEVC only at the same size or 1080p, not \(resolution.title).") }
            return ProcessingPlan(preset: preset, container: container, videoTrackIDs: video.map(\.id), audioTrackIDs: audio.map(\.id), passthrough: false, droppedNote: nil, expectsLossless: false,
                             expectedCodecs: [codec == .h264 ? "avc1" : "hvc1"])
        case .extractAudio(let container, let trackID):
            guard container.isAudioOnly else { throw MediaProcessError.unsupported("Audio can be saved as M4A or WAV.") }
            let chosen = audio.filter { trackID == nil || $0.id == trackID }
            guard let first = chosen.first else { throw MediaProcessError.unsupported(trackID == nil ? "There is no audio in this file." : "That audio track is not in the file or cannot be decoded.") }
            if container == .wav { return ProcessingPlan(preset: "wav", container: .wav, videoTrackIDs: [], audioTrackIDs: [first.id], passthrough: false, droppedNote: nil, expectsLossless: false, expectedCodecs: ["lpcm"]) }
            let copyable = canHold(.m4a, video: nil, audio: first.fourCC) == nil
            return ProcessingPlan(preset: copyable ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A, container: .m4a, videoTrackIDs: [], audioTrackIDs: [first.id], passthrough: copyable, droppedNote: nil,
                             expectsLossless: copyable, expectedCodecs: [copyable ? (first.fourCC ?? "aac ") : "aac "])
        case .trim(let start, let end, let mode, let container):
            guard start.isFinite, end.isFinite, start >= 0, end > start else { throw MediaProcessError.invalid("The end must come after the start, and neither can be negative.") }
            guard let duration = facts.durationSeconds else { throw MediaProcessError.unsupported("The length of this file is not known, so it cannot be trimmed.") }
            guard start < duration else { throw MediaProcessError.invalid("The start is after the end of the file (\(SubtitleText.formatTime(duration))).") }
            guard end - start >= 0.1 else { throw MediaProcessError.invalid("The part to keep must be at least a tenth of a second.") }
            guard !video.isEmpty || !audio.isEmpty else { throw MediaProcessError.unsupported("There is no video or audio to trim.") }
            guard [.mp4, .mov, .m4v, .m4a].contains(container) else { throw MediaProcessError.unsupported("A trim is saved as MP4, MOV, M4V or M4A.") }
            if video.isEmpty, container != .m4a { throw MediaProcessError.unsupported("Audio is trimmed into M4A.") }
            if !video.isEmpty, container == .m4a { throw MediaProcessError.unsupported("M4A holds audio only.") }
            if mode == .fast {
                if let why = canHold(container, video: video.first?.fourCC, audio: audio.first?.fourCC) { throw MediaProcessError.unsupported(why + " Use the exact mode, which encodes again.") }
                return ProcessingPlan(preset: AVAssetExportPresetPassthrough, container: container, videoTrackIDs: video.map(\.id), audioTrackIDs: audio.map(\.id), passthrough: true, droppedNote: nil,
                                 expectsLossless: true, expectedCodecs: (video + audio).compactMap(\.fourCC))
            }
            return ProcessingPlan(preset: video.isEmpty ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality, container: container, videoTrackIDs: video.map(\.id), audioTrackIDs: audio.map(\.id),
                             passthrough: false, droppedNote: nil, expectsLossless: false, expectedCodecs: video.isEmpty ? ["aac "] : ["avc1"])
        case .extractSubtitles, .convertSubtitleFile:
            throw MediaProcessError.unsupported("Subtitles are handled separately.")
        }
    }

    /// The system's own answer, for this asset and file type, to whether a preset can be used. Asked again at the moment of export.
    /// Nil when the system can write `fileType` from `asset` with `preset`; otherwise the reason it cannot.
    static func systemRefusal(preset: String, asset: AVAsset, fileType: AVFileType) async -> String? {
        // (The passthrough preset is not in `allExportPresets()`, so the session itself is the test.)
        // The system refuses to create a session for a preset the asset cannot use, and lists the file types the session can write.
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return "This system cannot use that export setting on this file." }
        let types = await withCheckedContinuation { (c: CheckedContinuation<[AVFileType], Never>) in session.determineCompatibleFileTypes { c.resume(returning: $0) } }
        return types.contains(fileType) ? nil : "This system can write \(types.map { $0.rawValue.components(separatedBy: ".").last ?? $0.rawValue }.joined(separator: ", ")) from this file, not \(fileType.rawValue.components(separatedBy: ".").last ?? fileType.rawValue)."
    }
    static func systemAllows(preset: String, asset: AVAsset, fileType: AVFileType) async -> Bool { await systemRefusal(preset: preset, asset: asset, fileType: fileType) == nil }

    // MARK: Running

    /// The tracks and range of a request, as a composition: the chosen tracks only, starting at time zero, each with its own orientation.
    static func composition(for url: URL, plan: ProcessingPlan, range: ClosedRange<Double>?) async throws -> (composition: AVMutableComposition, source: AVURLAsset, duration: Double) {
        let asset = AVURLAsset(url: MediaAlias.url(for: url), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.load(.tracks)
        let wanted = Set(plan.videoTrackIDs + plan.audioTrackIDs)
        let chosen = tracks.filter { wanted.contains($0.trackID) }
        guard !chosen.isEmpty else { throw MediaProcessError.invalid("The tracks to carry are not in the file.") }
        // Time zero of the request is where the earliest chosen track begins, which is not always zero.
        var origin = CMTime.positiveInfinity
        for t in chosen { let r = try await t.load(.timeRange); if r.start < origin { origin = r.start } }
        let composition = AVMutableComposition()
        var longest = 0.0
        for track in chosen {
            let full = try await track.load(.timeRange)
            var span = full
            if let range {
                let wantStart = CMTimeAdd(origin, CMTime(seconds: range.lowerBound, preferredTimescale: 60_000))
                let wantEnd = CMTimeAdd(origin, CMTime(seconds: range.upperBound, preferredTimescale: 60_000))
                let start = max(wantStart, full.start), end = min(wantEnd, full.end)
                guard end > start else { continue }
                span = CMTimeRange(start: start, end: end)
            }
            guard let t = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MediaProcessError.failed("the system cannot build the tracks") }
            let at = CMTimeSubtract(span.start, CMTimeAdd(origin, range.map { CMTime(seconds: $0.lowerBound, preferredTimescale: 60_000) } ?? .zero))
            try t.insertTimeRange(span, of: track, at: at.seconds < 0 ? .zero : at)
            t.preferredTransform = try await track.load(.preferredTransform)
            t.languageCode = try? await track.load(.languageCode)
            longest = max(longest, CMTimeAdd(at.seconds < 0 ? .zero : at, span.duration).seconds)
        }
        guard longest > 0 else { throw MediaProcessError.invalid("Nothing of the file lies in that range.") }
        return (composition, asset, longest)
    }

    /// Writes `operation`'s result to `staged` (a file path that does not exist yet). `progress` is called with 0...1 off the main thread. Throws `.cancelled` when the task is cancelled.
    static func run(_ operation: MediaOperation, plan: ProcessingPlan, source: URL, staged: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if case .extractAudio(.wav, _) = operation { try await writeWAV(source: source, plan: plan, range: nil, to: staged, progress: progress); return }
        var range: ClosedRange<Double>?
        if case .trim(let s, let e, _, _) = operation { range = s...e }
        let built = try await composition(for: source, plan: plan, range: range)
        let comp = built.composition
        let fileType = plan.container.fileType
        if let why = await systemRefusal(preset: plan.preset, asset: comp, fileType: fileType) { throw MediaProcessError.unsupported(why) }
        guard let session = AVAssetExportSession(asset: comp, presetName: plan.preset) else { throw MediaProcessError.unsupported("The system cannot create this export.") }
        session.outputURL = staged
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = false
        if let items = try? await built.source.load(.metadata), !items.isEmpty { session.metadata = items }
        let poll = Task.detached {
            while !Task.isCancelled { progress(Double(session.progress)); try? await Task.sleep(nanoseconds: 150_000_000) }
        }
        defer { poll.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
        } onCancel: { session.cancelExport() }
        if Task.isCancelled || session.status == .cancelled { throw MediaProcessError.cancelled }
        guard session.status == .completed else { throw MediaProcessError.failed(session.error?.localizedDescription ?? "the system did not finish the export") }
        progress(1)
    }

    /// Decodes the audio to 16-bit PCM in a WAV file.
    static func writeWAV(source: URL, plan: ProcessingPlan, range: ClosedRange<Double>?, to target: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: MediaAlias.url(for: source))
        let tracks = try await asset.load(.tracks)
        guard let track = tracks.first(where: { plan.audioTrackIDs.contains($0.trackID) }) else { throw MediaProcessError.invalid("That audio track is not in the file.") }
        let total = max(0.001, (try await asset.load(.duration)).seconds)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw MediaProcessError.unsupported("The system cannot decode this audio.") }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: target, fileType: .wav)
        var channels = 2, rate = 44100.0
        if let d = (try await track.load(.formatDescriptions)).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            if asbd.mChannelsPerFrame > 0 { channels = Int(min(asbd.mChannelsPerFrame, 8)) }
            if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }
        }
        var out = settings; out[AVNumberOfChannelsKey] = channels; out[AVSampleRateKey] = rate
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: out)
        guard writer.canAdd(input) else { throw MediaProcessError.unsupported("The system cannot write WAV with these settings.") }
        writer.add(input)
        guard reader.startReading() else { throw MediaProcessError.failed(reader.error?.localizedDescription ?? "the audio could not be read") }
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let queue = DispatchQueue(label: "browsersetu.wav")
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if Task.isCancelled { reader.cancelReading(); input.markAsFinished(); c.resume(); return }
                        guard let buffer = output.copyNextSampleBuffer() else { input.markAsFinished(); c.resume(); return }
                        progress(min(0.99, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / total))
                        if !input.append(buffer) { input.markAsFinished(); c.resume(); return }
                    }
                }
            }
        } onCancel: { reader.cancelReading() }
        if Task.isCancelled { writer.cancelWriting(); throw MediaProcessError.cancelled }
        guard reader.status != .failed else { writer.cancelWriting(); throw MediaProcessError.failed(reader.error?.localizedDescription ?? "the audio could not be read") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw MediaProcessError.failed(writer.error?.localizedDescription ?? "the file could not be written") }
        progress(1)
    }

    // MARK: Checking the result

    struct Verification: Equatable, Sendable {
        var facts: MediaFacts
        /// Copied, not re-encoded, and the output's codecs are the source's.
        var lossless: Bool
        var note: String?
    }

    /// Reads the output back. It must have the tracks asked for, the codecs expected, a length close to the expected one, and (for video) a picture that decodes and (for audio) a sample that does.
    static func verify(output: URL, plan: ProcessingPlan, expectedDuration: Double?, sourceFacts: MediaFacts, tolerance: Double) async throws -> Verification {
        let facts: MediaFacts
        do { facts = try await MediaFactsReader.read(output) } catch { throw MediaProcessError.outputInvalid("it cannot be read back") }
        if !plan.videoTrackIDs.isEmpty, facts.video.isEmpty { throw MediaProcessError.outputInvalid("the video is missing") }
        if !plan.audioTrackIDs.isEmpty, facts.audio.isEmpty { throw MediaProcessError.outputInvalid("the audio is missing") }
        if plan.container == .wav, facts.container != "WAV" { throw MediaProcessError.outputInvalid("it is not a WAV file") }
        guard let duration = facts.durationSeconds, duration > 0 else { throw MediaProcessError.outputInvalid("it has no length") }
        if let expected = expectedDuration, abs(duration - expected) > tolerance { throw MediaProcessError.outputInvalid("its length is \(String(format: "%.2f", duration)) s, not about \(String(format: "%.2f", expected)) s") }
        let codecs = (facts.video + facts.audio).compactMap(\.fourCC)
        for expected in plan.expectedCodecs where !codecs.contains(expected) && !(expected == "avc1" && codecs.contains("avc3")) && !(expected == "hvc1" && codecs.contains("hev1")) && !(expected == "aac " && codecs.contains("mp4a")) {
            throw MediaProcessError.outputInvalid("it holds \(codecs.joined(separator: ", ")), not \(expected)")
        }
        // A picture and a stretch of sound that actually decode.
        if !facts.video.isEmpty {
            do { _ = try await MediaThumbnailer().thumbnail(for: output, at: min(duration / 2, max(0, duration - 0.05)), dimension: 64, isPrivate: true, tolerance: 1) }
            catch { throw MediaProcessError.outputInvalid("its picture does not decode") }
        }
        if !facts.audio.isEmpty { try await decodeSomeAudio(output) }
        // Lossless is claimed only for copied tracks whose codecs match the source's.
        var lossless = false
        if plan.passthrough {
            let source = (sourceFacts.video.filter { plan.videoTrackIDs.contains($0.id) } + sourceFacts.audio.filter { plan.audioTrackIDs.contains($0.id) }).compactMap(\.fourCC).sorted()
            lossless = source == codecs.sorted()
        }
        return Verification(facts: facts, lossless: lossless, note: nil)
    }

    private static func decodeSomeAudio(_ url: URL) async throws {
        let asset = AVURLAsset(url: MediaAlias.url(for: url))
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { throw MediaProcessError.outputInvalid("its audio cannot be opened") }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(out) else { throw MediaProcessError.outputInvalid("its audio cannot be decoded") }
        reader.add(out)
        guard reader.startReading(), out.copyNextSampleBuffer() != nil else { throw MediaProcessError.outputInvalid("its audio does not decode") }
        reader.cancelReading()
    }
}
