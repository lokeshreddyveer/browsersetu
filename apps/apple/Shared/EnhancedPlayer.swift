import SwiftUI

/// What the Enhanced Player panel shows: the players found on the page and which one it is about. The page's own player and its own controls are untouched; this only reads the player's
/// state and sends it commands (play, move, speed…), each addressed to one player by its number.
@MainActor
final class PlayerState: ObservableObject {
    @Published var videos: [DetectedVideo] = []
    @Published var selected: Int?
    @Published var loaded = false
    /// Players in frames from other sites, which cannot be reached from here.
    @Published var blockedFrames = 0
    var pollCount = 0
    var subtitleApplied: Set<Int> = []
    /// True while a finger is on the timeline, so the picture of the player does not jump under it.
    @Published var scrubbing = false
    /// The one the panel is about: the one chosen, else the one that is really being watched.
    var current: DetectedVideo? { videos.first { $0.id == selected } ?? MediaSelection.primary(of: videos) }
}

@MainActor
extension BrowserModel {
    func showPlayer() {
        playerPanelVisible = true
        playerPollTask?.cancel()
        // Asked only while the panel is open, twice a second: a bounded stand-in for the page telling us, which would need a new message channel from the page to the app.
        playerPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.playerPanelVisible {
                if !self.player.scrubbing { await self.refreshPlayers() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Puts the player controls on the page, over everything but dimming nothing. Shown at once, while the player is still being found.
    func openFloatingPlayer() {
        guard !floatingPlayerOpen else { return }
        floatingPlayerOpen = true
        showPlayer()
    }

    /// The cross: the panel goes, and comes back when another video starts (or from the command palette).
    func closeFloatingPlayer() {
        guard floatingPlayerOpen else { return }
        floatingPlayerOpen = false
        // The Page Tools Video tab uses the same player state; it keeps it running if it is the one showing.
        if sheet != .pageTools { hidePlayer() }
    }

    func hidePlayer() {
        if let now = player.current { notePlayerPosition(now, force: true) }
        playerPanelVisible = false
        playerPollTask?.cancel()
        player.pollCount = 0; player.blockedFrames = 0; player.subtitleApplied = []
        player.videos = []; player.selected = nil; player.loaded = false
    }

    func refreshPlayers() async {
        guard let engine = active?.engine else { return }
        let found = (await engine.mediaElements() ?? []).map { DetectedVideo(raw: $0) }
        if found != player.videos { player.videos = found }
        // The count of players that cannot be reached changes rarely: looked at on the first read and then every few.
        if player.pollCount % 6 == 0 { let blocked = await engine.blockedMediaFrames(); if blocked != player.blockedFrames { player.blockedFrames = blocked } }
        player.pollCount += 1
        if let now = player.current { applySiteSubtitle(to: now); if !now.paused { notePlayerPosition(now) } }
        if let selected = player.selected, !found.contains(where: { $0.id == selected }) { player.selected = nil }
        player.loaded = true
    }

    /// A change to the picture (brightness, contrast, colour) of the player the panel is about, or its reset.
    func playerAdjust(_ part: String, _ step: Double) {
        guard let video = player.current else { return }
        Task {
            if let problem = await active?.engine.controlVideo(id: video.id, action: "adjust:" + part, value: step) { notice = problem }
            await refreshPlayers()
        }
    }

    /// One command for the player the panel is about. A refusal is said out loud, never swallowed.
    func playerCommand(_ action: VideoAction, _ value: Double = 0) {
        guard let video = player.current else { return }
        Task {
            if let problem = await active?.engine.controlVideo(id: video.id, action: action.rawValue, value: value) { notice = problem }
            await refreshPlayers()
        }
    }
}

struct EnhancedPlayerPanel: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var player: PlayerState
    /// False inside the floating player, which supplies its own surface (in the theme's and the page's colours, with nothing blurred behind it).
    var showsChrome = true
    var close: () -> Void
    @State private var scrub: Double?
    @State private var showTranscript = false
    /// After a few quiet seconds of playing, the panel folds to a one-line bar; a touch opens it again. It never disappears, so the way back is always there.
    @State private var collapsed = false
    @State private var idleTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let steps: [Double] = [5, 10, 15, 30]

    private func cmd(_ action: VideoAction, _ value: Double = 0) { touch(); model.playerCommand(action, value) }

    private func touch() {
        if collapsed { if reduceMotion { collapsed = false } else { withAnimation(.easeOut(duration: 0.2)) { collapsed = false } } }
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, player.current?.paused == false, !player.scrubbing else { return }
            if reduceMotion { collapsed = true } else { withAnimation(.easeOut(duration: 0.25)) { collapsed = true } }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if collapsed, let video = player.current {
                mini(video)
            } else {
                header
                if let video = player.current {
                    if let offer = model.resumeOffer(for: video) {
                        Button { cmd(.seek, offer) } label: { Label("Carry on at \(DetectedVideo.clock(offer))", systemImage: "arrow.counterclockwise").font(.system(size: 13, weight: .semibold)) }
                            .buttonStyle(.plain).padding(.horizontal, 12).frame(height: 32).background(Capsule().fill(Theme.accent.opacity(0.18)))
                    }
                    problem(video)
                    timeline(video)
                    transport(video)
                    extras(video)
                } else {
                    Text(player.loaded ? "No video or audio was found on this page." : "Looking for a player…")
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                }
                if player.blockedFrames > 0 {
                    Text(player.blockedFrames == 1 ? "One player on this page comes from another site and cannot be controlled here. Use its own controls." : "\(player.blockedFrames) players on this page come from other sites and cannot be controlled here. Use their own controls.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(isPresented: $showTranscript) { if let v = player.current { TranscriptView(video: v) { showTranscript = false }.environmentObject(model) } }
        .onAppear { touch() }
        .onChange(of: player.current?.paused) { _, _ in touch() }
        .onDisappear { idleTask?.cancel() }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background { if showsChrome { RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial) } }
        .overlay { if showsChrome { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) } }
        .shadow(color: .black.opacity(showsChrome ? 0.2 : 0), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player controls")
    }

    private func mini(_ v: DetectedVideo) -> some View {
        HStack(spacing: 14) {
            Button { cmd(v.paused ? .play : .pause) } label: { Image(systemName: v.paused ? "play.fill" : "pause.fill").font(.system(size: 18)).frame(width: 36, height: 36) }
                .buttonStyle(.plain).accessibilityLabel(v.paused ? "Play" : "Pause")
            Text(v.isLive ? "LIVE" : DetectedVideo.clock(v.time) + (v.duration > 0 ? " / " + DetectedVideo.clock(v.duration) : "")).font(.system(size: 13, weight: .medium)).monospacedDigit()
            Spacer()
            Button { touch() } label: { Image(systemName: "chevron.up").font(.system(size: 13, weight: .bold)).frame(width: 36, height: 36) }
                .buttonStyle(.plain).accessibilityLabel("Show all the player controls")
        }
        .contentShape(Rectangle()).onTapGesture { touch() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.nowPlaying.isEmpty == false ? player.current!.nowPlaying : (player.current?.isVideo == false ? "Audio" : "Video"))
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let quality = player.current?.qualityText { Text(quality).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if player.videos.count > 1 {
                Menu {
                    ForEach(player.videos) { v in
                        Button { player.selected = v.id } label: {
                            if v.id == player.current?.id { Label(v.title, systemImage: "checkmark") } else { Text(v.title) }
                        }
                    }
                } label: { Image(systemName: "rectangle.stack").font(.system(size: 15)).frame(width: 34, height: 34) }
                    .accessibilityLabel("Choose a player")
            }
            Menu {
                Picker("Skip by", selection: $model.playerSeekStep) { ForEach(Self.steps, id: \.self) { Text("\(Int($0)) seconds").tag($0) } }
                if let host = model.active?.url?.host {
                    Picker("Skip by on \(host)", selection: Binding(get: { model.playerSiteSteps[host] ?? 0 }, set: { model.setPlayerSiteStep($0 == 0 ? nil : $0, host: host) })) {
                        Text("The same as everywhere").tag(0.0)
                        ForEach(Self.steps, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                }
                Toggle("Offer to carry on where I stopped", isOn: $model.resumeMedia).disabled(!model.playerCanStore)
                if !model.mediaResumeList.isEmpty { Button("Forget all positions and marks", role: .destructive) { model.clearMediaPositions() } }
            } label: { Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 34, height: 34) }
                .accessibilityLabel("Player settings")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34) }
                .buttonStyle(.plain).accessibilityLabel("Close the player controls")
        }
    }

    // MARK: Timeline

    @ViewBuilder private func timeline(_ v: DetectedVideo) -> some View {
        if v.isLive && !v.canSeek {
            HStack { Label("LIVE", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.red); Spacer() }
        } else if v.canSeek, let lo = v.seekStart, let hi = v.seekEnd, hi > lo {
            let shown = scrub ?? v.time
            VStack(spacing: 4) {
                PlayerTimeline(value: shown, low: lo, high: hi, buffered: v.bufferedEnd, markA: v.repeatA, markB: v.repeatB) { dragging, time in
                    player.scrubbing = dragging
                    scrub = dragging ? time : nil
                    if !dragging { cmd(.seek, time) }
                }
                HStack {
                    Text(DetectedVideo.clock(max(0, shown - lo))).monospacedDigit()
                    Spacer()
                    if v.isLive { Text("LIVE window").foregroundStyle(.red) }
                    else { Text("−" + DetectedVideo.clock(max(0, hi - shown))).monospacedDigit() }
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        } else {
            // Nothing to move through (not loaded yet, or a stream with no window): say so, show no fake bar.
            Text(v.time > 0 ? DetectedVideo.clock(v.time) : "Not ready to move through yet").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Transport

    private func transport(_ v: DetectedVideo) -> some View {
        let step = Int(model.playerStep)
        return HStack(spacing: 24) {
            if v.canSeek {
                Button { cmd(.seekBy, -model.playerStep) } label: { Image(systemName: "gobackward.\(step)").font(.system(size: 24)) }
                    .accessibilityLabel("Back \(step) seconds")
            }
            if v.paused, v.canSeek { Button { cmd(.frame, -1) } label: { Image(systemName: "backward.frame").font(.system(size: 18)) }.accessibilityLabel("Back a thirtieth of a second") }
            Button { cmd(v.paused ? .play : .pause) } label: {
                Image(systemName: v.paused ? "play.fill" : "pause.fill").font(.system(size: 30)).frame(width: 56, height: 56)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .accessibilityLabel(v.paused ? "Play" : "Pause")
            if v.canSeek {
                Button { cmd(.seekBy, model.playerStep) } label: { Image(systemName: "goforward.\(step)").font(.system(size: 24)) }
                    .accessibilityLabel("Forward \(step) seconds")
            }
            if v.paused, v.canSeek { Button { cmd(.frame, 1) } label: { Image(systemName: "forward.frame").font(.system(size: 18)) }.accessibilityLabel("Forward a thirtieth of a second") }
        }
        .buttonStyle(.plain).foregroundStyle(Color.primary)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if v.paused, v.canSeek { Text("Small steps are a thirtieth of a second, not a video frame").font(.system(size: 9)).foregroundStyle(.secondary).offset(y: 16) }
        }
        .padding(.bottom, v.paused && v.canSeek ? 14 : 0)
    }

    // MARK: The rest, each shown only if the player can do it

    private func extras(_ v: DetectedVideo) -> some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(VideoControls.speeds, id: \.self) { rate in
                    Button { cmd(.speed, rate) } label: { if abs(v.rate - rate) < 0.01 { Label(VideoControls.label(rate), systemImage: "checkmark") } else { Text(VideoControls.label(rate)) } }
                }
                Divider()
                Button("Slower by 0.05×", systemImage: "minus") { cmd(.speedBy, -0.05) }
                Button("Faster by 0.05×", systemImage: "plus") { cmd(.speedBy, 0.05) }
                if abs(v.rate - 1) > 0.01 { Button("Normal speed", systemImage: "arrow.counterclockwise") { cmd(.speed, 1) } }
            } label: { chip(VideoControls.label(v.rate), nil) }
            if !v.tracks.isEmpty {
                Menu {
                    Button { cmd(.subtitle, -1); model.rememberSubtitle(nil) } label: { if !v.tracks.contains(where: \.showing) { Label("Off", systemImage: "checkmark") } else { Text("Off") } }
                    ForEach(Array(v.tracks.enumerated()), id: \.offset) { i, t in
                        Button { cmd(.subtitle, Double(i)); model.rememberSubtitle(t.label) } label: { if t.showing { Label(t.label, systemImage: "checkmark") } else { Text(t.label) } }
                    }
                    if v.tracks.contains(where: \.showing) {
                        Divider()
                        Button("Subtitles earlier by 0.5 s", systemImage: "backward") { cmd(.subtitleShift, -0.5) }
                        Button("Subtitles later by 0.5 s", systemImage: "forward") { cmd(.subtitleShift, 0.5) }
                    }
                } label: { chip(nil, v.tracks.contains(where: \.showing) ? "captions.bubble.fill" : "captions.bubble") }
                    .accessibilityLabel("Subtitles")
            }
            if v.canSeek {
                Button { cmd(.loop, v.loops ? 0 : 1) } label: { chip(nil, v.loops ? "repeat.1" : "repeat", on: v.loops) }
                    .accessibilityLabel(v.loops ? "Stop repeating" : "Repeat this video")
                repeatMenu(v)
            }
            Button { cmd(.mute, v.muted ? 0 : 1) } label: { chip(nil, v.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                .accessibilityLabel(v.muted ? "Unmute" : "Mute")
            if v.isVideo, !v.protected { Button { cmd(.pictureInPicture) } label: { chip(nil, "pip.enter") }.accessibilityLabel("Picture in Picture") }
            if v.isVideo { Button { cmd(.fullscreen) } label: { chip(nil, "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Full screen") }
            moreMenu(v)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    /// Everything else, in one restrained menu; each entry is here only if the player can do it.
    private func moreMenu(_ v: DetectedVideo) -> some View {
        Menu {
            if v.isVideo {
                Button { cmd(.theater, v.theater ? 0 : 1) } label: { Label(v.theater ? "Leave theater mode" : "Theater mode", systemImage: v.theater ? "rectangle.compress.vertical" : "rectangle.expand.vertical") }
                Button { cmd(.focus, v.focus ? 0 : 1) } label: { Label(v.focus ? "Leave focus mode" : "Focus mode (dim the page)", systemImage: "circle.lefthalf.filled") }
                Menu("Fit") {
                    Button { cmd(.fit, 0) } label: { if v.fit == "contain" || v.fit.isEmpty { Label("Fit inside", systemImage: "checkmark") } else { Text("Fit inside") } }
                    Button { cmd(.fit, 1) } label: { if v.fit == "cover" { Label("Fill, cropping the edges", systemImage: "checkmark") } else { Text("Fill, cropping the edges") } }
                    Button { cmd(.fit, 2) } label: { if v.fit == "fill" { Label("Stretch", systemImage: "checkmark") } else { Text("Stretch") } }
                }
                if !v.protected {
                    Menu("Picture") {
                        Button("Brighter", systemImage: "sun.max") { model.playerAdjust("brightness", 0.1) }
                        Button("Darker", systemImage: "sun.min") { model.playerAdjust("brightness", -0.1) }
                        Button("More contrast", systemImage: "circle.lefthalf.filled") { model.playerAdjust("contrast", 0.1) }
                        Button("Less contrast", systemImage: "circle") { model.playerAdjust("contrast", -0.1) }
                        Button("More colour", systemImage: "drop.fill") { model.playerAdjust("saturation", 0.1) }
                        Button("Less colour", systemImage: "drop") { model.playerAdjust("saturation", -0.1) }
                        if v.picture != nil { Button("Reset the picture", systemImage: "arrow.counterclockwise") { model.playerAdjust("reset", 0) } }
                    }
                }
            }
            Button { cmd(.endAction, 1) } label: { Label("Leave theater and focus when it ends", systemImage: "flag.checkered") }
            if v.audioTracks.count > 1 {
                Menu("Audio") {
                    ForEach(Array(v.audioTracks.enumerated()), id: \.offset) { i, t in
                        Button { cmd(.audioTrack, Double(i)) } label: { if t.enabled { Label(t.label, systemImage: "checkmark") } else { Text(t.label) } }
                    }
                }
            }
            if !v.chapters.isEmpty {
                Menu("Chapters") { ForEach(Array(v.chapters.enumerated()), id: \.offset) { _, c in Button(c.title) { cmd(.seek, c.start) } } }
            }
            if model.playerCanStore, v.canSeek, !v.isLive { marksMenuItems(v) }
            if v.canAirPlay { Button { cmd(.airplay) } label: { Label("AirPlay", systemImage: "airplayvideo") } }
            if v.isVideo, !v.protected { Button { model.captureFrame(v) } label: { Label("Copy this picture", systemImage: "camera") } }
            if !v.tracks.isEmpty { Button { showTranscript = true } label: { Label("Transcript…", systemImage: "text.alignleft") } }
            if model.playerCanStore {
                Button { model.saveWatchLater(v) } label: { Label("Save to Watch Later", systemImage: "clock.badge.checkmark") }
                Button { model.saveClipNote(v) } label: { Label("Note at this moment…", systemImage: "note.text") }
            }
            Menu("Information") { ForEach(infoLines(v), id: \.self) { Text($0) } }
            let other = model.playingElsewhere
            if !other.isEmpty {
                Menu("Playing in other tabs") {
                    ForEach(other) { tab in
                        Menu(tab.displayTitle) {
                            Button("Go to this tab", systemImage: "arrow.right.circle") { model.select(tab.id) }
                            Button("Pause", systemImage: "pause") { model.pauseMedia(in: tab) }
                            Button(tab.muted ? "Unmute" : "Mute", systemImage: tab.muted ? "speaker.wave.2" : "speaker.slash") { tab.setMuted(!tab.muted) }
                        }
                    }
                    Divider()
                    Button("Pause everything", systemImage: "pause.circle", role: .destructive) { model.pauseAllMedia() }
                }
            }
        } label: { chip(nil, "ellipsis.circle") }
            .accessibilityLabel("More player controls")
    }

    private func infoLines(_ v: DetectedVideo) -> [String] {
        var out: [String] = []
        if let q = v.qualityText { out.append(q) }
        out.append(v.isLive ? "Live" : (v.duration > 0 ? "Length " + DetectedVideo.clock(v.duration) : "Length not known"))
        out.append("Speed " + VideoControls.label(v.rate))
        if let buffered = v.bufferedEnd { out.append("Loaded to " + DetectedVideo.clock(buffered)) }
        if let lo = v.seekStart, let hi = v.seekEnd { out.append("Can move between " + DetectedVideo.clock(lo) + " and " + DetectedVideo.clock(hi)) } else { out.append("Cannot be moved through") }
        out.append("Subtitles: \(v.tracks.count)   Audio tracks: \(v.audioTracks.count)")
        if v.protected { out.append("Protected (copy-protected video)") }
        return out
    }

    /// What went wrong, in plain words, when the player reports a fault; the same explanations the compatibility check gives.
    @ViewBuilder private func problem(_ v: DetectedVideo) -> some View {
        let fairplay = model.mediaReport?.features.first { $0.id == "fairplay" }?.status == .supported
        let e = MediaProblemExplainer.explain(errorCode: v.errorCode, errorMessage: v.errorMessage, hasMediaKeys: v.protected, isBlob: v.isBlobSource,
                                              readyState: v.readyState, networkState: v.networkState, fairplayAvailable: fairplay, output: ProtectedOutput.current())
        if v.errorCode != nil, e.isProblem {
            // The same design as the page-level errors, as a contained panel: only the video's own panel says it failed; the rest of the page keeps working.
            let info = BrowserErrorInfo(kind: .mediaFailure, url: URL(string: v.source), domain: "MediaError", code: v.errorCode ?? 0, detail: e.explanation, headline: e.headline)
            ErrorInlineView(info: info, actions: [.reload, .copyAddress]) { action in
                switch action {
                case .reload: model.active?.reload()
                case .copyAddress: copyToPasteboard(v.source); model.notice = "Copied the video address."
                default: break
                }
            }
        }
    }

    @ViewBuilder private func marksMenuItems(_ v: DetectedVideo) -> some View {
        let marks = model.mediaEntry(for: v)?.marks ?? []
        Menu("Marked places") {
            Button("Mark this place", systemImage: "bookmark") { model.addPlayerMark(v) }
            if !marks.isEmpty {
                Section("Marked places") { ForEach(marks) { m in Button(m.label, systemImage: "bookmark.fill") { cmd(.seek, m.time) } } }
                Menu("Remove a mark") { ForEach(marks) { m in Button(m.label, role: .destructive) { model.removePlayerMark(m.id, from: v) } } }
            }
        }
    }

    private func repeatMenu(_ v: DetectedVideo) -> some View {
        Menu {
            Button("Set A here", systemImage: "a.circle") { cmd(.markA) }
            Button("Set B here", systemImage: "b.circle") { cmd(.markB) }.disabled(v.repeatA == nil)
            if v.repeatA != nil { Button("Clear A–B", systemImage: "xmark.circle", role: .destructive) { cmd(.clearAB) } }
            if v.repeatA != nil, v.repeatB != nil, model.playerCanStore { Button("Save this repeat", systemImage: "square.and.arrow.down") { model.savePlayerLoop(v) } }
            let saved = model.mediaEntry(for: v)?.loops ?? []
            if !saved.isEmpty {
                Section("Saved repeats") { ForEach(saved) { l in Button(l.label, systemImage: "repeat") { touch(); model.playLoop(l) } } }
                Menu("Remove a saved repeat") { ForEach(saved) { l in Button(l.label, role: .destructive) { model.removePlayerLoop(l.id, from: v) } } }
            }
            if let a = v.repeatA { Text("A \(DetectedVideo.clock(a))" + (v.repeatB.map { " → B \(DetectedVideo.clock($0))" } ?? "")) }
        } label: { chip(v.repeatB != nil ? "A–B" : (v.repeatA != nil ? "A…" : nil), v.repeatA == nil ? "arrow.left.and.right.circle" : nil, on: v.repeatB != nil) }
            .accessibilityLabel("Repeat between two points")
    }

    private func chip(_ text: String?, _ symbol: String?, on: Bool = false) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 16)) }
            if let text { Text(text).font(.system(size: 13, weight: .semibold)).monospacedDigit() }
        }
        .foregroundStyle(on ? Theme.accent : Color.primary)
        .frame(minWidth: 40, minHeight: 40)
        .contentShape(Rectangle())
    }
}

/// The timeline: how much has played, how much has loaded, the two ends of an A–B repeat, and a thumb to drag. Dragging shows where you would land and moves the player only when you let go.
struct PlayerTimeline: View {
    let value: Double, low: Double, high: Double
    let buffered: Double?, markA: Double?, markB: Double?
    let onChange: (_ dragging: Bool, _ time: Double) -> Void
    @State private var dragging = false

    private func pos(_ t: Double, _ width: CGFloat) -> CGFloat { CGFloat((min(max(t, low), high) - low) / (high - low)) * width }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 5)
                if let buffered { Capsule().fill(Color.primary.opacity(0.22)).frame(width: pos(buffered, width), height: 5) }
                Capsule().fill(Theme.accent).frame(width: pos(value, width), height: 5)
                if let a = markA { Rectangle().fill(Color.primary).frame(width: 2, height: 11).offset(x: pos(a, width) - 1) }
                if let b = markB { Rectangle().fill(Color.primary).frame(width: 2, height: 11).offset(x: pos(b, width) - 1) }
                Circle().fill(Color.white).frame(width: 15, height: 15).shadow(radius: 2).offset(x: pos(value, width) - 7.5)
                // Where a release would land. Many sites offer no preview pictures to read, and a page's own pictures cannot be read back from a protected or cross-site player, so it is the time only.
                if dragging {
                    Text(DetectedVideo.clock(value - low)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.thinMaterial, in: Capsule())
                        .offset(x: min(max(pos(value, width) - 22, 0), max(width - 44, 0)), y: -26)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in dragging = true; onChange(true, low + Double(min(max(g.location.x / width, 0), 1)) * (high - low)) }
                .onEnded { g in dragging = false; onChange(false, low + Double(min(max(g.location.x / width, 0), 1)) * (high - low)) })
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(DetectedVideo.clock(value - low)) of \(DetectedVideo.clock(high - low))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(false, min(value + 10, high))
            case .decrement: onChange(false, max(value - 10, low))
            @unknown default: break
            }
        }
    }
}
