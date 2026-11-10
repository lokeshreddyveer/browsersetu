import Foundation

// Phase 20: other places the same file can be fetched from. A mirror is a candidate, not a fact: a matching name or length proves nothing about the bytes. So:
//  * mirrors are USED TOGETHER only for a download of the person's own that carries a trusted whole-file SHA-256, which is checked on the finished file; if it does not match, the
//    mirrors are dropped and the file is fetched again from its first source alone;
//  * in every other case (no hash, or an address that came from a page or a Metalink file) the sources are tried ONE AT A TIME, each from the start, never mixed.
// The origin of the task is the origin of every one of its sources: adding a mirror can only ever lower it, never raise it.

struct MirrorSource: Codable, Equatable, Identifiable, Sendable {
    enum State: Codable, Equatable, Sendable { case unchecked, inUse, used, bad(String) }
    var id = UUID()
    /// May carry a signed query: used to fetch, never shown or logged. A name or password in the address is refused when it is added.
    var url: String
    var addedAt = Date()
    /// Lower is tried first.
    var priority = 1000
    var state = State.unchecked
    var bytes: Int64 = 0

    var display: String { DiagnosticRedactor.url(url) ?? (URL(string: url)?.host ?? "mirror") }
    var isUsable: Bool { if case .bad = state { return false }; return true }
}

@MainActor
final class MirrorStore: ObservableObject {
    static let maxPerTask = 8
    static let maxTasks = 2000
    static let maxFileBytes = 4_000_000

    @Published private(set) var revision = 0
    private var table: [UUID: [MirrorSource]] = [:]
    private unowned let coordinator: DownloadCoordinator
    private let file: URL?
    /// Bytes the mirrors (not the first source) delivered in the current run, per task. Not saved: it describes a run.
    private var contributed: [UUID: Int64] = [:]

    init(coordinator: DownloadCoordinator, file: URL?) {
        self.coordinator = coordinator; self.file = file
        load()
    }

    private struct Disk: Codable { var version = 1; var mirrors: [String: [MirrorSource]] }

    private func load() {
        guard let file, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= Self.maxFileBytes,
              let data = try? Data(contentsOf: file), let disk = try? JSONDecoder().decode(Disk.self, from: data), disk.version == 1 else { return }
        for (key, list) in disk.mirrors.prefix(Self.maxTasks) {
            // Only tasks this profile still has, and only what passes the same rules as adding.
            guard let id = UUID(uuidString: key), coordinator.ledger.record(id) != nil else { continue }
            table[id] = Array(list.filter { Self.parse($0.url) != nil }.prefix(Self.maxPerTask))
        }
    }

