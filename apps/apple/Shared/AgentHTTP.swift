import Foundation
import Security

/// Just enough HTTP/1.1 for the local AI-tool connection: one POST with a JSON body per request. Pure parsing and checking, so it can be tested.
enum AgentHTTP {
    struct Request: Equatable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    enum Parse: Equatable {
        case needMore
        case request(Request)
        case bad(String)
    }

    static let maxHeader = 16 * 1024
    static let maxBody = 1_000_000

    /// Reads a request out of the bytes received so far.
    static func parse(_ data: Data) -> Parse {
        let marker = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: marker) else { return data.count > maxHeader ? .bad("Header too large") : .needMore }
        guard end.lowerBound <= maxHeader, let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .bad("Unreadable header") }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .bad("Bad request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .bad("Bad header") }
            headers[line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .bad("Chunked bodies are not supported") }
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        guard length >= 0, length <= maxBody else { return .bad("Body too large") }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .needMore }
        return .request(Request(method: first[0].uppercased(), path: first[1], headers: headers, body: data[bodyStart..<(bodyStart + length)]))
    }

    enum Check: Equatable {
        case ok
        case reject(status: Int, reason: String)
    }

    /// Who may talk to the browser. The connection is only on this Mac's own loopback address, and on top of that:
    /// a bearer token, a Host that names the loopback address (so a web page cannot reach it through a name it controls), and no Origin header
    /// (a web page's request always carries one; a command-line tool never does).
    static func authorize(_ request: Request, token: String, port: UInt16) -> Check {
        guard let host = request.headers["host"]?.lowercased(), host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return .reject(status: 403, reason: "Wrong host")
        }
        if request.headers["origin"] != nil { return .reject(status: 403, reason: "Requests from web pages are not accepted") }
        // With no token on record nothing can match, not even an empty one.
        guard !token.isEmpty, let header = request.headers["authorization"], header.hasPrefix("Bearer "), constantTimeEqual(String(header.dropFirst(7)), token) else {
            return .reject(status: 401, reason: "Missing or wrong token")
        }
        guard request.method == "POST" else { return .reject(status: 405, reason: "Use POST") }
        guard request.path == "/mcp" else { return .reject(status: 404, reason: "Not found") }
        return .ok
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0) }
        return diff == 0
    }

    static func response(status: Int, reason: String, body: Data = Data(), json: Bool = true) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if json && !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    /// 32 random bytes as hex.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess { for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) } }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
