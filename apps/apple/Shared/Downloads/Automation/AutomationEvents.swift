import Foundation

struct AutomationEvent: Codable, Equatable, Sendable {
    /// Position in the sequence; only meaningful together with `epoch`.
    var id: Int
    /// Names one unbroken run of the sequence. A different epoch means ids from before cannot be compared with these.
    var epoch: String = ""
    /// Set on `stream.gap`: why the missed events cannot be replayed, so the client takes a fresh snapshot instead.
    var note: String? = nil
    var type: String
    var taskID: String?
    var state: String?
    var fraction: Double?
    var bytesReceived: Int64?
    var sourceHost: String?
    var profile: String
    var at: Date
}

/// A sequence number that never repeats, even across restarts. A block of numbers is reserved on disk ahead of use, so after a crash the next run starts above anything that was
/// issued. If the reservation cannot be saved (or the saved one is unreadable) a new epoch is used for this run, so a client holding an older position is told it cannot resume.
final class AutomationEventSequence {
    private(set) var epoch: String
    private(set) var lastIssued: Int
    private var reservedUpTo: Int
    private let file: URL?
    private let block: Int
    private(set) var persistenceDegraded = false
    /// Called when the epoch changes while running (the reservation could not be saved), so everything tied to the old epoch can be dropped and clients told.
    var onEpochChange: (() -> Void)?
    private let writer: (Data, URL) throws -> Void

    private struct Saved: Codable { var epoch: String; var high: Int }

    init(file: URL?, block: Int = 256, writer: ((Data, URL) throws -> Void)? = nil) {
        self.file = file; self.block = max(1, block)
        self.writer = writer ?? { try $0.write(to: $1, options: .atomic) }
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.high >= 0 {
            epoch = saved.epoch; lastIssued = saved.high; reservedUpTo = saved.high
        } else {
            epoch = String(UUID().uuidString.prefix(8)).lowercased(); lastIssued = 0; reservedUpTo = 0
            if file != nil, FileManager.default.fileExists(atPath: file!.path) { persistenceDegraded = true }      // present but unreadable
        }
        reserveIfNeeded(force: true)
    }

    /// The next number.
    func next() -> Int {
        lastIssued += 1
        reserveIfNeeded(force: false)
        return lastIssued
    }

    private func reserveIfNeeded(force: Bool) {
        guard force || lastIssued >= reservedUpTo else { return }
        let high = lastIssued + block
        guard let file else { reservedUpTo = high; return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writer(try JSONEncoder().encode(Saved(epoch: epoch, high: high)), file)
            reservedUpTo = high
        } catch {
            // The reservation cannot be saved, so numbers from this run could be reused by the next. A new epoch makes them incomparable instead.
            if !persistenceDegraded { persistenceDegraded = true; epoch = String(UUID().uuidString.prefix(8)).lowercased(); lastIssued = 0; onEpochChange?() }
            reservedUpTo = lastIssued + block
        }
    }

    static func header(epoch: String, id: Int) -> String { "\(epoch)-\(id)" }

    /// Reads "epoch-number". nil for anything else.
    static func parse(_ text: String) -> (epoch: String, id: Int)? {
        let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].count == 8, let n = Int(parts[1]), n >= 0 else { return nil }
        return (parts[0], n)
    }
}

/// One client's view of the event stream: a bounded buffer. A slow client loses old progress (which is replaced by newer progress anyway) and, if it falls far behind on
/// events that matter, is told so and then disconnected. It can never make the app hold more than `capacity` events for it.
final class AutomationSubscription: @unchecked Sendable {
    static let capacity = 64
    let clientID: String
    let profile: String
    private let lock = NSLock()
    private var buffer: [AutomationEvent] = []
    private var waiter: CheckedContinuation<AutomationEvent?, Never>?
    private var closed = false
    private(set) var overflows = 0
    var onClose: (() -> Void)?

    init(clientID: String, profile: String) { self.clientID = clientID; self.profile = profile }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    var pending: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }

    func push(_ event: AutomationEvent) {
        lock.lock()
        if closed { lock.unlock(); return }
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: event); return }
        // Progress is coalesced: a newer reading of the same task replaces the one waiting.
        if event.type == "task.progress", let i = buffer.lastIndex(where: { $0.type == "task.progress" && $0.taskID == event.taskID }) {
            buffer[i] = event; lock.unlock(); return
        }
        if buffer.count >= Self.capacity {
            // Drop progress first; if only important events remain, drop the oldest and note it.
            if let i = buffer.firstIndex(where: { $0.type == "task.progress" }) { buffer.remove(at: i) }
            else { buffer.removeFirst(); overflows += 1 }
            if overflows > 3 { lock.unlock(); close(); return }
        }
        buffer.append(event)
        lock.unlock()
    }

    /// The next event, or nil once the subscription is closed.
    func next() async -> AutomationEvent? {
        await withCheckedContinuation { (c: CheckedContinuation<AutomationEvent?, Never>) in
            lock.lock()
            if !buffer.isEmpty { let e = buffer.removeFirst(); lock.unlock(); c.resume(returning: e); return }
            if closed { lock.unlock(); c.resume(returning: nil); return }
            if let old = waiter { waiter = nil; lock.unlock(); old.resume(returning: nil); lock.lock() }
            waiter = c
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        let was = closed; closed = true
        let w = waiter; waiter = nil
        let hook = onClose; onClose = nil
        lock.unlock()
        w?.resume(returning: nil)
        if !was { hook?() }
    }
}

