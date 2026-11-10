import Foundation
import CryptoKit

// MARK: Message Stream Encryption / Protocol Encryption (the BitTorrent "MSE/PE" handshake)
//
// What this is, and is not: a way for two peers to scramble a TCP stream so that it does not look like BitTorrent to simple traffic classifiers. A 768-bit Diffie–Hellman exchange gives both ends a
// secret; the stream is then RC4 (with the first 1024 bytes discarded) keyed from that secret and the torrent's info-hash. It is obfuscation: nobody is authenticated, a peer that is the other
// end of the connection sees everything, RC4 and a 768-bit group are weak by today's standards, and it provides no anonymity. It is not TLS and is never described as protection.
//
// The primitives are exactly those the existing implementations use (that is what interoperability requires), written here in the smallest form that does the job: RC4, a Montgomery multiply for the one
// fixed prime, and the handshake as a state machine over a byte stream. SHA-1 comes from CryptoKit.

enum MSEMath {
    /// The 768-bit prime of the protocol, as 24 little-endian 32-bit limbs.
    static let prime: [UInt32] = limbs(hex: "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A36210000000000090563")
    static let n = 24
    private static let nPrime: UInt32 = {
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- prime[0] &* inv) }
        return 0 &- inv
    }()
    /// R² mod p, with R = 2^768: found by doubling 1 (mod p) 1536 times.
    private static let rSquared: [UInt32] = {
        var r = [UInt32](repeating: 0, count: n); r[0] = 1
        for _ in 0..<(2 * 32 * n) {
            var carry: UInt32 = 0
            for i in 0..<n { let next = r[i] >> 31; r[i] = r[i] << 1 | carry; carry = next }
            if carry != 0 || !less(r, prime) { subtract(&r, prime) }
        }
        return r
    }()

    static func limbs(hex: String) -> [UInt32] {
        var bytes: [UInt8] = []; var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        return limbs(bigEndian: bytes)
    }
    static func limbs(bigEndian bytes: [UInt8]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: n)
        for (k, b) in bytes.reversed().enumerated() where k / 4 < n { out[k / 4] |= UInt32(b) << UInt32(8 * (k % 4)) }
        return out
    }
    static func bigEndian(_ limbs: [UInt32], length: Int) -> [UInt8] {
        (0..<length).map { k in let from = length - 1 - k; return UInt8(truncatingIfNeeded: limbs[from / 4] >> UInt32(8 * (from % 4))) }
    }

    private static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: n - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }
    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: Int64 = 0
        for i in 0..<n { let v = Int64(a[i]) - Int64(b[i]) - borrow; a[i] = UInt32(truncatingIfNeeded: v); borrow = v < 0 ? 1 : 0 }
    }

    /// Montgomery product a·b·R⁻¹ mod p.
    private static func montMul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var t = [UInt32](repeating: 0, count: n + 2)
        for i in 0..<n {
            var carry: UInt64 = 0
            for j in 0..<n { let v = UInt64(t[j]) + UInt64(a[j]) * UInt64(b[i]) + carry; t[j] = UInt32(truncatingIfNeeded: v); carry = v >> 32 }
            var v = UInt64(t[n]) + carry; t[n] = UInt32(truncatingIfNeeded: v); t[n + 1] = UInt32(truncatingIfNeeded: v >> 32)
            let m = UInt32(truncatingIfNeeded: UInt64(t[0]) &* UInt64(nPrime))
            v = UInt64(t[0]) + UInt64(m) * UInt64(prime[0]); carry = v >> 32
            for j in 1..<n { v = UInt64(t[j]) + UInt64(m) * UInt64(prime[j]) + carry; t[j - 1] = UInt32(truncatingIfNeeded: v); carry = v >> 32 }
            v = UInt64(t[n]) + carry; t[n - 1] = UInt32(truncatingIfNeeded: v); t[n] = t[n + 1] &+ UInt32(truncatingIfNeeded: v >> 32)
        }
        var r = Array(t[0..<n])
        if t[n] != 0 || !less(r, prime) { subtract(&r, prime) }
        return r
    }

    /// base^exponent mod p. `exponent` is any number of big-endian bytes (the protocol's secrets are 160 bits).
    static func modPow(base: [UInt32], exponent: [UInt8]) -> [UInt32] {
        var one = [UInt32](repeating: 0, count: n); one[0] = 1
        let x = montMul(base, rSquared)
        var acc = montMul(one, rSquared)
        for byte in exponent { for bit in stride(from: 7, through: 0, by: -1) { acc = montMul(acc, acc); if byte >> UInt8(bit) & 1 == 1 { acc = montMul(acc, x) } } }
        return montMul(acc, one)
    }
}

