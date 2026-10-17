import SwiftUI

/// Origin string used as the permission key, e.g. https://example.com or http://localhost:3000.
func originString(for url: URL?) -> String? {
    guard let url, let scheme = url.scheme, let host = url.host, scheme == "http" || scheme == "https" else { return nil }
    if let port = url.port { return "\(scheme)://\(host):\(port)" }
    return "\(scheme)://\(host)"
}

/// Safari-style site information. Shows only what the engine and core actually know.
struct SiteInfoView: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @State private var grants: [PermissionGrant] = []

    private var origin: String? { originString(for: tab.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tab.isBlank ? "New Tab" : displayHost(tab.url)).font(.headline)
            if tab.isPrivate {
                Label("Private tab. Nothing from this tab is saved.", systemImage: "eye.slash.fill")
                    .font(.caption).foregroundStyle(Theme.privateAccent)
            }
            row("Connection", value: connection)
            if let identity = tab.identity {
                VStack(alignment: .leading, spacing: 3) {
                    Label(identity.headline, systemImage: identity.isVerified ? "checkmark.seal.fill" : "lock.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(identity.isVerified ? Color.green : Color.secondary)
                    Text(identity.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let origin {
                Divider()
                Text("Permissions").font(.subheadline.weight(.semibold))
                if tab.isPrivate {
                    Text("Private tabs always ask and never remember a choice.").font(.caption).foregroundStyle(.secondary)
                } else {
                    permission(.camera, "Camera", origin: origin)
                    permission(.microphone, "Microphone", origin: origin)
                }
            }
            Divider()
            row("Privacy protection", value: model.privacy.state(forHost: tab.url?.host).statusWord)
        }
        .padding(16).frame(width: 300)
        .onAppear(perform: load)
        .accessibilityIdentifier("site-info")
    }

    private var connection: String {
        if tab.isBlank { return "No page loaded" }
        guard let scheme = tab.url?.scheme else { return "Unknown" }
        if scheme == "https" { return tab.isSecure ? "Secure (HTTPS)" : "HTTPS, with insecure content" }
        return "Not secure"
    }

    private func row(_ title: String, value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }.font(.callout)
    }

    private func permission(_ kind: PermissionType, _ title: String, origin: String) -> some View {
        let current = grants.first { $0.origin == origin && $0.kind == kind }?.decision ?? .prompt
        return HStack {
            Text(title)
            Spacer()
            Picker("", selection: Binding(get: { current }, set: { choice in
                try? model.core.rememberPermission(origin: origin, kind: kind, decision: choice)
                load()
            })) {
                Text("Ask").tag(Decision.prompt)
                Text("Allow").tag(Decision.allow)
                Text("Block").tag(Decision.deny)
            }
            .labelsHidden().frame(width: 100)
        }
        .font(.callout)
    }

    private func load() { grants = (try? model.core.listPermissions()) ?? [] }
}
