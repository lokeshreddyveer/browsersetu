import CryptoKit
import Foundation
import SwiftUI

/// Small tools a developer reaches for. Everything runs on this device; nothing is sent anywhere.
enum DevUtilities {
    // MARK: JSON

    enum JSONResult: Equatable { case ok(String), failed(String) }

    static func formatJSON(_ text: String, pretty: Bool = true) -> JSONResult {
        guard let data = text.data(using: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failed("Nothing to format.") }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
            if pretty { options.insert(.prettyPrinted) }
            let out = try JSONSerialization.data(withJSONObject: object, options: options)
            return .ok(String(decoding: out, as: UTF8.self))
        } catch { return .failed(((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription) }
    }

    // MARK: URL and Base64

    static func urlEncode(_ text: String, component: Bool = true) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        if component { allowed.remove(charactersIn: "!*'();:@&=+$,/?#[]") }
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func urlDecode(_ text: String) -> String? { text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding }

    static func base64Encode(_ text: String, urlSafe: Bool = false) -> String {
        let s = Data(text.utf8).base64EncodedString()
        return urlSafe ? s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") : s
    }

    /// Accepts the standard and the URL-safe alphabets, with or without padding.
    static func base64Decode(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Timestamps

    struct TimeReading: Equatable { var seconds: Double; var utc: String; var local: String; var unit: String }

    /// A number as a time. Ten digits or fewer is seconds; thirteen is milliseconds; sixteen microseconds.
    static func readTimestamp(_ text: String, zone: TimeZone = .current) -> TimeReading? {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite, number >= 0 else { return nil }
        let (seconds, unit): (Double, String) = number >= 1e15 ? (number / 1e6, "microseconds") : (number >= 1e11 ? (number / 1000, "milliseconds") : (number, "seconds"))
        let date = Date(timeIntervalSince1970: seconds)
        let utc = ISO8601DateFormatter(); utc.timeZone = TimeZone(identifier: "UTC")
        let local = ISO8601DateFormatter(); local.timeZone = zone
        return TimeReading(seconds: seconds, utc: utc.string(from: date), local: local.string(from: date), unit: unit)
    }

    static func timestamp(fromISO text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let full = ISO8601DateFormatter()
        if let d = full.date(from: t) { return d.timeIntervalSince1970 }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: t) { return d.timeIntervalSince1970 }
        let day = ISO8601DateFormatter(); day.formatOptions = [.withFullDate]
        return day.date(from: t)?.timeIntervalSince1970
    }

    // MARK: Regular expressions

    struct RegexMatch: Equatable { var text: String; var range: NSRange; var groups: [String] }
    enum RegexResult: Equatable { case matches([RegexMatch]), failed(String) }

    /// Flags: i (ignore case), m (lines), s (dot matches newline), x (extended).
    static func testRegex(_ pattern: String, in text: String, flags: String = "") -> RegexResult {
        guard !pattern.isEmpty else { return .failed("Enter a pattern.") }
        guard text.utf16.count <= 50_000 else { return .failed("The text is too long to test here (50,000 characters at most).") }
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: options)
            let whole = NSRange(text.startIndex..., in: text)
            let found = regex.matches(in: text, range: whole).prefix(500).map { m -> RegexMatch in
                let groups = (1..<max(m.numberOfRanges, 1)).map { i -> String in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? "" : (Range(r, in: text).map { String(text[$0]) } ?? "")
                }
                return RegexMatch(text: Range(m.range, in: text).map { String(text[$0]) } ?? "", range: m.range, groups: groups)
            }
            return .matches(Array(found))
        } catch { return .failed("That pattern is not valid.") }
    }

    // MARK: Colours

    struct ColorValues: Equatable { var hex: String; var rgb: String; var hsl: String }

    static func parseColor(_ text: String) -> (r: Double, g: Double, b: Double)? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") || t.allSatisfy({ $0.isHexDigit }) {
            var h = t; if h.hasPrefix("#") { h.removeFirst() }
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            return StartColor.components(h)
        }
        let numbers = t.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init)
        if t.hasPrefix("rgb"), numbers.count >= 3, numbers.prefix(3).allSatisfy({ (0...255).contains($0) }) { return (numbers[0] / 255, numbers[1] / 255, numbers[2] / 255) }
        if t.hasPrefix("hsl"), numbers.count >= 3, numbers[0] <= 360, numbers[1] <= 100, numbers[2] <= 100 { return hslToRGB(h: numbers[0], s: numbers[1] / 100, l: numbers[2] / 100) }
        return nil
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    static func describeColor(_ c: (r: Double, g: Double, b: Double)) -> ColorValues {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), l = (mx + mn) / 2, d = mx - mn
        var h = 0.0, s = 0.0
        if d > 0 {
            s = d / (1 - abs(2 * l - 1))
            if mx == c.r { h = 60 * ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) } else if mx == c.g { h = 60 * ((c.b - c.r) / d + 2) } else { h = 60 * ((c.r - c.g) / d + 4) }
            if h < 0 { h += 360 }
        }
        func b(_ x: Double) -> Int { Int((x * 255).rounded()) }
        return ColorValues(hex: StartColor.hex(r: c.r, g: c.g, b: c.b), rgb: "rgb(\(b(c.r)), \(b(c.g)), \(b(c.b)))", hsl: "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)")
    }

    // MARK: Text comparison

    struct LineDiff: Equatable { var removed: [String]; var added: [String]; var same: Int }

    static func diffLines(_ a: String, _ b: String) -> LineDiff {
        let left = a.components(separatedBy: "\n"), right = b.components(separatedBy: "\n")
        let difference = right.difference(from: left)
        var removed: [String] = [], added: [String] = []
        for change in difference {
            switch change {
            case .remove(_, let line, _): removed.append(line)
            case .insert(_, let line, _): added.append(line)
            }
        }
        return LineDiff(removed: removed.reversed(), added: added, same: left.count - removed.count)
    }

    // MARK: Hashes

    enum HashKind: String, CaseIterable, Identifiable {
        case sha256 = "SHA-256", sha512 = "SHA-512", sha1 = "SHA-1", md5 = "MD5"
        var id: String { rawValue }
        var note: String? { self == .sha1 || self == .md5 ? "Broken for security; fine for checking a file or an old checksum." : nil }
    }

    static func hash(_ text: String, _ kind: HashKind) -> String {
        let data = Data(text.utf8)
        func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
        switch kind {
        case .sha256: return hex(SHA256.hash(data: data))
        case .sha512: return hex(SHA512.hash(data: data))
        case .sha1: return hex(Insecure.SHA1.hash(data: data))
        case .md5: return hex(Insecure.MD5.hash(data: data))
        }
    }
}

