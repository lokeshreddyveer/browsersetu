import SwiftUI

/// Settings › Sync: keep bookmarks and (if you want) settings the same across your own devices, and see the tabs open on the others.
struct SyncSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var phrase = ""
    @State private var hasPhrase = false
    @State private var showTabs = false
    @State private var groupDraft = ""
    @State private var showHistory = false

    var body: some View {
        Section {
            Toggle("Sync with iCloud", isOn: $model.iCloudSync)
                .disabled(!CloudSync.available && !model.iCloudSync)
                .accessibilityIdentifier("icloud-sync")
            if !CloudSync.available {
                Label("Sign in to iCloud in the system Settings to turn this on.", systemImage: "icloud.slash").font(.callout).foregroundStyle(.secondary)
            }
            if model.iCloudSync {
                HStack {
                    TextField("Sync group", text: $groupDraft).autocorrectionDisabled().onSubmit { model.changeSyncGroup(groupDraft) }
                    if groupDraft.trimmingCharacters(in: .whitespaces) != model.syncGroupName, !groupDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Join") { model.changeSyncGroup(groupDraft) }
                    }
                }
                if hasPhrase {
                    LabeledContent("Sync passphrase", value: "Saved on this device")
                    Button("Change Passphrase…", role: .none) { hasPhrase = false; phrase = "" }
                } else {
                    SecureField("Passphrase, the same on every device", text: $phrase)
                    Button("Save Passphrase") {
                        guard phrase.count >= 6 else { model.syncStatus = "Use at least 6 characters."; return }
                        SyncKeys.setPassphrase(phrase, profile: model.profileName); hasPhrase = true; phrase = ""
                        Task { await model.syncNowCloud() }
                    }
                }
                Toggle("Also sync settings", isOn: $model.syncSettingsToo)
                if model.syncSettingsToo { Toggle("Ask me when a setting differs", isOn: $model.syncAskOnConflict) }
                Button("Sync Now") { Task { await model.syncNowCloud() } }.disabled(!hasPhrase).accessibilityIdentifier("sync-now")
            }
            if model.iCloudSync, !model.syncDevices.isEmpty {
                ForEach(model.syncDevices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.status == .pending ? "Waiting for your approval" : (device.status == .approved ? "Approved · seen " + device.lastSeen.formatted(date: .abbreviated, time: .shortened) : "Blocked")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if device.status != .approved { Button("Approve") { model.approveSyncDevice(device.id) } }
                        if device.status != .blocked { Button("Block", role: .destructive) { model.blockSyncDevice(device.id) } }
                        if device.status == .blocked { Button("Forget") { model.forgetSyncDevice(device.id) } }
                    }
                }
            }
            ForEach(model.syncConflicts) { conflict in
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(conflict.key)” differs from \(conflict.device)").font(.callout.weight(.medium))
                    Text("This device: \(conflict.mine.isEmpty ? "not set" : String(conflict.mine.prefix(60)))\nThat device: \(conflict.theirs.isEmpty ? "not set" : String(conflict.theirs.prefix(60)))").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("Keep Mine") { model.resolveSyncConflict(conflict, useTheirs: false) }; Button("Use Theirs") { model.resolveSyncConflict(conflict, useTheirs: true) } }
                }
            }
            if !model.syncHistory.isEmpty {
                DisclosureGroup("Sync history", isExpanded: $showHistory) {
                    ForEach(Array(model.syncHistory.suffix(15).reversed().enumerated()), id: \.offset) { _, line in Text(line).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !model.remoteTabs.isEmpty { Button("Tabs on Other Devices…") { showTabs = true } }
            Button("Sync over Wi-Fi with Another Device…") { model.sheet = .devices }
            if let last = model.lastSync { LabeledContent("Last synced", value: last.formatted(date: .abbreviated, time: .shortened)) }
            if !model.syncStatus.isEmpty { Text(model.syncStatus).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("Sync")
        } footer: {
            Text("Bookmarks are added across your devices (never removed), and each device’s open tabs can be reopened on the others. With iCloud, what is stored is scrambled with your passphrase, so Apple cannot read it. Passwords, history, cookies, private tabs and the page index are never synced. Devices only see each other inside one sync group, and a new device waits for your approval. Wi-Fi sync goes straight between your devices with a one-time code, with no server.")
        }
        .sheet(isPresented: $showTabs) { SyncedTabsView() }
        .onAppear { hasPhrase = model.syncPassphrase?.isEmpty == false; groupDraft = model.syncGroupName }
    }
}

struct SyncedTabsView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.remoteTabs) { device in
                    Section {
                        ForEach(device.tabs, id: \.url) { tab in
                            Button { model.open(urlString: tab.url, newTab: true); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.title.isEmpty ? tab.url : tab.title).lineLimit(1)
                                    Text(displayHost(URL(string: tab.url))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: { Text("\(device.device) · \(device.date.formatted(date: .abbreviated, time: .shortened))") }
                }
            }
            .navigationTitle("Tabs on Other Devices")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }
}
