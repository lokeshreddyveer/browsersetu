import SwiftUI

/// "Media on This Page": what the page's own video and audio elements and media links say, listed so the person can choose. Finding is not downloading; nothing is fetched
/// except the playlist of one stream the person asks to look at.
struct MediaDiscoverySheet: View {
    @EnvironmentObject var model: BrowserModel
    var done: () -> Void
    var body: some View { MediaDiscoveryContent(store: model.mediaDiscovery, model: model, done: done) }
}

private struct MediaDiscoveryContent: View {
    @ObservedObject var store: MediaDiscoveryStore
    @ObservedObject var model: BrowserModel
    var done: () -> Void
    @State private var selection: String?
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", streams = "Streams", files = "Files", other = "Not supported"
        var id: String { rawValue }
        func matches(_ c: MediaCandidate) -> Bool {
            switch self {
            case .all: true
            case .streams: c.kind.isStream
            case .files: c.kind == .directVideo || c.kind == .directAudio
            case .other: { if case .unsupported = c.state { return true }; return false }()
            }
        }
    }

    private var shown: [MediaCandidate] { store.ranked.filter { filter.matches($0) } }
    private var selected: MediaCandidate? { store.candidates.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.unobservedFrames > 0 {
                Label("\(store.unobservedFrames) embedded frame\(store.unobservedFrames == 1 ? "" : "s") on this page cannot be looked into (a frame that may not run scripts, or that the browser cannot reach). Media inside \(store.unobservedFrames == 1 ? "it" : "them") is not listed.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                list.frame(minWidth: 340)
                Divider().opacity(0.5)
                detail.frame(width: 300)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(minWidth: 740, minHeight: 420)
        .animation(.easeInOut(duration: 0.18), value: store.candidates)
        .onDisappear { model.cancelMediaDiscovery() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle").foregroundStyle(Theme.accent)
            Text("Media on This Page").font(.system(size: 15, weight: .semibold))
            if store.isPrivate { Label("Private: kept in memory only", systemImage: "eye.slash").font(.system(size: 11)).foregroundStyle(.secondary) }
            Text("\(store.ranked.count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            if store.searching { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 130)
            Button { model.discoverMediaOnCurrentPage() } label: { Label("Find Again", systemImage: "arrow.clockwise") }.controlSize(.small)
            Button("Done", action: done).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var list: some View {
        Group {
            if shown.isEmpty {
                VStack(spacing: 6) {
                    Text(store.searching ? "Looking at this page…" : (store.notice ?? "Nothing found yet.")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Text("Only the page's own video and audio elements and media links are read. Media a page builds in memory cannot be downloaded.").font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal, 24)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(shown) { c in row(c).tag(c.id) }
                }.listStyle(.inset)
            }
        }
    }

    private func row(_ c: MediaCandidate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: c.kind == .directAudio ? "waveform" : c.kind.isStream ? "play.rectangle" : c.kind == .directVideo ? "film" : "exclamationmark.triangle").frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                Text([c.kind.label, c.qualityLabel, c.isEmbedded ? "Embedded player" : nil, c.host, c.duration.map(Self.length)].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(c.downloadSupported ? "Can download" : c.state.label).font(.system(size: 11)).foregroundStyle(color(c))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("media-row")
    }

    private func color(_ c: MediaCandidate) -> Color {
        if c.downloadSupported { return .green }
        switch c.state { case .unsupported, .failed, .authorizationRequired, .expired: return .orange; default: return .secondary }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ProviderPanel(model: model, flow: model.providerFlow, selected: selected)
                if let c = selected { candidateDetail(c) }
                else { Text("Choose an item to see what is known about it.").font(.system(size: 12)).foregroundStyle(.secondary) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func candidateDetail(_ c: MediaCandidate) -> some View {
        Text(c.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
        Text("\(c.mechanism.label) · \(c.kind.label)" + (c.pageHost.map { " · found on \($0)" } ?? "")).font(.system(size: 11.5)).foregroundStyle(.secondary)
        Text(c.display).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        provenance(c)
        if !c.canOpen, let note = ProviderPolicy.note(for: c) { Label(note, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        if let d = c.state.detail { Label(d, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        if c.kind == .directVideo || c.kind == .directAudio, c.state == .recognized {
            Text("A file. Its size has not been checked; that happens when you download it.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        if let m = c.manifest, c.state == .inspected { representations(m) }
        if c.kind.isStream, c.state == .recognized || c.state == .inspecting || { if case .failed = c.state { return true }; return false }() {
            Text("Looking reads the playlist only (no video or audio) to list the available qualities.").font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        outputs(c)
        // An in-memory player has nothing to fetch by itself; its page may be resolvable by the person's extractor (asked only when this is clicked, with consent).
        if c.kind == .blob || c.kind == .unknown, let page = Self.pageURL(of: c), case .extractor = DownloadRouter.route(.candidate(c, pageURL: page), RouterContext(isPrivate: store.isPrivate, extractorConfigured: ExtractorChoice.isAvailable)) {
            Button("Look Up This Page With My Extractor…") { model.openVideoSheet(forPage: page, isPrivate: store.isPrivate) }.controlSize(.small).accessibilityIdentifier("media-extractor-lookup")
        }
        HStack {
            if c.kind.isStream, c.state == .recognized || { if case .failed = c.state { return true }; return false }() {
                Button(c.state == .recognized ? "Look at Qualities" : "Try Again") { model.inspectDiscoveredMedia(c.id) }.controlSize(.small).disabled(store.isPrivate).accessibilityIdentifier("media-look")
            }
            if c.state == .inspecting { ProgressView().controlSize(.small) }
            if c.canOpen && !store.isPrivate {
                Button(c.kind.isStream ? "Choose & Download…" : (c.state == .discovered ? "Try to Download as File" : "Download")) {
                    // A stream continues in the add-download form (its quality step): this picker steps aside so the form is in front, not behind it. A plain file is added right here and the list stays for the next one.
                    if case .mediaPreview = model.openDiscoveredMedia(c.id) { done() }
                }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(c.kind.isStream && c.state != .inspected).accessibilityIdentifier("media-download")
            }
        }
    }

    /// What can be saved from this item, and what cannot with the reason; "Source quality" or "Converted" says whether the result is the source's own.
    @ViewBuilder private func outputs(_ c: MediaCandidate) -> some View {
        let state = VideoOptions.state(for: c)
        let list = VideoOptions.options(for: c)
        VStack(alignment: .leading, spacing: 3) {
            Text("Status: \(state.label)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).accessibilityIdentifier("media-resolution-state")
            if let d = state.detail { Text(d).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            ForEach(list) { o in
                VStack(alignment: .leading, spacing: 0) {
                    Text(o.title + "  ·  " + o.provenance).font(.system(size: 11.5)).foregroundStyle(o.isAvailable ? Color.primary : Color.secondary)
                    if let w = o.unavailableReason { Text(w).font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
        .accessibilityIdentifier("media-outputs")
    }

    /// The page the item was found on, from the item itself (its key is "<tab>|<address>"), not from whichever tab is in front now.
    static func pageURL(of c: MediaCandidate) -> URL? {
        guard let bar = c.pageKey.firstIndex(of: "|") else { return nil }
        return URL(string: String(c.pageKey[c.pageKey.index(after: bar)...]))
    }

    /// Where this came from and how sure we are: only what was observed, never a token or a full address.
    @ViewBuilder private func provenance(_ c: MediaCandidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(c.confidence.label) · \(c.method.label)").font(.system(size: 11)).foregroundStyle(.secondary)
            if let q = c.qualityLabel { Text("Playing at \(q)" + (c.playing == true ? " now" : "")).font(.system(size: 11)).foregroundStyle(.secondary) }
            if !c.frameOrigins.isEmpty, c.isEmbedded { Text("Embedded player from \(c.frameOrigins.joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            if c.players.count > 1 { Text("Used by \(c.players.count) players on the page").font(.system(size: 11)).foregroundStyle(.secondary) }
            let languages = c.tracks.compactMap { $0.language ?? $0.label }
            if !languages.isEmpty { Text("Captions or subtitles on the page: " + languages.prefix(6).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            if let e = c.expiresAt { Text(e <= Date() ? "Expired" : "Expires " + e.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(e <= Date() ? .orange : .secondary) }
        }
        if c.isExpired() { Button("Find Again") { model.discoverMediaOnCurrentPage() }.controlSize(.small) }
    }

    @ViewBuilder private func representations(_ m: MediaManifest) -> some View {
        let choice = m.defaultSelection(preferring: model.mediaPreferences)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(m.format == .hls ? "HLS" : "MPEG-DASH")" + (m.duration.map { " · " + Self.length($0) } ?? "")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            if !m.videos.isEmpty {
                Text("Video").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(m.videos) { s in
                    VStack(alignment: .leading, spacing: 0) {
                        Text([s.resolutionText ?? s.label, s.frameRateText, s.bitrateText, MediaCodecs.summary(s)].compactMap { $0 }.joined(separator: " · ") + (s.id == choice.video ? "  (default)" : ""))
                            .font(.system(size: 11.5)).foregroundStyle(s.isDownloadable ? Color.primary : Color.secondary)
                        if let w = s.unsupported ?? MediaCodecs.outputWarning(s) { Text(w).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                Text("Bitrates are what the playlist advertises, not measured speed.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            if !m.audios.isEmpty {
                Text("Audio").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(m.audios) { s in
                    Text([s.label, s.language, MediaCodecs.summary(s), s.bitrateText].compactMap { $0 }.joined(separator: " · ") + (s.id == choice.audio ? "  (default)" : "")).font(.system(size: 11.5))
                }
            }
            if !m.subtitles.isEmpty {
                Text("Subtitles").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(m.subtitles) { s in Text([s.label, s.language].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11.5)) }
            }
            if let bytes = m.estimatedBytes(for: choice) {
                Text("About \(DownloadStats.bytes(bytes)) for the default choice (estimated from advertised bitrates).").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
            }
            let problems = m.problems(with: choice)
            ForEach(Array(problems.enumerated()), id: \.offset) { Text($0.element.text).font(.system(size: 11)).foregroundStyle(.orange) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { if let id = selection { model.addDiscoveredMediaToLinkGrabber([id]); model.openLinkGrabber() } } label: { Label("Add to LinkGrabber", systemImage: "square.stack.3d.down.right") }
                .disabled(!(selected?.canOpen ?? false))
            Button { if let id = selection { store.remove([id]); selection = nil } } label: { Label("Remove", systemImage: "minus.circle") }.disabled(selection == nil)
            Button { store.clear(); selection = nil } label: { Label("Clear", systemImage: "xmark.circle") }.disabled(store.candidates.isEmpty)
            if let note = model.linkNotice { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Button("Media Settings…") { SettingsRouter.open(.downloads) }.help("Watching pages for media, and the audio and subtitle languages, are in Settings ▸ Downloads").accessibilityIdentifier("media-settings")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private static func length(_ s: Double) -> String {
        let f = DateComponentsFormatter(); f.allowedUnits = s >= 3600 ? [.hour, .minute, .second] : [.minute, .second]; f.unitsStyle = .abbreviated
        return f.string(from: s) ?? ""
    }
}
