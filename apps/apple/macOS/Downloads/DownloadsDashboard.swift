import SwiftUI
import AppKit

// The Downloads window: a native table over the rows the view model projects from the ledger, an optional details inspector, and one context menu that works on the selection.
// Nothing here changes a task. Every button asks the view model, which asks the coordinator.

/// What a card hosting the dashboard offers it: a way to close, and a way to be moved by the header. Neither exists where the dashboard fills a tab.
struct PanelMover {
    var move: (CGSize) -> Void
    var end: () -> Void
}

private struct PanelCloseKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
private struct PanelMoverKey: EnvironmentKey { static let defaultValue: PanelMover? = nil }

extension EnvironmentValues {
    var panelClose: (() -> Void)? {
        get { self[PanelCloseKey.self] }
        set { self[PanelCloseKey.self] = newValue }
    }
    var panelMover: PanelMover? {
        get { self[PanelMoverKey.self] }
        set { self[PanelMoverKey.self] = newValue }
    }
}

struct DownloadsDashboard: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View { DownloadsDashboardContent(vm: model.downloadList, coordinator: model.downloads) }
}

private enum ColumnPrefs {
    static let key = "downloads.columns.v3"
    static func load() -> TableColumnCustomization<DownloadRow> {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(TableColumnCustomization<DownloadRow>.self, from: data) else { return TableColumnCustomization() }
        return value
    }
    static func save(_ value: TableColumnCustomization<DownloadRow>) { if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) } }
}

struct DownloadsDashboardContent: View {
    @ObservedObject var vm: DownloadsViewModel
    let coordinator: DownloadCoordinator
    @EnvironmentObject var model: BrowserModel
    @State private var sortOrder: [KeyPathComparator<DownloadRow>] = [KeyPathComparator(\.date, order: .reverse)]
    @State private var columns = ColumnPrefs.load()
    @State private var adding = false
    @State private var grabbing = false
    @State private var discovering = false
    @State private var videoSubject: VideoSubject?
    /// A video sheet waiting for the sheet that asked for it to finish closing (shown from `presentPendingVideoSheet`, never on a timer).
    @State private var pendingVideoSubject: VideoSubject?
    @State private var exploring = false
    @State private var zipping = false
    @State private var feeding = false
    @State private var remoteFiles = false
    @State private var providerFiles = false
    @State private var packaging = false
    @State private var creatingTorrent = false
    @State private var exportingTikTok = false
    @State private var prefill: String?
    @State private var prefillTorrent: URL?
    @State private var confirmingClearAll = false
    @Environment(\.panelClose) private var closePanel
    @Environment(\.panelMover) private var mover

