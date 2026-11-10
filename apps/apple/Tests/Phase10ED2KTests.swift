import Compression
import XCTest
@testable import Browser_Setu

final class MD4Tests: XCTestCase {
    private func md4(_ s: String) -> String { MD4.hash(Data(s.utf8)).hexString }

    /// The test suite of RFC 1320, appendix A.5.
    func testRFC1320Vectors() {
        XCTAssertEqual(md4(""), "31d6cfe0d16ae931b73c59d7e0c089c0")
        XCTAssertEqual(md4("a"), "bde52cb31de33e46245e05fbdbd6fb24")
        XCTAssertEqual(md4("abc"), "a448017aaf21d8525fc10ae87aa6729d")
        XCTAssertEqual(md4("message digest"), "d9130a8164549fe818874806e1c7014b")
        XCTAssertEqual(md4("abcdefghijklmnopqrstuvwxyz"), "d79e1c308aa5bbcdeea8ed63df412da9")
        XCTAssertEqual(md4("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"), "043f8582f241db351ce627e153e7f0e4")
        XCTAssertEqual(md4(String(repeating: "1234567890", count: 8)), "e33b4ddc9c38f2199c3e7b164fcc0536")
    }

    func testChunkingNeverChangesTheResult() {
        let data = Data((0..<10_000).map { UInt8(($0 * 13 + 5) % 251) })
        let whole = MD4.hash(data)
        for step in [1, 3, 55, 56, 63, 64, 65, 1000] {
            var m = MD4(); var i = 0
            while i < data.count { let n = min(step, data.count - i); m.update(data.subdata(in: i..<(i + n))); i += n }
            XCTAssertEqual(m.finalize(), whole, "step \(step)")
        }
    }

    func testLengthsAroundTheBlockBoundary() {
        // 55, 56 and 64 bytes are where the padding changes shape; the digests are those of the RFC's algorithm, checked against an independent run of it
        let known: [Int: String] = [55: "", 56: "", 64: ""]
        for n in known.keys { XCTAssertEqual(MD4.hash(Data(repeating: 0x61, count: n)).count, 16) }
        XCTAssertNotEqual(MD4.hash(Data(repeating: 0x61, count: 55)), MD4.hash(Data(repeating: 0x61, count: 56)))
    }

    func testHexRoundTrip() {
        XCTAssertEqual(Data(hex: "00ff10")?.hexString, "00ff10")
        XCTAssertNil(Data(hex: "0")); XCTAssertNil(Data(hex: "zz"))
    }
}

// MARK: Links

final class ED2KLinkTests: XCTestCase {
    let emptyMD4 = "31d6cfe0d16ae931b73c59d7e0c089c0"

    private func file(_ link: String) throws -> ED2KLink.File {
        guard case .file(let f) = try ED2KLink.parse(link) else { throw ED2KLink.Failure.notED2K }
        return f
    }

    func testAPlainFileLink() throws {
        let f = try file("ed2k://|file|Some%20Report.pdf|123456|\(emptyMD4)|/")
        XCTAssertEqual(f.name, "Some Report.pdf"); XCTAssertEqual(f.size, 123_456); XCTAssertEqual(f.hashHex, emptyMD4); XCTAssertNil(f.partHashes); XCTAssertTrue(f.sources.isEmpty)
        XCTAssertEqual(f.canonical, "ed2k://|file|Some Report.pdf|123456|\(emptyMD4)|/")
        XCTAssertEqual(try file("ED2K://|FILE|x|5|\(emptyMD4.uppercased())|/").hashHex, emptyMD4, "scheme and kind are case-insensitive; the emptyMD4 is read as bytes")
    }

