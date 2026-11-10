import Foundation

/// GitHub releases, source archives and Actions artifacts. Public repositories need no account; a private one uses the person's token for api.github.com only (the token is attached by the account
/// router for that exact host and is dropped when GitHub redirects to its storage host).
struct GitHubProvider: Sendable {
    enum Target: Equatable {
        case releases(owner: String, repo: String)                     // the list of releases
        case latest(owner: String, repo: String)
        case tag(owner: String, repo: String, tag: String)
        case asset(owner: String, repo: String, tag: String, name: String)   // a single file link
        case source(owner: String, repo: String, ref: String)          // tree/blob/archive of a ref
        case run(owner: String, repo: String, runID: Int64)            // Actions artifacts of a run
        var slug: String {
            switch self {
            case .releases(let o, let r), .latest(let o, let r), .tag(let o, let r, _), .asset(let o, let r, _, _), .source(let o, let r, _), .run(let o, let r, _): "\(o)/\(r)"
            }
        }
    }

    var apiBase = URL(string: "https://api.github.com")!
    var webHost = "github.com"
    let transport: ProviderTransport
    /// Whether a saved token will be attached to a request for this URL (decided by the account router; the token itself is never visible here).
    var hasToken: @Sendable (URL) -> Bool = { _ in false }
    var mac: ProviderPlatform.Arch = ProviderPlatform.currentArch

    // MARK: Addresses

    static func isName(_ s: String) -> Bool { !s.isEmpty && s.count <= 100 && s.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil && s != "." && s != ".." }

