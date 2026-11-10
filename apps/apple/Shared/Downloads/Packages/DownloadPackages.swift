import Foundation
import Combine

// Phase 19: a package is a named, ordered GROUPING of tasks that already exist in the ledger. It has no transfer of its own, no state machine of its own and no queue of its own:
// its progress and status are worked out from its members every time they are asked for, and every action is the coordinator's own action on a member.

struct DownloadPackage: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var profile: String
    var createdAt = Date()
    /// Folders (inside the downloads folder, "a/b") that members saved from now on go into. Cleaned when used; a task that has already started is not moved.
    var folder: String?
    /// Members in the order they were added. A task belongs to at most one package.
    var members: [UUID] = []
    /// Names the batch that made it, so asking for the same batch again finds this package instead of making tasks again.
    var batchKey: String?
    /// The last thing announced about it ("completed", "attention"), so each is announced once.
    var announced: String?
    /// Where the collection comes from ("feed:<address>"): asking for more from the same source adds to this collection instead of making another. Optional, so older files still read.
    var source: String?
    /// Each item's stable identity (a feed entry's id, a playlist entry's id…) and the task made for it: how a refresh knows what is already here, without comparing file names or addresses.
    var identities: [String: String]?
    /// How many items were chosen when the collection was made (the tasks may later be removed one by one).
    var originalCount: Int?
    /// Items chosen but not (yet) a task: waiting for their turn, being looked up, failed before a task existed, or cancelled. Kept from the moment they are chosen, so the collection always knows
    /// its children, survives a relaunch, and can offer them again. Removed when the item becomes a task.
    var entries: [String: CollectionEntry]?
}

struct CollectionEntry: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case queued, working, failed, cancelled }
    var title: String
    var state: State
    var reason: String?
}

enum PackageStatus: String, Equatable, Sendable { case empty, waiting, active, paused, needsAttention, completed, incomplete }

struct PackageProgress: Equatable, Sendable {
    var total = 0, active = 0, waiting = 0, paused = 0, completed = 0, failed = 0, cancelled = 0, recovery = 0
    var knownBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// Every member that is not cancelled has a known size.
    var sizesKnown = false
    var retryable = 0
    var status = PackageStatus.empty
    /// A share only when it means something: every counted member's size is known. Otherwise nil, and the count of finished tasks is the honest figure.
    var fraction: Double? { sizesKnown && totalBytes > 0 ? min(1, Double(knownBytes) / Double(totalBytes)) : nil }
}

struct PackageOutcome: Equatable {
    var succeeded: [UUID] = []
    var skipped: [(id: UUID, reason: String)] = []
    var failed: [(id: UUID, reason: String)] = []
    static func == (a: PackageOutcome, b: PackageOutcome) -> Bool { a.succeeded == b.succeeded && a.skipped.map(\.id) == b.skipped.map(\.id) && a.failed.map(\.id) == b.failed.map(\.id) }
    var summary: String {
        var parts = ["\(succeeded.count) done"]
        if !skipped.isEmpty { parts.append("\(skipped.count) left as they were") }
        if !failed.isEmpty { parts.append("\(failed.count) could not be done") }
        return parts.joined(separator: ", ")
    }
}