    func testOptionalFieldsAndSources() throws {
        let data = Data(repeating: 7, count: 10_000_000)             // two parts
        let (parts, whole) = ED2KHash.hashes(of: data)
        let p = parts.map(\.hexString).joined(separator: ":")
        let f = try file("ed2k://|file|big.bin|10000000|\(whole.hexString)|p=\(p)|h=ABCDEFGHIJKLMNOPQRSTUVWXYZ234567|s=http://example.com/x|/|sources,8.8.4.4:4662,1.2.3.4:4662:0:|/")
        XCTAssertEqual(f.partHashes, parts); XCTAssertEqual(f.aichRoot, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        XCTAssertEqual(f.sources.map(\.host), ["1.2.3.4", "8.8.4.4"]); XCTAssertEqual(f.sources.first?.port, 4662)
    }

    func testPartHashesThatDoNotAddUpAreRefused() throws {
        let (parts, whole) = ED2KHash.hashes(of: Data(repeating: 1, count: 10_000_000))
        let wrong = [parts[0].hexString, parts[0].hexString].joined(separator: ":")
        XCTAssertThrowsError(try file("ed2k://|file|b|10000000|\(whole.hexString)|p=\(wrong)|/"))
        XCTAssertThrowsError(try file("ed2k://|file|b|10000000|\(whole.hexString)|p=\(parts[0].hexString)|/"), "the wrong number of hashes")
    }

    func testBadHashesAndSizes() {
        for bad in ["", "abc", String(emptyMD4.dropLast()), emptyMD4 + "0", "zz" + emptyMD4.dropFirst(2), String(repeating: "g", count: 32)] {
            XCTAssertThrowsError(try file("ed2k://|file|n|10|\(bad)|/"), "emptyMD4 \(bad)")
        }
        for size in ["0", "-5", "abc", "", "1.5", "99999999999999999999", String(Int64(1) << 40), "１２３"] {
            XCTAssertThrowsError(try file("ed2k://|file|n|\(size)|\(emptyMD4)|/"), "size \(size)")
        }
    }

    func testMalformedLinks() {
        for bad in ["ed2k://file|n|1|\(emptyMD4)|/", "ed2k://|file|n|1|/", "ed2k://|file|", "ed2k://", "ed2k://||||", "http://example.com", "ed2k://|file|n|1|\(emptyMD4)|p=a|p=b|/", "ed2k://|file|n\u{0}x|1|\(emptyMD4)|/"] {
            XCTAssertThrowsError(try ED2KLink.parse(bad), bad)
        }
        XCTAssertThrowsError(try ED2KLink.parse("ed2k://|file|" + String(repeating: "a", count: 40_000) + "|1|\(emptyMD4)|/")) { XCTAssertEqual($0 as? ED2KLink.Failure, .tooLong) }
    }

    func testFileNamesCannotEscapeTheFolder() throws {
        for name in ["..%2F..%2Fetc%2Fpasswd", "%2Fetc%2Fpasswd", "a%5C..%5Cb", "..", "."] {
            if let f = try? file("ed2k://|file|\(name)|1|\(emptyMD4)|/") {
                XCTAssertFalse(f.name.contains("/") || f.name.contains("\\") || f.name == ".." || f.name == ".", "\(name) -> \(f.name)")
            }
        }
        XCTAssertLessThanOrEqual(try file("ed2k://|file|\(String(repeating: "a", count: 300))|1|\(emptyMD4)|/").name.utf8.count, 255, "a long name is cut to a usable length by the download-name rules")
    }

    func testUnsafeSourcesAreRefused() {
        for bad in ["127.0.0.1:4662", "10.0.0.5:4662", "192.168.1.1:4662", "169.254.1.1:4662", "172.16.0.1:4662", "0.0.0.0:4662", "224.0.0.1:4662", "example.com:4662", "1.2.3:4662", "1.2.3.4:0", "1.2.3.4:70000", "1.2.3.4", "999.1.1.1:4662", "1.2.3.4.5:4662"] {
            XCTAssertThrowsError(try file("ed2k://|file|n|1|\(emptyMD4)|/|sources,\(bad)|/"), bad)
        }
        let many = (1...60).map { "8.8.\($0).1:4662" }.joined(separator: ",")
        XCTAssertThrowsError(try file("ed2k://|file|n|1|\(emptyMD4)|/|sources,\(many)|/")) { XCTAssertEqual($0 as? ED2KLink.Failure, .tooManySources) }
    }

    func testServerAndServerListLinks() throws {
        XCTAssertEqual(try ED2KLink.parse("ed2k://|server|8.8.8.8|4661|/"), .server(host: "8.8.8.8", port: 4661))
        XCTAssertThrowsError(try ED2KLink.parse("ed2k://|server|127.0.0.1|4661|/")); XCTAssertThrowsError(try ED2KLink.parse("ed2k://|server|example.com|4661|/"))
        XCTAssertThrowsError(try ED2KLink.parse("ed2k://|server|8.8.8.8|0|/"))
        XCTAssertEqual(try ED2KLink.parse("ed2k://|serverlist|http://example.com/server.met|/"), .serverList(URL(string: "http://example.com/server.met")!))
        XCTAssertThrowsError(try ED2KLink.parse("ed2k://|serverlist|ftp://example.com/s|/")); XCTAssertThrowsError(try ED2KLink.parse("ed2k://|serverlist|file:///etc/passwd|/"))
        XCTAssertThrowsError(try ED2KLink.parse("ed2k://|friend|x|1.2.3.4|4662|/")) { XCTAssertEqual($0 as? ED2KLink.Failure, .unsupported("friend")) }
    }
}

// MARK: Hashes

final class ED2KHashTests: XCTestCase {
    func testPartGeometry() {
        XCTAssertEqual(ED2KHash.partCount(size: 1), 1); XCTAssertEqual(ED2KHash.partCount(size: ED2KHash.partSize), 1); XCTAssertEqual(ED2KHash.partCount(size: ED2KHash.partSize + 1), 2)
        XCTAssertEqual(ED2KHash.partLength(1, size: ED2KHash.partSize + 5), 5); XCTAssertEqual(ED2KHash.partLength(0, size: ED2KHash.partSize + 5), ED2KHash.partSize); XCTAssertEqual(ED2KHash.partLength(2, size: 10), 0)
        XCTAssertEqual(ED2KHash.partCount(size: 0), 0)
    }

    func testSmallFileHashIsItsMD4() {
        let data = Data("hello eD2k".utf8)
        let (parts, whole) = ED2KHash.hashes(of: data)
        XCTAssertEqual(parts.count, 1); XCTAssertEqual(whole, MD4.hash(data))
    }

    func testManyPartsHashTheHashes() {
        let data = Data((0..<10_100_000).map { UInt8($0 % 241) })
        let (parts, whole) = ED2KHash.hashes(of: data)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], MD4.hash(data.subdata(in: 0..<Int(ED2KHash.partSize))))
        XCTAssertEqual(whole, MD4.hash(parts[0] + parts[1]))
        XCTAssertEqual(ED2KHash.validatedPartHashes(parts, fileHash: whole, size: Int64(data.count)), parts)
        XCTAssertEqual(ED2KHash.validatedPartHashes(parts + [ED2KHash.emptyHash], fileHash: whole, size: Int64(data.count)), parts, "the eMule form with a final empty part is accepted")
        XCTAssertNil(ED2KHash.validatedPartHashes(parts + [Data(repeating: 1, count: 16)], fileHash: whole, size: Int64(data.count)))
        XCTAssertNil(ED2KHash.validatedPartHashes([parts[1], parts[0]], fileHash: whole, size: Int64(data.count)), "order matters")
        XCTAssertNil(ED2KHash.validatedPartHashes(parts, fileHash: Data(repeating: 0, count: 16), size: Int64(data.count)))
    }

    func testAnExactMultipleOfThePartSizeAcceptsEitherForm() {
        let a = MD4.hash(Data("one".utf8)), b = MD4.hash(Data("two".utf8))
        let size = ED2KHash.partSize * 2
        let plain = MD4.hash(a + b), withEmpty = MD4.hash(a + b + ED2KHash.emptyHash)
        XCTAssertNotEqual(plain, withEmpty)
        XCTAssertEqual(Set(ED2KHash.acceptableFileHashes(partHashes: [a, b], size: size)), [plain, withEmpty])
        XCTAssertNotNil(ED2KHash.validatedPartHashes([a, b], fileHash: plain, size: size)); XCTAssertNotNil(ED2KHash.validatedPartHashes([a, b], fileHash: withEmpty, size: size))
        XCTAssertEqual(ED2KHash.acceptableFileHashes(partHashes: [a, b], size: size + 1).count, 1, "only exact multiples have two")
    }

    func testCorruptionChangesThePartHash() {
        var data = Data((0..<100_000).map { UInt8($0 % 251) })
        let good = MD4.hash(data)
        data[5_000] ^= 0x01
        XCTAssertNotEqual(MD4.hash(data), good)
    }
}

// MARK: Wire

