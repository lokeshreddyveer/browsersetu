import Foundation

// What happens to a download's file after it is finished, asked of the coordinator so the ledger's record of where the file is always matches where it really is.
// Each operation changes the file first and the record second, and only the record's own fields (name, path, integrity): never the task's state.

extension DownloadCoordinator {
    /// The folders a finished download's file may be in: the downloads folder and any folder the person chose for a rule that is still open.
    var managedRoots: [URL] { [Self.directory] + DownloadDestinationAccess.grantedRoots }

    /// The file of a completed task, if it is still there as a plain file in a managed folder.
    func managedFile(of id: UUID) -> URL? {
        guard let record = ledger.record(id), record.state == .completed else { return nil }
        if let found = DownloadFileOperations.managedFile(record.file.destinationPath, roots: managedRoots) { return found }
        // Older records may carry only a name: the folder it was sorted into is looked for as before.
        return Self.locate(filename: record.file.filename).flatMap { DownloadFileOperations.managedFile($0.path, roots: managedRoots) }
    }

    @discardableResult
    func renameFile(of id: UUID, to newName: String) -> Result<URL, DownloadFileOperations.Failure> {
        guard let file = managedFile(of: id) else { return .failure(.notAFile) }
        do {
            let target = try DownloadFileOperations.rename(file, to: newName, roots: managedRoots)
            recordMoved(id, to: target)
            note("Renamed \(file.lastPathComponent) to \(target.lastPathComponent)")
            return .success(target)
        } catch let failure as DownloadFileOperations.Failure { return .failure(failure) } catch { return .failure(.failed(error.localizedDescription)) }
    }

    @discardableResult
    func moveFile(of id: UUID, toFolder folder: URL) -> Result<URL, DownloadFileOperations.Failure> {
        guard let file = managedFile(of: id) else { return .failure(.notAFile) }
        do {
            let target = try DownloadFileOperations.move(file, toFolder: folder, roots: managedRoots)
            recordMoved(id, to: target)
            note("Moved \(file.lastPathComponent) to \(folder.lastPathComponent)")
            return .success(target)
        } catch let failure as DownloadFileOperations.Failure { return .failure(failure) } catch { return .failure(.failed(error.localizedDescription)) }
    }

    /// The record follows the file. A file moved outside every managed folder is still recorded where it is, since the person asked for that; the next operation on it will be refused.
    private func recordMoved(_ id: UUID, to url: URL) {
        ledger.update(id) { $0.file.filename = url.lastPathComponent; $0.file.destinationPath = url.path }
    }

    /// Calculates the SHA-256 again off the main thread and stores what it found. A checksum that was given is compared with it; without one the digest is only recorded, and the file is not
    /// called verified.
    @discardableResult
    func reverify(_ id: UUID) async -> DownloadIntegrityCheck.Report? {
        guard let record = ledger.record(id), record.state == .completed, let file = managedFile(of: id) else { return nil }
        let expected = record.engineMetadata["sha256"]
        let trusted = record.engineMetadata["sha256From"] == "user"
        let size = record.transfer.totalBytes
        guard let report = try? await DownloadIntegrityCheck.verifyAsync(file: file, expectedSHA256: expected, expectedSize: size, digestIsTrusted: trusted) else {
            note("Could not check \(record.file.filename)")
            return nil
        }
        // The task may have been removed while the file was being read.
        guard ledger.record(id) != nil else { return report }
        ledger.update(id) {
            $0.engineMetadata["sha256Computed"] = report.sha256
            switch report.outcome {
            case .matchesGivenChecksum: $0.file.integrity = .verified
            case .doesNotMatchChecksum, .sizeDiffers: $0.file.integrity = .mismatch
            case .computedOnly: break           // nothing was given to compare with: what was known stays as it was
            }
        }
        note("Checked \(record.file.filename): \(DownloadIntegrityCheck.summary(report.outcome, sha256: report.sha256))")
        return report
    }

    func canExtract(_ id: UUID) -> Bool { managedFile(of: id).map(ArchiveExtractor.canExtract) ?? false }

    /// Opens a downloaded zip into a new folder beside it, on a background thread. Only on request.
    func extractArchive(_ id: UUID) async -> Result<URL, ArchiveExtractor.Failure> {
        guard let file = managedFile(of: id) else { return .failure(.notAFile) }
        do {
            let folder = try await Task.detached(priority: .userInitiated) { try ArchiveExtractor.extract(file: file) }.value
            note("Opened \(file.lastPathComponent) into \(folder.lastPathComponent)")
            return .success(folder)
        } catch let failure as ArchiveExtractor.Failure { note("Could not open \(file.lastPathComponent): \(failure.localizedDescription)"); return .failure(failure) }
        catch { return .failure(.invalid("The archive could not be opened.")) }
    }
}