/// Turns changes in the ledger into events. It only reads snapshots; it never changes a task.
@MainActor
final class AutomationEventHub {
    struct Snapshot: Equatable { var id: UUID; var state: DownloadState; var fraction: Double?; var bytes: Int64; var host: String?; var profile: String; var integrity: String? = nil; var retryCount: Int = 0 }

    static let maxSubscribers = 8
    static let maxPerClient = 4
    static let historyLimit = 200
    private var known: [UUID: Snapshot] = [:]
    private var lastProgress: [UUID: (fraction: Double, at: TimeInterval)] = [:]
    let sequence: AutomationEventSequence
    private var history: [AutomationEvent] = []
    private(set) var subscribers: [AutomationSubscription] = []
    private var seeded = false
    private var busyByProfile: [String: Int] = [:]
    /// Profiles whose existing tasks have been learned. A profile that appears later is learned silently too, so it does not announce everything it already had as new.
    private var learnedProfiles = Set<String>()
    private var completedThisRound: [String: Int] = [:]

    init(sequence: AutomationEventSequence = AutomationEventSequence(file: nil)) {
        self.sequence = sequence
        // A new epoch mid-run: old events can never be replayed as if they belonged to it, and everyone connected is told to take a fresh snapshot.
        sequence.onEpochChange = { [weak self] in
            guard let self else { return }
            self.history.removeAll()
            for sub in self.subscribers {
                sub.push(AutomationEvent(id: 0, epoch: sequence.epoch, note: "restarted", type: "stream.gap", taskID: nil, state: nil, fraction: nil, bytesReceived: nil, sourceHost: nil, profile: sub.profile, at: Date()))
            }
        }
    }

    /// `lastEventID` is the "epoch-number" the client last saw. Whatever cannot be replayed completely is said so, with a `stream.gap` event as the first thing the client gets: it must
    /// then fetch the current state, because events were missed.
    func subscribe(clientID: String, profile: String, lastEventID: String?) -> AutomationSubscription? {
        subscribers.removeAll { $0.isClosed }
        guard subscribers.count < Self.maxSubscribers, subscribers.filter({ $0.clientID == clientID }).count < Self.maxPerClient else { return nil }
        let sub = AutomationSubscription(clientID: clientID, profile: profile)
        sub.onClose = { [weak self, weak sub] in Task { @MainActor in if let sub { self?.subscribers.removeAll { $0 === sub } } } }
        subscribers.append(sub)
        if let lastEventID {
            func gap(_ why: String) {
                sub.push(AutomationEvent(id: sequence.lastIssued, epoch: sequence.epoch, note: why, type: "stream.gap", taskID: nil, state: nil, fraction: nil, bytesReceived: nil, sourceHost: nil, profile: profile, at: Date()))
            }
            if let seen = AutomationEventSequence.parse(lastEventID) {
                if seen.epoch != sequence.epoch { gap("restarted") }
                else if seen.id > sequence.lastIssued { gap("unknown_position") }
                else if let oldest = history.first?.id {
                    if seen.id + 1 < oldest { gap("expired") }
                    else {
                        let missed = history.filter { $0.id > seen.id && $0.profile == profile }
                        if missed.count > AutomationSubscription.capacity - 8 { gap("too_many_missed") } else { for e in missed { sub.push(e) } }
                    }
                } else if seen.id < sequence.lastIssued { gap("history_unavailable") }
            } else { gap("unrecognised_position") }
        }
        return sub
    }

    func close(clientID: String) { for s in subscribers where s.clientID == clientID { s.close() } }
    func closeAll() { for s in subscribers { s.close() }; subscribers = [] }

