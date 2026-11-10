import CryptoKit
import UniformTypeIdentifiers
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
    /// Optional narrowing, all absent in rules saved before they existed (so those still decode and still behave exactly as they did).
    /// A Uniform Type Identifier the file must conform to ("public.image"), the browser profile the rule is for, and a folder outside the downloads folder the person chose
    /// (kept as a security-scoped bookmark, never as a path to trust).
    var uti: String?
    var profile: String?
    var bookmark: Data?
    var bookmarkName: String?
    var id: String {
        let base = "\(host.lowercased())|\(kind.rawValue)"
        let extra = [uti ?? "", profile ?? ""]
        return extra.allSatisfy(\.isEmpty) ? base : base + "|" + extra.joined(separator: "|")
    }

    /// How specific the rule is: a site outranks a type, a type outranks a profile. Equal rules keep the order the person put them in.
    var specificity: Int { (host.isEmpty ? 0 : 4) + (uti == nil ? 0 : 2) + (profile == nil ? 0 : 1) }

    static func cleanFolder(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 60, !trimmed.hasPrefix("."), trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains(":") else { return nil }
        return trimmed
    }

    func matches(sourceHost: String?, filename: String, profile currentProfile: String? = nil) -> Bool {
        if !host.isEmpty {
            guard let h = sourceHost?.lowercased() else { return false }
            let want = host.lowercased()
            guard h == want || h.hasSuffix("." + want) else { return false }
        }
        if let profile, profile != currentProfile { return false }           // a rule for one profile never applies to another
        if let uti {
            guard let type = UTType(filenameExtension: (filename as NSString).pathExtension), let wanted = UTType(uti), type.conforms(to: wanted) else { return false }
        }
        return kind.matches(extension: (filename as NSString).pathExtension)
    }
}

enum DownloadRouting {
    /// The rule that applies: the most specific one that matches, and among equals the first the person listed. Nil leaves the file where it would go.
    static func rule(for filename: String, from host: String?, profile: String? = nil, rules: [DownloadRule]) -> DownloadRule? {
        let matching = rules.enumerated().filter { $0.element.matches(sourceHost: host, filename: filename, profile: profile) }
        return matching.sorted { ($0.element.specificity, -$0.offset) > ($1.element.specificity, -$1.offset) }.first?.element
    }

    /// The folder the first matching rule names (rules with a site come before ones without), or nil to leave the file where it would go.
    static func folder(for filename: String, from host: String?, profile: String? = nil, rules: [DownloadRule]) -> String? {
        rule(for: filename, from: host, profile: profile, rules: rules)?.folder
    }

    /// A name that does not overwrite an existing file: "a.pdf", "a 2.pdf", "a 3.pdf".
    static func uniqueName(_ name: String, existing: (String) -> Bool) -> String { FileNaming.unique(name, style: .spaced, existing: existing) }
}

/// The one place that turns a name that is taken into one that is free. Downloads use "name (1).ext"; copies the browser makes of a file (a PDF edit, a split) use "name 2.ext".
enum FileNaming {
    enum Style { case parenthesized, spaced }

    static func unique(_ name: String, style: Style, existing: (String) -> Bool) -> String {
        guard existing(name) else { return name }
        let ns = name as NSString, base = ns.deletingPathExtension, ext = ns.pathExtension
        for n in (style == .spaced ? 2 : 1)...999 {
            let tag = style == .spaced ? " \(n)" : " (\(n))"
            let candidate = ext.isEmpty ? base + tag : base + tag + "." + ext
            if !existing(candidate) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(6))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    enum PublishError: Error, LocalizedError {
        case noFreeName(String), failed(String)
        var errorDescription: String? { switch self { case .noFreeName(let n): "No free name was found for “\(n)”."; case .failed(let why): "The file could not be put in place (\(why))." } }
    }

    /// Gives a finished file (`partial`, anywhere) its final name, atomically and without ever replacing an existing file. The name is claimed by the rename itself (`RENAME_EXCL`: it fails if the name
    /// exists), not by looking first, so two saves of the same name running at once cannot both get it: the second gets "name (2).ext", "name (3).ext"… Returns the name actually used.
    /// `claim` is the exclusive rename (returns 0 or an errno); tests replace it to make a volume that has none.
    /// A `partial` on another volume is first copied beside the destination (so the claim is still one rename on one volume).
    @discardableResult
    static func publish(_ partial: URL, as preferred: URL, firstNumber: Int = 2, claim: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }) throws -> URL {
        let fm = FileManager.default
        let dir = preferred.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var source = partial, copied: URL?
        let ns = preferred.lastPathComponent as NSString
        let stem = ns.deletingPathExtension, ext = ns.pathExtension
        var number = firstNumber - 1
        var target = preferred
        defer { if let copied { try? fm.removeItem(at: copied) } }
        while true {
            let code: Int32 = claim(source.path, target.path)
            switch code {
            case 0:
                if copied != nil { try? fm.removeItem(at: partial); copied = nil }
                return target
            case EEXIST:
                number += 1
                guard number < 10_000 else { throw PublishError.noFreeName(preferred.lastPathComponent) }
                target = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)")
            case EXDEV where copied == nil:
                let beside = dir.appendingPathComponent(".\(UUID().uuidString.prefix(8)).bsetu-pub")
                copied = beside          // set first: a copy that fails half-way is removed too
                do { try fm.copyItem(at: partial, to: beside) } catch { throw PublishError.failed(error.localizedDescription) }
                source = beside
            case ENOTSUP, EINVAL:
                // This volume (FAT/exFAT, some network shares) has no exclusive rename. The name is claimed another atomic way every file system has: create it exclusively, then rename over our own
                // empty placeholder. Either way nothing that was there before is ever replaced.
                let fd = open(target.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                if fd < 0 {
                    if errno == EEXIST { number += 1; guard number < 10_000 else { throw PublishError.noFreeName(preferred.lastPathComponent) }
                        target = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"); continue }
                    throw PublishError.failed(String(cString: strerror(errno)))
                }
                close(fd)
                if rename(source.path, target.path) != 0 {
                    // The file is on another volume: copy it beside the destination first, then the rename is on one volume.
                    if errno == EXDEV, copied == nil {
                        let beside = dir.appendingPathComponent(".\(UUID().uuidString.prefix(8)).bsetu-pub")
                        copied = beside
                        do { try fm.copyItem(at: partial, to: beside) } catch { unlink(target.path); throw PublishError.failed(error.localizedDescription) }
                        source = beside
                        if rename(source.path, target.path) == 0 { try? fm.removeItem(at: partial); copied = nil; return target }
                    }
                    let why = String(cString: strerror(errno)); unlink(target.path); throw PublishError.failed(why)
                }
                if copied != nil { try? fm.removeItem(at: partial); copied = nil }
                return target
            default:
                throw PublishError.failed(String(cString: strerror(code)))
            }
        }
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
