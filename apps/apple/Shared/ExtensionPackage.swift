import Compression
import CryptoKit
import Foundation

/// Opens an extension packed as Chrome packs it: a `.crx` file (a zip behind a short signed header) or a plain `.zip`. Nothing is run or fetched; the
/// files are only unpacked into a new temporary folder, which is then inspected and approved exactly like a folder the user chose. The signature
/// in a `.crx` is not verified: the user reviews what the extension asks for, and what is installed is exactly what was reviewed (see `digest`).
enum ExtensionPackage {
    enum Failure: LocalizedError {
        case notAPackage, unsafePath(String), tooLarge(Int), tooManyFiles(Int), unsupported

        var errorDescription: String? {
            switch self {
            case .notAPackage: "That file is not an extension package (.crx or .zip)."
            case .unsafePath(let name): "The package holds a file that would be written outside its own folder (“\(name)”), so it was not opened."
            case .tooLarge(let bytes): "That extension is \(bytes / 1_048_576) MB once unpacked, and the limit is \(ExtensionPackage.maxUnpacked / 1_048_576) MB."
            case .tooManyFiles(let count): "That extension holds \(count) files, and the limit is \(ExtensionPackage.maxEntries)."
            case .unsupported: "That package uses a zip feature Browser Setu cannot read. Unpack it and choose the folder instead."
            }
        }
    }

    static let maxUnpacked = 300 * 1024 * 1024
    static let maxEntries = 20_000