    /// An event that is not about one task's state (a package finished). Goes to the same history and the same subscribers as every other, with the next number in the sequence.
    @discardableResult
    func publish(type: String, subject: String, profile: String, fraction: Double?, sink: ((AutomationEvent) -> Void)? = nil) -> AutomationEvent {
        let e = AutomationEvent(id: sequence.next(), epoch: sequence.epoch, type: type, taskID: subject, state: nil, fraction: fraction, bytesReceived: nil, sourceHost: nil, profile: profile, at: Date())
        history.append(e); if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        sink?(e)
        for sub in subscribers where sub.profile == profile { sub.push(e) }
        return e
    }

    /// Compares the current tasks with what was last seen and publishes the differences. The first call only learns what exists.
    func ingest(_ snapshots: [Snapshot], profiles: Set<String> = [], now: TimeInterval, sink: ((AutomationEvent) -> Void)? = nil) {
        let current = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        defer { known = current; lastProgress = lastProgress.filter { current[$0.key] != nil } }
        guard seeded else {
            seeded = true
            learnedProfiles = profiles.union(snapshots.map(\.profile))
            let busy: Set<DownloadState> = [.created, .resolving, .queued, .starting, .running, .verifying, .retrying, .pausing, .resuming]
            for s in snapshots where busy.contains(s.state) { busyByProfile[s.profile, default: 0] += 1 }
            return
        }
        func emit(_ type: String, _ s: Snapshot) {
            let e = AutomationEvent(id: sequence.next(), epoch: sequence.epoch, type: type, taskID: s.id.uuidString, state: s.state.rawValue, fraction: s.fraction, bytesReceived: s.bytes, sourceHost: s.host, profile: s.profile, at: Date())
            history.append(e); if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
            sink?(e)
            for sub in subscribers where sub.profile == s.profile { sub.push(e) }
        }
        completedThisRound = [:]
        for s in snapshots {
            guard let old = known[s.id] else { if profiles.isEmpty || learnedProfiles.contains(s.profile) { emit("task.created", s) }; continue }
            if old.state != s.state {
                switch s.state {
                case .running, .starting:
                    // One "started" per start: starting → running is the same start, and a resume is a resume.
                    if old.state == .starting && s.state == .running { break }
                    switch old.state {
                    case .paused, .pausing, .resuming: emit("task.resumed", s)
                    case .scheduled: emit("task.scheduled_ready", s)
                    default: emit("task.started", s)
                    }
                case .paused: emit("task.paused", s)
                case .completed:
                    emit("task.completed", s)
                    if s.integrity == "mismatch" { emit("task.integrity_failed", s) }
                    completedThisRound[s.profile, default: 0] += 1
                case .failed: emit("task.failed", s)
                case .cancelled: emit("task.cancelled", s)
                case .recoveryRequired: emit("task.recovery_required", s)
                case .queued where old.state == .scheduled: emit("task.scheduled_ready", s)
                case .retrying: emit("task.retry_scheduled", s)
                default: emit("task.updated", s)
                }
            } else if s.retryCount > old.retryCount {
                emit("task.retry_scheduled", s)
            } else if s.state == .running, let f = s.fraction {
                // A reading is sent when it moved at least one percent and at least half a second has passed.
                let last = lastProgress[s.id]
                if last == nil || (f - last!.fraction >= 0.01 && now - last!.at >= 0.5) { lastProgress[s.id] = (f, now); emit("task.progress", s) }
            }
        }
        // The queue is done when a profile's last busy download ends by finishing, and nothing is merely paused or waiting for a time. A pause, a cancellation or a task that vanished
        // from the list is not "everything is done".
        let busyStates: Set<DownloadState> = [.created, .resolving, .queued, .starting, .running, .verifying, .retrying, .pausing, .resuming]
        let parked: Set<DownloadState> = [.paused, .scheduled, .recoveryRequired]
        var busyNow: [String: Int] = [:], parkedNow: [String: Int] = [:]
        for s in snapshots {
            if busyStates.contains(s.state) { busyNow[s.profile, default: 0] += 1 }
            if parked.contains(s.state) { parkedNow[s.profile, default: 0] += 1 }
        }
        for profile in Set(busyByProfile.keys).union(busyNow.keys) {
            let before = busyByProfile[profile] ?? 0, after = busyNow[profile] ?? 0
            if before > 0, after == 0, (completedThisRound[profile] ?? 0) > 0, (parkedNow[profile] ?? 0) == 0 {
                let e = AutomationEvent(id: sequence.next(), epoch: sequence.epoch, type: "queue.completed", taskID: nil, state: nil, fraction: nil, bytesReceived: nil, sourceHost: nil, profile: profile, at: Date())
                history.append(e); if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
                sink?(e)
                for sub in subscribers where sub.profile == profile { sub.push(e) }
            }
        }
        busyByProfile = busyNow
        learnedProfiles.formUnion(profiles); learnedProfiles.formUnion(snapshots.map(\.profile))
    }
}
