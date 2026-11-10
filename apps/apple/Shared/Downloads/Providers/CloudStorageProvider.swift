import Foundation

/// Cloud object storage that can be read over plain HTTPS without an SDK: S3 and S3-compatible services (including Google Cloud Storage's XML API, MinIO, R2, Wasabi…) whose bucket allows listing,
/// Azure Blob containers opened with a SAS address, and any single signed address (presigned S3/GCS, Azure SAS, CloudFront). Signed addresses are secrets: they are never logged or shown in full,
/// an expired one is reported as expired (a new one must come from its owner, it is never retried), and no key is ever asked for here.
enum SignedURL {
    static func isSigned(_ url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let names = Set(items.map { $0.name.lowercased() })
        return names.contains("x-amz-signature") || names.contains("x-goog-signature") || (names.contains("sig") && names.contains("sv")) || (names.contains("signature") && names.contains("expires")) || names.contains("x-amz-security-token")
    }

    /// When the address stops working, if the address itself says.
    static func expiry(_ url: URL) -> Date? {
        let items = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { i in i.value.map { (i.name.lowercased(), $0) } }, uniquingKeysWith: { a, _ in a })
        func compact(_ s: String) -> Date? {          // 20261109T101500Z
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f.date(from: s)
        }
        for (dateKey, lenKey) in [("x-amz-date", "x-amz-expires"), ("x-goog-date", "x-goog-expires")] {
            if let d = items[dateKey].flatMap(compact), let n = items[lenKey].flatMap(TimeInterval.init) { return d.addingTimeInterval(n) }
        }
        if let se = items["se"] {                       // Azure: ISO 8601
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: se) { return d }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; if let d = f.date(from: se) { return d }
        }
        if let e = items["expires"].flatMap(TimeInterval.init), items["signature"] != nil || items["x-goog-signature"] != nil { return Date(timeIntervalSince1970: e) }
        return nil
    }

    static func isExpired(_ url: URL, now: Date = Date()) -> Bool { expiry(url).map { $0 <= now } ?? false }
    static func redacted(_ url: URL) -> String { DownloadURLRedactor.redact(url) }
}

struct CloudStorageProvider: Sendable {
    enum Flavor: Equatable { case s3Virtual(bucket: String), s3Path(bucket: String), azure(container: String) }
    struct Target: Equatable { var flavor: Flavor; var base: URL; var prefix: String; var sas: [URLQueryItem] }

    let transport: ProviderTransport
    static let maxFiles = 50_000, maxPages = 100

