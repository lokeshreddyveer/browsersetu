import Foundation

/// A clock that only moves forward and is not affected by the wall clock being set (or the user changing the date). Replaceable so rate behaviour can be tested exactly.
protocol MonotonicClock: Sendable {
    /// Seconds since some fixed, arbitrary point.
    func now() -> Double
}

struct SystemMonotonicClock: MonotonicClock {
    func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }
}

/// One token bucket. Tokens are bytes. A caller takes bytes that have ALREADY arrived (the transports cannot ask first), so the balance may go below zero: that debt is how long the
/// caller must stay quiet before the next bytes are accepted. This keeps the long-run rate at exactly `rate` however the chunks are sized, and bounds the burst after silence to `burst`.
struct TokenBucket: Sendable {
    private(set) var rate: Double            // bytes per second
    private(set) var burst: Double           // most that can be saved up while idle
    private(set) var tokens: Double
    private var last: Double

    /// Never saves up less than this, or a very low rate could not pass one ordinary read.
    static let minimumBurst = 8 * 1024
    /// How long a quiet period may be banked.
    static let burstSeconds = 0.25

    static func burst(for rate: Double) -> Double { max(Double(minimumBurst), rate * burstSeconds) }

    init(rate: Double, now: Double) {
        self.rate = rate; burst = Self.burst(for: rate); tokens = burst; last = now
    }

    /// Time never runs backwards here: a clock reading earlier than the last one adds nothing (and is then taken as the new reference), and a long gap adds at most `burst`.
    mutating func refill(now: Double) {
        let elapsed = now - last
        last = now
        guard elapsed > 0 else { return }
        tokens = min(burst, tokens + elapsed * rate)
    }

    mutating func setRate(_ newRate: Double, now: Double) {
        refill(now: now)
        rate = newRate
        burst = Self.burst(for: newRate)
        tokens = min(tokens, burst)             // a lower limit takes effect now; a higher one fills gradually
    }

    /// Takes `bytes` and returns how long until the balance is not negative.
    mutating func take(_ bytes: Int, now: Double) -> Double {
        refill(now: now)
        tokens -= Double(bytes)
        return tokens >= 0 ? 0 : -tokens / rate
    }

    /// How long until the balance is not negative, without taking anything.
    mutating func wait(now: Double) -> Double {
        refill(now: now)
        return tokens >= 0 ? 0 : -tokens / rate
    }
}

/// Where a limit comes from, for the effective limit shown to the person.
enum BandwidthLimitSource: String, Sendable { case none, overall, download, adaptive }

/// Which profile (coordinator) a task belongs to, so a limit set by one profile never governs another's downloads. The scheduler records it when it grants a task its place; tasks nobody
/// has claimed belong to `defaultOwner`, which is what older callers and the tests use. Bounded: the oldest entries are dropped past a few thousand.
final class TransferOwnership: @unchecked Sendable {
    static let shared = TransferOwnership()
    static let defaultOwner = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
    private let lock = NSLock()
    private var owners: [UUID: UUID] = [:]
    private var order: [UUID] = []
    /// Tasks that hold a lease right now: never evicted, so a long download cannot lose its profile to a flood of newer tasks.
    private var pinned: Set<UUID> = []
    static let capacity = 4096

    func assign(_ task: UUID, owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owners.updateValue(owner, forKey: task) == nil { order.append(task) }
        if order.count > Self.capacity, let i = order.firstIndex(where: { !pinned.contains($0) }) { let drop = order.remove(at: i); owners[drop] = nil }
    }
    func pin(_ task: UUID) { lock.lock(); pinned.insert(task); lock.unlock() }
    func unpin(_ task: UUID) { lock.lock(); pinned.remove(task); lock.unlock() }
    func owner(of task: UUID) -> UUID { lock.lock(); defer { lock.unlock() }; return owners[task] ?? Self.defaultOwner }
    func forget(task: UUID) { lock.lock(); pinned.remove(task); owners[task] = nil; if let i = order.firstIndex(of: task) { order.remove(at: i) }; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return owners.count }
}

/// The speed policy for everything the app downloads itself, in two levels: one overall limit per profile shared by that profile's downloads, and an optional limit per download. A download
/// is held to the stricter of the two, and a download with several connections is one download here: its connections draw from the same buckets, never one each.
///
/// The overall limit of a profile is the lower of two numbers: the one the person set (`manual`, a hard bound that nothing here can raise) and an optional adaptive ceiling set by
/// `AdaptiveController` from measurements. The adaptive ceiling can only make a profile slower than its manual limit, never faster.
///
/// Sharing out the overall limit: every download of the profile that has been receiving recently also draws from an equal share of it (the limit divided by the number of such downloads). A
/// download that is idle or finished stops counting after `activeWindow`, so what it was not using goes to the others, and one with many connections cannot take more than its share while
/// others are busy. This is approximate fair sharing, not a guarantee of exact equality over short periods.
///
/// A transport reports bytes it has received with `reserve(task:bytes:)` and waits the returned time before accepting more. Nothing here sleeps or polls; the transport schedules the wait.
final class BandwidthController: @unchecked Sendable {
    static let shared = BandwidthController()

