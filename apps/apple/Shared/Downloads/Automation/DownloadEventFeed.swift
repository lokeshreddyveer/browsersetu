import Foundation
import Combine

/// The single place that watches the download ledger and turns its changes into events. The automation stream, the notifications and the diagnostics timeline are all
/// consumers of it; none of them keeps a second watcher. It only reads: it never changes a task.
@MainActor
final class DownloadEventFeed {
    let hub: AutomationEventHub
    private let coordinators: () -> [DownloadCoordinator]
    private let monotonic: () -> TimeInterval
    private var observers: [UUID: (AutomationEvent, DownloadCoordinator?) -> Void] = [:]
    private var bag = Set<AnyCancellable>()
    private(set) var isRunning = false

    init(coordinators: @escaping () -> [DownloadCoordinator], hub: AutomationEventHub? = nil, monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.coordinators = coordinators; self.hub = hub ?? AutomationEventHub(); self.monotonic = monotonic
    }

    @discardableResult
    func observe(_ f: @escaping (AutomationEvent, DownloadCoordinator?) -> Void) -> UUID { let id = UUID(); observers[id] = f; return id }
    func unobserve(_ id: UUID) { observers[id] = nil }
    var observerCount: Int { observers.count }

    /// Weakly held, compared by identity: a coordinator that is gone cannot be mistaken for a new one that reuses its address.
    private var watched: [WeakCoordinator] = []
    private struct WeakCoordinator { weak var value: DownloadCoordinator? }

    func start() {
        isRunning = true
        subscribeToCurrentCoordinators()
        publishChanges()
    }

    /// Follows the coordinators that exist now: a new one is watched, one that was replaced or removed is let go. Called on start and on every pass, so a profile created or torn
    /// down later is picked up without anyone having to remember to tell the feed.
    @discardableResult
    func syncCoordinators() -> Bool {
        let now = coordinators()
        let same = now.count == watched.count && zip(now, watched).allSatisfy { $0 === $1.value }
        guard isRunning, !same else { return false }
        subscribeToCurrentCoordinators()
        return true
    }

    private func subscribeToCurrentCoordinators() {
        bag.removeAll()
        let all = coordinators()
        watched = all.map { WeakCoordinator(value: $0) }
        for c in all {
            Publishers.Merge(c.tasksChanged.eraseToAnyPublisher(), c.$active.map { _ in () }.eraseToAnyPublisher())
                .throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] in self?.publishChanges() }
                .store(in: &bag)
        }
    }

    /// A package finished or needs attention. Goes out through the same hub and to the same observers as the task events.
    func publishPackage(type: String, packageID: UUID, profile: String, fraction: Double?) {
        let owner = coordinators().first { $0.profileName == profile }
        hub.publish(type: type, subject: packageID.uuidString, profile: profile, fraction: fraction) { [weak self] event in
            guard let self else { return }
            for f in self.observers.values { f(event, owner) }
        }
    }

    func stop() { isRunning = false; bag.removeAll(); watched = [] }

    /// Reads every coordinator at once (one comparison, so tasks of one profile are never mistaken for gone by looking at another), and reports each difference once.
    func publishChanges() {
        syncCoordinators()
        let all = coordinators()
        var snaps: [AutomationEventHub.Snapshot] = []
        for c in all {
            snaps += c.ledger.records.values.filter { !$0.isPrivate }.map {
                AutomationEventHub.Snapshot(id: $0.id, state: $0.state, fraction: c.active[$0.id]?.fraction, bytes: c.active[$0.id]?.completedBytes ?? $0.transfer.completedBytes,
                                            host: $0.source.host, profile: $0.profile, integrity: $0.file.integrity.rawValue, retryCount: $0.retryCount)
            }
        }
        hub.ingest(snaps, profiles: Set(all.map(\.profileName)), now: monotonic()) { [weak self] event in
            guard let self else { return }
            let owner = all.first { $0.profileName == event.profile }
            for f in self.observers.values { f(event, owner) }
        }
    }
}
