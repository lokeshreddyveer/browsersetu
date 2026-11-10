import CryptoKit
import Foundation

/// A package that has been opened and checked but not installed. Looking at it changes nothing.
struct ExtensionInspection: Identifiable, Equatable, @unchecked Sendable {
    var id: String { manifest.id }
    var manifest: ExtensionManifest
    var rules: ExtensionRuleSet
    var folder: URL                  // a temporary copy; deleted when the inspection is dropped without installing
    var digest: String
    var permissionLines: [String]
    /// The profile it was opened for: it is installed into that profile only.
    var profile = ""
}

struct InstalledDownloadExtension: Identifiable, Equatable {
    enum Status: Equatable { case ready, damaged(String), incompatible(String) }
    var id: String { manifest.id }
    var manifest: ExtensionManifest
    var rules: ExtensionRuleSet?
    var enabled: Bool
    var grantedCapabilities: Set<ExtensionManifest.Capability>
    var grantedHosts: [ExtensionMatchPattern]
    var digest: String
    var status: Status
    var settings: [String: String]
    var storageUsed = 0
    var isActive: Bool { enabled && status == .ready }
}

struct ExtensionUpdatePlan: Equatable {
    var inspection: ExtensionInspection
    var from: String
    var addedPermissions: [String]
    var needsApproval: Bool { !addedPermissions.isEmpty }
}

/// Installs, keeps and runs (as rules) the download extensions of one browser profile. It owns nothing about downloads: it answers "what would these extensions suggest for this address?" and the
/// answer is information. Nothing here can create, start, change or finish a download task; the app's own download code is the only thing that does, and it does not know this exists.
@MainActor
final class DownloadExtensionManager: ObservableObject {
    static let maxPackageBytes = 2 * 1024 * 1024
    static let maxPackageFiles = 50
    static let maxInstalled = 30

    enum Failure: Error, Equatable, LocalizedError {
        case notAPackage(String), tooLarge, unsafe(String), duplicate(String), notInstalled, tooMany, needsApproval, notNewer, differentExtension, failed(String)
        var errorDescription: String? {
            switch self {
            case .notAPackage(let why): "That is not a download extension (\(why))."
            case .tooLarge: "That extension package is larger than is allowed."
            case .unsafe(let what): "The package holds something that is not allowed (\(what)), so it was not opened."
            case .duplicate(let id): "An extension with the id “\(id)” is already installed. Use Update to replace it."
            case .notInstalled: "That extension is not installed."
            case .tooMany: "The most extensions that can be installed is \(DownloadExtensionManager.maxInstalled)."
            case .needsApproval: "This update asks for more access than the installed version, so it needs your approval."
            case .notNewer: "That is not a newer version than the one installed."
            case .differentExtension: "That package is for a different extension."
            case .failed(let why): why
            }
        }
    }

    let profile: String
    private let root: URL
    private let persistent: Bool
    @Published private(set) var installed: [InstalledDownloadExtension] = []
    @Published private(set) var diagnostics: [Diagnostic] = []
    private var storages: [String: ExtensionStorage] = [:]
    #if DEBUG
    /// For tests: makes an update fail after its files are copied, to show the old version is kept.
    var failUpdateAfterCopy = false
    #endif

    struct Diagnostic: Identifiable, Equatable { let id = UUID(); var at: Date; var extensionID: String; var message: String }

    /// `root` is this profile's folder for extensions. A private session passes `persistent: false`: nothing is written to the profile.
    init(root: URL, profile: String, persistent: Bool = true) {
        self.root = root; self.profile = profile; self.persistent = persistent
        if persistent { load() }
    }

    private var packages: URL { root.appendingPathComponent("packages", isDirectory: true) }
    private var indexFile: URL { root.appendingPathComponent("index.json") }
    private func storageFolder(_ id: String) -> URL? { persistent ? root.appendingPathComponent("storage", isDirectory: true).appendingPathComponent(id, isDirectory: true) : nil }

    func log(_ id: String, _ message: String) {
        diagnostics.append(Diagnostic(at: Date(), extensionID: id, message: String(message.prefix(200))))
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
    }

    // MARK: Inspecting

