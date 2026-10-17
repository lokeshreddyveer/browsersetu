import SwiftUI

/// Arranging a row of buttons by hand: drag one from the tray into the row to add it, side to side to reorder it, or out of the row to take it away.
/// The same panel arranges the sidebar's buttons and the address bar's; nothing needs the settings window.
struct ButtonArranger<Item: Hashable & Identifiable & RawRepresentable>: View where Item.RawValue == String {
    /// Names what is being dragged, so a button from one row is never dropped into another.
    let kind: String
    let heading: String
    @Binding var items: [Item]
    let all: [Item]
    let defaults: [Item]
    let title: (Item) -> String
    let symbol: (Item) -> String
    @Environment(\.dismiss) private var dismiss
    @State private var overRow = false
    @State private var overTray = false

    private var available: [Item] { all.filter { !items.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(heading).font(.system(size: 15, weight: .semibold))
                Text("Drag buttons into the row, side to side to reorder them, or back out of it to take them away.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            label("In the row")
            row
                .dropDestination(for: String.self) { payload, _ in
                    guard let dragged = payload.first.flatMap(item(from:)) else { return false }
                    place(dragged, before: nil)
                    return true
                } isTargeted: { overRow = $0 }

            label("Available")
            tray
                .dropDestination(for: String.self) { payload, _ in
                    guard let dragged = payload.first.flatMap(item(from:)) else { return false }
                    remove(dragged)
                    return true
                } isTargeted: { overTray = $0 }

            HStack {
                Button("Reset to Default") { animated(.easeOut(duration: 0.2)) { items = defaults } }.disabled(items == defaults)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
    }

    private var row: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if items.isEmpty { Text("Drop buttons here").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 8) }
                ForEach(items) { item in
                    chip(item, inRow: true)
                        .dropDestination(for: String.self) { payload, _ in
                            guard let dragged = payload.first.flatMap(self.item(from:)) else { return false }
                            place(dragged, before: item)
                            return true
                        }
                }
            }
            .padding(10)
        }
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(overRow ? 0.16 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(overRow ? 0.7 : 0.25), style: StrokeStyle(lineWidth: 1, dash: overRow ? [] : [5, 4])))
        .motion(.easeOut(duration: 0.15), value: overRow)
    }

    private var tray: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            if available.isEmpty { Text("Every button is in the row.").font(.system(size: 12)).foregroundStyle(.tertiary) }
            ForEach(available) { item in chip(item, inRow: false) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(overTray ? 0.10 : 0.04)))
        .motion(.easeOut(duration: 0.15), value: overTray)
    }

    private func chip(_ item: Item, inRow: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(item)).font(.system(size: 11, weight: .medium)).foregroundStyle(inRow ? Theme.accent : Color.secondary)
            Text(title(item)).font(.system(size: 12)).lineLimit(1)
            // Dragging is the way; a click does the same for anyone who cannot drag.
            Button { animated(.easeOut(duration: 0.2)) { if inRow { items.removeAll { $0 == item } } else { items.append(item) } } } label: {
                Image(systemName: inRow ? "xmark" : "plus").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).accessibilityLabel(inRow ? "Remove \(title(item))" : "Add \(title(item))")
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(Capsule().fill(Color.primary.opacity(inRow ? 0.10 : 0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .draggable("\(kind):\(item.rawValue)") {
            HStack(spacing: 6) { Image(systemName: symbol(item)); Text(title(item)) }
                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 30)
                .background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1.5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title(item))
    }

    private func item(from payload: String) -> Item? {
        guard payload.hasPrefix(kind + ":") else { return nil }
        let raw = String(payload.dropFirst(kind.count + 1))
        return all.first { $0.rawValue == raw }
    }

    private func place(_ dragged: Item, before target: Item?) {
        animated(.easeOut(duration: 0.2)) {
            var list = items
            list.removeAll { $0 == dragged }
            if let target, let index = list.firstIndex(of: target) { list.insert(dragged, at: index) } else { list.append(dragged) }
            items = list
        }
    }

    private func remove(_ dragged: Item) { animated(.easeOut(duration: 0.2)) { items.removeAll { $0 == dragged } } }
}
