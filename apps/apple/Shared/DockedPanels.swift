import SwiftUI

/// Bookmarks, History or Downloads beside the page. The page keeps its place and shrinks; the edge between them drags to resize.
struct DockedPanelView: View {
    @EnvironmentObject var model: BrowserModel
    let sheet: Sheet
    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                .overlay {
                    Color.clear.frame(width: 9).contentShape(Rectangle())
                        #if os(macOS)
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        #endif
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? model.dockWidth
                                dragStart = start
                                model.dockWidth = min(560, max(300, start - value.translation.width))
                            }
                            .onEnded { _ in dragStart = nil })
                }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    #if os(macOS)
                    PanelPill(symbol: "macwindow", label: "Show as a floating card from now on") {
                        animated(.easeOut(duration: 0.2)) { model.panelMode = .float; model.dockedPanel = nil; model.sheet = sheet }
                    }
                    #endif
                    PanelPill(symbol: "xmark", label: "Close") { model.dockedPanel = nil }.keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 2)
                NavigationStack {
                    Group {
                        switch sheet {
                        case .bookmarks: BookmarksPanel()
                        case .history: HistoryPanel()
                        case .downloads: DownloadsPanel(coordinator: model.downloads)
                        default: EmptyView()
                        }
                    }
                    .tint(Theme.accent)
                }
                .settlesBeforeShowing()
            }
            .themedSurface()
            .frame(width: model.dockWidth)
        }
        .chromeFill()
    }
}



/// The small round buttons at the top of a library panel.
struct PanelPill: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26).background(Circle().fill(Color.primary.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.12), value: hovering)
    }
}


