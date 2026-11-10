import SwiftUI
import UniformTypeIdentifiers

/// Downloads → Collect → Remote Files…: servers (SFTP, FTP/FTPS, WebDAV), browsing, choosing, and handing the choice to the ordinary download queue as a collection.
struct RemoteFilesSheet: View {
    @EnvironmentObject var model: BrowserModel
    var done: () -> Void
    var body: some View { RemoteFilesContent(remote: model.remoteBrowser, model: model, done: done) }
}

private struct RemoteFilesContent: View {
    @ObservedObject var remote: RemoteBrowserModel
    @ObservedObject var model: BrowserModel
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Remote Files").font(.system(size: 15, weight: .semibold))
                if let c = remote.connection, remote.phase == .browsing { Text(c.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if remote.connection != nil { Button("Disconnect") { remote.reset() }.controlSize(.small).accessibilityIdentifier("remote-disconnect") }
                Button("Close", action: done).keyboardShortcut(.cancelAction).accessibilityIdentifier("remote-close")
            }
            if let note = remote.securityNote, remote.phase == .idle || remote.phase == .browsing {
                Label(note, systemImage: "lock.open").font(.system(size: 11.5)).foregroundStyle(.orange).accessibilityIdentifier("remote-insecure")
            }
            content
            if let m = remote.message { Text(m).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("remote-message") }
        }
        .padding(18).frame(minWidth: 600, idealWidth: 680, minHeight: 460)
        .accessibilityElement(children: .contain).accessibilityIdentifier("remote-sheet")
        .onAppear { remote.isPrivate = model.active?.leavesNoTrace ?? false }
    }

    @ViewBuilder private var content: some View {
        switch remote.phase {
        case .idle: form
        case .connecting: VStack { Spacer(); ProgressView("Connecting…").controlSize(.small); Spacer() }.frame(maxWidth: .infinity, minHeight: 260)
        case .hostKey(let key): hostKeyPanel(key: key, changedFrom: nil)
        case .hostKeyChanged(let old, let key): hostKeyPanel(key: key, changedFrom: old)
        case .certificate(let fp): certificatePanel(fp)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 10) {
                Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("remote-failed")
                HStack { Button("Try Again") { remote.connectFromForm() }.accessibilityIdentifier("remote-retry"); Button("Change Settings") { remote.reset() } }
                Spacer()
            }.frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        case .browsing: browser
        }
    }

    // MARK: Connecting

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Address, for example sftp://server.example.com/projects/", text: $remote.address).textFieldStyle(.roundedBorder)
                    .onSubmit { remote.open(address: remote.address, origin: .user) }.accessibilityIdentifier("remote-address")
                Button("Open") { remote.open(address: remote.address, origin: .user) }.disabled(remote.address.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("remote-open")
            }
            if !remote.saved.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved servers").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(remote.saved) { c in
                        HStack(spacing: 6) {
                            Button { remote.use(c) } label: { Label("\(c.name)  ·  \(c.scheme.title)", systemImage: c.scheme.isEncrypted ? "lock" : "lock.open") }.buttonStyle(.link).font(.system(size: 12)).accessibilityIdentifier("remote-saved")
                            Spacer()
                            Button { remote.forget(c) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove this saved server and its password").accessibilityLabel("Remove \(c.name)")
                        }
                    }
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Type").foregroundStyle(.secondary)
                    Picker("", selection: $remote.scheme) { ForEach(RemoteScheme.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(maxWidth: 200).accessibilityIdentifier("remote-protocol")
                }
                GridRow {
                    Text("Server").foregroundStyle(.secondary)
                    HStack { TextField("server.example.com", text: $remote.host).textFieldStyle(.roundedBorder).accessibilityIdentifier("remote-host")
                             Text("Port").foregroundStyle(.secondary); TextField("", text: $remote.port).textFieldStyle(.roundedBorder).frame(width: 64).accessibilityIdentifier("remote-port") }
                }
                GridRow {
                    Text("Sign in").foregroundStyle(.secondary)
                    Picker("", selection: $remote.auth) { ForEach(authChoices, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(maxWidth: 200).accessibilityIdentifier("remote-auth")
                }
                if remote.auth == .password || remote.auth == .key {
                    GridRow {
                        Text("User").foregroundStyle(.secondary)
                        TextField("user name", text: $remote.user).textFieldStyle(.roundedBorder).accessibilityIdentifier("remote-user")
                    }
                    GridRow {
                        Text(remote.auth == .key ? "Passphrase" : "Password").foregroundStyle(.secondary)
                        SecureField(remote.auth == .key ? "only if the key has one" : "password", text: $remote.password).textFieldStyle(.roundedBorder).accessibilityIdentifier("remote-password")
                    }
                }
                if remote.auth == .agent { GridRow { Text("User").foregroundStyle(.secondary); TextField("user name (blank: this Mac's)", text: $remote.user).textFieldStyle(.roundedBorder).accessibilityIdentifier("remote-user") } }
                if remote.auth == .key {
                    GridRow {
                        Text("Key file").foregroundStyle(.secondary)
                        HStack { Text(remote.keyPath.isEmpty ? "None chosen" : (remote.keyPath as NSString).lastPathComponent).foregroundStyle(.secondary).lineLimit(1); Button("Choose…") { chooseKey() } }
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle(remote.isPrivate ? "Remember this server (not in a private tab)" : "Remember this server and its password in the Keychain", isOn: $remote.remember).disabled(remote.isPrivate).accessibilityIdentifier("remote-remember")
                }
            }
            HStack { Spacer(); Button("Connect") { remote.connectFromForm() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(remote.host.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("remote-connect") }
            Spacer(minLength: 0)
        }
    }

    private var authChoices: [RemoteConnection.Auth] {
        switch remote.scheme { case .sftp: [.agent, .key, .password]; case .ftp, .ftps: [.anonymous, .password]; case .webdav, .webdavs: [.anonymous, .password] }
    }

    private func chooseKey() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false; p.showsHiddenFiles = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh"); p.message = "Choose your private key file."
        if p.runModal() == .OK, let u = p.url { remote.keyPath = u.path }
    }

    // MARK: Trust

    private func hostKeyPanel(key: HostKeyInfo, changedFrom old: [String]?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let old {
                Label("The server's key has changed", systemImage: "exclamationmark.octagon.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.red)
                Text("You trusted a different key for this server before. That can mean someone is intercepting the connection, or that the server was reinstalled. Do not continue unless you know why it changed.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("Trusted before").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(old, id: \.self) { Text($0).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled) }
            } else {
                Label("Trust this server?", systemImage: "key.horizontal").font(.system(size: 14, weight: .semibold))
                Text("This is the first time you connect to \(remote.host). Make sure the fingerprint is the one the server's owner gave you.").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            Text(old == nil ? "Fingerprint (\(key.type))" : "Now offered (\(key.type))").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(key.fingerprint).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("remote-fingerprint")
            HStack {
                Button("Cancel") { remote.cancelPending() }.keyboardShortcut(old == nil ? .cancelAction : .defaultAction).accessibilityIdentifier("remote-hostkey-cancel")
                Spacer()
                if old == nil {
                    Button("Trust and Connect") { remote.trustAndContinue() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("remote-hostkey-trust")
                } else {
                    Button("Replace Trusted Key and Connect") { remote.trustAndContinue() }.buttonStyle(.bordered).tint(.red).accessibilityIdentifier("remote-hostkey-trust")
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading).accessibilityElement(children: .contain).accessibilityIdentifier("remote-hostkey")
    }

    private func certificatePanel(_ fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This server's certificate is not trusted by your Mac", systemImage: "exclamationmark.shield").font(.system(size: 14, weight: .semibold))
            Text("The server (\(remote.host)) uses a certificate that no authority your Mac knows has signed. If it is your own server, check the fingerprint and trust it for this server only.").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text(fingerprint).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("remote-cert-fingerprint")
            HStack {
                Button("Cancel") { remote.cancelPending() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Trust This Certificate") { remote.trustAndContinue() }.buttonStyle(.borderedProminent).accessibilityIdentifier("remote-cert-trust")
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading).accessibilityElement(children: .contain).accessibilityIdentifier("remote-certificate")
    }

    // MARK: Browsing

    private var browser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { remote.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!remote.canGoBack).help("Back").accessibilityLabel("Back")
                Button { remote.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!remote.canGoForward).help("Forward").accessibilityLabel("Forward")
                Button { remote.goUp() } label: { Image(systemName: "arrow.up") }.disabled(remote.path == "/").help("Enclosing folder").accessibilityIdentifier("remote-up").accessibilityLabel("Enclosing folder")
                Text(remote.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head).textSelection(.enabled).accessibilityIdentifier("remote-path")
                Spacer()
                if remote.listing { ProgressView().controlSize(.small) }
                Button { remote.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload").accessibilityLabel("Reload")
                TextField("Filter", text: $remote.search).textFieldStyle(.roundedBorder).frame(width: 130)
            }.buttonStyle(.borderless)
            List(remote.visible) { entry in row(entry) }.listStyle(.inset).accessibilityIdentifier("remote-list")
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard remote.canChange else { return false }
                    var urls: [URL] = []; let group = DispatchGroup()
                    for p in providers { group.enter(); _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { urls.append(u) }; group.leave() } }
                    group.notify(queue: .main) { remote.requestUpload(urls) }
                    return true
                }
            if let op = remote.operation {
                HStack(spacing: 8) {
                    ProgressView(value: Double(op.done), total: Double(max(1, op.total))).frame(maxWidth: 180)
                    Text("\(op.title) \(op.done) of \(op.total)\(op.current.isEmpty ? "" : " — " + op.current)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Cancel") { remote.cancelOperation() }.controlSize(.small).accessibilityIdentifier("remote-op-cancel")
                }.accessibilityElement(children: .contain).accessibilityIdentifier("remote-operation")
            }
            HStack {
                Text(remote.selection.isEmpty ? "\(remote.entries.count) item\(remote.entries.count == 1 ? "" : "s")" : "\(remote.selectedEntries.count) selected" + (remote.selectedBytes > 0 ? " · \(ByteCountFormatter.string(fromByteCount: remote.selectedBytes, countStyle: .file))" : ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary).accessibilityIdentifier("remote-count")
                Button { chooseUploads() } label: { Image(systemName: "square.and.arrow.up") }.help(remote.isPrivate ? "A server cannot be changed from a private tab" : "Upload files to this folder…").controlSize(.small).disabled(!remote.canChange).accessibilityIdentifier("remote-upload").accessibilityLabel("Upload files")
                Button { remote.requestDelete() } label: { Image(systemName: "trash") }.help(remote.isPrivate ? "A server cannot be changed from a private tab" : "Delete the selected items from the server…").controlSize(.small).disabled(!remote.canChange || remote.selectedEntries.isEmpty).accessibilityIdentifier("remote-delete").accessibilityLabel("Delete from the server")
                Button("Select All") { remote.selectAllFiles() }.controlSize(.small).accessibilityIdentifier("remote-select-all")
                Button("None") { remote.selectNone() }.controlSize(.small)
                Spacer()
                Button("Download \(remote.selectedEntries.count)") { remote.downloadSelection() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(remote.selectedEntries.isEmpty).accessibilityIdentifier("remote-download")
            }
        }
    }

    private func chooseUploads() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true; p.prompt = "Choose"; p.message = "Choose the files to upload to this folder."
        if p.runModal() == .OK { remote.requestUpload(p.urls) }
    }

    private func row(_ e: RemoteEntry) -> some View {
        let selectable = e.isDirectory || e.isDownloadable
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { remote.selection.contains(e.name) }, set: { on in if on { remote.selection.insert(e.name) } else { remote.selection.remove(e.name) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!selectable).accessibilityLabel(e.name)
            Image(systemName: e.isDirectory ? "folder.fill" : (e.isBroken ? "link.badge.plus" : "doc")).foregroundStyle(e.isDirectory ? Color.accentColor : .secondary).frame(width: 18)
            Text(e.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle).foregroundStyle(selectable ? .primary : .secondary)
            Spacer(minLength: 8)
            if let d = e.modified { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
            Text(e.isDirectory ? "Folder" : (e.isBroken ? "Broken link" : (e.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"))).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if e.isDirectory { remote.open(e) } }
        .onTapGesture { if selectable { if remote.selection.contains(e.name) { remote.selection.remove(e.name) } else { remote.selection.insert(e.name) } } }
        .accessibilityElement(children: .contain).accessibilityIdentifier("remote-row")
        .accessibilityLabel(e.name)
        .accessibilityAction(named: "Open") { if e.isDirectory { remote.open(e) } }
    }
}
