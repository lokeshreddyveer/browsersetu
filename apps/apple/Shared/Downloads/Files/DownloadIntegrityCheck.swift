import Foundation
import CryptoKit

/// Checking a finished file. Two different things are reported and never mixed up:
///  - **Matches a checksum you were given.** The file's SHA-256 equals one the person (or a trusted caller) supplied. That is evidence the file is the intended one.
///  - **A computed SHA-256.** The file's digest, which says what the bytes are but nothing about who made them: a digest that came from the same server as the file proves nothing, since
///    whoever could change the file could change the digest too. It is shown for comparing with a trusted source, and never counted as verification.
enum DownloadIntegrityCheck {
    enum Outcome: Equatable, Sendable {
        /// Equals the checksum that was given. `trusted` is true when the person supplied it themselves.
        case matchesGivenChecksum(trusted: Bool)
        case doesNotMatchChecksum(expected: String)
        case sizeDiffers(expected: Int64)
        /// No checksum was given: only the digest is known.
        case computedOnly
    }

    struct Report: Equatable, Sendable {
        var bytes: Int64
        var sha256: String
        var outcome: Outcome
    }

    enum Failure: Error, Equatable { case unreadable(String), notAFile }

    /// 64 lowercase hex digits from what a person may paste ("SHA256:AB…", spaces, upper case). Nil if it is not a SHA-256.
    static func normalizedDigest(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sha256:", "sha-256:", "sha256=", "sha256 "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        t = t.replacingOccurrences(of: " ", with: "")
        guard t.count == 64, t.allSatisfy({ $0.isHexDigit }) else { return nil }
        return t
    }

    /// Reads the file once, in chunks of 1 MiB, so a large file never sits in memory. Call from a background task; it is synchronous.
    static func verify(file: URL, expectedSHA256: String?, expectedSize: Int64?, digestIsTrusted: Bool, isCancelled: () -> Bool = { false }) throws -> Report {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { throw Failure.notAFile }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) } catch { throw Failure.unreadable(error.localizedDescription) }
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while true {
            if isCancelled() { throw CancellationError() }
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        var outcome = Outcome.computedOnly
        if let expectedSHA256, let wanted = normalizedDigest(expectedSHA256) {
            outcome = wanted == digest ? .matchesGivenChecksum(trusted: digestIsTrusted) : .doesNotMatchChecksum(expected: wanted)
        } else if let expectedSize, expectedSize > 0, expectedSize != bytes {
            outcome = .sizeDiffers(expected: expectedSize)
        }
        return Report(bytes: bytes, sha256: digest, outcome: outcome)
    }

    static func verifyAsync(file: URL, expectedSHA256: String?, expectedSize: Int64?, digestIsTrusted: Bool) async throws -> Report {
        try await Task.detached(priority: .utility) {
            try verify(file: file, expectedSHA256: expectedSHA256, expectedSize: expectedSize, digestIsTrusted: digestIsTrusted, isCancelled: { Task.isCancelled })
        }.value
    }

    /// The sentence the inspector shows. A computed digest is never called "verified".
    static func summary(_ outcome: Outcome?, sha256: String?) -> String {
        switch outcome {
        case .matchesGivenChecksum(let trusted)?: return trusted ? "Matches the checksum you gave." : "Matches the checksum supplied with the request."
        case .doesNotMatchChecksum?: return "Does not match the checksum it was given."
        case .sizeDiffers?: return "The file is a different size than expected."
        case .computedOnly?, nil: return sha256 == nil ? "Not checked." : "SHA-256 calculated. This is not proof the file is genuine: compare it with a checksum from the publisher."
        }
    }
}
