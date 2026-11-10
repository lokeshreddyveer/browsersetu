import CryptoKit
import Darwin
import Foundation

// MARK: Torrent creation (BEP 3, BEP 47, BEP 52)
//
// Pure Swift, no UI. The steps are separate so the sheet can show everything BEFORE any hashing:
//   1. `plan(root:)`   lists the files safely (never follows a symbolic link) and checks every name.
//   2. `layout(plan:options:)`  validates the piece size and options and returns the piece count and an estimate of the metadata size.
//   3. `create(plan:options:progress:)`  reads every file once in 1 MiB chunks (memory stays bounded whatever the size), builds the metainfo, checks it again independently, and returns it.
//   4. `write(_:named:in:)`  saves it without ever replacing an existing file.
//
// Layout rules come from the formats, not from this file: v1 `pieces` run across file boundaries; v2 uses per-file Merkle trees (see Merkle.swift); a hybrid torrent carries both in one info
// dictionary, with BEP 47 padding files so that every file starts on a piece boundary (a padding file follows each file whose size is not a multiple of the piece length, never the last one).

struct TorrentCreator: Sendable {
    enum Format: String, CaseIterable, Sendable, Identifiable {
        case v1, v2, hybrid
        var id: String { rawValue }
        var title: String { switch self { case .v1: "Version 1"; case .v2: "Version 2"; case .hybrid: "Hybrid (v1 + v2)" } }
        var hasV1: Bool { self != .v2 }
        var hasV2: Bool { self != .v1 }
    }

    enum PieceSize: Equatable, Sendable { case automatic, fixed(Int64) }

    struct Options: Sendable {
        var format: Format = .v1
        var pieceSize: PieceSize = .automatic
        /// Tracker addresses in tiers (BEP 12). Each inner array is one tier.
        var trackerTiers: [[String]] = []
        var webSeeds: [String] = []
        var isPrivate = false
        var comment = ""
        var creationDate: Date? = nil
        var createdBy: String? = "Browser Setu"
        init() {}
    }

    struct Entry: Sendable, Equatable {
        var components: [String]
        var url: URL
        var size: Int64
        var modified: Date?
        var relativePath: String { components.joined(separator: "/") }
    }

    struct Skipped: Sendable, Equatable { var path: String; var reason: String }

    struct Plan: Sendable {
        var root: URL
        var name: String
        var isFolder: Bool
        var files: [Entry]
        var skipped: [Skipped]
        var totalBytes: Int64
        var fileCount: Int { files.count }
    }

    struct Layout: Sendable, Equatable {
        var format: Format
        var pieceLength: Int64
        var pieceCount: Int
        var paddingBytes: Int64
        var estimatedMetadataBytes: Int
        var automatic: Bool
    }

    struct Progress: Sendable {
        var bytesDone: Int64
        var totalBytes: Int64
        var currentFile: String
        var filesDone: Int
        var fraction: Double { totalBytes > 0 ? min(1, Double(bytesDone) / Double(totalBytes)) : 0 }
    }

    struct Summary: Sendable {
        var name: String
        var format: Format
        var totalBytes: Int64
        var fileCount: Int
        var pieceLength: Int64
        var pieceCount: Int
        var isPrivate: Bool
        var skipped: [Skipped]
        var suggestedFileName: String
    }

    struct CreatedTorrent: Sendable {
        var data: Data
        var infoHashV1: Data?
        var infoHashV2: Data?
        var magnet: String
        var summary: Summary
    }

