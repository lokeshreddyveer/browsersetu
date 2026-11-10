import Foundation
import UniformTypeIdentifiers

// What may be previewed, and whether a file that is still downloading may.
//
// A preview only ever shows a file: nothing is opened with another program and nothing is run. Programs, packages, scripts and anything the system treats as executable are
// refused outright; the file must be a plain file (not a link) inside a folder the app may use.

enum MediaPreviewKind: Equatable, Sendable {
    case video, audio, image, document
    case unsupported(String)
    var isPreviewable: Bool { if case .unsupported = self { false } else { true } }
}

enum MediaPreviewPolicy {
    /// Documents Quick Look is asked to show: text, PDF and the common office and data types. Not anything executable or an app bundle.
    static func kind(of url: URL) -> MediaPreviewKind {
        let head: Data = {
            guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? h.close() }
            return (try? h.read(upToCount: 512)) ?? Data()
        }()
        let container = MediaFactsReader.sniffContainer(head)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey, .isExecutableKey, .isPackageKey])
        if values?.isSymbolicLink == true { return .unsupported("This is a link, not a file.") }
        guard values?.isRegularFile == true else { return .unsupported("This is not a plain file.") }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type {
            let blocked: [UTType] = [.executable, .unixExecutable, .application, .applicationBundle, .shellScript, .script, .package, .diskImage, .archive]
            if blocked.contains(where: { type.conforms(to: $0) }) { return .unsupported("Programs, scripts and archives are never opened from a preview.") }
        }
        if values?.isExecutable == true, (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 0, url.pathExtension.isEmpty { return .unsupported("Programs are never opened from a preview.") }
        // The first bytes decide for media, not the name.
        if let container {
            switch container {
            case "MP3", "AAC (ADTS)", "WAV", "AIFF", "Core Audio", "FLAC", "MPEG-4 audio": return .audio
            case "MP4", "QuickTime", "3GPP": return type?.conforms(to: .audio) == true ? .audio : .video
            case "Image": return .image
            case "Matroska/WebM", "AVI", "Ogg": return .unsupported("\(container) cannot be played by the system. Nothing is converted unless you ask.")
            case "HLS playlist": return .unsupported("A playlist is not a media file.")
            default: break
            }
        }
        guard let type else { return .unsupported("The kind of file is not known.") }
        if type.conforms(to: .image) { return container == "Image" || container == "HEIF image" ? .image : .unsupported("The file's contents are not a picture, whatever its name says.") }
        if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audio) {
            return .unsupported("The file's contents are not audio or video the system can play, whatever its name says.")
        }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) || type.conforms(to: .rtf) || type.conforms(to: .json) || type.conforms(to: .xml) { return .document }
        return .unsupported("There is no preview for this kind of file.")
    }

    /// A preview is shown only when the file is inside a folder the app may use (links followed) and, for a private download, only for the session that owns it.
    static func mayPreview(_ url: URL, roots: [URL]) -> Bool { DownloadPathPolicy.isAuthorized(url.path, roots: roots) }
}

/// Whether a download that has not finished can be looked at.
///
/// A picture can be taken from a half-written file only when (1) the container is MP4 or QuickTime, (2) its index (`moov`) comes before the media data and lies wholly inside the part
/// that is certainly there, (3) that part is a continuous run from the start of the file (a download in several pieces fills in the middle first, so it is refused), and (4) the file
/// is not being put in place. What is shown is a read-only copy of that part, never the file being written; a live transfer is not touched. Even then only the first part of the
/// movie plays: the rest is missing.
enum PartialPreview {
    enum Decision: Equatable, Sendable {
        case allowed(bytes: Int64)
        case refused(String)
    }
    static let maxSnapshot: Int64 = 512 * 1024 * 1024

    /// The top-level boxes in the first bytes of an MP4/QuickTime file, as (type, start, size). A size of 0 means "to the end of the file" and 1 means a 64-bit size follows.
    static func topLevelBoxes(_ head: Data, knownLength: Int64) -> [(type: String, start: Int64, size: Int64)] {
        var boxes: [(String, Int64, Int64)] = []
        var position: Int64 = 0
        while position + 8 <= Int64(head.count), boxes.count < 64 {
            let i = head.startIndex + Int(position)
            var size = Int64(head[i]) << 24 | Int64(head[i + 1]) << 16 | Int64(head[i + 2]) << 8 | Int64(head[i + 3])
            let type = String(decoding: head[(i + 4)..<(i + 8)], as: UTF8.self)
            if size == 1 {
                guard position + 16 <= Int64(head.count) else { break }
                var wide: UInt64 = 0
                for k in 0..<8 { wide = wide << 8 | UInt64(head[i + 8 + k]) }
                guard wide <= UInt64(Int64.max) else { break }
                size = Int64(wide)
            } else if size == 0 { size = max(8, knownLength - position) }
            guard size >= 8 else { break }
            let (next, overflow) = position.addingReportingOverflow(size)
            if overflow || next <= position { break }
            boxes.append((type, position, size))
            position = next
        }
        return boxes
    }

    /// `contiguousBytes` is how much of the start of the file is certainly written and unbroken; nil when the engine cannot say (pieces, torrents, streams).
    static func evaluate(file: URL, contiguousBytes: Int64?, isFinalizing: Bool, isPrivate: Bool) -> Decision {
        if isFinalizing { return .refused("The file is being put in place; wait for it to finish.") }
        guard let contiguous = contiguousBytes, contiguous > 0 else { return .refused("This download arrives in pieces or from several places at once, so it is not certain which part is complete. Preview it when it has finished.") }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .refused("The partly downloaded file cannot be read.") }
        defer { try? handle.close() }
        let limit = Int(min(contiguous, 1_048_576))
        let head = (try? handle.read(upToCount: limit)) ?? Data()
        guard let container = MediaFactsReader.sniffContainer(head), ["MP4", "QuickTime", "MPEG-4 audio", "3GPP"].contains(container) else {
            return .refused("Only MP4 and QuickTime files can be previewed before they finish.")
        }
        let boxes = topLevelBoxes(head, knownLength: contiguous)
        guard let moov = boxes.first(where: { $0.type == "moov" }) else { return .refused("The index at the start of the file has not arrived yet, or this file keeps it at the end, so it cannot be played yet.") }
        if let mdat = boxes.first(where: { $0.type == "mdat" }), mdat.start < moov.start { return .refused("This file keeps its index after the picture data, so it can only be played when it has finished.") }
        guard moov.size <= contiguous - moov.start else { return .refused("The index has not fully arrived yet.") }
        guard contiguous <= maxSnapshot else { return .refused("The part that has arrived is too large to preview safely.") }
        return .allowed(bytes: contiguous)
    }

    /// Copies the first `bytes` bytes to a new read-only file inside `folder`. The source is only read.
    static func snapshot(of file: URL, bytes: Int64, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = folder.appendingPathComponent("preview-\(UUID().uuidString).\(file.pathExtension.isEmpty ? "mp4" : file.pathExtension)")
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw MediaProcessError.failed("the preview file could not be made") }
        do {
            let input = try FileHandle(forReadingFrom: file), output = try FileHandle(forWritingTo: target)
            defer { try? input.close(); try? output.close() }
            var remaining = min(bytes, maxSnapshot)
            while remaining > 0 {
                let chunk = try input.read(upToCount: Int(min(remaining, 4 * 1024 * 1024))) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
        return target
    }
}
