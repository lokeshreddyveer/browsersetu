import SwiftUI

struct FeedSheet: View {
    @EnvironmentObject var model: BrowserModel
    var done: () -> Void
    var body: some View { FeedContent(feeds: model.feedSheetModel, model: model, done: done) }
}

private struct FeedContent: View {
    @ObservedObject var feeds: FeedSheetModel
    @ObservedObject var model: BrowserModel
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Feeds & Podcasts").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close", action: done).keyboardShortcut(.cancelAction).accessibilityIdentifier("feed-close")
            }
            HStack(spacing: 8) {
                TextField("Feed or website address", text: $feeds.address).textFieldStyle(.roundedBorder).onSubmit { feeds.load() }.accessibilityIdentifier("feed-address")
                if feeds.phase == .loading { ProgressView().controlSize(.small); Button("Stop") { feeds.cancelLoading() } }
                else { Button("Load") { feeds.load() }.disabled(feeds.address.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("feed-load") }
                Button("This Page's Feeds") { Task { await findOnPage() } }.disabled(model.active?.isBlank ?? true).help("Look for feeds the open page advertises").accessibilityIdentifier("feed-find")
            }
            if !feeds.found.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Feeds on this page").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(feeds.found, id: \.url) { f in
                        Button(f.title ?? f.url.absoluteString) { feeds.open(f) }.buttonStyle(.link).font(.system(size: 12)).lineLimit(1).accessibilityIdentifier("feed-found")
                    }
                }
            }
            content
            if let m = feeds.message { Text(m).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("feed-message") }
        }
        .padding(18).frame(minWidth: 560, idealWidth: 620, minHeight: 440)
        .accessibilityElement(children: .contain).accessibilityIdentifier("feed-sheet")
        .onAppear { feeds.isPrivate = model.active?.leavesNoTrace ?? false }          // (changing it clears what the other kind of tab loaded)
        .onDisappear { feeds.cancelLoading() }
    }

    @ViewBuilder private var content: some View {
        switch feeds.phase {
        case .idle where feeds.needsPlaylistConsent:
            VStack(alignment: .leading, spacing: 8) {
                Text("Look this playlist up with your extractor?").font(.system(size: 13, weight: .semibold))
                Text("The address of \(feeds.playlistHost ?? "this page") will be passed to the program you chose in Settings, and then the address of each entry you choose to download. That program is independently maintained third-party software; it may make its own network requests and runs with your Mac permissions. Nothing else is given to it. A protected or sign-in-only video will not be saved.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow for \(feeds.playlistHost ?? "This Site")") { feeds.allowPlaylist(scope: .site(feeds.playlistHost ?? "")) }.accessibilityIdentifier("feed-allow-site")
                    Button("Allow for This Profile") { feeds.allowPlaylist(scope: .profile) }.accessibilityIdentifier("feed-allow-profile")
                    Button("Don't Allow") { feeds.needsPlaylistConsent = false }
                }.controlSize(.small)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("feed-playlist-consent")
            Spacer()
        case .idle:
            Text("Paste the address of a podcast or blog feed, or of a page that has one, and press Load. Choose the episodes or files you want; nothing is downloaded until you press Download.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the feed…").font(.system(size: 12)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("feed-failed")
            if let page = feeds.playlistOffer {
                Text("This page may hold a playlist of videos. Your own extractor program can list it; the page's address is given to it, and nothing is downloaded until you choose entries.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Look Up as a Playlist…") { feeds.lookUpAsPlaylist(page: page) }.accessibilityIdentifier("feed-playlist")
            }
            Spacer()
        case .ready:
            if let feed = feeds.feed { list(feed) }
        }
    }

    @ViewBuilder private func list(_ feed: DownloadFeed) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(feed.title.isEmpty ? "Feed" : feed.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(feed.items.count) entries · \(feed.items.filter { !$0.enclosures.isEmpty }.count) with files").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !feeds.isPlaylist { Button(feeds.subscription == nil ? "Subscribe" : "Unsubscribe") { feeds.toggleSubscription() }.controlSize(.small).accessibilityIdentifier("feed-subscribe") }
            Button("Refresh") { feeds.refresh() }.controlSize(.small).accessibilityIdentifier("feed-refresh")
        }
        HStack(spacing: 8) {
            TextField("Search entries", text: $feeds.search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            Toggle("New only", isOn: $feeds.onlyNew).toggleStyle(.checkbox).disabled(feeds.subscription == nil).help(feeds.subscription == nil ? "Subscribe to see what is new since you last downloaded" : "Hide entries you have already downloaded")
            Spacer()
            Button("Select All") { feeds.selectAll() }.controlSize(.small).accessibilityIdentifier("feed-select-all")
            Button("Select None") { feeds.selectNone() }.controlSize(.small).accessibilityIdentifier("feed-select-none")
        }
        List(feeds.visible) { item in row(item) }
            .listStyle(.inset).accessibilityIdentifier("feed-list")
        HStack {
            Text(feeds.selection.isEmpty ? "Nothing selected" : "\(feeds.selectedItems.count) selected").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityIdentifier("feed-count")
            if feeds.isPlaylist {
                if feed.more { Button(feeds.loadingMore ? "Loading…" : "Load More Entries") { feeds.loadMorePlaylist() }.controlSize(.small).disabled(feeds.loadingMore).accessibilityIdentifier("feed-more") }
                if feeds.runner.running { Button("Stop Saving") { feeds.runner.cancel() }.controlSize(.small).accessibilityIdentifier("feed-stop") }
                else if feeds.runner.failedCount > 0 { Button("Retry \(feeds.runner.failedCount) Failed") { feeds.retryPlaylistFailures() }.controlSize(.small).accessibilityIdentifier("feed-retry") }
            }
            Spacer()
            if feeds.isPlaylist {
                Picker("Quality", selection: $feeds.quality) { ForEach(PlaylistQuality.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.menu).controlSize(.small).fixedSize().help("What to save from each entry. Right-click an entry to choose differently for it.").accessibilityIdentifier("feed-quality")
            }
            Button("Download \(feeds.selectedItems.count)") { if feeds.isPlaylist { feeds.downloadPlaylist() } else { Task { await feeds.download(isPrivate: model.active?.leavesNoTrace ?? false) } } }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(feeds.selectedItems.isEmpty || feeds.busy).accessibilityIdentifier("feed-download")
        }
    }

    private func row(_ item: DownloadFeedItem) -> some View {
        let selectable = feeds.isSelectable(item)
        let state = feeds.isPlaylist ? feeds.runner.states[item.id] : nil
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { feeds.selection.contains(item.id) }, set: { on in if on { feeds.selection.insert(item.id) } else { feeds.selection.remove(item.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!selectable).accessibilityLabel(item.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                    if feeds.isNewItem(item) { Text("New").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Theme.accent.opacity(0.18))).foregroundStyle(Theme.accent) }
                }
                Text(state.map(describe) ?? detail(item)).font(.system(size: 11)).foregroundStyle(state.map(color) ?? .secondary).lineLimit(2)
                if !item.summary.isEmpty { Text(item.summary).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if selectable { if feeds.selection.contains(item.id) { feeds.selection.remove(item.id) } else { feeds.selection.insert(item.id) } } }
        .accessibilityElement(children: .contain).accessibilityIdentifier("feed-row")
        .playlistQualityMenu(feeds: feeds, item: item)
    }

    private func detail(_ item: DownloadFeedItem) -> String {
        var parts: [String] = []
        if let d = item.published { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        if let s = item.season, let e = item.episode { parts.append("S\(s) E\(e)") } else if let e = item.episode { parts.append("Episode \(e)") }
        if let t = item.duration, t > 0 { parts.append(Duration.seconds(t).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) }
        if let e = item.enclosures.first {
            parts.append(FeedCollection.fileExtension(for: e)?.uppercased() ?? "File")
            if let l = e.length, l > 0 { parts.append(ByteCountFormatter.string(fromByteCount: l, countStyle: .file)) }
            if item.enclosures.count > 1 { parts.append("+\(item.enclosures.count - 1) more") }
        } else if item.link != nil { parts.append("Video page") } else { parts.append("No file") }
        return parts.joined(separator: " · ")
    }

    private func describe(_ s: PlaylistRunner.ItemState) -> String {
        switch s {
        case .waiting: "Waiting…"
        case .looking: "Looking it up…"
        case .saving(let f): "Saving… \(Int(f * 100))%"
        case .done(let name): "Saved: \(name)"
        case .failed(let why): why
        case .skipped(let why): why
        }
    }
    private func color(_ s: PlaylistRunner.ItemState) -> Color { if case .failed = s { return .orange }; if case .done = s { return .green }; return .secondary }

    private func findOnPage() async {
        guard let tab = model.active, let html = await tab.engine.pageSource(), let page = tab.url else { return }
        let links = DownloadFeedDiscovery.links(inHTML: html, pageURL: page)
        feeds.found = links
        feeds.message = links.isEmpty ? "This page does not advertise a feed." : nil
        if links.count == 1, let only = links.first { feeds.open(only) }
    }
}


private extension View {
    /// The per-entry quality choice, only on a playlist's rows (a feed's rows are left exactly as they were).
    @ViewBuilder func playlistQualityMenu(feeds: FeedSheetModel, item: DownloadFeedItem) -> some View {
        if feeds.isPlaylist {
            self.contextMenu {
                Picker("Quality for this entry", selection: Binding(get: { feeds.entryQuality[item.id] ?? feeds.quality }, set: { feeds.entryQuality[item.id] = $0 })) { ForEach(PlaylistQuality.allCases) { Text($0.title).tag($0) } }
                if feeds.entryQuality[item.id] != nil { Button("Use the Default Quality") { feeds.entryQuality[item.id] = nil } }
            }
        } else { self }
    }
}
