import SwiftUI

/// Type a word or phrase; every open tab that contains it is listed, tabs that are asleep included. Choosing one switches to that tab and finds the text there.
struct FindInAllTabsView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [TabTextHit] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

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
                ForEach(hits) { hit in
                    Button { open(hit) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(hit.title).lineLimit(1); if hit.close { Text("similar").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.secondary.opacity(0.18))) }; if hit.asleep { Image(systemName: "moon.zzz").font(.caption).foregroundStyle(.secondary) } }
                            Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(hit.host).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !query.isEmpty && !searching {
                    Text(model.indexPages ? "Tabs that are asleep are looked up in the saved copy of pages you read, so they are not woken."
                                          : "Tabs that are asleep are only searched by title and address. Turn on “Searchable copy of pages” to search their text too.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: query) { _, _ in run() }
        .onAppear { focused = true; if let start = model.findAllPrefill { query = start; model.findAllPrefill = nil } }
        .accessibilityIdentifier("find-all-tabs")
    }

    private func run() {
        task?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { hits = []; searching = false; return }
        searching = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.searchTabText(text)
            guard !Task.isCancelled else { return }
            hits = found; searching = false
        }
    }

    private func open(_ hit: TabTextHit) {
        let text = query
        model.select(hit.tabID)
        dismiss()
        model.sheet = nil
        if !hit.asleep { model.showFind(); model.findText = hit.found.isEmpty ? text : hit.found; model.findNext() }
    }
}
