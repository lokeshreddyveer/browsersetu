import Foundation
import Compression

// Archives: looking inside, and taking files out.
//
// Supported, because they can be read with the system's own decompressor and a reader small enough to review: ZIP (including ZIP64; stored and deflated entries), TAR (ustar, GNU and pax
// names) and TAR.GZ. NOT supported, and said so with the reason: 7z, RAR and the other formats (there is no vetted, licensed decoder bundled and none is written here), password-protected
// ZIP entries (no password is ever tried or asked for, because there is no decoder to give it to), archives in several parts.
//
// Listing never writes anything. Extraction writes into a hidden folder of its own beside the destination, checks every entry, and puts the finished folder in place under a name that
// is free (never merged into, never replacing). The archive itself is never changed or removed.

enum ArchiveKind: Equatable, Sendable {
    case zip, tar, tarGz
    case unsupported(String)
    var title: String {
        switch self { case .zip: "ZIP"; case .tar: "TAR"; case .tarGz: "TAR.GZ"; case .unsupported: "Unsupported" }
    }
}

struct ArchiveItem: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case supported, unsupported(String) }
    let id: Int
    var name: String
    var parts: [String]?
    var isDirectory: Bool
    var size: UInt64
    var compressedSize: UInt64?
    var method: String
    var encrypted: Bool
    var status: Status
    /// A name that could land outside the folder (absolute, "..", a drive letter), as opposed to merely not being supported.
    var unsafePath: Bool
    var isSupported: Bool { status == .supported }
}

struct ArchiveListing: Equatable, Sendable {
    var kind: ArchiveKind
    var items: [ArchiveItem]
    var totalSize: UInt64
    var notes: [String]
    /// True when some entry's name is unsafe: "extract everything" is then refused, and only chosen safe entries can be taken.
    var hasUnsafeEntries: Bool { items.contains { $0.unsafePath } }
    var supportedCount: Int { items.filter(\.isSupported).count }
}

enum ArchiveError: Error, Equatable, LocalizedError {
    case notAFile, notAnArchive, unsupported(String), tooLarge(String), damaged(String), unsafe(String), notAuthorized, cancelled
    case notEnoughSpace(needed: Int64, available: Int64)
    case entry(String, String)
    var errorDescription: String? {
        switch self {
        case .notAFile: "That is not a file Browser Setu can open."
        case .notAnArchive: "That does not look like an archive Browser Setu can read."
        case .unsupported(let why): why
        case .tooLarge(let why): why
        case .damaged(let why): "The archive is damaged: \(why)"
        case .unsafe(let why): why
        case .notAuthorized: "That folder is not one the app may write to."
        case .cancelled: "Cancelled."
        case .notEnoughSpace(let needed, let available): "Not enough space: it needs about \(DownloadStats.bytes(needed)) and \(DownloadStats.bytes(available)) is free."
        case .entry(let name, let why): "“\(name.prefix(60))”: \(why)"
        }
    }
}

struct ArchiveLimits: Sendable {
    var maxEntries = 10_000
    var maxTotal: UInt64 = 4 * 1024 * 1024 * 1024
    var maxEntry: UInt64 = 2 * 1024 * 1024 * 1024
    /// For a compressed stream (tar.gz) whose size cannot be known in advance: past this much output, it may not expand more than `maxRatio` times its compressed size.
    var ratioFloor: UInt64 = 64 * 1024 * 1024
    var maxRatio: UInt64 = 1000
    var maxHeaderBytes = 64 * 1024
}

enum ArchiveManager {
    // MARK: What it is