/// Builds folder names from a template. Every part is cleaned: nothing here can climb out of the downloads folder, name a hidden folder or hold a separator.
enum PackageFolderTemplate {
    static let maxParts = 4
    static func clean(_ part: String) -> String? {
        var t = part.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init).reduce(into: "") { $0.append($1) }
        t = t.trimmingCharacters(in: .whitespaces)
        for bad in ["\\", ":", "\u{0}"] { t = t.replacingOccurrences(of: bad, with: "-") }
        while t.hasPrefix(".") { t.removeFirst() }
        t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == ".." ? nil : t
    }
    /// "{package}/{host}" with the values given. Tokens: package, host, directory (the last folder of the address's path), date (yyyy-MM-dd).
    static func components(_ template: String, package: String, host: String?, directory: String?, date: Date = Date()) -> [String] {
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        var out: [String] = []
        for raw in template.split(separator: "/", omittingEmptySubsequences: true).prefix(maxParts) {
            var part = String(raw)
            part = part.replacingOccurrences(of: "{package}", with: package).replacingOccurrences(of: "{host}", with: host ?? "")
                .replacingOccurrences(of: "{directory}", with: directory ?? "").replacingOccurrences(of: "{date}", with: day.string(from: date))
            // A '/' that arrived through a value is not a folder break.
            part = part.replacingOccurrences(of: "/", with: "-")
            if let c = clean(part) { out.append(c) }
        }
        return out
    }
    static func directory(of url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts[parts.count - 2].removingPercentEncoding ?? parts[parts.count - 2]
    }
}

@MainActor
final class PackageStore: ObservableObject {
    static let maxPackages = 200
    static let maxMembers = 2000
    static let maxNameLength = 80
    static let maxFileBytes = 32_000_000

    @Published private(set) var packages: [DownloadPackage] = []
    /// Changes whenever the tasks do, so a view of the progress redraws.
    @Published private(set) var revision = 0
    private unowned let coordinator: DownloadCoordinator
    private let file: URL?
    private var bag = Set<AnyCancellable>()
    /// Called once when a package finishes or needs attention: (type, package, fraction). Wired to the event feed.
    var onEvent: ((String, DownloadPackage, Double?) -> Void)?

