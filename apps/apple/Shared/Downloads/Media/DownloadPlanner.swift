import Foundation

// The one place that decides what can be saved from a source and exactly how. Every list of choices in the app (the media picker, the category list, the Download sheet, the extractor results)
// comes from here, so the same media always offers the same choices. A choice is listed as available only when a plan the existing engines can carry out exists for it; otherwise it is listed
// with the reason. Nothing here fetches anything, makes a file, or owns a task: it describes, and `SourceSaveOperation` (with the coordinator) carries out.

/// One thing the person can choose, with what it takes to make it.
struct PlannedOption: Identifiable, Equatable, Sendable {
    var option: OutputOption
    /// How it is carried out; nil when it cannot be (the option then has its reason).
    var choice: SourceSaveOperation.Choice?
    /// The exact source format this choice uses, carried to the download unchanged.
    var representation: NormalizedRepresentation?
    /// The sound track used (for a join or for sound made from a track), chosen by the planner and carried unchanged.
    var audio: NormalizedRepresentation?
    /// For a stream: the playlist's own id of the chosen rendition.
    var streamID: String?
    var id: String { option.id + "|" + (representation?.pickKey ?? streamID ?? "") }
    /// True when the only thing missing is the optional media processing tool: the screens then offer to enable it instead of just saying no.
    var requiresProcessingTool: Bool = false
    var isExecutable: Bool { option.isAvailable && choice != nil }
}

enum DownloadPlanner {
    /// Containers the system's media engine reads and joins; others are carried as they are.
    static var systemContainers: Set<String> { NormalizedMediaSource.systemContainers }

    /// Whether the optional media processing tool (joins WebM, takes sound out of WebM/Opus) is installed.
    static var processingReady: Bool {
        #if os(macOS)
        FFmpegTool.isReady
        #else
        false
        #endif
    }
    static let needsProcessingTool = "Needs the optional media processing tool (Settings › Downloads)."

    static func options(for source: NormalizedMediaSource, manifest: MediaManifest? = nil, encoders: (m4a: Bool, mp3: Bool) = (LocalEncoders.m4a, LocalEncoders.mp3), processing: Bool = DownloadPlanner.processingReady) -> [PlannedOption] {
        switch source.shape {
        case .manifest: return manifestOptions(manifest, encoders: encoders)
        case .tracks(let reps): return trackOptions(reps, encoders: encoders, processing: processing)
        }
    }

    /// The sound track to use: one the system's media engine can read, then the highest bitrate (or largest file), then the first listed. Never merely the first in the list.
    static func bestAudio(_ audios: [NormalizedRepresentation]) -> NormalizedRepresentation? {
        audios.enumerated().max { l, r in
            func score(_ a: NormalizedRepresentation) -> (Int, Int, Int, Int64) { (systemContainers.contains(a.container) ? 1 : 0, a.languagePreference ?? 0, a.bitrate ?? 0, a.bytes ?? 0) }
            let (x, y) = (score(l.element), score(r.element))
            return x != y ? x < y : l.offset > r.offset
        }?.element
    }

    // MARK: Direct files and separate tracks

