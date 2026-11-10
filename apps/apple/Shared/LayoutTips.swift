import SwiftUI

/// A few plain steps shown once per layout: on a new install (including one made after an uninstall, which starts with nothing saved) and the first time a layout is chosen.
struct LayoutTip {
    let symbol: String
    let steps: [String]
    /// What the hands can do in this layout; the edge swipes belong to the page and are the same in all of them.
    var gestures: [String] { Self.gestures(for: preset) }
    var preset: PhonePreset = .bottomBar

    static func gestures(for preset: PhonePreset) -> [String] {
        let edges = "Swipe in from the left edge of the screen to go back, from the right edge to go forward."
        switch preset {
        case .bottomBar, .topBar, .compactBottom, .compactTop, .custom:
            return [edges, "Swipe the address left or right to move to the next or previous tab.", "Swipe the address up to see all your tabs.", "Press and hold the address for the menu."]
        case .immersive:
            return [edges, "Swipe the small pill left or right to move to the next or previous tab.", "Swipe the pill up to bring back the whole bar.", "Press and hold the pill for the menu."]
        }
    }

    static func tip(for preset: PhonePreset) -> LayoutTip {
        var tip = base(for: preset); tip.preset = preset; return tip
    }

    private static func base(for preset: PhonePreset) -> LayoutTip {
        switch preset {
        case .bottomBar:
            LayoutTip(symbol: "rectangle.bottomthird.inset.filled", steps: [
                "The address sits in a glass card at the bottom, with your buttons under it.",
                "Tap the address to type or search.",
                "Scroll down and the card shrinks to a small pill. Tap the pill to open it again."])
        case .topBar:
            LayoutTip(symbol: "rectangle.topthird.inset.filled", steps: [
                "The address sits in a glass card at the top, with your buttons under it.",
                "Tap the address to type or search.",
                "Scroll down and the card shrinks to a small pill. Tap the pill to open it again."])
        case .compactBottom, .compactTop:
            LayoutTip(symbol: "rectangle.compress.vertical", steps: [
                "A thin bar with back, the address and the menu. The page runs underneath it.",
                "Tap the address to type or search; the menu holds tabs and everything else.",
                "Scroll down and the bar shrinks to a small pill. Tap it to open it again."])
        case .immersive:
            LayoutTip(symbol: "arrow.up.left.and.arrow.down.right", steps: [
                "Just the page and one small address pill.",
                "Tap the pill to fan out new tab, tabs and refresh. Tap the address itself to type or search.",
                "Open the tabs list to see which pages were opened from which."])
        case .custom:
            LayoutTip(symbol: "slider.horizontal.3", steps: [
                "This is the layout you built. Change any part of it under Settings › Layout.",
                "Tap the address to type or search."])
        }
    }
}

extension BrowserModel {
    private func tipKey(_ preset: PhonePreset) -> String { "layout_tip_\(preset.rawValue)" }

    /// Shows the steps for the layout in use, once. `force` shows them again (Settings › Layout).
    func maybeShowLayoutTip(force: Bool = false) {
        #if os(iOS)
        guard !showSetup, !isSecondary else { return }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil, !force { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["BS_NO_TIP"] == "1", !force { return }
        #endif
        let key = tipKey(phonePreset)
        guard force || (try? core.getSetting(key: key)) ?? nil != "1" else { return }
        animated(.easeOut(duration: 0.25)) { layoutTip = phonePreset }
        #endif
    }

    func dismissLayoutTip() {
        if let shown = layoutTip { saveSetting(tipKey(shown), "1") }
        animated(.easeOut(duration: 0.2)) { layoutTip = nil }
    }
}

#if os(iOS)
struct LayoutTipCard: View {
    @EnvironmentObject var model: BrowserModel
    let preset: PhonePreset

    var body: some View {
        let tip = LayoutTip.tip(for: preset)
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { model.dismissLayoutTip() }
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: tip.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.accent)
                    Text(preset.title).font(.title3.weight(.semibold))
                }
                ForEach(Array(tip.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(.footnote.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(Circle().fill(Theme.accent))
                        Text(step).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Gestures").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(tip.gestures, id: \.self) { gesture in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "hand.draw").font(.footnote).foregroundStyle(Theme.accent).frame(width: 22)
                        Text(gesture).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button { model.dismissLayoutTip() } label: {
                    Text("Got it").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Capsule().fill(Theme.accent)).foregroundStyle(.white)
                }
                .padding(.top, 4)
            }
            .padding(22) }
            .frame(maxHeight: 640).fixedSize(horizontal: false, vertical: true)
            .floatingGlassCard(cornerRadius: 28, solidity: 0.9)
            .padding(.horizontal, 28)
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        }
        .transition(.opacity)
    }
}
#endif


#if os(iOS)
/// Every layout in one place: what it looks like, how it works, and the gestures. Settings › Layout › Guide.
struct LayoutGuideView: View {
    var body: some View {
        PanelList {
            ForEach(PhonePreset.allCases) { preset in
                let tip = LayoutTip.tip(for: preset)
                Section {
                    ForEach(Array(tip.steps.enumerated()), id: \.offset) { index, step in
                        Label { Text(step).font(.subheadline) } icon: { Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(Theme.accent) }
                    }
                    ForEach(tip.gestures, id: \.self) { gesture in
                        Label { Text(gesture).font(.subheadline) } icon: { Image(systemName: "hand.draw").foregroundStyle(Theme.accent) }
                    }
                } header: {
                    Label(preset.title, systemImage: tip.symbol)
                }
            }
        }
        .navigationTitle("Layout guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