    static func parse(_ url: URL) -> Target? {
        guard url.scheme == "https" || url.scheme == "http", let host = url.host?.lowercased() else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let parts = comps.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        var base = URLComponents(); base.scheme = url.scheme; base.host = url.host; base.port = url.port
        if host.hasSuffix(".blob.core.windows.net") {
            guard let container = parts.first else { return nil }
            let sas = (comps.queryItems ?? []).filter { !["restype", "comp", "prefix", "marker", "delimiter", "maxresults"].contains($0.name.lowercased()) }
            base.percentEncodedPath = "/" + enc(container)
            return Target(flavor: .azure(container: container), base: base.url!, prefix: parts.dropFirst().joined(separator: "/"), sas: sas)
        }
        if host.range(of: "^[a-z0-9][a-z0-9.-]*\\.s3[.-]", options: .regularExpression) != nil, host.contains("amazonaws.com") || host.contains(".s3.") {
            let bucket = String(host.prefix(upTo: host.range(of: ".s3")!.lowerBound))
            base.percentEncodedPath = ""
            return Target(flavor: .s3Virtual(bucket: bucket), base: base.url!, prefix: parts.joined(separator: "/"), sas: [])
        }
        guard let bucket = parts.first, !bucket.isEmpty else { return nil }
        base.percentEncodedPath = "/" + enc(bucket)
        return Target(flavor: .s3Path(bucket: bucket), base: base.url!, prefix: parts.dropFirst().joined(separator: "/"), sas: [])
    }

    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s }
    static func encKey(_ s: String) -> String { s.split(separator: "/", omittingEmptySubsequences: false).map { enc(String($0)) }.joined(separator: "/") }

    /// The address of one object: the signed query of a SAS address is carried (it is the credential), nothing else is added.
    func objectURL(_ t: Target, key: String) -> URL {
        var c = URLComponents(url: t.base, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = (t.base.path.isEmpty || t.base.path == "/" ? "" : c.percentEncodedPath) + "/" + Self.encKey(key)
        if !t.sas.isEmpty { c.queryItems = t.sas }
        return c.url!
    }

    func listing(_ t: Target) async throws -> ProviderListing {
        var files: [ProviderFile] = []
        var token: String?
        var truncated = false
        var pages = 0
        let parser = CloudListingParser()
        let name: String
        switch t.flavor { case .s3Virtual(let b), .s3Path(let b): name = b; case .azure(let c): name = c }
        repeat {
            pages += 1
            var c = URLComponents(url: t.flavor.isAzure ? t.base : t.base, resolvingAgainstBaseURL: false)!
            var items: [URLQueryItem] = t.sas
            if case .azure = t.flavor {
                items += [URLQueryItem(name: "restype", value: "container"), URLQueryItem(name: "comp", value: "list")]
                if !t.prefix.isEmpty { items.append(URLQueryItem(name: "prefix", value: t.prefix)) }
                if let token { items.append(URLQueryItem(name: "marker", value: token)) }
            } else {
                c.percentEncodedPath = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
                items += [URLQueryItem(name: "list-type", value: "2")]
                if !t.prefix.isEmpty { items.append(URLQueryItem(name: "prefix", value: t.prefix)) }
                if let token { items.append(URLQueryItem(name: "continuation-token", value: token)) }
            }
            c.percentEncodedQuery = items.map { Self.enc($0.name) + "=" + Self.enc($0.value ?? "") }.joined(separator: "&")
            let url = c.url!
            let r = try await transport.get(url, headers: ["Accept": "application/xml"], maxBytes: 16_000_000)
            if r.status == 403, SignedURL.isExpired(url) || (!t.sas.isEmpty && SignedURL.isExpired(t.base.appendingSAS(t.sas))) { throw ProviderError.expiredLink }
            if r.status == 403 { throw ProviderError.forbidden("this bucket does not allow listing without a key") }
            try ProviderStatus.check(r, host: url.host ?? "storage", hadToken: false)
            let page = try parser.parse(r.body, azure: t.flavor.isAzure)
            for o in page.objects {
                if o.key.hasSuffix("/") { continue }          // folder placeholder
                let rel = t.prefix.isEmpty ? o.key : (o.key.hasPrefix(t.prefix.hasSuffix("/") ? t.prefix : t.prefix + "/") ? String(o.key.dropFirst(t.prefix.hasSuffix("/") ? t.prefix.count : t.prefix.count + 1)) : (o.key == t.prefix ? (o.key as NSString).lastPathComponent : o.key))
                let comps = rel.split(separator: "/").map(String.init)
                guard let last = comps.last, !comps.contains(where: { $0 == ".." || $0 == "." }) else { continue }
                let folders = comps.dropLast().compactMap { PackageFolderTemplate.clean($0) }
                guard folders.count == comps.count - 1 else { continue }
                files.append(ProviderFile(id: "object:\(o.key)", name: ProviderNames.safe(last), folders: folders, size: ProviderNames.size(o.size), url: objectURL(t, key: o.key), kind: .object, group: name))
                if files.count >= Self.maxFiles { truncated = true; break }
            }
            token = page.next
        } while token != nil && !truncated && pages < Self.maxPages
        if token != nil { truncated = true }
        var notices: [String] = []
        if truncated { notices.append("Only the first \(files.count) objects are listed. Open a sub-folder address to see the rest.") }
        if t.flavor.isAzure { notices.append("The shared-access address is kept only in memory here; the downloads carry it until it expires.") }
        return ProviderListing(title: name + (t.prefix.isEmpty ? "" : "/" + t.prefix), source: "cloud:\(t.base.host ?? ""):\(name)/\(t.prefix)", files: files, revision: nil, notices: notices, truncated: truncated)
    }
}

extension CloudStorageProvider.Flavor { var isAzure: Bool { if case .azure = self { true } else { false } } }
private extension URL {
    func appendingSAS(_ items: [URLQueryItem]) -> URL { var c = URLComponents(url: self, resolvingAgainstBaseURL: false)!; c.queryItems = items; return c.url! }
}

/// Reads ListObjectsV2 (S3, GCS, compatible) and Azure "List Blobs" answers. Foreign keys are only ever names: nothing here is a path until it has been checked.
final class CloudListingParser: NSObject, XMLParserDelegate {
    struct Object { var key: String; var size: Int64? }
    struct Page { var objects: [Object]; var next: String? }
    private var objects: [Object] = []
    private var next: String?, truncated = false
    private var stack: [String] = [], text = ""
    private var key = "", size: Int64?
    private var azure = false

    func parse(_ data: Data, azure: Bool) throws -> Page {
        objects = []; next = nil; truncated = false; stack = []; text = ""; self.azure = azure
        let p = XMLParser(data: data); p.delegate = self
        p.shouldResolveExternalEntities = false
        guard p.parse() else { throw ProviderError.badResponse("not a listing") }
        return Page(objects: objects, next: (azure || truncated) ? (next?.isEmpty == false ? next : nil) : nil)
    }
    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(e); text = ""
        if e == "Contents" || e == "Blob" { key = ""; size = nil }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        defer { _ = stack.popLast(); text = "" }
        let parent = stack.dropLast().last
        switch e {
        case "Key" where parent == "Contents": key = text
        case "Name" where parent == "Blob": key = text
        case "Size" where parent == "Contents": size = Int64(text)
        case "Content-Length" where parent == "Properties": size = Int64(text)
        case "IsTruncated": truncated = text.lowercased() == "true"
        case "NextContinuationToken": next = text
        case "NextMarker": next = text
        case "Contents", "Blob": if !key.isEmpty { objects.append(Object(key: key, size: size)) }
        default: break
        }
    }
}