    /// The unpacked extension, in a new folder the caller owns. The work is done off the main thread; see `unpackAsync`.
    static func unpack(file: URL) throws -> URL {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        // A package larger than the unpacked limit cannot unpack to less than that limit's worth of useful content: refuse it before reading it.
        let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= maxUnpacked else { throw Failure.tooLarge(fileSize) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("extension-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try extract(zip: try zipPayload(of: data), into: folder)
            // Chrome packs the extension at the top of the archive; some zips wrap it in one folder.
            return try rootOfExtension(in: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The same, on a background thread, so unpacking never stalls the window.
    static func unpackAsync(file: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try unpack(file: file) }.value
    }

    /// The zip inside a `.crx` (version 2 or 3), or the data itself when it is already a zip.
    static func zipPayload(of data: Data) throws -> Data {
        let b = [UInt8](data.prefix(16))
        if b.count >= 4, b[0] == 0x50, b[1] == 0x4B { return data }
        guard b.count >= 12, b[0] == 0x43, b[1] == 0x72, b[2] == 0x32, b[3] == 0x34 else { throw Failure.notAPackage }   // "Cr24"
        func u32(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
        let version = u32(4)
        let start: Int
        switch version {
        case 3: start = 12 + u32(8)
        case 2:
            guard b.count >= 16 else { throw Failure.notAPackage }
            start = 16 + u32(8) + u32(12)
        default: throw Failure.unsupported
        }
        guard start > 0, start < data.count else { throw Failure.notAPackage }
        return data.suffix(from: data.startIndex + start)
    }

    /// CRC-32 as zip uses it.
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 { data.withUnsafeBytes { crc(0, $0.bindMemory(to: UInt8.self)) } }

    private static func crc(_ crc: UInt32, _ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var c = ~crc
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }

    /// Unpacks a zip into `folder`, holding to what the archive actually contains, not what it says about itself: stored entries must be exactly as long as they
    /// claim, compressed entries are inflated in small pieces and stopped the moment they pass their declared size or the total budget, every file's CRC must
    /// match, and entries that overlap or repeat a name are refused.
    static func extract(zip: Data, into folder: URL) throws {
        try zip.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let z = raw.bindMemory(to: UInt8.self)
            func u16(_ at: Int) -> Int { Int(z[at]) | Int(z[at + 1]) << 8 }
            func u32(_ at: Int) -> Int { Int(z[at]) | Int(z[at + 1]) << 8 | Int(z[at + 2]) << 16 | Int(z[at + 3]) << 24 }
            guard z.count >= 22 else { throw Failure.notAPackage }
            var eocd = -1
            var i = z.count - 22
            while i >= max(0, z.count - 22 - 65_535) {
                if z[i] == 0x50, z[i + 1] == 0x4B, z[i + 2] == 5, z[i + 3] == 6 { eocd = i; break }
                i -= 1
            }
            guard eocd >= 0 else { throw Failure.notAPackage }
            let count = u16(eocd + 10), directory = u32(eocd + 16)
            guard count != 0xFFFF, directory != 0xFFFF_FFFF else { throw Failure.unsupported }       // zip64
            guard count <= maxEntries else { throw Failure.tooManyFiles(count) }

            struct Entry { var name: String; var nameBytes: [UInt8]; var method: Int; var crc: UInt32; var compressed: Int; var size: Int; var offset: Int }
            var entries: [Entry] = []
            var at = directory, declaredTotal = 0
            var names = Set<String>()
            for _ in 0..<count {
                guard at >= 0, at + 46 <= z.count, z[at] == 0x50, z[at + 1] == 0x4B, z[at + 2] == 1, z[at + 3] == 2 else { throw Failure.notAPackage }
                let flags = u16(at + 8), method = u16(at + 10)
                let entryCRC = UInt32(truncatingIfNeeded: u32(at + 16))
                let compressed = u32(at + 20), size = u32(at + 24)
                let nameLength = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32), offset = u32(at + 42)
                guard at + 46 + nameLength <= z.count else { throw Failure.notAPackage }
                guard flags & 1 == 0 else { throw Failure.unsupported }                              // encrypted
                let nameBytes = Array(z[(at + 46)..<(at + 46 + nameLength)])
                let name = String(decoding: nameBytes, as: UTF8.self)
                guard names.insert(name.lowercased()).inserted else { throw Failure.unsafePath(name) }   // the same file twice
                declaredTotal += size
                guard declaredTotal <= maxUnpacked else { throw Failure.tooLarge(declaredTotal) }
                entries.append(Entry(name: name, nameBytes: nameBytes, method: method, crc: entryCRC, compressed: compressed, size: size, offset: offset))
                at += 46 + nameLength + extra + comment
            }

            // The data of two entries must never overlap: that is how a small archive is made to write a lot.
            var spans: [(Int, Int)] = []
            let root = folder.standardizedFileURL.path
            var written = 0
            for entry in entries {
                let name = entry.name
                guard !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/").contains("..") else { throw Failure.unsafePath(name) }
                let target = folder.appendingPathComponent(name).standardizedFileURL
                guard target.path.hasPrefix(root + "/") || target.path == root else { throw Failure.unsafePath(name) }
                if name.hasSuffix("/") {
                    guard entry.size == 0, entry.compressed <= 2 else { throw Failure.notAPackage }
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                guard entry.offset >= 0, entry.offset + 30 <= z.count, z[entry.offset] == 0x50, z[entry.offset + 1] == 0x4B, z[entry.offset + 2] == 3, z[entry.offset + 3] == 4 else { throw Failure.notAPackage }
                let localName = u16(entry.offset + 26), localExtra = u16(entry.offset + 28)
                guard entry.offset + 30 + localName <= z.count, Array(z[(entry.offset + 30)..<(entry.offset + 30 + localName)]) == entry.nameBytes else { throw Failure.notAPackage }
                let begin = entry.offset + 30 + localName + localExtra
                guard begin + entry.compressed <= z.count else { throw Failure.notAPackage }
                spans.append((entry.offset, begin + entry.compressed))
                let packed = UnsafeBufferPointer(rebasing: z[begin..<(begin + entry.compressed)])

                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: target.path, contents: nil), let handle = try? FileHandle(forWritingTo: target) else { throw Failure.notAPackage }
                var fileCRC: UInt32 = 0
                var fileBytes = 0
                do {
                    defer { try? handle.close() }
                    switch entry.method {
                    case 0:
                        // Stored: it must be exactly as long as it says.
                        guard entry.compressed == entry.size else { throw Failure.notAPackage }
                        fileCRC = crc(0, packed); fileBytes = packed.count; written += packed.count
                        guard written <= maxUnpacked else { throw Failure.tooLarge(written) }
                        try handle.write(contentsOf: Data(packed))
                    case 8:
                        try inflate(packed, expecting: entry.size, budget: maxUnpacked - written) { chunk in
                            fileCRC = crc(fileCRC, chunk); fileBytes += chunk.count; written += chunk.count
                            try handle.write(contentsOf: Data(chunk))
                        }
                    default: throw Failure.unsupported
                    }
                } catch { try? FileManager.default.removeItem(at: target); throw error }
                guard fileBytes == entry.size, fileCRC == entry.crc else { try? FileManager.default.removeItem(at: target); throw Failure.notAPackage }
            }
            spans.sort { $0.0 < $1.0 }
            for (earlier, later) in Swift.zip(spans, spans.dropFirst()) where later.0 < earlier.1 { throw Failure.notAPackage }
        }
    }

    /// Inflates raw deflate data a piece at a time. Stops with an error as soon as the output would pass `expecting` or the remaining `budget`, and
    /// fails if it ends with anything other than exactly `expecting` bytes.
    private static func inflate(_ packed: UnsafeBufferPointer<UInt8>, expecting: Int, budget: Int, sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        guard expecting <= budget else { throw Failure.tooLarge(maxUnpacked + 1) }
        if packed.isEmpty { guard expecting == 0 else { throw Failure.notAPackage }; return }
        let chunkSize = 64 * 1024
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { output.deallocate() }
        var stream = compression_stream(dst_ptr: output, dst_size: 0, src_ptr: packed.baseAddress!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw Failure.unsupported }
        defer { compression_stream_destroy(&stream) }
        stream.src_ptr = packed.baseAddress!
        stream.src_size = packed.count
        var produced = 0
        while true {
            stream.dst_ptr = output
            stream.dst_size = chunkSize
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let count = chunkSize - stream.dst_size
            produced += count
            guard produced <= expecting else { throw Failure.tooLarge(produced) }
            if count > 0 { try sink(UnsafeBufferPointer(start: output, count: count)) }
            if status == COMPRESSION_STATUS_END { break }
            guard status == COMPRESSION_STATUS_OK, count > 0 || stream.src_size > 0 else { throw Failure.notAPackage }
        }
        guard produced == expecting else { throw Failure.notAPackage }
    }

    private static func rootOfExtension(in folder: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        let inside = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let folders = inside.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if folders.count == 1, FileManager.default.fileExists(atPath: folders[0].appendingPathComponent("manifest.json").path) { return folders[0] }
        return folder
    }

    /// Removes an unpacked extension folder made by `unpack`, whatever depth inside it `folder` points to. Anything else is left alone.
    static func discardUnpacked(_ folder: URL) {
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        var url = folder.standardizedFileURL
        guard url.path.hasPrefix(temp + "/") else { return }
        while url.deletingLastPathComponent().path != temp {
            let parent = url.deletingLastPathComponent()
            guard parent.path.count > temp.count else { return }
            url = parent
        }
        guard url.lastPathComponent.hasPrefix("extension-") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Unpacked folders and downloads left behind by an earlier run (an approval that was cancelled, a crash).
    static func purgeStale(olderThan age: TimeInterval = 3600) {
        let temp = FileManager.default.temporaryDirectory
        for item in (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let name = item.lastPathComponent
            guard name.hasPrefix("extension-") || (name.hasSuffix(".crx") && name.count == 36) else { continue }
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// A SHA-256 over every file's path and contents, in a fixed order: the same bytes always give the same answer, and any change gives another.
    static func digest(of folder: URL) -> String? {
        let base = folder.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        var files: [URL] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
        var hasher = SHA256()
        for url in files.sorted(by: { $0.standardizedFileURL.path < $1.standardizedFileURL.path }) {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            hasher.update(data: Data(relative.utf8)); hasher.update(data: Data([0]))
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var length = 0
            while let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty { hasher.update(data: chunk); length += chunk.count }
            hasher.update(data: Data("|\(length)|".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
