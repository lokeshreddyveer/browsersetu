import SwiftUI

/// Type a word or phrase; every open tab that contains it is listed. Choosing one switches to that tab and finds the text there.
struct FindInAllTabsView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [TabController] = []
    @State private var searched = 0
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var candidates: [TabController] { model.tabs.filter { $0.isPrivate == model.activeIsPrivate && $0.hasLoadedPage } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in all open tabs", text: $query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { run() }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()
            List {
                if !query.isEmpty && !searching && hits.isEmpty {
                    Text("No open tab contains “\(query)”.").foregroundStyle(.secondary)
                }
                ForEach(hits) { tab in
                    Button { open(tab) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tab.displayTitle).lineLimit(1)
                            Text(displayHost(tab.url)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !query.isEmpty && !searching {
                    Text("Searched \(searched) loaded tab\(searched == 1 ? "" : "s"). Tabs that are asleep are not searched.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: query) { _, _ in run() }
        .onAppear { focused = true }
        .accessibilityIdentifier("find-all-tabs")
    }

    private func run() {
        task?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { hits = []; searched = 0; searching = false; return }
        searching = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let tabs = candidates
            var found: [TabController] = []
            for tab in tabs {
                if Task.isCancelled { return }
                if await tab.engine.find(text, backwards: false) { found.append(tab) }
                tab.engine.clearFind()
            }
            guard !Task.isCancelled else { return }
            hits = found; searched = tabs.count; searching = false
        }
    }

    private func open(_ tab: TabController) {
        let text = query
        model.select(tab.id)
        dismiss()
        model.sheet = nil
        model.showFind()
        model.findText = text
        model.findNext()
    }
}
