import CryptoKit
import Foundation
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: Two-factor codes

enum TOTP {
    /// Base32 (RFC 4648) to bytes; spaces, dashes and case are ignored. Nil for anything else.
    static func decodeBase32(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in text.uppercased().filter({ $0 != " " && $0 != "-" && $0 != "=" }) {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | i; bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((value >> bits) & 0xFF)) }
        }
        return out.isEmpty ? nil : out
    }

    /// The code for a secret at a moment (RFC 6238, SHA-1, 30-second steps, 6 digits by default).
    static func code(secret: String, at date: Date = Date(), digits: Int = 6, period: Double = 30) -> String? {
        guard let key = decodeBase32(secret) else { return nil }
        var counter = UInt64(date.timeIntervalSince1970 / period).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var divisor: UInt32 = 1
        for _ in 0..<digits { divisor *= 10 }
        return String(format: "%0\(digits)d", Int(binary % divisor))
    }

    static func secondsLeft(at date: Date = Date(), period: Double = 30) -> Int { Int(period - date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)) }

    /// The secret out of what a person pastes: the bare secret, or an otpauth:// link as a QR code reader gives it.
    static func secret(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("otpauth://"), let items = URLComponents(string: t)?.queryItems, let s = items.first(where: { $0.name == "secret" })?.value { return decodeBase32(s) == nil ? nil : s }
        return decodeBase32(t) == nil ? nil : t
    }
}

struct TwoFactorEntry: Codable, Identifiable, Equatable { var id = UUID(); var label: String; var secret: String }
struct SecureNote: Codable, Identifiable, Equatable { var id = UUID(); var title: String; var body: String; var date = Date() }

/// Codes and notes are sealed in the Keychain for this profile, on this device. Nothing here is synced or sent.
enum VaultStore {
    private static func service(_ profile: String) -> String { "com.browsersetu.vault." + profile }

    static func load<T: Decodable>(_ account: String, profile: String, as: T.Type) -> [T] {
        guard let data = SecretStore.get(service: service(profile), account: account), let list = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return list
    }

    @discardableResult
    static func save<T: Encodable>(_ list: [T], _ account: String, profile: String) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        return SecretStore.put(data, service: service(profile), account: account) != .failed
    }
}

// MARK: Tasks

struct SiteTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var site: String
    var done = false
    var added = Date()
}

// MARK: Searching saved pages

