import Foundation

// Adaptive transfer management.
//
// What this can know, from a sandboxed app with no special permission: the bytes the app's own downloads move, how many connections they hold, how many transfers failed or were
// throttled, whether the browser is loading a page, the network path (offline, metered, Low Data Mode) and the Mac's power state. What it cannot know: how much of the network other
// applications use, or the network's real capacity. So nothing here claims to measure either. A browser that is busy is a reason to ask less of the network; a run of failures is a reason
// to open fewer connections; neither is a measurement of someone else's traffic.
//
// Everything is advisory and conservative. The controller can only LOWER what the person's own settings allow (a ceiling on speed, a ceiling on connections per download); the manual
// limit stays the hard upper bound, the connection budget stays shared and enforced, and a task held by the network policy stays held.

enum AdaptiveMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case unlimited, balanced, browserPriority, downloadPriority, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unlimited: "Unlimited"
        case .balanced: "Balanced"
        case .browserPriority: "Browser Priority"
        case .downloadPriority: "Download Priority"
        case .custom: "Custom"
        }
    }
    var detail: String {
        switch self {
        case .unlimited: "No limit of its own. Your connection settings and network rules still apply."
        case .balanced: "Opens fewer connections after repeated errors, and eases off while pages load."
        case .browserPriority: "Holds downloads well back while a page loads or video plays, so browsing stays quick."
        case .downloadPriority: "Keeps downloads going at nearly full speed, easing off only a little while pages load."
        case .custom: "Only the speed and connection numbers you set. Nothing changes by itself."
        }
    }
    /// Whether the controller does anything at all in this mode.
    var isAdaptive: Bool { self == .balanced || self == .browserPriority || self == .downloadPriority }
}

// MARK: - Browser activity

/// Whether the browser is busy loading, as far as navigation events say. It holds a count and some times: no address, no title, no content, nothing about which tab (or whether it is private).
/// A load that never reports its end (a lost event) cannot hold downloads back for long: a flag older than `staleAfter` is ignored.
final class BrowserActivity: @unchecked Sendable {
    static let shared = BrowserActivity()
    static let staleAfter = 60.0

    private let lock = NSLock()
    private var loading = 0
    private var lastEvent = -Double.infinity
    private var lastEnd = -Double.infinity
    private let clock: MonotonicClock
    init(clock: MonotonicClock = SystemMonotonicClock()) { self.clock = clock }

    func navigationStarted() { lock.lock(); loading += 1; lastEvent = clock.now(); lock.unlock() }
    func navigationEnded() {
        lock.lock()
        let now = clock.now()
        loading = max(0, loading - 1); lastEvent = now; lastEnd = now
        lock.unlock()
    }

    /// Busy while something is loading (and was reported recently), and for `grace` seconds after the last load ended.
    func isBusy(grace: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()
        if loading > 0, now - lastEvent < Self.staleAfter { return true }
        if loading > 0 { loading = 0 }                       // a stale count is dropped
        return now - lastEnd < grace
    }

    func reset() { lock.lock(); loading = 0; lastEvent = -.infinity; lastEnd = -.infinity; lock.unlock() }
}

// MARK: - Estimation

/// A smoothed view of recent throughput. One short transfer does not make a capacity: nothing is reported until there are `minimumSamples` samples with data in them.
struct ThroughputEstimator: Equatable, Sendable {
    static let minimumSamples = 3
    static let alpha = 0.3
    private(set) var smoothed: Double?
    private(set) var samples = 0

    mutating func add(bytesPerSecond: Double) {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return }
        smoothed = smoothed.map { $0 + Self.alpha * (bytesPerSecond - $0) } ?? bytesPerSecond
        samples += 1
    }
    /// The smoothed rate, or nil while there is too little to say.
    var estimate: Double? { samples >= Self.minimumSamples ? smoothed : nil }
    mutating func reset() { smoothed = nil; samples = 0 }
}

// MARK: - The decision

struct AdaptiveInput: Equatable, Sendable {
    var now: Double
    /// Bytes per second moved by this profile's downloads over the last interval.
    var bytesPerSecond: Double
    /// Downloads that moved data in the last interval.
    var activeTransfers: Int
    var browserBusy: Bool
    var lowPower: Bool
    var thermalSerious: Bool
    /// The network policy is holding downloads (offline, metered or Low Data Mode, as the person chose).
    var held: Bool
    /// What the person's settings allow at most.
    var workersMax: Int
    /// The person's own overall speed limit, if any. Bytes the transport has already received can briefly exceed it (data in flight), so a measurement is never taken above it.
    var manualLimit: Int64? = nil
}

struct AdaptiveDecision: Equatable, Sendable {
    /// Bytes per second all this profile's downloads may use together, or nil for no adaptive ceiling.
    var rateCeiling: Int64?
    /// Connections per download, or nil for no adaptive bound.
    var workerCeiling: Int?
    /// Set only when something changed that is worth telling.
    var reason: String?
}