    private static func trackOptions(_ reps: [NormalizedRepresentation], encoders: (m4a: Bool, mp3: Bool), processing: Bool) -> [PlannedOption] {
        var out: [PlannedOption] = []
        let videos = reps.filter { $0.role == .video }.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        let audios = reps.filter { $0.role == .audio }
        let muxed = reps.filter { $0.role == .muxed }.sorted { ($0.height ?? 0) > ($1.height ?? 0) }

        for m in muxed {
            out.append(PlannedOption(option: OutputOption(kind: .original, title: "Video with sound · " + m.label, provenance: "Source quality", detail: m.codecs, formatID: m.formatID), choice: .original, representation: m))
        }
        for v in videos {
            if let a = bestAudio(audios) {
                if systemContainers.contains(v.container) && systemContainers.contains(a.container) {
                    out.append(PlannedOption(option: OutputOption(kind: .video, title: "Video with sound · " + v.label, provenance: "Source quality, joined", detail: "Separate picture and sound are joined into one MP4 without re-encoding", formatID: v.formatID), choice: .joined, representation: v, audio: a))
                } else {
                    // The system's media engine cannot join these (WebM and the like). The processing tool joins them without re-encoding; when it is not installed the choice is listed, with what it needs.
                    let box = FFmpegContainerChoice.name(video: v, audio: a)
                    out.append(PlannedOption(option: OutputOption(kind: .video, title: "Video with sound · " + v.label, provenance: "Source quality, joined", detail: "Picture and sound are joined into one \(box.uppercased()) file without re-encoding. It plays in \(box == "webm" ? "browsers, VLC and most players" : "VLC and most players"); QuickTime cannot open it.",
                                                                  unavailableReason: processing ? nil : needsProcessingTool, formatID: v.formatID),
                                             choice: processing ? .joinedFFmpeg(container: box) : nil, representation: v, audio: a, requiresProcessingTool: !processing))
                    // The system's media engine cannot join these (WebM and the like): the picture is also offered on its own, and says so.
                    out.append(PlannedOption(option: OutputOption(kind: .video, title: "Picture only · " + v.label, provenance: "Source quality", detail: "The sound is a separate \(a.container.uppercased()) file that cannot be joined with this \(v.container.uppercased()) picture", formatID: v.formatID), choice: .original, representation: v))
                }
            } else {
                out.append(PlannedOption(option: OutputOption(kind: .video, title: "Video without sound · " + v.label, provenance: "Source quality", detail: "The source offers no separate audio", formatID: v.formatID), choice: .original, representation: v))
            }
        }
        for a in audios {
            out.append(PlannedOption(option: OutputOption(kind: .audioOriginal, title: "Original audio · " + a.label, provenance: "Source quality", detail: a.language, formatID: a.formatID), choice: .original, representation: a))
        }
        // Sound made from a file or track on this Mac. The first audio track (or the best combined file) is the source; which one is carried in the option.
        if let source = bestAudio(audios) ?? muxed.first(where: { systemContainers.contains($0.container) }) ?? muxed.first {
            let readable = systemContainers.contains(source.container)
            let why = readable ? nil : "Audio cannot be taken from a \(source.container.uppercased()) file by the system's media engine."
            out.append(PlannedOption(option: OutputOption(kind: .audioM4A, title: "Audio only (M4A)", provenance: "Converted", unavailableReason: !encoders.m4a ? "This Mac cannot write M4A." : why, formatID: source.formatID),
                                     choice: (encoders.m4a && readable) ? .audioM4A : nil, representation: source, audio: source.role == .audio ? source : nil))
            out.append(PlannedOption(option: OutputOption(kind: .audioMP3, title: "Audio as MP3", provenance: "Converted", unavailableReason: !encoders.mp3 ? "This build has no MP3 encoder. Save the original audio or M4A instead." : why, formatID: source.formatID),
                                     choice: (encoders.mp3 && readable) ? .audioMP3(kbps: 192) : nil, representation: source, audio: source.role == .audio ? source : nil))
            if !readable {
                // The system's media engine cannot read this container: the processing tool decodes it. M4A is made with the tool's AAC encoder; MP3 goes through a lossless intermediate into the app's own LAME.
                let i = out.count - 2, j = out.count - 1
                out[i].option.unavailableReason = processing ? nil : needsProcessingTool; out[i].choice = processing ? .audioM4AFFmpeg : nil; out[i].requiresProcessingTool = !processing
                if encoders.mp3 { out[j].option.unavailableReason = processing ? nil : needsProcessingTool; out[j].choice = processing ? .audioMP3FFmpeg(kbps: 192) : nil; out[j].requiresProcessingTool = !processing }
            }
        }
        return out
    }

    // MARK: Streams