enum WebArchiveText {
    /// The readable text of a saved web archive: its main page, with markup removed. Empty if the file is not an archive.
    static func extract(from url: URL) -> String {
        guard let data = try? Data(contentsOf: url), data.count < 60_000_000,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any], let html = main["WebResourceData"] as? Data else { return "" }
        var text = String(decoding: html, as: UTF8.self)
        text = text.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
        return FeedParser.plain(text)
    }

    static func snippet(in text: String, for query: String, radius: Int = 70) -> String? {
        guard let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(r.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        return "…" + text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

// MARK: The model

@MainActor
extension BrowserModel {
    func loadMoreTools() {
        siteTasks = Self.decodeMap(try? core.getSetting(key: "site_tasks"), as: [SiteTask].self)["list"] ?? []
        downloadTags = Self.decodeMap(try? core.getSetting(key: "download_tags"), as: [String].self)
    }

    func saveTasks() { saveSetting("site_tasks", encodedMap(["list": siteTasks])) }

    func addTask(_ text: String, site: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, siteTasks.count < 300 else { return }
        siteTasks.insert(SiteTask(text: String(clean.prefix(200)), site: site), at: 0)
        saveTasks()
    }

    func remind(_ task: SiteTask) {
        Task { @MainActor in
            do { try await ReminderMaker.add(title: task.text, notes: task.site.isEmpty ? nil : "From Browser Setu · \(task.site)"); notice = "Added to Reminders." }
            catch { notice = "Allow Reminders for Browser Setu in System Settings to do this." }
        }
    }

    func tags(forDownload name: String) -> [String] { downloadTags[name] ?? [] }

    func addDownloadTag(_ tag: String, to name: String) {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty, clean.count <= 24 else { return }
        var list = downloadTags[name] ?? []
        if !list.contains(clean) { list.append(clean) }
        downloadTags[name] = list
        saveSetting("download_tags", encodedMap(downloadTags))
    }

    func removeDownloadTag(_ tag: String, from name: String) {
        downloadTags[name] = (downloadTags[name] ?? []).filter { $0 != tag }
        if downloadTags[name]?.isEmpty == true { downloadTags[name] = nil }
        saveSetting("download_tags", encodedMap(downloadTags))
    }

    /// A picture-perfect copy of the whole page as a PDF, opened in the editor so it can be drawn on, highlighted, redacted or signed.
    func annotatePageScreenshot() async {
        guard let tab = active, !tab.isBlank, let data = await tab.engine.pagePDF(), !data.isEmpty else { notice = "This page could not be captured."; return }
        let folder = DownloadCoordinator.directory.appendingPathComponent("Page Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(tab.displayTitle.replacingOccurrences(of: "[/\\\\:\\n\\r]+", with: "-", options: .regularExpression).prefix(60))
        let url = DownloadCoordinator.uniqueURL(in: folder, name: (name.isEmpty ? "Page" : name) + ".pdf")
        guard (try? data.write(to: url, options: .atomic)) != nil else { notice = "The screenshot could not be saved."; return }
        editPDF(at: url)
    }

    /// Reopens the pages of the newest checkpoint that are not open now (the same as picking it in the Session Time Machine).
    func reopenLastSession() {
        loadCheckpoints()
        guard let latest = checkpoints.first else { notice = "There is no saved session to reopen yet."; return }
        restoreCheckpoint(latest)
    }
}

// MARK: Screens

struct VaultView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var unlocked = false
    @State private var codes: [TwoFactorEntry] = []
    @State private var notes: [SecureNote] = []
    @State private var label = ""
    @State private var secret = ""
    @State private var problem: String?
    @State private var noteTitle = ""
    @State private var noteBody = ""
    @State private var editing: SecureNote?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        List {
            if !unlocked {
                Section {
                    Button("Unlock the Vault") { Task { if await model.requireAuthentication("Open your codes and secure notes") { load() } } }
                } footer: { Text("Two-factor codes and secure notes are sealed in your Keychain, on this device, for this profile. They are not synced and never leave it.") }
            } else {
                Section("Two-Factor Codes") {
                    if codes.isEmpty { Text("No codes yet.").foregroundStyle(.secondary) }
                    ForEach(codes) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.label)
                                Text("\(TOTP.secondsLeft(at: now)) s left").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(TOTP.code(secret: entry.secret, at: now).map { $0.prefix(3) + " " + $0.suffix(3) } ?? "Invalid secret").font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                            Button("Copy") { copySecretToPasteboard(TOTP.code(secret: entry.secret, at: now) ?? "", clearAfter: 30) }.buttonStyle(.borderless)
                            Button(role: .destructive) { codes.removeAll { $0.id == entry.id }; persist() } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless)
                        }
                    }
                    TextField("Name (the site or account)", text: $label).textFieldStyle(.roundedBorder)
                    SecureField("Secret key, or the otpauth:// link", text: $secret).textFieldStyle(.roundedBorder)
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                    Button("Add Code") {
                        guard !label.isEmpty, let s = TOTP.secret(from: secret) else { problem = "That is not a valid secret key."; return }
                        codes.append(TwoFactorEntry(label: String(label.prefix(60)), secret: s)); persist(); label = ""; secret = ""; problem = nil
                    }.disabled(label.isEmpty || secret.isEmpty)
                }
                Section("Secure Notes") {
                    ForEach(notes) { note in
                        HStack {
                            Button { editing = note } label: { VStack(alignment: .leading) { Text(note.title.isEmpty ? "Untitled" : note.title).fontWeight(.medium); Text(note.body).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }.buttonStyle(.plain)
                            Spacer()
                            Button(role: .destructive) { notes.removeAll { $0.id == note.id }; persist() } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless)
                        }
                    }
                    TextField("Title", text: $noteTitle).textFieldStyle(.roundedBorder)
                    TextEditor(text: $noteBody).frame(height: 80).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                    Button("Save Note") {
                        notes.insert(SecureNote(title: String(noteTitle.prefix(80)), body: String(noteBody.prefix(5000))), at: 0)
                        persist(); noteTitle = ""; noteBody = ""
                    }.disabled(noteTitle.isEmpty && noteBody.isEmpty)
                }
                Section { Button("Lock") { unlocked = false; codes = []; notes = [] } }
            }
        }
        .onReceive(tick) { now = $0 }
        .onDisappear { unlocked = false; codes = []; notes = [] }
        .sheet(item: $editing) { note in
            VStack(alignment: .leading, spacing: 10) {
                Text(note.title.isEmpty ? "Untitled" : note.title).font(.headline)
                ScrollView { Text(note.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Button("Copy") { copySecretToPasteboard(note.body, clearAfter: 90) }; Spacer(); Button("Done") { editing = nil } }
            }.padding(20).frame(minWidth: 360, minHeight: 240)
        }
    }

    /// Writes both lists to the Keychain. If it refuses, the person is told: the lists on screen are then not stored and would be gone at the next unlock.
    private func persist() {
        let saved = VaultStore.save(codes, "codes", profile: model.profileName) && VaultStore.save(notes, "notes", profile: model.profileName)
        if !saved { model.notice = "The Keychain would not store this, so it will be gone when the vault is locked." }
    }

    private func load() {
        codes = VaultStore.load("codes", profile: model.profileName, as: TwoFactorEntry.self)
        notes = VaultStore.load("notes", profile: model.profileName, as: SecureNote.self)
        unlocked = true
    }
}