    /// Limits are in whole bytes per second; nothing below this is accepted, because a limit that low is a stall, not a limit.
    static let minimumRate: Int64 = 1024
    /// A downloader that has received nothing for this long no longer counts as sharing the overall limit.
    static let activeWindow = 2.0

    private let clock: MonotonicClock
    private let lock = NSLock()
    private var manual: [UUID: Int64] = [:]
    private var adaptive: [UUID: Int64] = [:]
    private var overall: [UUID: TokenBucket] = [:]          // at the lower of manual and adaptive
    private var perTask: [UUID: TokenBucket] = [:]
    private var share: [UUID: TokenBucket] = [:]
    private var seen: [UUID: Double] = [:]
    private var changeHandlers: [UUID: @Sendable () -> Void] = [:]
    private var total: Int64 = 0
    private var ownerBytes: [UUID: Int64] = [:]

    init(clock: MonotonicClock = SystemMonotonicClock()) { self.clock = clock }

    private static var def: UUID { TransferOwnership.defaultOwner }

    // MARK: Limits

    /// Bytes per second for all of a profile's downloads together, as the person set it; nil removes the limit.
    var overallLimit: Int64? { overallLimit(owner: Self.def) }
    func overallLimit(owner: UUID) -> Int64? { lock.lock(); defer { lock.unlock() }; return manual[owner] }
    func adaptiveCeiling(owner: UUID) -> Int64? { lock.lock(); defer { lock.unlock() }; return adaptive[owner] }
    /// What the profile's downloads are actually held to together: the lower of the two.
    func effectiveOverall(owner: UUID) -> Int64? { lock.lock(); defer { lock.unlock() }; return overall[owner].map { Int64($0.rate) } }

    func setOverallLimit(_ bytesPerSecond: Int64?) { setOverallLimit(bytesPerSecond, owner: Self.def) }

    func setOverallLimit(_ bytesPerSecond: Int64?, owner: UUID) {
        lock.lock()
        manual[owner] = Self.valid(bytesPerSecond)
        rebuild(owner: owner)
        let handlers = Array(changeHandlers.values)
        lock.unlock()
        handlers.forEach { $0() }
    }

    /// A ceiling from the adaptive controller; nil removes it. It can lower the profile's speed but never lifts the manual limit.
    func setAdaptiveCeiling(_ bytesPerSecond: Int64?, owner: UUID) {
        lock.lock()
        let new = Self.valid(bytesPerSecond)
        if adaptive[owner] == new { lock.unlock(); return }          // unchanged: nothing is rebuilt and nobody is woken
        adaptive[owner] = new
        rebuild(owner: owner)
        let handlers = Array(changeHandlers.values)
        lock.unlock()
        handlers.forEach { $0() }
    }

    /// Called with the lock held.
    private func rebuild(owner: UUID) {
        let now = clock.now()
        let rates = [manual[owner], adaptive[owner]].compactMap { $0 }
        if let rate = rates.min() {
            if overall[owner] != nil { overall[owner]?.setRate(Double(rate), now: now) } else { overall[owner] = TokenBucket(rate: Double(rate), now: now) }
        } else { overall[owner] = nil }
        for key in share.keys where TransferOwnership.shared.owner(of: key) == owner { share[key] = nil }
    }