    private static func manifestOptions(_ m: MediaManifest?, encoders: (m4a: Bool, mp3: Bool)) -> [PlannedOption] {
        guard let m else {
            // Not read yet: the stream engine lists the qualities when the playlist is read; until then there is one honest entry.
            return [PlannedOption(option: OutputOption(kind: .original, title: "Video from the stream", provenance: "Source quality", detail: "Qualities are read from the playlist first"), choice: .original, representation: nil),
                    PlannedOption(option: OutputOption(kind: .audioM4A, title: "Audio only (M4A)", provenance: "Source quality", detail: "The stream's own audio, if it lists it separately", unavailableReason: encoders.m4a ? nil : "This Mac cannot write M4A."), choice: encoders.m4a ? .audioM4A : nil, representation: nil),
                    PlannedOption(option: OutputOption(kind: .audioMP3, title: "Audio as MP3", provenance: "Converted", unavailableReason: encoders.mp3 ? nil : "This build has no MP3 encoder."), choice: encoders.mp3 ? .audioMP3(kbps: 192) : nil, representation: nil)]
        }
        var out: [PlannedOption] = []
        for v in m.videos {
            let name = VideoOptions.heightName(v.height) ?? v.label
            let why: String? = v.isDownloadable ? MediaCodecs.outputWarning(v) : (v.unsupported ?? "This rendition cannot be downloaded.")
            let detail = [MediaCodecs.summary(v), v.hdr.flatMap { $0 == "SDR" ? nil : $0 }].compactMap { $0 }.joined(separator: " · ")
            // A rendition the MP4 cannot hold is still listed, with the reason, rather than silently dropped.
            out.append(PlannedOption(option: OutputOption(kind: .video, title: name + (v.frameRate.map { " · \(Int($0.rounded())) fps" } ?? ""), provenance: "Source quality", detail: detail, unavailableReason: why, formatID: v.id),
                                     choice: why == nil ? .original : nil, representation: nil, streamID: v.id))
        }
        let hasAudio = !m.audios.filter(\.isDownloadable).isEmpty
        if hasAudio || m.videos.contains(where: { $0.kind == .muxed }) {
            let why: String? = !encoders.m4a ? "This Mac cannot write M4A." : (hasAudio ? nil : "This stream's audio is inside its video; separating it is not supported yet.")
            out.append(PlannedOption(option: OutputOption(kind: .audioM4A, title: "Audio only (M4A)", provenance: hasAudio ? "Source quality" : "Converted", detail: hasAudio ? "The stream's own audio, not re-encoded" : nil, unavailableReason: why), choice: why == nil ? .audioM4A : nil, representation: nil))
            out.append(PlannedOption(option: OutputOption(kind: .audioMP3, title: "Audio as MP3", provenance: "Converted", unavailableReason: !encoders.mp3 ? "This build has no MP3 encoder." : (hasAudio ? nil : "This stream's audio is inside its video; separating it is not supported yet.")), choice: (encoders.mp3 && hasAudio) ? .audioMP3(kbps: 192) : nil, representation: nil))
        }
        return out
    }
}


/// Which container a join of separate picture and sound goes into: WebM holds VP8/VP9/AV1 with Opus/Vorbis; anything else goes into Matroska, which holds all of them. Streams are copied, never re-encoded.
enum FFmpegContainerChoice {
    static func family(_ codecs: String?) -> String? {
        guard let c = codecs?.lowercased() else { return nil }
        for part in c.split(separator: ",") {
            let s = part.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("vp09") || s == "vp9" { return "vp9" }
            if s.hasPrefix("vp08") || s == "vp8" { return "vp8" }
            if s.hasPrefix("av01") || s == "av1" { return "av1" }
            if s == "opus" { return "opus" }
            if s == "vorbis" { return "vorbis" }
        }
        return nil
    }
    static func name(video: NormalizedRepresentation, audio: NormalizedRepresentation) -> String {
        if let v = family(video.codecs), let a = family(audio.codecs), ["vp8", "vp9", "av1"].contains(v), ["opus", "vorbis"].contains(a) { return "webm" }
        return "mkv"
    }
}