/// The state and rules of adaptive control, with no clock or system calls, so every case can be tested exactly.
struct AdaptiveState: Equatable, Sendable {
    static let rateFloor: Int64 = 64 * 1024
    static let failureWindow = 30.0
    static let decreaseCooldown = 10.0
    static let increaseAfter = 30.0
    static let rateCooldown = 5.0
    static let rateHysteresis = 0.2

    var estimator = ThroughputEstimator()
    private(set) var rateCeiling: Int64?
    private(set) var workerCeiling: Int?
    private var baseline: Double?                       // the rate before a ceiling began: a ceiling is a share of this, not of the (already reduced) rate that follows
    private var failures: [Double] = []
    private var lastWorkerChange = -Double.infinity
    private var lastRateChange = -Double.infinity

    mutating func noteFailure(at now: Double) {
        failures.append(now)
        if failures.count > 32 { failures.removeFirst(failures.count - 32) }
    }

    private func factor(_ mode: AdaptiveMode) -> Double {
        switch mode { case .browserPriority: 0.4; case .downloadPriority: 0.85; default: 0.7 }
    }

    mutating func step(mode: AdaptiveMode, _ input: AdaptiveInput) -> AdaptiveDecision {
        let now = input.now
        failures.removeAll { now - $0 > Self.failureWindow }
        // Not adaptive, or held by the network policy: nothing is adjusted, and whatever was adjusted before is lifted.
        guard mode.isAdaptive, !input.held else {
            let changed = rateCeiling != nil || workerCeiling != nil
            clearCeilings()
            return AdaptiveDecision(rateCeiling: nil, workerCeiling: nil, reason: changed ? (input.held ? "Waiting for the network rule; adaptive limits cleared" : "Adaptive limits cleared") : nil)
        }
        var reason: String?

        // Measurement: only while data moves, and only while no ceiling is shaping the rate.
        if rateCeiling == nil, input.activeTransfers > 0 { estimator.add(bytesPerSecond: input.manualLimit.map { min(input.bytesPerSecond, Double($0)) } ?? input.bytesPerSecond) }

        // Connections: fewer after repeated errors (multiplicative), one more at a time after a quiet spell (additive).
        let current = workerCeiling ?? input.workersMax
        if failures.count >= 2, now - lastWorkerChange >= Self.decreaseCooldown, current > 1 {
            workerCeiling = max(1, current * 3 / 4 == current ? current - 1 : current * 3 / 4)
            lastWorkerChange = now; reason = "Several transfer errors in the last half minute: \(workerCeiling!) connection\(workerCeiling! == 1 ? "" : "s") per download"
        } else if failures.isEmpty, let ceiling = workerCeiling, now - lastWorkerChange >= Self.increaseAfter {
            lastWorkerChange = now
            workerCeiling = ceiling + 1 >= input.workersMax ? nil : ceiling + 1
            reason = workerCeiling == nil ? "Transfers are steady again: full connections restored" : "Transfers are steady: \(workerCeiling!) connections per download"
        }
        // A weak battery or a hot Mac: no more than two connections per download while it lasts.
        if input.lowPower || input.thermalSerious {
            let bound = min(workerCeiling ?? input.workersMax, 2)
            if workerCeiling != bound { workerCeiling = bound; lastWorkerChange = now; reason = input.thermalSerious ? "The Mac is hot: two connections per download" : "Low Power Mode: two connections per download" }
        }

        // Speed: only while the browser is busy, only with enough history, and only as a share of the rate measured before the ceiling.
        if input.browserBusy {
            if let base = baseline ?? estimator.estimate {
                let target = Int64(max(Double(Self.rateFloor), base * factor(mode)))
                let changedEnough = rateCeiling.map { abs(Double(target - $0)) / Double($0) > Self.rateHysteresis } ?? true
                if changedEnough, now - lastRateChange >= Self.rateCooldown {
                    if baseline == nil { baseline = base }
                    rateCeiling = target; lastRateChange = now
                    reason = "The browser is busy: downloads held to about \(DownloadStats.bytes(target))/s"
                }
            }
        } else if rateCeiling != nil, now - lastRateChange >= Self.rateCooldown {
            rateCeiling = nil; baseline = nil; lastRateChange = now
            estimator.reset()                                // the rate changes character once the ceiling is gone: measure afresh
            reason = "The browser is idle: no speed ceiling"
        }
        return AdaptiveDecision(rateCeiling: rateCeiling, workerCeiling: workerCeiling, reason: reason)
    }

    mutating func clearCeilings() { rateCeiling = nil; workerCeiling = nil; baseline = nil; failures.removeAll() }
    var recentFailures: Int { failures.count }
}

// MARK: - The controller

/// Runs the rules for one profile: samples once every few seconds while downloads are moving, applies the result to the shared controllers under that profile's owner id, and stops its timer
/// when nothing is moving. It is the only thing that writes an adaptive ceiling, and it can only lower.
@MainActor
final class AdaptiveController {
    struct Snapshot: Equatable {
        var mode: AdaptiveMode
        var measuredBytesPerSecond: Double?
        var estimateBytesPerSecond: Double?
        var rateCeiling: Int64?
        var workerCeiling: Int?
        var activeConnections: Int
        var recentFailures: Int
        var browserBusy: Bool
        var note: String?
    }

