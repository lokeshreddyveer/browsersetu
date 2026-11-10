import CryptoKit
import Foundation

// A Metalink document the person chose to open (from a file, a page link or the address bar) becomes ordinary downloads in one DX-10 collection. Mirrors are the existing MirrorStore; the engine,
// naming, resume and history are the HTTP engine's.
//
// Parallel sources are used only when it is safe: the document gives the file's SHA-256 (which the finished file is checked against, so mixed-up bytes from a bad mirror are caught) AND every source
// is a public address. Otherwise the sources are tried one at a time, each from the start, and a document can never aim the browser at this Mac's own network.

enum MetalinkLink {
    static func isMetalink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "meta4" || ext == "metalink"
    }
}

enum MetalinkImport {
    struct Outcome: Equatable { var started = 0, alreadyThere = 0, failed = 0, combined = 0, source = "" }

    static func documentKey(_ data: Data) -> String { "metalink:" + SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined() }

    /// Whether every source of `file` is public: a name is looked up and EVERY address it resolves to must be public (a name an attacker controls may point inside this Mac's network). A name that
    /// cannot be resolved is not public.
    static func isPublic(_ file: MetalinkFile, resolver: HostAddressResolving = SystemHostResolver()) async -> Bool {
        for text in file.urls {
            guard let host = URL(string: text)?.host else { return false }
            if HTTPRequestPolicy.classify(host: host).isInternal { return false }
            let isLiteral = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
            if isLiteral { continue }
            guard let addresses = await resolver.addresses(for: host), !addresses.isEmpty, !addresses.contains(where: { HTTPRequestPolicy.classify(host: $0).isInternal }) else { return false }
        }
        return true
    }

    /// A short, honest summary for the question asked before anything starts.
    static func summary(_ files: [MetalinkFile]) -> String {
        var lines: [String] = []
        for f in files.prefix(6) {
            var l = "• \(f.name)"
            if let s = f.size { l += " (\(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)))" }
            let n = "\(f.urls.count) source\(f.urls.count == 1 ? "" : "s")"
            l += f.sha256 != nil ? " — \(n), checked against its SHA-256" : (f.sha512 != nil ? " — \(n), checked against its SHA-512 when done (one source at a time)" : " — \(n), no hash given, so not checked")
            lines.append(l)
        }
        if files.count > 6 { lines.append("…and \(files.count - 6) more") }
        let notes = Set(files.flatMap(\.notes)).sorted().prefix(3)
        return (lines + notes.map { "Note: \($0)" }).joined(separator: "\n")
    }

    @MainActor
    static func add(_ files: [MetalinkFile], title: String, documentKey key: String, coordinator: DownloadCoordinator, isPrivate: Bool = false, startAt: Date = Date(), resolver: HostAddressResolving = SystemHostResolver()) async -> Outcome {
        var out = Outcome(); out.source = key
        let name = PackageStore.cleanName(title)
        let package = (files.count > 1 && !isPrivate) ? (coordinator.packages.package(withSource: key) ?? coordinator.packages.create(name: name, members: [], source: key)?.package) : nil
        var chosen = 0
        for f in files {
            let itemKey = f.name + "#0"
            if package != nil, coordinator.packages.isCollected(itemKey, source: key) { out.alreadyThere += 1; continue }
            chosen += 1
            // The person opened this document, so a verified file from public sources may use them together; anything else is held to the page rules and tried one source at a time.
            var combine = false
            if f.sha256 != nil { combine = await isPublic(f, resolver: resolver) }
            guard let id = coordinator.addFromMetalink(f, origin: combine ? .user : .page, at: startAt) else { out.failed += 1; continue }
            out.started += 1; if combine && f.urls.count > 1 { out.combined += 1 }
            if let package { coordinator.packages.add([id], to: package.id); coordinator.packages.recordIdentity(itemKey, task: id, in: package.id) }
        }
        if let package, chosen > 0 { coordinator.packages.noteChosen(chosen, in: package.id) }
        return out
    }
}
