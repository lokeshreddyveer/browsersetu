import Foundation
import SwiftUI

// MARK: Password strength

struct StrengthReport: Equatable {
    /// 0 (very weak) to 4 (very strong).
    var score: Int
    var bits: Double
    var tips: [String]
    var label: String { ["Very weak", "Weak", "Fair", "Strong", "Very strong"][min(max(score, 0), 4)] }
    var isWeak: Bool { score <= 1 }
}

enum PasswordStrength {
    static let common: Set<String> = ["password", "123456", "12345678", "123456789", "qwerty", "abc123", "111111", "letmein", "welcome", "admin", "iloveyou", "monkey",
                                      "dragon", "football", "baseball", "sunshine", "master", "login", "princess", "qwertyuiop", "passw0rd", "password1", "1234567890", "000000"]

    static func evaluate(_ password: String, user: String? = nil) -> StrengthReport {
        guard !password.isEmpty else { return StrengthReport(score: 0, bits: 0, tips: ["Enter a password."]) }
        let lower = password.lowercased()
        var tips: [String] = []
        var pool = 0
        if password.contains(where: { $0.isLowercase }) { pool += 26 }
        if password.contains(where: { $0.isUppercase }) { pool += 26 }
        if password.contains(where: { $0.isNumber }) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }
        var bits = Double(password.count) * log2(Double(max(pool, 2)))
        // Repeats and runs add little: "aaaaaa", "123456", "abcdef".
        let chars = Array(lower)
        var repeats = 0, runs = 0
        for i in 1..<max(chars.count, 1) {
            if chars[i] == chars[i - 1] { repeats += 1 }
            if let a = chars[i - 1].asciiValue, let b = chars[i].asciiValue, Int(b) - Int(a) == 1 { runs += 1 }
        }
        bits -= Double(repeats + runs) * log2(Double(max(pool, 2))) * 0.8
        if common.contains(lower) { bits = min(bits, 10); tips.append("This is one of the most common passwords.") }
        else if common.contains(where: { lower.contains($0) && $0.count >= 6 }) { bits -= 12; tips.append("It contains a very common password.") }
        if let user, user.count >= 3, lower.contains(user.lowercased().split(separator: "@").first.map(String.init) ?? user.lowercased()) { bits -= 15; tips.append("It contains your username.") }
        if password.count < 12 { tips.append("Use at least 12 characters.") }
        if pool < 62 && password.count < 20 { tips.append("Mix upper and lower case, numbers and symbols, or use a longer phrase.") }
        if repeats + runs >= 3 { tips.append("Avoid repeated characters and runs like 1234 or abcd.") }
        bits = max(bits, 0)
        let score = bits < 28 ? 0 : (bits < 40 ? 1 : (bits < 60 ? 2 : (bits < 80 ? 3 : 4)))
        return StrengthReport(score: score, bits: bits, tips: score >= 3 ? [] : tips)
    }
}

struct StrengthMeter: View {
    let password: String
    var user: String?

    var body: some View {
        let r = PasswordStrength.evaluate(password, user: user)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in RoundedRectangle(cornerRadius: 2).fill(i <= r.score && !password.isEmpty ? color(r.score) : Color.primary.opacity(0.12)).frame(height: 4) }
            }
            Text(password.isEmpty ? " " : r.label).font(.caption.weight(.medium)).foregroundStyle(color(r.score))
            ForEach(r.tips, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
        }
        .motion(.easeOut(duration: 0.15), value: r.score)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Password strength: \(password.isEmpty ? "none" : r.label)")
    }

    private func color(_ score: Int) -> Color { [Color.red, .orange, .yellow, .green, .green][min(max(score, 0), 4)] }
}

// MARK: Saved addresses

struct SavedAddress: Codable, Identifiable, Equatable {
    var id = UUID()
    var label = ""
    var name = ""
    var organization = ""
    var street = ""
    var street2 = ""
    var city = ""
    var region = ""
    var postal = ""
    var country = ""
    var phone = ""
    var email = ""

