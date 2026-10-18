import Foundation
import SQLite3
import SwiftUI

// MARK: Diagnostic log

/// A small log kept on this device so a problem can be understood afterwards. It records what kind of thing happened, never an address, a page title or
/// anything typed: web addresses are replaced by a placeholder before a line is written. Nothing is sent anywhere.
enum DiagLog {
    static let maxLines = 300
    nonisolated(unsafe) static var folder: URL?
    private static let queue = DispatchQueue(label: "app.browsersetu.diaglog")

    static func sanitize(_ text: String) -> String {
        let withoutAddresses = text.replacingOccurrences(of: "[a-zA-Z][a-zA-Z0-9+.-]*://\\S+", with: "<address>", options: .regularExpression)
        return String(withoutAddresses.replacingOccurrences(of: "\n", with: " ").prefix(200))
    }

    static func line(_ category: String, _ message: String, at date: Date = Date()) -> String {
        "\(ISO8601DateFormatter().string(from: date)) \(category.prefix(20)) \(sanitize(message))"
    }

    static func record(_ category: String, _ message: String) {
        guard let folder else { return }
        let entry = line(category, message)
        queue.async {
            let url = folder.appendingPathComponent("diagnostics.log")
            var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            lines.append(entry)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func recent(limit: Int = 60) -> [String] {
        guard let folder, let text = try? String(contentsOf: folder.appendingPathComponent("diagnostics.log"), encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").map(String.init).suffix(limit))
    }

    static func clear() { if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent("diagnostics.log")) } }
}

// MARK: Measurements

/// Counts of things that went wrong, measured as they happened. They are numbers from this run of the app, not estimates.
@MainActor
final class ReliabilityStats: ObservableObject {
    static let shared = ReliabilityStats()
    @Published private(set) var failedNavigations = 0
    @Published private(set) var tabCrashes = 0
    @Published private(set) var unresponsiveEvents = 0
    @Published private(set) var memoryWarnings = 0
    @Published private(set) var lastMemoryWarning: Date?
    @Published private(set) var databaseCheckedAt: Date?
    @Published private(set) var databaseResult: String?

    let started = Date()
    private static let terminationKey = "last_unexpected_termination"

    /// When an earlier run of the app ended without finishing its start-up, or nil if none was recorded.
    var lastUnexpectedTermination: Date? { UserDefaults.standard.object(forKey: Self.terminationKey) as? Date }

    func noteUnexpectedTermination() { UserDefaults.standard.set(Date(), forKey: Self.terminationKey); DiagLog.record("launch", "The previous run ended before it finished starting.") }
    func noteFailedNavigation(_ kind: String) { failedNavigations += 1; DiagLog.record("navigation", "A page failed to load: \(kind).") }
    func noteTabCrash() { tabCrashes += 1; DiagLog.record("tab", "A page's process ended unexpectedly.") }
    func noteUnresponsive() { unresponsiveEvents += 1; DiagLog.record("tab", "A page stopped answering.") }
    func noteMemory(critical: Bool) { memoryWarnings += 1; lastMemoryWarning = Date(); DiagLog.record("memory", critical ? "Critical memory pressure." : "Memory pressure warning.") }
    func noteDatabase(_ result: String) { databaseCheckedAt = Date(); databaseResult = result; DiagLog.record("database", "Integrity check: \(result == "ok" ? "passed" : "FAILED")") }

    enum Status: Equatable { case healthy, attention([String]) }

    func status(recovering: Bool, safeStart: Bool) -> Status {
        var reasons: [String] = []
        if recovering { reasons.append("The profile database is in recovery.") }
        if safeStart { reasons.append("The app started in safe mode after repeated crashes.") }
        if let r = databaseResult, r != "ok" { reasons.append("The database check reported a problem.") }
        if tabCrashes > 0 { reasons.append("\(tabCrashes) page process\(tabCrashes == 1 ? "" : "es") ended unexpectedly this run.") }
        if unresponsiveEvents > 0 { reasons.append("\(unresponsiveEvents) page\(unresponsiveEvents == 1 ? "" : "s") stopped answering this run.") }
        return reasons.isEmpty ? .healthy : .attention(reasons)
    }

