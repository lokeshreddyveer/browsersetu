import SwiftUI
import UniformTypeIdentifiers

/// Download extensions: rule files that suggest addresses and names for addresses you give. They cannot run code, start a download, or reach the network.
struct DownloadExtensionsSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View { DownloadExtensionsContent(manager: model.downloadExtensions) }
}

/// The list itself observes the manager, so a change made to it (enabled, revoked, updated) is shown at once.
private struct DownloadExtensionsContent: View {
    @ObservedObject var manager: DownloadExtensionManager
    @State private var importing = false
    @State private var updating: String?
    @State private var pending: ExtensionInspection?
    @State private var plan: ExtensionUpdatePlan?
    @State private var message: String?

    var body: some View {
        Section("Download extensions") {
            Text("Rule files that suggest download addresses and file names for addresses you paste into Add Download. They are data, not programs: they cannot run code, use the network, read your browsing, or start a download. Any address they suggest is shown to you, and a download from it is never started by the app itself.")
                .settingsNote()
            ForEach(manager.installed) { ext in row(ext) }
            if manager.installed.isEmpty { Text("No download extensions are installed.").foregroundStyle(.secondary) }
            HStack {
                Button("Install Extension…") { updating = nil; importing = true }
                if let message { Text(message).font(.caption).foregroundStyle(.orange).lineLimit(3) }
            }
            if let pending { approval(pending) }
            if let plan { updateApproval(plan) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder, .data], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            Task { @MainActor in
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                message = nil
                do {
                    if updating != nil { plan = try await manager.prepareUpdate(url) } else { pending = try await manager.inspect(url) }
                } catch { message = (error as? LocalizedError)?.errorDescription ?? "That could not be opened." }
            }
        }
    }

    @ViewBuilder private func row(_ ext: InstalledDownloadExtension) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if !ext.manifest.description.isEmpty { Text(ext.manifest.description).font(.caption).foregroundStyle(.secondary) }
                Text("Access").font(.caption.weight(.semibold))
                ForEach(ext.manifest.capabilities.sorted { $0.rawValue < $1.rawValue }, id: \.self) { c in
                    Toggle(c.summary, isOn: Binding(get: { ext.grantedCapabilities.contains(c) }, set: { on in run { try manager.setCapability(ext.id, c, granted: on) } })).font(.caption)
                }
                ForEach(ext.manifest.hostPermissions + ext.manifest.optionalHostPermissions, id: \.self) { h in
                    Toggle("Read addresses matching \(h.text)", isOn: Binding(get: { ext.grantedHosts.contains(h) }, set: { on in run { on ? try manager.grantHost(ext.id, h) : try manager.revokeHost(ext.id, h) } })).font(.caption)
                }
                if !ext.manifest.proposeHosts.isEmpty { Text("May suggest downloads from: " + ext.manifest.proposeHosts.map(\.host).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                ForEach(ext.manifest.settings, id: \.name) { s in setting(ext, s) }
                Text("Storage: \(ext.storageUsed) of \(ext.manifest.storageQuota) bytes").font(.caption2).foregroundStyle(.tertiary)
                if case .damaged(let why) = ext.status { Text(why).font(.caption).foregroundStyle(.orange) }
                let notes = manager.diagnostics.filter { $0.extensionID == ext.id }.suffix(3)
                ForEach(Array(notes)) { n in Text(n.message).font(.caption2).foregroundStyle(.tertiary) }
                HStack {
                    Button("Update…") { updating = ext.id; importing = true }
                    Button("Remove", role: .destructive) { run { try manager.uninstall(ext.id) } }
                }.font(.caption)
            }.padding(.top, 2)
        } label: {
            HStack {
                Toggle(isOn: Binding(get: { ext.enabled }, set: { on in run { try manager.setEnabled(ext.id, on) } })) { Text(ext.manifest.name) }.disabled(ext.status != .ready)
                Text("v" + ext.manifest.version).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func setting(_ ext: InstalledDownloadExtension, _ s: ExtensionManifest.Setting) -> some View {
        let current = manager.settings(ext.id)[s.name] ?? s.defaultValue
        switch s.kind {
        case .boolean: Toggle(s.title, isOn: Binding(get: { current == "true" }, set: { v in run { try manager.setSetting(ext.id, s.name, v ? "true" : "false") } })).font(.caption)
        case .string where !s.options.isEmpty: Picker(s.title, selection: Binding(get: { current }, set: { v in run { try manager.setSetting(ext.id, s.name, v) } })) { ForEach(s.options, id: \.self) { Text($0).tag($0) } }.font(.caption)
        default: TextField(s.title, text: Binding(get: { current }, set: { v in run { try manager.setSetting(ext.id, s.name, v) } })).font(.caption)
        }
    }

    private func approval(_ p: ExtensionInspection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Install “\(p.manifest.name)” \(p.manifest.version)?").font(.callout.weight(.semibold))
            if !p.manifest.authorName.isEmpty { Text("By \(p.manifest.authorName)").font(.caption).foregroundStyle(.secondary) }
            Text("It will be able to:").font(.caption)
            ForEach(p.permissionLines, id: \.self) { Text("• " + $0).font(.caption) }
            if p.manifest.isBroad { Label("It asks to read every address you give it.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Install") { run { try manager.install(p); pending = nil } }.buttonStyle(.borderedProminent)
                Button("Cancel") { manager.discard(p); pending = nil }
            }
        }.padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func updateApproval(_ p: ExtensionUpdatePlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Update “\(p.inspection.manifest.name)” from \(p.from) to \(p.inspection.manifest.version)?").font(.callout.weight(.semibold))
            if p.needsApproval { Text("This version asks for more:").font(.caption); ForEach(p.addedPermissions, id: \.self) { Text("• " + $0).font(.caption) } }
            else { Text("It asks for no more access than before.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Update") { run { try manager.apply(p, approved: p.needsApproval); plan = nil } }.buttonStyle(.borderedProminent)
                Button("Cancel") { manager.discard(p.inspection); plan = nil }
            }
        }.padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); message = nil } catch { message = (error as? LocalizedError)?.errorDescription ?? "That did not work." }
    }
}