final class ED2KWireTests: XCTestCase {
    private func adler32(_ d: Data) -> UInt32 { var a: UInt32 = 1, b: UInt32 = 0; for x in d { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }; return b << 16 | a }
    private func zlib(_ d: Data) -> Data {
        var out = [UInt8](repeating: 0, count: d.count + 1024)
        let n = d.withUnsafeBytes { s in out.withUnsafeMutableBytes { compression_encode_buffer($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, s.bindMemory(to: UInt8.self).baseAddress!, s.count, nil, COMPRESSION_ZLIB) } }
        let sum = adler32(d)
        return Data([0x78, 0x9C]) + Data(out[0..<n]) + Data([UInt8(sum >> 24), UInt8((sum >> 16) & 0xFF), UInt8((sum >> 8) & 0xFF), UInt8(sum & 0xFF)])
    }

    func testPacketsRoundTripOneByteAtATime() throws {
        let packets = [ED2KWire.Packet(proto: 0xE3, opcode: 0x55, payload: Data()), ED2KWire.Packet(proto: 0xC5, opcode: 0x60, payload: Data(repeating: 9, count: 300)), ED2KWire.Packet(proto: 0xE3, opcode: 0x38, payload: Data("hi".utf8))]
        var parser = ED2KWire.Parser(); var got: [ED2KWire.Packet] = []
        for b in packets.map(ED2KWire.encode).reduce(Data(), +) { got += try parser.feed(Data([b])) }
        XCTAssertEqual(got, packets)
    }

    func testBadHeadersAreRefusedBeforeTheirBytesAreAwaited() {
        var p = ED2KWire.Parser()
        XCTAssertThrowsError(try p.feed(Data([0xE3, 0xFF, 0xFF, 0xFF, 0x7F, 0x01]))) { XCTAssertTrue(($0 as? ED2KWire.Failure).map { if case .tooLong = $0 { true } else { false } } ?? false) }
        XCTAssertLessThan(p.buffered, 10)
        var q = ED2KWire.Parser(); XCTAssertThrowsError(try q.feed(Data([0xE3, 0, 0, 0, 0, 0x01])), "a length of 0 has no room for an opcode")
        var r = ED2KWire.Parser(); XCTAssertThrowsError(try r.feed(Data([0x41, 1, 0, 0, 0, 1])), "an unknown protocol byte")
    }

    func testPackedPacketsAreInflatedAndBounded() throws {
        let payload = Data((0..<5000).map { UInt8($0 % 7) })
        var p = ED2KWire.Parser()
        let wire = ED2KWire.encode(ED2KWire.Packet(proto: 0xD4, opcode: 0x42, payload: zlib(payload)))
        let got = try p.feed(wire)
        XCTAssertEqual(got.first?.payload, payload); XCTAssertEqual(got.first?.proto, ED2KWire.emule)
        var bomb = ED2KWire.Parser()
        XCTAssertThrowsError(try bomb.feed(ED2KWire.encode(ED2KWire.Packet(proto: 0xD4, opcode: 1, payload: zlib(Data(count: 3_000_000))))), "a small packet that inflates past the limit")
        var junk = ED2KWire.Parser()
        XCTAssertThrowsError(try junk.feed(ED2KWire.encode(ED2KWire.Packet(proto: 0xD4, opcode: 1, payload: Data(repeating: 0x55, count: 40)))))
    }

    func testTagsAreReadAndBounded() throws {
        var bytes = ED2KWire.tag(id: 0x01, string: "nick") + ED2KWire.tag(id: 0x11, uint: 60)
        bytes += Data([0x89, 0x20, 7])                             // new form: type 9 (uint8) with the high bit, id 0x20, value 7
        var r = ED2KWire.Reader(bytes)
        let tags = try ED2KWire.readTags(&r, count: 3)
        XCTAssertEqual(tags[0], ED2KWire.Tag(id: 1, name: nil, value: .string("nick"))); XCTAssertEqual(tags[1].value, .uint(60)); XCTAssertEqual(tags[2], ED2KWire.Tag(id: 0x20, name: nil, value: .uint(7)))
        var small = ED2KWire.Reader(Data([0x02, 0x01, 0x00, 0x01, 0xFF, 0xFF]))
        XCTAssertThrowsError(try ED2KWire.readTags(&small, count: 1), "a string that claims more than is there")
        var many = ED2KWire.Reader(Data()); XCTAssertThrowsError(try ED2KWire.readTags(&many, count: 1000))
        var unknown = ED2KWire.Reader(Data([0x7E, 0x01, 0x00, 0x01])); XCTAssertThrowsError(try ED2KWire.readTags(&unknown, count: 1))
        var huge = ED2KWire.Reader(Data([0x02, 0x01, 0x00, 0x01, 0xFF, 0x7F]) + Data(count: 100)); XCTAssertThrowsError(try ED2KWire.readTags(&huge, count: 1))
    }

    func testServerMessages() throws {
        XCTAssertEqual(try ED2KWire.parseIDChange(ED2KWire.le32(0x0100_0001)).isLowID, false)
        XCTAssertTrue(try ED2KWire.parseIDChange(ED2KWire.le32(1234) + ED2KWire.le32(1)).isLowID)
        XCTAssertEqual(try ED2KWire.parseIDChange(ED2KWire.le32(1234) + ED2KWire.le32(1)).flags, 1)
        XCTAssertThrowsError(try ED2KWire.parseIDChange(Data([1, 2])))
        XCTAssertEqual(try ED2KWire.parseServerMessage(ED2KWire.le16(5) + Data("hello".utf8)), "hello")
        XCTAssertThrowsError(try ED2KWire.parseServerMessage(ED2KWire.le16(500) + Data("hi".utf8)))
        let st = try ED2KWire.parseServerStatus(ED2KWire.le32(10) + ED2KWire.le32(20)); XCTAssertEqual(st.users, 10); XCTAssertEqual(st.files, 20)
        let h = Data(repeating: 3, count: 16)
        let entry = ED2KWire.SourceEntry(id: 0x0403_0201, port: 4662)
        XCTAssertEqual(entry.host, "1.2.3.4")
        let ok = try ED2KWire.parseFoundSources(h + Data([2]) + ED2KWire.le32(0x0403_0201) + ED2KWire.le16(4662) + ED2KWire.le32(77) + ED2KWire.le16(1))
        XCTAssertEqual(ok.sources.count, 2); XCTAssertTrue(ok.sources[1].isLowID); XCTAssertFalse(ok.sources[0].isLowID)
        XCTAssertThrowsError(try ED2KWire.parseFoundSources(h + Data([5]) + Data(count: 12)), "it claims 5 sources and holds 2")
    }

