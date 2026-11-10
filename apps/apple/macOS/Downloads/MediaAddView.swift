import SwiftUI

/// Step two of adding a stream playlist (HLS or MPEG-DASH): what the playlist offers, and what the person wants from it. Only the playlist is fetched to show this; no video or audio
/// is fetched until Download is pressed, and then only the chosen tracks.
@MainActor
final class MediaAddModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed(String) }
    let coordinator: DownloadCoordinator
    let url: URL
    @Published var phase = Phase.loading
    @Published var manifest: MediaManifest?
    @Published var video: String?
    @Published var audio: String? { didSet { extraAudios.remove(audio ?? ""); if audio == nil { extraAudios = [] } } }
    @Published var subtitles = Set<String>()
    /// DX-08: further audio tracks (other languages) to put in the same file.
    @Published var extraAudios = Set<String>()
    /// DX-08: what to do if the chosen quality cannot be read when the download starts. Off: stop and say so. On: the next best quality of the same kind, with the same sound.
    @Published var allowFallback = false
    /// Save only the sound, in an M4A file (the stream's own audio, not re-encoded). Off: the picture and sound together.
    @Published var audioOnly = false {
        didSet {
            guard let m = manifest, oldValue != audioOnly else { return }
            let d = m.defaultSelection(preferring: preferences)
            if audioOnly { video = nil; audio = audio ?? m.audios.first(where: \.isDownloadable)?.id; subtitles = [] }
            else { video = d.video; audio = d.audio; subtitles = Set(d.subtitles) }
        }
    }
    /// Audio can be saved alone only when the stream lists its audio separately.
    var canSaveAudioOnly: Bool { manifest.map { m in m.audios.contains(where: \.isDownloadable) } ?? false }
    @Published var name: String
    @Published var busy = false
    @Published var problem: String?
    private var task: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    let preferences: MediaPreferences
    /// Fixed when the preview is made and used for every fetch it causes: the playlist, the plan and the download.
    let origin: DownloadRequestOrigin

    init(coordinator: DownloadCoordinator, url: URL, name: String?, preferences: MediaPreferences = MediaPreferences(), origin: DownloadRequestOrigin = .user) {
        self.coordinator = coordinator; self.url = url; self.preferences = preferences; self.origin = origin
        self.name = name ?? Self.suggestedName(url)
    }

    /// A manifest called "master.m3u8" or "index.m3u8" is named after a more telling part of its address instead: the one naming rule (FilenameResolver) decides.
    static func suggestedName(_ url: URL) -> String { FilenameResolver.streamName(from: url) }

    /// Streams that carry sound and nothing else (an audio-only playlist lists its variants as plain streams, so the manifest itself does not say "audio").
    static func isAudioOnly(_ s: MediaStream) -> Bool {
        if s.kind == .audio { return true }
        guard s.kind != .muxed || s.width == nil, s.width == nil, s.height == nil, let codecs = s.codecs?.lowercased(), !codecs.isEmpty else { return false }
        let audio = ["mp4a", "ac-3", "ec-3", "opus", "flac", "vorbis", "mp3"]
        return codecs.split(separator: ",").allSatisfy { part in audio.contains { part.trimmingCharacters(in: .whitespaces).hasPrefix($0) } }
    }

    func load() {
        task?.cancel()
        phase = .loading
        task = Task {
            do {
                let m = try await coordinator.media.inspect(url, origin: origin)
                guard !Task.isCancelled else { return }
                manifest = m
                let d = m.defaultSelection(preferring: preferences)
                video = d.video; audio = d.audio; subtitles = Set(d.subtitles)
                phase = m.unsupported != nil ? .failed(m.unsupported ?? "") : (m.hasDownloadableStream ? .ready : .failed("None of the streams in this playlist can be downloaded."))
            } catch { if !Task.isCancelled { phase = .failed((error as? LocalizedError)?.errorDescription ?? "The playlist could not be read.") } }
        }
    }
    func cancel() { task?.cancel(); startTask?.cancel() }

    var selectedVideo: MediaStream? { manifest?.videos.first { $0.id == video } }
    /// A stream that already carries its sound needs no separate audio.
    var needsAudioChoice: Bool { selectedVideo.map { $0.kind != .muxed } ?? true }
    var choice: MediaChoice {
        MediaChoice(video: video, audio: needsAudioChoice ? audio : nil, subtitles: subtitles.sorted(), extraAudios: needsAudioChoice && audio != nil ? extraAudios.subtracting([audio ?? ""]).filter { id in manifest?.audios.contains { $0.id == id } == true }.sorted() : [])
    }
    /// How many audio tracks the file will hold.
    var audioTrackCount: Int { selectedVideo?.kind == .muxed ? 1 : ((audio == nil ? 0 : 1) + choice.extraAudios.count) }
    var problems: [MediaChoiceProblem] { manifest.map { $0.problems(with: choice) } ?? [] }
    var canDownload: Bool { phase == .ready && !busy && problems.isEmpty }

    func start(done: @escaping () -> Void) {
        guard canDownload, let manifest else { return }
        busy = true; problem = nil
        let choice = self.choice
        let fallbacks = allowFallback ? (selectedVideo.map { MediaManifest.standIns(for: $0, in: manifest.videos.filter(\.isDownloadable)).map(\.id) } ?? []) : []
        let allow = allowFallback
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? Self.suggestedName(url) : name
        startTask = Task {
            do {
                let plan = try await coordinator.media.plan(for: manifest, selection: choice, title: title, origin: origin, allowFallback: allow, fallbacks: fallbacks, sourceURL: url)
                try Task.checkCancellation()
                _ = try await coordinator.media.add(plan, name: title, source: url, origin: origin)
                done()
            } catch is CancellationError {} catch { problem = (error as? LocalizedError)?.errorDescription ?? "The download could not be started." }
            busy = false
        }
    }
}

