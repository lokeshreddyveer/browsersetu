import SwiftUI

/// The iPad's tab overview: a title with the tab count, a Tabs / Private switch, large cards in a roomy grid, and two big pills to add a
/// tab or leave. Cards come from the same `TabCard` the other platforms use, so previews, closing and the long-press menu all work.
struct IPadTabOverview: View {
    @EnvironmentObject var model: BrowserModel
    @State private var query = ""

    private var tabs: [TabController] {
        query.isEmpty ? model.visibleTabs : model.visibleTabs.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) || ($0.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(tabs.count == 1 ? "1 Tab" : "\(tabs.count) Tabs").font(.system(size: 26, weight: .bold))
                Picker("", selection: Binding(get: { model.privateMode }, set: { switchMode(private: $0) })) {
                    Text("Tabs").tag(false)
                    Text("Private").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 200)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Tabs", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear") }
                }
                .padding(.horizontal, 12).frame(height: 40).frame(maxWidth: 300)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                Spacer()
                pill("New Tab", symbol: "plus", tinted: true) { model.newTab(); model.hideOverview() }
                pill("Done", symbol: nil, tinted: false) { model.hideOverview() }
            }
            .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 14)

            ScrollView {
                if tabs.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No Tabs" : "No Matching Tabs", systemImage: "square.on.square").padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 20)], spacing: 22) {
                        ForEach(tabs) { tab in TabCard(tab: tab, selected: tab.id == model.activeID) }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)
                    .motion(.spring(response: 0.34, dampingFraction: 0.86), value: tabs.map(\.id))
                }
            }
            Text("Press and hold a card for more. Tap the cross to close it.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.bottom, 16)
        }
        .background(ThemeState.animated ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial))
        .background((ThemeState.chrome ?? Color(.systemBackground)).opacity(ThemeState.animated ? 0.35 : 0.6))
    }

    private func pill(_ title: String, symbol: String?, tinted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .bold)) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 20).frame(height: 44)
            .foregroundStyle(tinted ? Theme.accent : Color.primary)
            .background(Capsule().fill(tinted ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func switchMode(private isPrivate: Bool) {
        model.privateMode = isPrivate
        if let first = model.visibleTabs.first { model.select(first.id) } else { model.openTab(url: nil, isPrivate: isPrivate) }
    }
}