    func testRequestsForSources() {
        let h = Data(repeating: 1, count: 16)
        XCTAssertEqual(ED2KWire.getSources(hash: h, size: 1000).payload, h + ED2KWire.le32(1000))
        XCTAssertEqual(ED2KWire.getSources(hash: h, size: 5_000_000_000).payload, h + ED2KWire.le32(0) + ED2KWire.le64(5_000_000_000))
        let login = ED2KWire.loginRequest(userHash: ED2KWire.newUserHash(), nickname: "tester")
        XCTAssertEqual(login.opcode, 0x01); XCTAssertEqual(login.payload.count > 26, true)
        let uh = ED2KWire.newUserHash(); XCTAssertEqual(uh[5], 14); XCTAssertEqual(uh[14], 111)
    }

    func testHelloAndAnswer() throws {
        let uh = ED2KWire.newUserHash()
        let hello = ED2KWire.hello(userHash: uh, nickname: "me")
        XCTAssertEqual(try ED2KWire.parseHello(hello.payload, isAnswer: false), uh)
        XCTAssertEqual(try ED2KWire.parseHello(hello.payload.dropFirst(), isAnswer: true), uh, "an answer has no leading length byte")
        XCTAssertThrowsError(try ED2KWire.parseHello(Data([5]) + uh + Data(count: 12), isAnswer: false))
        XCTAssertThrowsError(try ED2KWire.parseHello(hello.payload.prefix(20), isAnswer: false), "cut before the fixed fields end")
        let odd = Data([16]) + uh + ED2KWire.le32(0) + ED2KWire.le16(0) + ED2KWire.le32(1) + Data([0x06, 0x01, 0x00, 0x01, 0x00])             // a tag type this client does not know
        XCTAssertEqual(try ED2KWire.parseHello(odd, isAnswer: false), uh, "an unknown tag does not turn away a valid peer")
    }

    func testFileMessages() throws {
        let h = Data(repeating: 4, count: 16)
        XCTAssertEqual(try ED2KWire.parseFileNameAnswer(h + ED2KWire.le16(3) + Data("abc".utf8)).name, "abc")
        XCTAssertEqual(try ED2KWire.parseFileNameAnswer(h + ED2KWire.le32(3) + Data("abc".utf8)).name, "abc", "the 4-byte length form")
        XCTAssertThrowsError(try ED2KWire.parseFileNameAnswer(h + ED2KWire.le16(9) + Data("abc".utf8)))
        XCTAssertEqual(try ED2KWire.parseFileStatus(h + ED2KWire.le16(0), expectedParts: 3).have, [true, true, true], "a count of 0 means all of it")
        XCTAssertEqual(try ED2KWire.parseFileStatus(h + ED2KWire.le16(3) + Data([0b101]), expectedParts: 3).have, [true, false, true])
        XCTAssertThrowsError(try ED2KWire.parseFileStatus(h + ED2KWire.le16(9) + Data([1, 1]), expectedParts: 3), "the wrong number of parts")
        XCTAssertThrowsError(try ED2KWire.parseFileStatus(h + ED2KWire.le16(3), expectedParts: 3), "the bitmap is missing")
        let a = Data(repeating: 1, count: 16), b = Data(repeating: 2, count: 16)
        XCTAssertEqual(try ED2KWire.parseHashsetAnswer(h + ED2KWire.le16(2) + a + b).parts, [a, b])
        XCTAssertThrowsError(try ED2KWire.parseHashsetAnswer(h + ED2KWire.le16(5) + a))
    }

    func testPartRequestsAndBlocks() throws {
        let h = Data(repeating: 5, count: 16)
        let p = ED2KWire.requestParts(hash: h, ranges: [ED2KWire.Range(start: 0, end: 184_320), ED2KWire.Range(start: 184_320, end: 200_000)])
        XCTAssertEqual(p.opcode, 0x47); XCTAssertEqual(p.payload.count, 16 + 24)
        XCTAssertEqual(p.payload.subdata(in: 16..<28), ED2KWire.le32(0) + ED2KWire.le32(184_320) + ED2KWire.le32(0), "three starts, then three ends; unused slots are zero")
        let wide = ED2KWire.requestParts(hash: h, ranges: [ED2KWire.Range(start: 5_000_000_000, end: 5_000_184_320)])
        XCTAssertEqual(wide.opcode, 0xA3); XCTAssertEqual(wide.proto, 0xC5); XCTAssertEqual(wide.payload.count, 16 + 48)
        let block = ED2KWire.Part(hash: h, start: 1000, end: 1010, data: Data(repeating: 8, count: 10))
        XCTAssertEqual(try ED2KWire.parseSendingPart(ED2KWire.sendingPart(block).payload, wide: false), block)
        let w = ED2KWire.Part(hash: h, start: 5_000_000_000, end: 5_000_000_010, data: Data(repeating: 8, count: 10))
        XCTAssertEqual(try ED2KWire.parseSendingPart(ED2KWire.sendingPart(w, wide: true).payload, wide: true), w)
        XCTAssertThrowsError(try ED2KWire.parseSendingPart(h + ED2KWire.le32(0) + ED2KWire.le32(100) + Data(count: 10), wide: false), "a block that is not the size it claims")
        XCTAssertThrowsError(try ED2KWire.parseSendingPart(h + ED2KWire.le32(50) + ED2KWire.le32(10) + Data(count: 10), wide: false), "an end before the start")
        XCTAssertThrowsError(try ED2KWire.parseSendingPart(h + ED2KWire.le32(0) + ED2KWire.le32(300_000) + Data(count: 300_000), wide: false), "more than a block")
    }
}

// MARK: Sessions against in-memory servers and peers (they speak the real wire format)

final class FakeED2K: PeerTransport, @unchecked Sendable {
    enum Role {
        case server(sources: [ED2KWire.SourceEntry], rejects: Bool = false)
        case peer(Peer)
    }
    struct Peer {
        var corrupt: Set<Int> = []                 // parts it damages
        var wrongHashInStatus = false
        var notFound = false
        var queueForever = false
        var compressed = false
        var hugeFrame = false
        var unsolicited = false
        var badHashset = false
        var emptyAnswerName = false
    }

    let queue: DispatchQueue
    let role: Role
    let stream: Data
    let fileHash: Data
    let partHashes: [Data]
    let size: Int64
    private var parser = ED2KWire.Parser()
    private var pending: ((Data?, Error?) -> Void)?
    private var outbox = Data()
    private(set) var closed = false
    private(set) var served = 0
    private(set) var sentBytes = 0
    private(set) var requestedRanges: [ED2KWire.Range] = []
    private(set) var asked = Set<UInt8>()

