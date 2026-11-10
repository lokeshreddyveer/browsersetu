import CryptoKit
import Foundation

// The small tools (JSON, URL, Base64, timestamps, text compare, hashes, regular expressions, colours, UUIDs, and a look inside a JWT), described once so the Tools panel and the command
// palette share one list. Every tool runs on this device on what is typed or pasted and returns text; none opens a connection, and nothing typed into one is kept: the inputs live only
// in the panel while it is open (they are not saved, not put in history or search, and not synced). The list is built the first time a tool is asked for, so browsing never pays for it.

enum ToolPlatform: Hashable { case mac, phone }

struct ToolInputSpec: Identifiable, Equatable {
    enum Kind: Equatable { case text, multiline, choice([String]), flag }
    let id: String
    let label: String
    var kind: Kind = .multiline
    var initial = ""
}

/// What a tool produced: labelled values, an error if the input could not be used, and the one text that "Copy Result" copies.
struct ToolOutput: Equatable {
    var rows: [(label: String, value: String)] = []
    var warnings: [String] = []
    var error: String?
    var primary: String { rows.first?.value ?? "" }

    static func == (a: ToolOutput, b: ToolOutput) -> Bool { a.rows.map(\.label) == b.rows.map(\.label) && a.rows.map(\.value) == b.rows.map(\.value) && a.warnings == b.warnings && a.error == b.error }
    static func failure(_ text: String) -> ToolOutput { ToolOutput(error: text) }
}

struct ToolDescriptor: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let platforms: Set<ToolPlatform>
    let inputs: [ToolInputSpec]
    /// Everything it needs is in `values` (by input id); it does the work here and returns text.
    let run: ([String: String]) -> ToolOutput
    var example: [String: String] = [:]

    /// The most any one box may hold (about a million characters): beyond that a tool only slows the panel down.
    static let maxInput = 1_000_000

    /// Runs the tool, after checking that nothing typed is too big for it. The panel and the palette use this, not `run` directly.
    func runBounded(_ values: [String: String]) -> ToolOutput {
        if values.values.contains(where: { $0.utf8.count > Self.maxInput }) { return .failure("That is too much text for this tool (about a million characters at most).") }
        if id == "diff", values.values.contains(where: { $0.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } >= DevUtilities.maxDiffLines }) {
            return .failure("Too many lines to compare here (\(DevUtilities.maxDiffLines) at most on each side).")
        }
        return run(values)
    }
}

/// A tool and its text, moved off the main thread to be worked on there.
struct ToolJob: @unchecked Sendable {
    let tool: ToolDescriptor
    let values: [String: String]
    func run() -> ToolOutput { tool.runBounded(values) }
}

