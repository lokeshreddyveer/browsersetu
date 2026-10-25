import Foundation

/// Four lookups that ask an outside service something, and only when the person presses the button for it:
///
///  * the Internet Archive, for a saved copy of a page that will not load (sends the page's address without its query or fragment),
///  * Mozilla's HTTP Observatory, for a site's security headers (sends the site's name),
///  * Frankfurter, for a currency rate from the European Central Bank (sends two currency codes),
///  * Crossref, for the exact reference of a paper (sends its DOI).
///
/// None runs by itself, none carries a cookie, a referrer or a sign-in, and an address on a private network is never sent (see `PublicAddress`).
/// This is the only file that makes these requests. Everything that can be worked out without a network (the requests, the reading of the answers, the
/// citation text) is plain functions, so it is tested without one.
enum ExternalLookup {
    enum Failure: Error, Equatable { case busy, notFound, unavailable, unreadable, notPublic }

    /// Refuses to follow a redirect to another host, so an answer can never send the request somewhere it was not meant to go.
    private final class StayOnHost: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            let from = task.originalRequest?.url?.host?.lowercased(), to = request.url?.host?.lowercased()
            completionHandler(from != nil && from == to ? request : nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "BrowserSetu (a lookup the person asked for)", "Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    static func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request, delegate: StayOnHost())
            guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
            switch http.statusCode {
            case 200..<300: guard data.count <= 2_000_000 else { throw Failure.unreadable }; return data
            case 404: throw Failure.notFound
            case 429, 503: throw Failure.busy
            default: throw Failure.unavailable
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unavailable
        }
    }
}

// MARK: What may be sent

/// Only addresses on the public internet are ever sent to an outside service. A name on a home or work network, a bare machine name and a private
/// number are not.
enum PublicAddress {
    private static let privateEndings = [".local", ".lan", ".internal", ".home", ".corp", ".intranet", ".localdomain", ".home.arpa", ".test", ".invalid", ".localhost"]

    static func isPublicHost(_ raw: String?) -> Bool {
        guard var host = raw?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else { return false }
        if host.hasPrefix("[") || host.contains(":") { return false }
        host = host.trimmingCharacters(in: .whitespaces)
        guard host.contains("."), host != "localhost" else { return false }
        if privateEndings.contains(where: { host.hasSuffix($0) || "." + host == $0 }) { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            let parts = host.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
            let (a, b) = (parts[0], parts[1])
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && b == 168 { return false }
            if a == 100 && (64...127).contains(b) { return false }
        }
        return host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    static func isPublicWeb(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return isPublicHost(url.host)
    }
}

// MARK: 1. A saved copy (Internet Archive)

enum Wayback {
    enum Outcome: Equatable { case found(URL, Date?), none, busy, failed, notPublic }

    /// The question to ask: the page's address without any query, fragment or sign-in details, which can hold tokens and search words.
    static func lookupURL(for page: URL) -> URL? {
        guard PublicAddress.isPublicWeb(page), var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        guard let clean = parts.url else { return nil }
        var ask = URLComponents(string: "https://archive.org/wayback/available")
        ask?.queryItems = [URLQueryItem(name: "url", value: clean.absoluteString)]
        return ask?.url
    }

    /// The closest saved copy in an answer, accepted only if it is a page on web.archive.org.
    static func snapshot(from data: Data) -> (url: URL, date: Date?)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let closest = (root["archived_snapshots"] as? [String: Any])?["closest"] as? [String: Any],
              (closest["available"] as? Bool) == true, var text = closest["url"] as? String else { return nil }
        if text.hasPrefix("http://") { text = "https://" + text.dropFirst(7) }
        guard let url = URL(string: text), url.scheme == "https", url.host?.lowercased() == "web.archive.org" else { return nil }
        return (url, (closest["timestamp"] as? String).flatMap(date(fromTimestamp:)))
    }

    static func date(fromTimestamp stamp: String) -> Date? {
        guard stamp.count == 14, stamp.allSatisfy(\.isNumber) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: stamp)
    }

    static func lookup(_ page: URL) async -> Outcome {
        guard let ask = lookupURL(for: page) else { return .notPublic }
        do {
            let data = try await ExternalLookup.data(for: URLRequest(url: ask))
            if let found = snapshot(from: data) { return .found(found.url, found.date) }
            return .none
        } catch ExternalLookup.Failure.busy { return .busy }
        catch { return .failed }
    }
}

// MARK: 2. A site's security headers (Mozilla HTTP Observatory)

