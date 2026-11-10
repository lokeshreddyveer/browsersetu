import CryptoKit
import Foundation

/// The torrent's files on disk, written piece by piece.
///
/// Everything is kept in one private working folder inside the authorised downloads folder (`.<id>.bsetu-torrent/`): the selected files at their relative paths, and one sparse scratch file for
/// the bytes of files the person did not choose that share a piece with ones they did (a piece can only be checked whole). Nothing is placed where the person sees it until every
/// selected piece has been checked; then the working folder's contents are moved into place by `finish`, never over anything that exists.
///
/// Every path is built from the names `TorrentMetainfo` already checked, then checked again here to be inside the working folder; a link on the way is never followed.
final class TorrentStorage: @unchecked Sendable {
    enum Failure: Error, Equatable, LocalizedError {
        case escapesFolder(String), noSpace(needed: Int64, available: Int64), io(String), alreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .escapesFolder(let p): "A file in the torrent would be written outside its folder (“\(p.prefix(60))”), so nothing was written."
            case .noSpace(let n, let a): "Not enough space: it needs about \(DownloadStats.bytes(n)) and \(DownloadStats.bytes(a)) is free."
            case .io(let why): why
            case .alreadyExists(let name): "“\(name)” already exists."
            }
        }
    }

    let meta: TorrentMetainfo
    let workingFolder: URL
    /// The torrent's own files live here, apart from the app's sidecar files and scratch file in the folder above, so no name in a torrent can collide with them.
    var dataFolder: URL { workingFolder.appendingPathComponent("data", isDirectory: true) }
    /// File indices the person wants. Can change while the download runs (`reselect`); read through the lock.
    private var chosen: Set<Int>
    var selected: Set<Int> { lock.lock(); defer { lock.unlock() }; return chosen }
    private let lock = NSLock()
    private var handles: [Int: Int32] = [:]            // by file index; -1 is the scratch file
    private static let scratch = -1

    static func workingFolder(for id: UUID, in directory: URL) -> URL { directory.appendingPathComponent(".\(id.uuidString.prefix(8)).bsetu-torrent", isDirectory: true) }

    /// Piece layers known so far (BEP 52), by pieces root: those the torrent carried, plus any installed after being fetched from peers.
    private var layers: [Data: Data]

    init(meta: TorrentMetainfo, workingFolder: URL, selected: Set<Int>) {
        self.meta = meta; self.workingFolder = workingFolder
        // Padding is never a choice: an old saved choice that named one is ignored.
        let real = Set(meta.files.filter { !$0.isPadding }.map(\.index))
        self.chosen = selected.isEmpty ? real : selected.intersection(real)
        self.layers = meta.pieceLayers
    }

    deinit { closeAll() }

    // MARK: Which pieces are needed

    /// Pieces that hold at least one byte of a selected file.
    var neededPieces: [Int] {
        var needed = Set<Int>()
        for f in meta.files where selected.contains(f.index) && f.length > 0 {
            let first = Int(f.offset / meta.pieceLength), last = Int((f.offset + f.length - 1) / meta.pieceLength)
            for p in first...last { needed.insert(p) }
        }
        return needed.sorted()
    }

    /// Bytes of selected files, which is what is shown as the size of the download.
    var selectedBytes: Int64 { meta.files.filter { selected.contains($0.index) }.reduce(0) { $0 + $1.length } }

    /// Disk the transfer will use: the selected files in full (the scratch file is sparse and holds only the edges).
    var expectedDiskUsage: Int64 {
        var edge: Int64 = 0
        for p in neededPieces { edge += meta.length(ofPiece: p) }
        return max(selectedBytes, min(edge, selectedBytes + 2 * meta.pieceLength * Int64(max(1, meta.files.count - selected.count + 1))))
    }

    // MARK: Opening

    /// Creates the folder and the files (sparse, at full length). Throws before writing anything if the disk cannot hold the selection.
    func prepare(freeSpace: ((URL) -> Int64?)? = nil) throws {
        let fm = FileManager.default
        let parent = workingFolder.deletingLastPathComponent()
        let need = expectedDiskUsage
        if let free = (freeSpace ?? { DiskSpace.available(at: $0) })(parent), free < need + max(50_000_000, need / 20) { throw Failure.noSpace(needed: need, available: free) }
        try fm.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        for f in meta.files where selected.contains(f.index) {
            let url = try fileURL(f)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = try handle(for: f.index, url: url)
            var st = stat()
            if fstat(fd, &st) == 0, Int64(st.st_size) != f.length, ftruncate(fd, off_t(f.length)) != 0 { throw Failure.io("A file could not be prepared (\(String(cString: strerror(errno)))).") }
        }
    }

    /// The path of a selected file inside the working folder. Checked: standardised, inside the folder, and no link on the way.
    func fileURL(_ f: TorrentMetainfo.File) throws -> URL {
        var url = dataFolder
        for part in f.path { url.appendPathComponent(part) }
        let standard = url.standardizedFileURL.path, root = dataFolder.standardizedFileURL.path
        guard standard.hasPrefix(root + "/") else { throw Failure.escapesFolder(f.relativePath) }
        // A link planted in the folder (by another program) must not redirect the write.
        var walk = dataFolder
        for part in f.path.dropLast() {
            walk.appendPathComponent(part)
            if let values = try? walk.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw Failure.escapesFolder(f.relativePath) }
        }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw Failure.escapesFolder(f.relativePath) }
        return url
    }

    private func handle(for index: Int, url: URL) throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if let fd = handles[index] { return fd }
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.io("A file could not be opened (\(String(cString: strerror(errno)))).") }
        handles[index] = fd
        return fd
    }

    private func scratchHandle() throws -> Int32 {
        try handle(for: Self.scratch, url: workingFolder.appendingPathComponent(".unselected"))
    }

    func closeAll() {
        lock.lock(); defer { lock.unlock() }
        for fd in handles.values { Darwin.close(fd) }
        handles = [:]
    }

    // MARK: Reading and writing a piece

    /// Writes a whole, already-verified piece to the files it belongs to.
    func write(piece index: Int, data: Data) throws {
        guard Int64(data.count) == meta.length(ofPiece: index) else { throw Failure.io("A piece has the wrong size.") }
        let start = Int64(index) * meta.pieceLength
        var consumed = 0
        let selected = self.selected
        for seg in meta.segments(offset: start, length: Int64(data.count)) {
            let f = meta.files[seg.file]
            let chunk = data.subdata(in: consumed..<(consumed + Int(seg.count)))
            if f.isPadding {
                // Padding is zeros by definition and is never stored (the check refuses a piece whose padding is not zeros).
            } else if selected.contains(f.index) {
                try pwriteAll(try handle(for: f.index, url: try fileURL(f)), chunk, at: seg.fileOffset)
            } else {
                try pwriteAll(try scratchHandle(), chunk, at: f.offset + seg.fileOffset)
            }
            consumed += Int(seg.count)
        }
    }

    /// Reads a piece back from disk (for re-checking). Nil if a file is missing or short.
    func read(piece index: Int) -> Data? {
        let length = meta.length(ofPiece: index)
        var out = Data(capacity: Int(length))
        let selected = self.selected
        for seg in meta.segments(offset: Int64(index) * meta.pieceLength, length: length) {
            let f = meta.files[seg.file]
            if f.isPadding { out.append(Data(count: Int(seg.count))); continue }
            let fd: Int32
            do { fd = selected.contains(f.index) ? try handle(for: f.index, url: try fileURL(f)) : try scratchHandle() } catch { return nil }
            var buffer = [UInt8](repeating: 0, count: Int(seg.count))
            let offset = selected.contains(f.index) ? seg.fileOffset : f.offset + seg.fileOffset
            let wanted = buffer.count
            var got = 0
            while got < wanted {
                let done = got
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, wanted - done, off_t(offset) + off_t(done)) }
                if n <= 0 { return nil }
                got += n
            }
            out.append(contentsOf: buffer)
        }
        return out.count == Int(length) ? out : nil
    }

    /// Reads one block of a piece (not the whole piece): what is served to a peer.
    func read(piece index: Int, begin: Int, length: Int) -> Data? {
        guard index >= 0, index < meta.pieceCount, begin >= 0, length > 0, begin + length <= Int(meta.length(ofPiece: index)) else { return nil }
        var out = Data(capacity: length)
        let selected = self.selected
        for seg in meta.segments(offset: Int64(index) * meta.pieceLength + Int64(begin), length: Int64(length)) {
            let f = meta.files[seg.file]
            if f.isPadding { out.append(Data(count: Int(seg.count))); continue }
            let fd: Int32
            do { fd = selected.contains(f.index) ? try handle(for: f.index, url: try fileURL(f)) : try scratchHandle() } catch { return nil }
            var buffer = [UInt8](repeating: 0, count: Int(seg.count))
            let offset = selected.contains(f.index) ? seg.fileOffset : f.offset + seg.fileOffset
            let wanted = buffer.count
            var got = 0
            while got < wanted {
                let done = got
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, wanted - done, off_t(offset) + off_t(done)) }
                if n <= 0 { return nil }
                got += n
            }
            out.append(contentsOf: buffer)
        }
        return out.count == length ? out : nil
    }

    /// The bytes of one file from `offset`, read through the same layout as everything else. For a reader (a player) that has checked the pieces are verified; nothing here checks that.
    func read(file index: Int, offset: Int64, length: Int) -> Data? {
        guard index >= 0, index < meta.files.count, offset >= 0, length > 0 else { return nil }
        let f = meta.files[index]
        guard offset + Int64(length) <= f.length else { return nil }
        var out = Data(capacity: length)
        var global = f.offset + offset, remaining = length
        while remaining > 0 {
            let piece = Int(global / meta.pieceLength)
            let begin = Int(global - Int64(piece) * meta.pieceLength)
            let n = min(remaining, Int(meta.length(ofPiece: piece)) - begin)
            guard n > 0, let chunk = read(piece: piece, begin: begin, length: n) else { return nil }
            out.append(chunk); global += Int64(n); remaining -= n
        }
        return out
    }

    /// After a pause, a crash or a change of the choice that was cut short, the verified pieces may be in the other place (the scratch file instead of the file, or the reverse). Each verified
    /// piece is read where it should be; if it does not check out there, the other place is tried, and if THAT checks out against the torrent's hash it is written where it belongs. A piece that
    /// is in neither place is returned, to be fetched again. Nothing is trusted without its hash.
    func reconcile(verified: Set<Int>) -> (healed: Int, missing: [Int]) {
        var healed = 0, missing: [Int] = []
        let chosen = selected
        for p in verified.sorted() {
            if let d = read(piece: p), matches(d, piece: p) { continue }
            if let alt = readOtherPlace(piece: p, chosen: chosen), matches(alt, piece: p), (try? write(piece: p, data: alt)) != nil { healed += 1 } else { missing.append(p) }
        }
        return (healed, missing)
    }

    /// The piece assembled segment by segment: each part comes from where it should be, and, when that part is all zeros (a file that was created but never filled) and the other place has
    /// something, from the other place instead (chosen files' bytes are kept in the scratch file while their file is not chosen, and the reverse). The caller checks the result against the hash.
    private func readOtherPlace(piece index: Int, chosen: Set<Int>) -> Data? {
        let length = meta.length(ofPiece: index)
        var out = Data(capacity: Int(length))
        func bytes(fd: Int32, offset: Int64, count: Int) -> [UInt8]? {
            var buffer = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let done = got
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
                if n <= 0 { return nil }
                got += n
            }
            return buffer
        }
        for seg in meta.segments(offset: Int64(index) * meta.pieceLength, length: length) {
            let f = meta.files[seg.file]
            let count = Int(seg.count)
            if f.isPadding { out.append(Data(count: count)); continue }
            var own: [UInt8]?, other: [UInt8]?
            let ownFile = try? fileURL(f)
            let fileFD: Int32? = ownFile.flatMap { FileManager.default.fileExists(atPath: $0.path) ? (try? handle(for: f.index, url: $0)) : nil }
            let scratchFD: Int32? = try? scratchHandle()
            if chosen.contains(f.index) {
                own = fileFD.flatMap { bytes(fd: $0, offset: seg.fileOffset, count: count) }
                other = scratchFD.flatMap { bytes(fd: $0, offset: f.offset + seg.fileOffset, count: count) }
            } else {
                own = scratchFD.flatMap { bytes(fd: $0, offset: f.offset + seg.fileOffset, count: count) }
                other = fileFD.flatMap { bytes(fd: $0, offset: seg.fileOffset, count: count) }
            }
            if let own, own.contains(where: { $0 != 0 }) { out.append(contentsOf: own) }
            else if let other, other.contains(where: { $0 != 0 }) { out.append(contentsOf: other) }
            else if let own { out.append(contentsOf: own) }
            else if let other { out.append(contentsOf: other) }
            else { return nil }
        }
        return out.count == Int(length) ? out : nil
    }

    // MARK: Changing the selection while downloading (DX-05)

    /// Chosen files hold their bytes in their own files; every other file's bytes live in the scratch file. Changing the choice moves the bytes of VERIFIED pieces between the two, so nothing
    /// that was downloaded is lost or downloaded again: a file newly chosen is filled from the scratch file, a file no longer chosen is emptied into it and its file is removed (it is never
    /// published). Call from the same queue as the writes. `verified`: the pieces known good. Throws before changing the choice if a copy fails.
    func reselect(to newSelection: Set<Int>, verified: Set<Int>) throws {
        let valid = Set(meta.files.filter { !$0.isPadding }.map(\.index))
        let target = newSelection.intersection(valid)
        guard !target.isEmpty else { throw Failure.io("At least one file must stay chosen.") }
        let old = selected
        let fm = FileManager.default
        func ranges(of f: TorrentMetainfo.File) -> [(Int64, Int64)] {          // (offset in the file, count) covered by verified pieces
            guard f.length > 0 else { return [] }
            var out: [(Int64, Int64)] = []
            let first = Int(f.offset / meta.pieceLength), last = Int((f.offset + f.length - 1) / meta.pieceLength)
            for p in first...last where verified.contains(p) {
                let a = max(f.offset, Int64(p) * meta.pieceLength), b = min(f.offset + f.length, Int64(p) * meta.pieceLength + meta.length(ofPiece: p))
                guard b > a else { continue }
                if let l = out.last, l.0 + l.1 == a - f.offset { out[out.count - 1].1 += b - a } else { out.append((a - f.offset, b - a)) }
            }
            return out
        }
        var created: [URL] = []          // files this call made: removed again if it fails, so a failed change leaves nothing behind
        do {
        for f in meta.files {
            let was = old.contains(f.index), will = target.contains(f.index)
            if was == will { continue }
            if f.length == 0 {          // an empty file has no bytes to move, but it is still made or removed with the choice
                if will { let url = try fileURL(f); try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); _ = try handle(for: f.index, url: url); created.append(url) }
                continue
            }
            let covered = ranges(of: f)
            if will {
                let url = try fileURL(f)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: url.path) { created.append(url) }
                let fd = try handle(for: f.index, url: url)
                var st = stat()
                if fstat(fd, &st) == 0, Int64(st.st_size) != f.length, ftruncate(fd, off_t(f.length)) != 0 { throw Failure.io("A file could not be prepared (\(String(cString: strerror(errno)))).") }
                let scratch = try scratchHandle()
                for (offset, count) in covered { try copy(from: scratch, at: f.offset + offset, to: fd, at: offset, count: count) }
            } else {
                let url = try fileURL(f)
                if !covered.isEmpty, fm.fileExists(atPath: url.path) {
                    let fd = try handle(for: f.index, url: url), scratch = try scratchHandle()
                    for (offset, count) in covered { try copy(from: fd, at: offset, to: scratch, at: f.offset + offset, count: count) }
                }
            }
        }
        } catch {
            for url in created { try? fm.removeItem(at: url) }
            lock.lock(); for f in meta.files where !old.contains(f.index) { if let fd = handles.removeValue(forKey: f.index) { Darwin.close(fd) } }; lock.unlock()
            throw error
        }
        // Only now that every copy is done does the choice change; then the files of dropped entries go.
        lock.lock(); chosen = target; lock.unlock()
        for f in meta.files where old.contains(f.index) && !target.contains(f.index) {
            lock.lock(); if let fd = handles.removeValue(forKey: f.index) { Darwin.close(fd) }; lock.unlock()
            if let url = try? fileURL(f) {
                try? fm.removeItem(at: url)
                var dir = url.deletingLastPathComponent()          // folders left empty by it go too, up to the data folder
                while dir.standardizedFileURL.path != dataFolder.standardizedFileURL.path, dir.path.hasPrefix(dataFolder.path),
                      (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir); dir = dir.deletingLastPathComponent() }
            }
        }
    }

    private func copy(from source: Int32, at sourceOffset: Int64, to target: Int32, at targetOffset: Int64, count: Int64) throws {
        var done: Int64 = 0
        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        while done < count {
            let want = Int(min(Int64(chunk), count - done))
            let n = buffer.withUnsafeMutableBytes { pread(source, $0.baseAddress!, want, off_t(sourceOffset + done)) }
            if n <= 0 { throw Failure.io("A file could not be read while the choice of files changed.") }
            try Data(buffer[0..<n]).withUnsafeBytes { raw in
                var written = 0
                while written < n {
                    let w = pwrite(target, raw.baseAddress! + written, n - written, off_t(targetOffset + done) + off_t(written))
                    if w < 0 { if errno == EINTR { continue }; throw Failure.io("Writing failed (\(String(cString: strerror(errno)))).") }
                    written += w
                }
            }
            done += Int64(n)
        }
    }

    /// The one gate for piece bytes (`index` is the piece's place in the torrent's single byte stream). Version 1: SHA-1. Version 2 only: the piece's file's Merkle layer. Hybrid: both.
    /// A hybrid piece whose file's layer is not known yet is judged by version 1 alone (the layer cannot say yes or no); a wrong layer still fails it.
    func matches(_ data: Data, piece index: Int) -> Bool {
        guard index >= 0, index < meta.pieceCount, Int64(data.count) == meta.length(ofPiece: index) else { return false }
        switch meta.version {
        case .v1: return v1Matches(data, piece: index)
        case .v2: return v2Verdict(data, piece: index) == .pass
        case .hybrid: return v1Matches(data, piece: index) && v2Verdict(data, piece: index) != .fail
        }
    }

    private func v1Matches(_ data: Data, piece index: Int) -> Bool {
        guard index < meta.pieceHashes.count, Data(Insecure.SHA1.hash(data: data)) == meta.pieceHashes[index] else { return false }
        return !meta.hasPadding || paddingIsZero(data, piece: index)
    }

    /// Padding must be zeros (BEP 47): a piece that carries anything else there is not the torrent's piece, even if a hash somehow agreed.
    private func paddingIsZero(_ data: Data, piece index: Int) -> Bool {
        var consumed = 0
        for seg in meta.segments(offset: Int64(index) * meta.pieceLength, length: Int64(data.count)) {
            let n = Int(seg.count)
            if meta.files[seg.file].isPadding, data.subdata(in: (data.startIndex + consumed)..<(data.startIndex + consumed + n)).contains(where: { $0 != 0 }) { return false }
            consumed += n
        }
        return true
    }

    enum V2Verdict { case pass, fail, unavailable }

    /// Checks a piece against the Merkle data of the one file it belongs to. `unavailable`: the file is longer than a piece and its layer has not been installed.
    func v2Verdict(_ data: Data, piece index: Int) -> V2Verdict {
        let start = Int64(index) * meta.pieceLength
        guard let f = meta.file(containing: start), let root = f.pieceRoot else { return .fail }
        let real = Int(min(meta.pieceLength, f.offset + f.length - start))
        guard data.count >= real, meta.version == .hybrid || data.count == real else { return .fail }
        let bytes = data.count == real ? data : data.prefix(real)
        var layer: Data?
        if f.length > meta.pieceLength {
            lock.lock(); layer = layers[root]; lock.unlock()
            if layer == nil { return .unavailable }
        }
        return Merkle.pieceMatches(Data(bytes), fileLength: f.length, pieceLength: meta.pieceLength, piecesRoot: root, pieceLayer: layer, indexInFile: Int((start - f.offset) / meta.pieceLength)) ? .pass : .fail
    }

    /// Installs a piece layer (concatenated 32-byte piece roots) for the file(s) with this pieces root. Accepted only if it hashes to the root for a file of that length.
    @discardableResult
    func install(pieceLayer layer: Data, forRoot root: Data) -> Bool {
        guard meta.version != .v1, let f = meta.files.first(where: { !$0.isPadding && $0.pieceRoot == root && $0.length > meta.pieceLength }),
              Merkle.layerMatches(layer, fileLength: f.length, pieceLength: meta.pieceLength, piecesRoot: root) else { return false }
        lock.lock(); layers[root] = layer; lock.unlock()
        return true
    }

    /// Pieces roots of files longer than a piece whose layer is still unknown.
    var missingLayerRoots: [Data] {
        lock.lock(); defer { lock.unlock() }
        return meta.missingLayerRoots.filter { layers[$0] == nil }
    }

    /// The layers known now (to be saved with the torrent so they need not be fetched again).
    var knownPieceLayers: [Data: Data] { lock.lock(); defer { lock.unlock() }; return layers }

    private func pwriteAll(_ fd: Int32, _ data: Data, at offset: Int64) throws {
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = pwrite(fd, raw.baseAddress! + done, raw.count - done, off_t(offset) + off_t(done))
                if n < 0 { if errno == EINTR { continue }; throw Failure.io("Writing failed (\(String(cString: strerror(errno)))).") }
                done += n
            }
        }
    }

    func sync() { lock.lock(); let all = Array(handles.values); lock.unlock(); for fd in all { _ = fcntl(fd, F_FULLFSYNC) } }

    // MARK: Finishing

    /// Moves the finished files out of the working folder to `destination/<name>` (a folder for a multi-file torrent, the file itself for a single one). A name that is taken gets
    /// "name 2"; nothing is overwritten or merged. The working folder is removed afterwards. Returns where the download now is.
    func finish(into destination: URL, name finalName: String? = nil) throws -> URL {
        let placedName = finalName ?? meta.name
        closeAll()
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let selectedNow = selected
        // Only the chosen files are published: anything else that is in the data folder (a file left by a change that failed, an empty file) is removed first.
        for f in meta.files where !selectedNow.contains(f.index) && !f.isPadding {
            if let url = try? fileURL(f), fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                var dir = url.deletingLastPathComponent()
                while dir.standardizedFileURL.path != dataFolder.standardizedFileURL.path, dir.path.hasPrefix(dataFolder.path), (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir); dir = dir.deletingLastPathComponent() }
            }
        }
        let selectedFiles = meta.files.filter { selectedNow.contains($0.index) }
        if !meta.isMultiFile, let only = selectedFiles.first {
            let source = try fileURL(only)
            let target = try Self.place(source, in: destination, name: placedName, isDirectory: false)
            try? fm.removeItem(at: workingFolder)
            return target
        }
        // The data folder holds exactly the chosen files at their relative paths: it becomes the torrent's folder.
        let target = try Self.place(dataFolder, in: destination, name: placedName, isDirectory: true)
        try? fm.removeItem(at: workingFolder)
        return target
    }

    /// RENAME_EXCL to `name`, then `name 2`, `name 3`…; the first free one wins and nothing is replaced.
    static func place(_ source: URL, in directory: URL, name: String, isDirectory: Bool) throws -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...999 {
            let candidate = n == 1 ? name : (ext.isEmpty || isDirectory ? "\(name) \(n)" : "\(base) \(n).\(ext)")
            let target = directory.appendingPathComponent(candidate, isDirectory: isDirectory)
            if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST { throw Failure.io("The download could not be put in place (\(String(cString: strerror(errno)))).") }
        }
        throw Failure.alreadyExists(name)
    }

    func discard() { closeAll(); try? FileManager.default.removeItem(at: workingFolder) }
}
