import SwiftUI

// The pieces the library panels (Bookmarks, History, Downloads and their kin) are built from, so they share one structure: a header with the
// title, a count and a search field; filter chips; sections as cards that fold; rows that light up under the pointer; and a real empty state.

/// The top of a panel: what it is, how many things are in it, a search field, and the panel's own actions at the end.
struct PanelHeader<Actions: View>: View {
    let symbol: String
    let title: String
    var count: Int?
    @Binding var query: String
    var prompt = "Search"
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    if let count { Text(count == 1 ? "1 item" : "\(count) items").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                actions
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField(prompt, text: $query).textFieldStyle(.plain).font(.system(size: 13.5))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
    }
}

/// A row of filters as capsules, each with how many things it holds.
struct PanelChips<Choice: Hashable & Identifiable>: View {
    let choices: [Choice]
    @Binding var selection: Choice
    let title: (Choice) -> String
    var count: ((Choice) -> Int)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(choices) { choice in
                    let on = choice == selection
                    Button { animated(.easeOut(duration: 0.18)) { selection = choice } } label: {
                        HStack(spacing: 5) {
                            Text(title(choice)).font(.system(size: 12, weight: on ? .semibold : .regular))
                            if let count, count(choice) > 0 { Text("\(count(choice))").font(.system(size: 11)).foregroundStyle(on ? Theme.accent.opacity(0.8) : Color.secondary) }
                        }
                        .padding(.horizontal, 12).frame(height: 28)
                        .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.8))
                        .background(Capsule().fill(on ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.07)))
                        .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.35) : Color.clear, lineWidth: 0.75))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 6)
    }
}

/// A group of rows on one card, with a heading that can fold it away.
struct PanelSection<Content: View>: View {
    let title: String
    var symbol: String?
    var count: Int?
    var collapsible = true
    @State private var open = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard collapsible else { return }
                animated(.easeOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 7) {
                    if collapsible { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0)) }
                    if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.accent) }
                    Text(title).font(.system(size: 12, weight: .semibold)).tracking(0.5).textCase(.uppercase).foregroundStyle(.secondary)
                    if let count { Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            if open {
                VStack(spacing: 0) { content }
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ThemeState.raised?.opacity(0.55) ?? Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
    }
}

/// One row: something at the start, a title and a line under it, and things at the end that appear when the pointer is over it.
struct PanelRow<Leading: View, Trailing: View>: View {
    let title: String
    var detail: String?
    var tags: [String] = []
    /// One line, title then host, for long lists such as History.
    var compact = false
    var action: (() -> Void)?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 12) {
                leading
                if compact {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1).fixedSize()
                            if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
                        }
                        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                    }
                } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 6) {
                        if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            Text("#" + tag).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.accent.opacity(0.12)))
                        }
                    }
                }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 12).padding(.vertical, compact ? 5 : 9)
            .background(Color.primary.opacity(hovering ? 0.06 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.12), value: hovering)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5).padding(.leading, 54) }
    }
}

/// The same row's end buttons, shown on hover on a Mac and always on a phone.
struct PanelActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 6) { content }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

struct PanelEmpty: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent.opacity(0.8))
            Text(title).font(.system(size: 16, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
        .accessibilityElement(children: .combine)
    }
}

/// The scrolling body every panel shares: sections with room between them and at the foot.
struct PanelBody<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.panelFitsContent) private var fits
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) { content }.padding(.vertical, 8).padding(.bottom, 20)
                .background(GeometryReader { geo in Color.clear.preference(key: PanelContentHeight.self, value: geo.size.height) })
        }
        .scrollIndicators(.hidden)
        .onPreferenceChange(PanelContentHeight.self) { contentHeight = $0 }
        // In a floating card the list is only as tall as its rows, so no empty area is left under them.
        .frame(maxHeight: fits ? (contentHeight ?? .infinity) : .infinity)
    }
}

private struct PanelContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PanelFitsContentKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var panelFitsContent: Bool {
        get { self[PanelFitsContentKey.self] }
        set { self[PanelFitsContentKey.self] = newValue }
    }
}

/// Keeps a heavy view invisible for the first moments, until its layout has settled, then fades it in. Without it the rows show
/// loose in the air while the cards and groups around them are still being laid out.
struct SettlesBeforeShowing: ViewModifier {
    @State private var ready = false
    func body(content: Content) -> some View {
        content
            .opacity(ready ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(70))
                animated(.easeOut(duration: 0.16)) { ready = true }
            }
    }
}

extension View {
    func settlesBeforeShowing() -> some View { modifier(SettlesBeforeShowing()) }
}