/// RC4, the stream cipher of MSE. Weak; used because the protocol is defined with it.
struct RC4 {
    private var s = [UInt8](0...255)
    private var i = 0, j = 0
    init(key: [UInt8], discard: Int = 1024) {
        var j = 0
        for i in 0..<256 { j = (j + Int(s[i]) + Int(key[i % key.count])) & 255; s.swapAt(i, j) }
        if discard > 0 { _ = process([UInt8](repeating: 0, count: discard)) }
    }
    mutating func process(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        for k in 0..<out.count {
            i = (i + 1) & 255; j = (j + Int(s[i])) & 255; s.swapAt(i, j)
            out[k] ^= s[(Int(s[i]) + Int(s[j])) & 255]
        }
        return out
    }
}

enum MSE {
    static let keyLength = 96
    static let maxPad = 512
    static let maxInitialPayload = 4096
    static let cryptoPlain: UInt32 = 0x01, cryptoRC4: UInt32 = 0x02

    /// Which methods this end will take: set from the person's encryption preference.
    struct Methods: OptionSet { let rawValue: UInt32; static let plaintext = Methods(rawValue: 1); static let rc4 = Methods(rawValue: 2) }

    enum Selected: Equatable { case plaintext, rc4 }
    struct Outcome { var selected: Selected; var infoHash: Data; var encrypt: RC4?; var decrypt: RC4?; var initialPayload: Data; var leftover: Data }
    enum Step { case more, done(Outcome), failed(String) }

    static func sha1(_ parts: Data...) -> [UInt8] { var h = Insecure.SHA1(); for p in parts { h.update(data: p) }; return [UInt8](h.finalize()) }

    /// The public value for a secret: 2^secret mod p, 96 bytes.
    static func publicKey(secret: [UInt8]) -> [UInt8] { var two = [UInt32](repeating: 0, count: MSEMath.n); two[0] = 2; return MSEMath.bigEndian(MSEMath.modPow(base: two, exponent: secret), length: keyLength) }
    static func sharedSecret(theirs: [UInt8], secret: [UInt8]) -> [UInt8] { MSEMath.bigEndian(MSEMath.modPow(base: MSEMath.limbs(bigEndian: theirs), exponent: secret), length: keyLength) }
}

/// One end of the handshake, fed the bytes that arrive and asked what to send. Bounded at every step: padding is at most 512 bytes, searches for the next marker give up after that, and the whole
/// thing is abandoned by the caller's timeout.
final class MSEHandshake {
    enum Role { case initiator(infoHash: Data, initialPayload: Data), responder(infoHashes: () -> [Data]) }

    private let role: Role
    private let allowed: MSE.Methods
    private var secret: [UInt8]
    private var buffer = Data()
    private var stage = 0
    private var shared: [UInt8] = []
    private var skey = Data()
    private var enc: RC4?, dec: RC4?
    private var expectedVC: [UInt8] = []
    private var provide: UInt32 = 0
    private var padCLength = 0, ialLength = 0
    private var selected: MSE.Selected?
    private var pendingOutput = Data()
    private(set) var finished = false

    init(role: Role, allowed: MSE.Methods, secret: [UInt8]? = nil, paddingLength: Int? = nil) {
        self.role = role; self.allowed = allowed
        self.secret = secret ?? (0..<20).map { _ in UInt8.random(in: 0...255) }
        let pad = paddingLength ?? Int.random(in: 0...MSE.maxPad)
        if case .initiator = role { pendingOutput = Data(MSE.publicKey(secret: self.secret)) + Data((0..<pad).map { _ in UInt8.random(in: 0...255) }) }
        padLength = pad
    }
    private let padLength: Int

    /// The bytes to send now (taken: asking again gives only what is new).
    func takeOutput() -> Data { defer { pendingOutput = Data() }; return pendingOutput }

