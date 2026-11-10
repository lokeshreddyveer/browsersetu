#if os(macOS)
import Foundation
import Security

// Browser Setu's own JavaScript challenge runner for yt-dlp. YouTube hides some stream addresses behind small JavaScript puzzles (the "n" and signature challenges); yt-dlp solves them by running
// its bundled solver scripts in a JavaScript engine. Instead of asking people to install Deno or Node, the app ships a tiny helper (Helpers/setu-jsc, Apple's JavaScriptCore) and a yt-dlp plugin that
// uses it. The helper runs in its own process under the App Sandbox with no other entitlement (no network, no files, no browser data) and only ever sees the solver script yt-dlp pipes in.
//
// Trust works like the bundled extractor's: nothing is passed to yt-dlp unless the helper and the plugin are byte-for-byte what Resources/BundledJSProvider.json (written by
// scripts/embed-js-provider.sh at release time) pins, and unless that manifest was written for the yt-dlp release this app pins. Anything else and yt-dlp runs exactly as before, without the plugin.
struct JSProviderManifest: Decodable, Equatable {
    var schemaVersion: Int
    var name: String
    var version: String
    var helper: String
    var helperSHA256: String
    var pluginDirectory: String
    var plugin: String
    var pluginSHA256: String
    var pluginTreeSHA256: String
    var architectures: [String]
    var signaturePolicy: String
    var entitlements: [String]
    var pinnedYtDlpVersion: String
}

enum JSChallengeProvider {
    static let manifestName = "BundledJSProvider"

    /// Why the provider is not being used. Every refusal has a reason, so Settings and the diagnostics can say what is wrong instead of "unavailable".
    enum Unavailable: Error, Equatable {
        case notInThisBuild, manifestInvalid, appHasNoTeamID, teamMismatch, ytDlpMismatch, pathsOutsideTheApp, helperMissing, helperChanged, pluginChanged, pluginFolderChanged, helperSignatureInvalid
        var summary: String {
            switch self {
            case .notInThisBuild: "this build does not include it"
            case .manifestInvalid: "its description in the app is not valid"
            case .appHasNoTeamID: "this copy of the app is not signed by a developer team"
            case .teamMismatch: "it was signed by a different team than this app"
            case .ytDlpMismatch: "it was checked for a different yt-dlp release than this app carries"
            case .pathsOutsideTheApp: "its description points outside the app"
            case .helperMissing: "the helper is missing or cannot run"
            case .helperChanged: "the helper no longer matches what was shipped"
            case .pluginChanged: "the plugin no longer matches what was shipped"
            case .pluginFolderChanged: "the plugin folder has extra or changed files"
            case .helperSignatureInvalid: "the helper's code signature is not valid"
            }
        }
    }