enum ToolRegistry {
    /// Built on first use.
    static let all: [ToolDescriptor] = [
        ToolDescriptor(id: "json", title: "JSON Formatter and Validator", symbol: "curlybraces", summary: "Checks JSON and lays it out, or squeezes it small.",
                       platforms: [.mac, .phone], inputs: [ToolInputSpec(id: "input", label: "JSON")], run: { v in
            let text = v["input"] ?? ""
            switch DevUtilities.formatJSON(text) {
            case .failed(let why): return .failure(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Paste JSON above." : why)
            case .ok(let pretty):
                var out = ToolOutput(rows: [("Formatted", pretty)])
                if case .ok(let small) = DevUtilities.formatJSON(text, pretty: false) { out.rows.append(("Minified", small)) }
                return out
            }
        }, example: ["input": "{\"name\":\"Browser Setu\",\"tabs\":[3,1,2],\"private\":true}"]),

        ToolDescriptor(id: "url", title: "URL Encode and Decode", symbol: "link", summary: "Percent-encodes text for an address, or reads it back.",
                       platforms: [.mac, .phone], inputs: [ToolInputSpec(id: "input", label: "Text or address")], run: { v in
            let text = v["input"] ?? ""
            guard !text.isEmpty else { return .failure("Type or paste text above.") }
            return ToolOutput(rows: [("Encoded", DevUtilities.urlEncode(text)), ("Decoded", DevUtilities.urlDecode(text) ?? "Not valid percent-encoding.")])
        }, example: ["input": "https://example.com/search?q=privacy browser&lang=en"]),

        ToolDescriptor(id: "base64", title: "Base64 Encode and Decode", symbol: "number", summary: "Base64, and the URL-safe form.",
                       platforms: [.mac, .phone], inputs: [ToolInputSpec(id: "input", label: "Text")], run: { v in
            let text = v["input"] ?? ""
            guard !text.isEmpty else { return .failure("Type or paste text above.") }
            return ToolOutput(rows: [("Encoded", DevUtilities.base64Encode(text)), ("URL-safe", DevUtilities.base64Encode(text, urlSafe: true)), ("Decoded", DevUtilities.base64Decode(text) ?? "Not valid Base64 text.")])
        }, example: ["input": "Browser Setu keeps your data on your device"]),

        ToolDescriptor(id: "uuid", title: "UUID Generator", symbol: "key.horizontal", summary: "Random version 4 identifiers, one or many, in the style you need.",
                       platforms: [.mac, .phone], inputs: [ToolInputSpec(id: "count", label: "How many (1 to 50)", kind: .text, initial: "1"),
                                                           ToolInputSpec(id: "style", label: "Style", kind: .choice(UUIDTool.Style.allCases.map(\.rawValue)), initial: UUIDTool.Style.standard.rawValue)], run: { v in
            let count = Int((v["count"] ?? "1").trimmingCharacters(in: .whitespaces)) ?? 1
            let style = UUIDTool.Style(rawValue: v["style"] ?? "") ?? .standard
            let list = UUIDTool.generate(count: count, style: style)
            return ToolOutput(rows: [("UUIDs", list.joined(separator: "\n"))], warnings: count > UUIDTool.maxCount ? ["Limited to \(UUIDTool.maxCount)."] : [])
        }),

        ToolDescriptor(id: "time", title: "Timestamp Formatter", symbol: "clock", summary: "Unix seconds or milliseconds to a date, or a date to Unix time.",
                       platforms: [.mac, .phone], inputs: [ToolInputSpec(id: "input", label: "Unix time or date", kind: .text)], run: { v in
            let text = v["input"] ?? ""
            if let r = DevUtilities.readTimestamp(text) { return ToolOutput(rows: [("UTC", r.utc), ("Local", r.local), ("Read as", r.unit)]) }
            if let seconds = DevUtilities.timestamp(fromISO: text) { return ToolOutput(rows: [("Seconds", String(Int(seconds))), ("Milliseconds", String(Int(seconds * 1000)))]) }
            return .failure("Enter a Unix time (seconds or milliseconds) or a date such as 2026-10-18T09:30:00Z.")
        }, example: ["input": "1760803200"]),

        ToolDescriptor(id: "diff", title: "Text Diff", symbol: "arrow.left.arrow.right", summary: "Which lines are only on the left, and which only on the right.",
                       platforms: [.mac, .phone], inputs: [ToolInputSpec(id: "left", label: "Left text"), ToolInputSpec(id: "right", label: "Right text")], run: { v in
            let d = DevUtilities.diffLines(v["left"] ?? "", v["right"] ?? "")
            return ToolOutput(rows: [("Summary", "\(d.same) lines the same · \(d.removed.count) only on the left · \(d.added.count) only on the right"),
                                     ("Only on the left", d.removed.prefix(200).map { "− " + $0 }.joined(separator: "\n")), ("Only on the right", d.added.prefix(200).map { "+ " + $0 }.joined(separator: "\n"))])
        }, example: ["left": "one\ntwo\nthree", "right": "one\n2\nthree\nfour"]),

        ToolDescriptor(id: "hash", title: "Hash Calculator", symbol: "number.square", summary: "SHA-256, SHA-512, SHA-1 or MD5 of some text.",
                       platforms: [.mac, .phone], inputs: [ToolInputSpec(id: "input", label: "Text"), ToolInputSpec(id: "algorithm", label: "Algorithm", kind: .choice(DevUtilities.HashKind.allCases.map(\.rawValue)), initial: DevUtilities.HashKind.sha256.rawValue)], run: { v in
            let kind = DevUtilities.HashKind(rawValue: v["algorithm"] ?? "") ?? .sha256
            var out = ToolOutput(rows: [(kind.rawValue, DevUtilities.hash(v["input"] ?? "", kind))])
            if let note = kind.note { out.warnings.append(note) }
            return out
        }, example: ["input": "Browser Setu"]),

        ToolDescriptor(id: "jwt", title: "JWT Inspector", symbol: "key.viewfinder", summary: "Reads a token's header and claims on this device. The signature is not checked and the token is never sent anywhere.",
                       platforms: [.mac, .phone], inputs: [ToolInputSpec(id: "input", label: "Token")], run: { v in JWTInspector.inspect(v["input"] ?? "").output }),

        ToolDescriptor(id: "regex", title: "Regular Expression Tester", symbol: "text.magnifyingglass", summary: "Shows what a pattern matches in some text, with its groups.",
                       platforms: [.mac, .phone], inputs: [ToolInputSpec(id: "pattern", label: "Pattern", kind: .text), ToolInputSpec(id: "text", label: "Text to test"), ToolInputSpec(id: "flags", label: "Flags (i m s x)", kind: .text, initial: "i")], run: { v in
            switch DevUtilities.testRegex(v["pattern"] ?? "", in: v["text"] ?? "", flags: v["flags"] ?? "") {
            case .failed(let why): return .failure(why)
            case .matches(let list):
                if list.isEmpty { return ToolOutput(rows: [("Result", "No match")]) }
                var rows = [("Result", "\(list.count) match\(list.count == 1 ? "" : "es")")]
                for (i, m) in list.prefix(50).enumerated() { rows.append(("Match \(i + 1)", ([m.text] + m.groups.enumerated().map { "  group \($0.offset + 1): \($0.element)" }).joined(separator: "\n"))) }
                return ToolOutput(rows: rows)
            }
        }, example: ["pattern": "(\\w+)@(\\w+)\\.com", "text": "write to ada@example.com or grace@navy.com today", "flags": "i"]),

        ToolDescriptor(id: "color", title: "Colour Converter", symbol: "paintpalette", summary: "Hex, RGB and HSL of a colour, whichever you type.",
                       platforms: [.mac, .phone], inputs: [ToolInputSpec(id: "input", label: "#1B2A4A, rgb(27, 42, 74) or hsl(220, 47%, 20%)", kind: .text)], run: { v in
            guard let c = DevUtilities.parseColor(v["input"] ?? "") else { return .failure("Type #1B2A4A, rgb(27, 42, 74) or hsl(220, 47%, 20%).") }
            let d = DevUtilities.describeColor(c)
            return ToolOutput(rows: [("Hex", d.hex), ("RGB", d.rgb), ("HSL", d.hsl)])
        }, example: ["input": "#1B2A4A"]),
    ]

    static func tool(_ id: String) -> ToolDescriptor? { all.first { $0.id == id } }

    static func tools(for platform: ToolPlatform) -> [ToolDescriptor] { all.filter { $0.platforms.contains(platform) } }

    /// What the command palette lists: a name and a symbol per tool.
    static var paletteEntries: [(id: String, title: String, symbol: String)] {
        #if os(macOS)
        let platform = ToolPlatform.mac
        #else
        let platform = ToolPlatform.phone
        #endif
        return tools(for: platform).map { ($0.id, $0.title, $0.symbol) }
    }
}

// MARK: - UUIDs

enum UUIDTool {
    enum Style: String, CaseIterable { case standard = "Lower case", upper = "Upper case", compact = "No dashes", braces = "In braces" }
    static let maxCount = 50