enum SiteScan {
    struct Result: Equatable {
        var grade: String
        var score: Int
        var passed: Int
        var failed: Int
        var total: Int
        var details: URL?
    }
    enum Outcome: Equatable { case done(Result), busy, failed(String), notPublic }

    /// Only the site's name is sent.
    static func request(host raw: String?) -> URLRequest? {
        guard PublicAddress.isPublicHost(raw), let host = raw?.lowercased() else { return nil }
        var parts = URLComponents(string: "https://observatory-api.mdn.mozilla.net/api/v2/scan")
        parts?.queryItems = [URLQueryItem(name: "host", value: host)]
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        return request
    }

    static func parse(_ data: Data) -> Result? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["error"] is NSNull || root["error"] == nil,
              let grade = root["grade"] as? String, !grade.isEmpty, grade.count <= 3, let score = root["score"] as? Int else { return nil }
        let details = (root["details_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == "developer.mozilla.org" ? $0 : nil }
        return Result(grade: grade, score: score, passed: root["tests_passed"] as? Int ?? 0, failed: root["tests_failed"] as? Int ?? 0,
                      total: root["tests_quantity"] as? Int ?? 0, details: details)
    }

    static func errorMessage(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let text = root["message"] as? String, !text.isEmpty { return String(text.prefix(140)) }
        if let text = root["error"] as? String, !text.isEmpty { return String(text.prefix(140)) }
        return nil
    }

    static func scan(host: String?) async -> Outcome {
        guard let request = request(host: host) else { return .notPublic }
        do {
            let data = try await ExternalLookup.data(for: request)
            if let result = parse(data) { return .done(result) }
            return .failed(errorMessage(data) ?? "Mozilla could not scan this site.")
        } catch ExternalLookup.Failure.busy { return .busy }
        catch { return .failed("Mozilla could not be reached.") }
    }
}

// MARK: 3. Currency (Frankfurter, European Central Bank rates)

enum Currency {
    struct Amount: Equatable, Identifiable {
        var value: Double
        var code: String
        var source: String
        var id: String { source }
    }

    /// The currencies the European Central Bank publishes a rate for.
    static let supported: Set<String> = ["AUD", "BGN", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF", "IDR", "ILS", "INR", "ISK", "JPY",
                                         "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB", "TRY", "USD", "ZAR"]

    private static let symbols: [(String, String)] = [("R$", "BRL"), ("A$", "AUD"), ("C$", "CAD"), ("NZ$", "NZD"), ("HK$", "HKD"), ("S$", "SGD"),
                                                       ("US$", "USD"), ("€", "EUR"), ("£", "GBP"), ("₹", "INR"), ("₩", "KRW"), ("₺", "TRY"), ("¥", "JPY"),
                                                       ("zł", "PLN"), ("Kč", "CZK"), ("₪", "ILS"), ("฿", "THB"), ("₱", "PHP"), ("$", "USD")]

