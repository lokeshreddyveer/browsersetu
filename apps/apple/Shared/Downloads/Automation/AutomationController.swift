import Foundation
import SwiftUI

/// Puts the pieces together for one profile: the clients, the service, the webhooks and (on the Mac) the socket. Switching it off closes everything and changes no download.
@MainActor
final class AutomationController: ObservableObject {
    let profile: String
    let clients: AutomationClientStore
    let service: AutomationService
    let webhooks: AutomationWebhooks
    /// Removing a profile removes everything automation and remote control kept for it: paired devices' channel keys and webhook secrets (read from the saved lists, since the Keychain
    /// cannot be listed) and then the folder with the clients, the withdrawn-access list and the webhooks. A profile created later under the same name starts with none of it, so a phone
    /// paired to the old one cannot reach the new one.
    nonisolated static func wipe(profile: String, root: URL) {
        let folder = root.appendingPathComponent("automation", isDirectory: true).appendingPathComponent(profile, isDirectory: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("remote-devices.json")), let list = try? AutomationJSON.decoder.decode([RemoteDevice].self, from: data) {
            let keys = KeychainDeviceKeyStore(profile: profile)
            for device in list { _ = keys.set(nil, for: device.id) }
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("webhooks.json")), let list = try? AutomationJSON.decoder.decode([WebhookEndpoint].self, from: data) {
            let vault = KeychainSecretVault(profile: profile)
            for endpoint in list { vault.remove(endpoint: endpoint.id) }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    @Published private(set) var enabled = false
    @Published private(set) var status = "Off"
    @Published private(set) var endpoint: String?
    private let folder: URL
    private let persistent: Bool
    #if os(macOS)
    private var transport: AutomationTransport?
    #endif

    init(root: URL, profile: String, persistent: Bool, coordinators: @escaping () -> [DownloadCoordinator], feed: DownloadEventFeed? = nil, vault: AutomationSecretVault? = nil) {
        self.profile = profile; self.persistent = persistent
        folder = root.appendingPathComponent("automation", isDirectory: true).appendingPathComponent(profile, isDirectory: true)
        // Withdrawn access is also kept in the Keychain, a different kind of storage from the files, so one kind of failure cannot bring a revoked client back. (Not under test runs:
        // tests never touch the real Keychain.)
        var denyStores: [AuthorizationDenyStore]?
        if persistent {
            denyStores = [FileDenyStore(file: folder.appendingPathComponent("denied.json"))]
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { denyStores?.append(KeychainBackedDenyStore(profile: profile)) }
        }
        clients = AutomationClientStore(file: persistent ? folder.appendingPathComponent("clients.json") : nil, denyStores: denyStores)
        service = AutomationService(clients: clients, coordinators: coordinators, feed: feed)
        webhooks = AutomationWebhooks(file: persistent ? folder.appendingPathComponent("webhooks.json") : nil, secrets: vault ?? KeychainSecretVault(profile: profile))
        service.eventSink = { [weak webhooks] event in webhooks?.enqueue(event) }
    }

    /// Paired devices and remote control for this profile. Created on first use; off until the person turns it on, and its keys never touch the real Keychain under test.
    #if os(macOS)
    private(set) lazy var remote: RemoteAccessController = {
        let keys: DeviceKeyStore = (persistent && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil) ? KeychainDeviceKeyStore(profile: profile) : MemoryDeviceKeyStore()
        let devices = RemoteDeviceStore(file: persistent ? folder.appendingPathComponent("remote-devices.json") : nil, keys: keys)
        return RemoteAccessController(profile: profile, persistent: persistent, clients: clients, automation: service, devices: devices)
    }()
    #endif

    /// A socket path short enough for the system (104 bytes), in a folder only this account can enter.
    static func socketPath(folder: URL, profile: String, temp: URL = FileManager.default.temporaryDirectory) -> String? {
        let tag = String(Data(profile.utf8).sha256Hex.prefix(8))
        let candidates = [folder.appendingPathComponent("dl-\(tag).sock").path, temp.appendingPathComponent("bsetu-dl-\(tag).sock").path]
        #if os(macOS)
        return candidates.first { $0.utf8.count <= AutomationTransport.maxPath }
        #else
        return candidates.first
        #endif
    }

    func setEnabled(_ on: Bool) {
        #if os(macOS)
        if !on { transport?.stop(); transport = nil; service.stop(); enabled = false; status = "Off"; endpoint = nil; return }
        guard !enabled else { return }
        // A temporary profile keeps nothing and so offers no outside access.
        guard persistent else { status = "Not available in a temporary profile"; return }
        guard let path = Self.socketPath(folder: folder, profile: profile) else { status = "No socket path is short enough"; return }
        service.start()
        let t = AutomationTransport(service: service)
        do {
            try t.start(.unix(path: path), onFailure: { [weak self] why in Task { @MainActor in self?.status = "Stopped: \(why)"; self?.enabled = false } })
            transport = t; enabled = true; endpoint = path; status = "On"
        } catch {
            service.stop(); status = "Could not start: \(error)"; endpoint = nil
        }
        #else
        status = "Available on the Mac"
        #endif
    }
}

// MARK: - Settings

struct DownloadAutomationSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View { AutomationContent(controller: model.automation, model: model) }
}

private struct AutomationContent: View {
    @ObservedObject var controller: AutomationController
    @ObservedObject var model: BrowserModel
    @ObservedObject private var clients: AutomationClientStore
    @ObservedObject private var service: AutomationService
    @ObservedObject private var webhooks: AutomationWebhooks
    @State private var name = ""
    @State private var scopes: Set<AutomationScope> = [.downloadsRead]
    @State private var shownToken: String?
    @State private var hookURL = ""
    @State private var hookSecret: String?
    @State private var message: String?

