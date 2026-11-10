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
    /// The longest a pattern may work on the text. A pattern such as (a+)+$ can take longer than the age of the universe on a few dozen characters; the matcher reports
    /// its progress now and then, and when the time is up it is stopped, so a typo in a pattern can never freeze the app.
    static let regexTimeLimit: TimeInterval = 1.0

    static func testRegex(_ pattern: String, in text: String, flags: String = "", timeLimit: TimeInterval = DevUtilities.regexTimeLimit) -> RegexResult {
        guard !pattern.isEmpty else { return .failed("Enter a pattern.") }
        guard pattern.utf16.count <= 500 else { return .failed("The pattern is too long (500 characters at most).") }
        guard text.utf16.count <= 50_000 else { return .failed("The text is too long to test here (50,000 characters at most).") }
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: options)
            let whole = NSRange(text.startIndex..., in: text)
            let deadline = Date().addingTimeInterval(timeLimit)
            var timedOut = false
            var found: [RegexMatch] = []
            regex.enumerateMatches(in: text, options: [.reportProgress], range: whole) { m, flags, stop in
                if Date() > deadline { timedOut = true; stop.pointee = true; return }
                guard let m, !flags.contains(.progress) else { return }
                let groups = (1..<max(m.numberOfRanges, 1)).map { i -> String in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? "" : (Range(r, in: text).map { String(text[$0]) } ?? "")
                }
                found.append(RegexMatch(text: Range(m.range, in: text).map { String(text[$0]) } ?? "", range: m.range, groups: groups))
                if found.count >= 500 { stop.pointee = true }
            }
            if timedOut { return .failed("That pattern took too long on this text, so it was stopped. A repeat inside a repeat, such as (a+)+, is the usual cause.") }
            return .matches(found)
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

    /// The most lines a side may have for the comparison: the work grows with the lines times the differences.
    static let maxDiffLines = 3_000

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