struct DevUtilitiesView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case json = "JSON", url = "URL", base64 = "Base64", time = "Timestamp", regex = "Regex", color = "Colour", compare = "Compare", hash = "Hash"
        var id: String { rawValue }
    }
    @State private var tool = Tool.json
    @State private var input = ""
    @State private var second = ""
    @State private var flags = "i"
    @State private var hashKind = DevUtilities.HashKind.sha256
    @State private var picked = Color.blue

    var body: some View {
        List {
            Section {
                Button("Try an Example") { loadExample() }.buttonStyle(.borderless)
                Picker("Tool", selection: $tool) { ForEach(Tool.allCases) { Text($0.rawValue).tag($0) } }
                editor(tool == .compare ? "Left text" : (tool == .regex ? "Pattern" : "Input"), $input, height: tool == .regex ? 36 : 110)
                if tool == .regex { editor("Text to test", $second, height: 90); TextField("Flags (i m s x)", text: $flags).textFieldStyle(.roundedBorder) }
                if tool == .compare { editor("Right text", $second, height: 110) }
                if tool == .hash { Picker("Algorithm", selection: $hashKind) { ForEach(DevUtilities.HashKind.allCases) { Text($0.rawValue).tag($0) } }
                    if let note = hashKind.note { Text(note).font(.caption).foregroundStyle(.secondary) } }
            }
            Section("Result") { result }
        }
        #if DEBUG
        .onAppear {
            if let name = UserDefaults.standard.string(forKey: "ShotTool"), let wanted = Tool(rawValue: name) { tool = wanted; loadExample() }
        }
        #endif
    }

    /// Fills the boxes for the tool in use with something that shows what it does.
    private func loadExample() {
        switch tool {
        case .json: input = "{\"name\":\"Browser Setu\",\"tabs\":[3,1,2],\"private\":true,\"engine\":\"WebKit\"}"
        case .url: input = "https://example.com/search?q=privacy browser&lang=en"
        case .base64: input = "Browser Setu keeps your data on your device"
        case .time: input = "1760803200"
        case .regex: input = "(\\w+)@(\\w+)\\.com"; second = "write to ada@example.com or grace@navy.com today"
        case .color: input = "#1B2A4A"
        case .compare: input = "one\ntwo\nthree"; second = "one\n2\nthree\nfour"
        case .hash: input = "Browser Setu"
        }
    }

    private func editor(_ title: String, _ text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(.callout, design: .monospaced)).frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        }
    }

    private func out(_ text: String, copyable: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text.isEmpty ? " " : text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            if copyable && !text.isEmpty { Button("Copy") { copyToPasteboard(text) }.buttonStyle(.borderless) }
        }
    }

    @ViewBuilder private var result: some View {
        switch tool {
        case .json:
            switch DevUtilities.formatJSON(input) {
            case .ok(let pretty): out(pretty); Button("Copy Minified") { if case .ok(let m) = DevUtilities.formatJSON(input, pretty: false) { copyToPasteboard(m) } }.buttonStyle(.borderless)
            case .failed(let why): Text(input.isEmpty ? "Paste JSON above." : why).foregroundStyle(input.isEmpty ? Color.secondary : Color.red)
            }
        case .url:
            LabeledContent("Encoded") { out(DevUtilities.urlEncode(input)) }
            LabeledContent("Decoded") { out(DevUtilities.urlDecode(input) ?? "Not valid percent-encoding.") }
        case .base64:
            LabeledContent("Encoded") { out(DevUtilities.base64Encode(input)) }
            LabeledContent("URL-safe") { out(DevUtilities.base64Encode(input, urlSafe: true)) }
            LabeledContent("Decoded") { out(input.isEmpty ? "" : (DevUtilities.base64Decode(input) ?? "Not valid Base64 text.")) }
        case .time:
            if let r = DevUtilities.readTimestamp(input) {
                LabeledContent("Read as", value: r.unit); LabeledContent("UTC") { out(r.utc) }; LabeledContent("Local") { out(r.local) }
            } else if let seconds = DevUtilities.timestamp(fromISO: input) {
                LabeledContent("Seconds") { out(String(Int(seconds))) }; LabeledContent("Milliseconds") { out(String(Int(seconds * 1000))) }
            } else { Text("Enter a Unix time (seconds, milliseconds) or a date such as 2026-10-18T09:30:00Z.").foregroundStyle(.secondary) }
            Button("Now") { input = String(Int(Date().timeIntervalSince1970)) }.buttonStyle(.borderless)
        case .regex:
            switch DevUtilities.testRegex(input, in: second, flags: flags) {
            case .failed(let why): Text(why).foregroundStyle(input.isEmpty ? Color.secondary : Color.red)
            case .matches(let list):
                Text(list.isEmpty ? "No match" : "\(list.count) match\(list.count == 1 ? "" : "es")").fontWeight(.medium)
                ForEach(Array(list.prefix(50).enumerated()), id: \.offset) { i, m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(i + 1). \(m.text)").font(.system(.callout, design: .monospaced))
                        ForEach(Array(m.groups.enumerated()), id: \.offset) { g, text in Text("   group \(g + 1): \(text)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                }
            }
        case .color:
            ColorPicker("Pick a colour", selection: $picked, supportsOpacity: false).onChange(of: picked) { _, c in input = StartColor.hex(of: c) }
            if let c = DevUtilities.parseColor(input) {
                let v = DevUtilities.describeColor(c)
                RoundedRectangle(cornerRadius: 6).fill(Color(red: c.r, green: c.g, blue: c.b)).frame(height: 28)
                LabeledContent("Hex") { out(v.hex) }; LabeledContent("RGB") { out(v.rgb) }; LabeledContent("HSL") { out(v.hsl) }
            } else { Text("Type #1B2A4A, rgb(27, 42, 74) or hsl(220, 47%, 20%), or pick one.").foregroundStyle(.secondary) }
        case .compare:
            let d = DevUtilities.diffLines(input, second)
            Text("\(d.same) lines the same · \(d.removed.count) only on the left · \(d.added.count) only on the right").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(d.removed.prefix(200).enumerated()), id: \.offset) { Text("− " + $1).foregroundStyle(Color.red).font(.system(.callout, design: .monospaced)) }
            ForEach(Array(d.added.prefix(200).enumerated()), id: \.offset) { Text("+ " + $1).foregroundStyle(Color.green).font(.system(.callout, design: .monospaced)) }
        case .hash:
            out(DevUtilities.hash(input, hashKind))
        }
    }
}
