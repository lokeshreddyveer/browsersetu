import Foundation

/// Typed commands in the address bar: "/tabs mail", "/find invoice", "/save morning". They only appear after a slash, so ordinary typing is not affected.
enum SlashCommand: String, CaseIterable, Identifiable {
    case tabs, close, find, group, sleep, duplicates, save, open, workspace, forget, privateTab = "private", scratch, note, split, restore

    var id: String { rawValue }

    var usage: String {
        switch self {
        case .tabs: "/tabs <words>"
        case .close: "/close <words>"
        case .find: "/find <words>"
        case .group: "/group <name or site>"
        case .sleep: "/sleep"
        case .duplicates: "/duplicates"
        case .save: "/save <name>"
        case .open: "/open <name>"
        case .workspace: "/workspace <name>"
        case .forget: "/forget"
        case .privateTab: "/private <address>"
        case .scratch: "/scratch"
        case .note: "/note <text>"
        case .split: "/split <words>"
        case .restore: "/restore"
        }
    }

    var summary: String {
        switch self {
        case .tabs: "Switch to an open tab by its title or address"
        case .close: "Close every tab that matches"
        case .find: "Search the text of every open tab, asleep ones too"
        case .group: "Move this tab to a group, or type “site” to group all tabs by website"
        case .sleep: "Put every other tab to sleep"
        case .duplicates: "Close the extra copies of pages open twice"
        case .save: "Save the open tabs as a named session"
        case .open: "Open a saved session"
        case .workspace: "Switch to a workspace"
        case .forget: "Forget this site completely"
        case .privateTab: "Open an address in a private tab"
        case .scratch: "Open a scratch tab that leaves nothing behind"
        case .note: "Add a note to this page"
        case .split: "Open a tab beside this one"
        case .restore: "Put the window layout back to standard"
        }
    }

    /// Commands that do something with what follows the name.
    var takesText: Bool {
        switch self { case .sleep, .duplicates, .forget, .scratch, .restore: false; default: true }
    }
}

enum SlashParse: Equatable {
    /// Not a command at all: the text is searched or opened as usual.
    case notACommand
    /// The command word is not finished: these are the commands that begin with it.
    case choosing([SlashCommand])
    /// A whole command name was typed, with whatever followed it.
    case command(SlashCommand, argument: String)

    /// "/" alone lists every command. A word that matches no command is not treated as one, so a path such as "/Users/me" still works as an address.
    static func parse(_ text: String) -> SlashParse {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return .notACommand }
        let body = trimmed.dropFirst()
        let word = String(body.prefix { !$0.isWhitespace }).lowercased()
        let rest = String(body.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
        if word.isEmpty { return rest.isEmpty ? .choosing(SlashCommand.allCases) : .notACommand }
        if let exact = SlashCommand(rawValue: word) { return .command(exact, argument: rest) }
        if let alias = aliases[word] { return .command(alias, argument: rest) }
        guard rest.isEmpty else { return .notACommand }
        let matches = SlashCommand.allCases.filter { $0.rawValue.hasPrefix(word) }
        return matches.isEmpty ? .notACommand : .choosing(matches)
    }

    static let aliases: [String: SlashCommand] = ["t": .tabs, "tab": .tabs, "x": .close, "f": .find, "g": .group, "dupes": .duplicates, "ws": .workspace, "p": .privateTab, "session": .open, "layout": .restore]
}

/// Which tabs match words typed after a command. All the words must appear, in the title or the address.
enum TabMatch {
    /// Every typed word must be in the title or address, allowing a slip of the keys in the longer ones.
    static func matches(title: String, url: String, words: String) -> Bool {
        let terms = words.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = (title + " " + url).lowercased()
        if terms.allSatisfy({ haystack.contains($0) }) { return true }
        return FuzzyText.matches(words, in: title + " " + url)
    }
}

/// A short piece of text around the first place a word occurs, for showing why a tab matched.
enum TextSnippet {
    static func make(in text: String, around word: String, radius: Int = 48) -> String? {
        guard !word.isEmpty, let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        return make(in: text, range: range, radius: radius)
    }

    static func make(in text: String, range: Range<String.Index>, radius: Int = 48) -> String {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var piece = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        while piece.contains("  ") { piece = piece.replacingOccurrences(of: "  ", with: " ") }
        return (start > text.startIndex ? "…" : "") + piece.trimmingCharacters(in: .whitespaces) + (end < text.endIndex ? "…" : "")
    }
}
