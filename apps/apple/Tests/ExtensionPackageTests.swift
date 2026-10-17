import Compression
import XCTest
@testable import Browser_Setu

final class ExtensionPackageTests: XCTestCase {
    /// A zip written by hand. `declaredSize` and `crc` default to the truth; passing others builds the lying archives the extractor must refuse.
    private func zip(name: String, content: String, declaredSize: Int? = nil, crc: UInt32? = nil, method: Int = 0, packed: Data? = nil) -> Data {
        let body = [UInt8](packed ?? Data(content.utf8)), n = Array(name.utf8)
        let size = declaredSize ?? content.utf8.count
        let checksum = crc ?? ExtensionPackage.crc32(Data(content.utf8))
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)] }
        // Pieces are joined with `cat`: older Swift compilers cannot type-check a long chain of array additions.
        func cat(_ parts: [[UInt8]]) -> [UInt8] { parts.flatMap { $0 } }
        let sig1: [UInt8] = [0x50, 0x4B, 3, 4], sig2: [UInt8] = [0x50, 0x4B, 1, 2], sig3: [UInt8] = [0x50, 0x4B, 5, 6]
        let crcBytes: [UInt8] = le32(Int(checksum))
        let local: [UInt8] = cat([sig1, le16(20), le16(0), le16(method), le16(0), le16(0), crcBytes, le32(body.count), le32(size), le16(n.count), le16(0), n, body])
        let central: [UInt8] = cat([sig2, le16(20), le16(20), le16(0), le16(method), le16(0), le16(0), crcBytes, le32(body.count), le32(size),
                                    le16(n.count), le16(0), le16(0), le16(0), le16(0), le32(0), le32(0), n])
        let end: [UInt8] = cat([sig3, le16(0), le16(0), le16(1), le16(1), le32(central.count), le32(local.count), le16(0)])
        return Data(cat([local, central, end]))
    }

    /// Raw deflate, as a zip stores it.
    private func deflate(_ data: Data) -> Data? {
        var out = Data()
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        return data.withUnsafeBytes { raw -> Data? in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = data.count
            while true {
                stream.dst_ptr = buffer; stream.dst_size = 4096
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(buffer, count: 4096 - stream.dst_size)
                if status == COMPRESSION_STATUS_END { return out }
                if status == COMPRESSION_STATUS_ERROR { return nil }
            }
        }
    }

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testZipIsUnpacked() throws {
        let out = folder()
        try ExtensionPackage.extract(zip: zip(name: "manifest.json", content: "{\"manifest_version\":3}"), into: out)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("manifest.json"), encoding: .utf8), "{\"manifest_version\":3}")
    }

    func testCrx3HeaderIsStripped() throws {
        let payload = zip(name: "manifest.json", content: "{}")
        let header = Data([0x43, 0x72, 0x32, 0x34, 3, 0, 0, 0, 4, 0, 0, 0, 9, 9, 9, 9])
        XCTAssertEqual(try ExtensionPackage.zipPayload(of: header + payload), payload)
    }

    func testCrx2HeaderIsStripped() throws {
        let payload = zip(name: "manifest.json", content: "{}")
        let header = Data([0x43, 0x72, 0x32, 0x34, 2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 7, 7, 8])
        XCTAssertEqual(try ExtensionPackage.zipPayload(of: header + payload), payload)
    }

    func testAStoredEntryThatIsLongerThanItsDeclaredSizeIsRefused() {
        // Declares 1 byte, carries 4,096: the case that used to be written out in full.
        let big = String(repeating: "A", count: 4096)
        let out = folder()
        XCTAssertThrowsError(try ExtensionPackage.extract(zip: zip(name: "a.txt", content: "A", declaredSize: 1, packed: Data(big.utf8)), into: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("a.txt").path), "nothing is left behind")
    }

    func testAWrongChecksumIsRefused() {
        XCTAssertThrowsError(try ExtensionPackage.extract(zip: zip(name: "a.txt", content: "hello", crc: 12345), into: folder()))
    }

    func testACompressedEntryThatInflatesPastItsDeclaredSizeIsRefused() throws {
        // 8,192 zeros deflated is a few bytes; the entry claims 10.
        let content = String(repeating: "\0", count: 8192)
        let deflated = try XCTUnwrap(deflate(Data(content.utf8)))
        XCTAssertThrowsError(try ExtensionPackage.extract(zip: zip(name: "z.bin", content: content, declaredSize: 10, method: 8, packed: deflated), into: folder()))
        let honest = zip(name: "z.bin", content: content, method: 8, packed: deflated)
        let out = folder()
        XCTAssertNoThrow(try ExtensionPackage.extract(zip: honest, into: out))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("z.bin")).count, 8192)
    }

    /// A stored-entry archive with any number of entries; `centralOffsets` lets a test point two directory entries at the same data.
    private func zipMany(_ items: [(name: String, content: String)], centralOffsets: [Int]? = nil) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)] }
        func cat(_ parts: [[UInt8]]) -> [UInt8] { parts.flatMap { $0 } }
        let sig1: [UInt8] = [0x50, 0x4B, 3, 4], sig2: [UInt8] = [0x50, 0x4B, 1, 2], sig3: [UInt8] = [0x50, 0x4B, 5, 6]
        var local: [UInt8] = [], central: [UInt8] = [], offsets: [Int] = []
        for item in items {
            let body = [UInt8](item.content.utf8), n = Array(item.name.utf8)
            let checksum: [UInt8] = le32(Int(ExtensionPackage.crc32(Data(item.content.utf8))))
            offsets.append(local.count)
            local += cat([sig1, le16(20), le16(0), le16(0), le16(0), le16(0), checksum, le32(body.count), le32(body.count), le16(n.count), le16(0), n, body])
        }
        for (index, item) in items.enumerated() {
            let body = [UInt8](item.content.utf8), n = Array(item.name.utf8)
            let checksum: [UInt8] = le32(Int(ExtensionPackage.crc32(Data(item.content.utf8))))
            let offset: [UInt8] = le32((centralOffsets ?? offsets)[index])
            central += cat([sig2, le16(20), le16(20), le16(0), le16(0), le16(0), le16(0), checksum, le32(body.count), le32(body.count),
                            le16(n.count), le16(0), le16(0), le16(0), le16(0), le32(0), offset, n])
        }
        let end: [UInt8] = cat([sig3, le16(0), le16(0), le16(items.count), le16(items.count), le32(central.count), le32(local.count), le16(0)])
        return Data(cat([local, central, end]))
    }

    func testTheSameNameTwiceIsRefused() {
        XCTAssertNoThrow(try ExtensionPackage.extract(zip: zipMany([("a.txt", "x"), ("b.txt", "y")]), into: folder()))
        XCTAssertThrowsError(try ExtensionPackage.extract(zip: zipMany([("a.txt", "x"), ("A.txt", "y")]), into: folder()), "the same file twice")
    }

    func testTwoEntriesPointingAtTheSameDataAreRefused() {
        let archive = zipMany([("a.txt", "same"), ("b.txt", "same")], centralOffsets: [0, 0])
        XCTAssertThrowsError(try ExtensionPackage.extract(zip: archive, into: folder()), "overlapping entries are how a small archive writes a lot")
    }

    func testTheFolderDigestChangesWithAnyByte() throws {
        let a = folder()
        try "one".write(to: a.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let before = try XCTUnwrap(ExtensionPackage.digest(of: a))
        XCTAssertEqual(before, ExtensionPackage.digest(of: a))
        try "onf".write(to: a.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(before, ExtensionPackage.digest(of: a))
    }

    func testFilesThatEscapeTheFolderAreRefused() {
        XCTAssertThrowsError(try ExtensionPackage.extract(zip: zip(name: "../evil.txt", content: "x"), into: folder()))
        XCTAssertThrowsError(try ExtensionPackage.extract(zip: zip(name: "/etc/evil", content: "x"), into: folder()))
    }

    func testNonPackagesAreRefused() {
        XCTAssertThrowsError(try ExtensionPackage.zipPayload(of: Data("hello world, not a package".utf8)))
    }
}

final class ChromeWebStoreTests: XCTestCase {
    func testIDsAreReadFromAddressesAndPlainIDs() {
        let id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
        XCTAssertEqual(ChromeWebStore.extensionID(from: id), id)
        XCTAssertEqual(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/ublock-origin/\(id)?hl=en"), id)
        XCTAssertEqual(ChromeWebStore.extensionID(from: "https://chrome.google.com/webstore/detail/ublock-origin/\(id)"), id)
        XCTAssertNil(ChromeWebStore.extensionID(from: "https://evil.example/detail/x/\(id)"))
        XCTAssertNil(ChromeWebStore.extensionID(from: "not an id"))
    }

    func testDownloadAddressIsHTTPSOnGoogle() {
        let url = ChromeWebStore.downloadURL(id: "cjpalhdlnbpafiamejdnhcphjbkeiagm")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "clients2.google.com")
    }
}

final class ExtensionCompatibilityTests: XCTestCase {
    func testSupportedPermissionsAreNotFlagged() {
        let manifest: [String: Any] = ["manifest_version": 3, "permissions": ["storage", "tabs", "scripting", "https://*/*", "<all_urls>"]]
        XCTAssertTrue(ExtensionCompatibility.notes(forManifest: manifest).isEmpty)
    }

    func testMissingPermissionsAreNamedInPlainWords() {
        let manifest: [String: Any] = ["manifest_version": 3, "permissions": ["downloads", "storage"], "optional_permissions": ["history", "mysteryapi"]]
        let notes = ExtensionCompatibility.notes(forManifest: manifest)
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes.contains { $0.contains("managing downloads") })
        XCTAssertTrue(notes.contains { $0.contains("mysteryapi") })
    }

    func testManifestV2IsExplainedAndAPersistentBackgroundPageIsMentionedSeparately() {
        let v2: [String: Any] = ["manifest_version": 2, "background": ["scripts": ["b.js"], "persistent": true]]
        let notes = ExtensionCompatibility.notes(forManifest: v2)
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.contains { $0.contains("Manifest V2") })
        XCTAssertTrue(ExtensionCompatibility.notes(forManifest: ["manifest_version": 3]).isEmpty)
    }
}

