import SwiftUI
#if os(macOS)
import AppKit
#endif

/// VayuSetu is a separate app by the same author: a VPN client, encrypted DNS and ad blocker for the whole device. Browser Setu works without it. This is
/// only a way to find it: a button that opens its download page in a tab, and, on a Mac that already has it, one that opens the app. Nothing is fetched,
/// nothing is checked online, and nothing is installed for you.
enum VayuSetuLink {
    static let downloadPage = URL(string: "https://github.com/lokeshreddyveer/vayusetu/releases/latest")!
    static let website = URL(string: "https://lokeshreddyveer.github.io/vayusetu/")!
    static let macBundleID = "app.vayusetu.macos"

    #if os(macOS)
    /// Where VayuSetu is installed on this Mac, if it is. A lookup in the system's list of apps; it reads nothing from the app.
    static var installedMacApp: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: macBundleID) }
    #endif
}

/// Settings › Privacy: what VayuSetu adds that a browser cannot, and the button to get it.
struct VayuSetuSection: View {
    @EnvironmentObject var model: BrowserModel
    #if os(macOS)
    @State private var installed: URL? = VayuSetuLink.installedMacApp
    #endif

    var body: some View {
        Section {
            #if os(macOS)
            if installed != nil {
                Label("VayuSetu is installed on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Open VayuSetu") { openApp() }
            } else {
                Button { open(VayuSetuLink.downloadPage) } label: { Label("Download VayuSetu for Mac", systemImage: "arrow.down.circle") }
            }
            Button("About VayuSetu…") { open(VayuSetuLink.website) }
            #else
            Button { open(VayuSetuLink.website) } label: { Label("About VayuSetu", systemImage: "network.badge.shield.half.filled") }
            #endif
        } header: { Text("Network protection: VayuSetu") } footer: {
            #if os(macOS)
            Text("A separate app by the same author. It adds what a browser cannot: a VPN client (you bring your own WireGuard or IKEv2 server), encrypted DNS and ad blocking for every app on this Mac, not only here. Browser Setu works fully without it. The download button opens the release page in a tab; nothing is installed for you.")
            #else
            Text("A separate app by the same author: a VPN client, encrypted DNS and ad blocking for the whole device. The iPhone version is waiting for App Review. Browser Setu works fully without it.")
            #endif
        }
        #if os(macOS)
        .onAppear { installed = VayuSetuLink.installedMacApp }
        #endif
    }

    private func open(_ url: URL) {
        model.sheet = nil
        model.open(urlString: url.absoluteString, newTab: true)
    }

    #if os(macOS)
    private func openApp() {
        guard let installed else { return }
        NSWorkspace.shared.openApplication(at: installed, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
    #endif
}