    enum Failure: Error, Equatable, LocalizedError {
        case symlinkRoot, notFound, emptyFolder, noData
        case unsafeName(String), duplicateName(String), tooManyFiles, pathTooLong(String), tooDeep(String), tooLarge
        case unreadable(String), changed(String)
        case invalidPieceLength(String), tooManyPieces(Int), metadataTooLarge(Int)
        case badTracker(String), tooManyTrackers, badWebSeed(String), badComment
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .symlinkRoot: "The chosen item is a shortcut (symbolic link). Choose the real file or folder."
            case .notFound: "The chosen file or folder could not be found."
            case .emptyFolder: "The folder has no files to share."
            case .noData: "Every file is empty, so there is nothing to share."
            case .unsafeName(let n): "“\(n.prefix(60))” has a name that cannot be used in a torrent (separators, control characters or a name that is too long)."
            case .duplicateName(let n): "Two items would have the same name in a torrent (“\(n.prefix(60))”). Rename one of them."
            case .tooManyFiles: "There are more than \(TorrentMetainfo.Limit.maxFiles) files, which is more than Browser Setu allows in one torrent."
            case .pathTooLong(let n): "The path “\(n.prefix(60))” is too long for a torrent."
            case .tooDeep(let n): "“\(n.prefix(60))” is nested in too many folders for this torrent format."
            case .tooLarge: "The total size is larger than a torrent can describe."
            case .unreadable(let n): "“\(n.prefix(60))” could not be read. Nothing was created."
            case .changed(let n): "“\(n.prefix(60))” changed while it was being read. Nothing was created; try again when the files are not in use."
            case .invalidPieceLength(let why): "That piece size cannot be used: \(why)."
            case .tooManyPieces(let n): "That would make \(n) pieces, more than the limit of \(TorrentMetainfo.Limit.maxPieces). Choose a larger piece size."
            case .metadataTooLarge(let n): "The torrent file would be about \(n / 1024) KiB, over the \(TorrentMetainfo.Limit.maxInfoBytes / 1024) KiB limit. Choose a larger piece size or fewer files."
            case .badTracker(let t): "“\(t.prefix(80))” is not a tracker address (it must start with http://, https:// or udp://)."
            case .tooManyTrackers: "At most \(TorrentMetainfo.Limit.maxTrackers) trackers can be used."
            case .badWebSeed(let t): "“\(t.prefix(80))” is not a web seed address (it must start with http:// or https://)."
            case .badComment: "The comment is too long (at most 1000 bytes)."
            case .validationFailed(let why): "The torrent that was built did not pass its own check (\(why)), so it was not saved."
            }
        }
    }

    static let chunkSize = 1 << 20
    static let maxPieceLength: Int64 = 64 * 1024 * 1024
    static let automaticMaxPieceLength: Int64 = 16 * 1024 * 1024
    /// The nesting limit for the version 2 file tree (each folder level is one dictionary level and the readers cap nesting).
    static let maxV2PathDepth = 8
    static let targetMaxPieces = 2500

    /// Test seam: called after each chunk of each file is read.
    var chunkHook: (@Sendable (_ relativePath: String, _ bytesIntoFile: Int64) -> Void)? = nil

    init() {}

    // MARK: Piece size

    /// Every piece length the person may choose: powers of two from 16 KiB to 64 MiB.
    static var validPieceLengths: [Int64] {
        var out: [Int64] = [], n = TorrentMetainfo.Limit.minPieceLength
        while n <= maxPieceLength { out.append(n); n *= 2 }
        return out
    }

    /// The automatic choice: the smallest power of two, between 16 KiB and 16 MiB, that gives at most 2500 pieces (so 1250 to 2500 pieces for anything from 40 MiB up). Few enough pieces keep the
    /// metadata small and the trackers' and peers' bookkeeping cheap; small enough pieces keep re-checking and partial sharing granular. A small total gets 16 KiB, the smallest allowed.
    static func recommendedPieceLength(totalBytes: Int64) -> Int64 {
        var p = TorrentMetainfo.Limit.minPieceLength
        while p < automaticMaxPieceLength, (totalBytes + p - 1) / p > Int64(targetMaxPieces) { p *= 2 }
        return p
    }

    static func describe(_ length: Int64) -> String {
        if length >= 1 << 20 { return "\(length >> 20) MiB" }
        return "\(length >> 10) KiB"
    }

    // MARK: Trackers and web seeds (text helpers)

    /// One address per line; a blank line starts a new tier.
    static func parseTrackerText(_ text: String) -> [[String]] {
        var tiers: [[String]] = [[]]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if !(tiers.last ?? []).isEmpty { tiers.append([]) } } else { tiers[tiers.count - 1].append(line) }
        }
        return tiers.filter { !$0.isEmpty }
    }

    static func parseLines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func validate(_ options: Options) throws {
        var count = 0
        for tier in options.trackerTiers {
            for text in tier {
                count += 1
                guard let url = URL(string: text), text.utf8.count <= TorrentMetainfo.Limit.maxTrackerURL, let scheme = url.scheme?.lowercased(), ["http", "https", "udp"].contains(scheme),
                      url.host?.isEmpty == false else { throw Failure.badTracker(text) }
            }
        }
        guard count <= TorrentMetainfo.Limit.maxTrackers else { throw Failure.tooManyTrackers }
        for text in options.webSeeds {
            guard let url = URL(string: text), text.utf8.count <= TorrentMetainfo.Limit.maxTrackerURL, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false else { throw Failure.badWebSeed(text) }
        }
        guard options.comment.utf8.count <= 1000 else { throw Failure.badComment }
    }

    // MARK: 1. Plan

    /// Lists what would go into the torrent. Never follows a symbolic link (a link inside the folder is listed in `skipped`; a link as the chosen item is refused).
    func plan(root: URL, skipDSStore: Bool = true, skipHiddenFiles: Bool = false) throws -> Plan {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        guard let attrs = try? fm.attributesOfItem(atPath: rootPath) else { throw Failure.notFound }
        let type = attrs[.type] as? FileAttributeType
        if type == .typeSymbolicLink { throw Failure.symlinkRoot }
        guard let rawName = (rootPath as NSString).lastPathComponent as String?, let name = TorrentMetainfo.safeComponent(rawName) else { throw Failure.unsafeName((rootPath as NSString).lastPathComponent) }

        var files: [Entry] = []
        var skipped: [Skipped] = []
        var total: Int64 = 0

        if type == .typeRegular {
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard fm.isReadableFile(atPath: rootPath) else { throw Failure.unreadable(name) }
            files = [Entry(components: [name], url: URL(fileURLWithPath: rootPath), size: size, modified: attrs[.modificationDate] as? Date)]
            return Plan(root: URL(fileURLWithPath: rootPath), name: name, isFolder: false, files: files, skipped: [], totalBytes: size)
        }
        guard type == .typeDirectory else { throw Failure.notFound }

        var seen = Set<String>()
        var stack: [(path: String, comps: [String])] = [(rootPath, [])]
        while let (dirPath, comps) = stack.popLast() {
            let names: [String]
            do { names = try fm.contentsOfDirectory(atPath: dirPath) } catch { throw Failure.unreadable((dirPath as NSString).lastPathComponent) }
            for raw in names {
                let display = (comps + [raw]).joined(separator: "/")
                if skipDSStore, raw == ".DS_Store" { skipped.append(Skipped(path: display, reason: "Finder bookkeeping file")); continue }
                if skipHiddenFiles, raw.hasPrefix(".") { skipped.append(Skipped(path: display, reason: "hidden file")); continue }
                guard let safe = TorrentMetainfo.safeComponent(raw) else { throw Failure.unsafeName(raw) }
                let childPath = dirPath + "/" + raw
                // The child must stay inside the chosen folder (a name can never contain a separator, but this is checked anyway).
                guard childPath.hasPrefix(rootPath + "/"), (childPath as NSString).deletingLastPathComponent == dirPath else { throw Failure.unsafeName(raw) }
                guard let a = try? fm.attributesOfItem(atPath: childPath) else { throw Failure.unreadable(display) }
                let t = a[.type] as? FileAttributeType
                if t == .typeSymbolicLink { skipped.append(Skipped(path: display, reason: "symbolic link (not followed)")); continue }
                if t == .typeDirectory { stack.append((childPath, comps + [safe])); continue }
                guard t == .typeRegular else { skipped.append(Skipped(path: display, reason: "not a regular file")); continue }
                guard fm.isReadableFile(atPath: childPath) else { throw Failure.unreadable(display) }
                let path = comps + [safe]
                guard path.count <= TorrentMetainfo.Limit.maxPathDepth else { throw Failure.tooDeep(display) }
                guard path.joined(separator: "/").utf8.count <= TorrentMetainfo.Limit.maxPathBytes else { throw Failure.pathTooLong(display) }
                guard seen.insert(path.joined(separator: "/").lowercased().precomposedStringWithCanonicalMapping).inserted else { throw Failure.duplicateName(display) }
                let size = (a[.size] as? NSNumber)?.int64Value ?? 0
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow, sum <= TorrentMetainfo.Limit.maxTotal else { throw Failure.tooLarge }
                total = sum
                files.append(Entry(components: path, url: URL(fileURLWithPath: childPath), size: size, modified: a[.modificationDate] as? Date))
                guard files.count <= TorrentMetainfo.Limit.maxFiles else { throw Failure.tooManyFiles }
            }
        }
        guard !files.isEmpty else { throw Failure.emptyFolder }
        files.sort { Self.pathLess($0.components, $1.components) }
        return Plan(root: URL(fileURLWithPath: rootPath), name: name, isFolder: true, files: files, skipped: skipped.sorted { $0.path < $1.path }, totalBytes: total)
    }

    /// Component-wise comparison by raw UTF-8 bytes: the order a v2 file tree is traversed in, and the order the v1 list uses.
    static func pathLess(_ a: [String], _ b: [String]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8)) }
        return a.count < b.count
    }

    // MARK: 2. Layout

    /// Bytes of padding a hybrid torrent adds after each file that does not end on a piece boundary (not after the last file).
    static func paddingSizes(_ sizes: [Int64], pieceLength: Int64) -> [Int64] {
        sizes.enumerated().map { i, size in (i < sizes.count - 1 && size % pieceLength != 0) ? pieceLength - size % pieceLength : 0 }
    }

    func layout(plan: Plan, options: Options) throws -> Layout {
        try Self.validate(options)
        guard plan.totalBytes > 0 else { throw Failure.noData }
        let automatic: Bool
        let p: Int64
        switch options.pieceSize {
        case .automatic: automatic = true; p = Self.recommendedPieceLength(totalBytes: plan.totalBytes)
        case .fixed(let n):
            automatic = false; p = n
            guard Self.validPieceLengths.contains(n) else { throw Failure.invalidPieceLength("it must be a power of two from 16 KiB to 64 MiB") }
        }
        if options.format.hasV2, let deep = plan.files.first(where: { $0.components.count > Self.maxV2PathDepth }) { throw Failure.tooDeep(deep.relativePath) }
        let padding = options.format == .hybrid ? Self.paddingSizes(plan.files.map(\.size), pieceLength: p) : []
        let padTotal = padding.reduce(0, +)
        guard plan.files.count + padding.filter({ $0 > 0 }).count <= TorrentMetainfo.Limit.maxFiles else { throw Failure.tooManyFiles }          // padding entries are files of the torrent too
        let v1Pieces = Int((plan.totalBytes + padTotal + p - 1) / p)
        let v2Pieces = plan.files.reduce(0) { $0 + Int(($1.size + p - 1) / p) }
        let count = options.format.hasV1 ? v1Pieces : v2Pieces
        guard count <= TorrentMetainfo.Limit.maxPieces else { throw Failure.tooManyPieces(count) }

        var est = 1024 + options.comment.utf8.count
        for t in options.trackerTiers.joined() { est += t.utf8.count + 12 }
        for w in options.webSeeds { est += w.utf8.count + 12 }
        if options.format.hasV1 {
            est += v1Pieces * 20
            if plan.isFolder { for f in plan.files { est += 40 + f.components.reduce(0) { $0 + $1.utf8.count + 5 } } }
            est += padding.filter { $0 > 0 }.count * 60
        }
        if options.format.hasV2 {
            for f in plan.files {
                est += 100 + f.components.reduce(0) { $0 + $1.utf8.count + 10 }
                if f.size > p { est += 40 + Int((f.size + p - 1) / p) * 32 }
            }
        }
        guard est <= TorrentMetainfo.Limit.maxInfoBytes else { throw Failure.metadataTooLarge(est) }
        return Layout(format: options.format, pieceLength: p, pieceCount: count, paddingBytes: padTotal, estimatedMetadataBytes: est, automatic: automatic)
    }

    // MARK: 3. Create

    func create(plan: Plan, options: Options, progress: (@Sendable (Progress) -> Void)? = nil) async throws -> CreatedTorrent {
        let creator = self
        let work = Task.detached(priority: .userInitiated) { try creator.createSync(plan: plan, options: options, progress: progress) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// Synchronous body of `create`; checks `Task.isCancelled` between chunks, so it must run inside a task to be cancellable.
    func createSync(plan: Plan, options: Options, progress: (@Sendable (Progress) -> Void)? = nil) throws -> CreatedTorrent {
        let lay = try layout(plan: plan, options: options)
        let p = lay.pieceLength
        let format = options.format
        let hashed = try hashContent(plan: plan, pieceLength: p, format: format, progress: progress)

        // ---- info dictionary
        var info: [(Data, BNode)] = []
        func put(_ key: String, _ value: BNode) { info.append((Data(key.utf8), value)) }
        put("name", .str(plan.name))
        put("piece length", .int(p))
        if options.isPrivate { put("private", .int(1)) }
        let sizes = plan.files.map(\.size)
        let padding = format == .hybrid ? Self.paddingSizes(sizes, pieceLength: p) : []
        if format.hasV1 {
            put("pieces", .bytes(hashed.pieces))
            if plan.isFolder {
                var list: [BNode] = []
                for (i, f) in plan.files.enumerated() {
                    list.append(.dict([(Data("length".utf8), .int(f.size)), (Data("path".utf8), .list(f.components.map { .str($0) }))]))
                    if format == .hybrid, padding[i] > 0 {
                        list.append(.dict([(Data("attr".utf8), .str("p")), (Data("length".utf8), .int(padding[i])), (Data("path".utf8), .list([.str(".pad"), .str(String(padding[i]))]))]))
                    }
                }
                put("files", .list(list))
            } else {
                put("length", .int(plan.totalBytes))
            }
        }
        var layers: [(Data, BNode)] = []
        if format.hasV2 {
            put("meta version", .int(2))
            let tree = TreeNode()
            for (i, f) in plan.files.enumerated() {
                var meta: [(Data, BNode)] = [(Data("length".utf8), .int(f.size))]
                if let root = hashed.v2[i].root { meta.append((Data("pieces root".utf8), .bytes(root))) }
                if let layer = hashed.v2[i].layer, let root = hashed.v2[i].root, !layers.contains(where: { $0.0 == root }) { layers.append((root, .bytes(layer))) }
                tree.insert(f.components, meta: .dict(meta))
            }
            put("file tree", tree.node)
        }
        let infoNode = BNode.dict(info)
        let infoBytes = infoNode.encoded
        guard infoBytes.count <= TorrentMetainfo.Limit.maxInfoBytes else { throw Failure.metadataTooLarge(infoBytes.count) }

        // ---- outer dictionary
        var top: [(Data, BNode)] = [(Data("info".utf8), infoNode)]
        func add(_ key: String, _ value: BNode) { top.append((Data(key.utf8), value)) }
        let tiers = options.trackerTiers.filter { !$0.isEmpty }
        if let first = tiers.first?.first {
            add("announce", .str(first))
            add("announce-list", .list(tiers.map { .list($0.map { .str($0) }) }))
        }
        if !options.comment.isEmpty { add("comment", .str(options.comment)) }
        if let by = options.createdBy { add("created by", .str(by)) }
        if let date = options.creationDate { add("creation date", .int(Int64(date.timeIntervalSince1970))) }
        if !layers.isEmpty { add("piece layers", .dict(layers)) }
        if !options.webSeeds.isEmpty { add("url-list", .list(options.webSeeds.map { .str($0) })) }
        let data = BNode.dict(top).encoded

        let v1 = format.hasV1 ? Data(Insecure.SHA1.hash(data: infoBytes)) : nil
        let v2 = format.hasV2 ? Data(SHA256.hash(data: infoBytes)) : nil
        let created = CreatedTorrent(
            data: data, infoHashV1: v1, infoHashV2: v2,
            magnet: Self.magnet(v1: v1, v2: v2, name: plan.name, trackers: tiers.flatMap { $0 }, webSeeds: options.webSeeds),
            summary: Summary(name: plan.name, format: format, totalBytes: plan.totalBytes, fileCount: plan.fileCount, pieceLength: p, pieceCount: lay.pieceCount, isPrivate: options.isPrivate,
                             skipped: plan.skipped, suggestedFileName: Self.fileNameStem(plan.name) + ".torrent"))
        try Self.verify(created, plan: plan, padding: padding, pieces: hashed.pieces, pieceLength: p)
        return created
    }

    // MARK: Hashing

    private struct FileV2 { var root: Data?; var layer: Data? }
    private struct Hashed { var pieces: Data; var v2: [FileV2] }

    private func hashContent(plan: Plan, pieceLength p: Int64, format: Format, progress: (@Sendable (Progress) -> Void)?) throws -> Hashed {
        let per = Merkle.blocksPerPiece(p)
        let pad = format == .hybrid ? Self.paddingSizes(plan.files.map(\.size), pieceLength: p) : []
        var pieces = Data()
        var sha1 = Insecure.SHA1()
        var inPiece: Int64 = 0
        var v2: [FileV2] = []
        var done: Int64 = 0

        func feedV1(_ bytes: Data) {
            var off = bytes.startIndex
            while off < bytes.endIndex {
                let take = Int(min(Int64(bytes.endIndex - off), p - inPiece))
                sha1.update(data: bytes[off..<(off + take)])
                inPiece += Int64(take); off += take
                if inPiece == p { pieces.append(Data(sha1.finalize())); sha1 = Insecure.SHA1(); inPiece = 0 }
            }
        }

        for (index, entry) in plan.files.enumerated() {
            try Task.checkCancellation()
            let path = entry.relativePath
            var leaves: [Data] = []
            var roots: [Data] = []
            let long = entry.size > p
            var read: Int64 = 0
            if entry.size > 0 {
                // Opened without following a link (and without blocking on a pipe swapped in after listing); what was opened must be the regular file that was listed, and must still be the
                // same file, unchanged, once it is read.
                let fd = Darwin.open(entry.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw Failure.unreadable(path) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var opened = stat()
                guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG, Int64(opened.st_size) == entry.size else { throw Failure.changed(path) }
                while true {
                    try Task.checkCancellation()
                    var chunk = Data()
                    do {
                        while chunk.count < Self.chunkSize {
                            guard let part = try handle.read(upToCount: Self.chunkSize - chunk.count), !part.isEmpty else { break }
                            chunk.append(part)
                        }
                    } catch { throw Failure.unreadable(path) }
                    if chunk.isEmpty { break }
                    read += Int64(chunk.count)
                    guard read <= entry.size else { throw Failure.changed(path) }
                    if format.hasV1 { feedV1(chunk) }
                    if format.hasV2 {
                        var o = chunk.startIndex
                        while o < chunk.endIndex {
                            let e = min(o + Merkle.blockSize, chunk.endIndex)
                            leaves.append(Data(SHA256.hash(data: chunk[o..<e])))
                            o = e
                            if long, leaves.count == per {
                                guard let r = Merkle.root(of: leaves, paddedTo: per) else { throw Failure.validationFailed("piece root") }
                                roots.append(r); leaves.removeAll(keepingCapacity: true)
                            }
                        }
                    }
                    done += Int64(chunk.count)
                    progress?(Progress(bytesDone: done, totalBytes: plan.totalBytes, currentFile: path, filesDone: index))
                    chunkHook?(path, read)
                    if chunk.count < Self.chunkSize { break }
                }
                guard read == entry.size else { throw Failure.changed(path) }
                var after = stat(), onDisk = stat()
                guard fstat(fd, &after) == 0, lstat(entry.url.path, &onDisk) == 0,
                      after.st_size == opened.st_size, after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec, after.st_ino == opened.st_ino,
                      onDisk.st_ino == opened.st_ino, onDisk.st_dev == opened.st_dev, (onDisk.st_mode & S_IFMT) == S_IFREG else { throw Failure.changed(path) }
            }
            // The file must be as it was when it was listed.
            guard let a = try? FileManager.default.attributesOfItem(atPath: entry.url.path), (a[.size] as? NSNumber)?.int64Value == entry.size, (a[.modificationDate] as? Date) == entry.modified else {
                throw Failure.changed(path)
            }
            if format.hasV2 {
                if entry.size == 0 { v2.append(FileV2(root: nil, layer: nil)) }
                else if long {
                    if !leaves.isEmpty { guard let r = Merkle.root(of: leaves, paddedTo: per) else { throw Failure.validationFailed("piece root") }; roots.append(r) }
                    guard let root = Merkle.rootOfPieceLayer(roots, pieceLength: p) else { throw Failure.validationFailed("file root") }
                    v2.append(FileV2(root: root, layer: roots.reduce(Data(), +)))
                } else {
                    guard let root = Merkle.fileRoot(leaves: leaves, pieceLength: p) else { throw Failure.validationFailed("file root") }
                    v2.append(FileV2(root: root, layer: nil))
                }
            }
            if format == .hybrid, pad[index] > 0 {
                var left = pad[index]
                let zeros = Data(count: Int(min(left, Int64(Self.chunkSize))))
                while left > 0 { let n = Int(min(left, Int64(zeros.count))); feedV1(zeros.prefix(n)); left -= Int64(n) }
            }
        }
        if format.hasV1, inPiece > 0 { pieces.append(Data(sha1.finalize())) }
        return Hashed(pieces: pieces, v2: v2)
    }

    // MARK: Independent check

    /// Reads the finished bytes back. v1 and hybrid go through the app's own parser; the v2 parts are re-derived here with Merkle from the dictionary alone, never from the structures used to build it.
    private static func verify(_ made: CreatedTorrent, plan: Plan, padding: [Int64], pieces: Data, pieceLength p: Int64) throws {
        func fail(_ why: String) -> Failure { .validationFailed(why) }
        let format = made.summary.format
        let limits = BencodeDecoder.Limits(maxBytes: made.data.count + 1, maxDepth: 24, maxValues: 4_000_000, maxStringBytes: made.data.count + 1, binaryKeys: true)
        let decoded: BencodeDecoder.Decoded
        do { decoded = try BencodeDecoder.decode(made.data, limits: limits, rawKeys: ["info"]) } catch { throw fail("it cannot be read back") }
        guard let root = decoded.value.dict, let info = root["info"]?.dict, let range = decoded.rawRanges["info"] else { throw fail("no info section") }
        let rawInfo = made.data.subdata(in: range)
        if format.hasV1 {
            guard Data(Insecure.SHA1.hash(data: rawInfo)) == made.infoHashV1 else { throw fail("version 1 info hash") }
            let parsed: TorrentMetainfo
            do { parsed = try TorrentMetainfo.parse(made.data) } catch { throw fail("the app's parser refused it: \((error as? LocalizedError)?.errorDescription ?? "unknown")") }
            guard parsed.infoHash == made.infoHashV1, parsed.pieceLength == p, parsed.name == plan.name, parsed.pieceHashes.reduce(Data(), +) == pieces else { throw fail("version 1 fields differ") }
            guard parsed.totalLength == plan.totalBytes + padding.reduce(0, +) else { throw fail("version 1 length") }
            let real = parsed.files.filter { $0.path.first != ".pad" }
            guard real.count == plan.files.count, zip(real, plan.files).allSatisfy({ $0.path == $1.components && $0.length == $1.size }) else { throw fail("version 1 file list") }
            if format == .hybrid {
                // Padding exactly per BEP 47: a pad file after each file not ending on a piece boundary, none after the last.
                var expected: [(String, Int64)] = []
                for (i, f) in plan.files.enumerated() {
                    expected.append((f.relativePath, f.size))
                    if plan.isFolder, padding[i] > 0 { expected.append((".pad/\(padding[i])", padding[i])) }
                }
                guard plan.isFolder == false || (parsed.files.count == expected.count && zip(parsed.files, expected).allSatisfy { $0.relativePath == $1.0 && $0.length == $1.1 }) else { throw fail("padding files") }
                if plan.isFolder {
                    guard let list = info["files"]?.list else { throw fail("padding files") }
                    for entry in list { let isPad = entry.dict?["path"]?.list?.first?.string == ".pad"; guard (entry.dict?["attr"]?.string == "p") == isPad else { throw fail("padding attribute") } }
                }
            }
        }
        if format.hasV2 {
            guard Data(SHA256.hash(data: rawInfo)) == made.infoHashV2 else { throw fail("version 2 info hash") }
            guard info["meta version"]?.int == 2, info["piece length"]?.int == p, Merkle.validPieceLength(p), info["name"]?.string == plan.name, let tree = info["file tree"]?.dict else { throw fail("version 2 fields") }
            let layerDict = root["piece layers"]?.dict ?? [:]
            func keyString(_ d: Data) -> String { String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? "" }
            // Walk the tree in order, collecting (path, length, root).
            var found: [(path: [String], length: Int64, root: Data?)] = []
            func walk(_ dict: [String: Bencode], _ path: [String]) throws {
                for key in dict.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                    guard key.isEmpty == false, let child = dict[key]?.dict else { throw fail("tree shape") }
                    if let leaf = child[""]?.dict {
                        guard child.count == 1, let len = leaf["length"]?.int, len >= 0 else { throw fail("leaf") }
                        found.append((path + [key], len, leaf["pieces root"]?.data))
                    } else { try walk(child, path + [key]) }
                }
            }
            do { try walk(tree, []) } catch let f as Failure { throw f } catch { throw fail("tree") }
            if !plan.isFolder { guard tree.count == 1, found.count == 1, found[0].path == [plan.name] else { throw fail("single file tree") } }
            guard found.count == plan.files.count else { throw fail("version 2 file count") }
            var usedLayers = 0
            for (got, want) in zip(found, plan.files) {
                guard got.path == want.components, got.length == want.size else { throw fail("version 2 file \(want.relativePath)") }
                if want.size == 0 { guard got.root == nil else { throw fail("empty file has a root") }; continue }
                guard let r = got.root, r.count == 32 else { throw fail("missing root for \(want.relativePath)") }
                if want.size > p {
                    guard let layer = layerDict[keyString(r)]?.data, Merkle.layerMatches(layer, fileLength: want.size, pieceLength: p, piecesRoot: r) else { throw fail("piece layer for \(want.relativePath)") }
                    usedLayers += 1
                } else if layerDict[keyString(r)] != nil, !found.contains(where: { $0.root == r && $0.length > p }) { throw fail("unexpected layer") }
            }
            let longRoots = Set(found.filter { $0.length > p }.compactMap(\.root))
            guard layerDict.count == longRoots.count, usedLayers >= longRoots.count else { throw fail("piece layers do not match the long files") }
        }
    }

    // MARK: Magnet

    static func magnet(v1: Data?, v2: Data?, name: String, trackers: [String], webSeeds: [String]) -> String {
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        var parts: [String] = []
        if let v1 { parts.append("xt=urn:btih:" + hex(v1)) }
        if let v2 { parts.append("xt=urn:btmh:1220" + hex(v2)) }
        parts.append("dn=" + encode(name))
        for t in trackers { parts.append("tr=" + encode(t)) }
        for w in webSeeds { parts.append("ws=" + encode(w)) }
        return "magnet:?" + parts.joined(separator: "&")
    }

    private static func encode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E { out.append(Character(UnicodeScalar(byte))) }
            else { out += String(format: "%%%02X", byte) }
        }
        return out
    }

    // MARK: 4. Writing

    static func fileNameStem(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Torrent" : cleaned
    }

    /// Saves `data` as `<name>` in `directory` atomically and never replaces an existing file: if the name is taken, "name 2.torrent", "name 3.torrent" and so on are tried. Returns the file written.
    @discardableResult
    static func write(_ data: Data, named fileName: String, in directory: URL) throws -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        for n in 1...10_000 {
            let candidate = n == 1 ? fileName : (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            let url = directory.appendingPathComponent(candidate)
            // Preferred: write a temporary file beside the target, then rename it with RENAME_EXCL (atomic, and it fails rather than replace anything).
            let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            if (try? data.write(to: temp)) != nil {
                let result = renamex_np(temp.path, url.path, UInt32(RENAME_EXCL))
                if result == 0 { return url }
                let code = errno
                try? FileManager.default.removeItem(at: temp)
                if code == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            // The sandbox may allow only the exact file a save panel returned: create it exclusively instead.
            do { try data.write(to: url, options: [.withoutOverwriting]); return url }
            catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) { continue }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

// MARK: Canonical bencoding (raw-byte binary values and keys)

/// The app's `Bencode` has text-only dictionary keys, but a v2 `piece layers` dictionary is keyed by 32 raw bytes. This small encoder keeps keys as bytes and sorts them by raw byte value.
private indirect enum BNode {
    case int(Int64)
    case bytes(Data)
    case list([BNode])
    case dict([(Data, BNode)])

    static func str(_ s: String) -> BNode { .bytes(Data(s.utf8)) }

    var encoded: Data {
        var out = Data()
        write(into: &out)
        return out
    }

    private func write(into out: inout Data) {
        switch self {
        case .int(let n): out.append(contentsOf: Array("i\(n)e".utf8))
        case .bytes(let d): out.append(contentsOf: Array("\(d.count):".utf8)); out.append(d)
        case .list(let items): out.append(UInt8(ascii: "l")); for i in items { i.write(into: &out) }; out.append(UInt8(ascii: "e"))
        case .dict(let items):
            out.append(UInt8(ascii: "d"))
            for (key, value) in items.sorted(by: { $0.0.lexicographicallyPrecedes($1.0) }) {
                out.append(contentsOf: Array("\(key.count):".utf8)); out.append(key)
                value.write(into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }
}

/// A folder tree for the v2 `file tree`: each file's node is `{ "": {length, pieces root} }`.
private final class TreeNode {
    var kids: [String: TreeNode] = [:]
    var meta: BNode?

    func insert(_ path: [String], meta: BNode) {
        guard let first = path.first else { self.meta = meta; return }
        let child = kids[first] ?? TreeNode()
        kids[first] = child
        child.insert(Array(path.dropFirst()), meta: meta)
    }

    var node: BNode {
        if let meta { return .dict([(Data(), meta)]) }
        return .dict(kids.map { (Data($0.key.utf8), $0.value.node) })
    }
}
