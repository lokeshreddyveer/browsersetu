import Foundation

/// Brings what the app kept before the task database existed (`interrupted.json` with one `.resume` file per download, and `scheduled.json`) into the database.
///
/// Safe by construction:
///  - Everything is read and checked first; nothing is deleted. The old files are MOVED into `legacy-v0/` only after the new records have been written in one transaction
///    and read back, and they stay there as the recovery copy.
///  - It runs once (a marker in the database says so) and again does nothing; run twice by accident, it changes nothing.
///  - If anything fails, the old files are left exactly where they were and the next launch tries again.
///  - What is read is not trusted: names are reduced to plain file names, sizes are capped, counts are capped, and a record that does not make sense is skipped and counted.
enum DownloadLegacyMigration {
    static let markerKey = "legacy_v0_imported"
    static let backupFolderName = "legacy-v0"
    static let maxInterrupted = 50
    static let maxScheduled = 200

    struct Result: Equatable {
        var imported = 0
        var skipped = 0
        var alreadyDone = false
        /// Set when the migration could not complete; the old files were left in place.
        var failure: String?
    }

    private struct StoredInterrupted: Codable { var id: UUID; var filename: String; var source: String? }

    @discardableResult
    static func run(folder: URL, store: DownloadTaskStore, profile: String, safeName: (String) -> String) -> Result {
        var result = Result()
        if store.meta(markerKey) != nil { result.alreadyDone = true; return result }
        let fm = FileManager.default
        let indexURL = folder.appendingPathComponent("interrupted.json")
        let scheduledURL = folder.appendingPathComponent("scheduled.json")
        let hasLegacy = fm.fileExists(atPath: indexURL.path) || fm.fileExists(atPath: scheduledURL.path)
        guard hasLegacy else {
            store.setMeta(markerKey, ISO8601DateFormatter().string(from: Date()))
            store.flush()
            result.alreadyDone = false
            return result
        }

        var records: [(DownloadTaskRecord, Data?)] = []
        let now = Date()

        // Interrupted downloads, with their resume data.
        if let data = try? Data(contentsOf: indexURL) {
            guard let list = try? JSONDecoder().decode([StoredInterrupted].self, from: data) else {
                result.failure = "interrupted.json could not be read; it was left where it is"
                return result
            }
            for item in list.prefix(maxInterrupted) {
                let resumeURL = folder.appendingPathComponent(item.id.uuidString + ".resume")
                guard let resume = try? Data(contentsOf: resumeURL), !resume.isEmpty, resume.count <= DownloadTaskStore.maxResumeBytes else { result.skipped += 1; continue }
                let source = item.source.flatMap(URL.init(string:))
                var record = DownloadTaskRecord(id: item.id, protocolID: .webKit, profile: profile, source: DownloadSourceRef(url: source), filename: safeName(item.filename), now: now)
                record.state = .paused
                record.transfer.resumeAvailable = true
                records.append((record, resume))
            }
            if list.count > maxInterrupted { result.skipped += list.count - maxInterrupted }
        }

        // Downloads put off until later.
        if let data = try? Data(contentsOf: scheduledURL) {
            guard let list = try? JSONDecoder().decode([ScheduledDownload].self, from: data) else {
                result.failure = "scheduled.json could not be read; it was left where it is"
                return result
            }
            for item in list.prefix(maxScheduled) {
                guard DownloadSchedule.canSchedule(URL(string: item.url)) else { result.skipped += 1; continue }
                var record = DownloadTaskRecord(id: item.id, protocolID: .webKit, profile: profile, source: DownloadSourceRef(url: URL(string: item.url)), filename: safeName(item.filename), now: now)
                record.state = .scheduled
                record.priority = item.priority
                records.append((record, nil))
            }
            if list.count > maxScheduled { result.skipped += list.count - maxScheduled }
        }

        // One transaction: all of it or none of it. An id that is already in the database is left as the database has it.
        let existing = Set(store.loadAll(profile: profile).records.map(\.id))
        let fresh = records.filter { !existing.contains($0.0.id) }
        do {
            try store.transaction { s in
                for (record, resume) in fresh { try s.saveInTransaction(record, resumeData: resume) }
                try s.setMetaInTransaction(markerKey, ISO8601DateFormatter().string(from: now))
            }
        } catch {
            result.failure = "the tasks could not be written: \(error)"
            return result
        }
        // Read back before touching the old files.
        let stored = Set(store.loadAll(profile: profile).records.map(\.id))
        guard fresh.allSatisfy({ stored.contains($0.0.id) }) else {
            result.failure = "the tasks were not all there when read back; the old files were left in place"
            return result
        }
        result.imported = fresh.count

        // Only now are the old files put aside (moved, not removed).
        let backup = folder.appendingPathComponent(backupFolderName, isDirectory: true)
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name == "interrupted.json" || name == "scheduled.json" || name.hasSuffix(".resume") {
            let destination = backup.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            try? fm.moveItem(at: folder.appendingPathComponent(name), to: destination)
        }
        return result
    }
}
