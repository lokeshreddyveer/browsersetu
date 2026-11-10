import Foundation

// The one description of a download, whatever engine fetches it. The coordinator owns a task's state and decides what happens next; an engine owns the transfer itself.
// Nothing here is specific to one protocol: what only one engine needs goes in `engineMetadata` (small, plain strings, never a secret).

typealias DownloadTaskID = UUID

/// Which engine a task belongs to. A string, not an enum, so a new engine adds a value without every switch in the app changing.
struct DownloadProtocolID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }

    /// A download WebKit makes (a page, a link, a file the page serves).
    static let webKit: Self = "webkit"
    /// A large file the app itself fetches in several pieces at once.
    static let httpPieces: Self = "http-pieces"
    /// A file on an FTP, FTPS or SFTP server, fetched by the app itself (DX-11).
    static let remoteFile: Self = "remote"

    /// Short, lowercase ASCII letters, digits and dashes: what a stored value must look like to be believed.
    var isValid: Bool { !rawValue.isEmpty && rawValue.count <= 32 && rawValue.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") } }
}

/// Where a task is in its life. Every change goes through `DownloadStateMachine`; nothing sets one of these directly.
enum DownloadState: String, Codable, CaseIterable, Sendable {
    case created            // known, nothing done yet
    case resolving          // asking the source what it is (name, size, whether it can resume)
    case queued             // waiting for a free place
    case scheduled          // put off until a time or until the queue is released
    case starting           // an engine has been given the task and has not yet moved bytes
    case running
    case pausing            // asked to stop and keep its place; the engine has not answered
    case paused             // stopped, place kept (resume data or a partial file)
    case resuming           // asked to carry on; the engine has not answered
    case verifying          // all bytes are here; being checked
    case retrying           // failed in a way a retry can fix; waiting out a delay
    case completed          // final
    case failed             // stopped for good; the person may try again
    case cancelled          // final: the person (or the app) abandoned it
    case recoveryRequired   // found part-way after the app was closed; needs a decision, never restarts by itself

    /// Never changes again.
    var isFinal: Bool { self == .completed || self == .cancelled }
    /// An engine may hold network or file resources for it.
    var holdsResources: Bool { [.resolving, .starting, .running, .pausing, .resuming, .verifying].contains(self) }
}

enum DownloadIntegrity: String, Codable, Sendable {
    case unknown       // nothing to compare against
    case verified      // size (or a checksum, for engines that have one) matched
    case mismatch      // it did not; the file is kept and the person is told
}

/// Why a task stopped, in plain words. Never holds the underlying error object, a header, or a URL.
struct DownloadFailureInfo: Codable, Equatable, Sendable {
    var code: String          // "NSURLErrorDomain:-1001", for diagnostics
    var reason: String        // what a person is told
    var retryable: Bool
}

/// The address a download came from, kept only as far as starting it again needs: no user name or password, no fragment.
struct DownloadSourceRef: Codable, Equatable, Sendable {
    var url: String?
    var host: String?

    init(url: URL?) {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        self.url = parts.url?.absoluteString
        self.host = url.host
    }

    init(url: String?, host: String?) { self.url = url; self.host = host }

    var asURL: URL? { url.flatMap(URL.init(string:)) }
}

struct DownloadFileRef: Codable, Equatable, Sendable {
    /// The name shown in the list.
    var filename: String
    /// Where the finished file goes (a path inside an authorised folder; checked again whenever it is loaded).
    var destinationPath: String?
    /// A partial file or folder of pieces that belongs to this task alone.
    var temporaryPath: String?
    var integrity: DownloadIntegrity = .unknown
}

struct DownloadTransfer: Codable, Equatable, Sendable {
    var totalBytes: Int64?
    var completedBytes: Int64 = 0
    /// Resume data (or an equivalent) is held, so `resumeRequested` makes sense.
    var resumeAvailable = false
}

/// The authoritative record of one download.
struct DownloadTaskRecord: Identifiable, Equatable, Sendable {
    static let currentRecordVersion = 1