    init(coordinator: DownloadCoordinator, file: URL?) {
        self.coordinator = coordinator; self.file = file
        load()
        coordinator.tasksChanged.throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true).sink { [weak self] in self?.reconcileAndAnnounce() }.store(in: &bag)
    }

    var profile: String { coordinator.profileName }

    // MARK: Persistence

    private struct Disk: Codable { var version = 1; var packages: [DownloadPackage] }

    private func load() {
        guard let file, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= Self.maxFileBytes,
              let data = try? Data(contentsOf: file), let disk = try? JSONDecoder().decode(Disk.self, from: data), disk.version == 1 else { return }
        // Only this profile's, bounded, and each member list bounded.
        var seenPackages = Set<UUID>(), seenTasks = Set<UUID>()
        packages = disk.packages.filter { $0.profile == profile && seenPackages.insert($0.id).inserted }.prefix(Self.maxPackages).map { var p = $0
            // A task is in one package, however the file came to be.
            p.members = Array(p.members.prefix(Self.maxMembers)).filter { seenTasks.insert($0).inserted }
            p.name = Self.cleanName(p.name)
            // An item that was waiting or being looked up when the app quit is not running any more: it is shown as stopped, ready to be asked for again.
            if var e = p.entries { for (k, v) in e where v.state == .queued || v.state == .working { e[k] = CollectionEntry(title: v.title, state: .failed, reason: "Interrupted: the app was closed before this was saved.") }
                p.entries = e.isEmpty ? nil : e }
            return p }
        reconcile()
    }

    private func save() {
        guard let file else { return }
        let disk = Disk(packages: packages)
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Rules

    static func cleanName(_ raw: String) -> String {
        let t = raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init).reduce(into: "") { $0.append($1) }.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = String(t.prefix(maxNameLength))
        return cut.isEmpty ? "Package" : cut
    }

    /// A task this profile owns and a package may hold: it exists in this profile's ledger, and it is not a private one.
    func canHold(_ id: UUID) -> Bool {
        guard let r = coordinator.ledger.record(id) else { return false }
        return !r.isPrivate && r.profile == profile
    }

    func package(_ id: UUID) -> DownloadPackage? { packages.first { $0.id == id } }
    func package(holding task: UUID) -> DownloadPackage? { packages.first { $0.members.contains(task) } }
    private func index(_ id: UUID) -> Int? { packages.firstIndex { $0.id == id } }

    struct AddReport: Equatable { var added = 0, alreadyThere = 0, rejected = 0, full = false }

    // MARK: Create and edit

    @discardableResult
    func create(name: String, members: [UUID] = [], folder: String? = nil, batchKey: String? = nil, source: String? = nil) -> (package: DownloadPackage, report: AddReport)? {
        guard packages.count < Self.maxPackages else { return nil }
        if let batchKey, let existing = packages.first(where: { $0.batchKey == batchKey }) { return (existing, AddReport(alreadyThere: members.count)) }
        var p = DownloadPackage(name: Self.cleanName(name), profile: profile, folder: folder.flatMap(Self.cleanFolderPath), batchKey: batchKey)
        p.source = source
        packages.append(p)
        let report = add(members, to: p.id)
        p = package(p.id) ?? p
        save()
        return (p, report)
    }

    // MARK: Item identity (collections that can be refreshed)

    static let maxIdentities = 5000

    /// The collection made from this source, if there is one (the oldest, if several).
    func package(withSource source: String) -> DownloadPackage? { packages.first { $0.source == source } }

    func recordIdentity(_ key: String, task: UUID, in packageID: UUID) {
        guard let i = index(packageID), !key.isEmpty, key.count <= 700 else { return }
        var map = packages[i].identities ?? [:]
        if map.count >= Self.maxIdentities, map[key] == nil {
            // Full: identities whose tasks no longer exist (removed from the list) are forgotten first.
            map = map.filter { UUID(uuidString: $0.value).flatMap { coordinator.ledger.record($0) } != nil }
            guard map.count < Self.maxIdentities else { return }
        }
        map[key] = task.uuidString
        packages[i].identities = map
        save()
    }

    static let maxEntries = 5000

    func setEntry(_ key: String, title: String, state: CollectionEntry.State, reason: String? = nil, in packageID: UUID) {
        guard let i = index(packageID), !key.isEmpty, key.count <= 700 else { return }
        var e = packages[i].entries ?? [:]
        guard e[key] != nil || e.count < Self.maxEntries else { return }
        e[key] = CollectionEntry(title: String(title.prefix(200)), state: state, reason: reason.map { String($0.prefix(300)) })
        packages[i].entries = e
        save()
    }

    func clearEntry(_ key: String, in packageID: UUID) {
        guard let i = index(packageID), packages[i].entries?[key] != nil else { return }
        packages[i].entries?[key] = nil
        if packages[i].entries?.isEmpty == true { packages[i].entries = nil }
        save()
    }

    /// Forgets the entries that are stopped (failed or cancelled) so the collection can finish; waiting ones are left to their run.
    func dismissStoppedEntries(in packageID: UUID) {
        guard let i = index(packageID), var e = packages[i].entries else { return }
        e = e.filter { $0.value.state == .queued || $0.value.state == .working }
        packages[i].entries = e.isEmpty ? nil : e
        packages[i].announced = nil
        save()
    }

    func entry(_ key: String, in packageID: UUID) -> CollectionEntry? { package(packageID)?.entries?[key] }

    func noteChosen(_ count: Int, in packageID: UUID) { guard let i = index(packageID), count > 0 else { return }; packages[i].originalCount = (packages[i].originalCount ?? 0) + count; save() }

    /// Whether this item is already part of the collection from `source`: it was made into a task that is still in the list and has not failed or been cancelled (running, waiting, or finished
    /// with its file still there). An item whose task was removed, failed or whose file is gone is not "collected": asking again makes it again.
    func isCollected(_ key: String, source: String) -> Bool {
        // Across every collection of the source (a request grouped by site or type makes several).
        // (An identity carried in by a merge from another source is stored under that source's name.)
        let carried = source + "\u{1}" + key
        guard let raw = packages.lazy.compactMap({ p in p.source == source ? p.identities?[key] : p.identities?[carried] }).first, let task = UUID(uuidString: raw), let r = coordinator.ledger.record(task) else { return false }
        switch r.state {
        case .failed, .cancelled: return false
        case .completed: return r.file.destinationPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        default: return true
        }
    }

    static func cleanFolderPath(_ raw: String) -> String? {
        let parts = raw.split(separator: "/").prefix(PackageFolderTemplate.maxParts).compactMap { PackageFolderTemplate.clean(String($0)) }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    func rename(_ id: UUID, to name: String) { guard let i = index(id) else { return }; packages[i].name = Self.cleanName(name); save() }

    /// New members go to this folder. A member that has already started keeps the place it is writing to; nothing is moved.
    func setFolder(_ id: UUID, to folder: String?) {
        guard let i = index(id) else { return }
        packages[i].folder = folder.flatMap(Self.cleanFolderPath)
        for m in packages[i].members { applyFolder(packages[i], to: m) }
        save()
    }

    private func applyFolder(_ p: DownloadPackage, to task: UUID) {
        guard let r = coordinator.ledger.record(task), [.created, .queued, .scheduled].contains(r.state) else { return }
        // The package's folder replaces whatever the task had (a task moved out of a package with a folder does not keep that folder).
        coordinator.ledger.update(task) { $0.engineMetadata["packageFolder"] = p.folder; $0.engineMetadata["package"] = p.id.uuidString }
    }

    /// Adds tasks. One that is in another package moves here (a task is in one package). Anything this profile does not own, or that is private, is rejected.
    @discardableResult
    func add(_ ids: [UUID], to packageID: UUID) -> AddReport {
        var report = AddReport()
        guard let i = index(packageID) else { report.rejected = ids.count; return report }
        for id in ids {
            guard canHold(id) else { report.rejected += 1; continue }
            if packages[i].members.contains(id) { report.alreadyThere += 1; continue }
            guard packages[i].members.count < Self.maxMembers else { report.full = true; report.rejected += 1; continue }
            for j in packages.indices where j != i { packages[j].members.removeAll { $0 == id } }
            packages[i].members.append(id)
            applyFolder(packages[i], to: id)
            report.added += 1
        }
        packages[i].announced = nil
        save()
        return report
    }

    /// Takes tasks out of the grouping only. The tasks themselves, their files and their progress are untouched.
    func remove(_ ids: Set<UUID>, from packageID: UUID) {
        guard let i = index(packageID) else { return }
        packages[i].members.removeAll { ids.contains($0) }
        for id in ids where coordinator.ledger.record(id) != nil { coordinator.ledger.update(id) { $0.engineMetadata["package"] = nil; $0.engineMetadata["packageFolder"] = nil } }
        save()
    }

    @discardableResult
    func move(_ ids: [UUID], to packageID: UUID) -> AddReport { add(ids, to: packageID) }

    /// Everything in `source` goes into `target`, and `source` is removed (as a grouping).
    @discardableResult
    func merge(_ source: UUID, into target: UUID) -> AddReport {
        guard source != target, let s = package(source), let ti = index(target) else { return AddReport() }
        let report = add(s.members, to: target)
        // Whatever the target could not take stays where it was; the source goes only when it is empty.
        if let i = index(source) {
            let moved = Set(package(target)?.members ?? [])
            packages[i].members.removeAll { moved.contains($0) }
            if packages[i].members.isEmpty {
                // The collection's identity moves with its items: a refresh of the old source must still know what it already has.
                let ti = index(target) ?? ti
                if packages[ti].source == nil { packages[ti].source = s.source }
                let sameSource = packages[ti].source == s.source
                var ids = packages[ti].identities ?? [:]
                for (k, v) in s.identities ?? [:] {
                    guard let raw = UUID(uuidString: v), moved.contains(raw) else { continue }
                    let key = sameSource || s.source == nil || k.contains("\u{1}") ? k : (s.source! + "\u{1}" + k)
                    if ids[key] == nil { ids[key] = v }
                }
                if ids.count > Self.maxIdentities { ids = Dictionary(uniqueKeysWithValues: Array(ids).prefix(Self.maxIdentities).map { ($0.key, $0.value) }) }
                packages[ti].identities = ids.isEmpty ? nil : ids
                packages[ti].originalCount = (packages[ti].originalCount ?? 0) + (s.originalCount ?? 0)
                var e = packages[ti].entries ?? [:]
                for (k, v) in s.entries ?? [:] where e[k] == nil { e[k] = v }
                if e.count > Self.maxEntries { e = Dictionary(uniqueKeysWithValues: Array(e).prefix(Self.maxEntries).map { ($0.key, $0.value) }) }
                packages[ti].entries = e.isEmpty ? nil : e
                packages.remove(at: i)
            }
        }
        save()
        return report
    }

    /// The chosen members become a package of their own.
    @discardableResult
    func split(_ ids: Set<UUID>, from packageID: UUID, name: String) -> DownloadPackage? {
        guard let p = package(packageID) else { return nil }
        let chosen = p.members.filter { ids.contains($0) }
        guard !chosen.isEmpty, packages.count < Self.maxPackages else { return nil }
        guard let made = create(name: name, members: chosen, folder: p.folder, source: p.source)?.package, let from = index(packageID), let to = index(made.id) else { return nil }
        // Each item's identity goes with its task, so the new collection and the old one both still know what they hold.
        let chosenSet = Set(chosen)
        let moving = (packages[from].identities ?? [:]).filter { UUID(uuidString: $0.value).map(chosenSet.contains) == true }
        for k in moving.keys { packages[from].identities?[k] = nil }
        if packages[from].identities?.isEmpty == true { packages[from].identities = nil }
        packages[to].identities = moving.isEmpty ? nil : moving
        packages[to].originalCount = chosen.count
        if let n = packages[from].originalCount { packages[from].originalCount = max(0, n - chosen.count) }
        save()
        return package(made.id)
    }

    /// Removes the package as a grouping. Its tasks keep running or finished exactly as they were.
    func deletePackage(_ id: UUID) {
        guard let p = package(id) else { return }
        remove(Set(p.members), from: id)
        packages.removeAll { $0.id == id }
        save()
    }

    // MARK: Progress

    func progress(of packageID: UUID) -> PackageProgress { package(packageID).map(progress) ?? PackageProgress() }

    func progress(_ p: DownloadPackage) -> PackageProgress {
        var r = PackageProgress()
        var unknown = false
        for id in p.members {
            guard let rec = coordinator.ledger.record(id) else { continue }
            r.total += 1
            switch rec.state {
            case .completed: r.completed += 1
            case .cancelled: r.cancelled += 1
            case .failed: r.failed += 1
            case .recoveryRequired: r.recovery += 1
            case .paused, .pausing: r.paused += 1
            case .queued, .scheduled, .created: r.waiting += 1
            default: r.active += 1
            }
            if rec.state == .cancelled { continue }
            let done = rec.state == .completed ? (rec.transfer.totalBytes ?? rec.transfer.completedBytes) : rec.transfer.completedBytes
            r.knownBytes += max(0, done)
            if let t = rec.transfer.totalBytes, t > 0 { r.totalBytes += t } else if rec.state == .completed { r.totalBytes += max(0, done) } else { unknown = true }
        }
        for (_, e) in p.entries ?? [:] {
            r.total += 1
            switch e.state {
            case .queued, .working: r.waiting += 1
            case .failed: r.failed += 1
            case .cancelled: r.cancelled += 1
            }
            if e.state != .cancelled { unknown = true }
        }
        r.sizesKnown = !unknown && r.total - r.cancelled > 0
        r.retryable = p.members.filter { id in coordinator.failures.contains { $0.id == id && $0.canRetry } }.count
        r.status = Self.status(of: r)
        return r
    }

    static func status(of r: PackageProgress) -> PackageStatus {
        if r.total == 0 { return .empty }
        if r.completed == r.total { return .completed }
        if r.active > 0 { return .active }
        if r.failed > 0 || r.recovery > 0 { return .needsAttention }
        if r.paused > 0 { return .paused }
        if r.waiting > 0 { return .waiting }
        return .incomplete               // some finished, the rest cancelled: not complete, and nothing is going on
    }

    // MARK: Reconciling with the ledger

    /// Members whose tasks are gone (removed from the list) leave the package. Returns how many.
    @discardableResult
    func reconcile() -> Int {
        var removed = 0
        for i in packages.indices {
            let keep = packages[i].members.filter { canHold($0) }
            removed += packages[i].members.count - keep.count
            packages[i].members = keep
        }
        if removed > 0 { save() }
        return removed
    }

    private func reconcileAndAnnounce() {
        revision &+= 1
        reconcile()
        for i in packages.indices {
            let p = packages[i], r = progress(p)
            let now: String? = r.status == .completed ? "completed" : (r.status == .needsAttention ? "attention" : nil)
            if now == nil { if p.announced != nil { packages[i].announced = nil; save() }; continue }
            guard p.announced != now, onEvent != nil else { continue }          // with nobody listening it is not marked as announced, so it is announced when someone is
            packages[i].announced = now; save()
            coordinator.note(now == "completed" ? "Package “\(p.name)” finished" : "Package “\(p.name)” needs attention")
            onEvent?(now == "completed" ? "package.completed" : "package.attention", packages[i], r.fraction)
        }
    }

    // MARK: Actions (each is the coordinator's own action on a member; partial success is reported, never hidden)

    func pause(_ id: UUID) -> PackageOutcome {
        var out = PackageOutcome()
        for m in package(id)?.members ?? [] {
            if coordinator.canPause(m) { coordinator.pause(m); out.succeeded.append(m) } else { out.skipped.append((m, "not running, or cannot be paused")) }
        }
        return out
    }

    func resume(_ id: UUID) -> PackageOutcome {
        var out = PackageOutcome()
        for m in package(id)?.members ?? [] {
            if coordinator.interrupted[m] != nil { coordinator.resume(m); out.succeeded.append(m) } else { out.skipped.append((m, "nothing to resume")) }
        }
        return out
    }

    func cancel(_ ids: Set<UUID>, in packageID: UUID) -> PackageOutcome {
        var out = PackageOutcome()
        for m in package(packageID)?.members ?? [] where ids.contains(m) {
            guard let state = coordinator.ledger.record(m)?.state else { out.failed.append((m, "no longer in the list")); continue }
            if state.isFinal { out.skipped.append((m, "already \(state.rawValue)")) } else { coordinator.cancel(m); out.succeeded.append(m) }
        }
        return out
    }

    /// Cancels every member that has not finished. The package stays as a grouping.
    func cancelUnfinished(_ id: UUID) -> PackageOutcome { dismissStoppedEntries(in: id); return cancel(Set(package(id)?.members ?? []), in: id) }

    func retryFailed(_ id: UUID) -> PackageOutcome {
        var out = PackageOutcome()
        for m in package(id)?.members ?? [] {
            guard let rec = coordinator.ledger.record(m), rec.state == .failed || rec.state == .recoveryRequired else { continue }
            if coordinator.failures.contains(where: { $0.id == m && $0.canRetry }) { coordinator.retryFailure(m); out.succeeded.append(m) } else { out.skipped.append((m, "cannot be tried again from here")) }
        }
        return out
    }

    /// Takes finished members out of the package (the downloads stay in the list and on disk).
    @discardableResult
    func clearCompleted(_ id: UUID) -> Int {
        guard let p = package(id) else { return 0 }
        let done = Set(p.members.filter { coordinator.ledger.record($0)?.state == .completed })
        remove(done, from: id)
        return done.count
    }
}
