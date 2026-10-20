import CommonCrypto
import CryptoKit
import Foundation

/// What a backup holds: the user's bookmarks and interface settings. Passwords, cookies and browsing history are
/// deliberately not included.
struct BackupPayload: Codable, Equatable {
    struct Bookmark: Codable, Equatable {
        var url: String
        var title: String
        var folder: String
    }

    struct Tab: Codable, Equatable {
        var url: String
        var title: String
        /// The tab group it was in. Older copies have none.
        var group: String? = nil
    }

    var version = 1
    var created: Date
    var bookmarks: [Bookmark]
    var settings: [String: String]
    /// Open tabs. Only sync carries them; a backup file leaves them out.
    var tabs: [Tab]? = nil
    /// The device that made it. Only sync fills it in.
    var device: String? = nil
    /// The sync group it belongs to. Only sync fills it in; a snapshot from another group is never applied.
    var syncGroup: String? = nil
    /// The id of the device that made it (sync only), so devices can be approved or revoked one by one.
    var deviceID: String? = nil
    /// Research collections, in a backup file only (sync does not carry them).
    var research: [ResearchCollection]? = nil
    /// Saved passwords, only when the person chose to include them. A backup file is sealed with their passphrase.
    var passwords: [WebLogin]? = nil
    /// Sync only: every synced item with its stamp, so devices merge deterministically and deletions are remembered. When present it replaces `bookmarks`.
    var state: SyncState? = nil
    /// Sync only: counts up with every snapshot this device writes, so an out-of-date copy delivered late can be recognised and ignored.
    var seq: Int? = nil
    /// Sync only: the extensions installed on that device, for information (they are never installed by sync).
    var extensions: [SyncExtension]? = nil
    /// Sync only: tabs this device sent to other devices. Each stays until its recipient has had a week to see it.
    var outbox: [SentTab]? = nil
}

struct SyncExtension: Codable, Equatable, Identifiable {
    var name: String
    var chromeID: String?
    var version: String
    var id: String { chromeID ?? name }
}

extension BackupPayload: Sendable {}

enum BackupError: LocalizedError {
    case emptyPassphrase, notABackup, unsupportedVersion, wrongPassphraseOrDamaged, keyDerivation

    var errorDescription: String? {
        switch self {
        case .emptyPassphrase: "Enter a passphrase."
        case .notABackup: "That file is not a Browser Setu backup."
        case .unsupportedVersion: "That backup was made by a newer version of Browser Setu."
        case .wrongPassphraseOrDamaged: "The passphrase is wrong, or the file is damaged."
        case .keyDerivation: "Could not prepare the encryption key."
        }
    }
}

/// An encrypted backup file: a short header, then AES-256-GCM over the JSON payload. The key comes from the
/// passphrase through PBKDF2-HMAC-SHA256 with a random salt, and the header is authenticated with the data, so
/// changing any byte of either makes opening fail. Everything happens on this device.
enum BackupFile {
    private static let magic = Data("BSBK".utf8)
    private static let formatVersion: UInt8 = 1
    private static let saltLength = 16
    private static let headerLength = 4 + 1 + 4 + 16
    static let defaultIterations: UInt32 = 600_000
    private static let acceptedIterations: ClosedRange<UInt32> = 1_000...5_000_000

    static func seal(_ payload: BackupPayload, passphrase: String, iterations: UInt32 = defaultIterations) throws -> Data {
        guard !passphrase.isEmpty else { throw BackupError.emptyPassphrase }
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BackupError.keyDerivation }

        var header = magic
        header.append(formatVersion)
        withUnsafeBytes(of: iterations.bigEndian) { header.append(contentsOf: $0) }
        header.append(salt)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(payload)
        let key = try derive(passphrase: passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(plain, using: key, authenticating: header)
        guard let combined = box.combined else { throw BackupError.keyDerivation }
        return header + combined
    }

    static func open(_ data: Data, passphrase: String) throws -> BackupPayload {
        guard data.count > headerLength + 28, data.prefix(4) == magic else { throw BackupError.notABackup }
        guard data[4] == formatVersion else { throw BackupError.unsupportedVersion }
        let iterations = data[5..<9].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard acceptedIterations.contains(iterations), !passphrase.isEmpty else { throw BackupError.wrongPassphraseOrDamaged }
        let header = data.prefix(headerLength)
        let salt = data[9..<(9 + saltLength)]
        let key = try derive(passphrase: passphrase, salt: Data(salt), iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(headerLength))
            let plain = try AES.GCM.open(box, using: key, authenticating: header)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(BackupPayload.self, from: plain)
        } catch {
            throw BackupError.wrongPassphraseOrDamaged
        }
    }

    private static func derive(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { pw in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: CChar.self), pw.count,
                    s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw BackupError.keyDerivation }
        return SymmetricKey(data: derived)
    }
}
