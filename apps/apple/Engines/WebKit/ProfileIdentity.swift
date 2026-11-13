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

    // MARK: Test-process store identity

    /// What a process should do for a profile's persistent website-data store.
    enum StoreDecision: Equatable {
        /// The production identity, exactly `dataStoreID(for:)`: every non-test process, and every Release build.
        case production(UUID)
        /// A test process: an identity no production profile can have, so a test can never open, clear or delete a person's own store.
        case test(UUID)
        /// A test process that is not safely set up: no persistent store may be created.
        case refused(String)
    }

    /// Decided from the process's environment alone, so it can be checked with made-up paths. A test process is one XCTest started or one given a throwaway `-UITestRoot` (as `TestIsolation` decides).
    /// The identity is derived from a fixed test namespace, the canonical test root and the profile; a UI-test run's root is its `-UITestRoot`, an app-hosted unit-test run has no root of its own so its
    /// process token stands in. A test process that still has the person's own home, or whose root is empty or outside the temporary folders, is refused.
    static func storeDecision(profile: String, environment: [String: String], arguments: [String], realHome: String, temporaryDirectory: String, processToken: String) -> StoreDecision {
        // `-UITestRoot` with no value is still a test launch (the app builds its profile in the temporary folder): it is refused, never treated as production.
        if let i = arguments.firstIndex(of: "-UITestRoot"), !(arguments.indices.contains(i + 1) && !arguments[i + 1].isEmpty) { return .refused("the test root is empty") }
        let home = TestIsolation.homeDecision(environment: environment, arguments: arguments, realHome: realHome, relocatedHome: "")
        switch home {
        case .notATestProcess:
            return .production(dataStoreID(for: profile))
        case .relocate:
            return .refused("a test process still has the person's own home folder")
        case .alreadyRelocated:
            break
        }
        let canonicalRoot: String
        if let i = arguments.firstIndex(of: "-UITestRoot") {
            guard arguments.indices.contains(i + 1), !arguments[i + 1].isEmpty else { return .refused("the test root is empty") }
            let given = arguments[i + 1]
            let full = given.hasPrefix("/") ? given : (temporaryDirectory as NSString).appendingPathComponent(given)
            canonicalRoot = ((full as NSString).standardizingPath as NSString).resolvingSymlinksInPath
            let tmp = (temporaryDirectory as NSString).resolvingSymlinksInPath
            guard canonicalRoot.hasPrefix(tmp) || canonicalRoot.hasPrefix("/private/tmp/") else { return .refused("the test root is not under a temporary folder") }
        } else {
            guard !processToken.isEmpty else { return .refused("no test namespace") }
            canonicalRoot = "xctest-host:" + processToken
        }
        let digest = SHA256.hash(data: Data("browsersetu.test.v1|\(canonicalRoot)|\(profile)".utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return .test(UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])))
    }

    #if DEBUG && os(macOS)
    private static let processToken = UUID().uuidString
    #endif

    /// The persistent store identity for this process, or nil when a test process is not safely set up (the caller then creates no persistent store and touches none).
    /// Release builds and every non-test process get `dataStoreID(for:)` unchanged.
    static func storeID(for profile: String) -> UUID? {
        #if DEBUG && os(macOS)
        switch storeDecision(profile: profile, environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments, realHome: TestIsolation.realHome,
                             temporaryDirectory: NSTemporaryDirectory(), processToken: processToken) {
        case .production(let id), .test(let id): return id
        case .refused(let why):
            FileHandle.standardError.write(Data("ProfileIdentity: no persistent website data store for a test process: \(why)\n".utf8))
            return nil
        }
        #else
        return dataStoreID(for: profile)
        #endif
    }
}