    static let maxEvents = 20

    /// Seconds between looks while downloads move. Settable so tests can run quickly.
    var interval = 2.0
    unowned let coordinator: DownloadCoordinator
    private(set) var state = AdaptiveState()
    private(set) var events: [String] = []
    private var timer: Task<Void, Never>?
    private var lastBytes: Int64 = 0
    private var lastTick: Double?
    private var history: [(time: Double, bytes: Int64)] = []
    /// Seconds the rate is averaged over. A window shorter than the bursts of a throttled transfer would not measure a rate at all.
    var window = 6.0
    private var lastMeasured = 0.0
    private var idleTicks = 0
    /// Looks in a row with nothing moving before the timer stops (it starts again with the next download).
    static let idleTicksBeforeStop = 5
    private(set) var lastBrowserBusy = false
    private(set) var lastNote: String?
    var clock: MonotonicClock = SystemMonotonicClock()
    var browser: BrowserActivity = .shared
    var lowPower: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var thermalSerious: () -> Bool = { [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) }

    init(coordinator: DownloadCoordinator) { self.coordinator = coordinator }

    var mode: AdaptiveMode { coordinator.networkSettings.adaptiveMode }

    /// Called whenever the settings change: starts or stops the timer, and lifts every adaptive limit when the mode no longer wants them.
    func settingsChanged() {
        if !mode.isAdaptive {
            timer?.cancel(); timer = nil
            state.clearCeilings(); state.estimator.reset()
            apply(AdaptiveDecision(rateCeiling: nil, workerCeiling: nil, reason: nil))
        } else { startIfNeeded() }
    }

    /// The timer runs only while an adaptive mode is on and there are downloads that could be moving.
    func startIfNeeded() {
        guard mode.isAdaptive, timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.interval ?? 2))
                guard let self, !Task.isCancelled else { return }
                if !self.tick() { self.timer = nil; return }          // nothing is active: sleep until the next start
            }
        }
    }

    /// A failure or throttle on one of this profile's transfers (counted, never described: no address, no message).
    func noteTransient() { state.noteFailure(at: clock.now()) }

    /// One look. Returns false when there is nothing active and the timer may stop.
    @discardableResult
    func tick(browserBusyOverride: Bool? = nil) -> Bool {
        let now = clock.now()
        let bytes = BandwidthController.shared.bytesAccounted(owner: coordinator.ownerID)
        // Bytes are counted as they arrive, and a throttled transfer is stopped and started, so arrival comes in bursts with gaps: a rate over one interval would swing between very high and
        // zero. The rate used is the average over a sliding window of several intervals instead.
        history.append((now, bytes))
        history.removeAll { now - $0.time > window }
        let rate: Double = {
            guard let oldest = history.first, now - oldest.time >= window / 2 else { return 0 }
            return Double(bytes - oldest.bytes) / (now - oldest.time)
        }()
        lastTick = now; lastBytes = bytes
        let active = ConnectionBudget.shared.holding(owner: coordinator.ownerID)
        lastMeasured = rate
        let busy = browserBusyOverride ?? browser.isBusy(grace: Double(coordinator.networkSettings.browserGraceSeconds))
        lastBrowserBusy = busy
        let input = AdaptiveInput(now: now, bytesPerSecond: rate, activeTransfers: rate > 0 ? max(1, active) : 0, browserBusy: busy, lowPower: lowPower(), thermalSerious: thermalSerious(),
                                  held: coordinator.networkHold != nil, workersMax: coordinator.networkSettings.workersPerDownload, manualLimit: coordinator.networkSettings.overallLimit)
        let decision = state.step(mode: mode, input)
        apply(decision)
        idleTicks = (active == 0 && rate == 0 && state.rateCeiling == nil) ? idleTicks + 1 : 0
        if idleTicks >= Self.idleTicksBeforeStop { idleTicks = 0; lastTick = nil; lastBytes = bytes; history.removeAll(); return false }
        return true
    }

    private func apply(_ decision: AdaptiveDecision) {
        BandwidthController.shared.setAdaptiveCeiling(decision.rateCeiling, owner: coordinator.ownerID)
        coordinator.http.setAdaptiveWorkerCeiling(decision.workerCeiling)
        if let reason = decision.reason {
            lastNote = reason
            events.append(reason)
            if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
            coordinator.note(reason)                           // one line per significant change, never per small adjustment
        }
    }

    var snapshot: Snapshot {
        Snapshot(mode: mode, measuredBytesPerSecond: lastMeasured > 0 ? lastMeasured : nil, estimateBytesPerSecond: state.estimator.estimate, rateCeiling: state.rateCeiling,
                 workerCeiling: state.workerCeiling, activeConnections: ConnectionBudget.shared.holding(owner: coordinator.ownerID), recentFailures: state.recentFailures,
                 browserBusy: lastBrowserBusy, note: lastNote)
    }
}
