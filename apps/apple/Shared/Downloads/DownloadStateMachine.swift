import Foundation

/// What happens to a task. The coordinator turns what an engine reports, and what the person asks for, into these.
enum DownloadEvent: Equatable, Sendable {
    case resolveStarted
    case resolved
    case queued                              // (re)enters the queue: new, released from a schedule, retry delay over, tried again, or restarted
    case scheduled(at: Date?)
    case started                             // an engine has the task
    case running                             // bytes are moving
    case pauseRequested
    case paused(resumeAvailable: Bool)
    case resumeRequested
    case resumed
    case verifying
    case completed(DownloadIntegrity)
    case failed(DownloadFailureInfo)
    case retryPlanned
    case cancelled
    case recoveryRequired(reason: String)    // found live after the app was closed

    var name: String {
        switch self {
        case .resolveStarted: "resolveStarted"; case .resolved: "resolved"; case .queued: "queued"; case .scheduled: "scheduled"
        case .started: "started"; case .running: "running"; case .pauseRequested: "pauseRequested"; case .paused: "paused"
        case .resumeRequested: "resumeRequested"; case .resumed: "resumed"; case .verifying: "verifying"; case .completed: "completed"
        case .failed: "failed"; case .retryPlanned: "retryPlanned"; case .cancelled: "cancelled"; case .recoveryRequired: "recoveryRequired"
        }
    }
}

struct DownloadTransitionError: Error, Equatable, CustomStringConvertible {
    enum Kind: Equatable { case illegal, missingPrecondition(String), staleGeneration(expected: Int, got: Int) }
    let from: DownloadState
    let event: String
    let kind: Kind
    var description: String {
        switch kind {
        case .illegal: "\(event) is not allowed while a download is \(from.rawValue)"
        case .missingPrecondition(let why): "\(event) is not possible: \(why)"
        case .staleGeneration(let expected, let got): "\(event) came from attempt \(got), but the download is on attempt \(expected)"
        }
    }
}

/// The legal moves, in one place.
///
///     created ─resolveStarted→ resolving ─resolved→ queued ─started→ starting ─running→ running ─verifying→ verifying ─completed→ completed
///     created/scheduled/retrying/failed/recoveryRequired ─queued→ queued;  created/resolving/queued/scheduled ─scheduled→ scheduled
///     running/pausing/resuming ─verifying→ verifying;  recoveryRequired ─verifying→ verifying (found complete on disk after the app was closed)
///     running ─pauseRequested→ pausing ─paused→ paused ─resumeRequested→ resuming ─resumed→ running   (running/starting/resuming ─paused→ paused when an engine stops with a place kept)
///     starting/running/resuming/resolving ─retryPlanned→ retrying
///     any live state, queued ─failed→ failed;  anything not final or failed ─cancelled→ cancelled
///     a state that held resources ─recoveryRequired→ recoveryRequired (only when found after the app was closed)
///
/// `completed` and `cancelled` never change again. `failed` changes only by `queued` (the person tries again) or stays.
enum DownloadStateMachine {
    static func next(from state: DownloadState, on event: DownloadEvent) -> DownloadState? {
        switch (state, event) {
        case (.created, .resolveStarted): return .resolving
        case (.resolving, .resolved): return .queued

        case (.created, .queued), (.scheduled, .queued), (.retrying, .queued), (.failed, .queued), (.recoveryRequired, .queued): return .queued
        case (.created, .scheduled), (.resolving, .scheduled), (.queued, .scheduled), (.scheduled, .scheduled): return .scheduled

        case (.queued, .started): return .starting
        case (.starting, .running): return .running
        case (.running, .pauseRequested): return .pausing
        case (.pausing, .paused), (.running, .paused), (.starting, .paused), (.resuming, .paused): return .paused
        case (.paused, .resumeRequested), (.recoveryRequired, .resumeRequested): return .resuming
        case (.resuming, .resumed): return .running
        // A pause or resume that was still being answered when the last byte arrived: the data is complete, so it goes on to be checked.
        case (.running, .verifying), (.pausing, .verifying), (.resuming, .verifying), (.recoveryRequired, .verifying): return .verifying
        case (.verifying, .completed): return .completed

        case (.starting, .retryPlanned), (.running, .retryPlanned), (.resuming, .retryPlanned), (.resolving, .retryPlanned): return .retrying
        case (.resolving, .failed), (.queued, .failed), (.starting, .failed), (.running, .failed), (.pausing, .failed), (.resuming, .failed),
             (.verifying, .failed), (.retrying, .failed), (.recoveryRequired, .failed), (.scheduled, .failed), (.paused, .failed): return .failed

        case (let s, .cancelled) where !s.isFinal && s != .failed: return .cancelled
        case (let s, .recoveryRequired) where s.holdsResources: return .recoveryRequired
        // A retry that was planned when the app ended: found after the app was closed, so it is shown and waits for the person, rather than staying invisible.
        case (.retrying, .recoveryRequired): return .recoveryRequired
        default: return nil
        }
    }

    static func canApply(_ event: DownloadEvent, to state: DownloadState) -> Bool { next(from: state, on: event) != nil }
}

extension DownloadTaskRecord {
    /// The record after `event`, or why it cannot be. Pure: it changes nothing until the caller stores the result.
    /// `attempt`, when given, is the start number the reporting engine was given; a report from an earlier start is refused.
    func applying(_ event: DownloadEvent, attempt reported: Int? = nil, now: Date = Date()) throws -> DownloadTaskRecord {
        if let reported, reported != attempt, state.holdsResources || state == .paused {
            throw DownloadTransitionError(from: state, event: event.name, kind: .staleGeneration(expected: attempt, got: reported))
        }
        guard let target = DownloadStateMachine.next(from: state, on: event) else {
            throw DownloadTransitionError(from: state, event: event.name, kind: .illegal)
        }
        var next = self
        next.state = target
        next.updatedAt = now
        switch event {
        case .started:
            next.attempt += 1
            next.startedAt = startedAt ?? now
            next.failure = nil
            next.enqueuedAt = nil; next.retryAt = nil
        case .resumeRequested:
            guard transfer.resumeAvailable else { throw DownloadTransitionError(from: state, event: event.name, kind: .missingPrecondition("there is nothing to resume from")) }
            next.attempt += 1
            next.failure = nil
        case .paused(let resumeAvailable):
            next.transfer.resumeAvailable = resumeAvailable
        case .resumed:
            next.transfer.resumeAvailable = false
        case .queued:
            next.scheduledAt = nil
            next.enqueuedAt = now
            next.retryAt = nil
            if state == .failed || state == .recoveryRequired { next.failure = nil; next.transfer.completedBytes = transfer.resumeAvailable ? transfer.completedBytes : 0 }
        case .scheduled(let at):
            next.scheduledAt = at
        case .completed(let integrity):
            next.retryAt = nil; next.enqueuedAt = nil
            next.completedAt = now
            next.file.integrity = integrity
            next.transfer.resumeAvailable = false
            if let total = transfer.totalBytes, total > 0 { next.transfer.completedBytes = total }
        case .failed(let info):
            next.retryAt = nil; next.enqueuedAt = nil
            next.failure = info
        case .retryPlanned:
            next.retryCount += 1
        case .cancelled:
            next.retryAt = nil; next.enqueuedAt = nil
            next.transfer.resumeAvailable = false
        case .recoveryRequired(let reason):
            next.failure = DownloadFailureInfo(code: "app:interrupted", reason: reason, retryable: true)
        case .resolveStarted, .resolved, .pauseRequested, .verifying:
            break
        case .running:
            break
        }
        return next
    }
}