    let id: DownloadTaskID
    var protocolID: DownloadProtocolID
    /// The browser profile that owns it. A task is never shown to, or touched by, another profile.
    var profile: String
    /// From a private tab: never written down.
    var isPrivate: Bool
    /// Which private session it came from (a private window's, or the one the private tabs of ordinary windows share). Only for the running process: a private record is never written down, so
    /// neither is this. Decides who may see the task in a Downloads list.
    var privateSession: UUID?
    var state: DownloadState = .created
    var priority: DownloadPriority = .normal
    /// Position among the waiting (lower goes first within a priority).
    var queueOrder: Int = 0
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var scheduledAt: Date?
    /// Scheduler state, saved in columns of their own (not in `engineMetadata`, whose room belongs to the engine). When the task joined the waiting line (so a relaunch does not reset
    /// how long it has waited), and the wall-clock time a planned retry becomes due.
    var enqueuedAt: Date?
    var retryAt: Date?
    /// Counts starts. An engine's reports carry the number they were started with; a report from an earlier one is ignored.
    var attempt: Int = 0
    var retryCount: Int = 0
    var failure: DownloadFailureInfo?
    var source: DownloadSourceRef
    var file: DownloadFileRef
    var transfer = DownloadTransfer()
    /// What only this task's engine needs, as short plain strings. Never a credential, cookie or header.
    var engineMetadata: [String: String] = [:]
    var recordVersion = DownloadTaskRecord.currentRecordVersion

    init(id: DownloadTaskID = UUID(), protocolID: DownloadProtocolID, profile: String, isPrivate: Bool = false, source: DownloadSourceRef, filename: String, now: Date = Date()) {
        self.id = id; self.protocolID = protocolID; self.profile = profile; self.isPrivate = isPrivate
        self.source = source; self.file = DownloadFileRef(filename: filename)
        self.createdAt = now; self.updatedAt = now
    }
}

enum DownloadEngineMetadata {
    static let maxEntries = 16, maxKeyLength = 48, maxValueLength = 256

    /// Counters an engine refreshes as it runs. They are worth showing, not worth keeping: when room runs short they go first, so a lasting fact (an ETag, who asked) is never what is lost.
    static let volatileKeys: Set<String> = ["connections", "pieces", "piecesDone", "piecesRetrying", "networkBytes"]

    struct Rejection: Equatable, Sendable {
        enum Reason: String, Sendable { case invalidKey, valueTooLong, overCapacity }
        var key: String
        var reason: Reason
    }

    /// What is kept and, explicitly, what is not and why. Nothing is dropped without being named.
    static func reconcile(_ metadata: [String: String]) -> (kept: [String: String], rejected: [Rejection]) {
        var rejected: [Rejection] = []
        var valid: [String: String] = [:]
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            guard !key.isEmpty, key.count <= maxKeyLength, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }) else {
                rejected.append(Rejection(key: String(key.prefix(maxKeyLength)), reason: .invalidKey)); continue
            }
            guard value.count <= maxValueLength else { rejected.append(Rejection(key: key, reason: .valueTooLong)); continue }
            valid[key] = value
        }
        guard valid.count > maxEntries else { return (valid, rejected) }
        // Lasting facts first, counters last; within each, by name so the outcome is the same every time.
        let ranked = valid.keys.sorted { a, b in
            let (va, vb) = (volatileKeys.contains(a), volatileKeys.contains(b))
            return va != vb ? !va : a < b
        }
        var kept: [String: String] = [:]
        for (index, key) in ranked.enumerated() {
            if index < maxEntries { kept[key] = valid[key] } else { rejected.append(Rejection(key: key, reason: .overCapacity)) }
        }
        return (kept, rejected)
    }

    /// Keeps what fits the limits; see `reconcile` for what is lost and why.
    static func validated(_ metadata: [String: String]) -> [String: String] { reconcile(metadata).kept }
}

/// Where a task may say its files are. A path read back from disk is believed only if it is inside one of these.
enum DownloadPathPolicy {
    static func isAuthorized(_ path: String?, roots: [URL]) -> Bool {
        guard let path, !path.isEmpty, path.hasPrefix("/") else { return false }
        let resolved = realPath(URL(fileURLWithPath: path))
        return roots.contains { root in
            let base = realPath(root)
            return resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// The path with every link followed, also for a place that does not exist yet. Foundation leaves a path alone when its last part is missing, so a new file or folder inside a linked
    /// folder (the sandbox's own Downloads folder is one) kept its unresolved spelling and looked as if it were outside the real one. Here the longest part that does exist is resolved,
    /// and the parts after it are put back on.
    static func realPath(_ url: URL, depth: Int = 0) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            // A link whose target is missing still exists as a link: it is followed to where it points (never skipped over, and never taken for a place inside the folder).
            if (try? existing.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true, depth < 16,
               let target = try? FileManager.default.destinationOfSymbolicLink(atPath: existing.path) {
                let aimed = URL(fileURLWithPath: target, relativeTo: existing.deletingLastPathComponent())
                var resolved = URL(fileURLWithPath: realPath(aimed, depth: depth + 1))
                for part in rest { resolved = resolved.appendingPathComponent(part) }
                return resolved.standardizedFileURL.path
            }
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in rest { resolved = resolved.appendingPathComponent(part) }
        return resolved.standardizedFileURL.path
    }
}