    static func parse(_ url: URL, webHost: String = "github.com") -> Target? {
        guard url.scheme == "https" || url.scheme == "http", url.host?.lowercased() == webHost else { return nil }
        let parts = url.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 2, isName(parts[0]), isName(parts[1]) else { return nil }
        let o = parts[0], r = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        guard isName(r) else { return nil }
        if parts.count == 2 { return .releases(owner: o, repo: r) }
        switch parts[2] {
        case "releases":
            if parts.count == 3 { return .releases(owner: o, repo: r) }
            if parts[3] == "latest" { return .latest(owner: o, repo: r) }
            if parts[3] == "tag", parts.count >= 5, !parts[4...].contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) { return .tag(owner: o, repo: r, tag: parts[4...].joined(separator: "/")) }
            if parts[3] == "download", parts.count >= 6, !parts[4...].contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) { return .asset(owner: o, repo: r, tag: parts[4..<(parts.count - 1)].joined(separator: "/"), name: parts.last!) }
            return nil
        case "tree", "commit":
            // A branch name may itself contain "/" ("feature/login"), and the address does not say where the name ends: more than one segment is not guessed at.
            return parts.count == 4 && parts[3] != "." && parts[3] != ".." ? .source(owner: o, repo: r, ref: parts[3]) : nil
        case "blob":
            return nil
        case "archive":
            // /archive/refs/tags/v1.zip, /archive/v1.tar.gz
            var ref = parts.dropFirst(3).joined(separator: "/")
            for ext in [".zip", ".tar.gz", ".tgz"] where ref.hasSuffix(ext) { ref = String(ref.dropLast(ext.count)) }
            if ref.hasPrefix("refs/tags/") { ref = String(ref.dropFirst(10)) } else if ref.hasPrefix("refs/heads/") { ref = String(ref.dropFirst(11)) }
            return ref.isEmpty || ref.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) ? nil : .source(owner: o, repo: r, ref: ref)
        case "actions":
            if parts.count >= 5, parts[3] == "runs", let id = Int64(parts[4]), id > 0 { return .run(owner: o, repo: r, runID: id) }
            return nil
        default:
            return nil
        }
    }

    private func api(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = (c.percentEncodedPath.hasSuffix("/") ? String(c.percentEncodedPath.dropLast()) : c.percentEncodedPath) + path
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }
    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s }
    private static func encPath(_ s: String) -> String { s.split(separator: "/", omittingEmptySubsequences: false).map { enc(String($0)) }.joined(separator: "/") }
    private var headers: [String: String] { ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"] }

    private func json<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        let r = try await transport.get(url, headers: headers, maxBytes: 16_000_000)
        try ProviderStatus.check(r, host: url.host ?? "GitHub", hadToken: hasToken(url))
        do { return try JSONDecoder().decode(T.self, from: r.body) } catch { throw ProviderError.badResponse("unexpected JSON") }
    }

    // MARK: Wire shapes

    struct Asset: Decodable { var id: Int64; var name: String; var size: Int64?; var url: String; var browser_download_url: String; var digest: String?; var state: String? }
    struct Release: Decodable { var id: Int64; var tag_name: String; var name: String?; var draft: Bool?; var prerelease: Bool?; var assets: [Asset]?; var zipball_url: String?; var tarball_url: String? }
    struct RepoInfo: Decodable { var `private`: Bool?; var default_branch: String? }
    struct Artifacts: Decodable { struct A: Decodable { var id: Int64; var name: String; var size_in_bytes: Int64?; var expired: Bool?; var archive_download_url: String }; var artifacts: [A] }

    // MARK: Listing

    func listing(_ target: Target) async throws -> ProviderListing {
        switch target {
        case .releases(let o, let r):
            let isPrivate = try await repoIsPrivate(o, r)
            let releases = try await json(api("/repos/\(o)/\(r)/releases", [URLQueryItem(name: "per_page", value: "30")]), as: [Release].self).filter { $0.draft != true }
            return try await build(o, r, releases, isPrivate: isPrivate, sidecarLimit: 3, source: "github:\(o)/\(r)")
        case .latest(let o, let r):
            let isPrivate = try await repoIsPrivate(o, r)
            let rel = try await json(api("/repos/\(o)/\(r)/releases/latest"), as: Release.self)
            return try await build(o, r, [rel], isPrivate: isPrivate, sidecarLimit: 1, source: "github:\(o)/\(r)@\(rel.tag_name)")
        case .tag(let o, let r, let tag), .asset(let o, let r, let tag, _):
            let isPrivate = try await repoIsPrivate(o, r)
            let rel = try await json(api("/repos/\(o)/\(r)/releases/tags/\(Self.encPath(tag))"), as: Release.self)
            var l = try await build(o, r, [rel], isPrivate: isPrivate, sidecarLimit: 1, source: "github:\(o)/\(r)@\(tag)")
            if case .asset(_, _, _, let name) = target { l.files = l.files.filter { $0.name == name || $0.kind == .sourceArchive }; if !l.files.contains(where: { $0.name == name }) { throw ProviderError.notFound } }
            return l
        case .source(let o, let r, let ref):
            let isPrivate = try await repoIsPrivate(o, r)
            return ProviderListing(title: "\(o)/\(r) — source at \(ref)", source: "github:\(o)/\(r)@src-\(ref)", files: sourceArchives(o, r, ref: ref, isPrivate: isPrivate), revision: ref)
        case .run(let o, let r, let runID):
            let a = try await json(api("/repos/\(o)/\(r)/actions/runs/\(runID)/artifacts", [URLQueryItem(name: "per_page", value: "100")]), as: Artifacts.self)
            var notices = ["Workflow artifacts always need an access token with read access to Actions, and their download links last one minute: each is requested fresh when it starts."]
            let files = a.artifacts.filter { $0.expired != true }.map { x in
                ProviderFile(id: "artifact:\(x.id)", name: ProviderNames.safe(x.name) + ".zip", size: ProviderNames.size(x.size_in_bytes), url: api("/repos/\(o)/\(r)/actions/artifacts/\(x.id)/zip"), kind: .artifact, needsAccount: true, note: "Workflow artifact", group: "run \(runID)")
            }
            if a.artifacts.contains(where: { $0.expired == true }) { notices.append("Some artifacts have expired and are not listed.") }
            return ProviderListing(title: "\(o)/\(r) — run \(runID)", source: "github:\(o)/\(r)@run-\(runID)", files: files, revision: nil, notices: notices)
        }
    }

    func repoIsPrivate(_ o: String, _ r: String) async throws -> Bool {
        (try await json(api("/repos/\(o)/\(r)"), as: RepoInfo.self)).private ?? false
    }

    func sourceArchives(_ o: String, _ r: String, ref: String, isPrivate: Bool) -> [ProviderFile] {
        ["zip": "zipball", "tar.gz": "tarball"].sorted { $0.key < $1.key }.map { ext, kind in
            ProviderFile(id: "source:\(kind):\(ref)", name: "\(r)-\(ProviderNames.safe(ref)).\(ext)", url: api("/repos/\(o)/\(r)/\(kind)/\(Self.encPath(ref))"), headers: [:], kind: .sourceArchive, needsAccount: isPrivate,
                         note: isPrivate ? "Private repository: GitHub's temporary link lasts five minutes, so it is requested when the download starts." : nil, group: ref)
        }
    }

    private func build(_ o: String, _ r: String, _ releases: [Release], isPrivate: Bool, sidecarLimit: Int, source: String) async throws -> ProviderListing {
        var files: [ProviderFile] = []
        var notices: [String] = []
        for (i, rel) in releases.enumerated() {
            let group = rel.tag_name
            var relFiles: [ProviderFile] = []
            for a in rel.assets ?? [] where a.state == nil || a.state == "uploaded" {
                // Public: the stable public link. Private: GitHub's API link, which needs the token (sent to api.github.com only).
                guard let direct = URL(string: a.browser_download_url), let viaAPI = URL(string: a.url) else { continue }
                var f = ProviderFile(id: "asset:\(a.id)", name: ProviderNames.safe(a.name), size: ProviderNames.size(a.size), url: isPrivate ? viaAPI : direct, kind: .asset, needsAccount: isPrivate, prerelease: rel.prerelease == true, group: group,
                                     platform: ProviderPlatform.classify(a.name))
                if isPrivate { f.headers = ["Accept": "application/octet-stream"] }
                if let d = a.digest, d.hasPrefix("sha256:"), let hex = Self.hex64(String(d.dropFirst(7))) { f.sha256 = hex; f.checksumSource = "GitHub digest" }
                if Self.isSignature(a.name) { f.note = "Signature file. Browser Setu saves it; it does not verify signatures." }
                relFiles.append(f)
            }
            if i < sidecarLimit { relFiles = await applySidecars(relFiles, assets: rel.assets ?? [], isPrivate: isPrivate) }
            files += relFiles
            files += sourceArchives(o, r, ref: rel.tag_name, isPrivate: isPrivate).map { var f = $0; f.group = group; f.prerelease = rel.prerelease == true; return f }
        }
        if releases.isEmpty { notices.append("This repository has no releases. Its source can be downloaded from the address of a branch or tag.") }
        return ProviderListing(title: "\(o)/\(r)" + (releases.count == 1 ? " — \(releases[0].name ?? releases[0].tag_name)" : ""), source: source, files: files, revision: releases.first?.tag_name, notices: notices, releaseNames: releases.map(\.tag_name))
    }

    // MARK: Checksums

    static func hex64(_ s: String) -> String? { let t = s.lowercased(); return t.count == 64 && t.allSatisfy(\.isHexDigit) ? t : nil }
    static func isSignature(_ n: String) -> Bool { let l = n.lowercased(); return [".sig", ".asc", ".minisig", ".pem", ".sigstore", ".sigstore.json", ".intoto.jsonl"].contains { l.hasSuffix($0) } }
    static func isChecksumList(_ n: String) -> Bool { let l = n.lowercased(); return l == "sha256sums" || l == "sha256sums.txt" || l == "checksums.txt" || l.hasSuffix("_checksums.txt") || l.hasSuffix("-checksums.txt") || l.hasSuffix("_sha256sums.txt") || l == "checksums.sha256" }

    /// "<hex>  name", "<hex> *name" and "SHA256 (name) = <hex>" lines.
    static func parseChecksumList(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("SHA256 (") , let close = l.range(of: ") = ") { if let h = hex64(String(l[close.upperBound...]).trimmingCharacters(in: .whitespaces)) { out[String(l[l.index(l.startIndex, offsetBy: 8)..<close.lowerBound])] = h }; continue }
            let bits = l.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let h = hex64(bits[0]) else { continue }
            var name = bits[1].trimmingCharacters(in: .whitespaces); if name.hasPrefix("*") { name.removeFirst() }
            if name.hasPrefix("./") { name.removeFirst(2) }
            if !name.contains("/") { out[name] = h }
        }
        return out
    }

    private func applySidecars(_ files: [ProviderFile], assets: [Asset], isPrivate: Bool) async -> [ProviderFile] {
        var files = files
        let byName = Dictionary(assets.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var lists = 0, fetched = 0
        for a in assets {
            let name = a.name, lower = name.lowercased()
            var map: [String: String] = [:]
            if Self.isChecksumList(name), lists < 2, (a.size ?? 0) <= 1_000_000 {
                lists += 1
                if let text = await fetchText(a, isPrivate: isPrivate) { map = Self.parseChecksumList(text) }
            } else if lower.hasSuffix(".sha256") || lower.hasSuffix(".sha256sum"), (a.size ?? 0) <= 4096, fetched < 20 {
                fetched += 1
                let target = String(name.dropLast(lower.hasSuffix(".sha256") ? 7 : 10))
                if byName[target] != nil, let text = await fetchText(a, isPrivate: isPrivate) {
                    let first = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                    if let h = Self.hex64(first) { map[target] = h } else { map = Self.parseChecksumList(text) }
                }
            }
            for i in files.indices where files[i].sha256 == nil { if let h = map[files[i].name] { files[i].sha256 = h; files[i].checksumSource = name } }
        }
        return files
    }

    private func fetchText(_ a: Asset, isPrivate: Bool) async -> String? {
        guard let url = URL(string: isPrivate ? a.url : a.browser_download_url) else { return nil }
        let h = isPrivate ? ["Accept": "application/octet-stream"] : [:]
        guard let r = try? await transport.get(url, headers: h, maxBytes: 1_100_000), (200..<300).contains(r.status) else { return nil }
        return String(decoding: r.body, as: UTF8.self)
    }
}

