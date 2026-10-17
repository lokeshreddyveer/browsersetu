import SwiftUI

/// A list inside Settings that shows its first few rows and ends with "Show 12 More" / "Show Less", so a long list never pushes everything below it out of reach.
struct ShowMoreRows<Element, ID: Hashable, Row: View>: View {
    let items: [Element]
    let id: KeyPath<Element, ID>
    var limit = 5
    @ViewBuilder let row: (Element) -> Row
    @State private var expanded = false

    init(_ items: [Element], id: KeyPath<Element, ID>, limit: Int = 5, @ViewBuilder row: @escaping (Element) -> Row) {
        self.items = items; self.id = id; self.limit = limit; self.row = row
    }

    var body: some View {
        ForEach(expanded ? items : Array(items.prefix(limit)), id: id) { row($0) }
        if items.count > limit {
            Button {
                animated(.easeOut(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(expanded ? "Show Less" : "Show \(items.count - limit) More")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(expanded ? "Show fewer" : "Show \(items.count - limit) more")
        }
    }
}

extension ShowMoreRows where Element: Identifiable, ID == Element.ID {
    init(_ items: [Element], limit: Int = 5, @ViewBuilder row: @escaping (Element) -> Row) {
        self.init(items, id: \.id, limit: limit, row: row)
    }
}
