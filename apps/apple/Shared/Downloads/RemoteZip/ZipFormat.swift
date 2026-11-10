import Foundation

// Phase 20: reading a ZIP archive's table of contents from pieces of it, without the rest. Everything here works on bytes it is handed and says exactly what it cannot handle.
//
// Supported: the ordinary end-of-central-directory record, the ZIP64 end-of-central-directory locator and record, central-directory entries (with their ZIP64 extra field), stored (0) and
// deflated (8) entries, UTF-8 or legacy names, directories. Not supported, and named as such: encryption of any kind, other compression methods, archives in several parts, links and
// other special files, entries whose position or size cannot be right.

struct ZipEntry: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case supported, unsupported(String) }
    let id: Int
    /// The name as the archive wrote it.
    var name: String
    /// The name as safe folder and file names, when it is safe. Never contains "..", an empty part, a separator inside a part, or a leading slash.
    var path: [String]?
    var isDirectory: Bool
    var method: UInt16
    var flags: UInt16
    var crc: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var localHeaderOffset: UInt64
    var nameLength: Int
    var status: Status

    var isSupported: Bool { status == .supported }
}

enum ZipError: Error, Equatable, LocalizedError {
    case notAZip, multiVolume, tooLarge(String), malformed(String), zip64Missing

    var errorDescription: String? {
        switch self {
        case .notAZip: "This does not look like a ZIP archive."
        case .multiVolume: "Archives in several parts are not supported."
        case .tooLarge(let why): why
        case .malformed(let why): "The archive's table of contents is not valid: \(why)."
        case .zip64Missing: "The archive needs a ZIP64 record that is not there."
        }
    }
}

enum ZipFormat {
    static let maxEntries = 10_000
    static let maxCentralDirectory = 16 * 1024 * 1024
    static let maxCommentLength = 65_535
    static let eocdSize = 22
    static let locatorSize = 20
    static let zip64RecordSize = 56
    /// Bytes at the end of an archive that always contain the end-of-central-directory record, and the ZIP64 locator before it.
    static let tailSize = eocdSize + maxCommentLength + locatorSize
    static let maxNameBytes = 1024
    static let maxDepth = 16
    static let maxEntrySize: UInt64 = 8 * 1024 * 1024 * 1024
    static let maxExpansion: UInt64 = 200

    // MARK: Little-endian reads (bounds checked by callers)