    /// The folder to give yt-dlp as `--plugin-dirs`, or the reason it must not be used.
    /// - `team`: the Team ID the helper must be signed by; by default the running app's own (an unsigned development build has none, so it never uses the provider).
    /// - `helperSignatureCheck`: how the helper's code signature is judged; tests substitute a stub, the app never does.
    static func verify(contents: URL? = nil, team: String? = nil, ownTeam: (() -> String?)? = nil, helperSignatureCheck: ((URL, String) -> Bool)? = nil) -> Result<URL, Unavailable> {
        let contents = contents ?? Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        guard let data = try? Data(contentsOf: resources.appendingPathComponent(manifestName + ".json")) else { return .failure(.notInThisBuild) }
        guard let m = try? JSONDecoder().decode(JSProviderManifest.self, from: data),
              m.schemaVersion == 1, m.name == "setu-jsc", m.entitlements == ["com.apple.security.app-sandbox"],
              m.signaturePolicy.hasPrefix("teamID:"), m.architectures.count == 1 else { return .failure(.manifestInvalid) }
        // The helper must be signed by the same team as this app (Developer ID, hardened runtime, App Sandbox as its only entitlement): swapping the helper, the plugin and the manifest together is not enough.
        guard let team = team ?? (ownTeam ?? { ownTeamID })() else { return .failure(.appHasNoTeamID) }
        guard m.signaturePolicy == "teamID:" + team else { return .failure(.teamMismatch) }
        // The yt-dlp this app pins is the only one the plugin was checked against.
        guard let pin = try? Data(contentsOf: resources.appendingPathComponent("BundledTools.json")),
              let pinned = (try? JSONSerialization.jsonObject(with: pin) as? [String: Any])?["version"] as? String, pinned == m.pinnedYtDlpVersion else { return .failure(.ytDlpMismatch) }
        // Every path stays inside the app: no "..", no ".", no absolute path, no links out; the plugin folder is ONE named folder, never "." or the whole Resources folder.
        guard let helper = inside(contents, m.helper), let plugin = inside(resources, m.plugin), !m.pluginDirectory.contains("/"),
              let folder = inside(resources, m.pluginDirectory), folder.standardizedFileURL.path != resources.standardizedFileURL.path,
              plugin.path.hasPrefix(folder.path + "/") else { return .failure(.pathsOutsideTheApp) }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return .failure(.helperMissing) }
        guard ManagedTool.sha256(of: helper) == m.helperSHA256 else { return .failure(.helperChanged) }
        guard ManagedTool.sha256(of: plugin) == m.pluginSHA256 else { return .failure(.pluginChanged) }
        // yt-dlp imports EVERY module under the folder it is given, so the whole folder is pinned, not just the one file: an extra module, package, cache file or link changes this digest.
        guard ManagedTool.treeDigest(of: folder) == m.pluginTreeSHA256 else { return .failure(.pluginFolderChanged) }
        guard (helperSignatureCheck ?? helperIsSignedAsRequired)(helper, team) else { return .failure(.helperSignatureInvalid) }
        return .success(folder)
    }

    /// The folder to give yt-dlp as `--plugin-dirs`, or nil when the provider must not be used.
    static func verifiedPluginFolder(contents: URL? = nil, team: String? = nil, ownTeam: (() -> String?)? = nil, helperSignatureCheck: ((URL, String) -> Bool)? = nil) -> URL? {
        try? verify(contents: contents, team: team, ownTeam: ownTeam, helperSignatureCheck: helperSignatureCheck).get()
    }

    /// Whether the helper's code signature is valid, strict, for the Team ID, with the hardened runtime and exactly the App Sandbox entitlement. Uses Apple's code-signing API, not the manifest.
    static func helperIsSignedAsRequired(_ helper: URL, team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"com.browsersetu.mac.jsc\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        guard SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures)), requirement, nil) == errSecSuccess else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess, let dict = info as? [String: Any] else { return false }
        guard let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any], Set(entitlements.keys) == ["com.apple.security.app-sandbox"] else { return false }
        let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        return flags & 0x10000 != 0          // kSecCodeSignatureRuntime: the hardened runtime
    }

    /// The Team ID this running app is signed with; nil for an unsigned development build.
    static var ownTeamID: String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// What Settings reports. Honest by construction: "built in" only when the same check that gates the plugin passes right now.
    enum Status: Equatable { case builtIn(version: String), unavailable(Unavailable) }
    static func status(contents: URL? = nil, team: String? = nil, helperSignatureCheck: ((URL, String) -> Bool)? = nil) -> Status {
        let contents = contents ?? Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        switch verify(contents: contents, team: team, helperSignatureCheck: helperSignatureCheck) {
        case .failure(let why): return .unavailable(why)
        case .success:
            guard let data = try? Data(contentsOf: contents.appendingPathComponent("Resources/\(manifestName).json")), let m = try? JSONDecoder().decode(JSProviderManifest.self, from: data) else { return .unavailable(.manifestInvalid) }
            return .builtIn(version: m.version)
        }
    }

    /// Options that add the verified plugin. `--no-plugin-dirs` (already in the base list) cleared every other place yt-dlp would look, so this is the only plugin it can load.
    static func pluginArguments(contents: URL? = nil, team: String? = nil, helperSignatureCheck: ((URL, String) -> Bool)? = nil) -> [String] {
        guard let folder = verifiedPluginFolder(contents: contents, team: team, helperSignatureCheck: helperSignatureCheck) else { return [] }
        return ["--plugin-dirs", folder.path]
    }

    private static func inside(_ base: URL, _ relative: String) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }), !relative.contains("\0") else { return nil }
        let url = base.appendingPathComponent(relative)
        let resolved = url.resolvingSymlinksInPath().path, root = base.resolvingSymlinksInPath().path
        guard resolved == root || resolved.hasPrefix(root + "/") else { return nil }
        return url
    }
}
#endif