    var body: some View {
        GeometryReader { proxy in
            let inspectorFits = proxy.size.width >= 900
            VStack(spacing: 0) {
                header
                DownloadFilterBar(vm: vm)
                if let note = vm.message {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 6)
                        .task(id: note) { try? await Task.sleep(for: .seconds(6)); if vm.message == note { vm.message = nil } }
                        .accessibilityLabel(note)
                }
                Divider().opacity(0.5)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ZStack { table; emptyState }
                        if vm.hasMoreHistory {
                            Divider().opacity(0.4)
                            Button("Show Older Downloads") { vm.loadMoreHistory() }.buttonStyle(.link).font(.system(size: 12)).frame(maxWidth: .infinity).frame(height: 28)
                                .accessibilityHint("Loads the next 200 downloads from before the task list")
                        }
                    }
                    if vm.inspectorShown && inspectorFits {
                        Divider().opacity(0.5)
                        DownloadInspector(vm: vm).frame(width: 260).transition(.opacity)
                    }
                }
            }
        }
        .onAppear { vm.acquire(); sortOrder = Self.comparators(for: vm.query); takeRequests() }
        .onChange(of: adding) { _, now in if !now { prefill = nil; prefillTorrent = nil } }
        .onChange(of: model.linkGrabberRequested) { _, _ in takeRequests() }
        .onChange(of: model.addDownloadPrefill) { _, _ in takeRequests() }
        .onChange(of: model.pendingTorrentFile) { _, _ in takeRequests() }
        .sheet(isPresented: $grabbing) { LinkGrabberSheet { grabbing = false } }
        .sheet(isPresented: $creatingTorrent) { CreateTorrentView { creatingTorrent = false } }
        .sheet(isPresented: $discovering) { MediaDiscoverySheet { discovering = false } }
        .sheet(item: $videoSubject) { subject in VideoDownloadSheet(subject: subject) { videoSubject = nil }.environmentObject(model) }
        .onChange(of: model.videoSheetRequest) { _, _ in takeRequests() }
        .onChange(of: otherSheetOpen) { _, _ in presentPendingVideoSheet() }
        .sheet(isPresented: $exploring) { ExplorerSheet { exploring = false } }
        .sheet(isPresented: $exportingTikTok) { TikTokExportView(model: TikTokExportModel(profile: model.profileName, isPrivate: false, coordinator: { coordinator }), close: { exportingTikTok = false }) }
        .onChange(of: model.tiktokExportRequested) { _, _ in takeRequests() }
        .sheet(isPresented: $zipping) { RemoteZipSheet { zipping = false } }
        .sheet(isPresented: $feeding) { FeedSheet { feeding = false }.environmentObject(model) }
        .sheet(isPresented: $remoteFiles) { RemoteFilesSheet { remoteFiles = false }.environmentObject(model) }
        .sheet(isPresented: $providerFiles) { ProviderFilesSheet { providerFiles = false }.environmentObject(model) }
        .onChange(of: model.providersRequested) { _, _ in takeRequests() }
        .onChange(of: model.remoteRequested) { _, _ in takeRequests() }
        .onChange(of: model.feedsRequested) { _, _ in takeRequests() }
        .onChange(of: model.remoteZipRequested) { _, _ in takeRequests() }
        .sheet(isPresented: $packaging) { PackagesSheet { packaging = false } }
        .onChange(of: model.explorerRequested) { _, _ in takeRequests() }
        .onChange(of: model.packagesRequested) { _, _ in takeRequests() }
        .onChange(of: model.mediaDiscoveryRequested) { _, _ in takeRequests() }
        .onDisappear { vm.release() }
        .onChange(of: sortOrder) { _, new in applySort(new) }
        .onChange(of: columns) { _, new in ColumnPrefs.save(new) }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { !vm.pendingTrash.isEmpty }, set: { if !$0 { vm.cancelTrash() } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { vm.confirmTrash() }
            Button("Keep Files", role: .cancel) { vm.cancelTrash() }
        } message: { Text("The files are moved to the Trash and removed from this list. Use Remove from List to keep a file and only forget the entry.") }
        .confirmationDialog("Clear all download history?", isPresented: $confirmingClearAll, titleVisibility: .visible) {
            Button("Clear \(vm.rowsToClear(.allFinished).count) Finished Downloads", role: .destructive) { vm.clearHistory(.allFinished) }
            Button("Keep Them", role: .cancel) {}
        } message: { Text("Only the list entries are removed. The downloaded files stay where they are, and downloads that are still running, waiting or paused are not touched.") }
    }

    private var otherSheetOpen: Bool { discovering || grabbing || adding || exploring || zipping || packaging || creatingTorrent || exportingTikTok }
    private func presentPendingVideoSheet() { if let v = pendingVideoSubject, !otherSheetOpen { pendingVideoSubject = nil; videoSubject = v } }

    /// A link that was clicked or chosen elsewhere opens its preview here; the LinkGrabber opens when asked for. Each request is taken once.
    private func takeRequests() {
        if model.linkGrabberRequested { model.linkGrabberRequested = false; grabbing = true }
        if model.mediaDiscoveryRequested { model.mediaDiscoveryRequested = false; discovering = true }
        if let v = model.videoSheetRequest {
            model.videoSheetRequest = nil
            // One sheet at a time: the media picker, if it asked for this, is closed first, and the video sheet is shown when it has gone.
            pendingVideoSubject = v; discovering = false
            presentPendingVideoSheet()
        }
        if model.explorerRequested { model.explorerRequested = false; exploring = true }
        if model.remoteZipRequested { model.remoteZipRequested = false; zipping = true }
        if model.feedsRequested { model.feedsRequested = false; feeding = true }
        if model.remoteRequested { model.remoteRequested = false; remoteFiles = true }
        if model.providersRequested { model.providersRequested = false; providerFiles = true }
        if model.packagesRequested { model.packagesRequested = false; packaging = true }
        if model.tiktokExportRequested { model.tiktokExportRequested = false; exportingTikTok = true }
        if let text = model.addDownloadPrefill { model.addDownloadPrefill = nil; prefill = text; prefillTorrent = nil; adding = true }
        if let file = model.pendingTorrentFile { model.pendingTorrentFile = nil; prefillTorrent = file; prefill = nil; adding = true }
    }

    /// One place for the ways of finding things to download. Each entry is the existing action (the same sheets and commands the Library menu uses); nothing here is new machinery.
    private var collectMenu: some View {
        Menu {
            Button("Find Media on This Page…") { model.discoverMediaOnCurrentPage() }.disabled(model.active?.isBlank ?? true)
            Button("Explore This Website…") { model.exploreCurrentSite() }.disabled(model.active?.isBlank ?? true)
            Button("Collect Images from This Page") { Task { await model.collectImagesFromCurrentPage() } }.disabled(model.active?.isBlank ?? true)
            Button("LinkGrabber") { grabbing = true }
            Button("Download Packages…") { model.openPackages() }
            Button("Open Archive from Address…") { model.openRemoteZip() }
            Button("Feeds & Podcasts…") { model.openFeeds() }
            Button("Remote Files…") { model.openRemote() }
            Button("Repositories & Models…") { model.openProviders(address: model.active?.url.flatMap { ProviderRoute.recognise($0) != nil ? $0.absoluteString : nil }) }
            Divider()
            Button("Export My TikTok Data…") { exportingTikTok = true }
        } label: { HeaderMenuLabel(symbol: "square.stack.3d.down.right", name: "Collect") }
            .headerMenuStyle()
            .help("Collect: find media, explore a website, gather links, open an archive or an account export")
            .accessibilityLabel("Collect").accessibilityIdentifier("downloads-collect")
    }

    private var trashTitle: String { vm.pendingTrash.count == 1 ? "Move “\(vm.pendingTrash[0].filename)” to the Trash?" : "Move \(vm.pendingTrash.count) files to the Trash?" }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            // The title end of the header is the handle: drag it to move the card.
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("Downloads").font(.system(size: 15, weight: .semibold))
                Text("\(vm.counted)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global).onChanged { mover?.move($0.translation) }.onEnded { _ in mover?.end() })
            .help(mover == nil ? "" : "Drag to move")
            .accessibilityElement(children: .combine)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search downloads", text: $vm.query.search).textFieldStyle(.plain).font(.system(size: 12.5))
                    .accessibilityLabel("Search downloads")
                if !vm.query.search.isEmpty {
                    Button { vm.query.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 9).frame(width: 220, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            filterMenu
            queueControls
            collectMenu
            Button { creatingTorrent = true } label: { Image(systemName: "doc.badge.plus") }
                .help("Create a torrent from a file or folder").accessibilityLabel("Create torrent")
            Button { adding = true } label: { Image(systemName: "plus") }
                .help("Add a download from a link").accessibilityLabel("Add download")
                .sheet(isPresented: $adding) { AddDownloadForm(coordinator: coordinator, extensions: model.downloadExtensions, initialText: prefill, initialTorrentFile: prefillTorrent, preferences: model.mediaPreferences, initialOrigin: model.addDownloadPrefillOrigin) { adding = false; prefill = nil; prefillTorrent = nil }.environmentObject(model)
                    .id(prefill ?? prefillTorrent?.path ?? "form") }
            Button { animated(.easeOut(duration: 0.18)) { vm.inspectorShown.toggle() } } label: { Image(systemName: "sidebar.right") }
                .help(vm.inspectorShown ? "Hide Details" : "Show Details").accessibilityLabel(vm.inspectorShown ? "Hide details" : "Show details")
            moreMenu
            if let closePanel {
                Button { closePanel() } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction).help("Close").accessibilityLabel("Close")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).frame(height: 44)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Priority", selection: $vm.query.priority) {
                Text("Any priority").tag(DownloadPriority?.none)
                ForEach(DownloadPriority.allCases) { Text($0.title).tag(DownloadPriority?.some($0)) }
            }
            Picker("Source", selection: $vm.query.protocolLabel) {
                Text("Any source").tag(String?.none)
                ForEach(Array(Set(vm.rows.map(\.protocolLabel))).sorted(), id: \.self) { Text($0).tag(String?.some($0)) }
            }
        } label: {
            HeaderMenuLabel(symbol: (vm.query.priority != nil || vm.query.protocolLabel != nil) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", name: "Filters")
        }
        .headerMenuStyle().help("Filter").accessibilityLabel("Filters")
    }

    /// The list's housekeeping, in one compact menu. Everything here removes list entries only, except the Trash item, which asks first.
    private var moreMenu: some View {
        Menu {
            let selected = vm.count(for: .removeRecord)
            let active = vm.count(for: .cancel)
            let files = vm.count(for: .trashFile)
            Button(selected > 1 ? "Remove \(selected) from List" : "Remove from List") { vm.perform(.removeRecord) }.disabled(selected == 0)
            Button(active > 1 ? "Cancel and Remove \(active)" : "Cancel and Remove") { vm.cancelAndRemove() }.disabled(active == 0)
            Divider()
            Button("Clear Completed (\(vm.rowsToClear(.completed).count))") { vm.clearHistory(.completed) }.disabled(vm.rowsToClear(.completed).isEmpty)
            Button("Clear Failed and Cancelled (\(vm.rowsToClear(.failedAndCancelled).count))") { vm.clearHistory(.failedAndCancelled) }.disabled(vm.rowsToClear(.failedAndCancelled).isEmpty)
            Button("Clear All History…") { confirmingClearAll = true }.disabled(vm.rowsToClear(.allFinished).isEmpty)
            Divider()
            Button(files > 1 ? "Move \(files) Files to Trash…" : "Move File to Trash…", role: .destructive) { vm.requestTrash() }.disabled(files == 0)
        } label: {
            HeaderMenuLabel(symbol: "ellipsis.circle", name: "More")
        }
        .headerMenuStyle().help("Remove and clear").accessibilityLabel("More")
    }

    /// What the queue button says aloud: whether it is paused and, when it is held until a time, that time (the same words the button shows).
    private var queueName: String { vm.held ? "Queue paused" + (vm.holdNote.map { ", \($0)" } ?? "") : "Queue" }

    private var queueControls: some View {
        Menu {
            if vm.held { Button("Resume Queue") { vm.resumeAll() } } else { Button("Pause All") { vm.pauseAll() } }
            Menu("Hold Until…") {
                Button("In an hour") { coordinator.holdQueue(until: Date().addingTimeInterval(3600)) }
                Button("2:00 at night") { if let t = DownloadSchedule.nextOccurrence(hour: 2, minute: 0) { coordinator.holdQueue(until: t) } }
                Button("7:00 in the morning") { if let t = DownloadSchedule.nextOccurrence(hour: 7, minute: 0) { coordinator.holdQueue(until: t) } }
                Divider()
                Button("Until I resume") { coordinator.holdQueue(until: .distantFuture) }
            }
        } label: {
            HStack(spacing: 4) {
                HeaderMenuLabel(symbol: vm.held ? "pause.circle.fill" : "pause.circle", name: queueName)
                if let note = vm.holdNote { Text(note).font(.system(size: 11.5)).lineLimit(1) }
            }
            .foregroundStyle(vm.held ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tint))
        }
        .headerMenuStyle().help("Queue").accessibilityLabel(queueName)
    }

    // MARK: Table

    private func dragProvider(for row: DownloadRow) -> NSItemProvider? {
        guard let file = coordinator.managedFile(of: row.id) else { return nil }
        return NSItemProvider(contentsOf: file)
    }

    private var table: some View {
        Table(of: DownloadRow.self, selection: $vm.selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            // In this table speed and time left have columns of their own, so a downloading row's second line is only how much has arrived.
            TableColumn("Name", value: \.filename) { row in DownloadNameCell(row: row, inTable: true) }
                .width(min: 150, ideal: 190).customizationID("name")
            TableColumn("Size", value: \.sortSize) { row in Text(DownloadFormat.size(row.totalBytes) ?? "—").foregroundStyle(.secondary) }
                .width(min: 52, ideal: 58, max: 90).customizationID("size")
            TableColumn("Progress", value: \.sortProgress) { row in DownloadProgressCell(row: row) }
                .width(min: 84, ideal: 104, max: 180).customizationID("progress")
            TableColumn("Speed") { row in Text(DownloadFormat.speed(row.bytesPerSecond) ?? "—").foregroundStyle(.secondary) }
                .width(min: 62, ideal: 70, max: 100).customizationID("speed")
            TableColumn("ETA") { row in Text(DownloadFormat.eta(row.secondsLeft) ?? "—").foregroundStyle(.secondary) }
                .width(min: 46, ideal: 54, max: 80).customizationID("eta")
            TableColumn("Status", value: \.sortStatus) { row in DownloadStatusCell(row: row) }
                .width(min: 140, ideal: 180, max: 280).customizationID("status")
            TableColumn("Priority", value: \.sortPriority) { row in Text(row.priority.title).foregroundStyle(.secondary) }
                .width(min: 56, ideal: 70, max: 90).customizationID("priority").defaultVisibility(.hidden)
            TableColumn("Date", value: \.date) { row in Text(row.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 90, ideal: 130).customizationID("date").defaultVisibility(.hidden)
            TableColumn("Source") { row in Text(row.host).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                .width(min: 80, ideal: 130).customizationID("host").defaultVisibility(.hidden)
            TableColumn("Protocol") { row in Text(row.protocolLabel).foregroundStyle(.secondary) }
                .width(min: 56, ideal: 70, max: 90).customizationID("protocol").defaultVisibility(.hidden)
        } rows: {
            // A finished download can be dragged out of the list to Finder, a mail message or another app. The provider carries the real file (the row's own file, found the same
            // way Reveal in Finder finds it); a row that is not finished, or whose file is gone or outside the managed folders, offers nothing.
            ForEach(vm.visible) { row in
                TableRow(row).itemProvider { dragProvider(for: row) }
            }
        }
        .font(.system(size: 12.5))
        // The table's striped rows drew an empty rounded stripe under the last download; without the stripes there is nothing below the last row.
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: UUID.self) { ids in DownloadContextMenu(vm: vm, ids: ids, tell: { model.notice = $0 }) } primaryAction: { ids in primary(ids) }
        .onDeleteCommand { vm.perform(.removeRecord) }
        .accessibilityLabel("Downloads")
        .accessibilityIdentifier("downloads-table")
    }

    @ViewBuilder private var emptyState: some View {
        if vm.visible.isEmpty {
            let filtering = !vm.query.search.isEmpty || vm.query.filter != .all || vm.query.priority != nil || vm.query.protocolLabel != nil
            VStack(spacing: 6) {
                Image(systemName: filtering ? "magnifyingglass" : "arrow.down.circle").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                Text(filtering ? "Nothing matches" : "No downloads").font(.system(size: 14, weight: .medium))
                Text(filtering ? "Try another search or filter." : "Files you download appear here, with progress while they come in.").font(.system(size: 12)).foregroundStyle(.secondary)
                if filtering { Button("Clear Filters") { vm.query.search = ""; vm.query.filter = .all; vm.query.priority = nil; vm.query.protocolLabel = nil }.buttonStyle(.link).font(.system(size: 12)) }
            }
            .multilineTextAlignment(.center).padding(24).allowsHitTesting(filtering)
            .accessibilityElement(children: .combine)
        }
    }

    private func primary(_ ids: Set<UUID>) {
        let completed = ids.compactMap { vm.row($0) }.filter { $0.actions.contains(.open) }
        if completed.isEmpty { animated(.easeOut(duration: 0.18)) { vm.inspectorShown = true } } else { completed.forEach { if let url = vm.fileURL(for: $0.id) { DownloadOpening.open(url) } } }
    }

    private func applySort(_ order: [KeyPathComparator<DownloadRow>]) {
        guard let first = order.first else { return }
        let ascending = first.order == .forward
        switch first.keyPath {
        case \DownloadRow.filename: vm.query.sort = .name
        case \DownloadRow.sortSize: vm.query.sort = .size
        case \DownloadRow.sortProgress: vm.query.sort = .progress
        case \DownloadRow.sortStatus: vm.query.sort = .status
        case \DownloadRow.sortPriority: vm.query.sort = .priority
        default: vm.query.sort = .date
        }
        vm.query.ascending = ascending
    }

    static func comparators(for query: DownloadQuery) -> [KeyPathComparator<DownloadRow>] {
        let order: SortOrder = query.ascending ? .forward : .reverse
        switch query.sort {
        case .name: return [KeyPathComparator(\.filename, order: order)]
        case .size: return [KeyPathComparator(\.sortSize, order: order)]
        case .progress: return [KeyPathComparator(\.sortProgress, order: order)]
        case .status: return [KeyPathComparator(\.sortStatus, order: order)]
        case .priority: return [KeyPathComparator(\.sortPriority, order: order)]
        case .date: return [KeyPathComparator(\.date, order: order)]
        }
    }
}

