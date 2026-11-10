import Foundation

// The one place that decides which download may start, and when.
//
// What it owns: the waiting line (priority, order, aging), the limit on tasks running at once, the leases on shared resources (connections today; peers or bandwidth for a later
// engine), the hold on the whole queue, and the timers that make a task eligible later (a retry's delay, a scheduled start). What it does not own: a task's state (the ledger does)
// or a transfer (an engine does). It keeps nothing of its own on disk: the line is rebuilt from the ledger's records, so there is nothing that can disagree with them.
//
// It runs on the main actor with the rest of the coordinator. Everything it does is a few comparisons over a bounded list; nothing blocks, so a dedicated actor would only add
// hops. Time comes from a clock that tests replace, so no test waits for real time.

// MARK: Clock

/// Wall time (for deadlines that must survive a relaunch), monotonic time (for how long something has waited in this run) and a way to be called later.
@MainActor
protocol SchedulerClock: AnyObject {
    var now: Date { get }
    var uptime: TimeInterval { get }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SchedulerTimer
}

@MainActor
protocol SchedulerTimer: AnyObject { func cancel() }

/// The real clock. The wait is a task sleeping on the continuous clock, which keeps counting while the Mac sleeps, so a timer that came due during sleep fires as soon as it wakes;
/// the scheduler also re-checks every deadline against wall time when told the Mac woke (`reconcile`), because "soon" is not "exactly".
@MainActor
final class SystemSchedulerClock: SchedulerClock {
    var now: Date { Date() }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private final class Sleeper: SchedulerTimer {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel(); task = nil }
    }

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SchedulerTimer {
        let sleeper = Sleeper()
        sleeper.task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
            guard !Task.isCancelled else { return }
            action()
        }
        return sleeper
    }
}

// MARK: Resources

/// Something shared that tasks take a share of while they run. A pool is asked before a task starts and told when it ends; it never needs to know what a task is.
/// Leases are per task, so ending a task gives back everything it held, once, however many ways its ending is reported.
protocol ResourcePool: AnyObject {
    var name: String { get }
    /// Whether `amount` could be leased now. `scope` narrows it (a host name, for connections).
    func canGrant(_ amount: Int, scope: String?) -> Bool
    /// The same question for a particular task, for pools whose answer depends on whose task it is (one profile has a cap that another does not).
    func canGrant(_ amount: Int, scope: String?, task: UUID) -> Bool
    func grant(_ amount: Int, scope: String?, task: UUID) -> Bool
    /// Everything this task holds. Safe to repeat.
    func release(task: UUID)
}

/// What a task needs before it may start, in terms of pools. Slots are separate: every task needs one.
struct ResourceNeed: Equatable, Sendable {
    struct Request: Equatable, Sendable { var pool: String; var amount: Int; var scope: String? }
    var requests: [Request] = []
    static let none = ResourceNeed()
}

// MARK: Scheduler

extension ResourcePool {
    func canGrant(_ amount: Int, scope: String?, task: UUID) -> Bool { canGrant(amount, scope: scope) }
}

@MainActor
final class DownloadScheduler {
    /// The profile whose scheduler this is; every place it grants is recorded as that profile's, so shared limits can tell profiles apart.
    var ownerID = UUID()
    enum Kind: String, Sendable { case start, resume, retry }

    struct Entry: Identifiable {
        let id: UUID
        var kind: Kind
        var filename: String
        var priority: DownloadPriority
        var sequence: Int
        /// Wall time it joined the line (saved with the task, so a relaunch does not reset how long it has waited) and the monotonic reading to measure waiting from in this run.
        var enqueuedAt: Date
        var enqueuedUptime: TimeInterval
        var need: ResourceNeed
        var source: URL?
        /// Called, on the main actor, at the moment the entry is allowed to start. It must put the task into a state that counts as occupying a place before it returns.
        var onAdmit: @MainActor () -> Void
    }

    // Fairness: a waiting task gains one step of rank per `agingInterval` waited, up to a day's worth. High is two steps above Low, so a Low task that is more than two intervals older
    // than a High one outranks it, and a stream of new High tasks can delay it only until it has waited a few minutes: it can never wait for ever. A task that has not waited is
    // never passed by one that has waited less. Ties go to whoever joined first.
    static let agingInterval: TimeInterval = 120
    static let maxBoost = 720
    /// The longest a retry is made to wait after the wall clock moves (a clock set far ahead or back must not strand it).
    static let maxRetryWait: TimeInterval = 3600

    let clock: SchedulerClock
    private(set) var entries: [Entry] = []
    private var sequence = 0

    /// How many tasks may run at once, and how many do (a retrying task waiting out its delay does not hold a place).
    var slotLimit: () -> Int = { DownloadQueueRules.defaultConcurrent }
    var occupied: () -> Int = { 0 }
    /// Places promised to tasks that have been admitted and have not yet begun.
    private(set) var reserved = 0