// MARK: - Platform classification and recommendation

extension ProviderPlatform {
    static var currentArch: Arch { #if arch(arm64)
        .arm64
        #else
        .x86_64
        #endif
    }

    static func classify(_ name: String) -> ProviderPlatform {
        let l = name.lowercased()
        let tokens = Set(l.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        var os = OS.unknown
        if tokens.isDisjoint(with: ["darwin", "macos", "macosx", "osx", "mac", "apple"]) == false || l.hasSuffix(".dmg") || l.hasSuffix(".pkg") { os = .mac }
        else if tokens.isDisjoint(with: ["windows", "win", "win32", "win64", "msvc"]) == false || l.hasSuffix(".exe") || l.hasSuffix(".msi") { os = .windows }
        else if tokens.isDisjoint(with: ["linux", "musl", "gnu", "freebsd"]) == false || l.hasSuffix(".deb") || l.hasSuffix(".rpm") || l.hasSuffix(".appimage") || l.hasSuffix(".snap") { os = .linux }
        else if l.hasSuffix(".apk") || l.hasSuffix(".ipa") { os = .other }
        var arch = Arch.unknown
        if l.contains("x86_64") || !tokens.isDisjoint(with: ["amd64", "x64", "intel", "x86"]) { arch = .x86_64 }
        if !tokens.isDisjoint(with: ["arm64", "aarch64", "silicon", "arm64e"]) { arch = .arm64 }
        if !tokens.isDisjoint(with: ["universal", "universal2", "fat"]) { arch = .universal }
        return ProviderPlatform(os: os, arch: arch)
    }
}

enum GitHubRecommendation {
    struct Result: Equatable { var fileID: String?; var reason: String }

