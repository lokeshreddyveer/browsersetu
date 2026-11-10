import SwiftUI

/// DX-09: what the site in front permits, and the actions that really work for it. Download appears only for a source the provider's own authorization produced; a site with no authorized route
/// shows why, and where its official route is. Every button here calls the real resolver, authorization store or download engine.
struct ProviderPanel: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var flow: ProviderFlow
    /// The item chosen in the list, if any: its embedded frame (known from WebKit's frame information) is what the lookup is told about besides the page.
    var selected: MediaCandidate?
    @State private var problem: String?
    /// Bumped when a window becomes key again (coming back from Settings after authorizing), so the panel looks at the authorization afresh.
    @State private var windowTick = 0
    @State private var started: Set<String> = []

    var body: some View {
        if let ctx = flow.currentContext(frame: frameURL), let match = ProviderRecognizer.provider(for: ctx).page, match.provider != .generic {
            content(ctx, match)
        }
    }

    private var frameURL: URL? { selected?.players.first(where: { !$0.frame.isMain }).flatMap { URL(string: $0.frame.origin) } }

    private func authorized(_ p: MediaProviderID, _ ctx: MediaPageContext) -> Bool { !ctx.isPrivate && ProviderCredentials.token(p, profile: ctx.profile) != nil }

    @ViewBuilder private func content(_ ctx: MediaPageContext, _ match: ProviderMatch) -> some View {
        let provider = match.provider
        let caps = ProviderRegistry.adapter(for: provider).capabilities(for: match, authorized: authorized(provider, ctx))
        let entry = flow.entry(for: ctx)
        VStack(alignment: .leading, spacing: 6) {
            Label(provider.displayName, systemImage: caps.canDownloadNow || provider == .vimeo ? "checkmark.shield" : "lock.shield").font(.system(size: 12.5, weight: .semibold))
                .accessibilityIdentifier("provider-name")
            if let f = ctx.frameURL?.host { Text("Playing in an embedded frame from \(f)").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityIdentifier("provider-frame") }
            if let n = caps.note { Text(n).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if ctx.isPrivate && provider == .vimeo { Text("Private tabs do not use your Vimeo authorization.").font(.system(size: 11)).foregroundStyle(.orange) }
            if let e = entry { stateLine(e).accessibilityIdentifier("provider-state") }
            if let p = problem { Text(p).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                if provider == .peertube, match.mediaID != nil {
                    Button(isLooking(entry) ? "Looking…" : "Check this video") { flow.resolve(ctx) }.disabled(isLooking(entry)).accessibilityIdentifier("provider-resolve")
                    if isLooking(entry) { Button("Cancel") { flow.cancel(ctx) }.accessibilityIdentifier("provider-cancel") }
                }
                if provider == .vimeo, match.mediaID != nil {
                    Button(isLooking(entry) ? "Looking…" : "Resolve") { flow.resolve(ctx) }
                        .disabled(isLooking(entry) || ctx.isPrivate).accessibilityIdentifier("provider-resolve")
                    if isLooking(entry) { Button("Cancel") { flow.cancel(ctx) }.accessibilityIdentifier("provider-cancel") }
                    Button("Manage account…") {
                        // Settings is a window of its own and cannot be used while a sheet of the browser window is open, so the panel is closed first; the list it found stays and is there when it is opened again.
                        model.sheet = nil
                        SettingsRouter.open(.downloads)
                    }.disabled(ctx.isPrivate).accessibilityIdentifier("provider-manage-account")
                        .help(authorized(provider, ctx) ? "Vimeo is authorized for this profile. Change it in Settings ▸ Downloads ▸ Providers." : "Authorize Vimeo for this profile in Settings ▸ Downloads ▸ Providers.")
                }
                if provider == .tiktok { Button("Export my TikTok data…") { model.tiktokExportRequested = true; model.ensureDownloadsShown() }.disabled(ctx.isPrivate).help(ctx.isPrivate ? "Private tabs do not use your account's authorization." : "Opens the account export in Downloads") }
                if let alt = caps.alternative, let url = alt.url { Link(alt.title, destination: url).font(.system(size: 11.5)) }
                else if let alt = caps.alternative, provider != .vimeo { Text(alt.title).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if let e = entry, e.state == .ready, let sources = e.resolution?.sources {
                ForEach(Array(sources.enumerated()), id: \.offset) { i, s in
                    Button { download(s, ctx) } label: { Label(sourceLabel(s), systemImage: "arrow.down.circle") }
                        .disabled(started.contains(s.identity)).accessibilityIdentifier("provider-download-\(i)")
                }
                if e.renewals > 0 { Text("Link renewed \(e.renewals) time\(e.renewals == 1 ? "" : "s") for the same file.").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityIdentifier("provider-renewed") }
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        // Looks up by itself, once: when the media picker is open on a page this site recognises with the video's id, this profile is authorized, and it is not a private tab. Never on page load, and
        // never without an authorization; Resolve stays as a manual refresh. A lookup that ended asking for authorization is repeated once the authorization is there.
        .task(id: "\(FlowKey.of(ctx))|\(authorized(provider, ctx))|\(windowTick)") {
            // Vimeo needs this profile's authorization; PeerTube's public API needs none (so it is asked only about the host the person is already on).
            guard (provider == .vimeo && authorized(provider, ctx)) || provider == .peertube, match.mediaID != nil, !ctx.isPrivate else { return }
            let current = flow.entry(for: ctx)
            if current == nil || current?.state == .authorizationRequired { flow.resolve(ctx) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in windowTick += 1 }
        .animation(.easeInOut(duration: 0.18), value: entry?.state)
    }

    private func isLooking(_ e: ProviderFlow.Entry?) -> Bool { e?.state == .resolving || e?.state == .identifying }

    private func sourceLabel(_ s: AuthorizedMediaSource) -> String {
        var parts = ["Download", s.quality ?? s.contentType ?? "file"]
        if let w = s.width, let h = s.height { parts.append("\(w)×\(h)") }
        if let b = s.bytes { parts.append(DownloadStats.bytes(b)) }
        if let e = s.expiresAt { parts.append("link good until " + e.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func stateLine(_ e: ProviderFlow.Entry) -> some View {
        switch e.state {
        case .identifying, .discovering, .resolving, .recovering: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Asking the website…").font(.system(size: 11)).foregroundStyle(.secondary) }
        case .authorizationRequired: Text(e.message ?? "Authorize this website to continue.").font(.system(size: 11)).foregroundStyle(.orange)
        case .restricted: Text(e.message ?? "The website does not allow this.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .refreshRequired: Text("The link ran out; getting a new one for the same file…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .failed(let why): Text(why).font(.system(size: 11)).foregroundStyle(.orange)
        case .unsupported: Text(e.message ?? "Nothing can be downloaded from here with this authorization.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .ready: Text("\(e.resolution?.sources.count ?? 0) download\(e.resolution?.sources.count == 1 ? "" : "s") available.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .cancelled: EmptyView()
        }
    }

    private func download(_ s: AuthorizedMediaSource, _ ctx: MediaPageContext) {
        problem = nil
        let base = (s.title ?? s.mediaID)
        let ext = s.contentType?.contains("mp4") == true || s.contentType == "source" ? "mp4" : "mp4"
        Task {
            do { _ = try await flow.start(s, in: ctx, name: "\(base) \(s.quality ?? "").\(ext)".replacingOccurrences(of: "  ", with: " "), origin: flow.downloadOrigin); started.insert(s.identity); model.ensureDownloadsShown() }
            catch { problem = (error as? LocalizedError)?.errorDescription ?? "It could not be started." }
        }
    }
}

extension MediaProviderID: Identifiable { public var id: String { rawValue } }

/// Authorization by access token: for Vimeo, a token the person created for their own account in Vimeo's developer settings, with the scopes this needs. Stored in the Keychain for this profile only,
/// sent only to the provider's API address, removable here at any time. (A sign-in window needs an app registered with the provider; none is built in.)
struct ProviderTokenSheet: View {
    let provider: MediaProviderID
    let profile: String
    var saved: () -> Void
    var cancel: () -> Void
    @State private var token = ""
    @State private var has = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Authorize \(provider.displayName)").font(.system(size: 14, weight: .semibold))
            Text(explanation).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Access token", text: $token).textFieldStyle(.roundedBorder).accessibilityIdentifier("provider-token-field")
            Text("The token is kept in this profile's Keychain, sent only to \(ProviderCatalog.entry(provider).apiHost ?? "the website's API"), never written to a log or a download record, and never used in a private tab.").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if has { Button("Remove authorization", role: .destructive) { ProviderCredentials.revoke(provider, profile: profile); has = false; token = ""; saved() } }
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save") { if ProviderCredentials.store(token.trimmingCharacters(in: .whitespacesAndNewlines), provider, profile: profile) { saved() } }
                    .buttonStyle(.borderedProminent).disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).count < 8).keyboardShortcut(.defaultAction).accessibilityIdentifier("provider-token-save")
            }
        }
        .padding(16).frame(width: 420)
        .onAppear { has = ProviderCredentials.token(provider, profile: profile) != nil }
    }

    private var explanation: String {
        switch provider {
        case .vimeo: "Vimeo gives download links only to the video's owner (or someone the owner allowed), on plans that include them. Create a personal access token for your own account at developer.vimeo.com with the scopes public, private and video_files, and paste it here. This app asks Vimeo for the video's owner-enabled download links and nothing else."
        case .tiktok: "TikTok's Data Portability API works only for apps TikTok has approved and for eligible accounts (currently users in the EEA and the UK). Paste an access token your approved app obtained for you with a portability scope. This app cannot make an app or an account eligible."
        default: "This website has no authorization that this app uses."
        }
    }
}

struct TikTokExportView: View {
    @StateObject var model: TikTokExportModel
    var close: () -> Void
    @State private var token = ""
    @State private var polling: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export my TikTok data").font(.system(size: 14, weight: .semibold))
            Text("TikTok prepares an archive of your own account data and lets an approved app download it as a ZIP file. It is not a way to download other people's videos, and it is available only where TikTok offers it (currently the EEA and the UK) to apps TikTok has approved. Required scope: \(TikTokExportModel.scopes).")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.token == nil || model.phase == .needsToken {
                SecureField("Access token", text: $token).textFieldStyle(.roundedBorder)
                Button("Save token") { _ = ProviderCredentials.store(token.trimmingCharacters(in: .whitespacesAndNewlines), .tiktok, profile: model.profile); token = ""; model.objectWillChange.send() }.disabled(token.count < 8)
            }
            Picker("Format", selection: $model.format) { Text("JSON").tag("json"); Text("Text").tag("text") }.pickerStyle(.segmented).disabled(model.phase != .idle && model.phase != .needsToken)
            ForEach(TikTokExportModel.categories, id: \.self) { c in
                Toggle(c.replacingOccurrences(of: "_", with: " "), isOn: Binding(get: { model.chosen.contains(c) }, set: { on in if on { model.chosen.insert(c) } else { model.chosen.remove(c) } })).toggleStyle(.checkbox).font(.system(size: 11.5))
            }
            Text(status).font(.system(size: 11.5)).foregroundStyle(statusColor).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Forget request", role: .destructive) { model.forget() }.disabled(model.requestID == nil)
                Spacer()
                Button("Close") { polling?.cancel(); close() }
                switch model.phase {
                case .idle, .needsToken, .cancelled, .expired, .ineligible where model.requestID == nil || model.phase == .expired || model.phase == .cancelled: Button("Request") { Task { await model.request() } }.buttonStyle(.borderedProminent).disabled(model.token == nil)
                case .failed where model.requestID == nil: Button("Request") { Task { await model.request() } }.buttonStyle(.borderedProminent).disabled(model.token == nil)
                case .failed, .ineligible, .needsToken: Button("Check status") { Task { await model.check() } }
                case .pending: Button("Check status") { Task { await model.check() } }
                case .ready: Button("Download ZIP") { Task { await model.download() } }.buttonStyle(.borderedProminent)
                case .requesting, .downloading: ProgressView().controlSize(.small)
                case .done: EmptyView()
                }
            }
        }
        .padding(16).frame(width: 460)
        .onAppear { if model.phase == .pending { Task { await model.check() } } }
    }

    private var status: String {
        switch model.phase {
        case .idle: "Choose what to export, then request it."
        case .needsToken: "TikTok did not accept the token, or there is none. Paste a valid one."
        case .requesting: "Asking TikTok to collect your data…"
        case .pending: "TikTok is still collecting your data. This can take minutes or hours; check again later (the request is remembered)."
        case .ready: "Your archive is ready. TikTok keeps it for about four days."
        case .expired: "This request expired. Request the data again."
        case .cancelled: "This request was cancelled."
        case .downloading: "Downloading the archive…"
        case .done(let n): "Saved \(n) in your Downloads folder."
        case .failed(let w), .ineligible(let w): w
        }
    }
    private var statusColor: Color { switch model.phase { case .failed, .ineligible, .needsToken: .orange; default: .secondary } }
}

private enum FlowKey { @MainActor static func of(_ c: MediaPageContext) -> String { ProviderFlow.key(c) } }