    /// Opens a package (.zip or .crx) or a folder, and checks it completely. Nothing is installed and nothing in it is run.
    func inspect(_ source: URL) async throws -> ExtensionInspection {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else { throw Failure.notAPackage("it is not there") }
        let temp: URL
        if isDir.boolValue { temp = try Self.copyFolder(source) }
        else {
            do { temp = try await ExtensionPackage.unpackAsync(file: source) }
            catch let e as ExtensionPackage.Failure { throw Failure.unsafe(e.errorDescription ?? "unreadable") }
            catch { throw Failure.notAPackage("it could not be unpacked") }
        }
        do { var i = try Self.check(folder: temp); i.profile = profile; return i } catch { ExtensionPackage.discardUnpacked(temp); throw error }
    }

    /// A folder copied into a private temporary place with the same limits as an unpacked package, so the same checks apply to both.
    static func copyFolder(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent("extension-dl-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var bytes = 0, files = 0
        do { try copyContents(of: source, to: dest, files: &files, bytes: &bytes) } catch { try? fm.removeItem(at: dest); throw error }
        return dest
    }

    private static func copyContents(of source: URL, to dest: URL, files: inout Int, bytes: inout Int) throws {
        let fm = FileManager.default
        var folders = 0
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw Failure.notAPackage("unreadable") }
        let base = source.standardizedFileURL.path
        for case let url as URL in walker {
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
            if v.isSymbolicLink == true { throw Failure.unsafe("a link") }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if v.isDirectory == true { folders += 1; guard folders <= maxPackageFiles else { throw Failure.tooLarge }; try fm.createDirectory(at: dest.appendingPathComponent(relative), withIntermediateDirectories: true); continue }
            guard v.isRegularFile == true else { continue }
            files += 1; bytes += v.fileSize ?? 0
            guard files <= maxPackageFiles, bytes <= maxPackageBytes else { throw Failure.tooLarge }
            try fm.copyItem(at: url, to: dest.appendingPathComponent(relative))
        }
    }

    private static func readSmall(_ url: URL, limit: Int) throws -> Data {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard v?.isRegularFile == true, v?.isSymbolicLink != true else { throw Failure.notAPackage("\(url.lastPathComponent) is missing") }
        guard (v?.fileSize ?? Int.max) <= limit else { throw Failure.tooLarge }
        return try Data(contentsOf: url)
    }