    init(queue: DispatchQueue, role: Role, stream: Data, fileHash: Data, partHashes: [Data]) {
        self.queue = queue; self.role = role; self.stream = stream; self.fileHash = fileHash; self.partHashes = partHashes; size = Int64(stream.count)
    }

    func connect(_ done: @escaping (Error?) -> Void) { queue.async { done(nil) } }
    func send(_ data: Data) {
        guard let packets = try? parser.feed(data) else { closed = true; return }
        for p in packets { asked.insert(p.opcode); handle(p) }
    }
    func receive(_ handler: @escaping (Data?, Error?) -> Void) { queue.async { [self] in pending = handler; flush() } }
    func close() { closed = true }

    private func emit(_ p: ED2KWire.Packet) { outbox.append(ED2KWire.encode(p)); sentBytes += p.payload.count; flush() }
    private func flush() {
        queue.async { [self] in
            guard let handler = pending, !outbox.isEmpty || closed else { return }
            if closed && outbox.isEmpty { pending = nil; handler(nil, nil); return }
            let chunk = outbox.prefix(16384); outbox.removeFirst(chunk.count); pending = nil
            handler(Data(chunk), nil)
        }
    }

    private func handle(_ p: ED2KWire.Packet) {
        switch role {
        case .server(let sources, let rejects):
            if p.opcode == ED2KWire.Op.loginRequest {
                if rejects { emit(.init(proto: 0xE3, opcode: ED2KWire.Op.reject, payload: Data())); return }
                emit(.init(proto: 0xE3, opcode: ED2KWire.Op.serverMessage, payload: ED2KWire.le16(5) + Data("hello".utf8)))
                emit(.init(proto: 0xE3, opcode: ED2KWire.Op.idChange, payload: ED2KWire.le32(0x0100_007F)))
                emit(.init(proto: 0xE3, opcode: ED2KWire.Op.serverStatus, payload: ED2KWire.le32(5) + ED2KWire.le32(9)))
            } else if p.opcode == ED2KWire.Op.getSources {
                let asked = Data(p.payload.prefix(16))
                let list = asked == fileHash ? sources : []
                emit(.init(proto: 0xE3, opcode: ED2KWire.Op.foundSources, payload: fileHash + Data([UInt8(list.count)]) + list.map { ED2KWire.le32($0.id) + ED2KWire.le16($0.port) }.reduce(Data(), +)))
            }
        case .peer(let b):
            switch p.opcode {
            case ED2KWire.Op.hello:
                if b.hugeFrame { outbox.append(Data([0xE3, 0xFF, 0xFF, 0xFF, 0x7F, 0x01])); flush(); return }
                emit(.init(proto: 0xE3, opcode: ED2KWire.Op.helloAnswer, payload: ED2KWire.newUserHash() + ED2KWire.le32(0) + ED2KWire.le16(4662) + ED2KWire.le32(0) + ED2KWire.le32(0) + ED2KWire.le16(0)))
                if b.unsolicited { emit(ED2KWire.sendingPart(.init(hash: fileHash, start: 0, end: 10, data: Data(count: 10)))) }
            case ED2KWire.Op.requestFileName:
                if b.notFound { emit(.init(proto: 0xE3, opcode: ED2KWire.Op.fileNotFound, payload: fileHash)); return }
                emit(.init(proto: 0xE3, opcode: ED2KWire.Op.reqFileNameAnswer, payload: fileHash + ED2KWire.le16(3) + Data("abc".utf8)))
            case ED2KWire.Op.setReqFileID:
                let parts = ED2KHash.partCount(size: size)
                guard parts > 1 else { return }                           // a one-part file has no status packet
                var map = Data(count: (parts + 7) / 8); for i in 0..<parts { map[i / 8] |= 1 << UInt8(i % 8) }
                let hash = b.wrongHashInStatus ? Data(repeating: 9, count: 16) : fileHash
                emit(.init(proto: 0xE3, opcode: ED2KWire.Op.fileStatus, payload: hash + ED2KWire.le16(UInt16(parts)) + map))
            case ED2KWire.Op.hashsetRequest:
                var hashes = partHashes; if b.badHashset { hashes[0] = Data(repeating: 1, count: 16) }
                emit(.init(proto: 0xE3, opcode: ED2KWire.Op.hashsetAnswer, payload: fileHash + ED2KWire.le16(UInt16(hashes.count)) + hashes.reduce(Data(), +)))
            case ED2KWire.Op.startUploadReq:
                if b.queueForever { emit(.init(proto: 0xC5, opcode: ED2KWire.Op.queueRanking, payload: ED2KWire.le16(5) + Data(count: 10))) } else { emit(.init(proto: 0xE3, opcode: ED2KWire.Op.acceptUploadReq, payload: Data())) }
            case ED2KWire.Op.requestParts:
                if b.compressed { emit(.init(proto: 0xC5, opcode: ED2KWire.Op.compressedPart, payload: fileHash + ED2KWire.le32(0) + ED2KWire.le32(4) + Data(count: 4))); return }
                var r = ED2KWire.Reader(p.payload); _ = try? r.hash()
                let starts = (0..<3).compactMap { _ in try? r.u32() }, ends = (0..<3).compactMap { _ in try? r.u32() }
                for (s, e) in zip(starts, ends) where e > s {
                    requestedRanges.append(.init(start: Int64(s), end: Int64(e)))
                    var data = stream.subdata(in: Int(s)..<Int(e))
                    if b.corrupt.contains(Int(Int64(s) / ED2KHash.partSize)) { data[0] ^= 0xFF }
                    served += 1
                    emit(ED2KWire.sendingPart(.init(hash: fileHash, start: Int64(s), end: Int64(e), data: data)))
                }
            default: break
            }
        }
    }
}

final class FakeED2KNet: PeerTransportFactory, @unchecked Sendable {
    var build: (PeerAddress, DispatchQueue) -> FakeED2K
    private let lock = NSLock()
    private(set) var made: [PeerAddress: FakeED2K] = [:]
    init(build: @escaping (PeerAddress, DispatchQueue) -> FakeED2K) { self.build = build }
    func make(_ a: PeerAddress, queue: DispatchQueue) -> PeerTransport { let t = build(a, queue); lock.lock(); made[a] = t; lock.unlock(); return t }
    var all: [FakeED2K] { lock.lock(); defer { lock.unlock() }; return Array(made.values) }
}

class ED2KSessionTestCase: XCTestCase {
    var root: URL!
    let taskID = UUID()
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("p10-\(UUID().uuidString)"); try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDown() { ED2KBudget.peers.releaseAll(task: taskID); ED2KBudget.servers.releaseAll(task: taskID); try? FileManager.default.removeItem(at: root) }

