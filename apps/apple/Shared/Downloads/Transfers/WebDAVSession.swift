import Foundation

// WebDAV folder browsing (RFC 4918 PROPFIND). Downloading the files is not done here: a WebDAV file is an ordinary https/http file, so it becomes an ordinary HTTP download task, with the
// same engine, naming, resume and history as any other. This file only answers "what is in this folder?" and "is this a WebDAV server?", through the same fetcher every download uses (address
// checks, redirect guard, the profile's proxy choice, no cookies).

struct WebDAVConfig: Sendable {
    /// The folder or server root, e.g. https://cloud.example/remote.php/dav/files/alice/
    var base: URL
    /// A ready Authorization header value (Basic …), or nil for an open share. Never logged.
    var authorization: String?
    var origin: DownloadRequestOrigin = .user
}

final class WebDAVSession: RemoteSession, @unchecked Sendable {
    private let config: WebDAVConfig
    private let network: DownloadNetworkSetup
    static let maxResponse = 8 << 20
    static let maxEntries = 100_000

    init(config: WebDAVConfig, network: DownloadNetworkSetup) { self.config = config; self.network = network }
    func close() {}

    static func validate(_ c: WebDAVConfig) throws {
        guard let scheme = c.base.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = c.base.host, !host.isEmpty else { throw RemoteError.invalidAddress("A WebDAV address starts with http:// or https://.") }
        guard c.base.user == nil, c.base.password == nil else { throw RemoteError.invalidAddress("Do not put a name or password in the address; enter them in the connection.") }
    }

