import Foundation
import AppKit

// Browser Setu is distributed as a direct-download, unsandboxed app. Earlier builds ran in the App Sandbox, which keeps an app's files in ~/Library/Containers/<id>/Data. An unsandboxed
// build looks in ~/Library instead, so without this the person's profiles would seem to have vanished. This copies what the app owns from the old container to the new places, once.
//
// Rules: it only ever COPIES. The container is never changed or deleted. A file that already exists at the destination is kept as it is (the destination wins; a differing one is recorded as a
// conflict). Each file is written beside its final name and then renamed, so an interruption leaves whole files only, and the next launch carries on (it copies what is still missing). When
// it has finished it writes a record of what it copied, which is also what a later undo uses. It runs before anything opens the profile data, and not at all under tests or with a test root.

enum SandboxMigration {
    struct Record: Codable, Equatable {
        var version = 1
        var finishedAt: Date
        var source: String
        var copied: [String]          // destination paths this migration created
        var conflicts: [String]       // destination paths that already existed with different content (kept as they were)
        var skipped: [String]         // things not copied, with the reason
        var defaultsKeysCopied: [String]
        /// Size and modification time of each copied file at the moment it was copied, so a later undo removes only files nobody has changed since.
        var signatures: [String: [Double]] = [:]
    }
    enum Outcome: Equatable { case notNeeded(String), alreadyDone, migrated(Record), failed(String) }

    /// What is copied, from the container's Library to the real Library. Caches, content-rule lists and extension build products are rebuilt by the app and are left behind on purpose.
    static let items: [(from: String, to: String)] = [
        ("Application Support/BrowserSetu", "Application Support/BrowserSetu"),
        ("WebKit/WebsiteData", "WebKit/{id}/WebsiteData"),
        ("WebKit/WebsiteDataStore", "WebKit/{id}/WebsiteDataStore"),
    ]
    static let recordName = ".sandbox-migration.json"
    /// Inside a website-data store, HTTP and media caches are rebuilt by the web engine and make up most of its size; everything else in it is the person's session (cookies, local storage, IndexedDB,
    /// service-worker storage, HSTS, per-site settings) and is copied.
    static let rebuiltInsideStores: Set<String> = ["NetworkCache", "MediaCache", "JavaScriptCoreDebug"]

