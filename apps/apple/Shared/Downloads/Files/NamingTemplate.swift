import Foundation
import UniformTypeIdentifiers

/// What a finished download is called and which folders it goes under, from a template such as `{site}/{date}/{name}`.
///
/// A template is data, never code: only the tokens below are known, nothing is evaluated, and the result is always a relative path of plain names inside the folder the download was
/// going to. The last part names the file; the parts before it are folders, at most `maxFolders` deep. The file part must keep the name the site gave (`{name}` or `{filename}`), or
/// two different downloads could be given the same name. When two files still end up with one name, the number that is added is not part of the template ("report (2).pdf").
enum NamingTemplate {
    /// `{name}` the name without its ending, `{filename}` the whole name, `{ext}` the ending, `{site}` (or `{host}`) the website, `{type}` the kind of file, `{date}` 2026-11-05, `{time}` 14-30.
    static let tokens = ["{name}", "{filename}", "{ext}", "{site}", "{host}", "{type}", "{date}", "{time}"]
    static let maxFolders = 3
    /// The template itself (as before); the name it makes is cut to `maxLength`.
    static let maxTemplateLength = 120
    static let maxLength = 160
    static let defaultTemplate = "{name}"

    struct Expansion: Equatable {
        /// Folder names under the download folder, outermost first; each is one safe name.
        var folders: [String]
        var name: String
        var relativePath: String { (folders + [name]).joined(separator: "/") }
    }

    /// Nil when the template can be used; otherwise one sentence on why not.
    static func problem(_ template: String) -> String? {
        let t = template.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "The template is empty." }
        if t.count > maxTemplateLength { return "It is too long." }
        if t.hasPrefix("/") || t.hasPrefix("~") { return "A template cannot start with / or ~: it describes a place inside the downloads folder." }
        if t.contains("\\") || t.contains(":") { return "A name cannot contain \\ or :." }
        if t.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return "A name cannot contain control characters." }
        var rest = t
        for token in tokens { rest = rest.replacingOccurrences(of: token, with: "") }
        if rest.contains("{") || rest.contains("}") { return "Only \(tokens.joined(separator: ", ")) can be used between braces." }
        let parts = t.components(separatedBy: "/")
        if parts.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return "A folder or file name between slashes is empty." }
        if parts.contains(where: { $0 == "." || $0 == ".." || $0.hasPrefix(".") }) { return "A name cannot be . or .. or start with a dot." }
        if parts.count - 1 > maxFolders { return "At most \(maxFolders) folders deep." }
        guard let file = parts.last, file.contains("{name}") || file.contains("{filename}") else { return "The last part must contain {name} or {filename}, the name the site gave the file." }
        return nil
    }

    /// The name and folders for a file. An unusable template leaves the file as it was named, in no extra folder.
    static func expand(_ template: String, filename: String, host: String?, now: Date = Date(), category: String? = nil) -> Expansion {
        let plain = DownloadFilename.sanitize(filename) ?? "download"
        guard problem(template) == nil, template.trimmingCharacters(in: .whitespaces) != defaultTemplate else { return Expansion(folders: [], name: plain) }
        let ns = plain as NSString
        let stem = ns.deletingPathExtension, ext = ns.pathExtension
        let day = DateFormatter(), time = DateFormatter()
        for f in [day, time] { f.locale = Locale(identifier: "en_US_POSIX") }
        day.dateFormat = "yyyy-MM-dd"; time.dateFormat = "HH-mm"
        let site = (host ?? "download").replacingOccurrences(of: "www.", with: "")
        let kind = category ?? DownloadCategory.folderName(forFilename: plain)

        func fill(_ part: String) -> String {
            // Values are made safe one at a time, so a site name or a file name cannot add a slash of its own.
            part.replacingOccurrences(of: "{filename}", with: plain)
                .replacingOccurrences(of: "{name}", with: stem)
                .replacingOccurrences(of: "{ext}", with: ext)
                .replacingOccurrences(of: "{site}", with: site)
                .replacingOccurrences(of: "{host}", with: site)
                .replacingOccurrences(of: "{type}", with: kind)
                .replacingOccurrences(of: "{date}", with: day.string(from: now))
                .replacingOccurrences(of: "{time}", with: time.string(from: now))
        }
        let parts = template.trimmingCharacters(in: .whitespaces).components(separatedBy: "/")
        var folders: [String] = []
        for part in parts.dropLast() {
            let cleaned = fill(part).replacingOccurrences(of: "/", with: "-")
            guard let folder = DownloadRule.cleanFolder(DownloadFilename.sanitize(cleaned) ?? "") else { return Expansion(folders: [], name: plain) }
            folders.append(folder)
        }
        let last = parts.last ?? "{name}"
        var out = String(fill(last).prefix(maxLength)).replacingOccurrences(of: "/", with: "-")
        // The ending stays unless the template placed it itself.
        if !last.contains("{filename}"), !last.contains("{ext}"), !ext.isEmpty { out += "." + ext }
        guard let named = DownloadFilename.sanitize(out) else { return Expansion(folders: [], name: plain) }
        return Expansion(folders: folders, name: named)
    }

    /// What a template would produce for an example, for showing next to the field.
    static func preview(_ template: String, now: Date = Date()) -> String {
        if let why = problem(template) { return why }
        return expand(template, filename: "Quarterly report.pdf", host: "www.example.com", now: now).relativePath
    }
}

/// The kind of a file, from its ending and, failing that, what the system knows about that ending. A server's Content-Type is not consulted: it says nothing the person can rely on.
enum DownloadCategory: String, CaseIterable, Identifiable, Sendable {
    case documents = "Documents", images = "Images", video = "Video", audio = "Audio", archives = "Archives", applications = "Applications", other = "Other"
    var id: String { rawValue }

    static func of(filename: String) -> DownloadCategory {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "tiff", "bmp", "avif": return .images
        case "pdf", "doc", "docx", "pages", "txt", "rtf", "md", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key", "epub": return .documents
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz": return .archives
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff": return .audio
        case "mp4", "mov", "m4v", "mkv", "avi", "webm": return .video
        case "dmg", "pkg", "mpkg", "app", "iso", "exe", "msi", "apk", "ipa": return .applications
        default: break
        }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .spreadsheet) || type.conforms(to: .presentation) { return .documents }
        if type.conforms(to: .application) || type.conforms(to: .diskImage) { return .applications }
        return .other
    }

    /// The folder name sorted downloads use. The existing folders keep their names ("Installers" for applications), so files already sorted stay where they are.
    static func folderName(forFilename name: String) -> String {
        let kind = of(filename: name)
        return kind == .applications ? "Installers" : kind.rawValue
    }
}
