import SwiftUI

/// Settings ▸ Downloads ▸ Website accounts. Credentials are typed here, once, for a named website; they are stored in the Keychain on this device and never shown again.
struct AccountsSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View { AccountsContent(store: model.accountStore) }
}

private struct AccountsContent: View {
    @ObservedObject var store: AccountStore
    @State private var adding = false
    @State private var name = ""
    @State private var host = ""
    @State private var method = AccountMethod.apiToken
    @State private var user = ""
    @State private var secret = ""
    @State private var message: String?
    @State private var reconnecting: String?

    var body: some View {
        Section("Website accounts") {
            Text("For downloads you start yourself from Add Download. A credential is sent only to the website you name, only over https, and never to another site a download is redirected to. Downloads from a page you are signed in to keep using that page's own session; nothing here reads your browser's cookies or passwords.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(store.accounts) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(a.name).font(.system(size: 13, weight: .medium))
                        Text(a.state.title).font(.caption).foregroundStyle(a.state == .valid ? Color.green : Color.orange)
                        Spacer()
                        if a.method.storesSecret && a.state != .disconnected && a.state != .valid { Button("Reconnect") { reconnecting = a.id; secret = ""; user = a.username ?? ""; adding = false } }
                        if a.method.storesSecret && a.state != .disconnected { Button("Disconnect") { store.disconnect(a.id) } }
                        Button("Delete") { store.delete(a.id) }
                    }
                    Text("\(a.host)\(a.port.map { ":\($0)" } ?? "") · \(a.method.title)" + (a.username.map { " · \($0)" } ?? "") + (a.lastValidatedAt.map { " · worked " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if let e = a.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                    if reconnecting == a.id { credentialFields(for: a.method) ; HStack { Button("Save") { reconnect(a) }; Button("Cancel") { reconnecting = nil; secret = "" } } }
                }
            }
            if let p = store.storageProblem { Text(p).font(.caption).foregroundStyle(.orange) }
            if adding {
                TextField("Name", text: $name)
                TextField("Website (for example files.example.com)", text: $host).autocorrectionDisabled()
                Picker("Method", selection: $method) { ForEach(AccountMethod.allCases) { Text($0.title).tag($0) } }
                if method == .webSession { Text("Nothing is stored. This only records that you use this website signed in through the browser.").font(.caption).foregroundStyle(.secondary) }
                else { credentialFields(for: method) }
                HStack {
                    Button("Add") { add() }
                    Button("Cancel") { adding = false; secret = "" }
                }
            } else { Button("Add Account…") { adding = true; reconnecting = nil; message = nil } }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .onAppear { store.refreshExpiry(); store.checkKeychain() }
    }

    @ViewBuilder private func credentialFields(for method: AccountMethod) -> some View {
        if method == .httpBasic { TextField("User name", text: $user).autocorrectionDisabled() }
        SecureField(method == .httpBasic ? "Password" : "Token", text: $secret)
    }

    private func add() {
        switch store.add(name: name, host: host, method: method, username: user, secret: secret) {
        case .ok: adding = false; name = ""; host = ""; user = ""; secret = ""; message = nil
        case .refused(let why): message = why
        }
    }

    private func reconnect(_ a: WebsiteAccount) {
        switch store.reconnect(a.id, username: user, secret: secret) {
        case .ok: reconnecting = nil; secret = ""; message = nil
        case .refused(let why): message = why
        }
    }
}
