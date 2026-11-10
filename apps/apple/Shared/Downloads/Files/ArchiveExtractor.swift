import Foundation

/// Opens a downloaded `.zip` into a new folder next to it, only when the person asks, and only as far as the contents can be trusted to stay inside that folder.
///
/// Format coverage is deliberately narrow: **ZIP, with stored or deflated entries, not encrypted, not zip64**. Apple's Archive framework reads Apple's own `.aar`/`.yaa` formats, not ZIP, RAR
/// or 7z, and shelling out to a system tool would hand path decisions to it, so the reader already used (and reviewed) for extension packages is reused with stricter limits. Anything else is
/// refused with a plain reason, never half-unpacked.
///
/// Protections: no path outside the folder (absolute paths, "..", backslashes, NUL), no links of any kind, entries must be exactly as long as they say and pass their CRC, overlapping or
/// repeated entries are refused, and there are caps on total size, file count, folder depth and on how much a small zip may expand. Everything is written into a hidden staging folder first
/// and renamed into place only when all of it succeeded, so a failed extraction leaves nothing behind, and an existing file or folder is never overwritten or merged into.
enum ArchiveExtractor {
    enum Failure: LocalizedError, Equatable {
        case notSupported(String), notAFile, notEnoughSpace(needed: Int64, available: Int64), invalid(String)

        var errorDescription: String? {
            switch self {
            case .notSupported(let kind): "\(kind) cannot be opened here. Only ordinary .zip files can."
            case .notAFile: "That is not a file Browser Setu can open."
            case .notEnoughSpace(let needed, let available): "Not enough space: it needs about \(DownloadStats.bytes(needed)) and \(DownloadStats.bytes(available)) is free."
            case .invalid(let why): why
            }
        }
    }

    static let supportedExtensions: Set<String> = ["zip"]

    static var defaultLimits: ExtensionPackage.Limits {
        ExtensionPackage.Limits(maxUnpacked: 2 * 1024 * 1024 * 1024, maxEntries: 10_000, maxDepth: 16, maxRatio: 200, rejectLinks: true)
    }

    /// Whether the file looks like something that can be opened: a regular file (not a link) ending in .zip that starts like one.
    static func canExtract(_ file: URL) -> Bool {
        guard supportedExtensions.contains(file.pathExtension.lowercased()) else { return false }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: 4) else { return false }
        try? handle.close()
        return Array(head) == [0x50, 0x4B, 0x03, 0x04] || Array(head) == [0x50, 0x4B, 0x05, 0x06]
    }

    /// The new folder. `freeSpace` is replaceable so the "disk is nearly full" case can be tested.
    @discardableResult
    static func extract(file: URL, limits: ExtensionPackage.Limits? = nil, freeSpace: @escaping (URL) -> Int64? = { DiskSpace.available(at: $0) }) throws -> URL {
        let limits = limits ?? defaultLimits
        let fm = FileManager.default
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { throw Failure.notAFile }
        guard supportedExtensions.contains(file.pathExtension.lowercased()) else { throw Failure.notSupported(file.pathExtension.isEmpty ? "That kind of file" : ".\(file.pathExtension.lowercased()) files") }
        guard canExtract(file) else { throw Failure.invalid("That does not look like a zip file.") }
        let parent = file.deletingLastPathComponent()
        let data = try Data(contentsOf: file, options: .mappedIfSafe)

        let staging = parent.appendingPathComponent(".\(UUID().uuidString.prefix(8)).bsetu-extract", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try ExtensionPackage.extract(zip: data, into: staging, limits: limits) { declared in
                let need = Int64(declared)
                // Room for the files themselves with a margin, since the disk is shared with everything else.
                if let free = freeSpace(parent), free < need + max(50_000_000, need / 20) { throw Failure.notEnoughSpace(needed: need, available: free) }
            }
            copyQuarantine(from: file, toTreeAt: staging)
            return try place(staging, beside: file)
        } catch let failure as Failure {
            try? fm.removeItem(at: staging); throw failure
        } catch let failure as ExtensionPackage.Failure {
            try? fm.removeItem(at: staging); throw Failure.invalid(describe(failure))
        } catch {
            try? fm.removeItem(at: staging); throw Failure.invalid("The archive could not be opened.")
        }
    }

    /// Renames the finished staging folder to the archive's own name, or "name 2", "name 3" when that is taken. A rename onto an existing folder fails, so nothing is merged or replaced,
    /// and two extractions at once cannot end up with the same name.
    private static func place(_ staging: URL, beside file: URL) throws -> URL {
        let parent = file.deletingLastPathComponent()
        let base = DownloadFilename.sanitize(file.deletingPathExtension().lastPathComponent) ?? "Extracted"
        for n in 1...999 {
            let name = n == 1 ? base : "\(base) \(n)"
            let target = parent.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            // RENAME_EXCL: fails if anything (even an empty folder) is there, instead of replacing it.
            if renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST { throw Failure.invalid("The folder could not be created (\(String(cString: strerror(errno)))).") }
        }
        throw Failure.invalid("No free name was found for the new folder.")
    }

    private static func describe(_ failure: ExtensionPackage.Failure) -> String {
        switch failure {
        case .notAPackage: "The zip is damaged or not a normal zip, so it was not opened."
        case .unsafePath(let name): "It holds an entry that is unsafe to write (“\(name.prefix(60))”: a path outside the folder, or a link), so nothing was unpacked."
        case .tooLarge(let bytes): "It would unpack to about \(DownloadStats.bytes(Int64(bytes))) or expands far more than a normal zip, which is over the safety limit, so nothing was unpacked."
        case .tooManyFiles(let count): "It holds \(count) files, which is over the limit, so nothing was unpacked."
        case .unsupported: "It uses a zip feature that is not supported (password protection or zip64), so it was not opened."
        }
    }

    /// Files taken out of a file from the internet carry the same mark, so Gatekeeper treats them as it would an archive opened with Archive Utility.
    private static func copyQuarantine(from archive: URL, toTreeAt root: URL) {
        let size = getxattr(archive.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(archive.path, "com.apple.quarantine", &value, size, 0, 0) == size else { return }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            setxattr(url.path, "com.apple.quarantine", value, value.count, 0, 0)
        }
    }
}
