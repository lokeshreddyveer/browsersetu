import SwiftUI
import AVKit
import AVFoundation
import QuickLookUI

// The media part of the details panel: a picture, what the file is, and the things that can be done with it. Everything here is local: nothing is fetched, and the original file is
// never changed (a conversion makes a new file beside it).

struct MediaToolsSection: View {
    let context: MediaToolsContext
    @ObservedObject var service: MediaProcessingService
    @State private var facts: MediaFacts?
    @State private var thumbnail: CGImage?
    @State private var problem: String?
    @State private var sheet: Sheet?
    enum Sheet: Identifiable { case preview, convert; var id: Int { self == .preview ? 0 : 1 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 130).clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Picture from the video")
            }
            if let facts {
                factLine("Container", facts.container)
                if let v = facts.video.first { factLine("Video", [v.codec, facts.displaySize.map { "\($0.width)×\($0.height)" }, v.frameRate.map { String(format: "%.3g fps", $0) }, v.rotation.map { "turned \($0)°" }].compactMap { $0 }.joined(separator: " · ")) }
                ForEach(facts.audio) { a in factLine(facts.audio.count > 1 ? "Audio" + (a.language.map { " (\($0))" } ?? "") : "Audio", [a.codec, a.channels.map { "\($0) ch" }, a.sampleRate.map { String(format: "%.1f kHz", $0 / 1000) }].compactMap { $0 }.joined(separator: " · ")) }
                if !facts.subtitles.isEmpty { factLine("Subtitles", facts.subtitles.map { ($0.language ?? "unknown") + " (" + ($0.codec ?? "?") + ")" }.joined(separator: ", ")) }
                if let d = facts.durationSeconds { factLine("Length", DownloadStats.duration(d)) }
                if facts.container == nil { Text("The kind of file is not recognised from its contents.").font(.caption).foregroundStyle(.secondary) }
            }
            if let problem { Text(problem).font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 6) {
                Button("Preview") { sheet = .preview }.controlSize(.small)
                if context.isAudioVideo { Button("Convert…") { sheet = .convert }.controlSize(.small) }
            }
            if context.isPrivate { Text("Private download: no picture or history is kept after you close this.").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            jobs
        }
        .task(id: context.file) { await load() }
        .sheet(item: $sheet) { which in
            switch which {
            case .preview: MediaPreviewSheet(context: context) { sheet = nil }
            case .convert: MediaConvertSheet(context: context, facts: facts, service: service) { sheet = nil }
            }
        }
    }

    private func factLine(_ title: String, _ value: String?) -> some View {
        Group {
            if let value, !value.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    Text(value).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var jobs: some View {
        let mine = service.jobs.filter { $0.source == context.file }
        ForEach(mine) { job in MediaJobRow(job: job, service: service) }
    }

    private func load() async {
        problem = nil
        if context.isAudioVideo {
            do { facts = try await MediaFactsReader.read(context.file) } catch { facts = nil; problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            if context.kind == .video, facts?.video.isEmpty == false {
                thumbnail = try? await MediaThumbnailer.shared.thumbnail(for: context.file, dimension: 400, isPrivate: context.isPrivate)
            }
        }
    }
}

struct MediaJobRow: View {
    let job: MediaJob
    @ObservedObject var service: MediaProcessingService
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(job.operation.title).font(.system(size: 11.5, weight: .medium))
            if job.state == .processing { ProgressView(value: job.progress).controlSize(.small) }
            HStack(spacing: 6) {
                Text(job.state.title).font(.system(size: 11)).foregroundStyle(job.state.isFinal && job.state != .completed ? Color.orange : Color.secondary).lineLimit(3)
                if job.state == .completed, let out = job.output {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([out]) }.buttonStyle(.borderless).font(.system(size: 11))
                    if job.lossless == true { Text("copied, not re-encoded").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                    else if job.lossless == false { Text("encoded again").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }
                Spacer()
                if !job.state.isFinal { Button("Cancel") { service.cancel(job.id) }.buttonStyle(.borderless).font(.system(size: 11)) }
                else {
                    if job.state != .completed { Button("Try Again") { service.retry(job.id) }.buttonStyle(.borderless).font(.system(size: 11)) }
                    Button("Dismiss") { service.dismiss(job.id) }.buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            if let note = job.note { Text(note).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
        }
        .padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Preview

struct MediaPreviewSheet: View {
    let context: MediaToolsContext
    let done: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(context.file.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle); Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }.padding(12)
            Divider()
            Group {
                switch context.kind {
                case .video, .audio: PlayerPane(url: context.file)
                case .image, .document: QuickLookPane(url: context.file)
                case .unsupported(let why): Text(why).foregroundStyle(.secondary).padding()
                }
            }
            .frame(minWidth: 560, minHeight: 360)
        }
    }
}

private struct PlayerPane: View {
    let url: URL
    @State private var player = AVPlayer()
    @State private var audio: AVMediaSelectionGroup?
    @State private var legible: AVMediaSelectionGroup?
    @State private var error: String?
    var body: some View {
        VStack(spacing: 6) {
            VideoPlayer(player: player)
            if let error { Text(error).foregroundStyle(.orange).font(.caption).padding(.horizontal) }
            HStack {
                if let audio, audio.options.count > 1 { selector("Audio", audio) }
                if let legible, !legible.options.isEmpty { selector("Subtitles", legible, allowOff: true) }
                Spacer()
            }.padding([.horizontal, .bottom], 8)
        }
        .task(id: url) {
            let item = AVPlayerItem(url: MediaAlias.url(for: url))
            player.replaceCurrentItem(with: item)
            let asset = item.asset
            if let a = try? await asset.loadMediaSelectionGroup(for: .audible) { audio = a }
            if let l = try? await asset.loadMediaSelectionGroup(for: .legible) { legible = l }
            if let status = try? await asset.load(.isPlayable), !status { error = "The system cannot play this file." }
        }
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }
    private func selector(_ title: String, _ group: AVMediaSelectionGroup, allowOff: Bool = false) -> some View {
        Menu(title) {
            if allowOff { Button("Off") { player.currentItem?.select(nil, in: group) } }
            ForEach(group.options, id: \.self) { option in Button(option.displayName) { player.currentItem?.select(option, in: group) } }
        }.fixedSize()
    }
}

private struct QuickLookPane: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}

// MARK: - Conversion

struct MediaConvertSheet: View {
    let context: MediaToolsContext
    let facts: MediaFacts?
    @ObservedObject var service: MediaProcessingService
    let done: () -> Void

    struct Choice: Identifiable { var id: String { group + "|" + title }; var title: String; var group: String; var operation: MediaOperation; var unsupported: String? }
    @State private var choices: [Choice] = []
    @State private var selected: String?
    @State private var audioTrack: Int32?
    @State private var start = "0"
    @State private var end = ""
    @State private var exactTrim = false
    @State private var destination: URL?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Convert “\(context.file.lastPathComponent)”").font(.headline).lineLimit(1).truncationMode(.middle)
            Text("The original is never changed; the result is a new file next to it.").font(.caption).foregroundStyle(.secondary)
            if let facts { Text(summary(facts)).font(.caption).foregroundStyle(.secondary) }
            List(selection: $selected) {
                ForEach(Dictionary(grouping: choices, by: \.group).keys.sorted(), id: \.self) { group in
                    Section(group) {
                        ForEach(choices.filter { $0.group == group }) { choice in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.title).foregroundStyle(choice.unsupported == nil ? Color.primary : Color.secondary)
                                if let why = choice.unsupported { Text(why).font(.caption).foregroundStyle(.secondary) }
                            }.tag(choice.id).disabled(choice.unsupported != nil)
                        }
                    }
                }
            }.frame(minHeight: 220)
            if let facts, facts.audio.count > 1 {
                Picker("Audio track", selection: $audioTrack) {
                    Text("All tracks").tag(Int32?.none)
                    ForEach(facts.audio) { Text(($0.language ?? "Track \($0.id)") + " · " + ($0.codec ?? "?")).tag(Int32?.some($0.id)) }
                }
            }
            HStack {
                Text("Trim from").font(.caption); TextField("0", text: $start).frame(width: 70)
                Text("to").font(.caption); TextField("seconds", text: $end).frame(width: 70)
                Toggle("Exact cut (encodes again)", isOn: $exactTrim).font(.caption)
                Button("Trim") { startTrim() }.disabled(!validTrim)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("Saved in " + (destination ?? context.file.deletingLastPathComponent()).abbreviatedPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Choose Folder…") { chooseFolder() }.controlSize(.small)
                Spacer()
                Button("Close", action: done)
                Button("Start") { startSelected() }.keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }
        .padding(16).frame(width: 520)
        .task { await buildChoices() }
        .onChange(of: audioTrack) { _, _ in Task { await buildChoices() } }
    }

    private func summary(_ f: MediaFacts) -> String {
        [f.container, f.video.first?.codec, f.audio.first?.codec, f.durationSeconds.map(DownloadStats.duration)].compactMap { $0 }.joined(separator: " · ")
    }

    private func buildChoices() async {
        guard let facts else { choices = []; return }
        var out: [Choice] = []
        let hasVideo = !facts.video.isEmpty
        var ops: [(String, String, MediaOperation)] = []
        if hasVideo {
            for c in [OutputContainer.mp4, .mov, .m4v] { ops.append(("Change container (no re-encoding)", "Save as \(c.title)", .remux(c))) }
            for codec in [MediaVideoCodec.h264, .hevc] { for r in MediaResolution.allCases { ops.append(("Convert video (encodes again)", "\(codec == .h264 ? "H.264" : "HEVC") · \(r.title) · MP4", .convert(codec: codec, resolution: r, container: .mp4))) } }
        } else {
            ops.append(("Change container (no re-encoding)", "Save as M4A", .remux(.m4a)))
        }
        if !facts.audio.isEmpty {
            ops.append(("Extract audio", "M4A (AAC copied when it can be)", .extractAudio(.m4a, trackID: audioTrack)))
            ops.append(("Extract audio", "WAV (decoded to PCM)", .extractAudio(.wav, trackID: audioTrack)))
        }
        for subtitle in facts.subtitles { ops.append(("Subtitles", "Extract “\(subtitle.language ?? "unknown")” as WebVTT", .extractSubtitles(trackID: subtitle.id))) }
        for (group, title, op) in ops {
            var reason: String?
            do { _ = try await MediaProcessor.plan(op, facts: facts, audioTracks: audioTrack.map { [$0] }) } catch { if !isSubtitle(op) { reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription } }
            out.append(Choice(title: title, group: group, operation: op, unsupported: reason))
        }
        choices = out
    }
    private func isSubtitle(_ op: MediaOperation) -> Bool { if case .extractSubtitles = op { true } else { false } }

    private func startSelected() {
        guard let choice = choices.first(where: { $0.id == selected }) else { return }
        service.submit(source: context.file, operation: choice.operation, destination: destination, profileTag: "default", isPrivate: context.isPrivate, audioTracks: audioTrack.map { [$0] })
        message = nil; done()
    }

    private var validTrim: Bool {
        guard let s = Double(start), let e = Double(end), s.isFinite, e.isFinite, s >= 0, e > s else { return false }
        return e - s >= 0.1 && s < (facts?.durationSeconds ?? .infinity)
    }

    private func startTrim() {
        guard validTrim else { return }
        guard let s = Double(start), let e = Double(end) else { return }
        let container: OutputContainer = (facts?.video.isEmpty ?? true) ? .m4a : (context.file.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        service.submit(source: context.file, operation: .trim(start: s, end: e, mode: exactTrim ? .accurate : .fast, container: container), destination: destination, profileTag: "default", isPrivate: context.isPrivate, audioTracks: audioTrack.map { [$0] })
        done()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if service.isAuthorized(url) { destination = url; message = nil } else { message = "Results can only be saved inside your downloads folder." }
    }
}

private extension URL { var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath } }
private extension AVMediaSelectionOption { var displayNameOrFallback: String { displayName } }
