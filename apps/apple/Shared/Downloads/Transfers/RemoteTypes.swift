import Foundation

// DX-11: remote file sources (FTP, FTPS, SFTP, WebDAV). A remote file becomes an ordinary download task (see RemoteFileRunner); the types here only describe a server, its folders and
// what can go wrong. Nothing in this file touches the network or the disk.

enum RemoteScheme: String, Codable, CaseIterable, Sendable {
    case ftp, ftps, sftp, webdav, webdavs
    var defaultPort: Int { switch self { case .ftp: 21; case .ftps: 21; case .sftp: 22; case .webdav: 80; case .webdavs: 443 } }
    var title: String { switch self { case .ftp: "FTP"; case .ftps: "FTPS"; case .sftp: "SFTP"; case .webdav: "WebDAV"; case .webdavs: "WebDAV (HTTPS)" } }
    /// Whether the connection (and so the password) is protected on the wire.
    var isEncrypted: Bool { self != .ftp && self != .webdav }
    var isWebDAV: Bool { self == .webdav || self == .webdavs }

    /// The scheme an address names, or nil for anything that is not a remote-file address. `dav://` and `davs://` are WebDAV's own names.
    init?(urlScheme: String?) {
        switch urlScheme?.lowercased() {
        case "ftp": self = .ftp
        case "ftps": self = .ftps
        case "sftp": self = .sftp
        case "dav": self = .webdav
        case "davs": self = .webdavs
        default: return nil
        }
    }
}

struct RemoteEntry: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case file, directory, symlink, other }
    var name: String
    var kind: Kind
    var size: Int64?
    var modified: Date?
    /// A link that points nowhere, or at something this account may not look at: shown, but cannot be chosen.
    var isBroken = false
    /// The server lists this as a symbolic link (`kind` says what it points at). A link is removed as a link and never entered, so deleting a folder cannot reach files outside it.
    var isLink = false
    var id: String { name }
    var isDirectory: Bool { kind == .directory }
    var isDownloadable: Bool { kind == .file && !isBroken }
}

/// A server's folder listing, read in pieces so a large folder shows up as it arrives.
protocol RemoteSession: AnyObject, Sendable {
    /// Lists `path` (absolute, "/" separated). Entries are handed over in batches; the call ends when the folder has been read or `limit` entries were seen (then `truncated` is true).
    func list(_ path: String, limit: Int, onBatch: @Sendable ([RemoteEntry]) -> Void) async throws -> (count: Int, truncated: Bool)
    /// The server's own canonical form of a path (the home folder for "." where the protocol has one).
    func canonical(_ path: String) async throws -> String
    func close()
    /// Removes one file or empty folder (never recursive: the caller removes what is inside first). Not every kind of server can.
    func remove(_ path: String, isDirectory: Bool) async throws
    /// Puts a local file at `path` (a name that does not exist yet: an existing file is never replaced). `progress` gets bytes sent so far.
    func upload(_ local: URL, to path: String, progress: @Sendable @escaping (Int64) -> Void) async throws
}

extension RemoteSession {
    func remove(_ path: String, isDirectory: Bool) async throws { throw RemoteError.unsupported("This kind of server cannot be changed from here.") }
    func upload(_ local: URL, to path: String, progress: @Sendable @escaping (Int64) -> Void) async throws { throw RemoteError.unsupported("This kind of server cannot be changed from here.") }
}

enum RemoteError: Error, Equatable, LocalizedError, Sendable {
    case invalidAddress(String)
    case unreachable(String)
    case timedOut
    case authenticationFailed
    case hostKeyUnknown(HostKeyInfo)
    case hostKeyChanged(old: [String], new: HostKeyInfo)
    case certificateRejected(String)
    case notFound
    case permissionDenied
    case unsupported(String)
    case connectionLost(String)
    case protocolViolation(String)
    case changedOnServer
    case tooLarge(String)
    case diskFull
    case failed(String)
    case alreadyExists

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let why): why
        case .unreachable(let why): "The server could not be reached: \(why)"
        case .timedOut: "The server did not answer in time."
        case .authenticationFailed: "The server refused the user name or password (or key)."
        case .hostKeyUnknown(let k): "This server is new to you. Its key fingerprint is \(k.fingerprint)."
        case .hostKeyChanged(_, let k): "The server's key has CHANGED (now \(k.fingerprint)). That can mean someone is intercepting the connection, or the server was reinstalled."
        case .certificateRejected(let why): "The server's certificate was not accepted: \(why)"
        case .notFound: "That file or folder is not on the server (any more)."
        case .permissionDenied: "The server does not allow this account to read that."
        case .unsupported(let why): why
        case .connectionLost(let why): "The connection to the server was lost\(why.isEmpty ? "." : ": \(why)")"
        case .protocolViolation(let why): "The server sent something that is not valid (\(why))."
        case .changedOnServer: "The file changed on the server while it was being downloaded."
        case .tooLarge(let why): why
        case .diskFull: "There is not enough room on this Mac for that file."
        case .failed(let why): why
        case .alreadyExists: "A file with that name is already there, so nothing was uploaded (an existing file is never replaced)."
        }
    }

    /// Worth trying again by itself (a network problem), as opposed to something only the person can fix.
    var isRetryable: Bool {
        switch self {
        case .unreachable, .timedOut, .connectionLost: true
        default: false
        }
    }
}

/// A server's host key, as the person sees it.
struct HostKeyInfo: Equatable, Sendable {
    var type: String                // "ssh-ed25519"
    var keyBase64: String
    var fingerprint: String         // "SHA256:…"
}

/// Names and paths that come from a server are not trusted: a name is one path component with nothing in it that could climb out of the folder it is saved in.
enum RemoteNames {
    static func isSafeComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 1024 else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A name for the Mac: the server's name with anything that does not belong in a file name made harmless (control characters, bidi overrides, a leading dot is kept: it is the server's file).
    static func localName(_ name: String) -> String {
        var out = String(String.UnicodeScalarView(name.unicodeScalars.filter { s in
            let v = s.value
            return !(v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || s == "/" || s == ":" || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
                     || v == 0x200E || v == 0x200F || (0x200B...0x200D).contains(v) || v == 0x2028 || v == 0x2029 || v == 0xFEFF || v == 0x061C)
        }))
        out = out.precomposedStringWithCanonicalMapping
        if out.isEmpty || out == "." || out == ".." { return "file" }
        // A file name is at most 255 bytes: cut by bytes (never in the middle of a character), keeping the ending.
        if out.utf8.count > 240 {
            let ns = out as NSString, ext = ns.pathExtension, stem = ns.deletingPathExtension
            let keepExt = ext.utf8.count <= 16 ? "." + ext : ""
            var s = stem
            while (s + keepExt).utf8.count > 240, !s.isEmpty { s.removeLast() }
            out = (s.isEmpty ? "file" : s) + keepExt
        }
        return out
    }

    /// Joins a folder path and a name from a listing. The name must be one safe component.
    static func join(_ folder: String, _ name: String) -> String? {
        guard isSafeComponent(name) else { return nil }
        return folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// The parent of an absolute path ("/" has none beyond itself).
    static func parent(of path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count <= 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")
    }
}
