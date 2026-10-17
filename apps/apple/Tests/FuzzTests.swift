import XCTest
@testable import Browser_Setu

/// Repeatable fuzzing: valid inputs are damaged in thousands of seeded ways (flipped bytes, cut short, extended, spliced), and every result must be either a clean
/// refusal or something safe. A crash, a hang or a file outside its folder fails the run. The same seed always gives the same cases, so a failure can be replayed.
final class FuzzTests: XCTestCase {
    /// SplitMix64: small, fast and repeatable.
    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    static func mutate(_ data: Data, _ rng: inout Rng) -> Data {
        var bytes = [UInt8](data)
        guard !bytes.isEmpty else { return Data([UInt8.random(in: 0...255, using: &rng)]) }
        switch Int.random(in: 0..<5, using: &rng) {
        case 0: for _ in 0..<Int.random(in: 1...8, using: &rng) { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
        case 1: bytes = Array(bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng)))
        case 2: bytes += (0..<Int.random(in: 1...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        case 3:
            let a = Int.random(in: 0..<bytes.count, using: &rng), b = Int.random(in: 0..<bytes.count, using: &rng)
            bytes.replaceSubrange(min(a, b)..<max(a, b), with: bytes[min(a, b)..<max(a, b)].reversed())
        default:
            let at = Int.random(in: 0..<bytes.count, using: &rng)
            bytes.insert(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF], at: at)
        }
        return Data(bytes)
    }

    private func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testDamagedZipsAreRefusedOrStayInsideTheirFolder() throws {
        var rng = Rng(state: 0xB0B)
        let valid = ZipWriter.zip([("manifest.json", Data("{\"manifest_version\":3,\"name\":\"x\",\"version\":\"1\"}".utf8)), ("a/b.js", Data("var x = 1;".utf8)), ("c.txt", Data(repeating: 0x41, count: 4000))])
        var refused = 0, accepted = 0
        for _ in 0..<3000 {
            let damaged = Self.mutate(valid, &rng)
            let folder = try tempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            do { try ExtensionPackage.extract(zip: damaged, into: folder); accepted += 1 } catch { refused += 1 }
            // Whatever was written is inside the folder and within the size budget.
            let base = folder.standardizedFileURL.path
            var total = 0
            for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])! {
                XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(base), "a file was written outside its folder: \(url.path)")
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            XCTAssertLessThan(total, 1_000_000, "damaged archive wrote more than the original could hold")
        }
        XCTAssertGreaterThan(refused, 100, "the damage should usually be noticed (refused \(refused), accepted \(accepted))")
    }

    func testDamagedExtensionWrappersAreRefusedWithoutCrashing() {
        var rng = Rng(state: 0xC4)
        let zip = ZipWriter.zip([("manifest.json", Data("{}".utf8))])
        let crx3 = Data([0x43, 0x72, 0x32, 0x34, 3, 0, 0, 0, 4, 0, 0, 0, 1, 2, 3, 4]) + zip
        for _ in 0..<3000 { _ = try? ExtensionPackage.zipPayload(of: Self.mutate(crx3, &rng)) }
        for _ in 0..<1000 { _ = try? ExtensionPackage.zipPayload(of: Data((0..<Int.random(in: 0..<40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })) }
    }

    func testRandomManifestsNeverCrashTheReaders() {
        var rng = Rng(state: 0xD1)
        let keys = ["manifest_version", "name", "permissions", "host_permissions", "content_scripts", "commands", "background", "chrome_url_overrides", "action", "version", "declarative_net_request", "optional_permissions"]
        func value(_ depth: Int, _ rng: inout Rng) -> Any {
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: return Int.random(in: -5...5, using: &rng)
            case 1: return ["<all_urls>", "https://*.a.test/*", "tabs", "", "storage", "webRequestBlocking", "declarativeNetRequest"].randomElement(using: &rng)!
            case 2: return depth > 2 ? 0 : (0..<Int.random(in: 0...4, using: &rng)).map { _ in value(depth + 1, &rng) }
            case 3: return depth > 2 ? "x" : Dictionary(uniqueKeysWithValues: (0..<Int.random(in: 0...4, using: &rng)).map { (keys.randomElement(using: &rng)! + "\($0)", value(depth + 1, &rng)) })
            case 4: return NSNull()
            case 5: return Bool.random(using: &rng)
            default: return Double.random(in: -1e9...1e9, using: &rng)
            }
        }
        for i in 0..<4000 {
            var manifest: [String: Any] = [:]
            for key in keys where Bool.random(using: &rng) { manifest[key] = value(0, &rng) }
            _ = ExtensionCompatibility.notes(forManifest: manifest)
            _ = ExtensionManifestSummary(id: "id\(i)", name: "n", version: "1", manifest: manifest)
        }
    }

    func testDamagedBackupsNeverOpenToSomethingElse() throws {
        var rng = Rng(state: 0xE5)
        let original = BackupPayload(created: Date(timeIntervalSince1970: 1_700_000_000), bookmarks: [BackupPayload.Bookmark(url: "https://a.test", title: "A", folder: "")], settings: ["accent": "blue"])
        let sealed = try BackupFile.seal(original, passphrase: "correct horse", iterations: 1_000)
        for _ in 0..<1500 {
            let damaged = Self.mutate(sealed, &rng)
            if damaged == sealed { continue }
            if let opened = try? BackupFile.open(damaged, passphrase: "correct horse") {
                XCTAssertEqual(opened, original, "a damaged backup opened to different contents")
            }
        }
        XCTAssertEqual(try BackupFile.open(sealed, passphrase: "correct horse"), original)
        XCTAssertThrowsError(try BackupFile.open(sealed, passphrase: "wrong"))
    }

    func testDamagedSyncPayloadsAreDecodedOrRefused() throws {
        var rng = Rng(state: 0xF7)
        let payload = BackupPayload(created: Date(), bookmarks: (0..<20).map { BackupPayload.Bookmark(url: "https://a.test/\($0)", title: "T\($0)", folder: "F") },
                                    settings: ["accent": "blue", "layout_preset": "sidebar"], tabs: [BackupPayload.Tab(url: "https://a.test", title: "A")])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(payload)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for _ in 0..<4000 {
            guard let decoded = try? decoder.decode(BackupPayload.self, from: Self.mutate(json, &rng)) else { continue }
            // Whatever decodes is still filtered the same way before it is used.
            _ = SyncRules.bookmarksToAdd(remote: decoded.bookmarks, existing: [])
            _ = SyncRules.acceptedSettings(decoded.settings)
            let tabs = SyncRules.cleanTabs(decoded.tabs ?? [])
            XCTAssertTrue(tabs.allSatisfy { ["http", "https"].contains(URL(string: $0.url)?.scheme ?? "") }, "a sync payload slipped in a non-web tab")
            XCTAssertLessThanOrEqual(tabs.count, SyncRules.maxTabs)
        }
    }

    func testDamagedDeviceMessagesAreRefusedWithoutHugeAllocations() throws {
        var rng = Rng(state: 0xA9)
        let message = LinkMessage(kind: .text, name: "n", text: "hello", data: nil)
        let framed = try LinkWire.frame(message)
        for _ in 0..<4000 {
            var buffer = Self.mutate(framed, &rng)
            _ = try? LinkWire.unframe(&buffer)
            XCTAssertLessThanOrEqual(buffer.count, framed.count + 80, "the buffer grew while reading")
        }
        var oversized = Data([0x7F, 0xFF, 0xFF, 0xFF]) + Data(repeating: 0, count: 8)
        XCTAssertThrowsError(try LinkWire.unframe(&oversized))
    }
}
