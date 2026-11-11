#if os(macOS)
import Foundation
import Security

// How Browser Setu answers YouTube's JavaScript puzzles, in a fixed, explicit order:
//
//   1. native      Browser Setu's own sandboxed JavaScriptCore helper (JSChallengeProvider).             IMPLEMENTED and shipped in 0.4.1.
//   2. managed Deno an optional Deno that Browser Setu itself installed and verified (ManagedDeno below).  PREPARED, NOT SHIPPED: nothing in 0.4.1 downloads, hosts, bundles or requires it. Without
//                   a verified install it is simply absent and changes nothing.
//   3. no solver    yt-dlp carries on without solving: some formats may be missing, some videos cannot be read, and the error says so in plain words (JSChallengeProviderAdvice).
//
// yt-dlp itself chooses between the first two by priority (the native provider's is higher), so tier 2 is only ever used when tier 1 is unavailable. What is never done: looking in PATH, using a Homebrew or
// user-installed Deno or Node, or giving a custom yt-dlp any of these arguments (a custom program gets exactly the arguments it always got).

/// What a managed Deno's manifest (Resources/BundledDeno.json, written by the media-tools pipeline from the verified package, never by hand) must say beyond the usual tool fields.
struct DenoPin: Decodable, Equatable {
    var name: String
    var version: String
    var executable: String?
    var architectures: [String]?
    var signaturePolicy: String?
    /// The yt-dlp releases this Deno was verified to solve with (together with the yt-dlp-ejs scripts that release carries).
    var forYtDlp: [String]?
}

enum ManagedDeno {
    /// The same managed-tool machinery as ffmpeg and yt-dlp: versioned folder, atomic install, rollback, tree-digest verification. No second installer.
    static let tool = ManagedTool(resource: "BundledDeno", component: "deno")
    /// yt-dlp's own minimum Deno version.
    static let minimumVersion = [2, 3, 0]
    /// The entitlements Deno needs under the hardened runtime (V8 compiles code at run time). Nothing outside this set is accepted.
    static let allowedEntitlements: Set<String> = ["com.apple.security.cs.allow-jit", "com.apple.security.cs.allow-unsigned-executable-memory",
                                                  "com.apple.security.cs.disable-executable-page-protection", "com.apple.security.cs.disable-library-validation"]

    enum Unavailable: Error, Equatable {
        case notOffered, notInstalled, pinInvalid, changed, outsideItsFolder, appHasNoTeamID, teamMismatch, signatureInvalid, wrongArchitecture, tooOld(String), notVerifiedForThisYtDlp
        var summary: String {
            switch self {
            case .notOffered: "not offered in this release"
            case .notInstalled: "not installed"
            case .pinInvalid: "its description in the app is not valid"
            case .changed: "the installed files no longer match what was verified"
            case .outsideItsFolder: "it is not inside Browser Setu's own tools folder"
            case .appHasNoTeamID: "this copy of the app is not signed by a developer team"
            case .teamMismatch: "it was signed by a different team than this app"
            case .signatureInvalid: "its code signature is not valid"
            case .wrongArchitecture: "it does not run on this Mac's processor"
            case .tooOld(let v): "version \(v) is older than the video tool supports"
            case .notVerifiedForThisYtDlp: "it was not verified with the video tool release this app carries"
            }
        }
    }
    struct Verified: Equatable { var url: URL; var version: String }

    /// Whether there is a managed Deno that may be handed to yt-dlp: installed in Browser Setu's own folder, every file exactly as verified, signed by this app's team with the hardened runtime and only
    /// the entitlements Deno needs, built for this Mac's processor, new enough, and verified for this yt-dlp. Any single failure means "not used", with the reason.
    static func verify(tool: ManagedTool = ManagedDeno.tool, ytDlpVersion: String? = nil, ytDlpVersionProvider: (() -> String?)? = nil, team: String? = nil, ownTeam: (() -> String?)? = nil,
                       signatureCheck: ((URL, String) -> Bool)? = nil, architectures: ((URL) -> [String])? = nil) -> Result<Verified, Unavailable> {
        guard let manifestURL = tool.manifestURL, let raw = try? Data(contentsOf: manifestURL) else { return .failure(.notOffered) }
        guard let pin = try? JSONDecoder().decode(DenoPin.self, from: raw), pin.name == "deno", let base = tool.manifest(), base.treeSHA256?.isEmpty == false else { return .failure(.pinInvalid) }
        guard tool.isPresent else { return .failure(.notInstalled) }
        guard let verified = tool.verify() else { return .failure(.changed) }
        // Absolute, and inside Browser Setu's own folder for this tool (or inside the app): never a path from anywhere else.
        let exe = verified.url.resolvingSymlinksInPath()
        let homes = [tool.managedRoot, tool.inAppFolder].map { $0.resolvingSymlinksInPath().path + "/" }
        guard exe.path.hasPrefix("/"), homes.contains(where: { exe.path.hasPrefix($0) }) || tool.helpersFolder.map({ exe.path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }) == true else { return .failure(.outsideItsFolder) }
        guard let team = team ?? (ownTeam ?? { JSChallengeProvider.ownTeamID })() else { return .failure(.appHasNoTeamID) }
        guard pin.signaturePolicy == "teamID:" + team else { return .failure(.teamMismatch) }
        guard (signatureCheck ?? isSignedAsRequired)(exe, team) else { return .failure(.signatureInvalid) }
        let here = Self.thisMacsArchitecture
        guard (architectures ?? machOArchitectures)(exe) == [here], pin.architectures == [here] else { return .failure(.wrongArchitecture) }
        guard compare(pin.version, atLeast: minimumVersion) else { return .failure(.tooOld(pin.version)) }
        // Fail CLOSED: if the yt-dlp release this app carries cannot be read, the pairing cannot be shown, so the Deno is not used.
        guard let y = ytDlpVersion ?? (ytDlpVersionProvider ?? currentYtDlpVersion)(), pin.forYtDlp?.contains(y) == true else { return .failure(.notVerifiedForThisYtDlp) }
        return .success(Verified(url: exe, version: pin.version))
    }

