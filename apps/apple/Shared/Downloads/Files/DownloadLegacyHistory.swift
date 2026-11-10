import Foundation
import CryptoKit

/// Downloads from before the task database, kept by the Rust core as plain (address, name, time) rows. They are shown through a read-only adapter rather than migrated:
/// the old rows have no size, state or task identity, so turning them into task records would mean inventing those, and the original history stays exactly as it was.
///
/// - Nothing is written or deleted here.
/// - A legacy row gets a stable identifier made from what it holds (never a task id from the ledger), so the same row is the same row every time and a selection survives a refresh.
/// - A row that the task database also describes (same file name, same address without its query, finished within a minute) is dropped, so nothing is listed twice.
/// - The core's list call takes only a limit, so asking for a later page asks for more rows and keeps the newest `pageSize * pages`; only that slice is ever turned into rows.
enum DownloadLegacyHistory {
    static let pageSize = 200
    static let maxPages = 50                 // 10,000 rows: the most that is ever read

    struct Entry: Equatable, Sendable {
        var url: String
        var filename: String
        var created: Date
    }

    struct Page: Equatable {
        var entries: [Entry]
        /// True when the core had at least one more row than was returned.
        var hasMore: Bool
    }

    /// A stable id for a legacy row, in a namespace of its own: derived from the row, shaped like a UUID so the list can hold it with the others.
    static func identifier(for entry: Entry) -> UUID {
        let digest = SHA256.hash(data: Data("legacy|\(entry.url)|\(entry.filename)|\(Int(entry.created.timeIntervalSince1970))".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50      // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Reads one page through `fetch` (the core's `listDownloads(limit:)`), newest first.
    static func page(_ pages: Int, fetch: (UInt32) throws -> [(url: String, filename: String, created: Int64)]) -> Page {
        let wanted = min(max(1, pages), maxPages) * pageSize
        guard let rows = try? fetch(UInt32(wanted + 1)) else { return Page(entries: [], hasMore: false) }
        let entries = rows.prefix(wanted).map { Entry(url: $0.url, filename: $0.filename, created: Date(timeIntervalSince1970: TimeInterval($0.created))) }
        return Page(entries: Array(entries), hasMore: rows.count > wanted && pages < maxPages)
    }

    /// The address without its query, user name, or fragment: what two descriptions of the same download can be compared on.
    static func comparableAddress(_ text: String) -> String {
        guard var parts = URLComponents(string: text) else { return text }
        parts.query = nil; parts.user = nil; parts.password = nil; parts.fragment = nil
        return parts.string ?? text
    }

    /// The entries the task records do not already describe.
    static func unseen(_ entries: [Entry], records: [DownloadTaskRecord]) -> [Entry] {
        var seen: [String: [Date]] = [:]
        for r in records where r.state == .completed {
            let key = r.file.filename + "|" + comparableAddress(r.source.url ?? "")
            seen[key, default: []].append(r.completedAt ?? r.updatedAt)
        }
        return entries.filter { entry in
            let key = entry.filename + "|" + comparableAddress(entry.url)
            guard let times = seen[key] else { return true }
            return !times.contains { abs($0.timeIntervalSince(entry.created)) <= 60 }
        }
    }

    /// A row for the list. It carries no task state of its own beyond "completed": that is all the old history ever recorded.
    static func row(for entry: Entry, fileExists: (String) -> Bool) -> DownloadRow {
        let url = URL(string: entry.url)
        let source = DownloadSourceRef(url: url)
        let found = fileExists(entry.filename)
        var actions: DownloadRowActions = []
        if found { actions.formUnion([.open, .reveal]) }
        return DownloadRow(
            id: identifier(for: entry), filename: entry.filename, host: source.host ?? "", protocolLabel: "—", status: .completed, statusText: "Completed",
            detail: found ? entry.created.formatted(date: .abbreviated, time: .shortened) : entry.created.formatted(date: .abbreviated, time: .shortened) + " · file not found",
            totalBytes: nil, completedBytes: 0, fraction: 1, bytesPerSecond: nil, secondsLeft: nil, priority: .normal, date: entry.created, queuePosition: nil, dueAt: nil,
            actions: actions, resumeTitle: "Resume", retryAttempt: 0, connections: nil, pieces: nil, piecesDone: nil, problem: nil, technicalCode: nil, destinationName: entry.filename,
            isPrivate: false, sourceDisplay: DownloadRowProjector.displayAddress(source), destinationPath: nil, stateName: "history", attempt: 0, recoveryNote: nil, protocolID: "legacy",
            isLegacy: true, fileCategory: DownloadCategory.of(filename: entry.filename).rawValue)
    }
}