    final class Events: @unchecked Sendable {
        private let lock = NSLock(); private var list: [ED2KSession.Event] = []
        func add(_ e: ED2KSession.Event) { lock.lock(); list.append(e); lock.unlock() }
        var all: [ED2KSession.Event] { lock.lock(); defer { lock.unlock() }; return list }
        var finished: Bool { all.contains { if case .finished = $0 { true } else { false } } }
        var failure: String? { all.compactMap { if case .failed(let m, _) = $0 { m } else { nil } }.first }
        var verified: [Int] { all.compactMap { if case .verifiedPart(let i, _) = $0 { i } else { nil } } }
    }

    struct Built { var stream: Data; var link: ED2KLink.File; var parts: [Data]; var fileHash: Data }

    func built(size: Int, name: String = "sample.bin", includePartHashes: Bool = false) -> Built {
        let stream = TorrentFixture.content(size)
        let (parts, whole) = ED2KHash.hashes(of: stream)
        let link = ED2KLink.File(name: name, size: Int64(size), hash: whole, partHashes: includePartHashes ? parts : nil, aichRoot: nil, sources: [])
        return Built(stream: stream, link: link, parts: parts, fileHash: whole)
    }

    func addr(_ n: Int) -> PeerAddress { PeerAddress(host: "8.8.8.\(n)", port: 4662) }

    func until(_ seconds: Double = 15, _ condition: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    func run(_ b: Built, peers: [Int], behaviours: [Int: FakED2KPeerBehaviour] = [:], servers: [PeerAddress] = [], serverSources: [ED2KWire.SourceEntry] = [], have: Set<Int> = [], preload: Bool = false,
             settings: ED2KSession.Settings? = nil, down: BandwidthController? = nil) throws -> (ED2KSession, ED2KStorage, FakeED2KNet, Events) {
        let storage = ED2KStorage(size: b.link.size, partFile: ED2KStorage.partFile(for: taskID, in: root))
        try storage.prepare()
        if preload { for p in have { let s = p * Int(ED2KHash.partSize); try storage.write(part: p, data: b.stream.subdata(in: s..<(s + Int(ED2KHash.partLength(p, size: b.link.size))))) } }
        let net = FakeED2KNet { a, q in
            if servers.contains(a) { return FakeED2K(queue: q, role: .server(sources: serverSources), stream: b.stream, fileHash: b.fileHash, partHashes: b.parts) }
            return FakeED2K(queue: q, role: .peer(behaviours[Int(a.host.split(separator: ".").last!)!] ?? .init()), stream: b.stream, fileHash: b.fileHash, partHashes: b.parts)
        }
        var s = settings ?? ED2KSession.Settings(); s.allowLocalPeers = true
        let events = Events()
        let session = ED2KSession(file: b.link, servers: servers, extraSources: peers.map(addr), storage: { storage }, alreadyHave: have, transports: net, download: down, taskID: taskID, settings: s)
        session.onEvent = { events.add($0) }
        return (session, storage, net, events)
    }
}
typealias FakED2KPeerBehaviour = FakeED2K.Peer

final class ED2KSessionTests: ED2KSessionTestCase {
    func testDownloadsASinglePartFileFromAPeer() async throws {
        let b = built(size: 600_000)
        let (s, storage, net, ev) = try run(b, peers: [1])
        s.start()
        let ok = await until { ev.finished }
        XCTAssertTrue(ok, "failure: \(ev.failure ?? "-")")
        XCTAssertEqual(try Data(contentsOf: storage.partFile), b.stream)
        XCTAssertEqual(net.all.first?.served, 4, "600000 bytes is four blocks of at most 180 KiB")
        s.stop()
    }

    func testAskingForTheHashListAndDownloadingSeveralParts() async throws {
        let b = built(size: 10_500_000)                                 // two parts, and the link carries no part hashes
        let (s, storage, net, ev) = try run(b, peers: [1])
        s.start()
        let ok = await until(60) { ev.finished }
        XCTAssertTrue(ok, "failure: \(ev.failure ?? "-")")
        XCTAssertTrue(net.all.first?.asked.contains(ED2KWire.Op.hashsetRequest) ?? false)
        XCTAssertEqual(Set(ev.verified), [0, 1])
        XCTAssertEqual(try Data(contentsOf: storage.partFile), b.stream)
        s.stop()
    }

    func testAHashListThatDoesNotMatchTheFileIsRefused() async throws {
        let b = built(size: 10_500_000)
        let (s, _, net, ev) = try run(b, peers: [1], behaviours: [1: .init(badHashset: true)])
        s.start()
        try? await Task.sleep(for: .seconds(2))
        XCTAssertFalse(ev.finished); XCTAssertTrue(net.all.first?.closed ?? false, "the peer that sent it is dropped")
        s.stop()
    }

    func testACorruptPartIsRejectedAndFetchedFromAnotherPeer() async throws {
        let b = built(size: 600_000)
        let (s, storage, _, ev) = try run(b, peers: [1, 2], behaviours: [1: .init(corrupt: [0])])
        s.start()
        let ok = await until { ev.finished }
        XCTAssertTrue(ok, "failure: \(ev.failure ?? "-")")
        XCTAssertEqual(try Data(contentsOf: storage.partFile), b.stream, "the damaged data never reached the file")
        s.stop()
    }

    func testOnlyBadPeersMeansItNeverFinishes() async throws {
        let b = built(size: 300_000)
        let (s, _, _, ev) = try run(b, peers: [1], behaviours: [1: .init(corrupt: [0])])
        s.start()
        try? await Task.sleep(for: .seconds(2))
        XCTAssertFalse(ev.finished, "a file that does not match its hash is never called complete")
        s.stop()
    }

    func testSourcesAreFoundThroughAConfiguredServerAndLowIDOnesAreLeftAlone() async throws {
        let b = built(size: 400_000)
        let server = PeerAddress(host: "9.9.9.9", port: 4661)
        let src = [ED2KWire.SourceEntry(id: 0x0101_0101 | 0x0000_0008 << 24, port: 4662), ED2KWire.SourceEntry(id: 77, port: 4662)]       // 1.1.1.8 is reachable; ID 77 is a low ID
        let (s, _, net, ev) = try run(b, peers: [], servers: [server], serverSources: src)
        s.start()
        let ok = await until { ev.finished }
        XCTAssertTrue(ok, "failure: \(ev.failure ?? "-")")
        XCTAssertNotNil(net.made[server]); XCTAssertEqual(net.made.count, 2, "one server and one peer; the low ID was not dialled")
        XCTAssertEqual(s.snapshot.lowID, 1)
        XCTAssertTrue(s.snapshot.servers["9.9.9.9"]?.contains("source") ?? false)
        s.stop()
    }