    static func realHome() -> URL { URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir)) }
    static func defaultSource(_ id: String) -> URL { realHome().appendingPathComponent("Library/Containers/\(id)/Data", isDirectory: true) }

    /// Called once at start-up, before the profile data is opened.
    @discardableResult
    static func runIfNeeded(bundleID: String = Bundle.main.bundleIdentifier ?? "com.browsersetu.mac", sourceContainer: URL? = nil, destinationHome: URL? = nil, defaults: UserDefaults = .standard) -> Outcome {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return .notNeeded("this build is sandboxed") }
        let source = sourceContainer ?? defaultSource(bundleID)
        let home = destinationHome ?? realHome()
        let lib = source.appendingPathComponent("Library", isDirectory: true)
        guard FileManager.default.fileExists(atPath: lib.path) else { return .notNeeded("there is no earlier sandbox container") }
        let recordURL = home.appendingPathComponent("Library/Application Support/BrowserSetu/\(recordName)")
        if let data = try? Data(contentsOf: recordURL), (try? decoder.decode(Record.self, from: data)) != nil { return .alreadyDone }

        // The earlier (sandboxed) app may still be open and writing its databases; copying them mid-write could capture a torn state. Wait until it is closed.
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != getpid() }) {
            return .failed("Another copy of Browser Setu is still open. Quit it, then open Browser Setu again so your earlier data can be copied.")
        }
        var copied: [String] = [], conflicts: [String] = [], skipped: [String] = []
        let fm = FileManager.default
        for item in items {
            let from = lib.appendingPathComponent(item.from, isDirectory: true)
            let to = home.appendingPathComponent("Library", isDirectory: true).appendingPathComponent(item.to.replacingOccurrences(of: "{id}", with: bundleID), isDirectory: true)
            guard fm.fileExists(atPath: from.path) else { skipped.append("\(item.from): not in the container"); continue }
            do { try copyMissing(from: from, to: to, copied: &copied, conflicts: &conflicts, skipped: &skipped) }
            catch { return .failed("copying \(item.from): \(error.localizedDescription)") }
        }
        // A file that could not be copied is a real loss, not a skip: no record is written, so the next start tries again, and the person is told.
        let failures = skipped.filter { $0.contains("could not be copied") }
        if !failures.isEmpty { return .failed("\(failures.count) file\(failures.count == 1 ? "" : "s") could not be copied (\(failures.first ?? "")).") }
        // Preferences: keys the new place does not have yet. A value already set there is the newer truth.
        var keys: [String] = []
        let plist = lib.appendingPathComponent("Preferences/\(bundleID).plist")
        if let data = try? Data(contentsOf: plist), let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            for (k, v) in dict where !k.hasPrefix("NS") && !k.hasPrefix("Apple") && defaults.object(forKey: k) == nil { defaults.set(v, forKey: k); keys.append(k) }
        }
        var signatures: [String: [Double]] = [:]
        for path in copied {
            let a = try? fm.attributesOfItem(atPath: path)
            signatures[path] = [Double((a?[.size] as? NSNumber)?.intValue ?? -1), (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0]
        }
        let record = Record(finishedAt: Date(), source: source.path, copied: copied, conflicts: conflicts, skipped: skipped, defaultsKeysCopied: keys.sorted(), signatures: signatures)
        do {
            try fm.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(record).write(to: recordURL, options: .atomic)
        } catch { return .failed("writing the record: \(error.localizedDescription)") }
        return .migrated(record)
    }

    private static let sidecarSuffixes = ["-wal", "-journal"]
    private static func isSidecar(_ name: String) -> Bool { name.hasSuffix("-shm") || sidecarSuffixes.contains { name.hasSuffix($0) } }
    private static func baseName(_ sidecar: String) -> String { for s in ["-shm"] + sidecarSuffixes where sidecar.hasSuffix(s) { return String(sidecar.dropLast(s.count)) }; return sidecar }

    /// Copies every regular file that is not at the destination yet. Never overwrites, never follows or copies links, sockets or devices. A database and its write-ahead log or journal are one unit:
    /// the log is put in place first and the database last, so the database being there means the set is whole; if the database is already at the destination, none of the container's set is brought in
    /// (a log from another copy must never be replayed onto it). The shared-memory file is never copied (it is rebuilt).
    static func copyMissing(from: URL, to: URL, copied: inout [String], conflicts: inout [String], skipped: inout [String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey], options: [])
        let names = Set(entries.map(\.lastPathComponent))
        func put(_ entry: URL, _ target: URL) {
            let temp = to.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).migrating")
            do { try fm.copyItem(at: entry, to: temp); try fm.moveItem(at: temp, to: target); copied.append(target.path) }
            catch { try? fm.removeItem(at: temp); skipped.append("\(target.path): could not be copied (\(error.localizedDescription))") }
        }
        // The main database files that have a log or journal beside them.
        let mains = names.filter { n in !isSidecar(n) && sidecarSuffixes.contains { names.contains(n + $0) } }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if name == recordName || name.hasSuffix(".migrating") { continue }
            if rebuiltInsideStores.contains(name), from.path.contains("/WebKit/WebsiteDataStore") { skipped.append("\(to.appendingPathComponent(name).path): a cache, rebuilt"); continue }
            let target = to.appendingPathComponent(name)
            let v = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if v.isSymbolicLink == true { skipped.append("\(target.path): a link"); continue }
            if v.isDirectory == true { try copyMissing(from: entry, to: target, copied: &copied, conflicts: &conflicts, skipped: &skipped); continue }
            guard v.isRegularFile == true else { skipped.append("\(target.path): not a regular file"); continue }
            if isSidecar(name) {
                if name.hasSuffix("-shm") { skipped.append("\(target.path): rebuilt, not copied"); continue }
                if names.contains(baseName(name)) { continue }                 // handled with its database below
                // A log with no database beside it in the container: copy only if nothing is there.
                if !fm.fileExists(atPath: target.path) { put(entry, target) }
                continue
            }
            if fm.fileExists(atPath: target.path) {
                if (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) != v.fileSize { conflicts.append(target.path) }
                continue                                                         // the destination's database (and its own log) stands as it is
            }
            if mains.contains(name) {
                for suffix in sidecarSuffixes where names.contains(name + suffix) && !fm.fileExists(atPath: to.appendingPathComponent(name + suffix).path) { put(from.appendingPathComponent(name + suffix), to.appendingPathComponent(name + suffix)) }
            }
            put(entry, target)
        }
    }

    /// Moves to the Trash only what a finished migration copied AND nobody has changed since (same size and modification time as when it was copied), and only inside the two places it copies to. Anything
    /// the app has written since (live databases, new bookmarks) stays. The old container is not touched. Returns how many files were moved.
    @discardableResult
    static func undo(destinationHome: URL? = nil, bundleID: String = Bundle.main.bundleIdentifier ?? "com.browsersetu.mac") -> Int {
        let home = destinationHome ?? realHome()
        let recordURL = home.appendingPathComponent("Library/Application Support/BrowserSetu/\(recordName)")
        guard let data = try? Data(contentsOf: recordURL), let r = try? decoder.decode(Record.self, from: data) else { return 0 }
        let roots = [home.appendingPathComponent("Library/Application Support/BrowserSetu").path + "/", home.appendingPathComponent("Library/WebKit/\(bundleID)").path + "/"]
        var moved = 0
        for p in r.copied {
            guard roots.contains(where: { p.hasPrefix($0) }), !p.contains("/../"), let sig = r.signatures[p], sig.count == 2 else { continue }
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            guard Double((a?[.size] as? NSNumber)?.intValue ?? -2) == sig[0], ((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1) == sig[1] else { continue }
            if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)) != nil { moved += 1 }
        }
        try? FileManager.default.trashItem(at: recordURL, resultingItemURL: nil)
        return moved
    }

    /// What would be copied, without writing anything.
    static func dryRun(sourceContainer: URL, destinationHome: URL, bundleID: String) -> (files: Int, bytes: Int64) {
        var files = 0; var bytes: Int64 = 0
        let lib = sourceContainer.appendingPathComponent("Library", isDirectory: true)
        for item in items {
            let from = lib.appendingPathComponent(item.from, isDirectory: true)
            let to = destinationHome.appendingPathComponent("Library").appendingPathComponent(item.to.replacingOccurrences(of: "{id}", with: bundleID))
            guard let e = FileManager.default.enumerator(at: from, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in e {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let rel = String(url.path.dropFirst(from.path.count))
                if !FileManager.default.fileExists(atPath: to.path + rel) { files += 1; bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
        }
        return (files, bytes)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
