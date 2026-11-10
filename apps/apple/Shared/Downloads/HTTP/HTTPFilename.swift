import Foundation
import UniformTypeIdentifiers

/// The name a downloaded file is saved under, chosen from what the server says and what the address says, and never trusted as a path.
/// Order: a valid Content-Disposition filename (RFC 6266; `filename*` over `filename`), then the last part of the address, then "download".
/// A server's name is advice, not an instruction (RFC 6266 §4.3: never write outside the folder, never trust an extension).
enum DownloadFilename {
    enum Source: String, Sendable { case contentDisposition, url, fallback }

    struct Derived: Equatable, Sendable {
        var name: String
        var source: Source
        /// Looks like a document but ends in something that runs (report.pdf.app). It is saved as named, and the person is told.
        var suspicious: Bool
    }

    static let maxBytes = 200
    private static let executableEndings: Set<String> = ["app", "command", "pkg", "mpkg", "exe", "scr", "bat", "cmd", "com", "msi", "jar", "js", "vbs", "sh", "workflow", "action", "terminal", "dmg", "iso"]
    private static let documentEndings: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "jpg", "jpeg", "png", "gif", "heic", "mp3", "mp4", "mov", "zip", "csv", "pages", "numbers", "key"]
    private static let reserved: Set<String> = ["con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"]

    static func derive(contentDisposition: String?, url: URL?, mimeType: String? = nil) -> Derived {
        if let header = contentDisposition, let raw = filename(fromContentDisposition: header), let clean = sanitize(raw) {
            return Derived(name: clean, source: .contentDisposition, suspicious: isSuspicious(clean))
        }
        if let url {
            let last = url.pathComponents.last(where: { $0 != "/" }) ?? ""
            if let clean = sanitize(last.removingPercentEncoding ?? last) {
                let named = addingExtension(for: mimeType, to: clean)
                return Derived(name: named, source: .url, suspicious: isSuspicious(named))
            }
        }
        return Derived(name: addingExtension(for: mimeType, to: "download"), source: .fallback, suspicious: false)
    }

    // MARK: Content-Disposition

    /// The filename from a Content-Disposition value: `filename*=UTF-8''%E2%82%AC.txt` wins over `filename="x.txt"`.
    static func filename(fromContentDisposition value: String) -> String? {
        let parameters = parse(value)
        if let extended = parameters["filename*"], let decoded = decodeExtended(extended) { return decoded }
        return parameters["filename"]
    }

    /// `type; name=value; name="quoted \"value\""`, names lowercased. A malformed parameter is skipped, not guessed at.
    static func parse(_ value: String) -> [String: String] {
        var parts: [String] = []
        var current = "", inQuotes = false, escaped = false
        for ch in value {
            if escaped { current.append(ch); escaped = false; continue }
            if inQuotes, ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == ";", !inQuotes { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        var out: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let name = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\"") {
                guard raw.count >= 2, raw.hasSuffix("\"") else { continue }
                raw = String(raw.dropFirst().dropLast())
                var unescaped = "", skip = false
                for ch in raw { if skip { unescaped.append(ch); skip = false } else if ch == "\\" { skip = true } else { unescaped.append(ch) } }
                raw = unescaped
            }
            if !name.isEmpty, out[name] == nil { out[name] = raw }
        }
        return out
    }

    /// RFC 5987: `charset'language'percent-encoded`. Only UTF-8 and ISO-8859-1 are defined; anything else is refused.
    static func decodeExtended(_ value: String) -> String? {
        let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        let charset = pieces[0].lowercased()
        var bytes: [UInt8] = []
        let encoded = Array(pieces[2].utf8)
        var i = 0
        while i < encoded.count {
            if encoded[i] == UInt8(ascii: "%") {
                guard i + 2 < encoded.count, let hi = hex(encoded[i + 1]), let lo = hex(encoded[i + 2]) else { return nil }
                bytes.append(hi << 4 | lo); i += 3
            } else { bytes.append(encoded[i]); i += 1 }
        }
        switch charset {
        case "utf-8": return String(bytes: bytes, encoding: .utf8)
        case "iso-8859-1": return String(bytes: bytes, encoding: .isoLatin1)
        default: return nil
        }
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c { case 48...57: c - 48; case 65...70: c - 55; case 97...102: c - 87; default: nil }
    }

    // MARK: Making a name safe

    /// A plain file name, or nil when nothing usable is left.
    static func sanitize(_ suggested: String) -> String? {
        // The last path segment only: both separators count, so a name can never reach into another folder.
        var name = suggested.precomposedStringWithCanonicalMapping
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) { name = String(name[name.index(after: slash)...]) }
        // Control characters, direction overrides (which can make "txt.exe" display as "exe.txt"), zero-width and byte-order marks, and ":" (Finder shows it as "/").
        name = String(String.UnicodeScalarView(name.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            switch scalar.value {
            case 0..<0x20, 0x7F...0x9F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF: return nil
            case 0x3A: return "-"
            default: return scalar
            }
        }))
        name = name.trimmingCharacters(in: .whitespaces)
        // No hidden files, and no trailing dots or spaces.
        while name.hasPrefix(".") { name.removeFirst() }
        while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }
        guard !name.isEmpty else { return nil }
        let stem = (name as NSString).deletingPathExtension.lowercased()
        if reserved.contains(stem) { name = "_" + name }
        return truncated(name)
    }

    /// At most `maxBytes` of UTF-8, cut on a character boundary, keeping the ending.
    static func truncated(_ name: String, maxBytes: Int = maxBytes) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        let stem = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
        var kept = ""
        for ch in stem { if (kept + String(ch)).utf8.count + suffix.utf8.count > maxBytes { break }; kept.append(ch) }
        while kept.hasSuffix(" ") || kept.hasSuffix(".") { kept.removeLast() }          // a cut must not leave "Title ..mp4"
        return kept.isEmpty ? String(name.prefix(32)) : kept + suffix
    }

    static func isSuspicious(_ name: String) -> Bool {
        let parts = name.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 3, let last = parts.last, let before = parts.dropLast().last else { return false }
        return executableEndings.contains(last) && documentEndings.contains(before)
    }

    private static func addingExtension(for mimeType: String?, to name: String) -> String {
        guard (name as NSString).pathExtension.isEmpty, let mime = mimeType?.split(separator: ";").first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
              let ext = UTType(mimeType: mime)?.preferredFilenameExtension, !executableEndings.contains(ext) else { return name }
        return truncated(name + "." + ext)
    }
}
