import CryptoKit
import Foundation

// A file moving between two of the person's own devices over the pairing the local link already has (the one-time code, the encrypted connection). This file holds the parts that
// do not touch the network: what a transfer is, its limits, and how a file is written and checked as it arrives, one piece at a time, so a large file never sits in memory.

struct TransferProgress: Equatable {
    enum State: Equatable { case waiting, sending, receiving, verifying, finished, declined, cancelled, failed(String) }
    var name: String
    var done = 0
    var total = 0
    var state: State = .waiting
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var isActive: Bool { switch state { case .waiting, .sending, .receiving, .verifying: true; default: false } }

    var summary: String {
        switch state {
        case .waiting: "Waiting for the other device to accept “\(name)”…"
        case .sending: "Sending “\(name)”…"
        case .receiving: "Receiving “\(name)”…"
        case .verifying: "Checking “\(name)”…"
        case .finished: "“\(name)” arrived and was checked."
        case .declined: "The other device did not accept “\(name)”."
        case .cancelled: "“\(name)” was cancelled."
        case .failed(let reason): "“\(name)” did not arrive: \(reason)"
        }
    }
}

enum LinkTransferRules {
    /// One piece of a file. Pieces go one at a time, each waiting for the last to be on its way, so memory use stays at this size however large the file is.
    static let chunkBytes = 64 * 1024
    static let maxFileBytes = 2 * 1024 * 1024 * 1024
    static let acceptTimeout: TimeInterval = 60
    static let idleTimeout: TimeInterval = 30
    static let maxIncoming = 2

    /// A file name that cannot collide with one already in the folder (a number is added before the extension).
    static func uniqueURL(name: String, in folder: URL) -> URL {
        let safe = LinkWire.safeFileName(name)
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var candidate = folder.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) && n < 1000 {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    static func hasRoom(for bytes: Int, in folder: URL) -> Bool {
        guard let free = DiskSpace.available(at: folder) else { return true }
        return Int64(bytes) + 100 * 1024 * 1024 < free
    }

    /// The size and SHA-256 of a file, read a piece at a time.
    static func checksum(of url: URL) throws -> (size: Int, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size = 0
        while let data = try handle.read(upToCount: chunkBytes), !data.isEmpty {
            hasher.update(data: data)
            size += data.count
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// A file arriving. Written to a partial file as the pieces come, counted and hashed as it goes; only a whole file whose size and SHA-256 match is given its real name.
final class IncomingFile {
    let id: String
    let name: String
    let size: Int
    let expectedSHA: String
    private let partURL: URL
    private let finalURL: URL
    private let handle: FileHandle
    private var hasher = SHA256()
    private(set) var received = 0
    private(set) var nextIndex = 0
    var lastActivity = Date()

    init?(id: String, name: String, size: Int, sha256: String, folder: URL) {
        guard size >= 0, size <= LinkTransferRules.maxFileBytes, sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }),
              LinkTransferRules.hasRoom(for: size, in: folder) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = LinkTransferRules.uniqueURL(name: name, in: folder)
        let part = folder.appendingPathComponent(".\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil), let handle = try? FileHandle(forWritingTo: part) else { return nil }
        self.id = id; self.name = final.lastPathComponent; self.size = size; self.expectedSHA = sha256.lowercased()
        self.partURL = part; self.finalURL = final; self.handle = handle
    }

    /// Takes the next piece. False when the piece is out of order, or the file would grow past what was offered.
    func append(_ data: Data, index: Int) -> Bool {
        guard index == nextIndex, received + data.count <= size else { return false }
        do { try handle.write(contentsOf: data) } catch { return false }
        hasher.update(data: data)
        received += data.count; nextIndex += 1; lastActivity = Date()
        return true
    }

    /// Closes the file and gives it its name, if everything that was promised arrived.
    func finish() -> URL? {
        try? handle.close()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard received == size, digest == expectedSHA else { discard(); return nil }
        do { try FileManager.default.moveItem(at: partURL, to: finalURL); return finalURL } catch { discard(); return nil }
    }

    func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: partURL)
    }
}