    /// A file is recommended only when the names say it is for macOS and this Mac's processor (or both) and exactly one file does. Anything else gets no recommendation and a sentence saying why.
    static func pick(_ files: [ProviderFile], arch: ProviderPlatform.Arch) -> Result {
        let candidates = files.filter { $0.kind == .asset && !$0.prerelease && $0.note?.hasPrefix("Signature") != true && !GitHubProvider.isChecksumList($0.name) && !$0.name.lowercased().hasSuffix(".sha256") && $0.platform.os == .mac }
        guard !candidates.isEmpty else { return Result(fileID: nil, reason: "No file is named for macOS, so none is recommended.") }
        let exact = candidates.filter { $0.platform.arch == arch }
        let universal = candidates.filter { $0.platform.arch == .universal }
        let unknown = candidates.filter { $0.platform.arch == .unknown }
        for (tier, label) in [(exact, "this Mac's processor"), (universal, "both processors (universal)"), (unknown.count == candidates.count ? unknown : [], "macOS")] where !tier.isEmpty {
            if tier.count == 1 { return Result(fileID: tier[0].id, reason: "The only file named for \(label).") }
            return Result(fileID: nil, reason: "\(tier.count) files fit \(label); choose one.")
        }
        return Result(fileID: nil, reason: "The macOS files here are for the other processor type, so none is recommended.")
    }
}