    private var pools: [String: ResourcePool] = [:]
    var onChange: (() -> Void)?
    /// The hold is saved by whoever owns storage; the scheduler only tells it.
    var onHoldChange: ((Date?) -> Void)?

    private(set) var heldUntil: Date?
    private var holdTimer: SchedulerTimer?

    private struct Pending {
        var due: Date
        var maxWait: TimeInterval?
        var timer: SchedulerTimer?
        var fire: @MainActor () -> Void
    }
    private var pending: [UUID: Pending] = [:]

    init(clock: SchedulerClock) { self.clock = clock }

    func register(_ pool: ResourcePool) { pools[pool.name] = pool }

    // MARK: The line

    /// Puts a task in line. An entry for a task already in line is replaced, never duplicated.
    func enqueue(id: UUID, kind: Kind, filename: String, priority: DownloadPriority, need: ResourceNeed = .none, source: URL? = nil, enqueuedAt: Date? = nil,
                 onAdmit: @escaping @MainActor () -> Void) {
        entries.removeAll { $0.id == id }
        sequence += 1
        let waited = enqueuedAt.map { max(0, min(24 * 3600, clock.now.timeIntervalSince($0))) } ?? 0
        entries.append(Entry(id: id, kind: kind, filename: filename, priority: priority, sequence: sequence, enqueuedAt: enqueuedAt ?? clock.now,
                             enqueuedUptime: clock.uptime - waited, need: need, source: source, onAdmit: onAdmit))
        onChange?()
        pump()
    }

    /// Takes a task out of line (cancelled, or put off). Gives back anything leased to it.
    @discardableResult
    func remove(_ id: UUID) -> Bool {
        let had = entries.contains { $0.id == id }
        entries.removeAll { $0.id == id }
        cancelTimer(id)
        release(task: id)
        if had { onChange?() }
        return had
    }