// MARK: - Filter bar

struct DownloadFilterBar: View {
    @ObservedObject var vm: DownloadsViewModel

    var body: some View {
        PanelChips(choices: DownloadFilter.allCases, selection: $vm.query.filter, title: { $0.title }, count: { vm.counts[$0] ?? 0 })
            .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

// MARK: - Cells

struct DownloadFileIcon: View {
    let row: DownloadRow
    var body: some View {
        let symbol = row.status == .failed ? "exclamationmark.triangle" : DownloadsPanel.Kind.of(row.filename).symbol
        Image(systemName: symbol).font(.system(size: 13, weight: .medium))
            .foregroundStyle(row.status == .failed ? Color.orange : Theme.accent)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill((row.status == .failed ? Color.orange : Theme.accent).opacity(0.13)))
            
    }
}

struct DownloadNameCell: View {
    let row: DownloadRow
    /// In the dashboard table: speed and time left have their own columns, so a downloading row says only how much has arrived (the whole line is the hover text).
    var inTable = false

    /// The second line as shown.
    var shownDetail: String {
        DownloadNameCell.detail(for: row.detail, downloading: row.status == .downloading, inTable: inTable)
    }

    static func detail(for detail: String, downloading: Bool, inTable: Bool) -> String {
        guard inTable, downloading, let first = detail.components(separatedBy: " · ").first, !first.isEmpty else { return detail }
        return first
    }

