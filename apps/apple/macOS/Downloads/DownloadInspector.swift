import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The details of the selected download. Sections are built from what the row knows, so a field with nothing to say is left out rather than shown as "—", and a new kind of task
// adds its own section without changing these.

struct DownloadInspector: View {
    @ObservedObject var vm: DownloadsViewModel
    @State private var exportPreview: String?
    @State private var archiveTarget: ArchiveTarget?

    var body: some View {
        ScrollView { content }
            .background(Color.primary.opacity(0.025))
            .sheet(isPresented: Binding(get: { exportPreview != nil }, set: { if !$0 { exportPreview = nil } })) { exportSheet }
            .sheet(item: $archiveTarget) { target in ArchiveBrowserSheet(file: target.url, roots: [DownloadCoordinator.directory]) { archiveTarget = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Download details")
    }

    /// The report is shown in full before anything is saved or copied. It has already been through the redaction rules; nothing is sent anywhere.
    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics report").font(.headline)
            Text("This is everything that would be shared. Addresses have no query or password, and no cookies or tokens are included. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(exportPreview ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minWidth: 520, minHeight: 280).background(Color.primary.opacity(0.04))
            HStack {
                Button("Copy") { if let t = exportPreview { copyToPasteboardQuietly(t) } }
                Button("Save…") {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "browser-setu-diagnostics.json"
                    if panel.runModal() == .OK, let url = panel.url, let t = exportPreview { do { try t.write(to: url, atomically: true, encoding: .utf8) } catch { NSSound.beep(); NSAlert(error: error).runModal() } }
                }
                Spacer()
                Button("Done") { exportPreview = nil }.keyboardShortcut(.defaultAction)
            }
        }.padding(16)
    }

    /// The sections themselves, apart from the scrolling around them.
    var content: some View {
        let selected = vm.selectedRows
        return VStack(alignment: .leading, spacing: 14) {
            if selected.isEmpty {
                placeholder("Select a download to see its details.")
            } else if selected.count > 1 {
                multiple(selected)
            } else if let row = selected.first {
                single(row)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
    }

    private func multiple(_ rows: [DownloadRow]) -> some View {
        let total = rows.compactMap(\.totalBytes).reduce(0, +)
        let allowed = vm.allowedActions
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(rows.count) downloads selected").font(.system(size: 13, weight: .semibold))
            if total > 0 { Text(DownloadStats.bytes(total) + " in total").font(.system(size: 12)).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 6) {
                if allowed.contains(.pause) { batch("Pause", .pause, "pause.fill") }
                if allowed.contains(.resume) { batch("Resume", .resume, "play.fill") }
                if allowed.contains(.retry) { batch("Try Again", .retry, "arrow.clockwise") }
                if allowed.contains(.cancel) { batch("Cancel Downloads", .cancel, "xmark") }
                if allowed.contains(.removeRecord) { batch("Remove from List", .removeRecord, "minus.circle") }
            }
        }
    }

    private func batch(_ title: String, _ action: DownloadRowActions, _ symbol: String) -> some View {
        Button { vm.perform(action) } label: { Label("\(title) (\(vm.count(for: action)))", systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.bordered).controlSize(.small)
    }

    @ViewBuilder private func single(_ row: DownloadRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            DownloadFileIcon(row: row)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.filename).font(.system(size: 13, weight: .semibold)).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 5) { Image(systemName: DownloadStatusCell.symbol(row.status)).foregroundStyle(DownloadStatusCell.tint(row.status)); Text(row.statusText) }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        if let fraction = row.fraction, !row.status.isOver { ProgressView(value: fraction).tint(Theme.accent) }
        else if row.status == .downloading { ProgressView().progressViewStyle(.linear) }
        actions(row)

        section("Overview") {
            field("Source", row.sourceDisplay)
            field("Saved as", row.destinationName)
            field("Folder", row.destinationPath.map { ($0 as NSString).deletingLastPathComponent }.map { ($0 as NSString).abbreviatingWithTildeInPath })
            field("Type", row.protocolLabel)
            field("Kind", row.fileCategory)
            field("Priority", row.priority.title)
            field(row.status == .completed ? "Finished" : "Added", row.date.formatted(date: .abbreviated, time: .shortened))
        }
        if row.totalBytes != nil || row.completedBytes > 0 || row.bytesPerSecond != nil || row.connections != nil || row.queuePosition != nil || row.dueAt != nil || row.retryAttempt > 0 {
        section("Transfer") {
            field("Size", DownloadFormat.size(row.totalBytes))
            field("Done", DownloadFormat.progress(completed: row.completedBytes, total: row.totalBytes))
            field("Speed", DownloadFormat.speed(row.bytesPerSecond))
            field("Time left", DownloadFormat.eta(row.secondsLeft))
            field("Connections", row.connections.map(String.init))
            if let pieces = row.pieces, pieces > 0 { field("Pieces", row.piecesDone.map { "\($0) of \(pieces) done" } ?? "\(pieces)") }
            field("Queue", row.queuePosition.map { "#\($0) in line" })
            field("Starts", row.dueAt.map { $0.formatted(date: .abbreviated, time: .shortened) })
            field("Tries", row.retryAttempt > 0 ? "\(row.retryAttempt) retried" : nil)
        }
        }
        if let mirrors = vm.mirrorInfo(for: row.id) {
            section("Sources") {
                ForEach(mirrors.rows) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(m.address).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                            Text(m.state + (m.bytes > 0 ? " · \(DownloadFormat.size(m.bytes))" : "")).font(.system(size: 10.5)).foregroundStyle(m.usable ? Color.secondary : Color.orange).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Button { vm.removeMirror(m.id, from: row.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Remove this source")
                    }
                }
                if mirrors.canAdd {
                    Button("Add Source…") {
                        Task { @MainActor in
                            guard let text = await Dialogs.promptText(title: "Add another source", message: "The address of another copy of the same file.", placeholder: "https://mirror.example.com/file.zip", prefill: false), !text.isEmpty else { return }
                            vm.message = vm.addMirror(text, to: row.id)
                        }
                    }.controlSize(.small)
                }
                Text(mirrors.note).font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let info = vm.adaptiveInfo(for: row.id), info.mode != AdaptiveMode.unlimited.title || !info.constraints.isEmpty || !info.sources.isEmpty {
            section("Speed control") {
                field("Mode", info.mode)
                field("Connections", info.connections.map { "\($0) open" + (info.connectionBound.map { ", at most \($0) per download" } ?? "") })
                field("Held to", info.speedCeiling.map { "about \(DownloadStats.bytes($0))/s" })
                ForEach(Array(info.constraints.enumerated()), id: \.offset) { _, c in Text(c).font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(Array(info.sources.enumerated()), id: \.offset) { _, s in field(s.name, s.usable ? (DownloadFormat.speed(s.bytesPerSecond) ?? "—") : "not in use") }
            }
        }
        if let tools = MediaToolsAvailability.context(path: row.destinationPath, isCompleted: row.status == .completed, isPrivate: row.isPrivate) {
            section("Media") { MediaToolsSection(context: tools, service: MediaProcessingHub.shared) }
        } else if !row.status.isOver, let type = UTType(filenameExtension: (row.filename as NSString).pathExtension), type.conforms(to: .audiovisualContent) {
            section("Media") { Text(MediaToolsAvailability.partialExplanation).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        if let media = vm.mediaInfo(for: row.id) {
            section("Stream") {
                field("Format", media.format)
                field("Tracks", media.tracks)
                field("Progress", row.status == .completed ? nil : media.trackProgress)
                field("Result", media.output)
                if media.retries > 0, row.status != .completed { field("Retries", "\(media.retries) so far") }
                if media.refreshes > 0 { field("Links renewed", "\(media.refreshes) time\(media.refreshes == 1 ? "" : "s") from the page's playlist") }
                if media.segments > 0 { field("Segments", media.segmentsDone.map { "\($0) of \(media.segments) fetched" } ?? "\(media.segments)") }
                field("Subtitles", media.subtitleFiles)
                if let note = media.note { Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if let w = media.warnings { Text(w).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if row.status != .completed { Text("Fetched segments are kept if this stops, and a resume carries on from them. They are joined into one file when all are in.").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        if let ed = vm.ed2kInfo(for: row.id) {
            section("eD2k") {
                field("File hash", ed.hash.isEmpty ? nil : ed.hash)
                if let s = ed.live {
                    field("Sources", "\(s.sources) found" + (s.lowID > 0 ? ", \(s.lowID) unreachable (low ID)" : ""))
                    field("Connected", "\(s.connected) connected" + (s.queued > 0 ? ", \(s.queued) waiting in line" : "") + (s.sending > 0 ? ", \(s.sending) sending" : ""))
                    field("Parts", s.totalParts > 0 ? "\(s.verifiedParts) of \(s.totalParts) checked" : nil)
                    field("Speed", DownloadFormat.speed(s.downRate))
                    ForEach(s.servers.sorted(by: { $0.key < $1.key }), id: \.key) { f in field("Server", "\(f.key): \(f.value)") }
                    if let note = s.recoveryNote { Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                } else if row.status != .completed {
                    Text("Not running. Checked parts are kept; resuming checks the file again before it finishes.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Peers see your network address while this runs. Nothing is shared: this app only downloads. Sources that cannot be reached directly (low ID) are not used.").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let torrent = vm.torrentInfo(for: row.id) {
            section("Torrent") {
                field("Files", torrent.files > 0 ? "\(torrent.selected) of \(torrent.files) chosen" : nil)
                field("Kind", torrent.isPrivate ? "Private (its tracker only)" : "Public")
                TorrentLiveFilesPanel(vm: vm, id: row.id, running: torrent.live != nil).id(row.id)
                if let s = torrent.live {
                    field("Peers", "\(s.peers) connected" + (s.connecting > 0 ? ", \(s.connecting) connecting" : "") + (s.unchoked > 0 ? ", \(s.unchoked) sending" : ""))
                    field("Pieces", s.totalPieces > 0 ? "\(s.verifiedPieces) of \(s.totalPieces) checked" : nil)
                    field("Down", DownloadFormat.speed(s.downRate))
                    field("Up", DownloadFormat.speed(s.upRate) .map { "\($0) (\(DownloadStats.bytes(s.uploaded)) sent)" })
                    field("Copies", s.rarestAvailability > 0 ? "rarest piece is held by \(s.rarestAvailability) peer\(s.rarestAvailability == 1 ? "" : "s")" : nil)
                    field("Order", s.mode.title + (s.endgame ? " · last stretch (the last pieces are asked of several peers)" : ""))
                    ForEach(s.webSeeds) { w in
                        field(w.kind.capitalized, "\(w.name) · \(w.state)" + (w.pieces > 0 ? " · \(w.pieces) piece\(w.pieces == 1 ? "" : "s"), \(DownloadStats.bytes(w.bytes))" : ""))
                        if let e = w.lastError { Text(e).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    }
                    ForEach(s.trackerRows) { t in trackerBlock(t) }
                    if !s.trackerRows.isEmpty { Button("Check Tracker Counts") { vm.scrapeTrackers(row.id) }.buttonStyle(.borderless).font(.system(size: 11.5)).help("Asks each tracker how many people it knows of. A tracker may not answer; that says nothing about whether the download will work.") }
                    if let d = s.dht { dhtBlock(d, found: s.dhtPeers) }
                    peerBlock(s)
                    if let note = s.recoveryNote { Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                } else if row.status != .completed {
                    Text("Not running. Verified pieces are kept; resuming checks the files again before it finishes.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let seed = torrent.seeding { seedingBlock(seed, id: row.id) }
                Text("Speed limits for torrents are held where data is read from and sent to each peer. Peers see your network address while a torrent runs.").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let info = vm.speedLimitInfo(for: row.id) {
            section("Speed limit") {
                HStack {
                    Text(info.summary).font(.system(size: 12))
                    Spacer(minLength: 8)
                    Menu("Change") {
                        Button("No limit for this download") { vm.setSpeedLimit(row.id, nil) }
                        Divider()
                        ForEach([256 << 10, 512 << 10, 1 << 20, 2 << 20, 5 << 20], id: \.self) { rate in
                            Button(DownloadFormat.speed(Double(rate)) ?? "") { vm.setSpeedLimit(row.id, Int64(rate)) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Change this download's speed limit")
                }
                if info.effective != nil, case .notEnforced(let why) = info.enforcement {
                    Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if info.effective != nil {
                    Text("Kept by pausing the connection while the speed is above the limit.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        if row.status == .completed, !row.isLegacy, !row.integrityText.isEmpty {
            section("Integrity") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let matched = row.integrityMatched { Image(systemName: matched ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundStyle(matched ? Color.green : Color.orange).accessibilityHidden(true) }
                    Text(row.integrityText).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                if let sum = row.sha256 { Text(sum).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityLabel("SHA-256 \(sum)") }
            }
        }
        if row.problem != nil || row.recoveryNote != nil {
            section("What happened") {
                if let problem = row.problem { Text(problem).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                if let note = row.recoveryNote, note != row.problem { Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        if vm.diagnostics != nil {
            section("Diagnostics") {
                if let category = vm.failureCategory(for: row.id) {
                    Text(category.title).font(.system(size: 12, weight: .medium))
                    Text(category.advice).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(category.retryable ? "Trying again can help." : (category.needsUser ? "Needs you to change something first." : "Trying again will not help.")).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                let events = vm.timeline(for: row.id).suffix(6)
                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 6) {
                        Text(e.at.formatted(date: .omitted, time: .standard)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        Text(e.category.replacingOccurrences(of: "_", with: " ")).font(.system(size: 11.5))
                        if let a = e.retryAttempt { Text("try \(a)").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                    }
                }
                if events.isEmpty { Text("Nothing recorded for this download yet.").font(.system(size: 11)).foregroundStyle(.secondary) }
                Button("Export Diagnostics…") {
                    if let report = vm.diagnosticReport(for: row.id) { exportPreview = DownloadDiagnostics.json(report) }
                }.buttonStyle(.borderless).font(.system(size: 12))
            }
        }
        DisclosureGroup("Technical details") {
            VStack(alignment: .leading, spacing: 5) {
                field("Task", row.id.uuidString.prefix(8).lowercased())
                field("State", row.stateName)
                field("Engine", row.protocolID)
                field("Code", row.technicalCode)
                field("Attempt", row.attempt > 0 ? String(row.attempt) : nil)
                Text("Addresses are shown without their query, so a signed link is never displayed.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }.padding(.top, 4)
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private func actions(_ row: DownloadRow) -> some View {
        let a = row.actions
        let only: Set<UUID> = [row.id]
        HStack(spacing: 6) {
            if a.contains(.pause) { button("Pause", "pause.fill") { vm.perform(.pause, on: only) } }
            if a.contains(.resume) { button(row.resumeTitle, "play.fill", prominent: true) { vm.perform(.resume, on: only) } }
            if a.contains(.retry) { button("Try Again", "arrow.clockwise", prominent: true) { vm.perform(.retry, on: only) } }
            if a.contains(.startNow) { button("Start Now", "play.fill", prominent: true) { vm.perform(.startNow, on: only) } }
            if a.contains(.open), let url = vm.fileURL(for: row.id) { button("Open", "arrow.up.forward.app") { DownloadOpening.open(url) } }
            if a.contains(.reveal), let url = vm.fileURL(for: row.id) { button("Show", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            if a.contains(.cancel) { button("Cancel", "xmark") { vm.perform(.cancel, on: only) } }
        }
        HStack(spacing: 6) {
            if a.contains(.rename) { Button("Rename…") { DownloadFileUI.rename(vm, row.id) }.buttonStyle(.borderless).font(.system(size: 12)) }
            if a.contains(.move) { Button("Move…") { DownloadFileUI.move(vm, only) }.buttonStyle(.borderless).font(.system(size: 12)) }
            if a.contains(.verify) { Button("Calculate SHA-256") { vm.verify(only) }.buttonStyle(.borderless).font(.system(size: 12)) }
            if a.contains(.extract) { Button("Open Archive") { vm.extract(row.id) }.buttonStyle(.borderless).font(.system(size: 12)) }
            if row.status == .completed, let url = vm.fileURL(for: row.id), ["zip", "tar", "tgz", "gz"].contains(url.pathExtension.lowercased()) { Button("Browse Archive…") { archiveTarget = ArchiveTarget(url: url) }.buttonStyle(.borderless).font(.system(size: 12)) }
        }
        HStack(spacing: 6) {
            if a.contains(.copyPath) { Button("Copy Path") { DownloadFileUI.copyPath(vm, only) }.buttonStyle(.borderless).font(.system(size: 12)) }
            if a.contains(.openFolder) { Button("Open Folder") { DownloadFileUI.openFolder(vm, only) }.buttonStyle(.borderless).font(.system(size: 12)) }
        }
        HStack(spacing: 6) {
            if a.contains(.setPriority) {
                Menu("Priority: \(row.priority.title)") { ForEach(DownloadPriority.allCases.reversed()) { p in Button(p.title) { vm.perform(.setPriority, on: only, priority: p) } } }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
            }
            if a.contains(.removeRecord) { Button("Remove from List") { vm.perform(.removeRecord, on: only) }.buttonStyle(.borderless).font(.system(size: 12)) }
            if a.contains(.trashFile) { Button("Move File to Trash…", role: .destructive) { vm.requestTrash(on: only) }.buttonStyle(.borderless).font(.system(size: 12)) }
        }
    }

    private func button(_ title: String, _ symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Group {
            if prominent { Button(action: action) { Label(title, systemImage: symbol) }.buttonStyle(.borderedProminent) }
            else { Button(action: action) { Label(title, systemImage: symbol) }.buttonStyle(.bordered) }
        }.controlSize(.small).labelStyle(.titleAndIcon)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).tracking(0.4)
            content()
        }
    }

    /// One tracker: where it is, what it is doing, and only what is known. A count the tracker never gave is shown as unknown, never as zero.
    @ViewBuilder private func trackerBlock(_ t: TrackerStatusRow) -> some View {
        field("Tracker", "\(t.name) · \(t.scheme) · tier \(t.tier) · \(t.state.rawValue)")
        let counts = [t.seeders.map { "\($0) seeding" }, t.leechers.map { "\($0) downloading" }, t.completed.map { "\($0) finished" }].compactMap { $0 }
        let timing = [t.secondsSinceAnnounce.map { "asked \(Self.span($0)) ago" }, t.secondsUntilAnnounce.map { "next in \(Self.span($0))" }, t.interval.map { "every \(Self.span($0))" }].compactMap { $0 }
        if t.seeders == nil && t.leechers == nil && t.state == .working { Text("Counts: unknown").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
        if !counts.isEmpty { Text(counts.joined(separator: ", ")).font(.system(size: 10.5)).foregroundStyle(.secondary) }
        if !timing.isEmpty { Text(timing.joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
        if let error = t.lastError { Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        if t.needsSettings { Button("Open Settings → Downloads") { SettingsRouter.open(.downloads) }.buttonStyle(.link).font(.system(size: 10.5)) }
        if let note = t.scrapeNote { Text("Counts: \(note)").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
    }

    private func seedingStateText(_ seed: SeedingInfo) -> String {
        switch seed.state {
        case .verifying: return "Checking the files" + (seed.verifyProgress.map { " (\(Int($0 * 100))%)" } ?? "")
        case .seeding: return seed.superSeeding ? "Sharing (initial seeding)" : "Sharing"
        case .paused(let why): return "Paused. \(why)"
        case .ended(let why): return why
        case .stopped: return "Stopped"
        case .idle: return seed.authorized ? "Waiting for seeding to be turned on in Settings" : "Not shared"
        }
    }

    private func seedingLimitText(_ seed: SeedingInfo) -> String? {
        var parts: [String] = []
        if let r = seed.ratioTarget { parts.append("ratio \(String(format: "%.1f", r))") }
        if let t = seed.timeLimit { parts.append(Self.span(t)) }
        return parts.isEmpty ? nil : "stops at " + parts.joined(separator: " or ")
    }

    @ViewBuilder func seedingBlock(_ seed: SeedingInfo, id: UUID) -> some View {
        field("Sharing", seedingStateText(seed))
        field("Ratio", String(format: "%.2f", seed.ratio) + (seedingLimitText(seed).map { " · " + $0 } ?? ""))
        field("Uploaded", DownloadStats.bytes(seed.uploaded))
        if seed.isActive || seed.seconds > 0 { field("Seeding time", Self.span(seed.seconds)) }
        if seed.state == .seeding {
            field("Upload", DownloadFormat.speed(seed.upRate).map { $0 + " to " + String(seed.uploadPeers) + " of " + String(seed.peers) + " peer(s)" })
            if seed.servablePieces < seed.totalPieces { Text("\(seed.totalPieces - seed.servablePieces) of \(seed.totalPieces) pieces cannot be shared (their files are not all here, or changed).").font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        Button(seed.isActive ? "Stop Sharing" : "Start Sharing") { Task { @MainActor in await vm.toggleSeeding(id) } }
            .buttonStyle(.borderless).font(.system(size: 11.5))
            .help("Sharing uploads this torrent's files to other peers. Peers see your network address while it runs.")
    }

    @ViewBuilder func peerBlock(_ s: TorrentSession.Snapshot) -> some View {
        if s.peers > 0 || s.connectFailures > 0 || s.policyBlocked > 0 {
            field("Peers", "\(s.peersIPv4) IPv4 · \(s.peersIPv6) IPv6 · \(s.fastPeers) Fast Extension · \(s.pexPeers) PEX")
            let sources = s.peersBySource.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
            if !sources.isEmpty { field("From", sources) }
            if s.connectFailures > 0 || s.policyBlocked > 0 { Text("\(s.connectFailures) connection\(s.connectFailures == 1 ? "" : "s") failed" + (s.policyBlocked > 0 ? " · \(s.policyBlocked) not made because of your network settings" : "")).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
        }
        if let i = s.inbound, i.state != .off {
            field("Incoming", i.state == .listening ? "Listening on port \(i.tcpPort.map(String.init) ?? "?") · \(i.confirmedInbound ? "reachable (a peer connected in)" : "not yet confirmed reachable") · \(s.peersInbound) connected in" : i.state.rawValue)
            if let e = i.lastError, i.state != .listening { Text(e).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if i.needsSettings { Button("Open Settings → Downloads") { SettingsRouter.open(.downloads) }.buttonStyle(.link).font(.system(size: 10.5)) }
            if i.mapping.state != .off {
                field("Router", i.mapping.state == .mapped ? "Opened port \(i.mapping.externalPort.map(String.init) ?? "?") (\(i.mapping.via ?? "router"))" : i.mapping.state.rawValue)
                if let m = i.mapping.message { Text(m).font(.system(size: 10.5)).foregroundStyle(i.mapping.state == .failed ? .orange : .secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        if let l = s.lan {
            field("Local network", "\(l.state.rawValue) · \(l.peersFound) peer\(l.peersFound == 1 ? "" : "s") found")
            if let e = l.lastError, l.state != .listening { Text(e).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if l.needsSettings { Button("Open Settings → Downloads") { SettingsRouter.open(.downloads) }.buttonStyle(.link).font(.system(size: 10.5)) }
        }
    }

    @ViewBuilder func dhtBlock(_ d: DHTStatus, found: Int) -> some View {
        field("DHT", "\(d.state.rawValue) · \(d.nodes4 + d.nodes6) nodes · \(d.lookups) lookup\(d.lookups == 1 ? "" : "s") · \(found) peer\(found == 1 ? "" : "s") found")
        if let error = d.lastError, d.state != .ready { Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        if d.needsSettings { Button("Open Settings → Downloads") { SettingsRouter.open(.downloads) }.buttonStyle(.link).font(.system(size: 10.5)) }
    }

    private static func span(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 90 { return "\(s) s" }
        if s < 5400 { return "\(Int((Double(s) / 60).rounded())) min" }
        return String(format: "%.1f h", Double(s) / 3600)
    }

    @ViewBuilder private func field<S: StringProtocol>(_ name: String, _ value: S?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                Text(String(value)).font(.system(size: 12)).lineLimit(3).truncationMode(.middle).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