    static func sniff(_ file: URL) -> ArchiveKind {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: file) else { return .unsupported("That is not a plain file.") }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        let b = [UInt8](head)
        func has(_ bytes: [UInt8], at i: Int = 0) -> Bool { b.count >= i + bytes.count && Array(b[i..<i + bytes.count]) == bytes }
        if has([0x50, 0x4B, 0x03, 0x04]) || has([0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if has([0x1F, 0x8B]) { return looksLikeTarGz(file) ? .tarGz : .unsupported("A compressed file that is not a tar archive (a single .gz file) is not an archive Browser Setu opens.") }
        if has(Array("ustar".utf8), at: 257) { return .tar }
        if has([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .unsupported("7z archives cannot be opened: there is no vetted, licensed 7z decoder in the app.") }
        if has(Array("Rar!".utf8)) { return .unsupported("RAR archives cannot be opened: there is no vetted, licensed RAR decoder in the app.") }
        if has([0x42, 0x5A, 0x68]) { return .unsupported("bzip2 archives cannot be opened here.") }
        if has([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .unsupported("xz archives cannot be opened here.") }
        return .unsupported("This kind of file is not an archive Browser Setu can open.")
    }

    private static func looksLikeTarGz(_ file: URL) -> Bool {
        guard let first = try? TarGzFirstBlock.read(file) else { return false }
        return first
    }

    // MARK: Listing

    /// What is inside, without writing anything. Bounded in entries, in total size and (for streams) in expansion. Call off the main thread.
    static func list(_ file: URL, limits: ArchiveLimits = ArchiveLimits(), isCancelled: () -> Bool = { false }) throws -> ArchiveListing {
        switch sniff(file) {
        case .zip: return try listZip(file, limits: limits)
        case .tar: return try listTar(file, gzip: false, limits: limits, isCancelled: isCancelled)
        case .tarGz: return try listTar(file, gzip: true, limits: limits, isCancelled: isCancelled)
        case .unsupported(let why): throw ArchiveError.unsupported(why)
        }
    }

    // MARK: ZIP

    private static func listZip(_ file: URL, limits: ArchiveLimits) throws -> ArchiveListing {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) } catch { throw ArchiveError.notAFile }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= UInt64(ZipFormat.eocdSize) else { throw ArchiveError.notAnArchive }
        func read(_ offset: UInt64, _ length: UInt64) throws -> Data {
            try handle.seek(toOffset: offset)
            guard let d = try handle.read(upToCount: Int(length)), UInt64(d.count) == length else { throw ArchiveError.damaged("it is cut short") }
            return d
        }
        do {
            var end: ZipFormat.EndRecord?
            var lastError: ZipError = .notAZip
            for window in [UInt64(1024), UInt64(ZipFormat.tailSize)] {
                let length = min(window, size)
                let tail = try read(size - length, length)
                do { end = try ZipFormat.findEnd(tail: tail, archiveSize: size); break } catch let e as ZipError { lastError = e; if e != .notAZip && e != .zip64Missing { throw e } }
                if length == size { break }
            }
            guard var found = end else { throw lastError }
            let isZip64 = found.zip64RecordOffset != nil
            if let at = found.zip64RecordOffset {
                guard at &+ UInt64(ZipFormat.zip64RecordSize) <= size else { throw ZipError.malformed("the ZIP64 record is outside the archive") }
                found = try ZipFormat.applyZip64(try read(at, UInt64(ZipFormat.zip64RecordSize)), to: found)
            }
            try ZipFormat.validate(found, archiveSize: size)
            guard found.entries <= UInt64(limits.maxEntries) else { throw ArchiveError.tooLarge("The archive lists more than \(limits.maxEntries) entries.") }
            let directory = found.centralSize == 0 ? Data() : try read(found.centralOffset, found.centralSize)
            let entries = try ZipFormat.parseCentralDirectory(directory, entries: found.entries, archiveSize: size, centralOffset: found.centralOffset)
            let items: [ArchiveItem] = entries.map { e in
                var status: ArchiveItem.Status = e.isSupported ? .supported : { if case .unsupported(let why) = e.status { return .unsupported(why) }; return .supported }()
                if e.uncompressedSize > limits.maxEntry { status = .unsupported("It is larger than the limit for a single file.") }
                let name = e.name
                let unsafe = e.path == nil && !name.isEmpty
                return ArchiveItem(id: e.id, name: name, parts: e.path, isDirectory: e.isDirectory, size: e.uncompressedSize, compressedSize: e.compressedSize, method: e.method == 0 ? "stored" : e.method == 8 ? "deflate" : "method \(e.method)",
                                   encrypted: (e.flags & 1) != 0, status: status, unsafePath: unsafe)
            }
            // Only what could be written counts, and the sum can neither wrap nor pass the cap.
            var total: UInt64 = 0
            for item in items where item.isSupported && !item.isDirectory {
                let (sum, overflow) = total.addingReportingOverflow(item.size)
                guard !overflow, sum <= limits.maxTotal else { throw ArchiveError.tooLarge("It would unpack to more than \(DownloadStats.bytes(Int64(limits.maxTotal))), over the safety limit.") }
                total = sum
            }
            return ArchiveListing(kind: .zip, items: items, totalSize: total, notes: isZip64 ? ["ZIP64 archive."] : [])
        } catch let e as ZipError { throw ArchiveError.damaged(e.errorDescription ?? "unreadable") }
    }

    /// Where a ZIP entry's data is and how it is stored; the entry must be supported.
    private static func zipDataRange(_ handle: FileHandle, entry: ZipEntry) throws -> UInt64 {
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30 else { throw ArchiveError.damaged("an entry's header is missing") }
        do { return try ZipFormat.dataStart(localHeader: header, entry: entry) } catch { throw ArchiveError.damaged("an entry's header is not valid") }
    }

    // MARK: TAR

    private struct TarEntry { var name: String; var size: UInt64; var type: UInt8; var link: String }

    /// Feeds bytes of a tar stream and reports entries. Bounded: entries, header text, sizes.
    private final class TarReader {
        enum Event { case entry(TarEntry), data(UnsafeRawBufferPointer), end }
        private var buffer = Data()
        private var remaining: UInt64 = 0
        private var padding = 0
        private var extra: Data?                 // contents of a pax/GNU long-name record being collected
        private var extraKind: UInt8 = 0
        private var pendingName: String?
        private var pendingSize: UInt64?
        private var zeroBlocks = 0
        private(set) var finished = false
        private(set) var entries = 0
        /// Between entries, with no half header and no data owed: where a well-formed stream can end.
        var atBoundary: Bool { buffer.isEmpty && remaining == 0 && padding == 0 && extra == nil }
        let limits: ArchiveLimits
        let handler: (Event) throws -> Void
        init(limits: ArchiveLimits, handler: @escaping (Event) throws -> Void) { self.limits = limits; self.handler = handler }

        func feed(_ bytes: UnsafeRawBufferPointer) throws {
            var offset = 0
            while offset < bytes.count, !finished {
                if remaining > 0 {
                    let n = min(Int(min(remaining, UInt64(Int.max))), bytes.count - offset)
                    let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + n])
                    if extra != nil {
                        extra!.append(contentsOf: slice)
                        if extra!.count > limits.maxHeaderBytes { throw ArchiveError.damaged("a name record is too long") }
                    } else { try handler(.data(slice)) }
                    remaining -= UInt64(n); offset += n
                    if remaining == 0 { try finishData() }
                    continue
                }
                if padding > 0 {
                    let n = min(padding, bytes.count - offset); padding -= n; offset += n; continue
                }
                let need = 512 - buffer.count
                let n = min(need, bytes.count - offset)
                buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + n])); offset += n
                if buffer.count == 512 { let block = buffer; buffer = Data(); try header(block) }
            }
        }

        private func finishData() throws {
            if let collected = extra {
                extra = nil
                switch extraKind {
                case UInt8(ascii: "L"): pendingName = String(decoding: collected.prefix { $0 != 0 }, as: UTF8.self)
                case UInt8(ascii: "x"):
                    // "<length> <key>=<value>\n" records: path and size are the ones that matter.
                    var text = collected[...]
                    while let space = text.firstIndex(of: 0x20) {
                        let digits = text.distance(from: text.startIndex, to: space)
                        guard let length = Int(String(decoding: text[text.startIndex..<space], as: UTF8.self)), length >= digits + 2, length <= text.count else { break }          // (a record must hold its own length field, the space, and something after it)
                        let record = text[space + 1..<text.startIndex + length]
                        text = text.dropFirst(length)
                        let line = String(decoding: record, as: UTF8.self).trimmingCharacters(in: .newlines)
                        if line.hasPrefix("path=") { pendingName = String(line.dropFirst(5)) } else if line.hasPrefix("size="), let v = UInt64(line.dropFirst(5)) { pendingSize = v }
                    }
                default: break
                }
            }
        }

        private func header(_ b: Data) throws {
            if b.allSatisfy({ $0 == 0 }) { zeroBlocks += 1; if zeroBlocks >= 2 { finished = true; try handler(.end) }; return }
            zeroBlocks = 0
            // The checksum: the sum of the block with its own field counted as spaces.
            let stored = Self.octal(b, 148, 8)
            var sum: UInt64 = 0
            for (i, byte) in b.enumerated() { sum += (148..<156).contains(i) ? 0x20 : UInt64(byte) }
            guard let stored, stored == sum else { throw ArchiveError.damaged("a header's checksum is wrong") }
            let type = b[b.startIndex + 156]
            var size = Self.size(b)
            guard size != nil else { throw ArchiveError.damaged("an entry's size is not valid") }
            var name = Self.string(b, 0, 100)
            // The "prefix" field exists only in POSIX ustar ("ustar\0" and version "00"). GNU tar ("ustar  ") keeps access and change times there, which would read as a folder name.
            let magic = Array(b[(b.startIndex + 257)..<(b.startIndex + 265)])
            if magic == Array("ustar".utf8) + [0, 0x30, 0x30] { let prefix = Self.string(b, 345, 155); if !prefix.isEmpty { name = prefix + "/" + name } }
            if type == UInt8(ascii: "L") || type == UInt8(ascii: "x") || type == UInt8(ascii: "g") || type == UInt8(ascii: "K") {
                guard size! <= UInt64(limits.maxHeaderBytes) else { throw ArchiveError.damaged("a name record is too long") }
                extra = Data(); extraKind = type == UInt8(ascii: "g") || type == UInt8(ascii: "K") ? 0 : type
                remaining = size!; padding = Int((512 - size! % 512) % 512)
                if size! == 0 { extra = nil }
                return
            }
            if let p = pendingName { name = p; pendingName = nil }
            if let s = pendingSize { size = s; pendingSize = nil }
            entries += 1
            guard entries <= limits.maxEntries else { throw ArchiveError.tooLarge("The archive lists more than \(limits.maxEntries) entries.") }
            // Links, devices, pipes and folders carry no data; every other kind (a regular file, a sparse file, a vendor type) is followed by `size` bytes, which are skipped over rather than read as headers.
            let noData: Set<UInt8> = [UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "3"), UInt8(ascii: "4"), UInt8(ascii: "5"), UInt8(ascii: "6")]
            let carriesData = !noData.contains(type)
            let entry = TarEntry(name: name, size: carriesData ? size! : 0, type: type, link: Self.string(b, 157, 100))
            try handler(.entry(entry))
            let dataSize = carriesData ? size! : 0
            remaining = dataSize; padding = Int((512 - dataSize % 512) % 512)
        }

        static func string(_ b: Data, _ at: Int, _ length: Int) -> String {
            let slice = b[b.startIndex + at..<b.startIndex + at + length]
            return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
        }
        static func octal(_ b: Data, _ at: Int, _ length: Int) -> UInt64? {
            let text = string(b, at, length).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            return text.isEmpty ? 0 : UInt64(text, radix: 8)
        }
        /// An octal size, or a GNU base-256 one for very large files.
        static func size(_ b: Data) -> UInt64? {
            let first = b[b.startIndex + 124]
            if first & 0x80 != 0 {
                var value: UInt64 = UInt64(first & 0x7F)
                for i in 1..<12 { let (m, o1) = value.multipliedReportingOverflow(by: 256); if o1 { return nil }; value = m + UInt64(b[b.startIndex + 124 + i]) }
                return value
            }
            return octal(b, 124, 12)
        }
    }

    // MARK: Streams

    /// Reads the file, gunzipping when asked, and hands the (decompressed) bytes on. Stops at the limits; verifies the gzip trailer.
    private static func stream(_ file: URL, gzip: Bool, limits: ArchiveLimits, isCancelled: () -> Bool, into sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard let reader = try? FileHandle(forReadingFrom: file) else { throw ArchiveError.notAFile }
        defer { try? reader.close() }
        guard gzip else {
            while let chunk = try reader.read(upToCount: 1 << 16), !chunk.isEmpty {
                if isCancelled() { throw ArchiveError.cancelled }
                try chunk.withUnsafeBytes { try sink($0) }
            }
            return
        }
        let total = try reader.seekToEnd()
        guard total > 18 else { throw ArchiveError.damaged("it is cut short") }
        try reader.seek(toOffset: 0)
        let head = try reader.read(upToCount: 64 * 1024) ?? Data()
        guard let start = gzipHeaderLength(head) else { throw ArchiveError.damaged("the compressed header is not valid") }
        try reader.seek(toOffset: total - 8)
        guard let trailer = try reader.read(upToCount: 8), trailer.count == 8 else { throw ArchiveError.damaged("it is cut short") }
        let wantCRC = ZipFormat.u32(trailer, 0), wantSize = ZipFormat.u32(trailer, 4)
        let compressedEnd = total - 8
        try reader.seek(toOffset: UInt64(start))
        var position = UInt64(start)

        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 16), src = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 16)
        defer { dst.deallocate(); src.deallocate() }
        var cs = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(src), src_size: 0, state: nil)
        guard compression_stream_init(&cs, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ArchiveError.damaged("the decompressor could not start") }
        defer { compression_stream_destroy(&cs) }
        var crc: UInt32 = 0, produced: UInt64 = 0, ended = false, finalFed = false
        while !ended {
            if isCancelled() { throw ArchiveError.cancelled }
            if cs.src_size == 0, !finalFed {
                let want = Int(min(UInt64(1 << 16), compressedEnd - position))
                let chunk = want > 0 ? (try reader.read(upToCount: want) ?? Data()) : Data()
                if chunk.isEmpty { finalFed = true } else { chunk.copyBytes(to: src, count: chunk.count); cs.src_ptr = UnsafePointer(src); cs.src_size = chunk.count; position += UInt64(chunk.count) }
            }
            cs.dst_ptr = dst; cs.dst_size = 1 << 16
            let status = compression_stream_process(&cs, finalFed ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
            let n = (1 << 16) - cs.dst_size
            if n > 0 {
                produced += UInt64(n)
                guard produced <= limits.maxTotal else { throw ArchiveError.tooLarge("It would unpack to more than \(DownloadStats.bytes(Int64(limits.maxTotal))), over the safety limit.") }
                if produced > limits.ratioFloor, produced / max(1, position) > limits.maxRatio { throw ArchiveError.tooLarge("It expands far more than a normal archive does, so it was not opened.") }
                let bytes = UnsafeRawBufferPointer(start: dst, count: n)
                crc = ZipFormat.crc32(update: crc, bytes)
                try sink(bytes)
            }
            switch status {
            case COMPRESSION_STATUS_END: ended = true
            case COMPRESSION_STATUS_OK: if finalFed, n == 0, cs.src_size == 0 { throw ArchiveError.damaged("it is cut short") }
            default: throw ArchiveError.damaged("the compressed data is not valid")
            }
        }
        guard crc == wantCRC, UInt32(truncatingIfNeeded: produced) == wantSize else { throw ArchiveError.damaged("its checksum does not match") }
    }

    /// Bytes of the gzip header (10 fixed, plus the optional parts), or nil when it is not a gzip header.
    static func gzipHeaderLength(_ d: Data) -> Int? {
        let b = [UInt8](d.prefix(64 * 1024))
        guard b.count >= 10, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard b.count >= i + 2 else { return nil }; i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        for bit in [UInt8(0x08), 0x10] where flags & bit != 0 { while i < b.count, b[i] != 0 { i += 1 }; guard i < b.count else { return nil }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        return i <= b.count ? i : nil
    }

    // MARK: TAR listing

    /// Names as `tar czf x .` writes them ("./", "./a/b") lose their leading "./"; the folder itself ("." or "./") has no parts.
    static func normalizedTarName(_ raw: String) -> String {
        var n = raw
        while n.hasPrefix("./") { n.removeFirst(2) }
        return n == "." ? "" : n
    }

    private static func classify(_ e: TarEntry, id: Int) -> ArchiveItem {
        let isDir = e.type == UInt8(ascii: "5") || e.name.hasSuffix("/")
        let cleaned = normalizedTarName(e.name)
        let parts: [String]? = cleaned.isEmpty && !e.name.isEmpty ? [] : ZipFormat.safePath(cleaned)
        var status = ArchiveItem.Status.supported
        switch e.type {
        case 0, UInt8(ascii: "0"), 7, UInt8(ascii: "5"): break
        case UInt8(ascii: "S"), UInt8(ascii: "D"), UInt8(ascii: "M"), UInt8(ascii: "V"): status = .unsupported("A sparse, multi-volume or other special kind of entry: never created.")
        case UInt8(ascii: "1"): status = .unsupported("A hard link: links are never created.")
        case UInt8(ascii: "2"): status = .unsupported("A symbolic link: links are never created.")
        case UInt8(ascii: "3"), UInt8(ascii: "4"), UInt8(ascii: "6"): status = .unsupported("A device or pipe file: never created.")
        default: status = .unsupported("An unsupported kind of entry.")
        }
        if parts == nil { status = .unsupported("Its name is not safe to write.") }
        return ArchiveItem(id: id, name: e.name, parts: parts, isDirectory: isDir, size: e.size, compressedSize: nil, method: "stored", encrypted: false, status: status, unsafePath: parts == nil)
    }

    private static func listTar(_ file: URL, gzip: Bool, limits: ArchiveLimits, isCancelled: () -> Bool) throws -> ArchiveListing {
        var items: [ArchiveItem] = []
        var total: UInt64 = 0
        let reader = TarReader(limits: limits) { event in
            if case .entry(let e) = event {
                let (sum, overflow) = total.addingReportingOverflow(e.size)
                guard !overflow, sum <= limits.maxTotal else { throw ArchiveError.tooLarge("It would unpack to more than \(DownloadStats.bytes(Int64(limits.maxTotal))), over the safety limit.") }
                total = sum
                var item = classify(e, id: items.count)
                if e.size > limits.maxEntry { item.status = .unsupported("It is larger than the limit for a single file.") }
                items.append(item)
            }
        }
        try stream(file, gzip: gzip, limits: limits, isCancelled: isCancelled) { try reader.feed($0) }
        guard reader.finished || (!items.isEmpty && reader.atBoundary) else { throw items.isEmpty ? ArchiveError.notAnArchive : ArchiveError.damaged("it is cut short.") }
        markCollisions(&items)
        return ArchiveListing(kind: gzip ? .tarGz : .tar, items: items, totalSize: total, notes: gzip ? ["Read through the compressed stream (nothing was written)."] : [])
    }

    /// Names the file system treats as one (case, equivalent Unicode), and a file that shares a name with a folder.
    static func markCollisions(_ items: inout [ArchiveItem]) {
        var seen = Set<String>(), folders = Set<String>(), fileKeys = Set<String>()
        for i in items.indices where items[i].isSupported {
            guard let parts = items[i].parts, !parts.isEmpty else { continue }
            let key = parts.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            if items[i].isDirectory {
                if fileKeys.contains(key) { items[i].status = .unsupported("A file and a folder have the same name."); continue }
                folders.insert(key)
            } else {
                fileKeys.insert(key)
                if folders.contains(key) { items[i].status = .unsupported("A file and a folder have the same name."); continue }
            }
            if !seen.insert(key).inserted, !items[i].isDirectory { items[i].status = .unsupported("Another entry has the same name."); continue }
            for k in 1..<max(1, parts.count) { folders.insert(parts[0..<k].joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()) }
        }
        for i in items.indices where items[i].isSupported && !items[i].isDirectory {
            if let parts = items[i].parts, folders.contains(parts.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()) { items[i].status = .unsupported("A file and a folder have the same name.") }
        }
    }

    // MARK: Extraction

    struct Result: Equatable {
        var folder: URL
        var extracted: Int
        var bytes: Int64
        var skipped: [(name: String, reason: String)]
        static func == (a: Result, b: Result) -> Bool { a.folder == b.folder && a.extracted == b.extracted && a.bytes == b.bytes && a.skipped.map(\.name) == b.skipped.map(\.name) }
    }

    /// Takes the chosen entries (all of them when `selection` is nil) out into a NEW folder inside `destination`. `destination` must be inside `roots` (links followed). Nothing outside
    /// the new folder is written; the new folder appears only when everything chosen was written and checked; the archive is untouched.
    static func extract(_ file: URL, selection: Set<Int>? = nil, destination: URL, roots: [URL], limits: ArchiveLimits = ArchiveLimits(), freeSpace: (URL) -> Int64? = { DiskSpace.available(at: $0) },
                        progress: (Int64, Int64) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> Result {
        guard DownloadPathPolicy.isAuthorized(destination.path, roots: roots) else { throw ArchiveError.notAuthorized }
        // The destination is resolved once, here, and that resolved folder is the only one used from now on; if it is swapped for something else (a link, another folder) while this runs,
        // it is noticed before anything is placed. The archive is held to the same: what was listed is what is extracted.
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard let destinationIdentity = FileIdentity(destination), let archiveIdentity = FileIdentity(file) else { throw ArchiveError.damaged("the archive or the folder could not be read.") }
        sweepStale(in: destination)
        let listing = try list(file, limits: limits, isCancelled: isCancelled)
        guard FileIdentity(file) == archiveIdentity else { throw ArchiveError.damaged("It changed while it was being opened. Try again.") }
        if selection == nil, listing.hasUnsafeEntries { throw ArchiveError.unsafe("It holds an entry whose name could land outside the folder (an absolute path or “..”), so it is not opened as a whole. Choose the safe entries you want instead.") }
        let wanted = listing.items.filter { selection == nil || selection!.contains($0.id) }
        guard !wanted.isEmpty else { throw ArchiveError.unsafe("Nothing was chosen.") }
        var skipped: [(String, String)] = []
        var chosen: [ArchiveItem] = []
        for item in wanted {
            if item.unsafePath { throw ArchiveError.unsafe("“\(item.name.prefix(60))” has a name that is not safe to write.") }
            if case .unsupported(let why) = item.status { skipped.append((item.name, why)) } else { chosen.append(item) }
        }
        let need = chosen.reduce(Int64(0)) { $0 + Int64(min($1.size, UInt64(Int64.max / 4))) }
        if let free = freeSpace(destination), free < need + max(50_000_000, need / 20) { throw ArchiveError.notEnoughSpace(needed: need, available: free) }
        let fm = FileManager.default
        let staging = destination.appendingPathComponent(".\(UUID().uuidString.prefix(8)).bsetu-archive", isDirectory: true)
        guard FileIdentity(destination)?.isSameObject(as: destinationIdentity) == true else { throw ArchiveError.notAuthorized }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var written: Int64 = 0
        do {
            // The folder made must be directly inside the destination that was checked (not inside whatever a swapped link now points to).
            guard staging.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == destination.path, FileIdentity(destination)?.isSameObject(as: destinationIdentity) == true else { throw ArchiveError.notAuthorized }
            switch listing.kind {
            case .zip: try extractZip(file, chosen: chosen, into: staging, written: &written, total: need, progress: progress, isCancelled: isCancelled)
            case .tar, .tarGz: try extractTar(file, gzip: listing.kind == .tarGz, chosen: chosen, into: staging, limits: limits, written: &written, total: need, progress: progress, isCancelled: isCancelled)
            case .unsupported(let why): throw ArchiveError.unsupported(why)
            }
            guard FileIdentity(file) == archiveIdentity else { throw ArchiveError.damaged("It changed while it was being extracted, so nothing was kept. Try again.") }
            guard FileIdentity(destination)?.isSameObject(as: destinationIdentity) == true else { throw ArchiveError.notAuthorized }
            copyQuarantine(from: file, toTreeAt: staging)
            let folder = try place(staging, beside: destination, base: file.deletingPathExtension().lastPathComponent)
            return Result(folder: folder, extracted: chosen.filter { !$0.isDirectory }.count, bytes: written, skipped: skipped.map { (name: $0.0, reason: $0.1) })
        } catch {
            try? fm.removeItem(at: staging)          // only the folder this call made
            throw error
        }
    }

    /// A working folder left by a crash (more than a day old, named exactly as this code names them) is removed. Nothing else is touched.
    static func sweepStale(in destination: URL, olderThan age: TimeInterval = 24 * 3600) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: destination.path) else { return }
        for name in names where name.range(of: #"^\.[0-9A-F]{8}\.bsetu-archive(\.c\d+)?$"#, options: .regularExpression) != nil {
            let url = destination.appendingPathComponent(name)
            if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, Date().timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func target(_ item: ArchiveItem, in root: URL) throws -> URL {
        guard let parts = item.parts else { throw ArchiveError.entry(item.name, "its name is not safe") }
        if parts.isEmpty { return root }          // the archive's own top folder (".")
        var url = root
        for p in parts { url.appendPathComponent(p, isDirectory: false) }
        // Defence in depth: whatever the parts were, the result must be inside the staging folder.
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ArchiveError.entry(item.name, "it would land outside the folder") }
        return url
    }

    private static func extractZip(_ file: URL, chosen: [ArchiveItem], into staging: URL, written: inout Int64, total: Int64, progress: (Int64, Int64) -> Void, isCancelled: () -> Bool) throws {
        // The table of contents again, for the offsets the listing does not carry.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        // Working files for compressed data live beside the staging folder, never inside the tree being built (an entry could otherwise be named like one).
        let scratch = staging.deletingLastPathComponent()
        // Everything read here was already listed within the limits; an archive that now claims more has been replaced, and is refused rather than trusted.
        func read(_ o: UInt64, _ l: UInt64) throws -> Data { guard l <= 64 << 20, o <= size, l <= size - o else { throw ArchiveError.damaged("it changed while it was being read") }; try handle.seek(toOffset: o); guard let d = try handle.read(upToCount: Int(l)), UInt64(d.count) == l else { throw ArchiveError.damaged("it is cut short") }; return d }
        let tail = try read(size - min(size, UInt64(ZipFormat.tailSize)), min(size, UInt64(ZipFormat.tailSize)))
        var end = try ZipFormat.findEnd(tail: tail, archiveSize: size)
        if let at = end.zip64RecordOffset { end = try ZipFormat.applyZip64(try read(at, UInt64(ZipFormat.zip64RecordSize)), to: end) }
        let entries = try ZipFormat.parseCentralDirectory(try read(end.centralOffset, end.centralSize), entries: end.entries, archiveSize: size, centralOffset: end.centralOffset)
        let fm = FileManager.default
        for item in chosen {
            if isCancelled() { throw ArchiveError.cancelled }
            let dest = try target(item, in: staging)
            if item.isDirectory { try fm.createDirectory(at: dest, withIntermediateDirectories: true); continue }
            guard let entry = entries.first(where: { $0.id == item.id }), entry.isSupported else { throw ArchiveError.entry(item.name, "it is not in the table of contents") }
            guard entry.uncompressedSize == item.size else { throw ArchiveError.entry(item.name, "it changed since the archive was listed") }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if entry.compressedSize == 0 && entry.uncompressedSize == 0 {
                guard entry.crc == 0 else { throw ArchiveError.entry(item.name, "an empty file with a checksum") }
                fm.createFile(atPath: dest.path, contents: nil); continue
            }
            let start = try zipDataRange(handle, entry: entry)
            guard start &+ entry.compressedSize <= size else { throw ArchiveError.entry(item.name, "its data is outside the archive") }
            // The compressed bytes are copied (a bounded range) to a file of this extraction's own, and unpacked with the same checked reader the remote ZIP feature uses.
            let part = scratch.appendingPathComponent("\(staging.lastPathComponent).c\(item.id)")
            fm.createFile(atPath: part.path, contents: nil)
            do {
                let out = try FileHandle(forWritingTo: part)
                defer { try? out.close() }
                try handle.seek(toOffset: start)
                var left = entry.compressedSize
                while left > 0 { let chunk = try handle.read(upToCount: Int(min(left, 1 << 20))) ?? Data(); if chunk.isEmpty { throw ArchiveError.damaged("it is cut short") }; try out.write(contentsOf: chunk); left -= UInt64(chunk.count) }
            }
            defer { try? fm.removeItem(at: part) }
            fm.createFile(atPath: dest.path, contents: nil)
            do { _ = try ZipExtractor.unpack(from: part, method: entry.method, to: dest, expectedSize: entry.uncompressedSize, expectedCRC: entry.crc, cancelled: isCancelled) }
            catch let f as ZipExtractor.EntryFailure { throw ArchiveError.entry(item.name, f.reason) }
            catch is CancellationError { throw ArchiveError.cancelled }
            written += Int64(entry.uncompressedSize)
            progress(written, total)
        }
    }

    private static func extractTar(_ file: URL, gzip: Bool, chosen: [ArchiveItem], into staging: URL, limits: ArchiveLimits, written: inout Int64, total: Int64, progress: (Int64, Int64) -> Void, isCancelled: () -> Bool) throws {
        var byIndex: [Int: ArchiveItem] = [:]
        for c in chosen { byIndex[c.id] = c }
        let fm = FileManager.default
        var index = -1
        var current: FileHandle?
        var currentLeft: UInt64 = 0
        var done: Int64 = 0
        defer { try? current?.close() }
        try withoutActuallyEscaping(progress) { progress in
            let reader = TarReader(limits: limits) { event in
                switch event {
                case .entry(let e):
                    try current?.close(); current = nil
                    index += 1
                    guard let item = byIndex[index] else { return }
                    let dest = try target(item, in: staging)
                    if item.isDirectory { try fm.createDirectory(at: dest, withIntermediateDirectories: true); return }
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    fm.createFile(atPath: dest.path, contents: nil, attributes: [.posixPermissions: 0o644])
                    current = try FileHandle(forWritingTo: dest); currentLeft = e.size
                case .data(let bytes):
                    guard let handle = current else { return }
                    guard UInt64(bytes.count) <= currentLeft else { throw ArchiveError.damaged("an entry is longer than it says") }
                    try handle.write(contentsOf: Data(bytes)); currentLeft -= UInt64(bytes.count)
                    done += Int64(bytes.count); progress(done, total)
                case .end: break
                }
            }
            try stream(file, gzip: gzip, limits: limits, isCancelled: isCancelled) { try reader.feed($0) }
            guard reader.finished || reader.atBoundary else { throw ArchiveError.damaged("it is cut short.") }
        }
        try current?.close(); current = nil
        written = done
    }

    /// The finished folder under its own name, or "name 2", "name 3". RENAME_EXCL fails if anything is there, so nothing is merged or replaced.
    private static func place(_ staging: URL, beside destination: URL, base rawBase: String) throws -> URL {
        var base = rawBase
        if base.hasSuffix(".tar") { base = String(base.dropLast(4)) }
        base = DownloadFilename.sanitize(base) ?? "Extracted"
        for n in 1...999 {
            let target = destination.appendingPathComponent(n == 1 ? base : "\(base) \(n)", isDirectory: true)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            if renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST { throw ArchiveError.damaged("the folder could not be created (\(String(cString: strerror(errno)))).") }
        }
        throw ArchiveError.damaged("no free name was found for the new folder.")
    }

    /// The mark that says a file came from the internet, carried to everything taken out of an archive that has it.
    private static func copyQuarantine(from archive: URL, toTreeAt root: URL) {
        let size = getxattr(archive.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(archive.path, "com.apple.quarantine", &value, size, 0, 0) == size else { return }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { setxattr(url.path, "com.apple.quarantine", value, value.count, 0, 0) }
    }
}

/// Whether a gzip file holds a tar archive: its first decompressed block must have the tar "ustar" mark or a valid header checksum.
enum TarGzFirstBlock {
    static func read(_ file: URL) throws -> Bool {
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        let head = try reader.read(upToCount: 64 * 1024) ?? Data()
        guard let start = ArchiveManager.gzipHeaderLength(head), head.count > start else { return false }
        let src = [UInt8](head[head.startIndex + start..<head.endIndex])
        var out = [UInt8](repeating: 0, count: 1024)
        let produced = src.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { d in compression_decode_buffer(d.baseAddress!, d.count, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB) } }
        guard produced >= 512 else { return false }
        if Array(out[257..<262]) == Array("ustar".utf8) { return true }
        // An old-style tar has no mark: the header checksum is the test.
        var sum = 0
        for i in 0..<512 { sum += (148..<156).contains(i) ? 0x20 : Int(out[i]) }
        let field = String(decoding: out[148..<156].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return Int(field, radix: 8) == sum && sum > 0x20 * 8
    }
}

/// Which file this is and what state it is in: device, inode, size and modification time. Two reads that disagree mean the file was replaced or changed in between.
struct FileIdentity: Equatable {
    let device: Int32, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int
    /// The same file or folder, whatever happened inside it (a folder's own size and time change whenever something is created in it).
    func isSameObject(as other: FileIdentity) -> Bool { device == other.device && inode == other.inode }
    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = info.st_dev; inode = UInt64(info.st_ino); size = Int64(info.st_size); seconds = info.st_mtimespec.tv_sec; nanoseconds = info.st_mtimespec.tv_nsec
    }
}