    /// A report to share by hand: app version, system, counters and the safe log. No addresses, titles or personal data.
    func report(tabs: Int, sleeping: Int, extensions: Int) -> String {
        let info = Bundle.main.infoDictionary
        var lines = ["Browser Setu diagnostic report", "Version: \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
                     "System: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Running for: \(Int(Date().timeIntervalSince(started) / 60)) minutes",
                     "Tabs: \(tabs) (\(sleeping) asleep), extensions on: \(extensions)",
                     "Failed navigations: \(failedNavigations), page crashes: \(tabCrashes), unresponsive pages: \(unresponsiveEvents), memory warnings: \(memoryWarnings)",
                     "Database check: \(databaseResult ?? "not run")",
                     "Last unexpected termination: \(lastUnexpectedTermination.map { ISO8601DateFormatter().string(from: $0) } ?? "none recorded")", "", "Recent events:"]
        lines += DiagLog.recent(limit: 80)
        return lines.joined(separator: "\n")
    }
}

enum DatabaseCheck {
    /// Runs SQLite's own quick integrity check on a database file, opened read-only. Returns "ok" or what it found.
    static func quickCheck(at url: URL) -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return "could not open the file" }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &statement, nil) == SQLITE_OK else { return "the check could not run" }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return "the check gave no answer" }
        return String(cString: text)
    }
}

// MARK: Session Time Machine

/// A moment in the browsing session: which pages were open and how they were arranged. Only addresses, titles and arrangement are kept, never page contents.
struct SessionCheckpoint: Codable, Identifiable, Equatable {
    struct Tab: Codable, Equatable { var url: String; var title: String; var pinned: Bool; var group: String; var workspace: String }
    var id = UUID()
    var date: Date
    var reason: String
    var tabs: [Tab]

    /// What the open pages were, whatever their order, so two checkpoints of the same pages are known to be the same.
    var key: String { tabs.map { $0.url + "|" + $0.group }.sorted().joined(separator: "\n") }
}

enum CheckpointRules {
    static let maxCount = 60

    /// A new automatic checkpoint is worth keeping when the pages changed and enough time has passed since the last one.
    static func shouldTake(lastKey: String?, lastDate: Date?, newKey: String, now: Date, minInterval: TimeInterval = 600) -> Bool {
        guard !newKey.isEmpty else { return false }
        if newKey == lastKey { return false }
        guard let lastDate else { return true }
        return now.timeIntervalSince(lastDate) >= minInterval
    }

    /// Everything from the last three hours, then one an hour for three days, newest first. Forced ones ("before closing many tabs") are kept for a day.
    static func prune(_ list: [SessionCheckpoint], now: Date) -> [SessionCheckpoint] {
        var kept: [SessionCheckpoint] = [], hours = Set<Int>()
        for c in list.sorted(by: { $0.date > $1.date }) {
            let age = now.timeIntervalSince(c.date)
            if age > 72 * 3600 { continue }
            let forced = c.reason != "Automatic"
            if age <= 3 * 3600 || (forced && age <= 24 * 3600) { kept.append(c); continue }
            if hours.insert(Int(c.date.timeIntervalSince1970 / 3600)).inserted { kept.append(c) }
        }
        return Array(kept.prefix(maxCount))
    }

    /// The pages of a checkpoint that are not open now.
    static func missing(_ c: SessionCheckpoint, openURLs: Set<String>) -> [SessionCheckpoint.Tab] {
        var seen = openURLs
        return c.tabs.filter { seen.insert($0.url).inserted }
    }
}

