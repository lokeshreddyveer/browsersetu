import SwiftUI

/// A small button on the top or bottom edge of a tab list, shown only while the tab in front is scrolled out of sight. It points the way, shows that tab's icon,
/// and scrolls the list to it when pressed. It never changes which tab is selected.
struct TabLocatorOverlay: ViewModifier {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var coordinator: TabVisibilityCoordinator
    let reveal: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { if coordinator.location == .above { button(up: true).padding(.top, 6) } }
            .overlay(alignment: .bottom) { if coordinator.location == .below { button(up: false).padding(.bottom, 6) } }
            .motion(.easeOut(duration: 0.18), value: coordinator.location)
    }

    private func button(up: Bool) -> some View {
        Button(action: reveal) {
            HStack(spacing: 6) {
                Image(systemName: up ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                if let tab = model.active { SiteTile(url: tab.url?.absoluteString ?? "", title: tab.displayTitle, size: 16) }
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.move(edge: up ? .top : .bottom).combined(with: .opacity))
        .help(up ? "Show the current tab (above)" : "Show the current tab (below)")
        .accessibilityLabel(up ? "Scroll up to the current tab" : "Scroll down to the current tab")
    }
}

extension View {
    func tabLocator(_ coordinator: TabVisibilityCoordinator, reveal: @escaping () -> Void) -> some View {
        modifier(TabLocatorOverlay(coordinator: coordinator, reveal: reveal))
    }
}