    private static let number = #"(\d{1,3}(?:[,\x{202F}\x{00A0} ]\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)"#
    /// A number must not start in the middle of another one ("in 2024 250 EUR" is not 24,250).
    private static let numberAfterGap = #"(?<![\d.,])"# + number
    private static let codes = supported.sorted().joined(separator: "|")
    private static let beforePattern = NSRegularExpression.fixed(#"(R\$|A\$|C\$|NZ\$|HK\$|S\$|US\$|€|£|₹|₩|₺|¥|₪|฿|₱|\$)\s?"# + number)
    private static let afterCode = NSRegularExpression.fixed(numberAfterGap + #"\s?("# + codes + #")\b"#)
    private static let afterSymbol = NSRegularExpression.fixed(numberAfterGap + #"\s?(€|zł|Kč)"#)
    private static let beforeCode = NSRegularExpression.fixed(#"\b("# + codes + #")\s?"# + number)

    private static func value(_ text: String) -> Double? {
        Double(text.filter { $0.isNumber || $0 == "." })
    }

    /// Amounts of money written in the text: "$250", "€40", "₹1,200.50", "USD 250", "250 EUR". Up to five, without repeats.
    static func amounts(in text: String) -> [Amount] {
        var found: [Amount] = []
        func slice(_ match: NSTextCheckingResult, _ group: Int) -> String? { Range(match.range(at: group), in: text).map { String(text[$0]) } }
        let whole = NSRange(text.startIndex..., in: text)
        for match in beforePattern.matches(in: text, range: whole) {
            guard let symbol = slice(match, 1), let digits = slice(match, 2), let value = value(digits), let code = symbols.first(where: { $0.0 == symbol })?.1 else { continue }
            found.append(Amount(value: value, code: code, source: "\(symbol)\(digits)"))
        }
        for match in afterSymbol.matches(in: text, range: whole) {
            guard let digits = slice(match, 1), let symbol = slice(match, 2), let value = value(digits), let code = symbols.first(where: { $0.0 == symbol })?.1 else { continue }
            found.append(Amount(value: value, code: code, source: "\(digits) \(symbol)"))
        }
        for match in afterCode.matches(in: text, range: whole) {
            guard let digits = slice(match, 1), let code = slice(match, 2), let value = value(digits) else { continue }
            found.append(Amount(value: value, code: code, source: "\(digits) \(code)"))
        }
        for match in beforeCode.matches(in: text, range: whole) {
            guard let code = slice(match, 1), let digits = slice(match, 2), let value = value(digits) else { continue }
            found.append(Amount(value: value, code: code, source: "\(code) \(digits)"))
        }
        var seen = Set<String>()
        return Array(found.filter { $0.value > 0 && supported.contains($0.code) && seen.insert($0.source).inserted }.prefix(5))
    }

    /// Where to convert to: the person's own currency, then dollars and euros, never the currency of the amount itself.
    static func targets(for amount: Amount, locale: Locale = .current) -> [String] {
        var list: [String] = []
        for code in [locale.currency?.identifier, "USD", "EUR"].compactMap({ $0 }) where supported.contains(code) && code != amount.code && !list.contains(code) { list.append(code) }
        return Array(list.prefix(3))
    }

    /// Only the two codes are sent.
    static func request(from code: String, to targets: [String]) -> URLRequest? {
        guard supported.contains(code), !targets.isEmpty, targets.allSatisfy(supported.contains) else { return nil }
        var parts = URLComponents(string: "https://api.frankfurter.dev/v1/latest")
        parts?.queryItems = [URLQueryItem(name: "base", value: code), URLQueryItem(name: "symbols", value: targets.joined(separator: ","))]
        return parts?.url.map { URLRequest(url: $0) }
    }

    static func rates(from data: Data) -> (date: String, rates: [String: Double])? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let rates = root["rates"] as? [String: Any], !rates.isEmpty else { return nil }
        let numeric = rates.compactMapValues { ($0 as? NSNumber)?.doubleValue }.filter { supported.contains($0.key) && $0.value > 0 }
        return numeric.isEmpty ? nil : ((root["date"] as? String) ?? "", numeric)
    }

    static func format(_ value: Double, code: String, locale: Locale = .current) -> String {
        value.formatted(.currency(code: code).locale(locale).precision(.fractionLength(code == "JPY" || code == "KRW" || code == "IDR" || code == "HUF" ? 0 : 2)))
    }

    /// "€40" turned into the person's currency and the others, e.g. ["₹3,797.60", "$44.77"], and the day the rate is from.
    static func convert(_ amount: Amount) async -> (lines: [String], date: String)? {
        let targets = targets(for: amount)
        guard let request = request(from: amount.code, to: targets), let data = try? await ExternalLookup.data(for: request), let answer = rates(from: data) else { return nil }
        let lines = targets.compactMap { code in answer.rates[code].map { format(amount.value * $0, code: code) } }
        return lines.isEmpty ? nil : (lines, answer.date)
    }
}

// MARK: 4. A paper's exact reference (Crossref)

enum DOI {
    private static let pattern = NSRegularExpression.fixed(#"10\.\d{4,9}/[^\s"'<>\]\)&?#]+"#)

    /// The first DOI written in any of the texts, tidied: no trailing punctuation, no address in front of it.
    static func find(in texts: [String]) -> String? {
        for text in texts {
            let decoded = text.removingPercentEncoding ?? text
            guard let match = pattern.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)), let range = Range(match.range, in: decoded) else { continue }
            var doi = String(decoded[range])
            while let last = doi.last, ".,;:)]}>\"'".contains(last) { doi.removeLast() }
            if doi.count >= 8, doi.contains("/") { return doi }
        }
        return nil
    }
}

enum Crossref {
    struct Author: Equatable { var given: String; var family: String; var organisation: String }
    struct Work: Equatable {
        var title: String
        var authors: [Author]
        var container: String
        var year: String
        var volume: String
        var issue: String
        var pages: String
        var doi: String
    }

    static func request(doi: String) -> URLRequest? {
        guard DOI.find(in: [doi]) == doi else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: allowed), let url = URL(string: "https://api.crossref.org/works/\(encoded)") else { return nil }
        return URLRequest(url: url)
    }

    /// Titles in Crossref's answers can carry markup such as <i>…</i> and a few HTML entities.
    static func plain(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] { out = out.replacingOccurrences(of: entity, with: character) }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func work(from data: Data) -> Work? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let message = root["message"] as? [String: Any],
              let title = (message["title"] as? [String])?.first.map(plain), !title.isEmpty, let doi = message["DOI"] as? String else { return nil }
        let authors = ((message["author"] as? [[String: Any]]) ?? []).prefix(60).map {
            Author(given: plain($0["given"] as? String ?? ""), family: plain($0["family"] as? String ?? ""), organisation: plain($0["name"] as? String ?? ""))
        }.filter { !$0.family.isEmpty || !$0.organisation.isEmpty }
        func year(_ key: String) -> String? {
            guard let parts = (message[key] as? [String: Any])?["date-parts"] as? [[Any]], let first = parts.first?.first as? Int else { return nil }
            return String(first)
        }
        return Work(title: title, authors: authors, container: ((message["container-title"] as? [String])?.first).map(plain) ?? "",
                    year: year("issued") ?? year("published-print") ?? year("published-online") ?? year("created") ?? "n.d.",
                    volume: message["volume"] as? String ?? "", issue: message["issue"] as? String ?? "", pages: message["page"] as? String ?? "", doi: doi)
    }

