import Foundation

/// What can honestly be said about a download that was found part-way: whether it carries on from what it has, starts again, needs the person, or is gone.
///
/// The four are different promises and are never treated as equivalent. Apple's own resume data, for one, only works while the file on the server is unchanged, the server still
/// supports byte ranges, and the system's temporary data is still there; so "Resume" is offered with that wording, not as a guarantee.
enum DownloadRecoveryClass: Equatable, Sendable {
    /// The bytes already fetched are kept and the download carries on from them (if the website still allows it).
    case resumable
    /// Nothing usable is kept, so it starts again from the beginning. Nothing the person had is lost.
    case restartRequired(String)
    /// The address can no longer be used as it is (a signed link that has probably expired); a fresh one is needed from the person.
    case needsNewLink(String)
    /// Neither the bytes nor the address are left.
    case cannotRecover(String)

    var summary: String {
        switch self {
        case .resumable: "Stopped part-way. It will carry on from where it got to, if the website still allows it."
        case .restartRequired(let why): "Stopped part-way. \(why) It will start again from the beginning."
        case .needsNewLink(let why): why
        case .cannotRecover(let why): why
        }
    }

    /// What the one action does, in the button's words.
    var actionTitle: String? {
        switch self {
        case .resumable: "Resume"
        case .restartRequired: "Start Over"
        case .needsNewLink, .cannotRecover: nil
        }
    }

    var canAct: Bool { actionTitle != nil }
}

/// What the disk and the database say about one task, gathered once so the decision itself is a pure function that can be tested with any combination.
struct DownloadRecoveryFacts: Equatable, Sendable {
    var destinationSize: Int64?
    var destinationModified: Date?
    var workingSize: Int64?
    var donePieces = 0
    var hasResumeData = false
    var hasSource = false
    var sourceLooksSigned = false
    /// The address was stored without its secret (a signed link kept across a relaunch).
    var sourceSecretLost = false
}

enum DownloadRecoveryVerdict: Equatable, Sendable {
    /// The finished file is already in place (the app ended between putting it there and saying so): the task is completed, nothing is fetched again.
    case completeOnDisk
    case recover(DownloadRecoveryClass)
}

enum DownloadRecovery {
    static let sampleTolerance: TimeInterval = 2

    /// Pure. Never says "complete" for a file that could have been there before the task started.
    static func assess(_ record: DownloadTaskRecord, facts: DownloadRecoveryFacts) -> DownloadRecoveryVerdict {
        let multipart = record.engineMetadata["mode"] == "multipart"
        if let total = record.transfer.totalBytes, total > 0, let size = facts.destinationSize, size == total, facts.workingSize == nil,
           let modified = facts.destinationModified, modified >= (record.startedAt ?? record.createdAt).addingTimeInterval(-sampleTolerance) {
            return .completeOnDisk
        }
        func fromTheStart() -> DownloadRecoveryVerdict {
            if facts.sourceSecretLost { return .recover(.needsNewLink("This link carried a one-time token, which is not kept on disk. Copy a fresh link from the website.")) }
            guard facts.hasSource else { return .recover(.cannotRecover("The address was not kept, so this download cannot be started again.")) }
            if facts.sourceLooksSigned { return .recover(.needsNewLink("This link carries a one-time token and has probably expired. Copy a fresh link from the website.")) }
            return .recover(.restartRequired("What was fetched could not be kept."))
        }
        if multipart {
            // The parts are the checkpoint: they count only while the file they were written into is still there at its full size.
            if !facts.sourceSecretLost, facts.donePieces > 0, let working = facts.workingSize, let total = record.transfer.totalBytes, working == total { return .recover(.resumable) }
            return fromTheStart()
        }
        if facts.hasResumeData { return .recover(.resumable) }
        return fromTheStart()
    }

    /// Reads the facts for a record. Only paths inside the downloads folder are looked at.
    static func facts(for record: DownloadTaskRecord, store: DownloadTaskStore?, roots: [URL]) -> DownloadRecoveryFacts {
        var facts = DownloadRecoveryFacts()
        let fm = FileManager.default
        if let path = record.file.destinationPath, DownloadPathPolicy.isAuthorized(path, roots: roots) {
            let attrs = try? fm.attributesOfItem(atPath: path)
            facts.destinationSize = (attrs?[.size] as? NSNumber)?.int64Value
            facts.destinationModified = attrs?[.modificationDate] as? Date
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            let working = MultipartRun.workingURL(for: record.id, in: folder)
            facts.workingSize = (try? fm.attributesOfItem(atPath: working.path))?[.size].flatMap { ($0 as? NSNumber)?.int64Value }
        }
        facts.donePieces = store?.loadPieces(task: record.id).filter { $0.state == .done }.count ?? 0
        facts.hasResumeData = store?.resumeData(for: record.id) != nil
        facts.hasSource = DownloadSchedule.canSchedule(record.source.asURL)
        facts.sourceLooksSigned = DownloadURLRedactor.looksSigned(record.source.asURL)
        facts.sourceSecretLost = DownloadURLRedactor.lostSecret(record.source.asURL)
        return facts
    }

    /// Leftovers of a task that is over (finished, or cancelled): its parts and its working files. Only this task's own, by name, never anything else in the folder.
    @MainActor
    static func sweepLeftovers(_ ledger: DownloadLedger) -> Int {
        var swept = 0
        let fm = FileManager.default
        for record in ledger.records.values where record.protocolID == .http && (record.state == .completed || record.state == .cancelled) {
            var found = (ledger.store?.loadPieces(task: record.id).isEmpty == false)
            if found { ledger.store?.deletePieces(task: record.id) }
            if let path = record.file.destinationPath, DownloadPathPolicy.isAuthorized(path, roots: ledger.authorizedRoots()) {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
                for url in [MultipartRun.workingURL(for: record.id, in: folder), HTTPTransferEngine.partialURL(for: record.id, in: folder), HTTPTransferEngine.stagedURL(for: record.id, in: folder)] where fm.fileExists(atPath: url.path) {
                    // The task's own temporary name; a completed task's real file has a different one.
                    try? fm.removeItem(at: url); found = true
                }
            }
            if found { swept += 1 }
        }
        return swept
    }
}
