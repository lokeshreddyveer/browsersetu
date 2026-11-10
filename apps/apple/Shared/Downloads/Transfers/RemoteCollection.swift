import Foundation

// A remote folder (or a selection of files and folders) as a plan, and the plan as a DX-10 collection of ordinary tasks. Listing is bounded and tolerant: a folder that cannot be read is
// reported and skipped, the rest goes on.

struct RemotePlannedFile: Equatable, Sendable {
    var path: String                    // on the server
    var name: String                    // safe local name
    var size: Int64?
    var modified: Date?
    var subfolders: [String]            // safe local names below the collection folder
}

struct RemoteLimits: Sendable {
    var maxDepth = 24
    var maxFiles = 20_000
    var maxFolders = 5_000
    static let `default` = RemoteLimits()
}

struct RemotePlan: Sendable {
    var files: [RemotePlannedFile] = []
    var skipped: [(path: String, why: String)] = []
    var truncated = false
    var totalBytes: Int64 { files.reduce(0) { $0 + ($1.size ?? 0) } }
}

enum RemoteFolderPlanner {
    /// Lists `roots` (entries of the folder `base`) and everything below the folders among them. Symbolic links to folders are followed once (a loop is detected by the server's own canonical path).
    static func plan(session: RemoteSession, roots: [RemoteEntry], base: String, limits: RemoteLimits) async throws -> RemotePlan {
        var plan = RemotePlan()
        var visited = Set<String>()
        var folders = 0
        struct Item { var path: String; var subfolders: [String]; var depth: Int }
        var stack: [Item] = []
        for e in roots.reversed() {
            guard let full = RemoteNames.join(base, e.name) else { continue }
            if e.isDirectory { stack.append(Item(path: full, subfolders: [RemoteNames.localName(e.name)], depth: 1)) }
            else if e.isDownloadable { plan.files.append(RemotePlannedFile(path: full, name: RemoteNames.localName(e.name), size: e.size, modified: e.modified, subfolders: [])) }
        }
        while let item = stack.popLast() {
            try Task.checkCancellation()
            folders += 1
            if folders > limits.maxFolders || plan.files.count >= limits.maxFiles { plan.truncated = true; break }
            let real = (try? await session.canonical(item.path)) ?? item.path
            guard visited.insert(real).inserted else { plan.skipped.append((item.path, "a folder that leads back to itself")); continue }
            let box = EntryBox()
            do { _ = try await session.list(item.path, limit: limits.maxFiles) { box.add($0) } }
            catch is CancellationError { throw CancellationError() }
            catch { plan.skipped.append((item.path, (error as? RemoteError)?.errorDescription ?? "it could not be read")); continue }
            var children: [Item] = []
            for e in box.entries {
                guard let full = RemoteNames.join(item.path, e.name) else { continue }
                if e.isDirectory { if item.depth < limits.maxDepth { children.append(Item(path: full, subfolders: item.subfolders + [RemoteNames.localName(e.name)], depth: item.depth + 1)) } else { plan.skipped.append((full, "it is nested too deeply")) } }
                else if e.isDownloadable {
                    if plan.files.count >= limits.maxFiles { plan.truncated = true; break }
                    plan.files.append(RemotePlannedFile(path: full, name: RemoteNames.localName(e.name), size: e.size, modified: e.modified, subfolders: item.subfolders))
                } else if e.kind == .symlink || e.isBroken { plan.skipped.append((full, e.isBroken ? "a link that leads nowhere" : "a link this server does not describe")) }
            }
            stack.append(contentsOf: children.reversed())
        }
        return plan
    }

    final class EntryBox: @unchecked Sendable {
        private let lock = NSLock(); private var all: [RemoteEntry] = []
        func add(_ e: [RemoteEntry]) { lock.lock(); all += e; lock.unlock() }
        var entries: [RemoteEntry] { lock.lock(); defer { lock.unlock() }; return all }
    }
}

enum RemoteCollection {
    struct Outcome: Equatable { var started = 0, alreadyThere = 0, failedToStart = 0, source = "" }

    static func source(for connection: RemoteConnection, base: String) -> String { "remote:\(connection.id.uuidString):\(base)" }

    /// Makes (or finds) the collection for this place on this server and adds one task per file not already in it. Nothing is downloaded twice, and a refresh of the same place adds only what is new.
    @MainActor
    static func download(_ plan: RemotePlan, from connection: RemoteConnection, base: String, title: String, isPrivate: Bool = false, coordinator: DownloadCoordinator) async -> Outcome {
        var out = Outcome(); out.source = source(for: connection, base: base)
        let name = PackageStore.cleanName(title)
        // A private session keeps no collection (a package never holds a private task); its files are plain tasks.
        let package = isPrivate ? nil : (coordinator.packages.package(withSource: out.source) ?? coordinator.packages.create(name: name, members: [], source: out.source)?.package)
        let folder = PackageFolderTemplate.clean(name)
        var chosen = 0
        for file in plan.files {
            let key = file.path + "#0"
            if !isPrivate, coordinator.packages.isCollected(key, source: out.source) { out.alreadyThere += 1; continue }
            chosen += 1
            let job = RemoteFileJob(connection: connection.id, path: file.path, size: file.size, modified: file.modified, filename: file.name, subfolders: file.subfolders, collectionFolder: isPrivate ? nil : folder, isPrivate: isPrivate)
            guard let id = coordinator.remoteFiles.add(job) else { out.failedToStart += 1; continue }
            out.started += 1
            if let package { coordinator.packages.add([id], to: package.id); coordinator.packages.recordIdentity(key, task: id, in: package.id) }
        }
        if let package, chosen > 0 { coordinator.packages.noteChosen(chosen, in: package.id) }
        return out
    }
}


/// What deleting a selection would remove, worked out before anything is removed (so the person is told exactly). A symbolic link is a plain item to remove and is NEVER entered: following one out of the folder would
/// delete files that are not in it. Bounded: a selection with more items than the limit is refused, not cut short.
struct RemoteDeletePlan: Sendable {
    var roots: [(path: String, isDirectory: Bool)] = []
    var files: [String] = []               // files and links
    var folders: [String] = []             // deepest first
    var count: Int { files.count + folders.count }
}

enum RemoteDeletePlanner {
    static let maxItems = 2_000

    static func plan(session: RemoteSession, roots: [RemoteEntry], base: String) async throws -> RemoteDeletePlan {
        var plan = RemoteDeletePlan()
        func walk(_ folder: String, depth: Int) async throws {
            guard depth <= 24 else { throw RemoteError.tooLarge("That folder is nested too deeply to delete from here.") }
            let box = RemoteFolderPlanner.EntryBox()
            _ = try await session.list(folder, limit: maxItems + 1) { box.add($0) }
            for e in box.entries {
                try Task.checkCancellation()
                guard let full = RemoteNames.join(folder, e.name) else { continue }
                if e.isDirectory && !e.isLink { try await walk(full, depth: depth + 1) } else { plan.files.append(full) }
                if plan.count > maxItems { throw RemoteError.tooLarge("That is more than \(maxItems) items. Delete it in smaller parts.") }
            }
            plan.folders.append(folder)
        }
        for e in roots {
            guard let full = RemoteNames.join(base, e.name), full != "/" else { continue }
            if e.isDirectory && !e.isLink { plan.roots.append((full, true)); try await walk(full, depth: 1) }
            else { plan.roots.append((full, false)); plan.files.append(full) }
            if plan.count > maxItems { throw RemoteError.tooLarge("That is more than \(maxItems) items. Delete it in smaller parts.") }
        }
        return plan
    }
}
