import CryptoKit
import Foundation

/// A rule for a finished download: by site and/or kind, to a folder name and/or a "ask where" choice.
struct DownloadRule: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case any, images, documents, archives, audio, video, apps
        var title: String { self == .any ? "Anything" : rawValue.capitalized }
        func matches(extension ext: String) -> Bool {
            let e = ext.lowercased()
            switch self {
            case .any: return true
            case .images: return ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff", "bmp"].contains(e)
            case .documents: return ["pdf", "doc", "docx", "txt", "rtf", "pages", "xls", "xlsx", "csv", "ppt", "pptx", "key", "numbers", "epub", "md"].contains(e)
            case .archives: return ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"].contains(e)
            case .audio: return ["mp3", "m4a", "wav", "flac", "aac", "ogg"].contains(e)
            case .video: return ["mp4", "mov", "mkv", "avi", "webm", "m4v"].contains(e)
            case .apps: return ["dmg", "pkg", "app", "exe", "msi", "ipa", "apk"].contains(e)
            }
        }
    }
    var host: String
    var kind: Kind
    /// A folder inside the downloads folder: one safe name, never a path.
    var folder: String
    var id: String { "\(host.lowercased())|\(kind.rawValue)" }

    static func cleanFolder(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 60, !trimmed.hasPrefix("."), trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains(":") else { return nil }
        return trimmed
    }

    func matches(sourceHost: String?, filename: String) -> Bool {
        if !host.isEmpty {
            guard let h = sourceHost?.lowercased() else { return false }
            let want = host.lowercased()
            guard h == want || h.hasSuffix("." + want) else { return false }
        }
        return kind.matches(extension: (filename as NSString).pathExtension)
    }
}

enum DownloadRouting {
    /// The folder the first matching rule names (rules with a site come before ones without), or nil to leave the file where it would go.
    static func folder(for filename: String, from host: String?, rules: [DownloadRule]) -> String? {
        let ordered = rules.filter { !$0.host.isEmpty } + rules.filter { $0.host.isEmpty }
        return ordered.first { $0.matches(sourceHost: host, filename: filename) }?.folder
    }

    /// A name that does not overwrite an existing file: "a.pdf", "a 2.pdf", "a 3.pdf".
    static func uniqueName(_ name: String, existing: (String) -> Bool) -> String {
        guard existing(name) else { return name }
        let ns = name as NSString, base = ns.deletingPathExtension, ext = ns.pathExtension
        for n in 2...999 {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !existing(candidate) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(6))" + (ext.isEmpty ? "" : ".\(ext)")
    }
}

enum DuplicateFiles {
    struct Group: Equatable, Identifiable {
        var size: Int
        var urls: [URL]
        var id: String { urls.map(\.path).joined(separator: "|") }
    }

    /// Files in a folder with the same size and the same contents. Sizes are compared first so only likely matches are read.
    static func find(in folder: URL, digest: (URL) -> String? = { try? Data(contentsOf: $0, options: .mappedIfSafe).sha256Hex }) -> [Group] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var bySize: [Int: [URL]] = [:]
        for f in files {
            let v = try? f.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile == true, let s = v?.fileSize, s > 0 { bySize[s, default: []].append(f) }
        }
        var out: [Group] = []
        for (size, urls) in bySize where urls.count > 1 {
            var byDigest: [String: [URL]] = [:]
            for u in urls { if let d = digest(u) { byDigest[d, default: []].append(u) } }
            for list in byDigest.values where list.count > 1 { out.append(Group(size: size, urls: list.sorted { $0.path < $1.path })) }
        }
        return out.sorted { $0.size > $1.size }
    }
}

extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
