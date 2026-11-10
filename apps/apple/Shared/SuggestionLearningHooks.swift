import Foundation

@MainActor
extension BrowserModel {
    /// Whether anything about this tab may be learned: learning is on, and it is not a private tab, a scratch tab or a guest window.
    private func mayLearn(from tab: TabController?) -> Bool {
        guard learnSuggestions, !isGuest else { return false }
        if let tab { return !tab.leavesNoTrace }
        return active.map { !$0.leavesNoTrace } ?? true
    }

    /// A page finished loading in a tab: one more visit to that destination, in the workspace it was opened in.
    func learnVisit(_ tab: TabController, url: URL) {
        guard mayLearn(from: tab), SuggestionPrivacy.isLearnable(url, excludedHosts: suggestionExcludedHosts) else { return }
        suggestionLearning.recordVisit(key: SuggestionPrivacy.key(for: url), workspace: isEssentialTab(tab) ? activeWorkspace : tab.workspace)
    }

    /// A result was chosen under the address bar: remember what was typed and which result it led to. Rows made from the typed text itself (Go to, Search for,
    /// the engine's suggestions) teach nothing about a destination, so only the other rows are kept.
    func learnChoice(_ suggestion: Suggestion, typed: String) {
        guard mayLearn(from: nil) else { return }
        switch suggestion.kind {
        case .command:
            // Both spellings of a slash command ("slash:" completions and "slash-<word>" rows): what was typed after them (/private secret, /note text) must not be learned.
            guard !suggestion.target.hasPrefix("quick-answer-"), !suggestion.target.hasPrefix("slash") else { return }
            suggestionLearning.recordSelection(key: "cmd:" + suggestion.target, query: typed, workspace: activeWorkspace)
        case .openTab, .bookmark, .history, .page, .go:
            guard let url = URL(string: suggestion.target), SuggestionPrivacy.isLearnable(url, excludedHosts: suggestionExcludedHosts) else { return }
            suggestionLearning.recordSelection(key: SuggestionPrivacy.key(for: url), query: typed, workspace: activeWorkspace)
        case .search, .suggestion:
            return
        }
    }

    /// Forgets everything the address bar learned in this profile.
    func resetLearnedSuggestions() {
        suggestionLearning.reset()
        notice = "The address bar forgot what it had learned."
    }
}
