import Foundation

/// What the person can do to a downloaded file, each kept separate from the others: rename it, move it, trash it, or forget the list entry (which never touches the file).
/// All of them work only on a regular file that is inside a folder the app is allowed to use, never follow a link, and never overwrite: a name that is taken is an error, not a replacement.
enum DownloadFileOperations {
    enum Failure: LocalizedError, Equatable {
        case outsideAllowedFolders, notAFile, invalidName, exists(String), notAFolder, failed(String)

        var errorDescription: String? {
            switch self {
            case .outsideAllowedFolders: "That file is not in a folder Browser Setu manages, so it was left alone."
            case .notAFile: "The file is missing or is not an ordinary file."
            case .invalidName: "That is not a usable file name."
            case .exists(let name): "A file named “\(name)” is already there."
            case .notAFolder: "Choose a folder."
            case .failed(let why): why
            }
        }
    }

    /// The file as a URL if it is a plain file (not a link) inside one of `roots`; nil otherwise.
    static func managedFile(_ path: String?, roots: [URL]) -> URL? {
        guard DownloadPathPolicy.isAuthorized(path, roots: roots), let path else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }

    /// Gives the file a new name in the same folder. The name is cleaned like any downloaded name (one plain name, no path), and the ending is kept unless the person typed another.
    static func rename(_ file: URL, to newName: String, roots: [URL]) throws -> URL {
        guard managedFile(file.path, roots: roots) != nil else { throw file.isFileURL && FileManager.default.fileExists(atPath: file.path) ? Failure.outsideAllowedFolders : Failure.notAFile }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"), var clean = DownloadFilename.sanitize(trimmed) else { throw Failure.invalidName }
        if (clean as NSString).pathExtension.isEmpty, !file.pathExtension.isEmpty { clean += "." + file.pathExtension }
        let target = file.deletingLastPathComponent().appendingPathComponent(clean)
        if target.path == file.path { return file }
        // Case-only changes ("a.pdf" to "A.pdf") are the same file on a case-insensitive disk, so the exclusive rename would refuse them; a plain rename is safe there because it cannot
        // replace anything else. Anything else that exists is refused.
        if target.path.lowercased() == file.path.lowercased() {
            guard Darwin.rename(file.path, target.path) == 0 else { throw Failure.failed("The file could not be renamed (\(String(cString: strerror(errno)))).") }
            return target
        }
        if FileManager.default.fileExists(atPath: target.path) { throw Failure.exists(clean) }
        return try moveWithoutReplacing(file, to: target)
    }

    /// Puts the file in another folder, under its own name or the next free "name (2)". The folder is one the person chose (it is checked to be a real folder, not a link to somewhere else).
    static func move(_ file: URL, toFolder folder: URL, roots: [URL]) throws -> URL {
        guard managedFile(file.path, roots: roots) != nil else { throw Failure.outsideAllowedFolders }
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true,
              FileManager.default.isWritableFile(atPath: folder.path) else { throw Failure.notAFolder }
        if folder.standardizedFileURL.path == file.deletingLastPathComponent().standardizedFileURL.path { return file }
        let name = file.lastPathComponent
        var candidate = folder.appendingPathComponent(name)
        var n = 1
        while true {
            do { return try moveWithoutReplacing(file, to: candidate) }
            catch Failure.exists {
                n += 1
                guard n < 1000 else { throw Failure.exists(name) }
                let ns = name as NSString
                candidate = folder.appendingPathComponent(ns.pathExtension.isEmpty ? "\(ns.deletingPathExtension) (\(n))" : "\(ns.deletingPathExtension) (\(n)).\(ns.pathExtension)")
            }
        }
    }

    /// Never replaces: RENAME_EXCL fails if the name is taken. Across volumes (where rename is impossible) the file is copied to a name of its own beside the destination and then renamed
    /// into place, and the original is removed only after that worked, so a failure at any step leaves the original untouched.
    static func moveWithoutReplacing(_ source: URL, to target: URL) throws -> URL {
        if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
        let code = errno
        if code == EEXIST { throw Failure.exists(target.lastPathComponent) }
        guard code == EXDEV else { throw Failure.failed("The file could not be moved (\(String(cString: strerror(code)))).") }
        let fm = FileManager.default
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString.prefix(8)).bsetu-part")
        do {
            try fm.copyItem(at: source, to: temp)
            if renamex_np(temp.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                let again = errno
                try? fm.removeItem(at: temp)
                throw again == EEXIST ? Failure.exists(target.lastPathComponent) : Failure.failed("The file could not be moved (\(String(cString: strerror(again)))).")
            }
            try fm.removeItem(at: source)
            return target
        } catch let failure as Failure { throw failure }
        catch { try? fm.removeItem(at: temp); throw Failure.failed("The file could not be copied to the other disk (\(error.localizedDescription)).") }
    }

    /// Moves the file to the Trash. Only a managed file; the caller has already asked.
    static func trash(_ file: URL, roots: [URL]) throws {
        guard managedFile(file.path, roots: roots) != nil else { throw Failure.outsideAllowedFolders }
        do { try FileManager.default.trashItem(at: file, resultingItemURL: nil) } catch { throw Failure.failed("The file could not be moved to the Trash.") }
    }
}
