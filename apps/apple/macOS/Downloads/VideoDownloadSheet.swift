import SwiftUI

/// What the Download button on a video entry opens: a plain statement of what this item is, what can be saved from it and why anything cannot, then the choice. Nothing is fetched until
/// Download is pressed; a provider's video is never fetched here at all (its page opens, where the provider's own flow resolves it).
struct VideoSubject: Identifiable, Equatable {
    enum Kind: Equatable { case directVideo, directAudio, stream, providerVideo(MediaProviderID), page, otherFile }
    let id = UUID()
    var title: String
    var url: URL
    var host: String
    var kind: Kind
    var isPrivate: Bool
    var pageHost: String?

    /// A whole page whose player builds its video in memory: the page itself is what a lookup is asked about.
    init(page url: URL, title: String, isPrivate: Bool) {
        self.url = url; host = url.host ?? ""; pageHost = url.host; self.isPrivate = isPrivate; kind = .page; self.title = title
    }

    /// What the router is given for this subject.
    var resource: RouterResource {
        switch kind {
        case .providerVideo(let p): .videoPage(url, provider: p)
        case .page: .videoPage(url, provider: ProviderRecognizer.provider(forHost: host))
        case .stream: .file(url, category: .video)
        case .directAudio: .file(url, category: .audio)
        case .directVideo: .file(url, category: .video)
        case .otherFile: .file(url, category: .other)
        }
    }

    init?(_ r: DetectedResource, isPrivate: Bool) {
        guard let u = URL(string: r.url), u.scheme?.lowercased().hasPrefix("http") == true else { return nil }
        url = u; host = u.host ?? ""; pageHost = r.pageHost; self.isPrivate = isPrivate
        if let p = r.provider { kind = .providerVideo(p); title = r.filename }
        else if r.isManifest { kind = .stream; title = r.filename.isEmpty ? host : (r.filename as NSString).deletingPathExtension }
        else if r.category == .audio { kind = .directAudio; title = (r.filename as NSString).deletingPathExtension }
        else if r.category == .video { kind = .directVideo; title = (r.filename as NSString).deletingPathExtension }
        else { kind = .otherFile; title = (r.filename as NSString).deletingPathExtension }
    }
}

struct VideoDownloadSheet: View {
    /// Watched so the sheet re-routes the moment the media tools finish installing (the route depends on whether an extractor is available).
    @ObservedObject private var mediaTools = MediaToolsStore.shared
    @EnvironmentObject var model: BrowserModel
    let subject: VideoSubject
    var done: () -> Void

    /// Watched so the choices update the moment the media processing tool finishes installing (or is removed).
    @ObservedObject private var processingTool = MediaToolsStore.ffmpeg
    /// The planner option the person picked (by id); nothing picked means the first one that can be carried out.
    @State private var pickID = ""
    @State private var kbps = 192
    @State private var keepVideo = true
    @State private var name: String
    @State private var operation: VideoSaveOperation?
    /// Set instead of `operation` when the choice needs the media processing tool: the same operation the extractor sheet uses.
    @State private var toolOperation: SourceSaveOperation?
    @State private var consentTick = 0
    @State private var profileAtOpen = ""
    /// The person chose to ask their extractor even though the provider has a route of its own.
    @State private var useExtractor = false

    init(subject: VideoSubject, done: @escaping () -> Void) {
        self.subject = subject; self.done = done
        _name = State(initialValue: DownloadFilename.sanitize(subject.title) ?? "Video")
    }

