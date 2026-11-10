import Foundation

/// Hugging Face models and datasets. Files are listed from the repository tree at ONE commit (so a "main" that moves while the person chooses cannot change what they get), downloaded from
/// `resolve/<commit>/<path>` through the ordinary HTTP engine (which follows the service's redirect to its storage hosts and drops the token there), and checked against the LFS object id
/// (a SHA-256 of the real content) when there is one. A file that is only a Git LFS pointer is never accepted as the file.
struct HuggingFaceProvider: Sendable {
    enum Kind: String, Sendable { case model, dataset
        var apiSegment: String { self == .model ? "models" : "datasets" }
        var urlPrefix: String { self == .model ? "" : "datasets/" }
    }
    struct Target: Equatable {
        var kind: Kind
        var repo: String
        var revision: String            // as written ("main", a tag, a commit, "refs/pr/1")
        var path: String                // a folder or one file inside the repository, "" for all
        var isFile: Bool
    }

    var endpoint = URL(string: "https://huggingface.co")!
    let transport: ProviderTransport
    var hasToken: @Sendable (URL) -> Bool = { _ in false }
    static let maxFiles = 50_000
    static let maxPages = 200
    static let reserved: Set<String> = ["models", "datasets", "spaces", "docs", "blog", "papers", "settings", "api", "login", "join", "pricing", "organizations", "collections", "tasks", "chat", "new", "huggingface"]

    // MARK: Addresses