    /// The address of a path on this server (the path is relative to the server root, "/" separated, escaped here).
    func url(for path: String) -> URL {
        var comps = URLComponents(url: config.base, resolvingAgainstBaseURL: false)!
        let encoded = path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? "" }
        comps.percentEncodedPath = "/" + encoded.joined(separator: "/")
        comps.query = nil; comps.fragment = nil
        return comps.url ?? config.base
    }

    private func headers(_ extra: [String: String] = [:]) -> [String: String] {
        var h = extra
        if let a = config.authorization { h["Authorization"] = a }
        return h
    }

    private func fetcher() throws -> MediaFetcher {
        try MediaFetcher(policy: HTTPRequestPolicy(origin: config.origin), network: network, refuseInternal: config.origin != .user)
    }

    func canonical(_ path: String) async throws -> String { "/" + path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }.joined(separator: "/") }

    // MARK: Capability

    /// Whether the server says it speaks WebDAV (an OPTIONS answer with a DAV header). Not every endpoint does, and nothing is assumed from an address alone.
    func supportsWebDAV() async throws -> Bool {
        try Self.validate(config)
        let f = try fetcher(); defer { f.invalidate() }
        let r = try await f.exchange(url(for: "/"), method: "OPTIONS", headers: headers(), limit: 1 << 16)
        if r.status == 401 { throw RemoteError.authenticationFailed }
        return r.headers["dav"] != nil
    }

    // MARK: Listing

    static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?><propfind xmlns="DAV:"><prop><resourcetype/><getcontentlength/><getlastmodified/></prop></propfind>
    """.utf8)

    func list(_ path: String, limit: Int = 100_000, onBatch: @Sendable ([RemoteEntry]) -> Void) async throws -> (count: Int, truncated: Bool) {
        try Self.validate(config)
        let target = url(for: path)
        let f = try fetcher(); defer { f.invalidate() }
        let r: MediaFetcher.ExchangeResponse
        do { r = try await f.exchange(target, method: "PROPFIND", headers: headers(["Depth": "1", "Content-Type": "application/xml; charset=utf-8"]), body: Self.propfindBody, limit: Self.maxResponse) }
        catch is CancellationError { throw CancellationError() }
        catch let e as RemoteError { throw e }
        catch { throw RemoteError.unreachable((error as? LocalizedError)?.errorDescription ?? "the request failed") }
        if let e = Self.statusError(r.status, headers: r.headers) { throw e }
        guard r.status == 207 else { throw RemoteError.unsupported("This address did not answer as a WebDAV folder.") }
        let requestPath = target.path.removingPercentEncoding ?? target.path
        let parsed = try Self.parseMultistatus(r.data, requestPath: requestPath, host: target.host)
        var entries = parsed
        var truncated = false
        if entries.count > min(limit, Self.maxEntries) { entries = Array(entries.prefix(min(limit, Self.maxEntries))); truncated = true }
        for chunk in stride(from: 0, to: entries.count, by: 500) { onBatch(Array(entries[chunk ..< min(chunk + 500, entries.count)])) }
        return (entries.count, truncated)
    }

    static func statusError(_ status: Int, headers: [String: String]) -> RemoteError? {
        switch status {
        case 200, 207: return nil
        case 401:
            if (headers["www-authenticate"] ?? "").lowercased().contains("digest") && !(headers["www-authenticate"] ?? "").lowercased().contains("basic") { return .unsupported("This server asks for Digest sign-in, which this app does not use. Use a server setting that allows Basic over https, or an app password.") }
            return .authenticationFailed
        case 403: return .permissionDenied
        case 404, 410: return .notFound
        case 405, 501: return .unsupported("This address is not a WebDAV folder.")
        case 408, 504: return .timedOut
        case 423: return .failed("The folder is locked on the server.")
        case 507: return .failed("The server reports it is out of storage.")
        case 429, 500, 502, 503: return .connectionLost("the server answered \(status)")
        default: return status >= 400 ? .failed("The server answered \(status).") : nil
        }
    }

    // MARK: Changing the server (only what the person chose; see RemoteBrowserModel)

    func remove(_ path: String, isDirectory: Bool) async throws {
        try Self.validate(config)
        let f = try fetcher(); defer { f.invalidate() }
        // DELETE on a WebDAV folder removes it with what is in it, on the server's side (RFC 4918 9.6).
        let r = try await f.exchange(url(for: path), method: "DELETE", headers: headers(), limit: 1 << 16)
        if let e = Self.statusError(r.status, headers: r.headers) { throw e }
        guard r.status == 200 || r.status == 204 else { throw RemoteError.failed(r.status == 207 ? "The server removed only part of that." : "The server answered \(r.status).") }
    }

    /// PUT with `If-None-Match: *`: the server refuses (412) if something is already there, so an existing file is never replaced.
    func upload(_ local: URL, to path: String, progress: @Sendable @escaping (Int64) -> Void) async throws {
        try Self.validate(config)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: local.path), let total = (attrs[.size] as? NSNumber)?.int64Value, (attrs[.type] as? FileAttributeType) == .typeRegular else { throw RemoteError.failed("That is not a file this app can upload.") }
        let f = try fetcher(); defer { f.invalidate() }
        let r = try await f.upload(url(for: path), file: local, headers: headers(["If-None-Match": "*", "Content-Type": "application/octet-stream"]))
        if r.status == 412 { throw RemoteError.alreadyExists }
        if let e = Self.statusError(r.status, headers: r.headers) { throw e }
        guard r.status == 200 || r.status == 201 || r.status == 204 else { throw RemoteError.failed("The server answered \(r.status).") }
        progress(total)
    }

    // MARK: Parsing (bounded, no external entities)

    static func parseMultistatus(_ data: Data, requestPath: String, host: String?) throws -> [RemoteEntry] {
        let reader = MultistatusReader(requestPath: requestPath, host: host)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse() || reader.sawMultistatus else { throw RemoteError.protocolViolation("the folder listing is not valid XML") }
        guard reader.sawMultistatus else { throw RemoteError.unsupported("This address did not answer as a WebDAV folder.") }
        return reader.entries
    }

    private final class MultistatusReader: NSObject, XMLParserDelegate {
        let requestPath: String, host: String?
        var entries: [RemoteEntry] = []
        var sawMultistatus = false
        private var stack: [String] = []
        private var text = ""
        private var href = "", isCollection = false, length: Int64?, modified: Date?, propStatusOK = true, inResponse = false
        private var elements = 0
        init(requestPath: String, host: String?) { self.requestPath = requestPath.hasSuffix("/") ? String(requestPath.dropLast()) : requestPath; self.host = host }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            elements += 1; if elements > 400_000 || stack.count > 32 { parser.abortParsing(); return }
            stack.append(name); text = ""
            if name == "multistatus" { sawMultistatus = true }
            if name == "response" { inResponse = true; href = ""; isCollection = false; length = nil; modified = nil; propStatusOK = true }
            if name == "collection", stack.contains("resourcetype") { isCollection = true }
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { if text.count < 4096 { text += s } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { stack.removeLast() }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href" where stack.dropLast().last == "response": href = value
            case "getcontentlength": length = Int64(value).flatMap { $0 >= 0 ? $0 : nil }
            case "getlastmodified": modified = Self.httpDate(value)
            case "status" where stack.dropLast().last == "propstat": if !value.contains(" 200") { propStatusOK = false }
            case "response":
                inResponse = false
                if let e = entry() { entries.append(e) }
            default: break
            }
            text = ""
        }
        private func entry() -> RemoteEntry? {
            var path = href
            if let u = URL(string: href), u.scheme != nil {
                guard u.host?.lowercased() == host?.lowercased() else { return nil }          // another server's resource is not part of this folder
                path = u.path
            } else { path = href.components(separatedBy: "?").first ?? href }
            path = path.removingPercentEncoding ?? path
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard trimmed.hasPrefix(requestPath + "/"), trimmed != requestPath else { return nil }          // the folder itself, or something outside it
            let relative = String(trimmed.dropFirst(requestPath.count + 1))
            guard !relative.contains("/"), RemoteNames.isSafeComponent(relative) else { return nil }          // direct children only, one safe name
            return RemoteEntry(name: relative, kind: isCollection ? .directory : .file, size: isCollection ? nil : length, modified: modified)
        }
        static func httpDate(_ s: String) -> Date? {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
            for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] { f.dateFormat = format; if let d = f.date(from: s) { return d } }
            return nil
        }
    }
}
