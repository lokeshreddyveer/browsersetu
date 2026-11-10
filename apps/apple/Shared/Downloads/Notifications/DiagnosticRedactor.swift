import Foundation

/// The one set of rules for what may leave the app in a log line, a timeline or a report. Stored diagnostics and exported ones both go through it, so a copy is never less safe
/// than what is kept.
enum DiagnosticRedactor {
    /// A path segment that looks like a secret (long, random-looking) becomes "…".
    private static func looksSecret(_ segment: Substring) -> Bool {
        guard segment.count >= 24 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=")
        return segment.unicodeScalars.allSatisfy { allowed.contains($0) } && segment.contains { $0.isNumber }
    }

    /// scheme://host[:port]/path — no user name, password, query or fragment, and no secret-looking path pieces.
    static func url(_ raw: String?) -> String? {
        guard let raw, var parts = URLComponents(string: raw), let host = parts.host else { return nil }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        parts.path = parts.path.split(separator: "/", omittingEmptySubsequences: false).map { looksSecret($0) ? "…" : String($0) }.joined(separator: "/")
        _ = host
        return parts.url?.absoluteString
    }

    static func host(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if let h = URLComponents(string: raw)?.host { return h }
        guard !raw.contains("/") else { return nil }
        // "user:pass@host" without a scheme: only the host.
        let afterAt = raw.split(separator: "@").last.map(String.init) ?? raw
        return afterAt.split(separator: ":").first.map(String.init)
    }

    private static let patterns: [(String, String)] = [
        (#"(https?://[^\s?"')]*)\?[^\s"')]*"#, "$1"),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"#, "[redacted token]"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "[redacted key]"),
        (#"(?i)\b([A-Za-z0-9_-]*(?:token|secret|password|passwd|signature|apikey|api_key|api-key|credential|session|sid|auth|sig)[A-Za-z0-9_-]*)"?\s*[=:]\s*"?[^&\s"',;]+"#, "$1=[redacted]"),
        (#"/Users/[^/\s]+"#, "/Users/~"),
        (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer [redacted]"),
        (#"bsat_[0-9a-f]{8}_[0-9a-f]{16,}"#, "[redacted token]"),
        (#"(?i)(authorization|proxy-authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+"#, "$1: [redacted]"),
        (#"(?i)([?&;\s](?:sig|signature|token|access_token|key|api_key|apikey|password|passwd|secret|auth|x-amz-signature|x-amz-credential|session|sid)=)[^&\s"']+"#, "$1[redacted]"),
        (#"(?i)(https?://)[^/\s:@]+:[^/\s@]+@"#, "$1[redacted]@"),
        (#"\b[A-Fa-f0-9]{40,}\b"#, "[redacted hex]"),
        (#"\b[A-Za-z0-9+/_-]{40,}={0,2}"#, "[redacted]"),
    ]

    /// Free text (an error message, a note): every address inside loses its query, and anything shaped like a credential is removed.
    static func text(_ input: String?, limit: Int = 300) -> String? {
        guard var s = input.map({ String($0.prefix(4000)) }) else { return nil }
        for (pattern, template) in patterns {
            guard let rx = try? NSRegularExpression(pattern: pattern) else { continue }
            s = rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        // Whole addresses lose their query and fragment.
        if let rx = try? NSRegularExpression(pattern: #"https?://[^\s"')]+"#) {
            let ns = s as NSString
            for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                if let cleaned = url(ns.substring(with: m.range)) { s = (s as NSString).replacingCharacters(in: m.range, with: cleaned) }
            }
        }
        s = s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(String.init).joined()
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    /// A file name only: no folder, nothing the person would not see in the list.
    static func filename(_ raw: String?) -> String? { raw.map { String((($0 as NSString).lastPathComponent).prefix(120)) } }
}