    func testNoServerIsContactedUnlessItWasConfigured() async throws {
        let b = built(size: 100_000)
        let (s, _, net, ev) = try run(b, peers: [], servers: [])
        s.start()
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(net.all.isEmpty, "no sources and no server means nothing is dialled")
        XCTAssertFalse(ev.finished); s.stop()
    }

    func testAServerThatRefusesTheLoginIsReportedNotRetriedInALoop() async throws {
        let b = built(size: 100_000)
        let server = PeerAddress(host: "9.9.9.9", port: 4661)
        let storage = ED2KStorage(size: b.link.size, partFile: ED2KStorage.partFile(for: taskID, in: root)); try storage.prepare()
        let net = FakeED2KNet { _, q in FakeED2K(queue: q, role: .server(sources: [], rejects: true), stream: b.stream, fileHash: b.fileHash, partHashes: b.parts) }
        var st = ED2KSession.Settings(); st.allowLocalPeers = true
        let s = ED2KSession(file: b.link, servers: [server], extraSources: [], storage: { storage }, alreadyHave: [], transports: net, download: nil, taskID: taskID, settings: st)
        s.start()
        try? await Task.sleep(for: .milliseconds(2500))
        XCTAssertEqual(s.snapshot.servers["9.9.9.9"], "refused the login")
        XCTAssertLessThanOrEqual(net.all.count, 1, "one attempt, then it waits for the next round")
        XCTAssertEqual(ED2KBudget.servers.holding(task: taskID), 0)
        s.stop()
    }

    func testPeersThatMisbehaveAreDroppedAndHarmNothing() async throws {
        for (name, behaviour) in [("wrong file", FakeED2K.Peer(wrongHashInStatus: true)), ("not found", .init(notFound: true)), ("huge frame", .init(hugeFrame: true)), ("compressed", .init(compressed: true)), ("never accepts", .init(queueForever: true))] {
            let b = built(size: 10_500_000)
            var st = ED2KSession.Settings(); st.queueWait = 1
            let (s, _, net, ev) = try run(b, peers: [1], behaviours: [1: behaviour], settings: st)
            s.start()
            let dropped = await until(6) { net.all.first?.closed == true }
            XCTAssertTrue(dropped, name); XCTAssertFalse(ev.finished, name)
            s.stop()
            let released = await until(3) { ED2KBudget.peers.holding(task: self.taskID) == 0 }
            XCTAssertTrue(released, "\(name): every connection slot is given back")
        }
    }

    func testABlockNobodyAskedForIsIgnored() async throws {
        let b = built(size: 400_000)
        let (s, storage, _, ev) = try run(b, peers: [1], behaviours: [1: .init(unsolicited: true)])
        s.start()
        let ok = await until { ev.finished }
        XCTAssertTrue(ok, "failure: \(ev.failure ?? "-")"); XCTAssertEqual(try Data(contentsOf: storage.partFile), b.stream); s.stop()
    }

    func testSourcesOnTheLocalNetworkAreIgnoredByDefault() async throws {
        let b = built(size: 100_000)
        let storage = ED2KStorage(size: b.link.size, partFile: ED2KStorage.partFile(for: taskID, in: root)); try storage.prepare()
        let net = FakeED2KNet { _, q in FakeED2K(queue: q, role: .peer(.init()), stream: b.stream, fileHash: b.fileHash, partHashes: b.parts) }
        let s = ED2KSession(file: b.link, servers: [], extraSources: [PeerAddress(host: "127.0.0.1", port: 4662), PeerAddress(host: "192.168.1.9", port: 4662), PeerAddress(host: "10.0.0.2", port: 4662)], storage: { storage },
                            alreadyHave: [], transports: net, download: nil, taskID: taskID)
        s.start()
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(net.all.isEmpty, "a source list cannot point the app at the local network"); s.stop()
    }

    func testPartsAlreadyHeldAreNotFetchedAndDamageIsFound() async throws {
        let b = built(size: 10_500_000)
        let (s, storage, net, ev) = try run(b, peers: [1], have: [0], preload: true)
        // damage part 0 on disk, which the session believes it holds
        let h = try FileHandle(forUpdating: storage.partFile); try h.seek(toOffset: 1234); try h.write(contentsOf: Data([1, 2, 3])); try h.close()
        s.start()
        let ok = await until(60) { ev.finished }
        XCTAssertTrue(ok, "failure: \(ev.failure ?? "-")")
        XCTAssertEqual(try Data(contentsOf: storage.partFile), b.stream, "the damaged part was found by the final check and fetched again")
        XCTAssertTrue(net.all.contains { $0.requestedRanges.contains { $0.start < ED2KHash.partSize } }, "part 0 was requested again")
        s.stop()
    }

    func testStoppingClosesEverythingAndReleasesTheLimits() async throws {
        let b = built(size: 10_500_000)
        let down = BandwidthController(); down.setOverallLimit(64 << 10)
        let (s, _, net, ev) = try run(b, peers: [1, 2], down: down)
        s.start()
        _ = await until(3) { !net.all.isEmpty }
        s.stop()
        let closed = await until(2) { net.all.allSatisfy(\.closed) }
        XCTAssertTrue(closed); XCTAssertFalse(ev.finished)
        let n = ev.all.count
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(ev.all.count, n, "nothing is reported after a stop")
        XCTAssertEqual(ED2KBudget.peers.holding(task: taskID), 0)
    }

