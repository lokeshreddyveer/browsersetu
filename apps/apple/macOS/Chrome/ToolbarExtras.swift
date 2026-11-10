import SwiftUI

/// The toolbar buttons that were only to be found in the sidebar or the menu bar: workspaces, profile, split view, history, bookmarks, find and the command palette.
/// Which of them show is up to the person (Settings › Appearance › Toolbar); they appear in the Classic, Minimal and One Row layouts.
struct ToolbarExtras: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if model.shows(.workspaces) { WorkspaceToolbarMenu() }
        if model.shows(.profile) { ProfileToolbarMenu() }
        if model.shows(.splitView) { SplitToolbarMenu() }
        if model.shows(.history) { ChromeButton(symbol: "clock", help: "History", identifier: "history-button") { model.sheet = .history } }
        if model.shows(.library) { ChromeButton(symbol: "book", help: "Bookmarks", identifier: "library-button") { model.sheet = .bookmarks } }
        if model.shows(.find), model.active?.isBlank == false { ChromeButton(symbol: "magnifyingglass", help: "Find in Page", identifier: "find-button") { model.showFind() } }
        if model.shows(.palette) { ChromeButton(symbol: "command", help: "Command Palette", identifier: "palette-button") { model.paletteVisible.toggle() } }
    }
}

/// A toolbar menu button that looks like the others.
private struct ToolbarMenuButton<Content: View>: View {
    let symbol: String
    let help: String
    var tint: Color?
    let identifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular)).foregroundStyle(tint ?? .primary)
                .frame(width: 28, height: 28).contentShape(Rectangle()).accessibilityLabel(help)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(ChromeButtonStyle()).fixedSize()
        .help(help).accessibilityLabel(help).accessibilityIdentifier(identifier)
    }
}

struct WorkspaceToolbarMenu: View {
    @EnvironmentObject var model: BrowserModel
    private var icon: String { model.workspaces.first { $0.name == model.activeWorkspace }?.icon ?? "person" }

    var body: some View {
        ToolbarMenuButton(symbol: icon, help: "Workspace: \(model.activeWorkspace.isEmpty ? "Personal" : model.activeWorkspace)", tint: model.activeWorkspace.isEmpty ? nil : Theme.accent, identifier: "workspace-button") {
            Button { model.switchWorkspace("") } label: { Label("Personal", systemImage: model.activeWorkspace.isEmpty ? "checkmark" : "person") }
            ForEach(model.workspaces) { workspace in
                Button { model.switchWorkspace(workspace.name) } label: {
                    Label(workspace.name, systemImage: workspace.name == model.activeWorkspace ? "checkmark" : workspace.icon)
                }
            }
            Divider()
            Button("New Workspace…") { promptNewWorkspace(model: model) }
            Button("Manage Workspaces…") { SettingsRouter.open(.tabs) }
        }
    }
}

struct ProfileToolbarMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ToolbarMenuButton(symbol: model.profileStyle(model.profileName).symbol, help: "Profile: \(model.profileName)", identifier: "profile-button") {
            ForEach(model.profiles, id: \.self) { name in
                Button { model.switchProfile(name) } label: { Label(name, systemImage: name == model.profileName ? "checkmark" : model.profileStyle(name).symbol) }
            }
            Divider()
            if let url = model.active?.url, !(model.active?.isBlank ?? true), !(model.active?.isPrivate ?? false) {
                Menu("Open This Page in Profile") {
                    ForEach(model.profiles.filter { $0 != model.profileName }, id: \.self) { name in
                        Button(name) { model.openInProfile(url, profile: name) }
                    }
                }
                Menu("Always Open \(url.host ?? "This Site") in") {
                    ForEach(model.profiles, id: \.self) { name in Button(name) { model.assignSite(host: url.host, to: name) } }
                    Divider()
                    Button("No Profile") { model.assignSite(host: url.host, to: nil) }
                }
            }
            Button("Start a Temporary Profile") { model.startTemporaryProfile() }
            Button("Manage Profiles…") { SettingsRouter.open(.profiles) }
        }
    }
}

/// Everything about the split view, in one place: put another tab beside this one, a third panel, direction, swap, close.
struct SplitToolbarMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ToolbarMenuButton(symbol: model.splitTabID == nil ? "rectangle.split.2x1" : "rectangle.split.2x1.fill", help: "Split View", tint: model.splitTabID == nil ? nil : Theme.accent, identifier: "split-button") {
            SplitViewMenuItems()
        }
    }
}

/// The split-view commands, shared by the toolbar button, the More menu and the menu bar.
struct SplitViewMenuItems: View {
    @EnvironmentObject var model: BrowserModel

    private var others: [TabController] {
        model.visibleTabs.filter { $0.id != model.activeID && $0.id != model.splitTabID && $0.id != model.thirdSplitTabID && $0.id != model.fourthSplitTabID && !$0.isBlank && $0.isPrivate == model.activeIsPrivate }
    }