    func feed(_ data: Data) -> MSE.Step {
        guard !finished else { return .failed("the handshake was already over") }
        buffer.append(data)
        if buffer.count > 4 * MSE.maxPad + 4096 + MSE.maxInitialPayload + 128 * 1024 { return fail("too much data before the handshake ended") }
        switch role {
        case .initiator(let infoHash, let ia): return initiatorStep(infoHash, ia)
        case .responder(let hashes): return responderStep(hashes)
        }
    }

    private func fail(_ why: String) -> MSE.Step { finished = true; return .failed(why) }

    private func cipherKeys(initiator: Bool) {
        let a = MSE.sha1(Data("keyA".utf8), Data(shared), skey), b = MSE.sha1(Data("keyB".utf8), Data(shared), skey)
        enc = RC4(key: initiator ? a : b); dec = RC4(key: initiator ? b : a)
    }

    // Initiator: Ya+PadA → ; ← Yb+PadB ; → req1, req2^req3, E(VC, provide, padC, IA) ; ← E(VC, select, padD) then the stream.
    private func initiatorStep(_ infoHash: Data, _ ia: Data) -> MSE.Step {
        if stage == 0 {
            guard buffer.count >= MSE.keyLength else { return .more }
            shared = MSE.sharedSecret(theirs: [UInt8](buffer.prefix(MSE.keyLength)), secret: secret)
            buffer.removeFirst(MSE.keyLength)
            skey = infoHash
            cipherKeys(initiator: true)
            var probe = dec!; expectedVC = probe.process([UInt8](repeating: 0, count: 8))          // what the peer's encrypted VC will look like
            let h1 = MSE.sha1(Data("req1".utf8), Data(shared))
            let h2 = MSE.sha1(Data("req2".utf8), skey), h3 = MSE.sha1(Data("req3".utf8), Data(shared))
            var provideBits: UInt32 = 0
            if allowed.contains(.rc4) { provideBits |= MSE.cryptoRC4 }
            if allowed.contains(.plaintext) { provideBits |= MSE.cryptoPlain }
            var plain = Data(repeating: 0, count: 8)
            plain.appendBE(provideBits); plain.appendBE(UInt16(0)); plain.appendBE(UInt16(ia.count))          // no PadC
            var out = Data(h1) + Data(zip(h2, h3).map { $0 ^ $1 })
            out.append(Data(enc!.process([UInt8](plain)))); out.append(Data(enc!.process([UInt8](ia))))
            pendingOutput.append(out)
            stage = 1
        }
        if stage == 1 {
            // Find the encrypted VC after the peer's padding (at most 512 bytes).
            let bytes = [UInt8](buffer)
            guard bytes.count >= 8 else { return .more }
            var at: Int?
            for k in 0...min(MSE.maxPad, bytes.count - 8) where Array(bytes[k..<(k + 8)]) == expectedVC { at = k; break }
            guard let k = at else { return bytes.count > MSE.maxPad + 8 ? fail("the peer's reply did not make sense") : .more }
            buffer.removeFirst(k + 8)
            _ = dec!.process([UInt8](repeating: 0, count: 8))
            stage = 2
        }
        if stage == 2 {
            guard buffer.count >= 6 else { return .more }
            let head = dec!.processPreview([UInt8](buffer.prefix(6)))
            let select = UInt32(head[0]) << 24 | UInt32(head[1]) << 16 | UInt32(head[2]) << 8 | UInt32(head[3])
            let padD = Int(head[4]) << 8 | Int(head[5])
            guard padD <= MSE.maxPad else { return fail("the peer's padding was too long") }
            guard buffer.count >= 6 + padD else { return .more }
            _ = dec!.process([UInt8](buffer.prefix(6 + padD)))
            buffer.removeFirst(6 + padD)
            if select == MSE.cryptoRC4, allowed.contains(.rc4) { selected = .rc4 }
            else if select == MSE.cryptoPlain, allowed.contains(.plaintext) { selected = .plaintext }
            else { return fail("the peer chose a method that was not offered") }
            return complete(infoHash: infoHash, initial: Data())
        }
        return .more
    }

