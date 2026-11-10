import Foundation

/// Small address-bar completions that do not depend on the screen.
enum AddressShortcut {
    /// Control+Return on a single bare word: the `.com` address for it, or nil when the text is anything else (spaces, a dot, a path, a scheme, a port).
    static func dotCom(_ text: String) -> String? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 63 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard word.unicodeScalars.allSatisfy({ allowed.contains($0) }), !word.hasPrefix("-"), !word.hasSuffix("-") else { return nil }
        return "www.\(word.lowercased()).com"
    }
}
