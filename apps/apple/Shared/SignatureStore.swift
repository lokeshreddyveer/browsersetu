import Foundation

/// Signatures kept for reuse. Each one is stored in the Keychain on this device, separately for each profile, and is only handed over after Touch ID or the password.
enum SignatureStore {
    struct Saved: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var signature: PDFEdit.Signature
    }

    static let maxSaved = 12
    static func service(profile: String) -> String { "com.browsersetu.signature." + profile }

    static func list(profile: String) -> [Saved] {
        SecretStore.accounts(service: service(profile: profile)).compactMap { account in
            SecretStore.get(service: service(profile: profile), account: account).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Keeps a signature under a name. A name already used is replaced; the number kept is limited.
    @discardableResult
    static func save(_ signature: PDFEdit.Signature, named name: String, profile: String) -> Saved? {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty, !signature.isEmpty, signature.strokes.count <= 40, signature.strokes.allSatisfy({ $0.count <= 4_000 }) else { return nil }
        var existing = list(profile: profile)
        if let same = existing.first(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) { forget(same, profile: profile); existing.removeAll { $0.id == same.id } }
        guard existing.count < maxSaved else { return nil }
        let item = Saved(name: clean, signature: signature)
        guard let data = try? JSONEncoder().encode(item), SecretStore.set(data, service: service(profile: profile), account: item.id.uuidString) else { return nil }
        return item
    }

    static func forget(_ item: Saved, profile: String) { SecretStore.delete(service: service(profile: profile), account: item.id.uuidString) }
    static func removeAll(profile: String) { SecretStore.deleteAll(service: service(profile: profile)) }
}

extension BrowserModel {
    /// Touch ID or the password, every time a saved signature is used (within a minute of the last yes it is not asked again), whether or not the settings lock is on.
    func authenticateForSignature() async -> Bool {
        if Date().timeIntervalSince(lastAuthentication) < 60 { return true }
        let ok = await BiometricGate.authenticate(reason: "Use a saved signature")
        if ok { lastAuthentication = Date() }
        return ok
    }
}
