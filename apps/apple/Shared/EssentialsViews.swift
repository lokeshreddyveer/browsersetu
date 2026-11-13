import SwiftUI

/// The name of the coordinate space every scrolling tab list declares, so the row of the tab in front can be located (see `TabVisibilityCoordinator`).
enum TabListSpace { static let name = "tabList" }

/// The Essentials as a grid of icon tiles, above the pinned tiles and the tab rows. Nothing is drawn when there are none. Used by the Mac sidebars and by the
/// iPhone's tab overview.
struct EssentialsGrid: View {
    @EnvironmentObject var model: BrowserModel
    var tileHeight: CGFloat = 44
    var minimumTile: CGFloat = 40
    /// A thin line under the grid, where it sits above other tiles or rows (the sections of the Sidebar layout have headings instead).
    var separator = true
    /// Called after an Essential was opened (the overview closes itself).
    var didOpen: (() -> Void)?

    var body: some View {
        if !model.isGuest, !model.essentials.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTile, maximum: minimumTile + 22), spacing: 6)], spacing: 6) {
                ForEach(model.essentials) { essential in
                    EssentialTile(essential: essential, height: tileHeight, didOpen: didOpen)
                }
            }
            .padding(.bottom, separator ? 6 : 0)
            .transition(.opacity)
            .motion(.easeOut(duration: 0.18), value: model.essentials.map(\.id))
            if separator { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 4).padding(.bottom, 6) }
        }
    }
}

/// The Essentials as a short row (or column) of small icons, for the places that draw the tab list in a line: the top tab strips, the icon rail, One Row, the iPad
/// ribbon and the iPhone's landscape row. Without it an Essential would vanish from those layouts the moment it was added.
struct EssentialsInline: View {
    @EnvironmentObject var model: BrowserModel
    var size: CGFloat = 28
    var vertical = false

    var body: some View {
        if !model.isGuest, !(model.separatesPrivate && model.privateMode), !model.essentials.isEmpty {
            Group {
                if vertical {
                    VStack(spacing: 4) { tiles }
                } else {
                    HStack(spacing: 3) { tiles; Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 0.5, height: size * 0.6).padding(.horizontal, 3) }
                }
            }
            .transition(.opacity)
            .motion(.easeOut(duration: 0.18), value: model.essentials.map(\.id))
        }
    }

    private var tiles: some View {
        ForEach(model.essentials) { EssentialTile(essential: $0, height: size, width: size) }
    }
}

struct EssentialTile: View {
    @EnvironmentObject var model: BrowserModel
    let essential: EssentialTab
    let height: CGFloat
    /// A fixed width for the small tiles in a line; nil lets the tile fill its cell in a grid.
    var width: CGFloat?
    var didOpen: (() -> Void)?
    @State private var hovering = false
    @FocusState private var focused: Bool
    @State private var ringShown = false

    private func open() { model.openEssential(essential.id); didOpen?() }

    private var live: TabController? { model.liveTab(for: essential) }
    private var selected: Bool { live.map { $0.id == model.activeID } ?? false }
    private var asleep: Bool { live == nil || live?.isDiscarded == true }

    var body: some View {
        SiteTile(url: essential.url, title: essential.title, size: width == nil ? 22 : max(14, (width ?? 28) * 0.62))
            .opacity(asleep ? 0.55 : 1)
            .frame(maxWidth: width == nil ? .infinity : width).frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.24) : Color.primary.opacity(hovering ? 0.11 : 0.06)))
            .overlay(alignment: .bottomTrailing) { if let live { EssentialStatus(tab: live) } }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .trackedWhenSelected(selected, in: TabListSpace.name)
            .motion(.easeOut(duration: 0.14), value: hovering)
            .motion(.easeOut(duration: 0.16), value: selected)
            .onHover { hovering = $0 }
            .onTapGesture { open() }
            // Reachable from the keyboard (Full Keyboard Access, Tab) and by VoiceOver: Return and Space open it, and a ring shows where the keyboard is.
            .focusable().focusEffectDisabled().focused($focused)
            .onKeyPress(.return) { open(); return .handled }
            .onKeyPress(.space) { open(); return .handled }
            .onChange(of: focused) { _, now in
                #if os(macOS)
                guard now, let type = NSApp.currentEvent?.type else { return }
                if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown].contains(type) { ringShown = false }
                else if [.keyDown, .keyUp, .flagsChanged].contains(type) { ringShown = true }
                #else
                if now { ringShown = true }
                #endif
            }
            // The ring is for the keyboard; a tile that took focus from a click shows none.
            .overlay { if focused && ringShown { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1.5).allowsHitTesting(false) } }
            .accessibilityAction { open() }
            .help(essential.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(essential.title), Essential")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .draggable("essential:" + essential.id)
            .dropDestination(for: String.self) { items, _ in drop(items) }
            .contextMenu { menu }
    }

    /// An Essential dropped here is put at this place; a tab dropped here becomes an Essential.
    private func drop(_ items: [String]) -> Bool {
        guard let raw = items.first else { return false }
        if raw.hasPrefix("essential:") {
            let id = String(raw.dropFirst("essential:".count))
            guard let target = model.essentials.firstIndex(where: { $0.id == essential.id }) else { return false }
            model.moveEssential(id, to: target)
            return true
        }
        guard let tabID = UInt64(raw), let tab = model.tabs.first(where: { $0.id == tabID }) else { return false }
        return model.addToEssentials(tab)
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { model.openEssential(essential.id); didOpen?() }
        #if os(macOS)
        Button("Open in New Window") { model.openEssentialInNewWindow(essential.id) }
        #endif
        if let live, !live.isDiscarded {
            Button("Reload") { live.reload() }
            if live.id != model.activeID { Button("Unload") { live.discard(reason: "you unloaded this Essential") } }
        }
        Button("Copy Link") { copyToPasteboard(essential.url) }
        Divider()
        let index = model.essentials.firstIndex(where: { $0.id == essential.id }) ?? 0
        Button("Move Earlier") { model.moveEssential(essential.id, by: -1) }.disabled(index == 0)
        Button("Move Later") { model.moveEssential(essential.id, by: 1) }.disabled(index >= model.essentials.count - 1)
        Divider()
        Button("Remove from Essentials", role: .destructive) { model.removeFromEssentials(essential.id) }
    }
}

/// A small mark on an Essential whose page is working: loading, or using the camera or microphone.
private struct EssentialStatus: View {
    @ObservedObject var tab: TabController

    var body: some View {
        Group {
            if tab.usesCamera || tab.usesMicrophone {
                Circle().fill(Color.red).frame(width: 7, height: 7)
            } else if tab.isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
            } else if tab.playingAudio {
                Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 7)).foregroundStyle(.secondary)
            }
        }
        .padding(3)
        .accessibilityHidden(true)
    }
}