    var body: some View {
        HStack(spacing: 9) {
            DownloadFileIcon(row: row)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.filename).lineLimit(1).truncationMode(.middle)
                if !row.detail.isEmpty { Text(shownDetail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(row.detail) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilitySummary)
    }
}

struct DownloadProgressCell: View {
    let row: DownloadRow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch row.status {
            case .downloading, .verifying, .paused, .retrying:
                HStack(spacing: 6) {
                    if let fraction = row.fraction {
                        ProgressView(value: fraction).tint(row.status == .paused ? Color.secondary : Theme.accent)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
                        Text(DownloadFormat.percent(fraction) ?? "").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                    } else if row.status == .downloading {
                        ProgressView().progressViewStyle(.linear).accessibilityLabel("Progress unknown")
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            case .completed: Text("100%").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            default: Text("—").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(DownloadFormat.percent(row.fraction) ?? "unknown")
    }
}

struct DownloadStatusCell: View {
    let row: DownloadRow
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: Self.symbol(row.status)).font(.system(size: 11)).foregroundStyle(Self.tint(row.status))
            // The row is two lines tall (the name cell has its second line), so a long status ("Trying again (attempt 12)", "Waiting · #123 in line") wraps onto it instead of being cut off.
            Text(row.statusText).lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
        .help(row.problem ?? row.statusText)
    }