    static func parse(_ url: URL, host: String = "huggingface.co") -> Target? {
        guard url.scheme == "https" || url.scheme == "http", url.host?.lowercased() == host else { return nil }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        var parts = raw.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        var kind = Kind.model
        if parts.first == "datasets" { kind = .dataset; parts.removeFirst() } else if let f = parts.first, ["spaces", "api"].contains(f) || reserved.contains(f) && f != "huggingface" { return nil }
        guard !parts.isEmpty else { return nil }
        var repo: String
        if parts.count >= 2, validName(parts[0]), validName(parts[1]), !["tree", "blob", "resolve"].contains(parts[1]) { repo = parts[0] + "/" + parts[1]; parts.removeFirst(2) }
        else if kind == .dataset, validName(parts[0]) { repo = parts[0]; parts.removeFirst() }
        else { return nil }
        guard !parts.isEmpty else { return Target(kind: kind, repo: repo, revision: "main", path: "", isFile: false) }
        let mode = parts[0]
        guard ["tree", "blob", "resolve"].contains(mode), parts.count >= 2 else { return nil }
        let rev = parts[1], path = parts.dropFirst(2).joined(separator: "/")
        if path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) { return nil }
        return Target(kind: kind, repo: repo, revision: rev, path: path, isFile: mode != "tree" && !path.isEmpty)
    }
    static func validName(_ s: String) -> Bool { !s.isEmpty && s.count <= 96 && s.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil }

    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s }
    private static func encPath(_ s: String) -> String { s.split(separator: "/", omittingEmptySubsequences: false).map { enc(String($0)) }.joined(separator: "/") }

    private func url(_ percentEncodedPath: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = percentEncodedPath
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    struct RepoInfo: Decodable { var sha: String?; var `private`: Bool?; var gated: GatedValue? }
    /// "gated" is false, or the strings "auto" / "manual".
    enum GatedValue: Decodable, Equatable { case no, yes
        init(from d: Decoder) throws { let c = try d.singleValueContainer(); if let b = try? c.decode(Bool.self) { self = b ? .yes : .no } else if (try? c.decode(String.self)) != nil { self = .yes } else { self = .no } }
    }
    struct Entry: Decodable { struct LFS: Decodable { var oid: String?; var size: Int64? }; var type: String; var path: String; var size: Int64?; var lfs: LFS? }

    // MARK: Listing

    func listing(_ t: Target) async throws -> ProviderListing {
        let headers = ["Accept": "application/json"]
        let infoURL = url("/api/\(t.kind.apiSegment)/\(Self.encPath(t.repo))/revision/\(Self.enc(t.revision))")
        let r = try await transport.get(infoURL, headers: headers, maxBytes: 4_000_000)
        try ProviderStatus.check(r, host: infoURL.host ?? "huggingface.co", hadToken: hasToken(infoURL))
        guard let info = try? JSONDecoder().decode(RepoInfo.self, from: r.body), let commit = info.sha, commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw ProviderError.badResponse("no commit") }
        let isPrivate = info.private ?? false, gated = info.gated == .yes

        var files: [ProviderFile] = []
        var truncated = false
        var next: URL? = url("/api/\(t.kind.apiSegment)/\(Self.encPath(t.repo))/tree/\(commit)" + (t.path.isEmpty ? "" : "/" + Self.encPath(t.path)),
                             query: [URLQueryItem(name: "recursive", value: t.isFile ? "false" : "true")])
        var pages = 0, refusedNext = false
        while let page = next {
            pages += 1
            let resp = try await transport.get(page, headers: headers, maxBytes: 32_000_000)
            try ProviderStatus.check(resp, host: page.host ?? "huggingface.co", hadToken: hasToken(page))
            guard let entries = try? JSONDecoder().decode([Entry].self, from: resp.body) else { throw ProviderError.badResponse("unexpected tree") }
            for e in entries where e.type == "file" {
                if t.isFile, e.path != t.path { continue }
                guard let f = makeFile(e, t, commit: commit, isPrivate: isPrivate, gated: gated) else { continue }
                files.append(f)
                if files.count >= Self.maxFiles { truncated = true; break }
            }
            if truncated || pages >= Self.maxPages { truncated = truncated || pages >= Self.maxPages; break }
            next = Self.nextLink(resp.headers["link"], base: page, sameOriginAs: endpoint)
            if next == nil, let link = resp.headers["link"], link.contains("rel=\"next\"") { truncated = true; refusedNext = true }
        }
        if t.isFile && files.isEmpty { throw ProviderError.notFound }
        var notices: [String] = []
        if gated { notices.append("This \(t.kind.rawValue) is gated. Downloads need an access token for an account that has been granted access on the website; Browser Setu does not get around the gate.") }
        if truncated { notices.append(refusedNext ? "The list may be incomplete: the service pointed to a next page this feature will not follow. Choose a sub-folder to see more." : "Only the first \(files.count) files are listed. Choose a sub-folder to see the rest.") }
        let title = "\(t.repo) — \(t.revision == commit ? String(commit.prefix(8)) : t.revision) (\(String(commit.prefix(8))))"
        return ProviderListing(title: title, source: "hf:\(t.kind.rawValue):\(t.repo)@\(commit)", files: files, revision: commit, notices: notices, truncated: truncated)
    }

    func makeFile(_ e: Entry, _ t: Target, commit: String, isPrivate: Bool, gated: Bool) -> ProviderFile? {
        guard !e.path.hasPrefix("/"), !e.path.hasSuffix("/"), !e.path.contains("//") else { return nil }
        let comps = e.path.split(separator: "/").map(String.init)
        guard !comps.isEmpty, !comps.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }), let last = comps.last else { return nil }
        let name = ProviderNames.safe(last)
        let folders = comps.dropLast().compactMap { PackageFolderTemplate.clean($0) }
        guard folders.count == comps.count - 1 else { return nil }
        let resolve = url("/\(t.kind.urlPrefix)\(Self.encPath(t.repo))/resolve/\(commit)/\(Self.encPath(e.path))")
        var f = ProviderFile(id: "file:\(e.path)", name: name, folders: folders, size: ProviderNames.size(e.lfs?.size ?? e.size), url: resolve, kind: e.lfs == nil ? .repoFile : .lfsFile, needsAccount: isPrivate || gated, group: String(commit.prefix(8)))
        if let oid = e.lfs?.oid, let hex = GitHubProvider.hex64(oid) { f.sha256 = hex; f.checksumSource = "LFS object id" }
        f.platform = .unknown
        return f
    }

    /// `Link: <https://…?cursor=…>; rel="next"` — followed only when it stays on the service's own origin (a pagination link must never lead the token somewhere else).
    static func nextLink(_ header: String?, base: URL, sameOriginAs endpoint: URL) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let bits = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard bits.count >= 2, bits.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "").lowercased() == "rel=\"next\"" }), bits[0].hasPrefix("<"), bits[0].hasSuffix(">") else { continue }
            guard let u = URL(string: String(bits[0].dropFirst().dropLast()), relativeTo: base)?.absoluteURL, ProviderOrigin(u) == ProviderOrigin(endpoint) else { return nil }
            return u
        }
        return nil
    }
}

/// File-format grouping for the filter chips ("GGUF", "SafeTensors", "Config & tokenizer"…).
enum ProviderFormats {
    static func group(_ name: String) -> String {
        let l = name.lowercased()
        let ext = (l as NSString).pathExtension
        switch ext {
        case "gguf": return "GGUF"
        case "safetensors": return "SafeTensors"
        case "bin", "pt", "pth", "ckpt": return "PyTorch"
        case "onnx": return "ONNX"
        case "h5", "keras", "tflite", "mlmodel", "mlpackage": return "Other model"
        case "parquet", "arrow", "csv", "tsv", "jsonl", "ndjson", "json" where l.contains("data") || l.contains("train") || l.contains("test") || l.contains("val"): return "Data"
        case "json", "txt", "model", "vocab", "md", "yaml", "yml", "py", "tiktoken", "jinja": return "Config & docs"
        case "zip", "tar", "gz", "tgz", "7z": return "Archives"
        default: return "Other"
        }
    }
}