    func taskLimit(_ task: UUID) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return perTask[task].map { Int64($0.rate) }
    }

    func setTaskLimit(_ bytesPerSecond: Int64?, for task: UUID) {
        lock.lock()
        let now = clock.now()
        if let limit = Self.valid(bytesPerSecond) {
            if perTask[task] != nil { perTask[task]?.setRate(Double(limit), now: now) } else { perTask[task] = TokenBucket(rate: Double(limit), now: now) }
        } else { perTask[task] = nil }
        let handlers = Array(changeHandlers.values)
        lock.unlock()
        handlers.forEach { $0() }
    }

    /// Zero or negative means no limit; anything else is raised to the minimum.
    static func valid(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return max(minimumRate, value)
    }

    /// The limit a download is held to right now and which level it comes from.
    func effectiveLimit(for task: UUID) -> (bytesPerSecond: Int64, source: BandwidthLimitSource)? {
        lock.lock(); defer { lock.unlock() }
        let owner = TransferOwnership.shared.owner(of: task)
        let own = perTask[task].map { Int64($0.rate) }
        let all = overall[owner].map { Int64($0.rate) }
        let allSource: BandwidthLimitSource = (adaptive[owner] != nil && all == adaptive[owner] && (manual[owner] == nil || adaptive[owner]! < manual[owner]!)) ? .adaptive : .overall
        switch (own, all) {
        case (nil, nil): return nil
        case (let o?, nil): return (o, .download)
        case (nil, let a?): return (a, allSource)
        case (let o?, let a?): return o <= a ? (o, .download) : (a, allSource)
        }
    }

    var isLimiting: Bool { lock.lock(); defer { lock.unlock() }; return !overall.isEmpty || !perTask.isEmpty }

    // MARK: Accounting

    /// Records bytes a download has received and returns how long it must wait before accepting more (0 when it need not). With no limit that applies, this is a few comparisons.
    func reserve(task: UUID, bytes: Int) -> TimeInterval {
        guard bytes > 0 else { return 0 }
        let owner = TransferOwnership.shared.owner(of: task)
        lock.lock(); defer { lock.unlock() }
        total += Int64(bytes)
        ownerBytes[owner, default: 0] += Int64(bytes)
        guard overall[owner] != nil || perTask[task] != nil else { return 0 }
        let now = clock.now()
        var wait = 0.0
        if perTask[task] != nil { wait = max(wait, perTask[task]!.take(bytes, now: now)) }
        if overall[owner] != nil {
            seen[task] = now
            wait = max(wait, overall[owner]!.take(bytes, now: now))
            ensureShare(for: task, owner: owner, now: now)
            wait = max(wait, share[task]?.take(bytes, now: now) ?? 0)
        }
        return wait
    }

    /// How much longer a download that already reserved must wait, as of now and under the limits now in force (a limit changed while it waits is taken into account).
    func remainingWait(task: UUID) -> TimeInterval {
        let owner = TransferOwnership.shared.owner(of: task)
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()
        var wait = 0.0
        if perTask[task] != nil { wait = max(wait, perTask[task]!.wait(now: now)) }
        if overall[owner] != nil {
            wait = max(wait, overall[owner]!.wait(now: now))
            wait = max(wait, share[task]?.wait(now: now) ?? 0)
        }
        return wait
    }

    /// The download's bucket for its equal share of its profile's overall limit, sized to the number of that profile's downloads that have received lately.
    private func ensureShare(for task: UUID, owner: UUID, now: Double) {
        guard let all = overall[owner] else { return }
        seen = seen.filter { now - $0.value <= Self.activeWindow }
        let count = max(1, seen.keys.filter { TransferOwnership.shared.owner(of: $0) == owner }.count)
        let rate = max(Double(Self.minimumRate), all.rate / Double(count))
        if share[task] == nil { share[task] = TokenBucket(rate: rate, now: now) }
        else if abs(share[task]!.rate - rate) > 0.5 { share[task]!.setRate(rate, now: now) }
        for key in share.keys where seen[key] == nil && key != task { share[key] = nil }
    }

    /// A download stopped receiving (paused, failed, finished): it no longer counts toward sharing. Its own limit is kept, so a resume has the same policy.
    func forget(task: UUID) {
        lock.lock()
        share[task] = nil; seen[task] = nil
        lock.unlock()
    }

    /// A download is gone for good: its limit goes too. Safe to repeat.
    func discard(task: UUID) {
        lock.lock()
        perTask[task] = nil; share[task] = nil; seen[task] = nil
        lock.unlock()
    }

    /// Told whenever a limit changes, so a transport that is waiting can look again at once instead of at its next scheduled look. Returns a token for `unobserve`.
    func observe(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock(); changeHandlers[token] = handler; lock.unlock()
        return token
    }

    func unobserve(_ token: UUID) { lock.lock(); changeHandlers[token] = nil; lock.unlock() }

    /// Bytes reported since this controller was made (for tests and diagnostics).
    var bytesAccounted: Int64 { lock.lock(); defer { lock.unlock() }; return total }
    /// Bytes reported by one profile's downloads (the adaptive controller measures its rate from this).
    func bytesAccounted(owner: UUID) -> Int64 { lock.lock(); defer { lock.unlock() }; return ownerBytes[owner] ?? 0 }
}

/// What an engine can do about speed, stated so the Downloads list never promises more than a transport delivers.
enum BandwidthEnforcement: Equatable, Sendable {
    /// Bytes are accepted no faster than the limit: the transport stops reading from the connection while it waits.
    case enforced
    /// The transport hands the file to the system to fetch, with no way to slow it. A limit set for such a download has no effect; the reason is shown.
    case notEnforced(reason: String)

    var isEnforced: Bool { self == .enforced }
}