    static func symbol(_ s: DownloadRowStatus) -> String {
        switch s {
        case .downloading: "arrow.down.circle.fill"; case .verifying: "checkmark.shield"; case .queued: "list.number"; case .retrying: "arrow.clockwise"
        case .scheduled: "clock"; case .paused: "pause.circle.fill"; case .completed: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle.fill"
        case .recoveryRequired: "arrow.triangle.2.circlepath"; case .cancelled: "xmark.circle"
        }
    }

    static func tint(_ s: DownloadRowStatus) -> Color {
        switch s {
        case .downloading, .verifying: Theme.accent
        case .completed: .green
        case .failed: .orange
        case .recoveryRequired, .retrying: .yellow
        default: .secondary
        }
    }
}

// MARK: - Context menu

/// One menu for the right-clicked row or the whole selection. An entry appears only when at least one of those rows can take it, and says how many it will affect.
struct DownloadContextMenu: View {
    @ObservedObject var vm: DownloadsViewModel
    let ids: Set<UUID>
    var tell: (String) -> Void = { _ in }

    var body: some View {
        let rows = ids.compactMap { vm.row($0) }
        let allowed = DownloadBatch.allowed(in: rows, selection: ids)
        if rows.isEmpty { EmptyView() } else {
            if allowed.contains(.open) { Button("Open") { open(ids) } }
            if allowed.contains(.reveal) { Button("Show in Finder") { reveal(ids) } }
            if allowed.contains(.openFolder) { Button("Open Folder") { DownloadFileUI.openFolder(vm, ids) } }
            if allowed.contains(.copyPath) { Button(label("Copy Path", .copyPath)) { DownloadFileUI.copyPath(vm, ids) } }
            if allowed.contains(.pause) { Button(label("Pause", .pause)) { vm.perform(.pause, on: ids) } }
            if allowed.contains(.resume) { Button(label(resumeWord(rows), .resume)) { vm.perform(.resume, on: ids) } }
            if allowed.contains(.retry) { Button(label("Try Again", .retry)) { vm.perform(.retry, on: ids) } }
            if allowed.contains(.startNow) { Button(label("Start Now", .startNow)) { vm.perform(.startNow, on: ids) } }
            if allowed.contains(.setPriority) {
                Menu(label("Priority", .setPriority)) {
                    ForEach(DownloadPriority.allCases.reversed()) { p in Button(p.title) { vm.perform(.setPriority, on: ids, priority: p) } }
                }
            }
            if allowed.contains(.rename), rows.count == 1, let only = ids.first { Divider(); Button("Rename…") { DownloadFileUI.rename(vm, only) } }
            if allowed.contains(.move) { Button(label("Move to…", .move)) { DownloadFileUI.move(vm, ids) } }
            if allowed.contains(.verify) { Button(label("Calculate SHA-256", .verify)) { vm.verify(ids) } }
            if allowed.contains(.extract), rows.count == 1, let only = ids.first { Button("Open Archive") { vm.extract(only) } }
            if allowed.contains(.cancel) {
                Divider()
                Button(label("Cancel Download", .cancel)) { vm.perform(.cancel, on: ids) }
                Button(label("Cancel and Remove from List", .cancel)) { vm.cancelAndRemove(on: ids) }
            }
            if allowed.contains(.removeRecord) || allowed.contains(.trashFile) {
                Divider()
                if allowed.contains(.removeRecord) { Button(label("Remove from List", .removeRecord)) { vm.perform(.removeRecord, on: ids) } }
                if allowed.contains(.trashFile) { Button(label("Move File to Trash…", .trashFile), role: .destructive) { vm.requestTrash(on: ids) } }
            }
        }
    }

