import SwiftUI

/// The one set of measures every Settings pane is laid out with, so a pane is never sized on its own. Values are starting points that Dynamic Type and long text may exceed.
enum SettingsMetrics {
    /// The widest a pane's settings run; wider windows centre the column instead of stretching rows across the screen.
    static let contentMaxWidth: CGFloat = 720
    /// The least height of a standard row (a label with its control).
    static let rowMinHeight: CGFloat = 32
    /// A note under a setting: smaller than the label, quieter than it, and close to it.
    static let noteFont = Font.system(size: 11)
}

extension View {
    /// Lays a Settings pane's form out on the shared grid: a centred column of bounded width and compact rows.
    func settingsPaneLayout() -> some View {
        modifier(SettingsPaneLayout())
    }

    /// Puts a short note inside the same row as this control, under it, instead of in a row of its own (no extra padding, no divider between them).
    func settingsNoted(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            self
            if !note.isEmpty { Text(note).settingsNote() }
        }
    }

    /// A short note that belongs to the setting above it: small, secondary, and without a row of its own.
    func settingsNote() -> some View {
        // Where the list honours it (iOS), no line between a note and the setting it explains. The macOS grouped form draws its own lines and ignores this.
        font(SettingsMetrics.noteFont).foregroundStyle(.secondary).listRowSeparator(.hidden, edges: .top)
    }
}

private struct SettingsPaneLayout: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.defaultMinListRowHeight, SettingsMetrics.rowMinHeight)
            .frame(maxWidth: SettingsMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
    }
}

