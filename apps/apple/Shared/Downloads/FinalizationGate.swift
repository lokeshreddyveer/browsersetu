import Foundation

/// Decides, exactly once and atomically, whether a transfer ends by being cancelled or by being put in place.
///
/// Two things can arrive at nearly the same moment: the person's cancel (from the main thread) and the engine's last step (on its own queue). Without one arbiter both can
/// "win": the file is moved into place and the task is also reported cancelled, leaving a finished file nobody asked for. The gate makes the order a fact:
///
///   open ──claim──▶ finalising      the engine passed the point of no return; a cancel after this finds it too late and the download completes
///   open ──cancel─▶ cancelled       the person won; the engine finds the gate shut and puts nothing in place
///
/// Everything before the claim (checking the parts, hashing, choosing a name) can still be cancelled. Nothing after it can.
final class FinalizationGate: @unchecked Sendable {
    enum Phase: Equatable, Sendable { case open, finalising, cancelled }

    private let lock = NSLock()
    private var current = Phase.open

    var phase: Phase { lock.lock(); defer { lock.unlock() }; return current }

    /// The engine is about to put the file in place. False when the person has already cancelled (nothing may be put in place).
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch current {
        case .open: current = .finalising; return true
        case .finalising: return true         // repeating the claim is harmless: the same finalisation
        case .cancelled: return false
        }
    }

    /// The person is cancelling. True when the cancel took effect (or already had); false when the file is already being put in place, so the download will complete.
    func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch current {
        case .open: current = .cancelled; return true
        case .cancelled: return true
        case .finalising: return false
        }
    }

    /// Whether pausing still makes sense: not once the file is being put in place.
    var allowsPause: Bool { phase == .open }
}

/// Where a test can pause a finishing transfer to make a cancel arrive at one exact moment, instead of hoping to hit the window by timing.
enum FinalizationStage: Sendable { case beforeClaim, afterClaim }

enum FinalizationTestHook {
    /// Called on the engine's own queue. Nil in the app; only tests set it.
    nonisolated(unsafe) static var hook: ((FinalizationStage) -> Void)?
}
