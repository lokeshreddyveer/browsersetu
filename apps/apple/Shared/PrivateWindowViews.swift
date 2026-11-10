import SwiftUI

/// Settings › Tabs: what ⇧⌘N does. Only the Mac has windows to choose between.
struct PrivateOpenSettings: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        #if os(macOS)
        Picker("⇧⌘N", selection: $model.privateOpenMode) {
            ForEach(PrivateOpenMode.allCases) { Text($0.title).tag($0) }
        }
        Text("A private window has storage of its own that is dropped when it closes, and your bookmarks and saved passwords stay available. “New Private Window” and “New Private Tab” in the File menu always do exactly what they say. A guest window is separate: it hides your bookmarks and passwords.")
            .font(.caption).foregroundStyle(.secondary)
        #else
        EmptyView()
        #endif
    }
}

#if os(macOS)
/// The question shown when ⇧⌘N is set to ask: a private window or a private tab here. Return opens a window, Escape cancels, and "Remember my choice" makes the answer the setting.
struct PrivateChoiceCard: View {
    @EnvironmentObject var model: BrowserModel
    @State private var remember = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea().onTapGesture { model.privateChoicePending = false }
            VStack(spacing: 14) {
                Image(systemName: "eye.slash.fill").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.accent)
                Text("Open private browsing in…").font(.system(size: 16, weight: .semibold))
                VStack(spacing: 8) {
                    Button { model.answerPrivateChoice(window: true, remember: remember) } label: {
                        Text("Private Window").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    Button { model.answerPrivateChoice(window: false, remember: remember) } label: {
                        Text("Private Tab in This Window").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
                Toggle("Remember my choice", isOn: $remember).toggleStyle(.checkbox).font(.system(size: 12))
                Text("You can change this any time in Settings › Tabs.").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { model.privateChoicePending = false }.buttonStyle(.borderless).keyboardShortcut(.cancelAction).font(.system(size: 12))
            }
            .padding(22).frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Open private browsing in a private window or a private tab")
        }
    }
}

/// A small badge on a private window's page area, so it is never mistaken for an ordinary window.
struct PrivateWindowBadge: View {
    var body: some View {
        Label("Private", systemImage: "eye.slash.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.purple.opacity(0.85))).padding(10).allowsHitTesting(false)
            .accessibilityLabel("Private window. Its browsing data is removed when it closes.")
    }
}
#endif

#if os(macOS)
/// A quiet violet wash over the top bar of a private window, so it is never taken for an ordinary window (the Private badge says it in words). It is drawn over the page's own tint and the theme,
/// follows light and dark, and fades in with the window; a guest window has none (its badge is indigo and says Guest).
struct PrivateWindowTintLayer: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.colorScheme) private var scheme

    /// How strong the wash is: enough to see at a glance, never enough to tint the controls' colours.
    static func opacity(dark: Bool) -> Double { dark ? 0.20 : 0.12 }

    var body: some View {
        Group {
            if model.isPrivateWindow && !model.isGuest {
                Color(red: 0.55, green: 0.27, blue: 0.85).opacity(Self.opacity(dark: scheme == .dark)).transition(.opacity)
            }
        }
        .motion(.easeOut(duration: 0.25), value: model.isPrivateWindow)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
