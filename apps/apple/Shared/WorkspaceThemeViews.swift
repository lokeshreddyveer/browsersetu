import SwiftUI

/// The workspace's gradient as a faint wash that fades out down from the top of the sidebar. Subtle on purpose: a tint, not a picture.
struct WorkspaceWash: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if let gradient = model.activeWorkspaceGradient, !reduceTransparency {
                gradient.linear(dark: scheme == .dark)
                    .opacity(GradientRules.washOpacity(dark: scheme == .dark))
                    .frame(height: 150)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .motion(.easeOut(duration: 0.3), value: model.activeWorkspaceGradient)
    }
}

/// A workspace's icon on a small tile: its gradient when it has one, otherwise a tint of the accent.
struct WorkspaceIconTile: View {
    let icon: String
    let gradient: WorkspaceGradient?
    let accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            if let gradient {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(gradient.linear(dark: dark))
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(glyph(gradient, dark: dark))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.opacity(0.14))
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(accent)
            }
        }
        .frame(width: 30, height: 30)
    }

    /// White or black, whichever reads better on the tile's colours.
    private func glyph(_ gradient: WorkspaceGradient, dark: Bool) -> Color {
        let stops = gradient.stops(dark: dark)
        let white = stops.map { GradientColor.contrast($0, GradientColor(r: 1, g: 1, b: 1)) }.min() ?? 1
        let black = stops.map { GradientColor.contrast($0, GradientColor(r: 0, g: 0, b: 0)) }.min() ?? 1
        return white >= black ? .white : .black
    }
}

/// Settings › Workspaces › a workspace › Theme: a solid accent colour (the swatches above), or a gradient of two or three colours that is made, or tuned by hand, and
/// saved. The preview shows how it will look in both the light and the dark look, and says whether it can be read.
struct WorkspaceThemeEditor: View {
    @EnvironmentObject var model: BrowserModel
    let workspace: Workspace

    enum Mode: String, CaseIterable, Identifiable {
        case solid = "Solid Color", custom = "Custom Gradient", generate = "Generate Gradient"
        var id: String { rawValue }
    }

    @State private var mode: Mode
    @State private var draft: WorkspaceGradient

    init(workspace: Workspace) {
        self.workspace = workspace
        _mode = State(initialValue: workspace.gradient == nil ? .solid : .custom)
        _draft = State(initialValue: workspace.gradient ?? GradientGenerator.random(count: 2))
    }

    private var checked: WorkspaceGradient { draft.validated() ?? draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Theme").foregroundStyle(.secondary)
                Spacer()
                Picker("Theme", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            if mode != .solid { editor.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .motion(.easeOut(duration: 0.2), value: mode)
        .onChange(of: mode) { _, new in
            switch new {
            case .solid: model.setWorkspaceGradient(workspace.name, nil)
            case .generate: draft = GradientGenerator.random(count: draft.colors.count)
            case .custom: break
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                preview(dark: false)
                preview(dark: true)
            }
            HStack(spacing: 10) {
                ForEach(draft.colors.indices, id: \.self) { index in
                    ColorPicker("Colour \(index + 1)", selection: Binding(
                        get: { GradientColor(hex: draft.colors[index])?.color ?? .gray },
                        set: { draft.colors[index] = GradientColor($0).hex }), supportsOpacity: false)
                        .labelsHidden()
                }
                Picker("Colours", selection: Binding(get: { draft.colors.count }, set: setCount)) {
                    Text("2 colours").tag(2)
                    Text("3 colours").tag(3)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                Spacer()
                Button { draft = GradientGenerator.random(count: draft.colors.count) } label: { Label("Generate", systemImage: "dice") }
                    .help("A new complementary palette")
            }
            HStack {
                Text("Angle").foregroundStyle(.secondary)
                Slider(value: $draft.angle, in: 0...360, step: 5) { Text("Angle") }
                Text("\(Int(draft.angle))°").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            HStack {
                readabilityLabel
                Spacer()
                Button("Save as Workspace Theme") { _ = model.setWorkspaceGradient(workspace.name, draft); if let saved = draft.validated() { draft = saved } }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.validated() == nil || draft.validated() == workspace.gradient)
            }
        }
    }

    private func setCount(_ count: Int) {
        if count < draft.colors.count { draft.colors = Array(draft.colors.prefix(count)) }
        else if count > draft.colors.count, let last = draft.rgb.last {
            let c = last.hsb
            draft.colors.append(GradientColor(h: c.h + 0.15, s: c.s, b: c.b).hex)
        }
    }

    /// How a sidebar looks with this theme: the plain sidebar colour, the wash, a label and the accent.
    private func preview(dark: Bool) -> some View {
        let g = checked
        let base = GradientRules.base(dark: dark)
        return ZStack(alignment: .topLeading) {
            base.color
            g.linear(dark: dark).opacity(GradientRules.washOpacity(dark: dark))
            HStack(spacing: 6) {
                Circle().fill((g.accent(dark: dark) ?? base).color).frame(width: 8, height: 8)
                Text(dark ? "Dark" : "Light").font(.caption.weight(.medium))
                    .foregroundStyle(GradientRules.label(dark: dark).color.opacity(GradientRules.secondaryOpacity + 0.2))
            }
            .padding(8)
        }
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            // The gradient itself, undiluted, as a thin line, so the colours can be judged.
            g.linear(dark: dark).frame(height: 4).clipShape(Capsule()).padding(8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(dark ? "Dark" : "Light") look preview")
    }

    private var readabilityLabel: some View {
        let g = checked
        let light = g.readability(dark: false), dark = g.readability(dark: true)
        let ok = light.passes && dark.passes
        let worstText = min(light.textContrast, dark.textContrast)
        return Label(ok ? "Readable in light and dark (text \(String(format: "%.1f", worstText)) : 1)" : "Hard to read; the colours will be adjusted",
                     systemImage: ok ? "checkmark.seal" : "exclamationmark.triangle")
            .font(.caption).foregroundStyle(ok ? Color.secondary : Color.orange)
    }
}
