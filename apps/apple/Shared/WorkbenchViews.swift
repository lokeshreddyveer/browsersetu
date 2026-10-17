import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One window for the power tools. Each part reads or changes something real; nothing here is a preview.
struct WorkbenchView: View {
    @EnvironmentObject var model: BrowserModel
    enum Part: String, CaseIterable, Identifiable {
        case search = "Search", automate = "Automate", developer = "Developer", files = "Files", extensions = "Extensions", health = "Health"
        var id: String { rawValue }
    }
    @State private var part = Part.search

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $part) { ForEach(Part.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 16).padding(.bottom, 8)
            Group {
                switch part {
                case .search: WorkbenchSearch()
                case .automate: WorkbenchAutomate(bench: model.workbench)
                case .developer: WorkbenchDeveloper(bench: model.workbench)
                case .files: WorkbenchFiles(bench: model.workbench)
                case .extensions: WorkbenchExtensions(bench: model.workbench)
                case .health: WorkbenchHealth(bench: model.workbench)
                }
            }
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.18), value: part)
        .accessibilityIdentifier("workbench")
    }
}

private struct WorkbenchSearch: View {
    @EnvironmentObject var model: BrowserModel
    @State private var query = ""
    @State private var results: [SearchEntry] = []
    @FocusState private var focused: Bool

