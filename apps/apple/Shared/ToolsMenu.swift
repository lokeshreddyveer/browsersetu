import SwiftUI

/// The tools that used to be reachable only by typing ">" in the address bar, as plain menu rows on every platform.
struct ToolsMenuItems: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        Button { model.sheet = .digest } label: { Label("Daily Digest", systemImage: "newspaper") }
        Button { model.sheet = .toolkit } label: { Label("Feeds, Tasks, Vault, Clipboard…", systemImage: "square.grid.2x2") }
        Button { model.sheet = .readingList } label: { Label("Reading List", systemImage: "books.vertical") }
        Button { Task { await model.annotatePageScreenshot() } } label: { Label("Screenshot and Mark Up", systemImage: "camera.viewfinder") }
            .disabled(model.active?.isBlank ?? true)
        Button { model.reopenLastSession() } label: { Label("Reopen My Last Session", systemImage: "clock.arrow.circlepath") }
        Button { Task { await model.toggleWatch() } } label: { Label("Watch This Page for Changes", systemImage: "eye") }
            .disabled(model.active?.isBlank ?? true)
        Button { model.privacySheet = .site } label: { Label("Privacy Grade for This Site", systemImage: "checkmark.shield") }
            .disabled(model.active?.isBlank ?? true)
        Button { model.openSearchPanel(prefill: ">") } label: { Label("All Commands…", systemImage: "command") }
        Divider()
        Button(role: .destructive) { Task { await model.panic() } } label: { Label("Clear Everything Now…", systemImage: "exclamationmark.octagon") }
    }
}
