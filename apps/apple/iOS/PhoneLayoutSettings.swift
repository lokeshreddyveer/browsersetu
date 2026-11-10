import SwiftUI

/// A tiny drawing of a layout: the phone, and where its bar, dock or pills are. Drawn from the spec, so it is always what the layout really is.
struct PhoneLayoutGlyph: View {
    let spec: PhoneLayoutSpec

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.secondary.opacity(0.8), lineWidth: 1.2)
            switch spec.style {
            case .attached:
                VStack(spacing: 0) {
                    if spec.barAddress == .bottom { Spacer(minLength: 0) }
                    if spec.compactBar { Capsule().fill(Theme.accent).frame(height: 6).padding(.horizontal, 3).padding(.vertical, 6) }
                    else { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.accent).frame(height: 11).padding(.horizontal, 4).padding(.vertical, 4) }
                    if spec.barAddress == .top { Spacer(minLength: 0) }
                }
            case .floating:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Capsule().fill(Theme.accent).frame(height: 6).padding(.horizontal, 4).padding(.bottom, 5)
                }
            case .pills:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack { Circle().fill(Theme.accent).frame(width: 7, height: 7); Spacer(); Circle().fill(Theme.accent).frame(width: 7, height: 7) }.padding(.horizontal, 5).padding(.bottom, 5)
                }
            }
        }
        .frame(width: 26, height: 44)
        .accessibilityHidden(true)
    }
}

/// Settings › Toolbar and Appearance › Layout: the ready-made layouts, and Custom, where each choice is the person's own.
struct PhoneLayoutSettings: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            ForEach(PhonePreset.allCases) { preset in
                Button { choose(preset) } label: {
                    HStack(spacing: 14) {
                        PhoneLayoutGlyph(spec: preset.spec ?? model.phoneCustomSpec)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title).foregroundStyle(.primary)
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if model.phonePreset == preset { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent) }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("phone-preset-\(preset.rawValue)")
                .accessibilityAddTraits(model.phonePreset == preset ? .isSelected : [])
            }
        } header: {
            Text("Layout")
        } footer: {
            Text("Where the address bar and the buttons are, and what they do as you read. The buttons you chose and the menu stay as you set them. Every layout follows your theme.")
        }
        Section {
            if model.phoneSpec.fanOut {
                LabeledContent("Tabs open as", value: "Vertical list")
            } else {
                Picker("Tabs open as", selection: $model.phoneTabsView) { ForEach(PhoneTabsView.allCases) { Text($0.title).tag($0) } }
            }
        } header: {
            Text("Tabs")
        } footer: {
            Text(model.phoneSpec.fanOut ? "Immersive always opens your tabs as a vertical list that slides in from the left." : "What the tabs button opens: a grid of page pictures; a floating list that slides in over the page; or real vertical tabs, a column of tabs beside the page that the button folds out into a list.")
        }
        Section {
            Toggle("Offer a way back to the top", isOn: $model.backToTopPill)
        } header: {
            Text("Reading")
        } footer: {
            Text("On a long page, once you start scrolling back up, a small “Top” pill shows at the left, just above the bar, for a few seconds. It comes back later if you are still far down, and stops asking after a few times.")
        }
        Section {
            Button("How this layout works") { model.maybeShowLayoutTip(force: true) }
            NavigationLink("Guide to all layouts") { LayoutGuideView() }
        }
        if model.phonePreset == .custom { custom }
    }

    /// Choosing Custom starts from the layout in use, so nothing jumps.
    private func choose(_ preset: PhonePreset) {
        if preset == .custom, model.phonePreset != .custom { model.phoneCustomSpec = model.phoneSpec }
        model.phonePreset = preset
        model.maybeShowLayoutTip()
    }

    private var custom: some View {
        let style = Binding(get: { model.phoneCustomSpec.style }, set: { model.phoneCustomSpec.style = $0 })
        let address = Binding(get: { model.phoneCustomSpec.address }, set: { model.phoneCustomSpec.address = $0 })
        let reading = Binding(get: { model.phoneCustomSpec.reading }, set: { model.phoneCustomSpec.reading = $0 })
        let tabsPill = Binding(get: { model.phoneCustomSpec.tabsPill }, set: { model.phoneCustomSpec.tabsPill = $0 })
        let newTabPill = Binding(get: { model.phoneCustomSpec.newTabPill }, set: { model.phoneCustomSpec.newTabPill = $0 })
        return Section {
            Picker("Style", selection: style) { ForEach(PhoneLayoutSpec.Style.allCases) { Text($0.title).tag($0) } }
            if model.phoneCustomSpec.style == .attached {
                Picker("Address bar", selection: address) { ForEach(AddressBarPosition.allCases) { Text($0.title).tag($0) } }
                Toggle("Compact bar (three glass shapes)", isOn: Binding(get: { model.phoneCustomSpec.compactBar }, set: { model.phoneCustomSpec.compactBar = $0 }))
            }
            if model.phoneCustomSpec.style != .pills {
                Picker("As I read", selection: reading) { ForEach(PhoneLayoutSpec.Reading.allCases) { Text($0.title).tag($0) } }
            }
            if model.phoneCustomSpec.style != .attached {
                Toggle("Tabs pill (opens the tabs as a list)", isOn: tabsPill)
                Toggle("New tab button (+ above the tabs pill)", isOn: newTabPill)
                Toggle("Fan the buttons out of the address pill", isOn: Binding(get: { model.phoneCustomSpec.fanOut }, set: { model.phoneCustomSpec.fanOut = $0 }))
            }
        } header: {
            Text("Custom Layout")
        } footer: {
            Text("Style is the look of the controls. “As I read” says whether they fold while you scroll, and whether scrolling back opens them or only a tap does. The pills are what is left on the screen when the controls have folded.")
        }
    }
}
