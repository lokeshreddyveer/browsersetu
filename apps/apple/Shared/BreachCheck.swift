import CryptoKit
import Foundation

/// Checks saved passwords against the Have I Been Pwned list of leaked passwords without sending any password, or even a whole hash of one.
/// Each password is hashed with SHA-1 on this device and only the first five characters of the hash are sent ("k-anonymity"); the service returns every
/// leaked hash that starts the same way, and the match is made here. Nothing is checked unless the person asks, and nothing is stored from the answer.
enum BreachCheck {
    struct Finding: Equatable {
        /// How many times the password appears in known leaks; 0 means not found.
        var leaks = 0
        /// Other sites (hosts) where the same password is saved.
        var reusedOn: [String] = []
        var isProblem: Bool { leaks > 0 || !reusedOn.isEmpty }
    }

    /// The first five characters of the SHA-1 and the rest, in capitals, as the service expects.
    static func split(_ password: String) -> (prefix: String, suffix: String) {
        let hex = Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
        return (String(hex.prefix(5)), String(hex.dropFirst(5)))
    }

    /// The count for `suffix` in a response of "SUFFIX:COUNT" lines. Padding lines (count 0) mean "not found".
    static func count(of suffix: String, in body: String) -> Int {
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":")
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).uppercased() == suffix { return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        return 0
    }

    enum Failure: Error { case unreachable }

    /// Asks the service for one five-character range. No cookies, no account, no cache, and padded so every answer has a similar size.
    static func fetchRange(_ prefix: String) async throws -> String {
        guard prefix.count == 5, let url = URL(string: "https://api.pwnedpasswords.com/range/" + prefix) else { throw Failure.unreachable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "Add-Padding")
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else { throw Failure.unreachable }
        return text
    }

    /// Looks at every saved password: leaked ones and ones reused on other sites. Passwords that share a prefix cost one request. The result is keyed by the login's id.
    static func scan(_ logins: [WebLogin], fetch: (String) async throws -> String = fetchRange) async throws -> [String: Finding] {
        var results: [String: Finding] = [:]
        var byPrefix: [String: [(WebLogin, String)]] = [:]
        for login in logins where !login.password.isEmpty {
            let parts = split(login.password)
            byPrefix[parts.prefix, default: []].append((login, parts.suffix))
        }
        for (prefix, members) in byPrefix.sorted(by: { $0.key < $1.key }) {
            let body = try await fetch(prefix)
            for (login, suffix) in members { results[login.id, default: Finding()].leaks = count(of: suffix, in: body) }
            try Task.checkCancellation()
        }
        let byPassword = Dictionary(grouping: logins.filter { !$0.password.isEmpty }, by: \.password)
        for group in byPassword.values where Set(group.map(\.origin)).count > 1 {
            for login in group {
                let others = Set(group.filter { $0.origin != login.origin }.map { URL(string: $0.origin)?.host ?? $0.origin })
                results[login.id, default: Finding()].reusedOn = others.sorted()
            }
        }
        return results
    }

    static func summary(_ findings: [String: Finding], checked: Int) -> String {
        let leaked = findings.values.filter { $0.leaks > 0 }.count
        let reused = findings.values.filter { !$0.reusedOn.isEmpty }.count
        if leaked == 0, reused == 0 { return "Checked \(checked) password\(checked == 1 ? "" : "s"). None were found in known leaks, and none are reused." }
        var parts: [String] = []
        if leaked > 0 { parts.append("\(leaked) found in known leaks") }
        if reused > 0 { parts.append("\(reused) used on more than one site") }
        return "Checked \(checked) password\(checked == 1 ? "" : "s"): " + parts.joined(separator: ", ") + ". Change these first."
    }
}