    private func save() {
        revision &+= 1
        // Tasks that are gone take their sources (which may carry signed addresses) with them.
        for key in table.keys where coordinator.ledger.record(key) == nil { table[key] = nil; contributed[key] = nil }
        guard let file, let data = try? JSONEncoder().encode(Disk(mirrors: Dictionary(uniqueKeysWithValues: table.filter { !$0.value.isEmpty }.map { ($0.key.uuidString, $0.value) }))) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// An address a mirror may have: web, no name or password, a host, of a sane length.
    nonisolated static func parse(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 4096, let url = URL(string: t), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, !t.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return url
    }

    func mirrors(of task: UUID) -> [MirrorSource] { (table[task] ?? []).sorted { ($0.priority, $0.addedAt) < ($1.priority, $1.addedAt) } }
    func usable(for task: UUID) -> [MirrorSource] { mirrors(of: task).filter(\.isUsable) }
    /// Bytes mirrors have delivered into this task's file, kept with the task so a pause or a relaunch does not forget that the file holds data from several sources.
    func bytesFromMirrors(_ task: UUID) -> Int64 { max(contributed[task] ?? 0, Int64(coordinator.ledger.record(task)?.engineMetadata["mirrorBytes"] ?? "") ?? 0) }
    /// The file is being made again from one source: nothing is owed to the mirrors any more.
    func clearContribution(_ task: UUID) { contributed[task] = nil; coordinator.ledger.update(task) { $0.engineMetadata["mirrorBytes"] = nil } }

    struct AddReport: Equatable { var added = 0, duplicates = 0, rejected: [String] = [] }

    /// Adds mirrors to a task the person has. Each is held to the rules of the task's own origin (a task from a page cannot gain a mirror on the local network), and a task that is
    /// private, finished or unknown takes none.
    @discardableResult
    func add(_ texts: [String], to task: UUID, priority: Int = 1000) -> AddReport {
        var report = AddReport()
        guard let record = coordinator.ledger.record(task), !record.isPrivate, record.protocolID == .http, !record.state.isFinal else {
            report.rejected = texts.map { _ in "This download cannot take another source." }; return report
        }
        let origin = DownloadRequestOrigin(rawValue: record.engineMetadata["origin"] ?? "") ?? .automation
        // `.automation` and `.browserExtension` tasks do not run at all; a mirror for one is held to the same page rules rather than the person's.
        let policy = HTTPRequestPolicy(origin: origin == .user ? .user : .page)
        var list = table[task] ?? []
        let primary = record.source.asURL.map(LinkClassifier.normalizedKey)
        for text in texts {
            guard let url = Self.parse(text) else { report.rejected.append("Not a web address that can be used as a source."); continue }
            do { try policy.check(url) } catch { report.rejected.append((error as? HTTPRequestPolicy.Refusal)?.reason ?? "This address is not allowed."); continue }
            let key = LinkClassifier.normalizedKey(url)
            if key == primary || list.contains(where: { LinkClassifier.normalizedKey(URL(string: $0.url)!) == key }) { report.duplicates += 1; continue }
            guard list.count < Self.maxPerTask else { report.rejected.append("A download can have at most \(Self.maxPerTask) other sources."); continue }
            list.append(MirrorSource(url: url.absoluteString, priority: priority))
            report.added += 1
        }
        table[task] = list
        if report.added > 0 { save() }
        return report
    }

    func remove(_ id: UUID, from task: UUID) { table[task]?.removeAll { $0.id == id }; save() }
    func forget(task: UUID) { table[task] = nil; contributed[task] = nil; save() }
    func setState(_ id: UUID, in task: UUID, _ state: MirrorSource.State) {
        guard let i = table[task]?.firstIndex(where: { $0.id == id }) else { return }
        table[task]?[i].state = state; save()
    }

    /// Whether this task may fetch from several sources at once. Needs the person's own request, a whole-file SHA-256 that will be checked at the end, and mirrors not already
    /// found to have served wrong data for it.
    func canCombine(_ task: UUID) -> Bool {
        guard let r = coordinator.ledger.record(task), !r.isPrivate, DownloadRequestOrigin(rawValue: r.engineMetadata["origin"] ?? "") == .user,
              r.engineMetadata["sha256"].flatMap(DownloadIntegrityCheck.normalizedDigest) != nil, r.engineMetadata["mirrorsDisabled"] != "1" else { return false }
        return !usable(for: task).isEmpty
    }

    /// The next source to try, one at a time, after the current one has failed for good. Marks it in use. Nil when none is left.
    func takeNextForFailover(_ task: UUID) -> MirrorSource? {
        guard let next = mirrors(of: task).first(where: { $0.state == .unchecked }) else { return nil }
        setState(next.id, in: task, .inUse)
        return next
    }

    /// What a combined run reported about its mirrors (keys "mir.<id>" as "state:bytes:reason"): each lands on the mirror it names.
    func apply(_ metadata: [String: String], to task: UUID) {
        let list = mirrors(of: task)
        var total: Int64 = 0
        for m in list {
            guard let value = metadata["mir.\(m.id.uuidString)"] else { continue }
            let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let bytes = Int64(parts[1]) ?? 0
            total += bytes
            if let at = table[task]?.firstIndex(where: { $0.id == m.id }) {
                table[task]?[at].bytes = bytes
                switch parts[0] {
                case "bad": table[task]?[at].state = .bad(parts.count > 2 && !parts[2].isEmpty ? parts[2] : "It gave data that could not be used.")
                case "used": table[task]?[at].state = .used
                default: table[task]?[at].state = .inUse
                }
            }
        }
        contributed[task] = max(contributed[task] ?? 0, total)
        let kept = contributed[task] ?? 0
        if kept > 0 { coordinator.ledger.update(task) { $0.engineMetadata["mirrorBytes"] = String(kept) } }
        revision &+= 1
    }
}

// MARK: - Metalink 4 (RFC 5854): a file's name, size, hash and sources

struct MetalinkFile: Equatable, Sendable {
    var name: String
    var size: Int64?
    /// Lower-case hex SHA-256 of the whole file, when the document gives one. Other hash types are not used.
    var sha256: String?
    /// Lower-case hex SHA-512 of the whole file, when the document gives one: checked after the download finishes (parallel sources are only used with a SHA-256).
    var sha512: String?
    var urls: [String]
    /// Said to the person: what was in the document that this app does not use.
    var notes: [String]
}

enum MetalinkError: Error, LocalizedError, Equatable {
    case tooLarge, notMetalink, unsafe(String), malformed(String), noFiles
    var errorDescription: String? {
        switch self {
        case .tooLarge: "That Metalink file is too large."
        case .notMetalink: "That is not a Metalink file."
        case .unsafe(let why): "That Metalink file was refused: \(why)"
        case .malformed(let why): "That Metalink file is not valid: \(why)"
        case .noFiles: "That Metalink file lists no file to download."
        }
    }
}

/// Reads a Metalink 4 description with the care a document from a stranger needs: bounded, no entities or external loads, no path tricks, only web addresses. It starts nothing.
enum MetalinkParser {
    static let maxBytes = 1_000_000
    static let maxFiles = 20
    static let maxURLs = 8
    static let maxElements = 20_000
    static let namespace = "urn:ietf:params:xml:ns:metalink"
    /// The older Metalink 3.0 format (many download sites still publish it).
    static let namespaceV3 = "http://www.metalinker.org/"