    private func resumeWord(_ rows: [DownloadRow]) -> String {
        let titles = Set(rows.filter { $0.actions.contains(.resume) }.map(\.resumeTitle))
        return titles.count == 1 ? titles.first! : "Resume"
    }

    private func label(_ title: String, _ action: DownloadRowActions) -> String {
        let n = vm.count(for: action, on: ids)
        return n > 1 ? "\(title) (\(n))" : title
    }

    private func open(_ ids: Set<UUID>) { ids.compactMap { vm.fileURL(for: $0) }.forEach { DownloadOpening.open($0) } }
    private func reveal(_ ids: Set<UUID>) {
        let found = ids.compactMap { vm.fileURL(for: $0) }
        if found.isEmpty { tell( ids.count == 1 ? "That file is no longer where it was saved. It may have been moved, renamed or deleted." : "Those files are no longer where they were saved.") }
        else { NSWorkspace.shared.activateFileViewerSelecting(found); if found.count < ids.count { tell("\(ids.count - found.count) of the files could not be shown: they are no longer where they were saved.") } }
    }
}

// MARK: - Add download

struct AddDownloadForm: View {
    @EnvironmentObject private var model: BrowserModel
    let coordinator: DownloadCoordinator
    var extensions: DownloadExtensionManager?
    var initialText: String? = nil
    var initialTorrentFile: URL? = nil
    var preferences = MediaPreferences()
    /// Where `initialText` came from (see BrowserModel.addDownloadPrefillOrigin). Changing the text makes it the person's own.
    var initialOrigin: DownloadRequestOrigin = .user
    var done: () -> Void
    @State private var text = ""
    @State private var name = ""
    @State private var checksum = ""
    @State private var torrent: TorrentAddModel?
    @State private var ed2k: ED2KAddModel?
    @State private var media: MediaAddModel?
    @State private var torrentProblem: String?
    /// Asking the server what an unfamiliar address is (cancellable), and the person's choice when it turns out to be a web page.
    @State private var probing: Task<Void, Never>?
    @State private var pageChoice: PageChoice?
    /// An address that turned out to be a web page, with what the person had typed when they asked (so editing the fields meanwhile cannot change what is saved).
    struct PageChoice: Equatable { var url: URL; var name: String; var checksum: String; var origin: DownloadRequestOrigin }

    /// What the installed download extensions suggest for the address typed in. Information only: nothing here starts a download.
    @ViewBuilder private var suggestionsView: some View {
        if let url, let extensions {
            let proposals = extensions.propose(for: url)
            if !proposals.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(proposals) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Suggested by \(p.provenance.extensionName)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            if let f = p.filename { HStack { Text("Name: \(f)").font(.system(size: 11.5)).lineLimit(1); Spacer(); Button("Use Name") { name = f }.controlSize(.small) } }
                            if let c = p.category { Text("Kind: \(c.rawValue)").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                            ForEach(p.resources.prefix(5), id: \.url) { r in
                                HStack {
                                    Text(r.title ?? r.filename ?? r.url.host ?? "").font(.system(size: 11.5)).lineLimit(1)
                                    Text(r.url.host ?? "").font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                                    Spacer()
                                    Button("Copy Address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.url.absoluteString, forType: .string) }.controlSize(.small)
                                }
                            }
                        }
                    }
                    Text("The app does not start a download from an extension's address by itself: its safety rule only accepts addresses that came from you. Copy the address and paste it above if you trust it.").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8).frame(width: 300, alignment: .leading).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var isED2K: Bool { text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("ed2k:") }
    private var ed2kProblem: String? { isED2K ? ({ do { guard case .file = try ED2KLink.parse(text) else { return "Only links to files can be downloaded." }; return nil } catch { return (error as? LocalizedError)?.errorDescription } })() : nil }
    private var isMagnet: Bool { text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("magnet:") }
    private var magnet: MagnetLink? { isMagnet ? try? MagnetLink.parse(text) : nil }
    private var magnetProblem: String? { isMagnet ? MagnetLink.problem(text) : nil }

    /// An address that ends in .m3u8 or .mpd is a stream playlist: it gets the track choices before anything is downloaded.
    private var origin: DownloadRequestOrigin { text.trimmingCharacters(in: .whitespacesAndNewlines) == (initialText ?? "").trimmingCharacters(in: .whitespacesAndNewlines) && !text.isEmpty ? initialOrigin : .user }
    /// A video provider's watch page, reel or short: not a file. Saving it as a file would store the page's HTML, so it goes to the video options instead.
    private var isVideoPage: Bool {
        url.map(ProviderRecognizer.isVideoPage) ?? false
    }
    private var isStream: Bool { url.map { ["m3u8", "mpd"].contains($0.pathExtension.lowercased()) } ?? false }

    private var checksumOK: Bool { checksum.trimmingCharacters(in: .whitespaces).isEmpty || DownloadIntegrityCheck.normalizedDigest(checksum) != nil }

    private var url: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), DownloadSchedule.canSchedule(url) else { return nil }
        return url
    }