@MainActor
extension BrowserModel {
    private var checkpointFile: URL {
        let folder = URL(fileURLWithPath: root).appendingPathComponent("profiles/\(profileName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("checkpoints.json")
    }

    func loadCheckpoints() {
        guard let data = try? Data(contentsOf: checkpointFile), let list = try? JSONDecoder().decode([SessionCheckpoint].self, from: data) else { checkpoints = []; return }
        checkpoints = list
    }

    private func saveCheckpoints() {
        if let data = try? JSONEncoder().encode(checkpoints) { try? data.write(to: checkpointFile, options: .atomic) }
    }

    private func currentCheckpointTabs() -> [SessionCheckpoint.Tab] {
        tabs.filter { !$0.isPrivate && !$0.isBlank }.compactMap { tab in
            guard let url = tab.url, ["http", "https"].contains(url.scheme ?? "") else { return nil }
            return SessionCheckpoint.Tab(url: url.absoluteString, title: tab.displayTitle, pinned: tab.pinned, group: tab.group, workspace: tab.workspace)
        }
    }

    /// Saves a checkpoint of the open pages. Automatic ones are skipped when nothing changed or one was taken lately.
    func takeCheckpoint(reason: String = "Automatic", force: Bool = false, now: Date = Date()) {
        let current = SessionCheckpoint(date: now, reason: reason, tabs: currentCheckpointTabs())
        guard !current.tabs.isEmpty else { return }
        if !force, !CheckpointRules.shouldTake(lastKey: checkpoints.first?.key, lastDate: checkpoints.first?.date, newKey: current.key, now: now) { return }
        if force, checkpoints.first?.key == current.key, checkpoints.first?.reason == reason { return }
        checkpoints = CheckpointRules.prune([current] + checkpoints, now: now)
        saveCheckpoints()
    }

    /// Opens the pages of a checkpoint that are not open now, in their groups and pinned as they were.
    @discardableResult
    func restoreCheckpoint(_ checkpoint: SessionCheckpoint) -> Int {
        let open = Set(tabs.compactMap { $0.url?.absoluteString })
        var opened = 0
        for item in CheckpointRules.missing(checkpoint, openURLs: open) {
            guard let url = URL(string: item.url) else { continue }
            let tab = openTab(url: url, isPrivate: false, select: false)
            if !item.group.isEmpty { if !groupNames.contains(item.group) { createGroup(item.group) }; moveTab(tab, to: item.group) }
            if item.pinned { togglePin(tab) }
            opened += 1
        }
        notice = opened == 0 ? "All of those pages are already open." : "Reopened \(opened) page\(opened == 1 ? "" : "s")."
        return opened
    }

    func deleteCheckpoint(_ checkpoint: SessionCheckpoint) {
        checkpoints.removeAll { $0.id == checkpoint.id }
        saveCheckpoints()
    }

    /// Called with the window's background check, about every two minutes, in the first window only.
    func checkpointTick() {
        guard !isSecondary else { return }
        takeCheckpoint()
    }
}

struct TimeMachineView: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        List {
            Section {
                Button("Save a Checkpoint Now") { model.takeCheckpoint(reason: "Saved by you", force: true); model.notice = "Checkpoint saved." }
            } footer: {
                Text("The browser keeps a checkpoint of the open pages every few minutes while they change, and before closing many tabs at once: everything from the last three hours, then one an hour for three days. Only addresses, titles and arrangement are kept, never page contents. Private tabs are never included.")
            }
            if model.checkpoints.isEmpty { Section { Text("No checkpoints yet.").foregroundStyle(.secondary) } }
            ForEach(model.checkpoints) { checkpoint in
                let missing = CheckpointRules.missing(checkpoint, openURLs: Set(model.tabs.compactMap { $0.url?.absoluteString })).count
                Section {
                    DisclosureGroup {
                        ForEach(Array(checkpoint.tabs.prefix(60).enumerated()), id: \.offset) { _, tab in
                            Text(tab.title.isEmpty ? tab.url : tab.title).lineLimit(1).font(.caption)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(checkpoint.date.formatted(date: .abbreviated, time: .shortened)).fontWeight(.medium)
                            Text("\(checkpoint.tabs.count) tabs · \(checkpoint.reason) · \(missing) not open now").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Reopen the \(missing) Missing") { model.restoreCheckpoint(checkpoint) }.disabled(missing == 0)
                        Button("Keep as a Saved Session…") {
                            Task { @MainActor in
                                if let name = await Dialogs.promptText(title: "Save Session", message: "Name this session.", placeholder: checkpoint.date.formatted(date: .abbreviated, time: .shortened)), !name.isEmpty {
                                    model.saveCheckpointAsSession(checkpoint, named: name)
                                }
                            }
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { model.deleteCheckpoint(checkpoint) }.buttonStyle(.borderless)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .onAppear { model.loadCheckpoints() }
    }
}

@MainActor
extension BrowserModel {
    func saveCheckpointAsSession(_ checkpoint: SessionCheckpoint, named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60 else { return }
        let session = SavedSession(name: clean, tabs: checkpoint.tabs.map { SavedSession.Tab(url: $0.url, title: $0.title, pinned: $0.pinned) })
        setSavedSessions(Array(([session] + savedSessions).prefix(50)))
        notice = "Saved “\(clean)” with \(session.tabs.count) tabs."
    }
}

// MARK: Health Center section

struct ReliabilitySection: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var stats = ReliabilityStats.shared
    @State private var checking = false
    @State private var verifying = false
    @State private var backupData: Data?
    @State private var passphrase = ""
    @State private var verifyResult: String?
    @State private var choosing = false

    var body: some View {
        let status = stats.status(recovering: model.recovery != nil, safeStart: model.safeStart)
        Group {
            Section("Browser Health") {
                switch status {
                case .healthy: Label("Healthy", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                case .attention(let reasons):
                    Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    ForEach(reasons, id: \.self) { Text($0).font(.caption) }
                }
                LabeledContent("Tabs", value: "\(model.tabs.count) (\(model.tabs.filter(\.isDiscarded).count) asleep)")
                LabeledContent("Extensions", value: "\(model.extensionCenter.extensions.filter(\.enabled).count) enabled of \(model.extensionCenter.extensions.count)")
                LabeledContent("Failed navigations", value: "\(stats.failedNavigations) this run")
                LabeledContent("Page process crashes", value: "\(stats.tabCrashes) this run")
                LabeledContent("Pages that stopped answering", value: "\(stats.unresponsiveEvents) this run")
                LabeledContent("Memory warnings from the system", value: stats.memoryWarnings == 0 ? "None this run" : "\(stats.memoryWarnings), last \(stats.lastMemoryWarning!.formatted(.relative(presentation: .named)))")
                LabeledContent("Last unexpected termination", value: stats.lastUnexpectedTermination.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "None recorded")
                LabeledContent("Database integrity", value: stats.databaseResult.map { $0 == "ok" ? "Passed \(stats.databaseCheckedAt!.formatted(.relative(presentation: .named)))" : "Problem: \($0)" } ?? (model.recovery == nil ? "Passed when this profile opened" : "In recovery"))
                Button(checking ? "Checking…" : "Check the Database Now") { checkDatabase() }.disabled(checking)
            }
            Section {
                Button("Copy a Diagnostic Report") {
                    copyToPasteboard(stats.report(tabs: model.tabs.count, sleeping: model.tabs.filter(\.isDiscarded).count, extensions: model.extensionCenter.extensions.filter(\.enabled).count))
                    model.notice = "Report copied. It holds no addresses or titles."
                }
                Button("Clear the Diagnostic Log", role: .destructive) { DiagLog.clear(); model.notice = "Diagnostic log cleared." }
                Button("Session Time Machine…") { model.sheet = .timeMachine }
            } footer: {
                Text("The log records what kind of thing happened and when, never an address, a title or anything you typed. It stays on this device; share the report by hand if you want help.")
            }
            Section {
                Button("Verify a Backup File…") { choosing = true; verifyResult = nil; backupData = nil }
                if backupData != nil {
                    SecureField("Backup passphrase", text: $passphrase)
                    Button(verifying ? "Verifying…" : "Verify") { verifyBackup() }.disabled(verifying || passphrase.isEmpty)
                }
                if let verifyResult { Text(verifyResult).font(.caption) }
            } header: { Text("Backup Check") } footer: {
                Text("Opens the backup with its passphrase and reads it through, without changing anything in the browser.")
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.data, .item]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                backupData = try? Data(contentsOf: url)
                if backupData == nil { verifyResult = "That file could not be read." }
            }
        }
    }

    private func checkDatabase() {
        checking = true
        let file = URL(fileURLWithPath: model.root).appendingPathComponent("profiles/\(model.profileName)/browser.db")
        Task {
            let result = await Task.detached { DatabaseCheck.quickCheck(at: file) }.value
            ReliabilityStats.shared.noteDatabase(result)
            checking = false
        }
    }

    private func verifyBackup() {
        guard let data = backupData else { return }
        verifying = true
        let phrase = passphrase
        Task {
            do {
                let payload = try await Task.detached(priority: .userInitiated) { try BackupFile.open(data, passphrase: phrase) }.value
                verifyResult = "Readable. Made \(payload.created.formatted(date: .abbreviated, time: .shortened)), with \(payload.bookmarks.count) bookmarks and \(payload.settings.count) settings."
            } catch { verifyResult = "It could not be opened: the passphrase is wrong or the file is damaged." }
            verifying = false; passphrase = ""
        }
    }
}


@MainActor
extension BrowserModel {
    /// Asks the page in front a trivial question. A page that misses it twice in a row is reported once, with the choice to reload or wait.
    func watchResponsiveness() async {
        guard let tab = active, !tab.isBlank, !tab.isDiscarded, !tab.isLoading else { unresponsiveStreak = 0; unresponsiveReported = false; return }
        if await tab.engine.respondsWithin(4) { unresponsiveStreak = 0; unresponsiveReported = false; return }
        unresponsiveStreak += 1
        guard unresponsiveStreak >= 2, !unresponsiveReported else { return }
        unresponsiveReported = true
        ReliabilityStats.shared.noteUnresponsive()
        notice = "“\(tab.displayTitle)” is not answering. Wait, or reload it from the menu."
    }
}