final class NativeMessagingTests: XCTestCase {
    func testMessagesRoundTripThroughTheFraming() throws {
        var buffer = try NativeFraming.encode(["cmd": "hello", "n": 1]) + NativeFraming.encode("second")
        let messages = try NativeFraming.decode(&buffer)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual((messages[0] as? [String: Any])?["cmd"] as? String, "hello")
        XCTAssertEqual(messages[1] as? String, "second")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testAPartialMessageWaitsForTheRest() throws {
        let whole = try NativeFraming.encode(["a": 1])
        var buffer = whole.prefix(whole.count - 2)
        XCTAssertTrue(try NativeFraming.decode(&buffer).isEmpty)
        buffer.append(whole.suffix(2))
        XCTAssertEqual(try NativeFraming.decode(&buffer).count, 1)
    }

    func testAnOversizedMessageIsRefused() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0x7F, 1, 2, 3])
        XCTAssertThrowsError(try NativeFraming.decode(&buffer))
    }

    func testOnlyAppleHelpersNamedForTheExtensionArePermitted() {
        let id = "pejdijmoenmkgeppbflobdenhhabjlaj"
        let apple = NativeHosts.Manifest(name: "com.apple.passwordmanager", path: "/System/Cryptexes/App/System/Library/CoreServices/Helper.app/Contents/MacOS/Helper",
                                         allowedOrigins: [NativeHosts.origin(for: id)])
        XCTAssertTrue(NativeHosts.isPermitted(apple, chromeID: id))
        XCTAssertFalse(NativeHosts.isPermitted(apple, chromeID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertFalse(NativeHosts.isPermitted(apple, chromeID: nil))
        var elsewhere = apple
        elsewhere.path = "/Users/someone/Downloads/helper"
        XCTAssertFalse(NativeHosts.isPermitted(elsewhere, chromeID: id))
        var traversal = apple
        traversal.path = "/System/../Users/someone/helper"
        XCTAssertFalse(NativeHosts.isPermitted(traversal, chromeID: id))
    }

    func testHostNamesAreValidated() {
        XCTAssertTrue(NativeHosts.isValidName("com.apple.passwordmanager"))
        XCTAssertFalse(NativeHosts.isValidName("../etc/passwd"))
        XCTAssertFalse(NativeHosts.isValidName("Com.Apple"))
        XCTAssertFalse(NativeHosts.isValidName(""))
        XCTAssertFalse(NativeHosts.isValidName("a..b"))
    }
}

final class ExtensionInstallGateTests: XCTestCase {
    @MainActor func testInstallingIsAMacFeature() {
        let center = ExtensionCenter()
        #if os(macOS)
        XCTAssertFalse(center.canInstall, "nothing is attached yet, so it is not available")
        #else
        XCTAssertFalse(center.canInstall)
        #endif
    }
}