    private struct Node { var name: String; var attrs: [String: String]; var children: [Node] = []; var text = "" }
    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [Node] = [], root: Node?, count = 0, failure: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String: String]) {
            count += 1
            if count > MetalinkParser.maxElements || stack.count > 12 { failure = "too large or too deeply nested"; parser.abortParsing(); return }
            stack.append(Node(name: name, attrs: attrs))
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if !stack.isEmpty, stack[stack.count - 1].text.count < 8192 { stack[stack.count - 1].text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let n = stack.popLast() else { return }
            if stack.isEmpty { root = n } else { stack[stack.count - 1].children.append(n) }
        }
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { if failure == nil { failure = parseError.localizedDescription } }
    }

    /// RFC 5854: a file name is a relative path that does not start with "/", "./" or "../", and has no "/../" or trailing "/..". Here it must also be one plain name: the app
    /// chooses the folder, not the document.
    static func safeName(_ raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 255, !n.hasPrefix("/"), !n.hasPrefix("./"), !n.hasPrefix("../"), !n.contains("/../"), !n.hasSuffix("/.."), !n.contains("\\"), !n.contains("\0"),
              !n.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        // A subfolder in the document's name is not honoured: the file is saved under its last part.
        return DownloadFilename.sanitize(n.split(separator: "/").last.map(String.init) ?? n)
    }


    /// Metalink 3.0: `<files><file name><size/><verification><hash type/></verification><resources><url type preference/></resources></file></files>`. The same care as for version 4: only web addresses,
    /// only SHA-256 is used, a higher "preference" comes first.
    private static func parseV3(_ root: Node) throws -> [MetalinkFile] {
        guard let list = root.children.first(where: { $0.name == "files" }) else { throw MetalinkError.noFiles }
        var files: [MetalinkFile] = [], names = Set<String>()
        for node in list.children where node.name == "file" {
            guard files.count < maxFiles else { break }
            guard let rawName = node.attrs["name"], let name = safeName(rawName) else { throw MetalinkError.unsafe("a file name is not a plain relative name") }
            guard names.insert(rawName).inserted else { throw MetalinkError.malformed("two files have the same name") }
            var notes: [String] = ["This is an older Metalink (3.0) file."]
            var size: Int64?
            if let s = node.children.first(where: { $0.name == "size" })?.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                guard let v = Int64(s), v >= 0 else { throw MetalinkError.malformed("a size is not a number") }
                size = v
            }
            var sha: String?, sha512: String?
            for h in (node.children.first(where: { $0.name == "verification" })?.children ?? []) where h.name == "hash" {
                let type = (h.attrs["type"] ?? "").lowercased().replacingOccurrences(of: "-", with: "")
                let value = h.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if type == "sha256" { if value.count == 64, value.allSatisfy(\.isHexDigit) { sha = value } else { throw MetalinkError.malformed("a SHA-256 value is not 64 hex digits") } }
                else if type == "sha512" { if value.count == 128, value.allSatisfy(\.isHexDigit) { sha512 = value } else { throw MetalinkError.malformed("a SHA-512 value is not 128 hex digits") } }
                else if !type.isEmpty { notes.append("A \(type.prefix(20)) hash was ignored.") }
            }
            var urls: [(Int, String)] = []
            for u in (node.children.first(where: { $0.name == "resources" })?.children ?? []) where u.name == "url" {
                let kind = (u.attrs["type"] ?? "").lowercased()
                let text = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard kind == "http" || kind == "https" || kind.isEmpty, MirrorStore.parse(text) != nil else { if !text.isEmpty { notes.append("A source that is not a plain web address was ignored.") }; continue }
                urls.append((u.attrs["preference"].flatMap { Int($0) }.flatMap { (0...100).contains($0) ? $0 : nil } ?? 0, text))
            }
            urls.sort { $0.0 > $1.0 }
            if urls.count > maxURLs { notes.append("Only the first \(maxURLs) sources were kept."); urls = Array(urls.prefix(maxURLs)) }
            guard !urls.isEmpty else { throw MetalinkError.malformed("a file lists no usable address") }
            files.append(MetalinkFile(name: name, size: size, sha256: sha, sha512: sha512, urls: urls.map(\.1), notes: notes))
        }
        guard !files.isEmpty else { throw MetalinkError.noFiles }
        return files
    }

    static func parse(_ data: Data) throws -> [MetalinkFile] {
        guard data.count <= maxBytes else { throw MetalinkError.tooLarge }
        let bom = [UInt8](data.prefix(4))
        guard !(bom.starts(with: [0xFF, 0xFE]) || bom.starts(with: [0xFE, 0xFF]) || bom.contains(0)) else { throw MetalinkError.unsafe("it is not UTF-8") }
        let head = String(decoding: data, as: UTF8.self).lowercased()
        guard !head.contains("<!doctype"), !head.contains("<!entity") else { throw MetalinkError.unsafe("it contains a document type declaration") }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let builder = Builder(); parser.delegate = builder
        _ = parser.parse()
        if let f = builder.failure { throw MetalinkError.malformed(f) }
        guard let root = builder.root, root.name == "metalink" else { throw MetalinkError.notMetalink }
        if root.attrs["xmlns"] == namespaceV3 { return try parseV3(root) }
        guard root.attrs["xmlns"] == namespace else { throw MetalinkError.notMetalink }
        var files: [MetalinkFile] = []
        var names = Set<String>()
        for node in root.children where node.name == "file" {
            guard files.count < maxFiles else { break }
            guard let rawName = node.attrs["name"], let name = safeName(rawName) else { throw MetalinkError.unsafe("a file name is not a plain relative name") }
            guard names.insert(rawName).inserted else { throw MetalinkError.malformed("two files have the same name") }
            var notes: [String] = []
            var size: Int64?
            if let s = node.children.first(where: { $0.name == "size" })?.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                guard let v = Int64(s), v >= 0 else { throw MetalinkError.malformed("a size is not a number") }
                size = v
            }
            var sha: String?, sha512: String?
            for h in node.children where h.name == "hash" {
                // A hash with a type covers the whole file. Only SHA-256 is used (MD-family hashes are not trustworthy); others are noted.
                guard let type = h.attrs["type"]?.lowercased() else { continue }
                let value = h.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if type == "sha-256" { if value.count == 64, value.allSatisfy(\.isHexDigit) { sha = value } else { throw MetalinkError.malformed("a SHA-256 value is not 64 hex digits") } }
                else if type == "sha-512" { if value.count == 128, value.allSatisfy(\.isHexDigit) { sha512 = value } else { throw MetalinkError.malformed("a SHA-512 value is not 128 hex digits") } }
                else { notes.append("A \(type.prefix(20)) hash was ignored.") }
            }
            if node.children.contains(where: { $0.name == "pieces" }) { notes.append("Hashes of parts of the file were ignored; the whole file is checked at the end.") }
            if node.children.contains(where: { $0.name == "metaurl" }) { notes.append("A torrent link was ignored.") }
            var urls: [(Int, String)] = []
            for u in node.children where u.name == "url" {
                let text = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard MirrorStore.parse(text) != nil else { notes.append("An address that is not a plain web address was ignored."); continue }
                let p = u.attrs["priority"].flatMap { Int($0) }.flatMap { (1...999_999).contains($0) ? $0 : nil } ?? 999_999
                urls.append((p, text))
            }
            urls.sort { $0.0 < $1.0 }
            if urls.count > maxURLs { notes.append("Only the first \(maxURLs) sources were kept."); urls = Array(urls.prefix(maxURLs)) }
            guard !urls.isEmpty else { throw MetalinkError.malformed("a file lists no usable address") }
            files.append(MetalinkFile(name: name, size: size, sha256: sha, sha512: sha512, urls: urls.map(\.1), notes: notes))
        }
        guard !files.isEmpty else { throw MetalinkError.noFiles }
        return files
    }
}