    static func lookup(doi: String) async -> Work? {
        guard let request = request(doi: doi), let data = try? await ExternalLookup.data(for: request) else { return nil }
        return work(from: data)
    }

    // MARK: The text of a reference

    private static func initials(_ given: String) -> String {
        given.split(separator: " ").map { word in
            word.split(separator: "-").compactMap { $0.first.map { "\($0.uppercased())." } }.joined(separator: "-")
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func stop(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".?!".contains(last) ? text : text + "."
    }

    static func format(_ work: Work, style: PageCitation.Style) -> String {
        let link = "https://doi.org/\(work.doi)"
        switch style {
        case .apa:
            let names = work.authors.map { $0.organisation.isEmpty ? [$0.family, initials($0.given)].filter { !$0.isEmpty }.joined(separator: ", ") : $0.organisation }
            let who: String
            switch names.count {
            case 0: who = ""
            case 1: who = names[0]
            case 2...20: who = names.dropLast().joined(separator: ", ") + ", & " + names[names.count - 1]
            default: who = names.prefix(19).joined(separator: ", ") + ", . . . " + names[names.count - 1]
            }
            var source = work.container
            if !work.volume.isEmpty { source += (source.isEmpty ? "" : ", ") + work.volume + (work.issue.isEmpty ? "" : "(\(work.issue))") }
            if !work.pages.isEmpty { source += (source.isEmpty ? "" : ", ") + work.pages }
            return [who.isEmpty ? nil : stop(who), "(\(work.year)).", stop(work.title), source.isEmpty ? nil : stop(source), link].compactMap { $0 }.joined(separator: " ")
        case .mla:
            func full(_ a: Author) -> String { a.organisation.isEmpty ? [a.family, a.given].filter { !$0.isEmpty }.joined(separator: ", ") : a.organisation }
            let who: String
            switch work.authors.count {
            case 0: who = ""
            case 1: who = full(work.authors[0])
            case 2: who = full(work.authors[0]) + ", and " + [work.authors[1].given, work.authors[1].family].filter { !$0.isEmpty }.joined(separator: " ")
            default: who = full(work.authors[0]) + ", et al"
            }
            var pieces: [String] = []
            if !work.container.isEmpty { pieces.append(work.container) }
            if !work.volume.isEmpty { pieces.append("vol. \(work.volume)") }
            if !work.issue.isEmpty { pieces.append("no. \(work.issue)") }
            pieces.append(work.year)
            if !work.pages.isEmpty { pieces.append((work.pages.contains("-") || work.pages.contains("–") ? "pp. " : "p. ") + work.pages) }
            pieces.append(link)
            return [who.isEmpty ? nil : stop(who), "“\(stop(work.title))”", pieces.joined(separator: ", ") + "."].compactMap { $0 }.joined(separator: " ")
        case .plain:
            let who = work.authors.prefix(3).map { $0.organisation.isEmpty ? [$0.given, $0.family].filter { !$0.isEmpty }.joined(separator: " ") : $0.organisation }.joined(separator: ", ")
                + (work.authors.count > 3 ? " et al." : "")
            return [who, work.title, [work.container, work.year].filter { !$0.isEmpty }.joined(separator: ", "), link].filter { !$0.isEmpty }.joined(separator: " — ")
        }
    }
}