    /// The profile the sheet was opened in; a profile switch while it is open does not change which profile the request belongs to.
    private var profile: String { profileAtOpen.isEmpty ? model.profileName : profileAtOpen }
    private var needsConversionConsent: Bool { output.isAudio }
    private var consented: Bool {
        _ = consentTick
        return !needsConversionConsent || MediaConsentStore.shared.isAllowed(.localConversion, host: subject.pageHost, profile: profile, isPrivate: subject.isPrivate) || subject.isPrivate && localOnlyInPrivate
    }
    /// Converting on this Mac sends nothing anywhere, so it is allowed in a private tab without a stored grant (it is never stored there).
    private var localOnlyInPrivate: Bool { true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subject.title.isEmpty ? subject.host : subject.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(subject.host + (subject.isPrivate ? " · private tab" : "")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            switch route {
            case .providerAdapter(let p): builtInProviderBody(p)
            case .extractor: ExtractorLookupView(subject: subject, done: done)
            case .stream: streamBody
            case .tracks: fileBody
            case .torrent: unresolvedBody(.noRoute("Torrents and magnet links open in the link collection."))
            case .unresolved(let why): unresolvedBody(why)
            }
        }
        .padding(18).frame(width: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("video-download-sheet")
        .onAppear { if profileAtOpen.isEmpty { profileAtOpen = model.profileName } }
        .onDisappear {
            // Closing the sheet ends what it started and spends no permission it was given: nothing keeps running unseen.
            MediaConsentStore.shared.clearOnce()
            if let op = operation, !op.stage.isFinal { op.cancel() }
            if let op = toolOperation, !op.stage.isFinal { op.cancel() }
        }
    }

    /// The one decision about what this subject needs, from the router (the sheet no longer decides by the kind of entry it was opened from).
    private var extractorReady: Bool { ExtractorChoice.isAvailable && !subject.isPrivate }
    private var route: Route {
        if useExtractor, extractorReady { return .extractor(page: subject.url) }
        return DownloadRouter.route(subject.resource, RouterContext(isPrivate: subject.isPrivate, extractorConfigured: ExtractorChoice.isAvailable))
    }

    @ViewBuilder private func unresolvedBody(_ why: Unresolved) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Status: Source not resolved").font(.system(size: 12, weight: .semibold)).accessibilityIdentifier("video-sheet-status")
            Text(why.text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // The page needs the extractor and none is installed: the one place to enable it, in place, with progress and Retry. Not offered in a private tab.
            if case .extractorOff = why, !subject.isPrivate { MediaToolsOffer() }
        }
        HStack { Spacer(); Button("Close", action: done).keyboardShortcut(.cancelAction); Button("Open Video Page") { model.open(urlString: subject.url.absoluteString, newTab: true); done() }.buttonStyle(.borderedProminent).accessibilityIdentifier("video-sheet-open") }
    }

    private var icon: String { switch subject.kind { case .directAudio: "waveform"; case .stream: "play.rectangle"; case .providerVideo, .page: "play.rectangle.on.rectangle"; default: "film" } }

    // MARK: Provider video: analysis only

