import Foundation
import CryptoKit
import Network
import Security

// Cryptographic helpers for the remote companion. Nothing here invents a primitive: randomness is the system's, key derivation is HKDF-SHA256, the confirmation number is an
// HMAC-SHA256, and the encrypted channel is TLS (a pre-shared key per device, through Network.framework) — never a home-made protocol.

enum RemoteCrypto {
    /// `count` bytes from the system's secure random source. Failure to get them is fatal to the operation, never replaced by something weaker.
    static func random(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// RFC 4648 base32 without padding (easy to read aloud and to type: no 0/O/1/I mix-ups).
    static func base32(_ data: Data) -> String {
        var out = "", buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 { out.append(base32Alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { out.append(base32Alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    static func fromBase32(_ text: String) -> Data? {
        var buffer = 0, bits = 0
        var out = Data()
        for ch in text.uppercased() where ch != "-" && ch != " " {
            guard let value = base32Alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | value; bits += 5
            if bits >= 8 { out.append(UInt8((buffer >> (bits - 8)) & 0xFF)); bits -= 8 }
            buffer &= (1 << bits) - 1
        }
        return out
    }

    /// Groups of four for reading: "ABCD-EFGH-…".
    static func grouped(_ text: String) -> String {
        stride(from: 0, to: text.count, by: 4).map { i -> String in
            let start = text.index(text.startIndex, offsetBy: i), end = text.index(start, offsetBy: min(4, text.count - i))
            return String(text[start..<end])
        }.joined(separator: "-")
    }

    /// HKDF-SHA256: the 32-byte key a channel really uses, from a secret and a label, so a secret is never used directly as a key and two purposes never share one.
    static func derive(_ secret: Data, label: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data("browsersetu.remote.v1".utf8), info: Data(label.utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// A six-digit number both sides can work out from what was exchanged and only they can: the person compares it, so a stranger who only saw the QR code is not approved by mistake.
    static func confirmationNumber(secret: Data, clientNonce: Data, serverNonce: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: clientNonce + serverNonce, using: SymmetricKey(data: derive(secret, label: "confirm")))
        let value = mac.withUnsafeBytes { $0.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } } % 1_000_000
        return String(format: "%06d", value)
    }

    /// Equal-length comparison that does not stop at the first difference.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

/// TLS with a pre-shared key, as Network.framework offers it: the key identifies the peer and encrypts the channel; no certificate is involved, so there is nothing to trust-on-first-use.
enum RemoteTLS {
    /// Parameters for a listener that accepts only the given (identity, key) pairs.
    static func serverParameters(keys: [(identity: String, key: Data)], hint: String = "browsersetu") -> NWParameters {
        let tls = NWProtocolTLS.Options()
        configure(tls.securityProtocolOptions, keys: keys, hint: hint)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func clientParameters(identity: String, key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        configure(tls.securityProtocolOptions, keys: [(identity, key)], hint: nil)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private static func configure(_ options: sec_protocol_options_t, keys: [(identity: String, key: Data)], hint: String?) {
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        for (identity, key) in keys {
            let k = key.withUnsafeBytes { DispatchData(bytes: $0) }, i = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, k as __DispatchData, i as __DispatchData)
        }
        if let hint { sec_protocol_options_set_tls_pre_shared_key_identity_hint(options, Data(hint.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData) }
    }
}
