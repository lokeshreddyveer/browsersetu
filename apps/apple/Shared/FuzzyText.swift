import Foundation

/// Searching text that forgives a slip of the keys: "githb" finds "GitHub", "recieve" finds "receive", "kubernetes cluser" finds a page about a cluster of Kubernetes.
/// Pure and local; nothing is sent anywhere.
enum FuzzyText {
    /// How well a page matched, best first.
    enum Grade: Int, Comparable {
        /// The words were found as typed, one after another.
        case phrase = 0
        /// Every word was found (as typed, or the start of a longer word), though not together.
        case words = 1
        /// Every word was found, at least one of them with a letter wrong, missing, extra or swapped.
        case close = 2
        static func < (a: Grade, b: Grade) -> Bool { a.rawValue < b.rawValue }
    }

    struct Match: Equatable {
        var grade: Grade
        /// Where in the text to look: the first place the first word was found.
        var range: Range<String.Index>
        /// The text found there, as the page spells it. Differs from what was typed for a close match.
        var found: String
    }

    struct Word: Equatable {
        var text: String                    // lower case, accents removed
        var range: Range<String.Index>
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// The words of a text: runs of letters and digits, folded, with where each one is. Words over 40 characters (addresses, hashes) are skipped.
    static func words(in text: String, limit: Int = 80_000) -> [Word] {
        var out: [Word] = []
        var start: String.Index?
        var i = text.startIndex
        func close(_ end: String.Index) {
            guard let s = start else { return }
            start = nil
            if text.distance(from: s, to: end) <= 40 { out.append(Word(text: fold(String(text[s..<end])), range: s..<end)) }
        }
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber { if start == nil { start = i } } else { close(i) }
            i = text.index(after: i)
            if out.count >= limit { return out }
        }
        close(text.endIndex)
        return out
    }

    /// How many slips a word of this length may have: none for very short words, one for ordinary ones, two for long ones.
    static func tolerance(forLength n: Int) -> Int { n <= 3 ? 0 : (n <= 6 ? 1 : 2) }

    /// Edit distance where a swap of two neighbouring letters counts as one slip; nil as soon as it must exceed `limit`.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int? {
        if abs(a.count - b.count) > limit { return nil }
        if a.isEmpty { return b.count <= limit ? b.count : nil }
        if b.isEmpty { return a.count <= limit ? a.count : nil }
        var twoBack = [Int](repeating: 0, count: b.count + 1)
        var back = Array(0...b.count)
        var row = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            row[0] = i
            var best = row[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(back[j] + 1, row[j - 1] + 1, back[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { value = min(value, twoBack[j - 2] + 1) }
                row[j] = value
                best = min(best, value)
            }
            if best > limit { return nil }
            twoBack = back; back = row
        }
        let d = back[b.count]
        return d <= limit ? d : nil
    }

    /// Where one typed word is in a page's words: the first exact or start-of-word hit, or else the closest spelling. Nil when nothing is near.
    private static func find(_ term: String, in words: [Word]) -> (index: Int, close: Bool)? {
        let limit = tolerance(forLength: term.count)
        let chars = Array(term)
        var nearest: (index: Int, distance: Int)?
        for (index, word) in words.enumerated() {
            if word.text == term { return (index, false) }
            if term.count >= 3, word.text.hasPrefix(term) { return (index, false) }
            guard limit > 0, abs(word.text.count - term.count) <= limit else { continue }
            if let d = distance(chars, Array(word.text), limit: limit), nearest == nil || d < nearest!.distance { nearest = (index, d) }
        }
        return nearest.map { ($0.index, true) }
    }

    static func match(_ query: String, in text: String) -> Match? {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let range = text.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) {
            return Match(grade: .phrase, range: range, found: String(text[range]))
        }
        let terms = words(in: typed).map(\.text)
        guard !terms.isEmpty else { return nil }
        let page = words(in: text)
        guard !page.isEmpty else { return nil }
        var grade = Grade.words
        var first: Word?
        for (n, term) in terms.enumerated() {
            guard let hit = find(term, in: page) else { return nil }
            if hit.close { grade = .close }
            if n == 0 { first = page[hit.index] }
        }
        guard let first else { return nil }
        return Match(grade: grade, range: first.range, found: String(text[first.range]))
    }

    /// For a short text such as a tab's title and address: does every typed word occur in it, allowing the slips above?
    static func matches(_ words: String, in haystack: String) -> Bool {
        let terms = Self.words(in: words).map(\.text)
        guard !terms.isEmpty else { return true }
        let folded = fold(haystack)
        let page = Self.words(in: haystack)
        return terms.allSatisfy { folded.contains($0) || find($0, in: page) != nil }
    }
}