    // Responder: ← Ya+PadA ; → Yb+PadB ; ← req1, req2^req3, E(VC, provide, padC, IA) ; → E(VC, select, padD).
    private func responderStep(_ hashes: () -> [Data]) -> MSE.Step {
        if stage == 0 {
            guard buffer.count >= MSE.keyLength else { return .more }
            shared = MSE.sharedSecret(theirs: [UInt8](buffer.prefix(MSE.keyLength)), secret: secret)
            buffer.removeFirst(MSE.keyLength)
            pendingOutput = Data(MSE.publicKey(secret: secret)) + Data((0..<padLength).map { _ in UInt8.random(in: 0...255) })
            stage = 1
        }
        if stage == 1 {
            let marker = MSE.sha1(Data("req1".utf8), Data(shared)); let bytes = [UInt8](buffer)
            guard bytes.count >= 20 else { return .more }
            var at: Int?
            for k in 0...min(MSE.maxPad, bytes.count - 20) where Array(bytes[k..<(k + 20)]) == marker { at = k; break }
            guard let k = at else { return bytes.count > MSE.maxPad + 20 ? fail("not an encrypted handshake") : .more }
            buffer.removeFirst(k + 20)
            stage = 2
        }
        if stage == 2 {
            guard buffer.count >= 20 else { return .more }
            let masked = [UInt8](buffer.prefix(20))
            let h3 = MSE.sha1(Data("req3".utf8), Data(shared))
            guard let match = hashes().first(where: { h in zip(MSE.sha1(Data("req2".utf8), h), h3).map { $0 ^ $1 } == masked }) else { return fail("a torrent this client does not have") }
            buffer.removeFirst(20)
            skey = match
            cipherKeys(initiator: false)
            stage = 3
        }
        if stage == 3 {
            guard buffer.count >= 14 else { return .more }
            var probe = dec!
            let head = probe.process([UInt8](buffer.prefix(14)))
            guard head[0..<8].allSatisfy({ $0 == 0 }) else { return fail("the verification bytes were wrong") }
            provide = UInt32(head[8]) << 24 | UInt32(head[9]) << 16 | UInt32(head[10]) << 8 | UInt32(head[11])
            padCLength = Int(head[12]) << 8 | Int(head[13])
            guard padCLength <= MSE.maxPad else { return fail("the peer's padding was too long") }
            guard buffer.count >= 14 + padCLength + 2 else { return .more }
            let all = dec!.process([UInt8](buffer.prefix(14 + padCLength + 2)))
            ialLength = Int(all[14 + padCLength]) << 8 | Int(all[15 + padCLength])
            guard ialLength <= MSE.maxInitialPayload else { return fail("the initial payload was too long") }
            buffer.removeFirst(14 + padCLength + 2)
            stage = 4
        }
        if stage == 4 {
            guard buffer.count >= ialLength else { return .more }
            let ia = Data(dec!.process([UInt8](buffer.prefix(ialLength))))
            buffer.removeFirst(ialLength)
            if provide & MSE.cryptoRC4 != 0, allowed.contains(.rc4) { selected = .rc4 }
            else if provide & MSE.cryptoPlain != 0, allowed.contains(.plaintext) { selected = .plaintext }
            else { return fail("no encryption method in common") }
            var reply = Data(repeating: 0, count: 8)
            reply.appendBE(selected == .rc4 ? MSE.cryptoRC4 : MSE.cryptoPlain); reply.appendBE(UInt16(0))
            pendingOutput.append(Data(enc!.process([UInt8](reply))))
            return complete(infoHash: skey, initial: ia)
        }
        return .more
    }

    private func complete(infoHash: Data, initial: Data) -> MSE.Step {
        finished = true
        let rest = buffer
        buffer = Data()
        let method = selected ?? .plaintext
        // With RC4 selected the bytes after the handshake are encrypted: the rest of what has arrived is decrypted here, in order.
        let leftover = (method == .rc4 && !rest.isEmpty) ? Data(dec!.process([UInt8](rest))) : rest
        return .done(MSE.Outcome(selected: method, infoHash: infoHash, encrypt: method == .rc4 ? enc : nil, decrypt: method == .rc4 ? dec : nil, initialPayload: initial, leftover: leftover))
    }
}

private extension RC4 {
    /// The result of decrypting `bytes` without moving the cipher on.
    func processPreview(_ bytes: [UInt8]) -> [UInt8] { var copy = self; return copy.process(bytes) }
}