    static func check(folder: URL) throws -> ExtensionInspection {
        let fm = FileManager.default
        // size and shape of the whole package, with no link anywhere
        var files = 0, bytes = 0
        if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in walker {
                let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                if v.isSymbolicLink == true { throw Failure.unsafe("a link") }
                if v.isRegularFile == true { files += 1; bytes += v.fileSize ?? 0 }
            }
        }
        guard files <= maxPackageFiles, bytes <= maxPackageBytes else { throw Failure.tooLarge }
        let manifestData = try readSmall(folder.appendingPathComponent("manifest.json"), limit: ExtensionManifest.maxBytes)
        let manifest: ExtensionManifest
        do { manifest = try ExtensionManifest.parse(manifestData) } catch let e as ExtensionManifest.Failure { throw Failure.notAPackage(e.errorDescription ?? "invalid manifest") }
        let entry = folder.appendingPathComponent(manifest.entry)
        guard entry.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { throw Failure.unsafe("the entry file is outside the package") }
        let ruleData = try readSmall(entry, limit: ExtensionRuleSet.maxBytes)
        if let expected = manifest.entrySHA256 {
            guard SHA256.hash(data: ruleData).map({ String(format: "%02x", $0) }).joined() == expected else { throw Failure.unsafe("the rule file does not match the checksum in the manifest") }
        }
        let rules: ExtensionRuleSet
        do { rules = try ExtensionRuleSet.parse(ruleData, manifest: manifest) } catch let e as ExtensionRuleSet.Failure { throw Failure.notAPackage(e.errorDescription ?? "invalid rules") }
        guard let digest = ExtensionPackage.digest(of: folder) else { throw Failure.notAPackage("it could not be read") }
        return ExtensionInspection(manifest: manifest, rules: rules, folder: folder, digest: digest, permissionLines: manifest.permissionLines)
    }

    func discard(_ inspection: ExtensionInspection) { ExtensionPackage.discardUnpacked(inspection.folder) }

    // MARK: Installing

    /// Puts an inspected package in place. `grantOptional` also grants the optional host permissions; otherwise only the required ones are granted. Installed extensions start disabled
    /// unless `enable` is true, so installing and activating are separate steps the person takes.
    @discardableResult
    func install(_ inspection: ExtensionInspection, enable: Bool = true, grantOptional: Bool = false) throws -> InstalledDownloadExtension {
        let m = inspection.manifest
        guard inspection.profile == profile else { throw Failure.failed("That package was opened for a different profile. Open it again here.") }
        guard !installed.contains(where: { $0.id == m.id }) else { throw Failure.duplicate(m.id) }
        guard installed.count < Self.maxInstalled else { throw Failure.tooMany }
        let dest = packageFolder(m.id, m.version)
        if persistent {                                           // a private session keeps the extension in memory only and writes nothing to the profile
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: inspection.folder, to: dest)
                // What is installed must be exactly what was inspected and approved, not whatever the temporary copy held by the time it was copied.
                guard ExtensionPackage.digest(of: dest) == inspection.digest else { throw Failure.unsafe("the files changed while the extension was being installed") }
            } catch { try? FileManager.default.removeItem(at: dest); throw (error as? Failure) ?? Failure.failed("The extension could not be saved.") }
        }
        let ext = InstalledDownloadExtension(manifest: m, rules: inspection.rules, enabled: enable, grantedCapabilities: m.capabilities,
                                             grantedHosts: m.hostPermissions + (grantOptional ? m.optionalHostPermissions : []), digest: inspection.digest, status: .ready, settings: defaults(m))
        installed.append(ext)
        do { try saveIndex() } catch { installed.removeAll { $0.id == m.id }; try? FileManager.default.removeItem(at: dest); throw Failure.failed("The extension list could not be saved.") }
        discard(inspection)
        log(m.id, "Installed version \(m.version)")
        refreshStorageUse(m.id)
        return ext
    }

    private func packageFolder(_ id: String, _ version: String) -> URL { packages.appendingPathComponent(id, isDirectory: true).appendingPathComponent(version, isDirectory: true) }

    private func defaults(_ m: ExtensionManifest) -> [String: String] { Dictionary(uniqueKeysWithValues: m.settings.map { ($0.name, $0.defaultValue) }) }

    func setEnabled(_ id: String, _ on: Bool) throws {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { throw Failure.notInstalled }
        installed[i].enabled = on
        try saveIndex()
        log(id, on ? "Enabled" : "Disabled")
    }

    func uninstall(_ id: String) throws {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { throw Failure.notInstalled }
        let ext = installed.remove(at: i)
        if persistent { try? FileManager.default.removeItem(at: packages.appendingPathComponent(id, isDirectory: true)) }
        storage(for: ext)?.destroy(); storages[id] = nil
        if let folder = storageFolder(id) { try? FileManager.default.removeItem(at: folder) }          // also when the stored data was unreadable
        do { try saveIndex() } catch { installed.insert(ext, at: min(i, installed.count)); throw Failure.failed("The extension list could not be saved, so it was not removed.") }
        log(id, "Uninstalled")
    }

    // MARK: Permissions

    /// Takes access away at once. The next suggestion asked for already sees it gone; nothing is cached.
    func revokeHost(_ id: String, _ pattern: ExtensionMatchPattern) throws {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { throw Failure.notInstalled }
        installed[i].grantedHosts.removeAll { $0 == pattern }
        try saveIndex(); log(id, "Revoked access to \(pattern.text)")
    }

    /// Grants a host the manifest declared (required or optional); anything else is refused.
    func grantHost(_ id: String, _ pattern: ExtensionMatchPattern) throws {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { throw Failure.notInstalled }
        let m = installed[i].manifest
        guard (m.hostPermissions + m.optionalHostPermissions).contains(pattern) else { throw Failure.failed("The extension did not ask for that access.") }
        if !installed[i].grantedHosts.contains(pattern) { installed[i].grantedHosts.append(pattern) }
        try saveIndex(); log(id, "Granted access to \(pattern.text)")
    }

    func setCapability(_ id: String, _ capability: ExtensionManifest.Capability, granted: Bool) throws {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { throw Failure.notInstalled }
        guard installed[i].manifest.capabilities.contains(capability) else { throw Failure.failed("The extension did not declare that capability.") }
        if granted { installed[i].grantedCapabilities.insert(capability) } else { installed[i].grantedCapabilities.remove(capability) }
        try saveIndex(); log(id, "\(granted ? "Allowed" : "Stopped") \(capability.rawValue)")
    }

    // MARK: Settings and storage

    private func storage(for ext: InstalledDownloadExtension) -> ExtensionStorage? {
        if let s = storages[ext.id] { return s }
        guard let s = try? ExtensionStorage(folder: storageFolder(ext.id), quota: ext.manifest.storageQuota) else { return nil }
        storages[ext.id] = s; return s
    }

    private func refreshStorageUse(_ id: String) {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[i].storageUsed = storage(for: installed[i])?.used ?? 0
    }

    /// A setting the extension declared, checked against its type (and its options), saved in that extension's own storage.
    func setSetting(_ id: String, _ name: String, _ value: String) throws {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { throw Failure.notInstalled }
        guard let def = installed[i].manifest.settings.first(where: { $0.name == name }) else { throw Failure.failed("The extension has no such setting.") }
        switch def.kind {
        case .number: guard Double(value) != nil, value.count <= 30 else { throw Failure.failed("That setting must be a number.") }
        case .boolean: guard value == "true" || value == "false" else { throw Failure.failed("That setting must be on or off.") }
        case .string: guard value.count <= ExtensionRuleEngine.maxSettingValue, def.options.isEmpty || def.options.contains(value) else { throw Failure.failed("That is not one of the choices.") }
        }
        guard let s = storage(for: installed[i]) else { throw Failure.failed("The extension's storage could not be opened.") }
        do { try s.set("setting." + name, value) } catch { throw Failure.failed((error as? LocalizedError)?.errorDescription ?? "The setting could not be saved.") }
        installed[i].settings[name] = value
        refreshStorageUse(id)
    }

    func settings(_ id: String) -> [String: String] {
        guard let ext = installed.first(where: { $0.id == id }) else { return [:] }
        var out = defaults(ext.manifest)
        for (k, v) in storage(for: ext)?.all ?? [:] where k.hasPrefix("setting.") { out[String(k.dropFirst(8))] = v }
        return out
    }

    // MARK: Suggestions

    /// What the enabled extensions suggest for an address the person gave. Each extension is asked separately, sees only what it was granted, and a failure in one does not touch the others.
    /// Pure: it reads, it does not log or publish anything, so it is safe to call while a view is being drawn. Across all extensions it never spends more than `totalBudget` seconds.
    func propose(for url: URL, totalBudget: TimeInterval = 0.1) -> [ExtensionProposal] {
        var all: [ExtensionProposal] = []
        let started = ProcessInfo.processInfo.systemUptime
        for ext in installed where ext.isActive {
            guard ProcessInfo.processInfo.systemUptime - started < totalBudget, let rules = ext.rules else { continue }
            all += ExtensionRuleEngine.evaluate(manifest: ext.manifest, rules: rules, input: url, grantedCapabilities: ext.grantedCapabilities, grantedHosts: ext.grantedHosts, settings: settings(ext.id)).proposals
        }
        return all
    }

    // MARK: Updating

    func prepareUpdate(_ source: URL) async throws -> ExtensionUpdatePlan {
        let inspection = try await inspect(source)
        guard let current = installed.first(where: { $0.id == inspection.manifest.id }) else { discard(inspection); throw Failure.differentExtension }
        guard Self.isNewer(inspection.manifest.version, than: current.manifest.version) else { discard(inspection); throw Failure.notNewer }
        let old = Set(current.manifest.permissionLines), new = inspection.manifest.permissionLines
        return ExtensionUpdatePlan(inspection: inspection, from: current.manifest.version, addedPermissions: new.filter { !old.contains($0) })
    }

    /// Replaces the installed version. More access than before needs `approved`; the new version never gets access the person did not see. If anything fails the old version stays exactly as it was.
    func apply(_ plan: ExtensionUpdatePlan, approved: Bool) throws {
        let m = plan.inspection.manifest
        guard plan.inspection.profile == profile else { throw Failure.failed("That update was opened for a different profile.") }
        guard let i = installed.firstIndex(where: { $0.id == m.id }) else { throw Failure.notInstalled }
        let previous = installed[i]
        // The plan is checked against what is installed NOW: a stale one cannot downgrade the extension or write over the live package.
        guard plan.from == previous.manifest.version, Self.isNewer(m.version, than: previous.manifest.version) else { throw Failure.notNewer }
        let old = Set(previous.manifest.permissionLines)
        let added = m.permissionLines.filter { !old.contains($0) }
        if !added.isEmpty && !approved { throw Failure.needsApproval }
        let dest = packageFolder(m.id, m.version)
        let staging = packages.appendingPathComponent(".staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            if persistent {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: plan.inspection.folder, to: staging)
                guard ExtensionPackage.digest(of: staging) == plan.inspection.digest else { throw Failure.unsafe("the files changed while the update was being installed") }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: staging, to: dest)
            }
            #if DEBUG
            if failUpdateAfterCopy { throw Failure.failed("The update failed.") }
            #endif
            // Access carries over only where it still exists in the new version. Only access that is NEW is given, and only if approved; what the person had switched off stays off.
            let newCaps = m.capabilities.subtracting(previous.manifest.capabilities)
            let newHosts = (m.hostPermissions).filter { !previous.manifest.hostPermissions.contains($0) }
            var caps = previous.grantedCapabilities.intersection(m.capabilities)
            var hosts = previous.grantedHosts.filter { g in (m.hostPermissions + m.optionalHostPermissions).contains(g) }
            if approved { caps.formUnion(newCaps); for h in newHosts where !hosts.contains(h) { hosts.append(h) } }
            installed[i] = InstalledDownloadExtension(manifest: m, rules: plan.inspection.rules, enabled: previous.enabled, grantedCapabilities: caps, grantedHosts: hosts, digest: plan.inspection.digest, status: .ready, settings: previous.settings)
            storages[m.id] = nil                                  // the new version may have a different quota
            try saveIndex()
        } catch {
            installed[i] = previous                               // nothing of the failed update remains active
            try? FileManager.default.removeItem(at: staging)
            if persistent { try? FileManager.default.removeItem(at: dest) }
            try? saveIndex()
            log(m.id, "Update failed; version \(previous.manifest.version) kept")
            throw (error as? Failure) ?? Failure.failed("The update failed.")
        }
        if persistent { try? FileManager.default.removeItem(at: packageFolder(m.id, previous.manifest.version)) }
        discard(plan.inspection)
        log(m.id, "Updated to \(m.version)")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for (p, q) in zip(x, y) where p != q { return p > q }
        return x.count > y.count
    }

    // MARK: Saving and loading

    private struct Saved: Codable { var id: String; var version: String; var enabled: Bool; var capabilities: [String]; var hosts: [String]; var digest: String }

    private func saveIndex() throws {
        guard persistent else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let list = installed.map { Saved(id: $0.id, version: $0.manifest.version, enabled: $0.enabled, capabilities: $0.grantedCapabilities.map(\.rawValue).sorted(), hosts: $0.grantedHosts.map(\.text), digest: $0.digest) }
        let data = try JSONEncoder().encode(list)
        let temp = root.appendingPathComponent(".index.\(UUID().uuidString.prefix(6)).tmp")
        try data.write(to: temp)
        if rename(temp.path, indexFile.path) != 0 { let e = errno; try? FileManager.default.removeItem(at: temp); throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO) }
    }

    /// Reads what was saved and checks every package against the fingerprint taken when it was approved. One that was changed since is kept but switched off and marked damaged.
    private func load() {
        guard let data = try? Data(contentsOf: indexFile), data.count < 1_000_000, let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return }
        var seenIDs = Set<String>()
        for s in saved.prefix(Self.maxInstalled) {
            guard seenIDs.insert(s.id).inserted else { continue }
            guard s.id.range(of: #"^[a-z0-9]+([.-][a-z0-9]+){1,7}\z"#, options: .regularExpression) != nil, s.version.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,4}\z"#, options: .regularExpression) != nil else { continue }
            let folder = packageFolder(s.id, s.version)
            do {
                let inspection = try Self.check(folder: folder)
                guard inspection.manifest.id == s.id, inspection.manifest.version == s.version else { throw Failure.unsafe("the saved id does not match") }
                let hosts = s.hosts.compactMap(ExtensionMatchPattern.parse).filter { g in (inspection.manifest.hostPermissions + inspection.manifest.optionalHostPermissions).contains(g) }
                let caps = Set(s.capabilities.compactMap(ExtensionManifest.Capability.init(rawValue:))).intersection(inspection.manifest.capabilities)
                var ext = InstalledDownloadExtension(manifest: inspection.manifest, rules: inspection.rules, enabled: s.enabled, grantedCapabilities: caps, grantedHosts: hosts, digest: s.digest, status: .ready, settings: [:])
                if inspection.digest != s.digest { ext.status = .damaged("The files changed after the extension was approved."); ext.enabled = false; log(s.id, "Switched off: its files changed") }
                installed.append(ext)
                installed[installed.count - 1].settings = settings(ext.id)
            } catch {
                log(s.id, "Could not be loaded: \((error as? LocalizedError)?.errorDescription ?? "unreadable")")
            }
        }
    }
}