    /// The options that hand a verified Deno to yt-dlp by ABSOLUTE path (never PATH). Empty when there is none, which is every 0.4.1 build.
    static func runtimeArguments(tool: ManagedTool = ManagedDeno.tool, ytDlpVersion: String? = nil, ytDlpVersionProvider: (() -> String?)? = nil, team: String? = nil, ownTeam: (() -> String?)? = nil,
                                 signatureCheck: ((URL, String) -> Bool)? = nil, architectures: ((URL) -> [String])? = nil) -> [String] {
        guard case .success(let d) = verify(tool: tool, ytDlpVersion: ytDlpVersion, ytDlpVersionProvider: ytDlpVersionProvider, team: team, ownTeam: ownTeam, signatureCheck: signatureCheck, architectures: architectures) else { return [] }
        return ["--js-runtimes", "deno:" + d.url.path]
    }

    static var thisMacsArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func currentYtDlpVersion() -> String? { BundledExtractor.manifest()?.version }

    static func compare(_ version: String, atLeast minimum: [Int]) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? -1 }
        guard parts.count >= 3, !parts.contains(-1) else { return false }
        for (a, b) in zip(parts, minimum) { if a != b { return a > b } }
        return true
    }

    /// Valid strict signature for the team, hardened runtime, and entitlements that are a subset of what Deno needs.
    static func isSignedAsRequired(_ url: URL, team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        guard SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures)), requirement, nil) == errSecSuccess else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess, let dict = info as? [String: Any] else { return false }
        let entitlements = Set(((dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]) ?? [:]).keys)
        guard entitlements.isSubset(of: allowedEntitlements) else { return false }
        return ((dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0) & 0x10000 != 0          // the hardened runtime
    }

    /// The processor types in a Mach-O file's header (thin or universal).
    static func machOArchitectures(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 4096) else { return [] }
        try? h.close()
        func u32(_ o: Int, bigEndian: Bool = false) -> UInt32? {
            guard head.count >= o + 4 else { return nil }
            let b = head.subdata(in: o..<o + 4).map(UInt32.init)
            return bigEndian ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3] : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0]
        }
        func name(_ cpu: UInt32) -> String { cpu == 0x0100000c ? "arm64" : cpu == 0x01000007 ? "x86_64" : "other" }
        guard let magic = u32(0) else { return [] }
        if magic == 0xfeedfacf, let cpu = u32(4) { return [name(cpu)] }                     // thin, 64-bit, little-endian
        if magic == 0xbebafeca, let n = u32(4, bigEndian: true) {                           // universal (stored big-endian)
            return (0..<Int(min(n, 8))).compactMap { u32(8 + $0 * 20, bigEndian: true) }.map(name).sorted()
        }
        return ["other"]
    }
}

/// One honest answer to "how are YouTube's JavaScript puzzles handled here?": the tiers in order, what each one says right now, and which one would be used.
enum JSSolver {
    struct Report: Equatable {
        var native: String
        var managedDeno: String
        var effective: String
        /// Plain-text diagnostics: the full order and the state of every tier, suitable for a log or a support message.
        var diagnostics: String
    }

    static func report(contents: URL? = nil, team: String? = nil, nativeSignatureCheck: ((URL, String) -> Bool)? = nil,
                       deno: Result<ManagedDeno.Verified, ManagedDeno.Unavailable>? = nil) -> Report {
        let nativeStatus = JSChallengeProvider.status(contents: contents, team: team, helperSignatureCheck: nativeSignatureCheck)
        let denoResult = deno ?? ManagedDeno.verify(team: team)
        let native: String, nativeUsable: Bool
        switch nativeStatus {
        case .builtIn(let v): native = "built in (sandboxed JavaScriptCore helper \(v))"; nativeUsable = true
        case .unavailable(let why): native = "unavailable: \(why.summary)"; nativeUsable = false
        }
        let managed: String, denoUsable: Bool
        switch denoResult {
        case .success(let d): managed = "available (fallback runtime \(d.version), verified)"; denoUsable = true
        case .failure(let why): managed = (why == .notOffered ? "not available: \(why.summary) (planned, not part of this release)" : "not used: \(why.summary)"); denoUsable = false
        }
        let effective = nativeUsable ? "the built-in solver" : denoUsable ? "the fallback runtime" : "none: some YouTube formats may be missing"
        let text = """
        YouTube JavaScript puzzles, in order of use:
          1. built-in solver:  \(native)
          2. fallback runtime: \(managed)
          3. no solver:        the video tool continues without solving; some formats may be missing or a video cannot be read
        Used now: \(effective)
        A program you chose yourself (Settings > Media) is never given any of this automatically; PATH is never searched.
        """
        return Report(native: native, managedDeno: managed, effective: effective, diagnostics: text)
    }
}
#endif