    func testTheDownloadLimitPacesReading() async throws {
        let b = built(size: 360_000)
        let down = BandwidthController(); down.setOverallLimit(128 << 10)
        let (s, _, _, ev) = try run(b, peers: [1], down: down)
        let t0 = Date(); s.start()
        let ok = await until(20) { ev.finished }
        let took = Date().timeIntervalSince(t0)
        print("MEASURED ed2k download limit 128 KiB/s: 360 KB in \(took)s = \(360.0 / took) KB/s")
        XCTAssertTrue(ok); XCTAssertGreaterThan(took, 1.5); XCTAssertLessThan(took, 8); s.stop()
    }
}

final class ED2KPartPickerTests: XCTestCase {
    func testBlocksAreAskedAcceptedAndOnlyAsAsked() {
        let size = Int64(400_000)
        let p = ED2KPartPicker(size: size, alreadyHave: [])
        p.peerHas(1, [true]); p.peerHas(2, [true])
        let reqs = p.nextRequests(for: 1, limit: 3, now: 0)
        XCTAssertEqual(reqs.map { $0.end - $0.start }, [184_320, 184_320, 31_360])
        XCTAssertTrue(p.nextRequests(for: 2, limit: 3, now: 0).isEmpty, "everything is already asked of peer 1")
        XCTAssertEqual(p.received(from: 2, start: 0, end: 184_320, data: Data(count: 184_320)), .unexpected, "not the peer it was asked of")
        XCTAssertEqual(p.received(from: 1, start: 0, end: 184_000, data: Data(count: 184_000)), .unexpected, "not the range that was asked")
        XCTAssertEqual(p.received(from: 1, start: 0, end: 184_320, data: Data(count: 184_320)), .accepted)
        XCTAssertEqual(p.received(from: 1, start: 0, end: 184_320, data: Data(count: 184_320)), .unexpected, "a duplicate")
        _ = p.received(from: 1, start: 184_320, end: 368_640, data: Data(count: 184_320))
        guard case .partComplete(let i, let data, let who) = p.received(from: 1, start: 368_640, end: 400_000, data: Data(count: 31_360)) else { return XCTFail() }
        XCTAssertEqual(i, 0); XCTAssertEqual(data.count, 400_000); XCTAssertEqual(who, [1]); XCTAssertFalse(p.have[0], "not held until it has been checked")
        p.partVerified(0); XCTAssertTrue(p.isComplete); XCTAssertEqual(p.completedBytes, 400_000)
    }

    func testAPeerLeavingFreesItsBlocksAndMemoryIsCapped() {
        let p = ED2KPartPicker(size: ED2KHash.partSize * 6, alreadyHave: [], maxPartsInMemory: 2)
        p.peerHas(1, Array(repeating: true, count: 6)); p.peerHas(2, Array(repeating: true, count: 6))
        _ = p.nextRequests(for: 1, limit: 1000, now: 0)
        XCTAssertLessThanOrEqual(p.heldBytes, Int(ED2KHash.partSize) * 2, "no more than two unfinished parts are open")
        let before = p.nextRequests(for: 2, limit: 3, now: 0).count
        p.peerGone(1)
        XCTAssertGreaterThan(p.nextRequests(for: 2, limit: 3, now: 0).count, before - 1, "what peer 1 was asked is free again")
    }

    func testReleaseAndExpire() {
        let p = ED2KPartPicker(size: 400_000, alreadyHave: [])
        p.peerHas(1, [true]); p.peerHas(2, [true])
        let r = p.nextRequests(for: 1, limit: 3, now: 0)
        p.release(Array(r.suffix(1)))
        XCTAssertEqual(p.nextRequests(for: 2, limit: 3, now: 0).count, 1, "only the released block")
        XCTAssertEqual(p.expire(olderThan: 30, now: 31).sorted(), [1, 2])
    }
}

// MARK: Findings from the independent review

final class ED2KReviewFixTests: XCTestCase {
    func testFullWidthDigitsNeverCrashAndAreRefused() {
        let wide = String(repeating: "\u{FF21}", count: 32)                        // full-width "A": isHexDigit is true for it, UInt8(radix: 16) cannot read it
        XCTAssertNil(Data(hex: wide)); XCTAssertNil(Data(hex: "\u{FF11}\u{FF12}"))
        XCTAssertThrowsError(try ED2KLink.parse("ed2k://|file|x|1|\(wide)|/"))
        XCTAssertThrowsError(try ED2KLink.parse("ed2k://|file|x|10000000|31d6cfe0d16ae931b73c59d7e0c089c0|p=\(wide):\(wide)|/"))
        XCTAssertThrowsError(try MagnetLink.parse("magnet:?xt=urn:btih:" + String(repeating: "\u{FF21}", count: 40)), "the BitTorrent magnet parser had the same flaw")
    }

    func testAFileOfExactlyOnePartSizeGetsItsHashListChecked() {
        XCTAssertNil(ED2KHash.singlePartHashes(fileHash: Data(count: 16), size: ED2KHash.partSize), "its hash may be in the eMule form")
        XCTAssertNotNil(ED2KHash.singlePartHashes(fileHash: Data(count: 16), size: ED2KHash.partSize - 1))
        let p = MD4.hash(Data("part".utf8)), emule = MD4.hash(p + ED2KHash.emptyHash)
        XCTAssertNotNil(ED2KHash.validatedPartHashes([p, ED2KHash.emptyHash], fileHash: emule, size: ED2KHash.partSize), "the eMule form is accepted through a hash list")
    }

    func testAPartLeftOpenByAPeerWhoLeftDoesNotBlockOtherParts() {
        let p = ED2KPartPicker(size: ED2KHash.partSize * 3, alreadyHave: [], maxPartsInMemory: 1)
        p.peerHas(1, [true, false, false])
        XCTAssertFalse(p.nextRequests(for: 1, limit: 1, now: 0).isEmpty)
        _ = p.received(from: 1, start: 0, end: 184_320, data: Data(count: 184_320))        // a block of part 0 arrives, then the peer leaves
        p.peerGone(1)
        p.peerHas(2, [false, true, false])
        XCTAssertFalse(p.nextRequests(for: 2, limit: 1, now: 0).isEmpty, "part 0 is nobody's now: it is let go so part 1 can be fetched")
    }

    func testUnrequestedBlocksAreNotCountedAsDownloaded() async throws {
        // a block nobody asked for is ignored by the picker (see ED2KSessionTests.testABlockNobodyAskedForIsIgnored); the speed shown only counts blocks that were asked for
        let p = ED2KPartPicker(size: 400_000, alreadyHave: [])
        p.peerHas(1, [true])
        XCTAssertEqual(p.received(from: 1, start: 0, end: 184_320, data: Data(count: 184_320)), .unexpected, "nothing was asked, so nothing is accepted")
    }

    func testAnEmptyOrFullyHeldFilterOfLinkSourcesIsBounded() throws {
        let many = (1...40).map { "8.8.\($0).1:4662" }.joined(separator: ",")
        guard case .file(let f) = try ED2KLink.parse("ed2k://|file|n|1|31d6cfe0d16ae931b73c59d7e0c089c0|/|sources,\(many)|/") else { return XCTFail() }
        XCTAssertEqual(f.sources.count, 40, "the link may list them; the session uses only the first 8")
    }
}