    var body: some View {
        Group { if let media { MediaAddView(model: media, done: done) } else if let ed2k { ED2KAddView(model: ed2k, done: done) } else if let torrent { TorrentAddView(model: torrent, done: done) } else { form } }
            .onAppear {
                if text.isEmpty, let t = initialText { text = t }
                if torrent == nil, let f = initialTorrentFile { loadTorrent(f) }
            }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a download").font(.system(size: 13, weight: .semibold))
            TextField("https://example.com/file.zip or a magnet link", text: $text).textFieldStyle(.roundedBorder).frame(width: 300).onSubmit(start)
            Text(isED2K ? (ed2kProblem ?? "An eD2k link: you will see what it holds before anything is contacted.") : isMagnet ? (magnetProblem ?? "A magnet link: you will see what it holds before anything is fetched.") : (text.isEmpty || url != nil ? (isVideoPage ? "A video page: Next shows what can be saved." : "Paste a direct link to a file.") : "That does not look like a web link.")).font(.system(size: 11.5)).foregroundStyle((isED2K ? ed2kProblem : magnetProblem) == nil ? Color.secondary : Color.orange)
            suggestionsView
            if probing != nil { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking at the address…").font(.system(size: 11.5)).foregroundStyle(.secondary); Button("Stop") { probing?.cancel(); probing = nil }.controlSize(.small) } }
            if let choice = pageChoice { pageChoiceView(choice) }
            if let torrentProblem { Text(torrentProblem).font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            TextField("Save as (optional)", text: $name).textFieldStyle(.roundedBorder).frame(width: 300).accessibilityLabel("Save as")
            TextField("SHA-256 from the publisher (optional)", text: $checksum).textFieldStyle(.roundedBorder).frame(width: 300).accessibilityLabel("Expected SHA-256")
            if !checksumOK { Text("That is not a SHA-256 (64 hexadecimal characters).").font(.system(size: 11.5)).foregroundStyle(.orange) }
            HStack {
                Button("Open .torrent File…", action: openTorrentFile)
                Button("Open Metalink…", action: openMetalink)
                Spacer()
                if isVideoPage, let url { Button("Save Page as File") { saveAsFile(url) }.disabled(!checksumOK).help("Save the web page itself, not the video") }
                Button("Cancel") { probing?.cancel(); done() }
                Button(isMagnet || isED2K || isStream || isVideoPage ? "Next…" : "Download", action: start).buttonStyle(.borderedProminent).disabled(isED2K ? (ed2kProblem != nil || !checksumOK) : isMagnet ? magnet == nil : (url == nil || !checksumOK || probing != nil)).keyboardShortcut(.defaultAction)
            }
        }.padding(14).onDisappear { probing?.cancel() }
    }

    /// A Metalink file lists one file and several places it can be had. It is a stranger's document: its addresses are treated as coming from a page, and nothing starts until its time comes.
    private func openMetalink() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["meta4", "metalink"].compactMap { .init(filenameExtension: $0) } + [.xml]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.prompt = "Open"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        guard (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max <= MetalinkParser.maxBytes, let data = try? Data(contentsOf: file) else { torrentProblem = "That Metalink file is too large."; return }
        // The same question and the same import as a link or a typed address: one file, or a collection of several.
        model.openMetalink(data: data, title: file.deletingPathExtension().lastPathComponent)
    }

    private func openTorrentFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "torrent") ?? .data]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.prompt = "Open"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        loadTorrent(file)
    }

    /// Opens a .torrent file in the existing torrent preview. Nothing is contacted by looking at it.
    private func loadTorrent(_ file: URL) {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        guard (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max <= TorrentMetainfo.Limit.maxInfoBytes + 1_048_576, let data = try? Data(contentsOf: file) else { torrentProblem = "That file is too large to be a torrent."; return }
        do { torrent = try TorrentAddModel(coordinator: coordinator, torrentData: data); torrentProblem = nil }
        catch { torrentProblem = (error as? LocalizedError)?.errorDescription ?? "That is not a torrent file." }
    }

    private func start() {
        guard probing == nil else { return }          // a second Return while the address is being looked at must not start a second download
        if isED2K { do { ed2k = try ED2KAddModel(coordinator: coordinator, link: text, sha256: checksum.trimmingCharacters(in: .whitespaces).isEmpty ? nil : checksum) } catch { torrentProblem = (error as? LocalizedError)?.errorDescription }; return }
        if let magnet { torrent = TorrentAddModel(coordinator: coordinator, magnet: magnet, origin: origin); return }
        guard let url else { return }
        let typed = name.trimmingCharacters(in: .whitespaces)
        if isVideoPage { model.openVideoSheet(forPage: url, isPrivate: false); done(); return }
        if isStream { media = MediaAddModel(coordinator: coordinator, url: url, name: typed.isEmpty ? nil : typed, preferences: preferences, origin: origin); return }
        // An address that may be a web page is asked about first: what the server says it is decides, not the way the address ends. If it cannot be asked, it is saved as it always was.
        if AddressClassifier.worthProbing(url) {
            pageChoice = nil
            // Everything the answer will need is captured NOW: editing the fields while the server is asked cannot change the origin, name or checksum that are used.
            let choice = PageChoice(url: url, name: typed, checksum: checksum.trimmingCharacters(in: .whitespaces), origin: origin)
            probing = Task {
                let answer = await model.probeAddress(url, origin: choice.origin)
                guard !Task.isCancelled else { return }
                probing = nil
                switch AddressClassifier.classify(url, contentType: answer?.contentType, finalURL: answer?.finalURL) {
                case .videoPage: model.openVideoSheet(forPage: answer?.finalURL ?? url, isPrivate: false); done()
                case .webPage: pageChoice = choice
                case .file: saveAsFile(choice)
                }
            }
            return
        }
        saveAsFile(PageChoice(url: url, name: typed, checksum: checksum.trimmingCharacters(in: .whitespaces), origin: origin))
    }

    private func saveAsFile(_ url: URL) { saveAsFile(PageChoice(url: url, name: name.trimmingCharacters(in: .whitespaces), checksum: checksum.trimmingCharacters(in: .whitespaces), origin: origin)) }

    /// The plain download of the address, as typed: also what "Save the Page" does when the person means the page itself.
    private func saveAsFile(_ c: PageChoice) {
        coordinator.scheduleDownload(url: c.url, at: Date(), filename: c.name.isEmpty ? nil : c.name, expectedSHA256: c.checksum.isEmpty ? nil : c.checksum, origin: c.origin)
        done()
    }

    @ViewBuilder private func pageChoiceView(_ choice: PageChoice) -> some View {
        let checksumFine = choice.checksum.isEmpty || DownloadIntegrityCheck.normalizedDigest(choice.checksum) != nil
        VStack(alignment: .leading, spacing: 6) {
            Text("This address is a web page. Look for a video on it, or save the page itself?").font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Look for a Video") { pageChoice = nil; model.openVideoSheet(forPage: choice.url, isPrivate: false); done() }.controlSize(.small)
                Button("Save the Page") { pageChoice = nil; saveAsFile(choice) }.controlSize(.small).disabled(!checksumFine)
                Button("Not Now") { pageChoice = nil }.controlSize(.small)
            }
        }
    }
}