    init(controller: AutomationController, model: BrowserModel) {
        self.controller = controller; self.model = model
        _clients = ObservedObject(wrappedValue: controller.clients)
        _service = ObservedObject(wrappedValue: controller.service)
        _webhooks = ObservedObject(wrappedValue: controller.webhooks)
    }

    var body: some View {
        Section("Automation") {
            Text("Lets scripts and tools on this Mac list and control your downloads through a private socket only your account can open. Off until you turn it on. A tool can only propose a download; you approve it here. It cannot start peer-to-peer, touch other profiles, or see private tabs.")
                .settingsNote()
            Toggle("Allow local automation", isOn: $model.automationEnabled)
            LabeledContent("Status", value: controller.status)
            if let endpoint = controller.endpoint {
                LabeledContent("Socket") { Text(endpoint).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
            }
            ForEach(clients.clients) { client in clientRow(client) }
            HStack {
                TextField("Client name", text: $name)
                Menu("Permissions (\(scopes.count))") {
                    ForEach(AutomationScope.allCases, id: \.self) { s in
                        Button { if scopes.contains(s) { scopes.remove(s) } else { scopes.insert(s) } } label: { Label(s.rawValue, systemImage: scopes.contains(s) ? "checkmark" : "") }
                    }
                }
                Button("Add Client") {
                    switch clients.enrol(name: name, profile: controller.profile, scopes: scopes) {
                    case .created(_, let token): shownToken = token; message = nil; name = ""
                    case .refused(let why): message = why
                    }
                }
            }
            if let shownToken { secretNotice(shownToken, "This token is shown once. Put it in a file only you can read and point BSETU_TOKEN_FILE at it; do not paste it into a command.") { self.shownToken = nil } }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            if let problem = clients.storageProblem { Text(problem).font(.caption).foregroundStyle(.red) }
            if !service.proposals.filter({ $0.state == .pending }).isEmpty {
                Text("Waiting for your approval").font(.subheadline.weight(.medium))
                ForEach(service.proposals.filter { $0.state == .pending }) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.filename ?? p.url.lastPathComponent).lineLimit(1)
                            Text("\(p.url.host ?? "") · from \(p.clientName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Approve") { service.approve(p.id) }
                        Button("Reject") { service.reject(p.id) }
                    }
                }
            }
            Text("Webhooks").font(.subheadline.weight(.medium))
            Text("Optional. Sends a signed notice (no address, no file name) to a place you name: https to a website, or http to 127.0.0.1.").settingsNote()
            ForEach(webhooks.endpoints) { e in
                HStack {
                    Text(e.url.absoluteString).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Toggle("", isOn: Binding(get: { e.enabled }, set: { webhooks.setEnabled(e.id, $0) })).labelsHidden()
                    Button("Remove", role: .destructive) { webhooks.remove(e.id) }
                }
            }
            HStack {
                TextField("https://…", text: $hookURL)
                Button("Add Webhook") {
                    guard let url = URL(string: hookURL.trimmingCharacters(in: .whitespaces)) else { message = "That is not an address."; return }
                    switch webhooks.add(url) {
                    case .added(_, let secret): hookSecret = secret; hookURL = ""; message = nil
                    case .refused(let why): message = why
                    }
                }
            }
            if let hookSecret { secretNotice(hookSecret, "Signing secret, shown once. The receiver uses it to check each notice.") { self.hookSecret = nil } }
            if !service.audit.isEmpty {
                DisclosureGroup("Recent activity") {
                    ForEach(service.audit.prefix(10)) { e in
                        Text("\(e.client) · \(e.action) · \(e.outcome)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// A change that withdraws access is only called done when it was saved; otherwise the person is told it is blocked for now but may return after a restart.
    private func report(_ commit: ClientCommit) {
        switch commit {
        case .committed: message = nil
        case .restrictedButNotSaved(let why), .refused(let why): message = why
        }
    }

    private func clientRow(_ c: AutomationClient) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(c.name) + Text(c.revokedAt != nil ? "  (revoked)" : "").foregroundColor(.secondary)
                Text(c.scopes.map(\.rawValue).sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if c.revokedAt == nil {
                Button("New Token") {
                    let r = clients.rotate(c.id)
                    if let t = r.token { shownToken = t; message = nil } else if case .refused(let why) = r.commit { message = why }
                }
                Button("Revoke") { report(clients.revoke(c.id)) }
            }
            Button("Remove", role: .destructive) { report(clients.remove(c.id)) }
        }
    }

    /// A secret goes on the pasteboard marked as concealed (so clipboard managers skip it), not into clipboard history, and is removed after a minute if nothing else was copied.
    @MainActor static func copySecret(_ secret: String) {
        copyToPasteboardQuietly(secret)
        #if os(macOS)
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        NSPasteboard.general.addTypes([concealed], owner: nil)
        NSPasteboard.general.setData(Data(), forType: concealed)
        let count = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() } }
        #endif
    }

    private func secretNotice(_ secret: String, _ text: String, done: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.caption)
            HStack {
                Text(secret).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button("Copy") { Self.copySecret(secret) }
                Button("Done", action: done)
            }
        }
    }
}