    func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }

    func setPriority(_ id: UUID, _ priority: DownloadPriority) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].priority = priority
        onChange?()
        pump()
    }

    /// The priority a waiting task is ranked at now: its own, plus what its waiting has earned.
    func rank(_ entry: Entry) -> Int {
        let waited = max(0, clock.uptime - entry.enqueuedUptime)
        return entry.priority.rawValue + min(Self.maxBoost, Int(waited / Self.agingInterval))
    }

    /// The line in the order tasks would be admitted: highest rank first, and among equals whoever joined first.
    var ordered: [Entry] {
        entries.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra > rb : a.sequence < b.sequence
        }
    }

    /// 1 for the next to start. Nil if the task is not in line.
    func position(of id: UUID) -> Int? { ordered.firstIndex { $0.id == id }.map { $0 + 1 } }

    // MARK: Places

    /// A promised place is now a running task (or the task ended before it began): it no longer counts as promised.
    func settleReservation() { reserved = max(0, reserved - 1); pump() }

    var freeSlots: Int { max(0, slotLimit() - occupied() - reserved) }

    /// Why the next task in line is not starting, if it is not: for the one line of text the person sees.
    enum Waiting: Equatable { case held, noFreePlace, resourcesBusy, nothing }
    var waitingReason: Waiting {
        if entries.isEmpty { return .nothing }
        if isHeld { return .held }
        if freeSlots == 0 { return .noFreePlace }
        return nextAdmissible() == nil ? .resourcesBusy : .nothing
    }

    /// Starts as many as places and resources allow. Called whenever anything that could free a place changes.
    /// The network policy (offline with "wait for connection", a metered link, Low Data Mode) is holding new starts. Separate from `hold`, which is the person's own: lifting one never lifts the other.
    var policyHold = false { didSet { if oldValue, !policyHold { pump() } } }

    func pump() {
        guard !isHeld, !policyHold else { return }
        while freeSlots > 0, let entry = nextAdmissible() {
            guard lease(entry) else { break }
            entries.removeAll { $0.id == entry.id }
            if entry.kind == .start { reserved += 1 }
            onChange?()
            entry.onAdmit()
        }
    }

    /// The first in line that its resources allow. A task blocked only by a busy resource (one host's connections, say) is passed by, so it cannot hold up every other; as the
    /// line is in rank order, it is first again the moment that resource frees.
    private func nextAdmissible() -> Entry? {
        ordered.first { entry in { TransferOwnership.shared.assign(entry.id, owner: ownerID); return entry.need.requests.allSatisfy { request in pools[request.pool]?.canGrant(request.amount, scope: request.scope, task: entry.id) ?? true } }() }
    }

    private func lease(_ entry: Entry) -> Bool {
        TransferOwnership.shared.assign(entry.id, owner: ownerID)          // which profile this place is for
        var granted: [ResourcePool] = []
        for request in entry.need.requests {
            guard let pool = pools[request.pool] else { continue }
            if pool.grant(request.amount, scope: request.scope, task: entry.id) { granted.append(pool) }
            else { granted.forEach { $0.release(task: entry.id) }; return false }
        }
        return true
    }

    /// Gives back every lease a task holds (the end of its life, however it ended). Safe to repeat.
    func release(task: UUID) { pools.values.forEach { $0.release(task: task) } }

    // MARK: Holding the whole line

    var isHeld: Bool { heldUntil.map { $0 > clock.now } ?? false }

    /// Nothing starts until `date` (`.distantFuture` until released by hand). nil lifts the hold.
    func hold(until date: Date?) {
        holdTimer?.cancel(); holdTimer = nil
        heldUntil = date
        onHoldChange?(date)
        guard let date else { pump(); return }
        if date != .distantFuture {
            holdTimer = clock.schedule(after: max(0, date.timeIntervalSince(clock.now))) { [weak self] in self?.holdExpired() }
        }
    }

    private func holdExpired() {
        guard let held = heldUntil, held <= clock.now else { return }
        holdTimer = nil
        heldUntil = nil
        onHoldChange?(nil)
        onHoldExpired?()
        pump()
    }
    /// Told when a timed hold ends by itself, so what was put off during it can be started.
    var onHoldExpired: (() -> Void)?

    // MARK: Later

    /// Calls `fire` at `due` (a wall-clock deadline that is also saved with the task), once. One per task: scheduling again replaces the earlier one, which is what keeps a retry
    /// and a scheduled start from both firing. `maxWait` bounds the wait if the wall clock has been moved.
    func schedule(_ id: UUID, due: Date, maxWait: TimeInterval? = nil, fire: @escaping @MainActor () -> Void) {
        cancelTimer(id)
        var item = Pending(due: due, maxWait: maxWait, timer: nil, fire: fire)
        item.timer = clock.schedule(after: max(0, due.timeIntervalSince(clock.now))) { [weak self] in self?.timerFired(id) }
        pending[id] = item
    }

    func cancelTimer(_ id: UUID) {
        pending.removeValue(forKey: id)?.timer?.cancel()
    }

    func isScheduled(_ id: UUID) -> Bool { pending[id] != nil }
    func due(_ id: UUID) -> Date? { pending[id]?.due }
    var scheduledCount: Int { pending.count }

    private func timerFired(_ id: UUID) {
        guard let item = pending[id] else { return }
        // A timer can fire a little early on a clock that was set back; if the deadline is still ahead, wait for it.
        if item.due > clock.now.addingTimeInterval(0.5) { schedule(id, due: item.due, maxWait: item.maxWait, fire: item.fire); return }
        pending.removeValue(forKey: id)
        item.fire()
    }

    /// After the Mac woke, or the clock was changed: every deadline is checked against wall time again. Due ones fire now; ones pushed far into the future by a clock set
    /// backwards are brought back to the longest wait they were ever allowed; an expired hold is lifted.
    func reconcile() {
        let now = clock.now
        if let held = heldUntil, held != .distantFuture {
            if held <= now { holdTimer?.cancel(); holdExpiredNow() }
            else { hold(until: held) }
        }
        for (id, item) in pending {
            var due = item.due
            if let cap = item.maxWait, due.timeIntervalSince(now) > cap { due = now.addingTimeInterval(cap) }
            if due <= now {
                pending.removeValue(forKey: id)?.timer?.cancel()
                item.fire()
            } else {
                schedule(id, due: due, maxWait: item.maxWait, fire: item.fire)         // re-armed against the current clock
            }
        }
        pump()
    }

    private func holdExpiredNow() {
        holdTimer = nil
        heldUntil = nil
        onHoldChange?(nil)
        onHoldExpired?()
    }
}

// MARK: Rules for the schedule

/// What to do with a start that was put off until a time, when the app finds that time already past (it was closed, or the Mac was asleep).
enum SchedulePolicy {
    enum Decision: Equatable { case waitUntil(Date), startNow, needsPerson }

    /// How late a start may be and still go ahead by itself. A person who scheduled a download for 2 a.m. and opens the Mac at 7 expects it to have gone; one who opens it
    /// a week later does not expect a surprise, so it is shown and waits for them.
    static let grace: TimeInterval = 6 * 3600

    /// Only for something the person scheduled themselves. A crashed, failed or cancelled download is never decided here.
    static func decide(dueAt: Date?, now: Date, grace: TimeInterval = SchedulePolicy.grace) -> Decision {
        guard let dueAt else { return .needsPerson }          // held with no time: waits for the person to release the queue
        if dueAt > now { return .waitUntil(dueAt) }
        return now.timeIntervalSince(dueAt) <= grace ? .startNow : .needsPerson
    }
}
