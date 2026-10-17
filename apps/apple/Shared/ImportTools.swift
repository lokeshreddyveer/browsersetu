import Foundation
import Security

// MARK: - CSV

/// A small, strict reader for the CSV files other browsers write (RFC 4180: quoted fields, doubled quotes, line breaks inside quotes).
enum CSV {
    static let maxRows = 50_000

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", inQuotes = false
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }           // a byte-order mark from Excel and Chrome
        var i = 0
        func endField() { row.append(field); field = "" }
        func endRow() { endField(); if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }; row = [] }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" { if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { inQuotes = false } }
                else { field.unicodeScalars.append(c) }
            } else {
                switch c {
                case "\"": if field.isEmpty { inQuotes = true } else { field.unicodeScalars.append(c) }
                case ",": endField()
                case "\r": if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }; endRow()
                case "\n": endRow()
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
            if rows.count > maxRows { break }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// One field written so a spreadsheet or another browser reads it back unchanged. A field that begins like a formula is made harmless.
    static func field(_ value: String) -> String {
        var v = value
        if let first = v.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { v = "'" + v }
        guard v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || v.hasPrefix(" ") || v.hasSuffix(" ") else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - Passwords

enum PasswordImport {
    struct Result: Equatable {
        var logins: [WebLogin] = []
        var skippedInsecure = 0       // plain-http sites: never kept
        var skippedIncomplete = 0
        var skippedDuplicate = 0
    }

    /// Reads the passwords file from Chrome, Edge, Brave, Firefox or Apple's Passwords app. Columns are found by their names, in any order.
    static func parse(csv text: String, existing: [WebLogin] = []) -> Result {
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return Result() }
        func column(_ names: [String]) -> Int? { names.compactMap { header.firstIndex(of: $0) }.first }
        guard let urlColumn = column(["url", "login_uri", "website", "origin", "web site", "hostname"]),
              let userColumn = column(["username", "login_username", "user", "login", "email"]),
              let passColumn = column(["password", "login_password"]) else { return Result() }
        var result = Result()
        var seen = Set(existing.map(\.id))
        for row in rows.dropFirst() {
            func cell(_ i: Int) -> String { i < row.count ? row[i].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
            var address = cell(urlColumn)
            if !address.contains("://"), address.contains(".") { address = "https://" + address }     // Firefox and Apple write bare host names
            let user = cell(userColumn), password = row.indices.contains(passColumn) ? row[passColumn] : ""
            guard !user.isEmpty, !password.isEmpty, user.count <= LoginRules.maxUser, password.count <= LoginRules.maxPassword else { result.skippedIncomplete += 1; continue }
            guard let origin = WebLoginOrigin.normalized(address) else {
                if address.lowercased().hasPrefix("http://") { result.skippedInsecure += 1 } else { result.skippedIncomplete += 1 }
                continue
            }
            let login = WebLogin(origin: origin, user: user, password: password)
            if seen.contains(login.id) { result.skippedDuplicate += 1; continue }
            seen.insert(login.id)
            result.logins.append(login)
        }
        return result
    }

    /// The file other browsers can read (Chrome's column layout). It holds every password in plain text: the caller asks for Touch ID first and warns about it.
    static func csv(for logins: [WebLogin]) -> String {
        var lines = ["name,url,username,password,note"]
        for l in logins.sorted(by: { ($0.origin, $0.user) < ($1.origin, $1.user) }) {
            let host = URL(string: l.origin)?.host ?? l.origin
            lines.append([host, l.origin, l.user, l.password, ""].map(CSV.field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum PasswordGenerator {
    static let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), digits = Array("23456789"), symbols = Array("!@#$%^&*-_=+?")

    /// A random password from the system's secure generator, with at least one of each kind and without look-alike characters. Never fewer than 12.
    static func make(length: Int = 20, symbols useSymbols: Bool = true) -> String {
        let length = max(12, min(length, 128))
        var pools = [lower, upper, digits]; if useSymbols { pools.append(symbols) }
        let all = pools.flatMap { $0 }
        func pick(_ set: [Character]) -> Character { set[randomIndex(set.count)] }
        var out = pools.map(pick)
        while out.count < length { out.append(pick(all)) }
        for i in stride(from: out.count - 1, to: 0, by: -1) { out.swapAt(i, randomIndex(i + 1)) }      // Fisher-Yates
        return String(out)
    }

    /// An unbiased random number below `n` (values that would favour small results are thrown away).
    private static func randomIndex(_ n: Int) -> Int {
        precondition(n > 0)
        let limit = UInt32.max - (UInt32.max % UInt32(n))
        while true {
            var value: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            if value < limit { return Int(value % UInt32(n)) }
        }
    }
}

// MARK: - History

enum HistoryImport {
    struct Visit: Equatable { var url: String; var title: String; var seconds: Int64; var count: Int64 }

    /// Chrome's own export is not offered, but a Google Takeout file has "Browser History" with `time_usec` in microseconds since 1970.
    /// Safari's "Export Browsing History" file has `history` entries with `time_usec` too; both are read here, along with a few other common field names.
    static func parse(json data: Data) -> [Visit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var items: [[String: Any]] = []
        if let list = root as? [[String: Any]] { items = list }
        else if let dict = root as? [String: Any] {
            for key in ["Browser History", "history", "History", "items", "entries"] { if let list = dict[key] as? [[String: Any]] { items = list; break } }
        }
        var merged: [String: Visit] = [:]
        for item in items.prefix(500_000) {
            guard let url = (item["url"] ?? item["URL"] ?? item["destination_url"]) as? String else { continue }
            let title = ((item["title"] ?? item["Title"]) as? String) ?? ""
            let seconds = Self.seconds(from: item)
            let visits = (item["visit_count"] as? Int64) ?? Int64((item["visit_count"] as? Int) ?? (item["visitCount"] as? Int) ?? 1)
            if var existing = merged[url] { existing.count += max(1, visits); existing.seconds = max(existing.seconds, seconds); if existing.title.isEmpty { existing.title = title }; merged[url] = existing }
            else { merged[url] = Visit(url: url, title: title, seconds: seconds, count: max(1, visits)) }
        }
        return Array(merged.values)
    }

    private static func seconds(from item: [String: Any]) -> Int64 {
        func number(_ key: String) -> Double? { (item[key] as? NSNumber)?.doubleValue ?? (item[key] as? String).flatMap(Double.init) }
        if let micro = number("time_usec") ?? number("last_visit_time") ?? number("visit_time_usec") { return Int64(micro / 1_000_000) }
        if let s = number("time") ?? number("visit_time") ?? number("lastVisitTime") { return Int64(s > 1e12 ? s / 1000 : s) }
        return 0
    }
}