    @ViewBuilder private func builtInProviderBody(_ p: MediaProviderID) -> some View {
        let caps = ProviderRegistry.adapter(for: p).capabilities(for: ProviderRecognizer.recognize(subject.url) ?? ProviderMatch(provider: p, kind: .video, host: subject.host), authorized: false)
        VStack(alignment: .leading, spacing: 6) {
            Text("Status: " + (caps.requiresAuthentication ? "Authorization required" : (caps.canDownloadNow ? "Can be resolved" : "No source resolved from this link")))
                .font(.system(size: 12, weight: .semibold)).accessibilityIdentifier("video-sheet-status")
            // A provider's policy statement is not shown as the reason: the reason is technical (no resolver for this page). Notes that tell what to do (sign in, authorize) are kept.
            if let note = caps.note, caps.restriction == nil || caps.requiresAuthentication { Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if caps.restriction != nil { Text("This link is a \(p.displayName) page, and this app has no resolver that turns such a page into a file. Nothing is blocked by the site name: open the page, and if its player exposes a plain, unprotected stream it is listed under Media on This Page and downloads from there.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !ExtractorChoice.isAvailable && !subject.isPrivate { Text("To look this video up, Browser Setu needs its optional media tools (Settings › Media), or a program of your own.").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !ExtractorChoice.isAvailable && !subject.isPrivate { MediaToolsOffer() }
            if subject.isPrivate { Text("External extractors are not used in private tabs.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            Text("Nothing is fetched from \(p.displayName) from here. Open the video's page to look for what it exposes; a protected (DRM) or sign-in-only stream cannot be saved.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            if extractorReady { Button("Use My Extractor Instead") { useExtractor = true }.controlSize(.small).accessibilityIdentifier("video-sheet-use-extractor") }
            if let alt = caps.alternative, let u = alt.url { Link(alt.title, destination: u).font(.system(size: 12)) }
            Spacer()
            Button("Close", action: done).keyboardShortcut(.cancelAction)
            Button("Open Video Page") { model.open(urlString: subject.url.absoluteString, newTab: true); done() }.buttonStyle(.borderedProminent).accessibilityIdentifier("video-sheet-open")
        }
    }

    // MARK: Stream: the existing quality picker

    private var streamBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A stream playlist. Reading it lists the real qualities, audio languages and subtitles; you can save the video, or only the audio as M4A.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Choose Quality…") { done(); model.openLinkPreview(.mediaPreview(subject.url)) }.buttonStyle(.borderedProminent).accessibilityIdentifier("video-sheet-choose")
            }
        }
    }

    // MARK: A direct file

    /// The choices for this file, from the one planner.
    private var planned: [PlannedOption] {
        // Choices the system's engine cannot do (sound from WebM/Ogg/Opus) are carried out by the optional media processing tool when it is installed, or offered below when it is not.
        if case .tracks(let source) = route { return DownloadPlanner.options(for: source) }
        return []
    }
    private var selected: PlannedOption? { let ok = planned.filter(\.isExecutable); return ok.first { $0.id == pickID } ?? ok.first }
    /// What the choice does to the file; the tool-made sound is the same output as the system-made one, so consent, bitrate and wording are shared.
    private func outputFor(_ p: PlannedOption) -> VideoSaveOperation.Output {
        switch p.choice { case .audioM4A?, .audioM4AFFmpeg?: .m4a; case .audioMP3?, .audioMP3FFmpeg?: .mp3(kbps: kbps); default: .original }
    }
    private var output: VideoSaveOperation.Output { selected.map(outputFor) ?? .original }
    private var usesTool: Bool { switch selected?.choice { case .audioM4AFFmpeg?, .audioMP3FFmpeg?, .joinedFFmpeg?: true; default: false } }

    @ViewBuilder private var fileBody: some View {
        let options = planned
        if let op = operation { progress(op) }
        else if let op = toolOperation { SourceSaveProgress(op: op, done: done) }
        else {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Save as", text: $name).textFieldStyle(.roundedBorder)
                Picker("Save", selection: Binding(get: { selected?.id ?? "" }, set: { pickID = $0 })) {
                    ForEach(options.filter(\.isExecutable)) { p in Text(p.option.title + "  ·  " + p.option.provenance).tag(p.id) }
                }.pickerStyle(.radioGroup).accessibilityIdentifier("video-sheet-output")
                ForEach(options.filter { !$0.isExecutable }) { p in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.option.title).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Text(p.option.unavailableReason ?? "").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if case .mp3 = output {
                    Picker("Quality", selection: $kbps) { ForEach(MP3Encoder.bitrates, id: \.self) { Text("\($0) kbit/s").tag($0) } }.pickerStyle(.menu)
                    Text("Re-encoded from the source's audio: a higher bitrate does not improve what the source had.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                if output.isAudio {
                    if !usesTool { Toggle("Keep the downloaded video too", isOn: $keepVideo).font(.system(size: 12)) }
                    Text("The whole file is downloaded first, then the sound is made from it on this Mac.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                if options.contains(where: \.requiresProcessingTool), !DownloadPlanner.processingReady { ProcessingToolOffer() }
                if !consented, !subject.isPrivate { consentPrompt }
                Text("Saved to your Downloads folder.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Download") { begin() }.buttonStyle(.borderedProminent).disabled(!consented || name.trimmingCharacters(in: .whitespaces).isEmpty || options.filter(\.isExecutable).isEmpty).keyboardShortcut(.defaultAction).accessibilityIdentifier("video-sheet-download")
            }
        }
    }

    private var consentPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MediaConsentPurpose.localConversion.title).font(.system(size: 12, weight: .semibold))
            Text(MediaConsentPurpose.localConversion.explanation).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow Once") { grant(.once) }.accessibilityIdentifier("consent-once")
                if let h = subject.pageHost { Button("Allow for \(h)") { grant(.site(h.lowercased())) }.accessibilityIdentifier("consent-site") }
                Button("Allow for This Profile") { grant(.profile) }.accessibilityIdentifier("consent-profile")
            }.controlSize(.small)
            Text("You can revoke this in Settings › Media.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("consent-prompt")
    }

    private func grant(_ scope: MediaConsentScope) {
        MediaConsentStore.shared.grant(.localConversion, scope: scope, profile: profile, isPrivate: subject.isPrivate)
        consentTick += 1
    }

    private func begin() {
        guard operation == nil, toolOperation == nil else { return }             // a second click starts nothing
        if usesTool, let chosen = selected, case .tracks(var source) = route, var choice = chosen.choice {
            // Carried out by the media processing tool, with the same operation (coordinator downloads, checks, cleanup, cancel) the extractor sheet uses.
            source.isPrivate = subject.isPrivate
            if case .audioMP3FFmpeg = choice { choice = .audioMP3FFmpeg(kbps: kbps) }          // the bitrate the person picked
            let tool = SourceSaveOperation(source: source, choice: choice, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Video" : name, coordinator: model.engine.downloads, profileTag: MediaStore.profileTag(profile))
            tool.pickVideo = chosen.representation; tool.pickAudio = chosen.audio
            toolOperation = tool
            tool.start()
            if output.isAudio { if case .failed = tool.stage {} else { MediaConsentStore.shared.consumeOnce(.localConversion) } }          // spent only if the job really started
            return
        }
        let op = VideoSaveOperation(url: subject.url, name: name, output: output, keepOriginal: keepVideo, isPrivate: subject.isPrivate, coordinator: model.engine.downloads, profileTag: MediaStore.profileTag(profile))
        operation = op
        op.start()
        if output.isAudio, op.downloadID != nil { MediaConsentStore.shared.consumeOnce(.localConversion) }
    }

    @ViewBuilder private func progress(_ op: VideoSaveOperation) -> some View { VideoSaveProgress(op: op, done: done) }
}

private struct VideoSaveProgress: View {
    @ObservedObject var op: VideoSaveOperation
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch op.stage {
            case .waiting: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for the download to start…").font(.system(size: 12)).foregroundStyle(.secondary) }
            case .downloading(let f): ProgressView(value: f) { Text("Downloading…").font(.system(size: 12)) }
            case .converting(let f): ProgressView(value: f) { Text("Making \(op.output.title) on this Mac…").font(.system(size: 12)) }
            case .done(let url):
                Label("Saved: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                    .accessibilityIdentifier("video-sheet-done")
                RevealSavedFileButton(url: url)
                if let n = op.lastNote { Text(n).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            case .failed(let why): Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            case .cancelled: Text("Cancelled.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if op.stage.isFinal { Button("Done", action: done).keyboardShortcut(.defaultAction) }
                else { Button("Cancel") { op.cancel() }.accessibilityIdentifier("video-sheet-cancel") }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("video-sheet-progress")
    }
}


/// After a save: one quiet button that shows the finished file in Finder (only if it is still there).
private struct RevealSavedFileButton: View {
    let url: URL
    var body: some View {
        if FileManager.default.fileExists(atPath: url.path) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link).font(.system(size: 11.5)).accessibilityIdentifier("video-sheet-reveal")
        }
    }
}

// MARK: - Looking a video up with the person's external extractor

@MainActor
final class ExtractorLookupModel: ObservableObject {
    enum Phase: Equatable { case needsConsent, running, ready, failed(String), saving }
    @Published var phase = Phase.needsConsent
    @Published var source: NormalizedMediaSource?
    @Published var suggestedName: String?
    @Published var operation: SourceSaveOperation?
    private var task: Task<Void, Never>?

    @discardableResult
    func look(at page: URL, isPrivate: Bool, identity: String?, pathOverride: String? = nil, profile: String = "default") -> Bool {
        guard phase != .running else { return false }
        phase = .running
        // The program was already checked (off the main thread) when the sheet opened; the checked path is passed in. Resolving here would hash the whole program on the main thread.
        guard let path = pathOverride, !path.isEmpty else { phase = .failed(ExtractorFailure.notConfigured.localizedDescription); return false }
        task = Task {
            do {
                let s = try await ExtractorBroker.shared.lookup(page: page, path: path, identity: identity ?? "", profile: profile, isPrivate: isPrivate, allowLocal: HTTPRequestPolicy.debugFixtureAllowsLocalPageOrigin)
                guard !Task.isCancelled else { return }
                source = s; phase = .ready; suggestedName = DownloadFilename.sanitize(s.title)
            } catch is CancellationError { phase = .needsConsent }
            catch { if !Task.isCancelled { phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)") } }
        }
        return true
    }
    func cancel() { task?.cancel(); operation?.cancel() }
}

struct ExtractorLookupView: View {
    /// Watched so the list of choices updates the moment the media processing tool finishes installing.
    @ObservedObject private var processingTool = MediaToolsStore.ffmpeg
    @EnvironmentObject var model: BrowserModel
    let subject: VideoSubject
    var done: () -> Void
    @StateObject private var lookup = ExtractorLookupModel()
    @State private var consentTick = 0
    @State private var profileAtOpen = ""
    @State private var pickKey: String = ""
    @State private var exePath = ""
    @State private var exeTitle = ""
    @State private var exeIdentity: String?
    @State private var exeProblem: String?
    @State private var output = 0           // 0 video, 1 M4A, 2 MP3
    @State private var name = ""

    private var profile: String { profileAtOpen.isEmpty ? model.profileName : profileAtOpen }
    private var allowed: Bool {
        _ = consentTick
        guard let id = exeIdentity else { return false }
        return MediaConsentStore.shared.isAllowed(.externalExtractor(id), host: subject.url.host, profile: profile, isPrivate: subject.isPrivate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch lookup.phase {
            case .needsConsent: consent
            case .running: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking your extractor about this video…").font(.system(size: 12)).foregroundStyle(.secondary) }.accessibilityIdentifier("extractor-running")
                HStack { Spacer(); Button("Cancel") { lookup.cancel(); lookup.phase = .needsConsent }.accessibilityIdentifier("extractor-cancel") }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("extractor-failed")
                HStack { Spacer(); Button("Close", action: done); Button("Try Again") { lookup.phase = .needsConsent }.accessibilityIdentifier("extractor-retry") }
            case .ready, .saving: results
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: lookup.suggestedName) { _, n in if let n, !n.isEmpty { name = n } }
        .onAppear {
            if profileAtOpen.isEmpty { profileAtOpen = model.profileName }
            if name.isEmpty { name = DownloadFilename.sanitize(subject.title) ?? "Video" }
            refreshExecutable()
        }
        .onDisappear { MediaConsentStore.shared.clearOnce(); if let op = lookup.operation, !op.stage.isFinal { op.cancel() } else { lookup.cancel() } }
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Look this video up with your extractor?").font(.system(size: 13, weight: .semibold))
            Text("Program: \(exeTitle.isEmpty ? (exePath.isEmpty ? "none" : exePath) : exeTitle)").font(.system(size: 11.5, design: .monospaced)).lineLimit(2).truncationMode(.middle).accessibilityIdentifier("extractor-program")
            if let p = exeProblem { Label(p, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Text("This video page's web address will be passed to the program you chose in Settings. That program is independently maintained third-party software; it may make its own network requests, and it runs with your Mac permissions. Nothing else is given to it (no cookies, sign-ins, or other pages).").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Saving some content can go against a website's terms or the law where you are. Only save what you have permission to save. Permission here lets the browser do the lookup; it does not override a site's protections, and a protected or sign-in-only video will not be saved.").font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            if exeIdentity == nil {
                HStack { Spacer(); Button("Close", action: done) }
            } else if allowed {
                HStack { Spacer(); Button("Close", action: done); Button("Look Up Formats") { start() }.buttonStyle(.borderedProminent).accessibilityIdentifier("extractor-lookup") }
            } else {
                HStack {
                    Button("Allow Once") { grant(.once) }.accessibilityIdentifier("extractor-consent-once")
                    if let h = subject.url.host { Button("Allow for \(h)") { grant(.site(h.lowercased())) }.accessibilityIdentifier("extractor-consent-site") }
                    Button("Allow for This Profile") { grant(.profile) }.accessibilityIdentifier("extractor-consent-profile")
                    Spacer()
                    Button("Don't Allow") { done() }.accessibilityIdentifier("extractor-consent-deny")
                }.controlSize(.small)
                Text("You can revoke this in Settings › Media.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("extractor-consent")
    }

    /// The program as it is right now: its checked location and fingerprint. A grant is for exactly this.
    private func refreshExecutable() {
        Task {
            do { let c = try await ExtractorChoice.resolveAsync(); exePath = c.path; exeTitle = c.title; exeIdentity = c.identity; exeProblem = nil }
            catch { exeIdentity = nil; exeProblem = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }
    private func grant(_ scope: MediaConsentScope) {
        guard let id = exeIdentity else { return }
        MediaConsentStore.shared.grant(.externalExtractor(id), scope: scope, profile: profile, isPrivate: subject.isPrivate)
        consentTick += 1
        start()
    }
    private func start() {
        guard allowed, let id = exeIdentity else { return }
        // The grant is spent only if the lookup really started, and is for the program that was checked a moment ago; if the program changed since, the lookup refuses.
        if lookup.look(at: subject.url, isPrivate: subject.isPrivate, identity: id, pathOverride: exePath, profile: profile) { MediaConsentStore.shared.consumeOnce(.externalExtractor(id)) }
    }

    @ViewBuilder private var results: some View {
        if let src = lookup.source, case .tracks = src.shape {
            let options = DownloadPlanner.options(for: src)
            let executable = options.filter(\.isExecutable)
            Text(src.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            if let op = lookup.operation { SourceSaveProgress(op: op, done: done) }
            else {
                TextField("Save as", text: $name).textFieldStyle(.roundedBorder)
                if executable.isEmpty {
                    Text("Source not resolved: the extractor's formats cannot be saved with the engines in this browser.").font(.system(size: 11.5)).foregroundStyle(.orange).accessibilityIdentifier("extractor-no-plan")
                } else {
                    Picker("Save as", selection: Binding(get: { currentOption(executable).id }, set: { pickKey = $0 })) {
                        ForEach(executable) { p in Text(label(p)).tag(p.id) }
                    }.pickerStyle(.menu).accessibilityIdentifier("extractor-quality")
                }
                ForEach(options.filter { !$0.isExecutable }) { p in
                    VStack(alignment: .leading, spacing: 0) { Text(p.option.title).font(.system(size: 11.5)).foregroundStyle(.secondary); Text(p.option.unavailableReason ?? "").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                }
                if options.contains(where: \.requiresProcessingTool), !DownloadPlanner.processingReady { ProcessingToolOffer() }
                HStack { Spacer(); Button("Cancel", action: done)
                    Button("Download") { begin(src, executable) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(executable.isEmpty).accessibilityIdentifier("extractor-download")
                }
            }
        } else if let src = lookup.source, case .manifest(let u) = src.shape {
            Text(src.title).font(.system(size: 13, weight: .semibold))
            Text("The extractor found a stream playlist. The quality picker reads its real qualities.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel", action: done); Button("Choose Quality…") { done(); model.openLinkPreview(.mediaPreview(u)) }.buttonStyle(.borderedProminent) }
        }
    }

    private func currentOption(_ executable: [PlannedOption]) -> PlannedOption { executable.first { $0.id == pickKey } ?? executable[0] }

    private func label(_ p: PlannedOption) -> String {
        p.option.title + "  ·  " + p.option.provenance + (p.representation?.bytes.map { " · " + DownloadStats.bytes($0) } ?? "")
    }

    private func begin(_ src: NormalizedMediaSource, _ executable: [PlannedOption]) {
        guard lookup.operation == nil, !executable.isEmpty else { return }          // a second click starts nothing
        let chosen = currentOption(executable)
        guard let choice = chosen.choice else { return }
        var s = src; s.isPrivate = subject.isPrivate
        let op = SourceSaveOperation(source: s, choice: choice, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Video" : name, coordinator: model.engine.downloads, profileTag: MediaStore.profileTag(profile))
        op.pickVideo = chosen.representation          // exactly the format shown, whatever its kind
        op.pickAudio = chosen.audio                   // and the sound the planner chose
        op.pickStreamID = chosen.streamID
        lookup.operation = op; lookup.phase = .saving
        op.start()
    }
}

struct SourceSaveProgress: View {
    @ObservedObject var op: SourceSaveOperation
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch op.stage {
            case .waiting: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for the download to start…").font(.system(size: 12)).foregroundStyle(.secondary) }
            case .downloading(let f): ProgressView(value: f) { Text("Downloading…").font(.system(size: 12)) }
            case .converting(let f): ProgressView(value: f) { Text("Making the file on this Mac…").font(.system(size: 12)) }
            case .done(let url):
                Label("Saved: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12)).accessibilityIdentifier("video-sheet-done")
                RevealSavedFileButton(url: url)
            case .failed(let why): Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("extractor-save-failed")
            case .cancelled: Text("Cancelled.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack { Spacer(); if op.stage.isFinal { Button("Done", action: done).keyboardShortcut(.defaultAction) } else { Button("Cancel") { op.cancel() }.accessibilityIdentifier("video-sheet-cancel") } }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("video-sheet-progress")
    }
}


/// Shown in the Download sheet only when a page needs the extractor and none is installed: progress while it installs, Retry with the reason if it failed, or one quiet button to enable it.
struct MediaToolsOffer: View {
    @StateObject private var store = MediaToolsStore.shared
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch store.phase {
            case .working(let f, let t):
                // Stacked, not side by side: the text wraps in a narrow sheet instead of being cut off.
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: f).frame(maxWidth: 260).accessibilityLabel("Installing media tools").accessibilityValue("\(Int(f * 100)) percent")
                    Text("Installing media tools · \(t) \(Int(f * 100))%").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") { store.cancel() }.controlSize(.small).accessibilityIdentifier("media-tools-offer-cancel")
                }
                .accessibilityIdentifier("media-tools-offer-progress")
                Text("This video can be looked up when it finishes. You can keep browsing.").font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            case .failed(let why):
                Text(why).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Retry") { confirm = true }.controlSize(.small).accessibilityIdentifier("media-tools-offer-retry")
            case .checking, .ready:
                EmptyView()
            default:
                if store.manifest?.isInstallable == true { Button("Enable Advanced Media Downloads…") { confirm = true }.controlSize(.small).accessibilityIdentifier("media-tools-offer-enable") }
                else if store.manifest != nil { Text("Advanced media downloads are not available in this release yet. You can use a program you installed yourself (Settings › Media).").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("media-tools-offer-unavailable") }
            }
        }
        .onAppear { store.refresh() }
        .confirmationDialog(store.phase.isFailed ? "Try installing again?" : "Install advanced media downloads?", isPresented: $confirm) {
            Button("Download and Install\(store.sizeSummary.map { " (\($0))" } ?? "")") { store.install() }
            Button("Not Now", role: .cancel) { if store.choice == .undecided { store.setChoice(.declined) } }
        } message: { Text("Browser Setu downloads the extractor from its official release page, checks it against a fingerprint built into this app, and keeps it in its own folder. No administrator password is needed.") }
    }
}


/// Shown under the choices when some of them (joining WebM picture and sound, sound from WebM/Opus) only need the optional media processing tool: one quiet button, progress, Retry. The choice list updates by itself when it is ready.
struct ProcessingToolOffer: View {
    @StateObject private var store = MediaToolsStore.ffmpeg
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch store.phase {
            case .working(let f, let t):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: f).frame(maxWidth: 260).accessibilityLabel("Installing the media processing tool").accessibilityValue("\(Int(f * 100)) percent")
                    Text("Installing the media processing tool · \(t) \(Int(f * 100))%").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") { store.cancel() }.controlSize(.small)
                }.accessibilityIdentifier("processing-tools-offer-progress")
            case .failed(let why):
                Text(why).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Retry") { confirm = true }.controlSize(.small).accessibilityIdentifier("processing-tools-offer-retry")
            case .checking, .ready: EmptyView()
            default:
                if store.manifest?.isInstallable == true { Button("Enable Media Processing…") { confirm = true }.controlSize(.small).accessibilityIdentifier("processing-tools-offer-enable") }
                else { Text("The media processing tool is not available in this build yet.").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
        }
        .onAppear { store.refresh() }
        .confirmationDialog(store.phase.isFailed ? "Try installing again?" : "Install the media processing tool?", isPresented: $confirm) {
            Button("Download and Install\(store.sizeSummary.map { " (\($0))" } ?? "")") { store.install() }
            Button("Not Now", role: .cancel) {}
        } message: { Text("Browser Setu downloads FFmpeg from its release page, checks it against a fingerprint built into this app, and keeps it in its own folder. It works only on files on this Mac. No administrator password is needed.") }
    }
}
