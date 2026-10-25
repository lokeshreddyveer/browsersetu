import SwiftUI

/// The tools that used to be reachable only by typing ">" in the address bar, as plain menu rows on every platform.
struct ToolsMenuItems: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        Button { model.sheet = .digest } label: { Label("Daily Digest", systemImage: "newspaper") }
        Button { model.sheet = .toolkit } label: { Label("Feeds, Tasks, Vault, Clipboard…", systemImage: "square.grid.2x2") }
        Button { model.sheet = .readingList } label: { Label("Reading List", systemImage: "books.vertical") }
        Menu {
            Button("APA") { Task { await model.copyCitationFromDOI(.apa) } }
            Button("MLA") { Task { await model.copyCitationFromDOI(.mla) } }
            Button("Plain") { Task { await model.copyCitationFromDOI(.plain) } }
        } label: { Label("Copy Citation from DOI", systemImage: "quote.opening") }
            .disabled(model.active?.isBlank ?? true)
        Button { Task { await model.annotatePageScreenshot() } } label: { Label("Screenshot and Mark Up", systemImage: "camera.viewfinder") }
            .disabled(model.active?.isBlank ?? true)
        Button { model.reopenLastSession() } label: { Label("Reopen My Last Session", systemImage: "clock.arrow.circlepath") }
        Button { Task { await model.toggleWatch() } } label: { Label("Watch This Page for Changes", systemImage: "eye") }
            .disabled(model.active?.isBlank ?? true)
        Button { model.privacySheet = .site } label: { Label("Privacy Grade for This Site", systemImage: "checkmark.shield") }
            .disabled(model.active?.isBlank ?? true)
        #if os(macOS) && DIRECT_BUILD
        if AISwitches.shared.toolsActive {
            Button { if let tab = model.active { AgentBridge.shared.toggleShare(tab) } } label: {
                Label(model.active.map { AgentBridge.shared.isShared($0) } == true ? "Stop Sharing This Tab with AI Tools" : "Share This Tab with AI Tools", systemImage: "sparkles")
            }
            .disabled((model.active?.isBlank ?? true) || (model.active?.isPrivate ?? true))
            Button(role: .destructive) { AgentBridge.shared.stopEverything() } label: { Label("Stop AI Tools", systemImage: "stop.circle") }
        }
        #endif
        Button { model.openSearchPanel(prefill: ">") } label: { Label("All Commands…", systemImage: "command") }
        Divider()
        Button(role: .destructive) { Task { await model.panic() } } label: { Label("Clear Everything Now…", systemImage: "exclamationmark.octagon") }
    }
}