struct MediaAddView: View {
    @ObservedObject var model: MediaAddModel
    var done: () -> Void

    private static func length(_ s: Double) -> String {
        let f = DateComponentsFormatter(); f.allowedUnits = s >= 3600 ? [.hour, .minute, .second] : [.minute, .second]; f.unitsStyle = .abbreviated
        return f.string(from: s) ?? ""
    }

    private func label(_ s: MediaStream) -> String {
        var extras: [String] = []
        if let h = s.hdr, h != "SDR" { extras.append(h) }
        if let c = s.channels { extras.append(c == 1 ? "mono" : (c == 2 ? "stereo" : (c == 6 ? "5.1" : (c == 8 ? "7.1" : "\(c) channels")))) }
        switch s.role { case "commentary": extras.append("commentary"); case "description": extras.append("audio description"); default: break }
        if s.forced == true { extras.append("forced") }
        if s.accessibility == true { extras.append("for the hard of hearing") }
        return ([s.label, s.resolutionText, s.frameRateText, s.bitrateText, MediaCodecs.summary(s)].compactMap { $0 } + extras).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stream").font(.system(size: 13, weight: .semibold))
            Text(model.url.host ?? "").font(.system(size: 11.5)).foregroundStyle(.secondary)
            switch model.phase {
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the playlist…").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            case .ready:
                if let m = model.manifest { choices(m) }
            }
            if let p = model.problem { Text(p).font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.cancel(); done() }
                Button("Download") { model.start(done: done) }.buttonStyle(.borderedProminent).disabled(!model.canDownload).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 380)
        .onAppear { if model.manifest == nil { model.load() } }
        .animation(.easeInOut(duration: 0.18), value: model.phase)
    }

    @ViewBuilder private func choices(_ m: MediaManifest) -> some View {
        let format = m.format == .hls ? "HLS" : "MPEG-DASH"
        Text("\(format)" + (m.duration.map { " · \(Self.length($0))" } ?? "")).font(.system(size: 11.5)).foregroundStyle(.secondary)
        TextField("Save as", text: $model.name).textFieldStyle(.roundedBorder).accessibilityLabel("Save as")
        if model.canSaveAudioOnly {
            Picker("Save", selection: $model.audioOnly) {
                Text("Video with sound").tag(false)
                Text("Audio only (M4A)").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("media-save-kind")
            if model.audioOnly {
                Text("The stream's own audio, saved as M4A without re-encoding.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if !m.videos.isEmpty, !model.audioOnly {
            Picker(m.videos.allSatisfy(MediaAddModel.isAudioOnly) ? "Quality" : "Video", selection: $model.video) {
                ForEach(m.videos) { s in Text(label(s) + (s.isDownloadable ? "" : " (not supported)")).tag(Optional(s.id)).disabled(!s.isDownloadable) }
            }.pickerStyle(.menu)
        }
        if !m.audios.isEmpty, model.needsAudioChoice {
            Picker("Audio", selection: $model.audio) {
                Text("None").tag(String?.none)
                ForEach(m.audios.filter(\.isDownloadable)) { s in Text(label(s)).tag(Optional(s.id)) }
            }.pickerStyle(.menu)
        }
        let others = m.audios.filter { $0.isDownloadable && $0.id != model.audio }
        if model.needsAudioChoice, !others.isEmpty, model.audio != nil {
            VStack(alignment: .leading, spacing: 3) {
                Text("Also include these audio tracks").font(.system(size: 11.5)).foregroundStyle(.secondary)
                ForEach(others) { s in
                    Toggle(label(s), isOn: Binding(get: { model.extraAudios.contains(s.id) }, set: { on in if on { model.extraAudios.insert(s.id) } else { model.extraAudios.remove(s.id) } }))
                        .toggleStyle(.checkbox).font(.system(size: 11.5))
                }
            }
        }
        if m.videos.filter(\.isDownloadable).count > 1 {
            Picker("If that quality can't be read", selection: $model.allowFallback) {
                Text("Stop and tell me").tag(false)
                Text("Use the next best quality").tag(true)
            }.pickerStyle(.menu).font(.system(size: 11.5))
        }
        let subs = m.subtitles.filter(\.isDownloadable)
        if !subs.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Subtitles (saved as separate files)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                ForEach(subs) { s in
                    Toggle(label(s) + (s.language.map { " (\($0))" } ?? ""), isOn: Binding(get: { model.subtitles.contains(s.id) }, set: { on in if on { model.subtitles.insert(s.id) } else { model.subtitles.remove(s.id) } }))
                        .toggleStyle(.checkbox).font(.system(size: 11.5))
                }
            }
        }
        if let bytes = m.estimatedBytes(for: model.choice) {
            Text("About \(DownloadStats.bytes(bytes)), estimated from the advertised bitrates.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if model.audioTrackCount > 1 { Text("\(model.audioTrackCount) audio tracks go into the one file.").font(.system(size: 11)).foregroundStyle(.secondary) }
        ForEach(Array(model.problems.enumerated()), id: \.offset) { Text($0.element.text).font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        ForEach(Array(m.warnings.prefix(3).enumerated()), id: \.offset) { Text($0.element).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        if let v = model.selectedVideo, let w = MediaCodecs.outputWarning(v) { Text(w).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        Text("Only the tracks you choose are downloaded, then joined into one file in your Downloads folder. Streams that are live, encrypted or copy-protected are not supported.")
            .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}