    var given: String { name.split(separator: " ").first.map(String.init) ?? name }
    var family: String { name.split(separator: " ").dropFirst().joined(separator: " ") }
    var summary: String { [name, street, city].filter { !$0.isEmpty }.joined(separator: ", ") }
    var isEmpty: Bool { [name, street, city, postal, phone, email].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

/// Addresses are personal data, so they sit in the Keychain, on this device, for this profile only. Payment cards are not handled: the
/// system's card autofill is not available to other browsers' pages, and this browser does not keep card numbers.
enum AddressVault {
    static func service(profile: String) -> String { "com.browsersetu.addresses." + profile }

    static func load(profile: String) -> [SavedAddress] {
        guard let data = SecretStore.get(service: service(profile: profile), account: "list"), let list = try? JSONDecoder().decode([SavedAddress].self, from: data) else { return [] }
        return list
    }

    @discardableResult
    static func save(_ list: [SavedAddress], profile: String) -> Bool {
        guard let data = try? JSONEncoder().encode(Array(list.prefix(20))) else { return false }
        return SecretStore.put(data, service: service(profile: profile), account: "list") != .failed
    }
}

enum AddressFill {
    /// Fills the empty address boxes on the page that say what they are for (the autocomplete attribute, or a clear name). Returns how many were filled.
    static func script(for a: SavedAddress) -> String {
        let values: [String: String] = ["name": a.name, "given-name": a.given, "family-name": a.family, "organization": a.organization, "street-address": [a.street, a.street2].filter { !$0.isEmpty }.joined(separator: "\n"),
                                        "address-line1": a.street, "address-line2": a.street2, "address-level2": a.city, "address-level1": a.region, "postal-code": a.postal,
                                        "country-name": a.country, "country": a.country, "tel": a.phone, "email": a.email]
        let json = (try? String(data: JSONSerialization.data(withJSONObject: values), encoding: .utf8)) ?? "{}"
        return """
        const values = \(json);
        let filled = 0;
        const guess = (el) => {
          const ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(' ').pop();
          if (ac && values[ac] !== undefined) return ac;
          const t = ((el.name || '') + ' ' + (el.id || '')).toLowerCase();
          if (/e-?mail/.test(t)) return 'email';
          if (/zip|postal|post.?code/.test(t)) return 'postal-code';
          if (/phone|mobile|tel/.test(t)) return 'tel';
          return null;
        };
        for (const el of document.querySelectorAll('input, textarea, select')) {
          if (el.disabled || el.readOnly || el.type === 'hidden' || el.type === 'password' || el.type === 'checkbox' || el.type === 'radio') continue;
          const rect = el.getBoundingClientRect(); if (rect.width === 0 || rect.height === 0) continue;
          const key = guess(el); if (!key || !values[key]) continue;
          if (el.tagName !== 'SELECT' && (el.value || '') !== '') continue;
          if (el.tagName === 'SELECT') {
            const option = Array.from(el.options).find(o => o.value.toLowerCase() === values[key].toLowerCase() || o.text.toLowerCase() === values[key].toLowerCase());
            if (!option) continue; el.value = option.value;
          } else {
            const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, values[key]);
          }
          el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
          filled++;
        }
        return filled;
        """
    }
}

@MainActor
extension BrowserModel {
    func savedAddresses() -> [SavedAddress] { AddressVault.load(profile: profileName) }

    /// Fills the address boxes on the page in front, after the person confirms with Touch ID where that is switched on.
    func fillAddress() async {
        guard let tab = active, !tab.isBlank, !tab.isPrivate else { notice = "Open a normal page with an address form first."; return }
        let list = savedAddresses().filter { !$0.isEmpty }
        guard !list.isEmpty else { notice = "Save an address in Settings first."; return }
        var chosen = list[0]
        if list.count > 1 {
            let labels = list.prefix(3).map { $0.label.isEmpty ? $0.summary : $0.label } + ["Cancel"]
            let pick = await Dialogs.choose(title: "Which address?", message: "It fills only empty boxes on this page.", buttons: Array(labels))
            guard pick < min(list.count, 3) else { return }
            chosen = list[pick]
        }
        guard await requireAuthentication("Fill your saved address") else { return }
        let result = await tab.engine.runScratch(AddressFill.script(for: chosen))
        let count = Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        notice = count == 0 ? "No empty address boxes were found on this page." : "Filled \(count) box\(count == 1 ? "" : "es")."
    }
}

struct AddressesSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var list: [SavedAddress] = []
    @State private var editing: SavedAddress?

    var body: some View {
        Section {
            if list.isEmpty { Label("No saved addresses", systemImage: "house").foregroundStyle(.secondary) }
            ForEach(list) { a in
                HStack {
                    VStack(alignment: .leading) { Text(a.label.isEmpty ? (a.name.isEmpty ? "Address" : a.name) : a.label).fontWeight(.medium); Text(a.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Button("Edit") { editing = a }.buttonStyle(.borderless)
                    Button(role: .destructive) { list.removeAll { $0.id == a.id }; AddressVault.save(list, profile: model.profileName) } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless)
                }
            }
            Button("Add an Address…") { editing = SavedAddress() }
            Button("Fill This Page's Address Form") { Task { await model.fillAddress() } }.disabled(list.isEmpty || (model.active?.isBlank ?? true))
        } header: { Text("Saved Addresses") } footer: {
            Text("Kept in your Keychain, on this device, for this profile. Filling happens only when you ask, and only into empty boxes. Payment cards are not saved or filled: the system's card autofill is not open to other browsers.")
        }
        .onAppear { list = model.savedAddresses() }
        .sheet(item: $editing) { address in
            AddressEditor(original: address) { saved in
                if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                AddressVault.save(list, profile: model.profileName)
            }
        }
    }
}

private struct AddressEditor: View {
    @State var original: SavedAddress
    let onSave: (SavedAddress) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Label (Home, Work…)", text: $original.label)
            TextField("Full name", text: $original.name)
            TextField("Company", text: $original.organization)
            TextField("Street address", text: $original.street)
            TextField("Apartment, suite…", text: $original.street2)
            TextField("City", text: $original.city)
            TextField("State or region", text: $original.region)
            TextField("Postal code", text: $original.postal)
            TextField("Country", text: $original.country)
            TextField("Phone", text: $original.phone)
            TextField("Email", text: $original.email)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { onSave(original); dismiss() }.keyboardShortcut(.defaultAction).disabled(original.isEmpty) }
        }
        .padding(20).frame(minWidth: 420)
    }
}

