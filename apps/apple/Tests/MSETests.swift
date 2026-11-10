import XCTest
@testable import Browser_Setu

final class MSETests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private func bytes(_ h: String) -> [UInt8] { stride(from: 0, to: h.count, by: 2).map { UInt8(h[h.index(h.startIndex, offsetBy: $0)..<h.index(h.startIndex, offsetBy: $0 + 2)], radix: 16)! } }
    private let torrentHash = Data((1...20).map { UInt8($0) })

    // Reference values for the Diffie–Hellman step, computed with Python's arbitrary-precision pow().
    private let vectors: [(x: String, X: String, y: String, Y: String, S: String)] = [
    ("d29fc5210373d7a2aedcd32d0c7a81d90b01fde6", "68bfdf81150b88443602528c6cc3ab4960850afb18fa09b44da97861f95aa899726d924bb67530b86be7cd1eb19493dfd8dd7ef83da984908b5680d0182cdf93cd8f0703b511251da0767ab9327cd2d8f59b76e98278dac3ee31e7828140ffb7", "73f4f6f6625953bc9f9f9171c4c830763cc1afbe", "8286edbe8918e2ff86f2877ff302a6ab8bbd7f8de8f283d826274dd75313dd853eef6be8dcd9cac2af857f23ab74d79bf8663a3a599893d6e8f623611f1abcd2ba8665c097f9674b329054287ef9d11392011d2d6f3717c21e67072aa9243389", "d2f313621b75ec91038938c236c218e764dbcc40e63a224190c09412ea89e7027534dc6627712e74d6135ebac86173a916f18576c00f38cf595b759dbac83db9384ad722a8ff7279c39499f1a74b91021e1fbc6b8d099d863995d315c8cb909d"),
    ("64c9b7fc7c05b86ea5fc27a1663caf606a08288c", "8df3616ca1454aef267c42c12a437c7252b22fe28f892505e0201e480213f30348a7b06b62cf9a3e17f107e713b3b3a5a86ea3b446980df6a041d3f8999ca231c8f3bed6cd803ae2df418300799cc1e41502d1567b700891f59cb5adfdd114fa", "7f25a21b3e68d6a398e9c821b024fb21332f736f", "5eec4934cc5ee5743104374b2161fd78fef13e7f54f449acc7a7b8514052e5f1139643c58b8028a5c662f6a93eaa6054fb81e0ea5ea5926e0ce5537d95373a71537cc83ecb0ad3b3e99e350bb5d4ad0649a845a06a21de0d12f03688c5586a44", "32223ed4d886e8c6923d6e71153fb13d5b5dd34fddb49b903628dae7627f607c9b4b029fab03723dafc804985567a4ea6a408159de32aea40d3b3f4acb40c3674da069632204ec053cc6194ddfcbbc55759fc4eaca31ee7a500092cd4bc40e9d"),
    ("9731abc25b09cf3f0ff7d45d76f3fdc096631603", "20702e1945047594bc1d6949b949db288b2ff8393b0d9f199acdbdfec65227cad732f60c25456775ac03c340d3ca1e0c24ff751524b9716d1faab3a4e101c7905b73cd030dc5f7b2c6d8b5ece8edff1b5f8d3760a924318761ddb098a37a5e12", "c25b8daaabd30493946f149c76ba2db66e3dbf5d", "21e7a0584e461f0ee4f34492c2a93e0e4ac6ae257be5e0466a9099d4f94af56ca16d827060428c5941c72bf5e9197b0b44ee5baacc561ecd03484b5da29c76781675564de49bbbe95a24eb6b6190e7e6fdb7f7bce50480a4da118ae2d44c1928", "64fe4061075f2acfbf639296499be3683e74906498b2382e32e5e1034d5fcad4480d8d95f2759cc43e2b49aa2f0115c85322db7275c12ad73e24d5faa0353c6a278ede8549b53e0a2c06016111a1210e961eabef0e849fc2efa2f90ac6ee6996"),
    ]

    func testTheDiffieHellmanMathMatchesAnIndependentBignum() {
        for v in vectors {
            XCTAssertEqual(hex(MSE.publicKey(secret: bytes(v.x))), v.X)
            XCTAssertEqual(hex(MSE.publicKey(secret: bytes(v.y))), v.Y)
            XCTAssertEqual(hex(MSE.sharedSecret(theirs: bytes(v.Y), secret: bytes(v.x))), v.S)
            XCTAssertEqual(hex(MSE.sharedSecret(theirs: bytes(v.X), secret: bytes(v.y))), v.S, "both ends reach the same secret")
        }
    }

    func testRC4MatchesTheStandardTestVector() {
        var c = RC4(key: Array("Key".utf8), discard: 0)
        XCTAssertEqual(hex(c.process(Array("Plaintext".utf8))), "bbf316e8d940af0ad3")
        var d = RC4(key: Array("Wiki".utf8), discard: 0)
        XCTAssertEqual(hex(d.process(Array("pedia".utf8))), "1021bf0420")
    }

    /// Runs the two ends against each other, delivering their bytes in `chunk`-sized pieces.
    private func run(_ a: MSEHandshake, _ b: MSEHandshake, chunk: Int = 1 << 20) -> (MSE.Step, MSE.Step) {
        var ra: MSE.Step = .more, rb: MSE.Step = .more
        var aOut = a.takeOutput(), bOut = Data()
        for _ in 0..<5000 {
            if !aOut.isEmpty { let piece = aOut.prefix(chunk); aOut.removeFirst(piece.count); rb = b.feed(Data(piece)); bOut.append(b.takeOutput()) }
            if !bOut.isEmpty { let piece = bOut.prefix(chunk); bOut.removeFirst(piece.count); ra = a.feed(Data(piece)); aOut.append(a.takeOutput()) }
            if case .failed = ra { break }; if case .failed = rb { break }
            if case .done = ra, case .done = rb { break }
            if aOut.isEmpty, bOut.isEmpty { break }
        }
        return (ra, rb)
    }
    private func done(_ s: MSE.Step) -> MSE.Outcome? { if case .done(let o) = s { o } else { nil } }
    private func failed(_ s: MSE.Step) -> String? { if case .failed(let w) = s { w } else { nil } }

    func testBothEndsAgreeOnRC4AndTheStreamsInterworkAndTheInitialPayloadArrives() throws {
        let ia = Data("BitTorrent handshake bytes".utf8)
        let a = MSEHandshake(role: .initiator(infoHash: torrentHash, initialPayload: ia), allowed: [.rc4, .plaintext])
        let b = MSEHandshake(role: .responder(infoHashes: { return [self.torrentHash] }), allowed: [.rc4, .plaintext])
        let (ra, rb) = run(a, b)
        var oa = try XCTUnwrap(done(ra)), ob = try XCTUnwrap(done(rb))
        XCTAssertEqual(oa.selected, .rc4); XCTAssertEqual(ob.selected, .rc4)
        XCTAssertEqual(ob.infoHash, torrentHash); XCTAssertEqual(ob.initialPayload, ia, "the responder gets the initiator's first bytes")
        let message = Array("after the handshake, in order".utf8)
        XCTAssertEqual(ob.decrypt!.process(oa.encrypt!.process(message)), message)
        XCTAssertEqual(oa.decrypt!.process(ob.encrypt!.process(message)), message)
        XCTAssertNotEqual(oa.encrypt!.process(message), message, "the stream is scrambled")
        _ = oa; _ = ob
    }

    func testTheHandshakeWorksWhenBytesArriveOneAtATime() throws {
        let a = MSEHandshake(role: .initiator(infoHash: torrentHash, initialPayload: Data()), allowed: [.rc4])
        let b = MSEHandshake(role: .responder(infoHashes: { return [self.torrentHash] }), allowed: [.rc4])
        let (ra, rb) = run(a, b, chunk: 1)
        XCTAssertNotNil(done(ra)); XCTAssertNotNil(done(rb))
    }

    func testPlaintextAfterTheHandshakeWhenThatIsAllThatIsAgreed() throws {
        let a = MSEHandshake(role: .initiator(infoHash: torrentHash, initialPayload: Data()), allowed: [.plaintext])
        let b = MSEHandshake(role: .responder(infoHashes: { return [self.torrentHash] }), allowed: [.rc4, .plaintext])
        let (ra, rb) = run(a, b)
        XCTAssertEqual(done(ra)?.selected, .plaintext); XCTAssertEqual(done(rb)?.selected, .plaintext)
        XCTAssertNil(done(ra)?.encrypt)
    }

    func testRequireEncryptedNeverFallsBackToPlaintext() {
        // The responder will only do plaintext; the initiator requires RC4: the handshake fails rather than carrying on in the clear.
        let a = MSEHandshake(role: .initiator(infoHash: torrentHash, initialPayload: Data()), allowed: [.rc4])
        let b = MSEHandshake(role: .responder(infoHashes: { return [self.torrentHash] }), allowed: [.plaintext])
        let (ra, rb) = run(a, b)
        XCTAssertNotNil(failed(rb), "no method in common"); XCTAssertNil(done(ra))
    }

    func testAResponderRefusesATorrentItDoesNotHaveAndGarbage() {
        let a = MSEHandshake(role: .initiator(infoHash: torrentHash, initialPayload: Data()), allowed: [.rc4])
        let b = MSEHandshake(role: .responder(infoHashes: { return [Data(repeating: 9, count: 20)] }), allowed: [.rc4])
        let (_, rb) = run(a, b)
        XCTAssertNotNil(failed(rb))
        let g = MSEHandshake(role: .responder(infoHashes: { return [self.torrentHash] }), allowed: [.rc4])
        var step: MSE.Step = .more
        for _ in 0..<20 { step = g.feed(Data((0..<200).map { _ in UInt8.random(in: 0...255) })); if case .failed = step { break } }
        XCTAssertNotNil(failed(step), "random bytes are not a handshake and the search for the marker is bounded")
    }

    func testPaddingIsBoundedAndAnEnormousInitialPayloadIsRefused() {
        let a = MSEHandshake(role: .initiator(infoHash: torrentHash, initialPayload: Data()), allowed: [.rc4], paddingLength: 512)
        let b = MSEHandshake(role: .responder(infoHashes: { return [self.torrentHash] }), allowed: [.rc4], paddingLength: 512)
        let (ra, rb) = run(a, b)
        XCTAssertNotNil(done(ra)); XCTAssertNotNil(done(rb), "the largest legal padding still works")
        let big = MSEHandshake(role: .initiator(infoHash: torrentHash, initialPayload: Data(count: MSE.maxInitialPayload + 1)), allowed: [.rc4])
        let r = MSEHandshake(role: .responder(infoHashes: { return [self.torrentHash] }), allowed: [.rc4])
        let (_, rr) = run(big, r)
        XCTAssertNotNil(failed(rr))
    }

    func testBytesThatFollowTheHandshakeInTheSameReadAreKeptAndDecrypted() throws {
        let a = MSEHandshake(role: .initiator(infoHash: torrentHash, initialPayload: Data()), allowed: [.rc4])
        let b = MSEHandshake(role: .responder(infoHashes: { return [self.torrentHash] }), allowed: [.rc4])
        var aOut = a.takeOutput()
        _ = b.feed(aOut); aOut = Data()
        let bOut = b.takeOutput()
        // Step the responder to completion by giving it the initiator's second message, then see what the initiator makes of a reply with stream bytes glued on.
        _ = a.feed(bOut); let second = a.takeOutput()
        guard case .done(var ob) = b.feed(second) else { return XCTFail() }
        let reply = b.takeOutput()
        let payload = Array("peer wire bytes".utf8)
        let glued = reply + Data(ob.encrypt!.process(payload))
        guard case .done(let oa) = a.feed(glued) else { return XCTFail() }
        XCTAssertEqual([UInt8](oa.leftover), payload, "what arrived right behind the handshake is decrypted and handed on")
    }
}