    static func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 }
    static func u32(_ d: Data, _ o: Int) -> UInt32 { UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 }
    static func u64(_ d: Data, _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }

    // MARK: End of central directory

    struct EndRecord: Equatable, Sendable {
        var entries: UInt64
        var centralSize: UInt64
        var centralOffset: UInt64
        /// Where the record itself starts in the archive.
        var recordOffset: UInt64
        /// Set when the 32-bit fields are full: where the ZIP64 end-of-central-directory record is, to be fetched and passed to `applyZip64`.
        var zip64RecordOffset: UInt64?
    }

    /// Finds the record in the last bytes of an archive of `archiveSize` bytes. The comment is the end of the file: a signature inside it, or anything after the record, is not accepted.
    static func findEnd(tail: Data, archiveSize: UInt64) throws -> EndRecord {
        guard tail.count >= eocdSize else { throw ZipError.notAZip }
        let base = archiveSize - UInt64(tail.count)
        var position = tail.count - eocdSize
        let lowest = max(0, tail.count - eocdSize - maxCommentLength)
        while position >= lowest {
            if u32(tail, position) == 0x0605_4b50, Int(u16(tail, position + 20)) == tail.count - position - eocdSize {
                // Several parts: refused, not guessed at.
                guard u16(tail, position + 4) == 0, u16(tail, position + 6) == 0 else { throw ZipError.multiVolume }
                let entriesHere = u16(tail, position + 8), entries = u16(tail, position + 10)
                guard entriesHere == entries else { throw ZipError.multiVolume }
                var record = EndRecord(entries: UInt64(entries), centralSize: UInt64(u32(tail, position + 12)), centralOffset: UInt64(u32(tail, position + 16)), recordOffset: base + UInt64(position))
                if entries == 0xFFFF || u32(tail, position + 12) == 0xFFFF_FFFF || u32(tail, position + 16) == 0xFFFF_FFFF {
                    let at = position - locatorSize
                    guard at >= 0, u32(tail, at) == 0x0706_4b50 else { throw ZipError.zip64Missing }
                    guard u32(tail, at + 4) == 0, u32(tail, at + 16) <= 1 else { throw ZipError.multiVolume }
                    record.zip64RecordOffset = u64(tail, at + 8)
                }
                return record
            }
            position -= 1
        }
        throw ZipError.notAZip
    }

    /// Replaces the 32-bit values with the 64-bit ones from the ZIP64 record (56 bytes at least), after checking it is what the locator said.
    static func applyZip64(_ record: Data, to end: EndRecord) throws -> EndRecord {
        guard record.count >= zip64RecordSize, u32(record, 0) == 0x0606_4b50 else { throw ZipError.malformed("the ZIP64 record is missing or damaged") }
        guard u32(record, 16) == 0, u32(record, 20) == 0, u64(record, 24) == u64(record, 32) else { throw ZipError.multiVolume }
        var out = end
        out.entries = u64(record, 32); out.centralSize = u64(record, 40); out.centralOffset = u64(record, 48)
        out.zip64RecordOffset = nil
        return out
    }

    /// The central directory must lie wholly inside the archive, before the records that end it, and be of a size that holds that many entries and no more than the cap.
    static func validate(_ end: EndRecord, archiveSize: UInt64) throws {
        guard end.entries <= UInt64(maxEntries) else { throw ZipError.tooLarge("The archive lists more than \(maxEntries) entries.") }
        guard end.centralSize <= UInt64(maxCentralDirectory) else { throw ZipError.tooLarge("The archive's table of contents is too large to read safely.") }
        guard end.centralSize >= end.entries * 46 else { throw ZipError.malformed("the table of contents is too small for its entries") }
        let (stop, overflow) = end.centralOffset.addingReportingOverflow(end.centralSize)
        guard !overflow, stop <= end.recordOffset, stop <= archiveSize else { throw ZipError.malformed("the table of contents is outside the archive") }
    }

    // MARK: Central directory

    static func parseCentralDirectory(_ data: Data, entries expected: UInt64, archiveSize: UInt64, centralOffset: UInt64) throws -> [ZipEntry] {
        guard expected <= UInt64(maxEntries), data.count <= maxCentralDirectory else { throw ZipError.tooLarge("The archive is too large to list.") }
        var out: [ZipEntry] = []
        var pos = 0
        while out.count < Int(expected) {
            guard pos + 46 <= data.count, u32(data, pos) == 0x0201_4b50 else { throw ZipError.malformed("an entry is cut short or misplaced") }
            let flags = u16(data, pos + 8), method = u16(data, pos + 10), crc = u32(data, pos + 16)
            var csize = UInt64(u32(data, pos + 20)), usize = UInt64(u32(data, pos + 24))
            let nameLen = Int(u16(data, pos + 28)), extraLen = Int(u16(data, pos + 30)), commentLen = Int(u16(data, pos + 32))
            let diskStart = u16(data, pos + 34), external = u32(data, pos + 38)
            var offset = UInt64(u32(data, pos + 42))
            let madeBy = u16(data, pos + 4) >> 8
            let next = pos + 46 + nameLen + extraLen + commentLen
            guard next <= data.count, nameLen > 0 else { throw ZipError.malformed("an entry's name or extra data runs past the table") }
            let nameBytes = data.subdata(in: (data.startIndex + pos + 46)..<(data.startIndex + pos + 46 + nameLen))
            // ZIP64: a field that is full is read, in this order, from the extra data. Reading it as an ordinary 32-bit value would give a wrong position.
            var needsDiskStart = diskStart == 0xFFFF
            if usize == 0xFFFF_FFFF || csize == 0xFFFF_FFFF || offset == 0xFFFF_FFFF || needsDiskStart {
                var found = false
                var e = pos + 46 + nameLen, end = e + extraLen
                while e + 4 <= end {
                    let id = u16(data, e), size = Int(u16(data, e + 2))
                    guard e + 4 + size <= end else { throw ZipError.malformed("an extra field runs past its entry") }
                    if id == 0x0001 {
                        var f = e + 4
                        let stop = e + 4 + size
                        func read() throws -> UInt64 { guard f + 8 <= stop else { throw ZipError.malformed("the ZIP64 data of an entry is too short") }; defer { f += 8 }; return u64(data, f) }
                        if usize == 0xFFFF_FFFF { usize = try read() }
                        if csize == 0xFFFF_FFFF { csize = try read() }
                        if offset == 0xFFFF_FFFF { offset = try read() }
                        if needsDiskStart { guard f + 4 <= stop else { throw ZipError.malformed("the ZIP64 data of an entry is too short") }; if u32(data, f) != 0 { throw ZipError.multiVolume }; needsDiskStart = false }
                        found = true; break
                    }
                    e += 4 + size
                }
                end = 0
                guard found else { throw ZipError.zip64Missing }
            }
            guard diskStart == 0 || diskStart == 0xFFFF else { throw ZipError.multiVolume }
            var entry = ZipEntry(id: out.count, name: "", path: nil, isDirectory: false, method: method, flags: flags, crc: crc, compressedSize: csize, uncompressedSize: usize,
                                 localHeaderOffset: offset, nameLength: nameLen, status: .supported)
            decorate(&entry, nameBytes: nameBytes, madeBy: UInt8(madeBy), external: external, centralOffset: centralOffset)
            out.append(entry)
            pos = next
        }
        guard pos == data.count else { throw ZipError.malformed("there is unexplained data after the last entry") }
        flagProblems(&out, centralOffset: centralOffset)
        return out
    }

    /// Names, kinds and the reasons an entry cannot be taken.
    private static func decorate(_ e: inout ZipEntry, nameBytes: Data, madeBy: UInt8, external: UInt32, centralOffset: UInt64) {
        func refuse(_ why: String) { if e.status == .supported { e.status = .unsupported(why) } }
        let utf8 = e.flags & 0x0800 != 0
        if let s = String(data: nameBytes, encoding: .utf8) { e.name = s }
        else if utf8 { e.name = String(decoding: nameBytes, as: UTF8.self); refuse("Its name is not valid text.") }
        else { e.name = String(data: nameBytes, encoding: .isoLatin1) ?? ""; }
        e.isDirectory = e.name.hasSuffix("/")
        e.path = safePath(e.name)
        if e.path == nil { refuse("Its name is not a safe path (it climbs out of the folder, is absolute, or has unusable characters).") }
        if e.flags & 0x0001 != 0 || e.flags & 0x0040 != 0 { refuse("It is encrypted.") }
        if !e.isDirectory {
            if e.method != 0 && e.method != 8 { refuse("It uses compression method \(e.method), which is not supported.") }
            if e.method == 0, e.compressedSize != e.uncompressedSize { refuse("Its stored size is inconsistent.") }
            if e.uncompressedSize > maxEntrySize || e.compressedSize > maxEntrySize { refuse("It is larger than the limit for one file.") }
            if e.uncompressedSize > 1 << 20, e.compressedSize == 0 || e.uncompressedSize / max(e.compressedSize, 1) > maxExpansion { refuse("It expands far more than a normal file does.") }
        } else if e.uncompressedSize != 0 || e.compressedSize > 2 { refuse("A folder with contents is not valid.") }
        // Unix mode in the high half of the external attributes, when the archive was made on Unix (3) or macOS (19): only plain files and folders are taken.
        if madeBy == 3 || madeBy == 19 {
            let mode = external >> 16
            let kind = mode & 0xF000
            if kind == 0xA000 { refuse("It is a link, which is not extracted.") }
            else if kind != 0, kind != 0x8000, kind != 0x4000 { refuse("It is a special file, which is not extracted.") }
        }
        if e.localHeaderOffset >= centralOffset { refuse("Its position is outside the archive's data.") }
    }

    /// Name to folder and file names. Refuses anything that could land outside the folder it is put in.
    static func safePath(_ name: String) -> [String]? {
        // Everything is decided on the bytes (a "/" followed by a combining mark is still a separator to the file system, whatever a string comparison says).
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= maxNameBytes, bytes[0] != 0x2F, !bytes.contains(0x5C), !bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }) else { return nil }
        if bytes.count >= 2, bytes[1] == 0x3A { return nil }                                          // a drive letter
        var parts = bytes.split(separator: 0x2F, omittingEmptySubsequences: false).map { Array($0) }
        if parts.last?.isEmpty == true { parts.removeLast() }                                         // a folder's trailing slash
        guard !parts.isEmpty, parts.count <= maxDepth else { return nil }
        for p in parts {
            guard !p.isEmpty, p != [0x2E], p != [0x2E, 0x2E], p.count <= 255, !p.contains(0x3A) else { return nil }
        }
        return parts.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Entries that cannot all be true together: overlapping data, the same name twice (also when only the case differs), a name that is both a file and a folder.
    private static func flagProblems(_ entries: inout [ZipEntry], centralOffset: UInt64) {
        let order = entries.indices.filter { entries[$0].isSupported }.sorted { entries[$0].localHeaderOffset < entries[$1].localHeaderOffset }
        for (n, i) in order.enumerated() {
            let start = entries[i].localHeaderOffset
            let need = start &+ 30 &+ UInt64(entries[i].nameLength) &+ entries[i].compressedSize
            let limit = n + 1 < order.count ? entries[order[n + 1]].localHeaderOffset : centralOffset
            if need > limit || need < start {
                entries[i].status = .unsupported("Its data overlaps another entry.")
                if n + 1 < order.count, entries[order[n + 1]].isSupported, entries[order[n + 1]].localHeaderOffset == start { entries[order[n + 1]].status = .unsupported("Its data overlaps another entry.") }
            }
            if n > 0, entries[order[n - 1]].localHeaderOffset == start, entries[i].isSupported { entries[i].status = .unsupported("Its data overlaps another entry.") }
        }
        var seen: [String: Int] = [:]
        var folders = Set<String>()
        for i in entries.indices where entries[i].isSupported {
            guard let path = entries[i].path else { continue }
            // Names that the file system treats as one (case, and equivalent Unicode spellings) are one name.
            let key = path.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            if seen[key] != nil { entries[i].status = .unsupported("Another entry has the same name."); continue }
            seen[key] = i
            for k in 1..<max(1, path.count) { folders.insert(path[0..<k].joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()) }
        }
        for i in entries.indices where entries[i].isSupported && !entries[i].isDirectory {
            if let path = entries[i].path, folders.contains(path.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()) { entries[i].status = .unsupported("A file and a folder have the same name.") }
        }
    }

    // MARK: Local header

    /// Where an entry's data starts, from its local header (30 bytes plus name and extra field, at least the first 30 given) and what the central directory said.
    static func dataStart(localHeader h: Data, entry: ZipEntry) throws -> UInt64 {
        guard h.count >= 30, u32(h, 0) == 0x0403_4b50 else { throw ZipError.malformed("an entry's header is missing") }
        guard u16(h, 8) == entry.method else { throw ZipError.malformed("an entry's header disagrees with the table of contents") }
        guard (u16(h, 6) & 0x0001) == 0 else { throw ZipError.malformed("an entry is encrypted") }
        let (a, o1) = entry.localHeaderOffset.addingReportingOverflow(30 + UInt64(u16(h, 26)) + UInt64(u16(h, 28)))
        guard !o1 else { throw ZipError.malformed("an entry's position is not valid") }
        return a
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(update crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
    static func crc32(_ data: Data) -> UInt32 { data.withUnsafeBytes { crc32(update: 0, $0) } }
}