struct TasksView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var text = ""
    @State private var forThisSite = true

    private var site: String { forThisSite ? (model.active?.url?.host.flatMap { FaviconStore.key(forHost: $0) } ?? "") : "" }

    var body: some View {
        List {
            Section {
                TextField("A task", text: $text).textFieldStyle(.roundedBorder).onSubmit(add)
                if model.active?.url?.host != nil { Toggle("Tie it to \(FaviconStore.key(forHost: model.active?.url?.host) ?? "this site")", isOn: $forThisSite) }
                Button("Add Task", action: add).disabled(text.isEmpty)
            }
            Section("Open") {
                let open = model.siteTasks.filter { !$0.done }
                if open.isEmpty { Text("Nothing to do.").foregroundStyle(.secondary) }
                ForEach(open) { row($0) }
            }
            let done = model.siteTasks.filter(\.done)
            if !done.isEmpty {
                Section("Done") {
                    ForEach(done.prefix(30)) { row($0) }
                    Button("Clear Done", role: .destructive) { model.siteTasks.removeAll(where: \.done); model.saveTasks() }
                }
            }
        }
    }

    private func add() { model.addTask(text, site: site); text = "" }

    private func row(_ task: SiteTask) -> some View {
        HStack {
            Button { toggle(task) } label: { Image(systemName: task.done ? "checkmark.circle.fill" : "circle").foregroundStyle(task.done ? Theme.accent : Color.secondary).accessibilityLabel(task.done ? "Mark not done" : "Mark done") }.buttonStyle(.plain)
            VStack(alignment: .leading) {
                Text(task.text).strikethrough(task.done)
                if !task.site.isEmpty { Text(task.site).font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
            if !task.done { Button("Remind") { model.remind(task) }.buttonStyle(.borderless).font(.caption) }
            if !task.site.isEmpty { Button("Open") { model.open(urlString: "https://" + task.site, newTab: true) }.buttonStyle(.borderless).font(.caption) }
            Button(role: .destructive) { model.siteTasks.removeAll { $0.id == task.id }; model.saveTasks() } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless)
        }
    }

    private func toggle(_ task: SiteTask) {
        if let i = model.siteTasks.firstIndex(where: { $0.id == task.id }) { model.siteTasks[i].done.toggle(); model.saveTasks() }
    }
}