    var body: some View {
        Menu("Show Another Tab Beside This One") {
            if others.isEmpty { Text("No other tab is open") }
            ForEach(others.prefix(20)) { tab in
                Button(tab.displayTitle) { model.splitTabID == nil ? model.openSplit(with: tab) : model.addThirdPanel(with: tab) }
            }
        }
        Button("New Tab Beside This One") { model.splitTabID == nil ? model.openSplitNewTab() : model.addThirdPanelNewTab() }
            .disabled(model.fourthSplitTabID != nil)
        if model.splitTabID != nil {
            Divider()
            if model.thirdSplitTab != nil { Button("Remove the Last Panel") { model.removeThirdPanel() } }
            Button(model.splitOrientation == .sideBySide ? "Stack the Panels" : "Put the Panels Side by Side") {
                model.splitOrientation = model.splitOrientation == .sideBySide ? .stacked : .sideBySide
            }
            Button("Swap Panels") { model.swapSplit() }
            Button("Close Split View") { model.closeSplit() }
        }
    }
}

/// One small indicator per kind of download the page in front offers, each with its count. Video and audio keep the existing media picker; every other kind opens a list. Nothing shows
/// on a page that offers nothing, and a kind can be turned off in Settings. The video indicator keeps the identifier `media-button`.
struct MediaToolbarButton: View {
    @EnvironmentObject var model: BrowserModel
    @AppStorage(ResourceDetectionSettings.hiddenKey) private var hiddenRaw = ""
    @AppStorage(ResourceDetectionSettings.enabledKey) private var detectOn = true

    var body: some View {
        let r = model.resourceSummary
        let hidden = ResourceDetectionSettings.parse(hiddenRaw)
        let shown = detectOn ? r.categories.filter { !hidden.contains($0) } : []
        Group {
            if !shown.isEmpty {
                // Narrow toolbars fold the kinds into one chip with the total; roomy ones show each.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 2) { ForEach(shown) { CategoryChip(category: $0, summary: r) } }
                    CategoryChip(category: nil, summary: r, all: shown)
                }
                .transition(.opacity)
            }
        }
        .motion(.easeOut(duration: 0.18), value: r)
        // One popover for the whole indicator, attached here where the view's identity does not change when chips come and go (a popover attached to a chip is dismissed when the toolbar
        // swaps the chip row for the compact chip or the chip set changes). Which list it shows is the model's `resourcePopoverKey`; its contents follow the live summary.
        .popover(isPresented: Binding(get: { model.resourcePopoverKey != nil && !shown.isEmpty }, set: { if !$0 { model.resourcePopoverKey = nil } }), arrowEdge: .bottom) {
            ResourcePopover(categories: popoverCategories(shown: shown), summary: r, close: { model.resourcePopoverKey = nil })
        }
        .onChange(of: detectOn) { _, _ in model.scheduleResourceScan() }
        .task(id: model.active?.id) { model.scheduleMediaSummary(); model.scheduleResourceScan() }
    }

    private func popoverCategories(shown: [ResourceCategory]) -> [ResourceCategory] {
        guard let key = model.resourcePopoverKey else { return [] }
        if key == "all" { return shown }
        return ResourceCategory(rawValue: key).map { shown.contains($0) ? [$0] : [] } ?? []
    }
}

private struct CategoryChip: View {
    @EnvironmentObject var model: BrowserModel
    let category: ResourceCategory?
    let summary: PageResourceSummary
    var all: [ResourceCategory] = []
    /// Held by the model, not the chip: the list of chips changes while the page loads more, and an open list must stay open.
    private var key: String { category?.rawValue ?? "all" }

    private var cats: [ResourceCategory] { category.map { [$0] } ?? all }
    private var total: Int { cats.reduce(0) { $0 + summary.detected($1) } }
    private var usable: Int { cats.reduce(0) { $0 + summary.openable($1) } }
    private var symbol: String { category?.symbol ?? "arrow.down.doc" }
    private var title: String { category?.title ?? "Downloads on this page" }
    private var identifier: String { category == .video ? "media-button" : "category-\(category?.rawValue ?? "all")" }

    var body: some View {
        Button {
            model.resourcePopoverKey = (model.resourcePopoverKey == key) ? nil : key
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol).foregroundStyle(usable > 0 ? Theme.accent : Color.secondary)
                Text("\(total)").font(.system(size: 8, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 3).background(Capsule().fill(usable > 0 ? Theme.accent : Color.secondary.opacity(0.6))).foregroundStyle(.white)
                    .offset(x: 6, y: -5)
            }
            .padding(.trailing, 4)
        }
        .buttonStyle(ChromeButtonStyle())
        .help("\(title): \(total) found")
        .accessibilityLabel("\(title): \(total) found")
        .accessibilityIdentifier(identifier)
    }
}

/// The list behind an indicator: what the page offers in that kind, with what is known about each. Nothing here is fetched or downloaded until a button is pressed.
struct ResourcePopover: View {
    @EnvironmentObject var model: BrowserModel
    let categories: [ResourceCategory]
    let summary: PageResourceSummary
    let close: () -> Void
    @State private var picked: Set<String> = []