    static func generate(count: Int, style: Style) -> [String] {
        (0..<max(1, min(count, maxCount))).map { _ in
            let raw = UUID().uuidString
            switch style {
            case .standard: return raw.lowercased()
            case .upper: return raw
            case .compact: return raw.replacingOccurrences(of: "-", with: "").lowercased()
            case .braces: return "{" + raw + "}"
            }
        }
    }
}

// MARK: - JWT

/// Reads a JSON Web Token's structure without sending it anywhere and without claiming to verify it: the header and claims are decoded and laid out, dates in them are read,
/// and what looks risky is pointed out. The signature is never checked (there is no key), and the page says so.
enum JWTInspector {
    struct Report {
        var output: ToolOutput
    }

    private static func decodePart(_ part: Substring) -> Data? {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    private static func pretty(_ data: Data) -> (String, [String: Any])? {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any],
              let out = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return (String(decoding: out, as: UTF8.self), dictionary)
    }

    static func inspect(_ token: String, now: Date = Date()) -> Report {
        let text = token.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "Bearer ", with: "")
        guard !text.isEmpty else { return Report(output: .failure("Paste a token above.")) }
        guard text.count <= 100_000 else { return Report(output: .failure("That is too long to be a token.")) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 2 else { return Report(output: .failure("A token has three parts separated by dots (header, claims, signature). This has \(parts.count).")) }
        guard let headerData = decodePart(parts[0]), let header = pretty(headerData) else { return Report(output: .failure("The first part is not a readable header.")) }
        guard let claimsData = decodePart(parts[1]), let claims = pretty(claimsData) else { return Report(output: .failure("The second part is not readable claims (it may be encrypted).")) }
        var rows: [(label: String, value: String)] = [("Header", header.0), ("Claims", claims.0)]
        var warnings: [String] = ["The signature is NOT checked: this only reads the token. Nothing was sent anywhere."]
        let algorithm = (header.1["alg"] as? String) ?? ""
        if algorithm.isEmpty { warnings.append("The header names no algorithm.") }
        if algorithm.lowercased() == "none" { warnings.append("The algorithm is “none”: this token is not signed at all, so anyone could have written it.") }
        if parts.count == 2 || parts[2].isEmpty { warnings.append("There is no signature part.") }
        rows.append(("Algorithm", algorithm.isEmpty ? "(none named)" : algorithm))
        func date(_ key: String) -> Date? { (claims.1[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        func show(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
        if let issued = date("iat") { rows.append(("Issued", show(issued))) }
        if let notBefore = date("nbf") { rows.append(("Not valid before", show(notBefore))); if notBefore > now { warnings.append("It is not valid yet.") } }
        if let expires = date("exp") {
            rows.append(("Expires", show(expires)))
            warnings.append(expires < now ? "It has expired (\(show(expires)))." : "It has not expired.")
        } else { warnings.append("It has no expiry.") }
        for key in ["iss", "sub", "aud"] { if let value = claims.1[key] { rows.append((key == "iss" ? "Issuer" : key == "sub" ? "Subject" : "Audience", "\(value)")) } }
        return Report(output: ToolOutput(rows: rows, warnings: warnings))
    }
}