// MARK: Saved pages (offline)

@MainActor
enum SavedPages {
    /// Web archives kept on this device: the Saved Pages folder, and archives saved straight into Downloads.
    static func list() -> [URL] {
        let fm = FileManager.default
        let folders = [DownloadCoordinator.directory.appendingPathComponent("Saved Pages", isDirectory: true), DownloadCoordinator.directory]
        var seen = Set<String>(), out: [URL] = []
        for folder in folders {
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where url.pathExtension.lowercased() == "webarchive" {
                if seen.insert(url.path).inserted { out.append(url) }
            }
        }
        return out.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    static func title(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
extension BrowserModel {
    /// Opens a saved page in a new tab with no connection needed. It shows the page as it was saved and runs none of its scripts.
    func openSavedPage(_ file: URL) {
        let tab = openTab(url: nil, isPrivate: false)
        tab.allowedLocalFile = file
        tab.setReadingTitle(SavedPages.title(file))
        tab.engine.loadLocalFile(file)
    }
}

struct SavedPagesSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var files: [URL] = []
    @State private var query = ""
    @State private var hits: [(file: URL, snippet: String)] = []

    var body: some View {
        Section {
            TextField("Search inside saved pages", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
            ForEach(hits, id: \.file.path) { hit in
                Button { model.openSavedPage(hit.file); model.sheet = nil } label: { VStack(alignment: .leading) { Text(SavedPages.title(hit.file)).fontWeight(.medium); Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2) } }.buttonStyle(.plain)
            }
            if files.isEmpty { Label("No saved pages", systemImage: "square.and.arrow.down").foregroundStyle(.secondary) }
            ForEach(files, id: \.path) { file in
                HStack {
                    Button { model.openSavedPage(file); model.sheet = nil } label: { Label(SavedPages.title(file), systemImage: "doc.richtext").lineLimit(1) }.buttonStyle(.plain)
                    Spacer()
                    Button(role: .destructive) { try? FileManager.default.removeItem(at: file); files = SavedPages.list() } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless)
                }
            }
            Button("Save This Page for Offline…") { Task { await model.savePageForLater(); files = SavedPages.list() } }.disabled(model.active?.isBlank ?? true)
        } header: { Text("Saved Pages") } footer: {
            Text("A page saved as a web archive opens without a connection. It shows the page as it was and runs none of its scripts.")
        }
        .onAppear { files = SavedPages.list() }
        .onChange(of: query) { _, q in if q.isEmpty { hits = [] } }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { hits = []; return }
        let list = files
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [(file: URL, snippet: String)] in
                list.prefix(200).compactMap { f in WebArchiveText.snippet(in: WebArchiveText.extract(from: f), for: q).map { (f, $0) } }
            }.value
            hits = found
        }
    }
}