// MARK: - Panels and the pasteboard

/// The parts of a file operation that need the window system: asking for a name or a folder, copying to the pasteboard, opening a folder. Everything else is the view model's.
@MainActor
enum DownloadFileUI {
    static func rename(_ vm: DownloadsViewModel, _ id: UUID) {
        guard let row = vm.row(id) else { return }
        Task { @MainActor in
            guard let text = await Dialogs.promptText(title: "Rename “\(row.filename)”", message: "Type the new name. The ending is kept if you leave it out.", placeholder: row.filename), !text.isEmpty else { return }
            vm.rename(id, to: text)
        }
    }

    static func move(_ vm: DownloadsViewModel, _ ids: Set<UUID>) {
        let targets = DownloadBatch.eligible(.move, in: vm.rows, selection: ids)
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = targets.count == 1 ? "Choose where to move “\(targets[0].filename)”." : "Choose where to move \(targets.count) files."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        for row in targets { vm.move(row.id, toFolder: folder) }
    }

    static func copyPath(_ vm: DownloadsViewModel, _ ids: Set<UUID>) {
        let paths = DownloadBatch.eligible(.copyPath, in: vm.rows, selection: ids).compactMap { vm.fileURL(for: $0.id)?.path }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        vm.message = paths.count == 1 ? "Path copied." : "\(paths.count) paths copied."
    }

    static func openFolder(_ vm: DownloadsViewModel, _ ids: Set<UUID>) {
        let folders = Set(DownloadBatch.eligible(.openFolder, in: vm.rows, selection: ids).compactMap { vm.fileURL(for: $0.id)?.deletingLastPathComponent() })
        for folder in folders { NSWorkspace.shared.open(folder) }
    }
}

/// Opening a finished download from the Downloads window: if it is a document that is really a program, the person is asked first. Nothing else is changed.
enum DownloadOpening {
    @MainActor static func open(_ url: URL) {
        guard let warning = DownloadScanner.warning(forFileAt: url) else { NSWorkspace.shared.open(url); return }
        Task { @MainActor in
            let answer = await Dialogs.choose(title: "Open “\(url.lastPathComponent)”?", message: warning, buttons: ["Cancel", "Open Anyway"])
            if answer == 1 { NSWorkspace.shared.open(url) }
        }
    }
}


/// The icon-and-chevron of a menu in the Downloads header. The name is on the icon itself and the chevron is hidden from VoiceOver: as a button-style menu the control then announces its name and
/// offers the menu-opening action, which the borderless pop-up style did not (it announced the symbol's description and offered only "press").
private struct HeaderMenuLabel: View {
    let symbol: String
    let name: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).accessibilityLabel(name)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
        }
        .padding(.horizontal, 3.5).contentShape(Rectangle())
    }
}

private extension View {
    func headerMenuStyle() -> some View {
        menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).foregroundStyle(.tint).fixedSize()
    }
}
