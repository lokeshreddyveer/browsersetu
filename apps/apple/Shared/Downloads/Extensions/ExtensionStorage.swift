import Foundation

/// One extension's own small store of values (its settings, for now), in a folder only that extension's id names. It cannot reach another extension's folder or any other path: the folder is
/// fixed when the store is made, keys are plain names, and nothing here builds a path from a key. Writes are atomic. A private session keeps everything in memory and writes nothing.
final class ExtensionStorage: @unchecked Sendable {
    static let schemaVersion = 1
    static let maxKeyLength = 64
    static let maxValueBytes = 4096
    static let hardQuotaLimit = 65_536

    enum Failure: Error, Equatable, LocalizedError {
        case badKey, valueTooLarge, quotaExceeded, unreadable
        var errorDescription: String? {
            switch self {
            case .badKey: "That is not a usable storage name."
            case .valueTooLarge: "That value is too large to store."
            case .quotaExceeded: "The extension has used all the storage it is allowed."
            case .unreadable: "The extension's saved data could not be read."
            }
        }
    }

    private let file: URL?
    let quota: Int
    private let lock = NSLock()
    private var values: [String: String] = [:]

    /// `folder` nil keeps everything in memory.
    init(folder: URL?, quota: Int) throws {
        file = folder?.appendingPathComponent("storage.json")
        self.quota = min(max(quota, 0), Self.hardQuotaLimit)
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let file, FileManager.default.fileExists(atPath: file.path) {
                guard let data = try? Data(contentsOf: file), data.count <= Self.hardQuotaLimit * 4,
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], (root["v"] as? Int).map({ $0 <= Self.schemaVersion }) == true,
                      let saved = root["values"] as? [String: String] else { throw Failure.unreadable }
                values = saved.filter { Self.validKey($0.key) }
            }
        }
    }

    static func validKey(_ k: String) -> Bool { !k.isEmpty && k.count <= maxKeyLength && k.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-") } }

    var used: Int { lock.lock(); defer { lock.unlock() }; return values.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } }

    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    var all: [String: String] { lock.lock(); defer { lock.unlock() }; return values }

    func set(_ key: String, _ value: String?) throws {
        guard Self.validKey(key) else { throw Failure.badKey }
        lock.lock(); defer { lock.unlock() }
        var next = values
        if let value {
            guard value.utf8.count <= Self.maxValueBytes else { throw Failure.valueTooLarge }
            next[key] = value
        } else { next[key] = nil }
        guard next.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= quota else { throw Failure.quotaExceeded }
        try persist(next)
        values = next
    }

    private func persist(_ v: [String: String]) throws {
        guard let file else { return }
        let data = try JSONSerialization.data(withJSONObject: ["v": Self.schemaVersion, "values": v], options: [.sortedKeys])
        let temp = file.deletingLastPathComponent().appendingPathComponent(".storage.\(UUID().uuidString.prefix(6)).tmp")
        try data.write(to: temp, options: [])
        if rename(temp.path, file.path) != 0 { let e = errno; try? FileManager.default.removeItem(at: temp); throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO) }          // atomic replace
    }

    /// Removes everything (the extension was uninstalled).
    func destroy() {
        lock.lock(); values = [:]; lock.unlock()
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }
}