    private var items: [DetectedResource] { categories.flatMap { summary.items[$0] ?? [] } }
    private var files: [DetectedResource] { items.filter { !$0.needsResolution } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(categories.count == 1 ? categories[0].title : "On this page").font(.headline)
            if categories.contains(where: \.usesMediaPicker), categories.contains { summary.mediaDetected[$0, default: 0] > 0 } {
                Button("Open the media picker (\(categories.reduce(0) { $0 + summary.mediaDetected[$1, default: 0] }) from players)") { close(); model.discoverMediaOnCurrentPage() }
                    .accessibilityIdentifier("category-open-picker")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(items.prefix(200)) { r in row(r) }
                }
            }.frame(maxHeight: 280)
            if summary.truncated || items.count > 200 { Text("Showing the first part of a long list; Download all starts at most \(BrowserModel.bulkLimit) at a time.").font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack {
                Button("Download \(picked.isEmpty ? "all" : "selected")") {
                    let chosen = model.downloadableAll(items, among: picked.intersection(Set(items.map(\.id))))
                    chosen.forEach { model.downloadDetected($0) }
                    close()
                }
                .disabled(files.isEmpty).accessibilityIdentifier("category-download-selected")
                Button("Look Again") { model.scheduleResourceScan(now: true) }
                    .help("Read the page's links again, for items it has loaded since. Nothing is scrolled, played or fetched.").accessibilityIdentifier("category-look-again")
                Spacer()
                Button("Collect These Links") {
                    _ = model.collectResources(items); close()
                }.accessibilityIdentifier("category-collect")
            }
        }
        .padding(12).frame(width: 360)
    }

    @ViewBuilder private func row(_ r: DetectedResource) -> some View {
        HStack(spacing: 8) {
            if !r.needsResolution { Toggle("", isOn: Binding(get: { picked.contains(r.id) }, set: { if $0 { picked.insert(r.id) } else { picked.remove(r.id) } })).labelsHidden() }
            VStack(alignment: .leading, spacing: 1) {
                Text(r.filename.isEmpty ? (r.host ?? "File") : r.filename).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(statusText(r)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if r.needsResolution {
                Button("Download") { close(); model.openVideoSheet(for: r) }.controlSize(.small).help("See what can be saved from this video").accessibilityIdentifier("resource-analyze-\(r.filename)")
            } else {
                Button("Download") { close(); r.category.usesMediaPicker ? model.openVideoSheet(for: r) : model.downloadDetected(r) }.controlSize(.small).accessibilityIdentifier("resource-download-\(r.filename)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("resource-row")
    }

    private func statusText(_ r: DetectedResource) -> String {
        if case .notAFile(let why) = r.availability { return why }
        if let p = r.provider { return "\(p.displayName) · not resolved yet" }
        if r.isManifest { return "Stream playlist · qualities are read first" }
        return [r.ext.isEmpty ? nil : r.ext.uppercased(), r.sizeText, r.host, r.confidence == .low ? "uncertain" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The Downloads button, with a ring that fills while something downloads, so the button itself shows that a download is under way.
struct DownloadsToolbarButton: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var coordinator: DownloadCoordinator
    /// True for a moment after the last download finished: the button shows a check mark, then goes back to its usual look.
    @State private var justFinished = false
    @State private var finishedTask: Task<Void, Never>?
    @State private var showsPopover = false

    var body: some View {
        let items = Array(coordinator.active.values)
        let average = items.isEmpty ? 0 : items.map(\.fraction).reduce(0, +) / Double(items.count)
        let showsCheck = items.isEmpty && justFinished
        // A click opens the small list; "Open Downloads" in it opens the whole window.
        Button { showsPopover.toggle() } label: {
            ZStack {
                if !items.isEmpty {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.04, average)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                Image(systemName: showsCheck ? "checkmark.circle.fill" : (items.isEmpty ? "arrow.down.circle" : "arrow.down"))
                    .foregroundStyle(items.isEmpty && !showsCheck ? Color.primary : Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: items.isEmpty ? nil : 20, height: items.isEmpty ? nil : 20)
        }
        .buttonStyle(ChromeButtonStyle())
        .marksDownloadsButton()
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            DownloadsPopover(vm: model.downloadList) { showsPopover = false; model.sheet = .downloads }
        }
        .help(items.isEmpty ? (showsCheck ? "Download finished" : "Downloads") : "Downloading… \(Int((average * 100).rounded()))%")
        .accessibilityLabel(items.isEmpty ? (showsCheck ? "Downloads, finished" : "Downloads") : "Downloads, \(Int((average * 100).rounded())) percent")
        .accessibilityIdentifier("downloads-button")
        .motion(.easeOut(duration: 0.2), value: items.isEmpty)
        .motion(.easeOut(duration: 0.2), value: showsCheck)
        .onChange(of: coordinator.completed.count) { old, new in
            guard new > old else { return }
            justFinished = true
            finishedTask?.cancel()
            finishedTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.2))
                if !Task.isCancelled { justFinished = false }
            }
        }
    }
}
