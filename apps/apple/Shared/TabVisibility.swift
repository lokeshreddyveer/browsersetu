import SwiftUI

/// Where the tab in front is, relative to the part of a scrolling tab list that can be seen.
enum TabLocation: Equatable {
    case visible, above, below
}

/// Follows one thing only, the tab in front, in one scrolling tab list, and says whether it is out of sight and on which side. It publishes a change only when
/// that answer changes, never on each scroll step, so scrolling the list does not redraw the list.
/// The same answer drives the small "find my tab" indicator at the edge of the list and its scroll-to-tab action.
@MainActor
final class TabVisibilityCoordinator: ObservableObject {
    @Published private(set) var location: TabLocation = .visible

    private var frame: CGRect?
    private var viewportHeight: CGFloat = 0

    /// The share of the row that must be inside the list to count as seen.
    nonisolated static let shownFraction: CGFloat = 0.5

    /// Pure: where a row at `frame` (in the list's own coordinates, 0 at the top of what is shown) is, given the list's height. A row not measured yet, or a
    /// list with no height yet, is treated as seen.
    nonisolated static func location(of frame: CGRect?, viewportHeight: CGFloat) -> TabLocation {
        guard let frame, viewportHeight > 0, frame.height > 0 else { return .visible }
        let visibleHeight = min(frame.maxY, viewportHeight) - max(frame.minY, 0)
        if visibleHeight >= frame.height * shownFraction { return .visible }
        return frame.midY < viewportHeight / 2 ? .above : .below
    }

    /// The tab in front was measured (nil: it is not in this list at the moment).
    func selectedFrameChanged(_ new: CGRect?) {
        frame = new
        refresh()
    }

    func viewportChanged(_ height: CGFloat) {
        viewportHeight = height
        refresh()
    }

    private func refresh() {
        let now = Self.location(of: frame, viewportHeight: viewportHeight)
        if now != location { location = now }
    }
}

/// The frame of the marked row in the list's coordinate space, or nil when no row is marked.
struct SelectedTabFrameKey: PreferenceKey {
    static var defaultValue: CGRect? { nil }
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

struct ListViewportKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Marks this row as the tab in front, so the list can tell whether it is in view. Costs nothing on the other rows.
    func trackedWhenSelected(_ selected: Bool, in space: String) -> some View {
        background {
            if selected {
                GeometryReader { proxy in Color.clear.preference(key: SelectedTabFrameKey.self, value: proxy.frame(in: .named(space))) }
            }
        }
    }

    /// Reports the list's height and the tab in front's position to a coordinator.
    func tracksTabVisibility(_ coordinator: TabVisibilityCoordinator, in space: String) -> some View {
        coordinateSpace(name: space)
            .background(GeometryReader { proxy in Color.clear.preference(key: ListViewportKey.self, value: proxy.size.height) })
            .onPreferenceChange(ListViewportKey.self) { coordinator.viewportChanged($0) }
            .onPreferenceChange(SelectedTabFrameKey.self) { coordinator.selectedFrameChanged($0) }
    }
}