    var body: some View {
        List {
            Section {
                TextField("Search tabs, bookmarks, history, downloads, research, notes, commands", text: $query)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { if let first = results.first { model.workbench.open(first) } }
            }
            ForEach(SearchEntry.Kind.allCases, id: \.self) { kind in
                let group = results.filter { $0.kind == kind }
                if !group.isEmpty {
                    Section(kind.title) {
                        ForEach(group) { entry in
                            Button { model.workbench.open(entry) } label: {
                                HStack {
                                    Image(systemName: kind.symbol).frame(width: 22).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.title.isEmpty ? (entry.url ?? "Untitled") : entry.title).lineLimit(1)
                                        if !entry.detail.isEmpty { Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if results.isEmpty, !query.isEmpty { Text("Nothing matches.").foregroundStyle(.secondary) }
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, new in results = model.workbench.search(new) }
    }
}

private struct WorkbenchAutomate: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var bench: Workbench
    @State private var name = ""
    @State private var steps: [WorkflowStep] = []
    @State private var kind = WorkflowStep.Kind.openURL
    @State private var value = ""
    @State private var keyText = ""
    @State private var keyAction = VimAction.scrollDown

    init(bench: Workbench) { _bench = ObservedObject(wrappedValue: bench) }

    var body: some View {
        List {
            Section {
                Toggle("Vim keys", isOn: $bench.vimEnabled)
                Text("When no text field has the keyboard, letters move around the page and the browser. Escape clears a half-typed key.").font(.caption).foregroundStyle(.secondary)
                if bench.vimEnabled {
                    ForEach(VimAction.allCases) { action in
                        LabeledContent(action.title, value: bench.keymap.sequence(for: action) ?? "not set")
                    }
                    HStack {
                        Picker("Action", selection: $keyAction) { ForEach(VimAction.allCases) { Text($0.title).tag($0) } }
                        TextField("keys", text: $keyText).frame(width: 70)
                        Button("Set") {
                            var map = bench.keymap
                            if let old = map.sequence(for: keyAction) { map.bindings[old] = nil }
                            if map.bind(keyText, to: keyAction) { bench.keymap = map; keyText = "" } else { model.notice = "Those keys clash with another binding or are too long." }
                        }.disabled(keyText.isEmpty)
                        Button("Reset") { bench.keymap = .standard }
                    }
                }
            } header: { Text("Keyboard") }

            Section("Workflows") {
                ForEach(bench.workflows) { flow in
                    HStack {
                        VStack(alignment: .leading) { Text(flow.name); Text("\(flow.steps.count) steps").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Run") { bench.run(flow) }
                        Button("Remove", role: .destructive) { bench.setWorkflows(bench.workflows.filter { $0.id != flow.id }) }
                    }
                }
                TextField("Workflow name", text: $name)
                ForEach(steps) { step in Text("\(step.kind.title): \(step.value)").font(.callout) }
                HStack {
                    Picker("Step", selection: $kind) { ForEach(WorkflowStep.Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    TextField(kind == .wait ? "seconds" : (kind == .command ? "command id" : "address or words"), text: $value)
                    Button("Add Step") {
                        let step = WorkflowStep(kind: kind, value: value)
                        if step.isValid, steps.count < Workflow.maxSteps { steps.append(step); value = "" } else { model.notice = "That step is not valid." }
                    }
                }
                Button("Save Workflow") { if bench.addWorkflow(Workflow(name: name, steps: steps)) { name = ""; steps = [] } else { model.notice = "Give it a new name and at least one valid step." } }
                    .disabled(name.isEmpty || steps.isEmpty)
                Text("Commands a workflow may run: " + Workbench.safeCommands.sorted().joined(separator: ", ") + ". Link form: browsersetu://workflow?name=…, which asks before it runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("When a site opens") {
                ForEach(bench.siteRules) { rule in
                    HStack {
                        VStack(alignment: .leading) { Text(rule.host); Text(rule.action.title).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Remove", role: .destructive) { bench.setSiteRules(bench.siteRules.filter { $0.id != rule.id }) }
                    }
                }
                SiteRuleAdder(bench: bench)
                Text("A page whose site has a rule is opened where the rule says before it loads. Private and container rules open a new tab; group and workspace rules file the tab you are in.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Scheduled page checks") {
                ForEach(bench.schedule) { item in
                    HStack {
                        VStack(alignment: .leading) { Text(item.url).lineLimit(1); Text("every \(item.everyMinutes >= 60 ? "\(item.everyMinutes / 60) h" : "\(item.everyMinutes) min")").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Stop", role: .destructive) { bench.removeSchedule(item.key) }
                    }
                }
                Menu("Check This Page Every…") {
                    ForEach(ScheduledCheck.allowedIntervals, id: \.self) { minutes in
                        Button(minutes >= 60 ? "\(minutes / 60) hour\(minutes == 60 ? "" : "s")" : "\(minutes) minutes") { if let tab = model.active { bench.addSchedule(for: tab, everyMinutes: minutes) } }
                    }
                }
                Text("Runs only while the app is open. Each check loads the page in a throwaway tab with no sign-in, so pages behind a login are not seen as you see them. Turn on “Watch This Page” first.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Scripts") {
                if bench.grants.allowed.isEmpty { Text("No script has been given any permission.").foregroundStyle(.secondary) }
                ForEach(bench.grants.allowed.keys.sorted(), id: \.self) { script in
                    HStack {
                        VStack(alignment: .leading) { Text(script); Text((bench.grants.allowed[script] ?? []).map(\.prompt).sorted().joined(separator: "; ")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Revoke", role: .destructive) { bench.grants.revoke(script) }
                    }
                }
            }
        }
    }
}

private struct WorkbenchDeveloper: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var bench: Workbench
    @State private var code = "return document.title;"
    @State private var busy = false

    init(bench: Workbench) { _bench = ObservedObject(wrappedValue: bench) }

    var body: some View {
        List {
            Section {
                HStack {
                    Button(busy ? "Reading…" : "Read This Page") { busy = true; Task { await bench.inspectPage(); busy = false } }.disabled(busy)
                    Button("Save Web Archive") { Task { await bench.exportWebArchive() } }
                    Button("Export HAR") { bench.exportHAR() }.disabled(bench.snapshot == nil)
                }
                Toggle("Allow Safari's Web Inspector", isOn: Binding(get: { bench.inspectable }, set: { bench.setInspectable($0) }))
                Text("With this on, open Safari's Develop menu to inspect the page's elements, styles, network and console. WebKit gives pages no request headers or bodies, so the waterfall and HAR use the page's own timing data. Console messages are not collected; uncaught errors are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let snap = bench.snapshot {
                Section("Performance") {
                    LabeledContent("Loaded in", value: String(format: "%.0f ms", snap.performance.loadMs))
                    LabeledContent("Content ready", value: String(format: "%.0f ms", snap.performance.domContentMs))
                    if let paint = snap.performance.firstPaintMs { LabeledContent("First paint", value: String(format: "%.0f ms", paint)) }
                    LabeledContent("Requests", value: "\(snap.performance.requests)")
                    LabeledContent("Downloaded", value: ByteCountFormatter.string(fromByteCount: Int64(snap.performance.transferBytes), countStyle: .file))
                    LabeledContent("Page elements", value: "\(snap.performance.domNodes)")
                    ForEach(snap.performance.notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                }
                Section("Waterfall") {
                    ForEach(Waterfall.bars(snap.resources).prefix(80)) { bar in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(string: bar.entry.name)?.lastPathComponent.nonEmpty ?? bar.entry.name).font(.caption).lineLimit(1)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(2, geo.size.width * bar.length)).offset(x: geo.size.width * bar.start)
                            }.frame(height: 6)
                            Text("\(bar.entry.type) · \(Int(bar.entry.durationMs)) ms · \(ByteCountFormatter.string(fromByteCount: Int64(bar.entry.transferBytes), countStyle: .file))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Stored by the page") {
                    ForEach(snap.storage) { item in
                        VStack(alignment: .leading) {
                            Text(item.key).font(.callout)
                            Text("\(item.area.rawValue) · \(item.valueSize) · \(item.preview)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if snap.storage.isEmpty { Text("Nothing stored.").foregroundStyle(.secondary) }
                }
                Section("Page errors") {
                    ForEach(Array(snap.errors.enumerated()), id: \.offset) { Text($1).font(.caption.monospaced()) }
                    if snap.errors.isEmpty { Text("None since the page loaded.").foregroundStyle(.secondary) }
                }
            }
            Section("Pick an element") {
                Button(bench.picking ? "Click an element on the page…" : "Pick an Element on the Page") { Task { await bench.pickElement() } }.disabled(bench.picking)
                if let e = bench.picked {
                    LabeledContent("Selector", value: e.selector).textSelection(.enabled)
                    LabeledContent("Size", value: "\(Int(e.size.width)) × \(Int(e.size.height))")
                    HStack { Button("Copy Selector") { copyToPasteboard(e.selector) }; Button("Copy CSS") { copyToPasteboard(e.css) }; Button("Copy HTML") { copyToPasteboard(e.html) } }
                    DisclosureGroup("Styles (\(e.styles.count))") {
                        ForEach(Array(e.styles.enumerated()), id: \.offset) { _, pair in LabeledContent(pair.name, value: pair.value).font(.caption.monospaced()) }
                    }
                }
                Text("Click once on the page; Escape cancels. The page is only read: nothing on it is changed, and the picker never runs in private tabs.").font(.caption).foregroundStyle(.secondary)
            }
            #if os(macOS)
            Section("Window size") {
                ForEach(ViewportPreset.all) { preset in Button("\(preset.title) · \(preset.summary)") { model.resizeWindow(to: preset) } }
                Toggle("Show the page size in the corner", isOn: $bench.showSizeHUD)
            }
            #endif
            Section("Scratchpad") {
                TextEditor(text: $code).font(.system(.callout, design: .monospaced)).frame(minHeight: 70)
                Button("Run on This Page") { Task { await bench.runScratch(code) } }
                if !bench.scratchOutput.isEmpty { Text(bench.scratchOutput).font(.caption.monospaced()).textSelection(.enabled) }
                Text("Runs in an isolated world: it sees the page's elements, not the page's own variables. It never runs in private tabs. Use return to show a result.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

private struct WorkbenchFiles: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var bench: Workbench
    @State private var host = ""
    @State private var kind = DownloadRule.Kind.any
    @State private var folder = ""
    @State private var annotating: URL?

    init(bench: Workbench) { _bench = ObservedObject(wrappedValue: bench) }

    var body: some View {
        filesList.sheet(item: $annotating) { url in PDFAnnotatorView(source: url).environmentObject(model) }
    }

    private var filesList: some View {
        List {
            Section("Download rules") {
                ForEach(bench.downloadRules) { rule in
                    HStack {
                        Text("\(rule.kind.title) from \(rule.host.isEmpty ? "any site" : rule.host)")
                        Spacer(); Text("→ \(rule.folder)").foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { bench.setDownloadRules(bench.downloadRules.filter { $0.id != rule.id }) }
                    }
                }
                HStack {
                    Picker("Kind", selection: $kind) { ForEach(DownloadRule.Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    TextField("site (optional)", text: $host)
                    TextField("folder", text: $folder)
                    Button("Add") { if bench.addDownloadRule(host: host, kind: kind, folder: folder) { host = ""; folder = "" } else { model.notice = "Use a plain folder name, with no slashes." } }
                        .disabled(folder.isEmpty)
                }
                Text("A rule with a site beats one without. Files go in a folder inside Downloads.").font(.caption).foregroundStyle(.secondary)
            }
            Section("PDFs in Downloads") {
                let pdfs = model.downloads.completed.filter { $0.pathExtension.lowercased() == "pdf" }.prefix(12)
                if pdfs.isEmpty { Text("No PDFs downloaded in this session.").foregroundStyle(.secondary) }
                ForEach(Array(pdfs), id: \.self) { url in
                    HStack { Text(url.lastPathComponent).lineLimit(1); Spacer(); Button("Annotate…") { annotating = url } }
                }
                Text("Highlights and notes are saved to a new copy; the original is not changed.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Duplicates in Downloads") {
                Button("Look for Duplicates") { bench.scanDuplicates() }
                ForEach(bench.duplicates) { group in
                    VStack(alignment: .leading) {
                        Text("\(group.urls.count) copies · \(ByteCountFormatter.string(fromByteCount: Int64(group.size), countStyle: .file)) each").font(.callout)
                        ForEach(group.urls, id: \.self) { Text($0.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

private struct WorkbenchExtensions: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var bench: Workbench
    @State private var changes: [String: [String]] = [:]

    init(bench: Workbench) { _bench = ObservedObject(wrappedValue: bench) }

    var body: some View {
        let center = model.extensionCenter
        List {
            Section("Conflicts") {
                let found = bench.conflicts()
                if found.isEmpty { Text("No clashes found between the extensions that are on.").foregroundStyle(.secondary) }
                ForEach(found) { Label($0.message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                Text("From what their manifests say, not from watching them run.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(center.extensions) { item in
                Section(item.name) {
                    Menu("Permission Preset") {
                        ForEach(ExtensionPermissionPreset.allCases) { preset in Button("\(preset.title): \(preset.summary)") { bench.applyPreset(preset, to: item.id) } }
                    }
                    if let lines = changes[item.id] {
                        if lines.isEmpty { Text("Nothing differs from the version before.").font(.caption) }
                        ForEach(lines, id: \.self) { Text($0).font(.caption) }
                    }
                    HStack {
                        Button("What Changed in the Last Update") { changes[item.id] = center.previousVersionChanges(item.id)?.lines ?? ["No earlier version is kept."] }
                        Button("Go Back to Earlier Version") { Task { if await model.requireAuthentication("Go back to an earlier extension version") { _ = await center.rollback(item.id) } } }
                    }
                    ForEach(center.diagnostics(openTabs: model.tabs.count).filter { $0.id == item.id }) { Text($0.summary).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Per-workspace extensions") {
                ForEach([""] + model.workspaces.map(\.name), id: \.self) { ws in
                    DisclosureGroup(ws.isEmpty ? "Personal" : ws) {
                        ForEach(center.extensions) { item in
                            Toggle(item.name, isOn: Binding(
                                get: { bench.extensionProfiles[ws]?.contains(item.id) ?? item.enabled },
                                set: { on in
                                    var list = bench.extensionProfiles[ws] ?? center.extensions.filter(\.enabled).map(\.id)
                                    if on { if !list.contains(item.id) { list.append(item.id) } } else { list.removeAll { $0 == item.id } }
                                    bench.setExtensions(list, forWorkspace: ws)
                                }))
                        }
                        if bench.extensionProfiles[ws] != nil { Button("Use Whatever Is On") { bench.setExtensions(nil, forWorkspace: ws) } }
                    }
                }
                Text("Switching to a workspace turns its extensions on and the others off.").font(.caption).foregroundStyle(.secondary)
            }
            #if os(macOS)
            Section("Test and back up") {
                Button("Test an Extension Folder in a Throwaway Profile…") { testFolder() }
                ForEach(bench.checks) { c in
                    Label("\(c.name)\(c.detail.isEmpty ? "" : ": " + c.detail)", systemImage: c.status == .passed ? "checkmark.circle" : (c.status == .failed ? "xmark.circle" : "minus.circle"))
                        .font(.callout).foregroundStyle(c.status == .failed ? Color.red : (c.status == .passed ? Color.green : Color.secondary))
                }
                if !bench.checks.isEmpty { Text("Score: " + ExtensionScore.label(bench.checks) + ". It shows that the extension loads and what it declares; it does not run its features against a site.").font(.caption).foregroundStyle(.secondary) }
                Button("Back Up Installed Extensions…") { backup() }
                Text("The backup holds the extension files, not your choices. Adding one back asks for approval again.").font(.caption).foregroundStyle(.secondary)
            }
            #endif
        }
    }

    #if os(macOS)
    private func testFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { bench.checks = await model.extensionCenter.sandboxTest(folder: url) }
    }
    private func backup() {
        guard let data = model.extensionCenter.backupArchive() else { model.notice = "No extensions to back up."; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "extensions-backup.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); model.notice = "Backup saved." } catch { model.notice = "Could not save the backup." }
    }
    #endif
}

private struct WorkbenchHealth: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var bench: Workbench
    @State private var h = HealthSnapshot()

    init(bench: Workbench) { _bench = ObservedObject(wrappedValue: bench) }

    var body: some View {
        List {
            Section("Tabs and memory") {
                LabeledContent("Open tabs", value: "\(h.tabs) (\(h.sleeping) asleep, \(h.privateTabs) private)")
                LabeledContent("Browser app memory", value: ByteCountFormatter.string(fromByteCount: Int64(h.appMemory), countStyle: .memory))
                Text("Pages and extensions run in separate WebKit processes. WebKit does not report memory or processor use for one tab or one extension, so none is guessed here.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                LabeledContent("Proxy", value: h.proxy)
                LabeledContent("WebRTC", value: h.webRTCBlocked ? "blocked" : "allowed")
                LabeledContent("Automatic deletion rules", value: "\(h.deleteRules)")
                LabeledContent("Temporary permissions", value: "\(h.temporaryPermissions)")
                ForEach(h.recentPermissionChanges, id: \.self) { Text($0).font(.caption) }
            }
            Section("Extensions, downloads, sync") {
                LabeledContent("Extensions on", value: "\(h.extensionsOn) of \(h.extensionsTotal)")
                LabeledContent("Interrupted downloads", value: "\(h.failedDownloads)")
                LabeledContent("Sync", value: h.lastSync.map { "last " + $0.formatted(.relative(presentation: .named)) } ?? "never synced")
                LabeledContent("Sync devices / waiting conflicts", value: "\(h.syncDevices) / \(h.conflicts)")
            }
            Section("Storage and recovery") {
                LabeledContent("This profile on disk", value: ByteCountFormatter.string(fromByteCount: Int64(h.profileBytes), countStyle: .file))
                LabeledContent("Last start", value: h.openedAfterCrash ? "recovered after repeated crashes" : "normal")
            }
        }
        .onAppear { h = bench.health() }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }


private struct SiteRuleAdder: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var bench: Workbench
    enum Kind: String, CaseIterable, Identifiable { case privateTab = "Private tab", container = "Container", group = "Group", workspace = "Workspace"; var id: String { rawValue } }
    @State private var host = ""
    @State private var kind = Kind.privateTab
    @State private var name = ""

    private var names: [String] {
        switch kind { case .privateTab: []; case .container: model.containers; case .group: model.groupNames; case .workspace: model.workspaces.map(\.name) }
    }

    var body: some View {
        HStack {
            TextField("site, such as example.com", text: $host)
            Picker("Where", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
            if kind != .privateTab {
                Picker("Which", selection: $name) { Text("Choose…").tag(""); ForEach(names, id: \.self) { Text($0).tag($0) } }.labelsHidden()
            }
            Button("Add") {
                let action: SiteOpenRule.Action
                switch kind { case .privateTab: action = .privateTab; case .container: action = .container(name); case .group: action = .group(name); case .workspace: action = .workspace(name) }
                if bench.addSiteRule(host: host, action: action) { host = ""; name = "" } else { model.notice = "Check the site name and that the \(kind.rawValue.lowercased()) exists." }
            }.disabled(host.isEmpty || (kind != .privateTab && name.isEmpty))
        }
        .onChange(of: kind) { _, _ in name = "" }
    }
}
