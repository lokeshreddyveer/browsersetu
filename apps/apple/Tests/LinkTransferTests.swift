import CryptoKit
import XCTest
@testable import Browser_Setu

/// Files between the person's own devices: written in pieces, counted, checked, and never given their name unless they arrive whole. (The connection itself needs two
/// devices; the iPhone listens, the Mac does not, so the live transfer is a device test.)
final class LinkTransferTests: XCTestCase {
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testAWholeFileArrivesInOrderAndIsChecked() throws {
        let dir = folder()
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let incoming = try XCTUnwrap(IncomingFile(id: "t1", name: "report.pdf", size: payload.count, sha256: sha(payload), folder: dir))
        var index = 0
        var offset = 0
        while offset < payload.count {
            let piece = payload.subdata(in: offset..<min(offset + LinkTransferRules.chunkBytes, payload.count))
            XCTAssertTrue(incoming.append(piece, index: index))
            index += 1; offset += piece.count
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("report.pdf").path), "no name until it is whole and checked")
        let url = try XCTUnwrap(incoming.finish())
        XCTAssertEqual(url.lastPathComponent, "report.pdf")
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }.count, 0, "no partial file is left")
    }

    func testAnythingThatDoesNotMatchWhatWasOfferedIsRefusedAndRemoved() throws {
        let dir = folder()
        let payload = Data(repeating: 7, count: 1000)
        // A piece out of order, or one that makes it larger than offered.
        let a = try XCTUnwrap(IncomingFile(id: "a", name: "a.bin", size: payload.count, sha256: sha(payload), folder: dir))
        XCTAssertFalse(a.append(payload, index: 1), "out of order")
        XCTAssertTrue(a.append(payload, index: 0))
        XCTAssertFalse(a.append(Data([1]), index: 1), "past the size offered")
        a.discard()
        // Wrong content: the checksum differs, so the file is never given its name.
        let b = try XCTUnwrap(IncomingFile(id: "b", name: "b.bin", size: payload.count, sha256: sha(Data(repeating: 8, count: 1000)), folder: dir))
        XCTAssertTrue(b.append(payload, index: 0))
        XCTAssertNil(b.finish())
        // Too short.
        let c = try XCTUnwrap(IncomingFile(id: "c", name: "c.bin", size: 2000, sha256: sha(payload), folder: dir))
        XCTAssertTrue(c.append(payload, index: 0))
        XCTAssertNil(c.finish())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 0, "nothing was kept")
        // An offer that is not acceptable at all.
        XCTAssertNil(IncomingFile(id: "d", name: "d", size: LinkTransferRules.maxFileBytes + 1, sha256: sha(payload), folder: dir))
        XCTAssertNil(IncomingFile(id: "e", name: "e", size: 10, sha256: "not-a-hash", folder: dir))
        XCTAssertNil(IncomingFile(id: "f", name: "f", size: -1, sha256: sha(payload), folder: dir))
    }

    func testNamesCannotEscapeTheFolderOrOverwriteAnotherFile() throws {
        let dir = folder()
        XCTAssertEqual(LinkWire.safeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(LinkWire.safeFileName(".hidden"), "Received File")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("photo.jpg").path, contents: Data("old".utf8))
        let payload = Data("new".utf8)
        let incoming = try XCTUnwrap(IncomingFile(id: "n", name: "../photo.jpg", size: payload.count, sha256: sha(payload), folder: dir))
        XCTAssertTrue(incoming.append(payload, index: 0))
        let url = try XCTUnwrap(incoming.finish())
        XCTAssertEqual(url.lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("photo.jpg"), encoding: .utf8), "old", "the existing file is untouched")
    }

    func testTheChecksumOfAFileIsReadAPieceAtATime() throws {
        let dir = folder()
        let url = dir.appendingPathComponent("big.bin")
        let payload = Data((0..<(LinkTransferRules.chunkBytes * 3 + 123)).map { UInt8($0 % 199) })
        try payload.write(to: url)
        let sums = try LinkTransferRules.checksum(of: url)
        XCTAssertEqual(sums.size, payload.count)
        XCTAssertEqual(sums.sha256, sha(payload))
    }

    func testTheMessagesKeepWorkingWithOlderOnesAndPiecesStayFarUnderTheFrameLimit() throws {
        let old = #"{"kind":"link","text":"https://example.com"}"#
        XCTAssertEqual(try JSONDecoder().decode(LinkMessage.self, from: Data(old.utf8)).kind, .link, "a message from an older version still reads")
        let piece = LinkMessage(kind: .chunk, data: Data(repeating: 1, count: LinkTransferRules.chunkBytes), id: "t", index: 3)
        var framed = try LinkWire.frame(piece)
        XCTAssertLessThan(framed.count, 120_000, "a piece is about 90 KB, however large the file")
        let back = try LinkWire.unframe(&framed)
        XCTAssertEqual(back.first?.index, 3)
        XCTAssertEqual(back.first?.data?.count, LinkTransferRules.chunkBytes)
        for kind in [LinkMessage.Kind.offer, .accept, .decline, .chunk, .finish, .result, .abort] { XCTAssertTrue(kind.isTransfer) }
        for kind in [LinkMessage.Kind.text, .link, .file, .sync] { XCTAssertFalse(kind.isTransfer) }
    }

    func testTheProgressNeverClaimsArrivalBeforeTheCheck() {
        var progress = TransferProgress(name: "a.pdf", done: 50, total: 100, state: .receiving)
        XCTAssertEqual(progress.fraction, 0.5)
        XCTAssertTrue(progress.isActive)
        progress.state = .verifying
        XCTAssertTrue(progress.isActive)
        XCTAssertFalse(progress.summary.contains("arrived"))
        progress.state = .finished
        XCTAssertTrue(progress.summary.contains("arrived and was checked"))
        XCTAssertFalse(progress.isActive)
        progress.state = .failed("it did not match what was offered")
        XCTAssertFalse(progress.summary.contains("arrived"))
        XCTAssertEqual(TransferProgress(name: "x").fraction, 0)
    }
}
