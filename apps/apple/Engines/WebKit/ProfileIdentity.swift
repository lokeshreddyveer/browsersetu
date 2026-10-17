import CryptoKit
import Foundation

enum ProfileIdentity {
    /// Stable per-profile identifier so each profile owns an isolated website data store.
    static func dataStoreID(for profile: String) -> UUID {
        let digest = SHA256.hash(data: Data("browsersetu.profile.\(profile)".utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
