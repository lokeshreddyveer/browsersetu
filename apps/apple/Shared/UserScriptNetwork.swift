import Foundation

// The one place the userscript system uses the network, and only for three things the person has authorised: downloading a script they asked to install, checking a
// script they asked to update, and a request that a script was given the "contact other websites" permission for. Every address is checked here, again, whoever asked.
// It has no cache, no cookies, no credentials and no way to reach an address inside the person's own network, and it keeps nothing about what it fetched.

enum UserScriptError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text } else { return nil } }
}

enum UserScriptNet {
    /// A name or address that is inside someone's own network: never reachable by a script, however it is asked for.
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.isEmpty || h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") { return true }
        if !h.contains(".") && !h.contains(":") { return true }          // a bare name only resolves inside a network
        if h.contains(":") { return h == "::1" || h == "::" || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb") || h.hasPrefix("::ffff") }
        let nums = h.split(separator: ".").compactMap { Int($0) }
        if nums.count == 4 {
            switch (nums[0], nums[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: break
            }
        }
        return false
    }

    /// Whether a host is one the script said it needs (`@connect`). A listed name covers its subdomains; "*" is every website (but never a local one).
    static func connectAllows(_ host: String, connects: [String]) -> Bool {
        let h = host.lowercased()
        guard !isLocalHost(h) else { return false }
        return connects.contains { c in c == "*" || h == c || h.hasSuffix("." + c) }
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        let allows: (String) -> Bool
        init(_ allows: @escaping (String) -> Bool) { self.allows = allows }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if let url = request.url, url.scheme == "https", let host = url.host, allows(host) { completionHandler(request) } else { completionHandler(nil) }
        }
    }

    private static func session(_ guardRedirects: @escaping (String) -> Bool) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: RedirectGuard(guardRedirects), delegateQueue: nil)
    }

    /// Downloads a script's code when the person asked for it (Install from a link, Check for update). Only https, only to a public website, only text, no cookies,
    /// and no more than a script may be.
    static func fetchScript(_ address: String) async throws -> String {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", let host = url.host, !isLocalHost(host) else {
            throw UserScriptError.message("Only https addresses of public websites can be used.")
        }
        var request = URLRequest(url: url)
        request.setValue("text/javascript, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        let (data, response) = try await session { !isLocalHost($0) }.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UserScriptError.message("The website did not return the script.") }
        guard data.count <= UserScript.maxBytes else { throw UserScriptError.message("That script is too long.") }
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(), type.contains("html") { throw UserScriptError.message("That address is a web page, not a script.") }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else { throw UserScriptError.message("That is not a text script.") }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)
        guard head != "<" else { throw UserScriptError.message("That address is a web page, not a script.") }
        return text
    }

    /// One request for a script that was allowed to make them. The caller has already checked the permission; this checks the address again, strips what
    /// would carry the person's identity, and limits sizes.
    static func request(method: String, address: String, headers: [String: String], body: String?, timeout: TimeInterval, connects: [String]) async -> [String: Any] {
        func fail(_ text: String) -> [String: Any] { ["error": text] }
        guard let url = URL(string: address), url.scheme == "https", let host = url.host else { return fail("Only https addresses can be used.") }
        guard connectAllows(host, connects: connects) else { return fail("The script did not list \(host) as a website it connects to.") }
        let verb = method.uppercased()
        guard ["GET", "POST", "PUT", "HEAD", "DELETE", "PATCH"].contains(verb) else { return fail("That request type is not allowed.") }
        var request = URLRequest(url: url, timeoutInterval: min(max(timeout, 1), 30))
        request.httpMethod = verb
        for (name, value) in headers.prefix(20) {
            let lower = name.lowercased()
            guard !["cookie", "host", "origin", "referer", "authorization", "proxy-authorization"].contains(lower), name.count < 100, value.count < 1000 else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body, verb != "GET", verb != "HEAD" { guard body.utf8.count <= 100_000 else { return fail("The request is too large.") }; request.httpBody = Data(body.utf8) }
        do {
            let (data, response) = try await session { connectAllows($0, connects: connects) }.data(for: request)
            guard let http = response as? HTTPURLResponse else { return fail("No answer.") }
            let capped = data.prefix(1_000_000)
            return ["status": http.statusCode, "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                    "responseText": String(decoding: capped, as: UTF8.self), "finalUrl": http.url?.absoluteString ?? address]
        } catch {
            return fail((error as NSError).code == NSURLErrorTimedOut ? "The request timed out." : "The request failed.")
        }
    }
}

