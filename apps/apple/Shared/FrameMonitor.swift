import Combine
import Foundation
import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: What a recording adds up to

/// The sums behind the smoothness report. Plain data with no screen in it, so every number can be checked by a test.
///
/// A frame is "slow" when the screen waited more than one and a half times its expected time for it, and a "stutter" when it waited more than three
/// times. The time beyond what a frame should have taken, added up and divided by the seconds recorded, is Apple's "hitch time ratio": under 5
/// milliseconds lost per second reads as smooth, over 10 as clearly rough.
struct FrameStats: Equatable {
    struct Bucket: Equatable {
        var seconds = 0.0
        var frames = 0
        var slow = 0
        var stutters = 0
        var worstMs = 0.0
        var hitchMs = 0.0
        var modelChanges = 0

        var lostMsPerSecond: Double { seconds > 0 ? hitchMs / seconds : 0 }
    }

    struct Worst: Equatable {
        var label: String
        var ms: Double
        var at: Double
    }

    static let slowRatio = 1.5
    static let stutterRatio = 3.0
    /// A wait this long is the app being in the background or the phone locked, not a stutter.
    static let pauseSeconds = 1.0
    static let idleLabel = "Idle or other"

    private(set) var buckets: [String: Bucket] = [:]
    private(set) var worst: [Worst] = []
    private(set) var pauses = 0
    private(set) var publishers: [String: Int] = [:]

    mutating func record(interval: Double, expected: Double, label: String, at: Double) {
        guard expected > 0, interval > 0 else { return }
        if interval >= Self.pauseSeconds { pauses += 1; return }
        var bucket = buckets[label, default: Bucket()]
        bucket.seconds += interval
        bucket.frames += 1
        let ratio = interval / expected
        if ratio > Self.slowRatio {
            bucket.slow += 1
            bucket.hitchMs += (interval - expected) * 1000
            bucket.worstMs = max(bucket.worstMs, interval * 1000)
            if ratio > Self.stutterRatio { bucket.stutters += 1 }
            keepIfAmongTheWorst(Worst(label: label, ms: interval * 1000, at: at))
        }
        buckets[label] = bucket
    }

    /// One notification that the whole model is about to change, and (when it could be found) which property set it, from where.
    mutating func noteModelChange(label: String, site: String?) {
        buckets[label, default: Bucket()].modelChanges += 1
        if let site { publishers[site, default: 0] += 1 }
    }

    private mutating func keepIfAmongTheWorst(_ candidate: Worst) {
        worst.append(candidate)
        worst.sort { $0.ms > $1.ms }
        if worst.count > 10 { worst.removeLast(worst.count - 10) }
    }

    var seconds: Double { buckets.values.reduce(0) { $0 + $1.seconds } }
    var frames: Int { buckets.values.reduce(0) { $0 + $1.frames } }
    var slow: Int { buckets.values.reduce(0) { $0 + $1.slow } }
    var stutters: Int { buckets.values.reduce(0) { $0 + $1.stutters } }
    var hitchMs: Double { buckets.values.reduce(0) { $0 + $1.hitchMs } }
    var modelChanges: Int { buckets.values.reduce(0) { $0 + $1.modelChanges } }
    var lostMsPerSecond: Double { seconds > 0 ? hitchMs / seconds : 0 }

    static func rating(lostMsPerSecond value: Double) -> String {
        value < 5 ? "smooth" : (value < 10 ? "borderline" : "rough")
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return whole >= 60 ? "\(whole / 60) min \(whole % 60) s" : String(format: "%.1f s", seconds)
    }

    /// The text that is copied. It holds action names, counts and Swift symbol names, never an address or a page title.
    func report(header: [String]) -> String {
        var lines = ["Smoothness report"] + header + [""]
        lines.append("Recorded \(Self.clock(seconds)) · \(frames) frames · \(slow) slow · \(stutters) stutters · lost \(String(format: "%.1f", lostMsPerSecond)) ms per second (\(Self.rating(lostMsPerSecond: lostMsPerSecond)))")
        lines.append("The whole model announced a change \(modelChanges) times (\(String(format: "%.1f", seconds > 0 ? Double(modelChanges) / seconds : 0)) per second)")
        if pauses > 0 { lines.append("Left out: \(pauses) pause(s) of a second or more (the app was in the background)") }
        lines += ["", "By what was happening, most time lost first:"]
        for (label, b) in buckets.sorted(by: { $0.value.hitchMs > $1.value.hitchMs }) {
            lines.append("  " + label.padding(toLength: 26, withPad: " ", startingAt: 0)
                         + String(format: "%6.1f s · %5d frames · slow %3d · stutters %3d · worst %4.0f ms · lost %5.1f ms/s (%@) · model changes %d",
                                  b.seconds, b.frames, b.slow, b.stutters, b.worstMs, b.lostMsPerSecond, Self.rating(lostMsPerSecond: b.lostMsPerSecond), b.modelChanges))
        }
        if !worst.isEmpty {
            lines += ["", "Ten longest single frames (when, what, how long):"]
            for item in worst { lines.append(String(format: "  +%6.1f s  ", item.at) + item.label.padding(toLength: 26, withPad: " ", startingAt: 0) + String(format: "%4.0f ms", item.ms)) }
        }
        if !publishers.isEmpty {
            lines += ["", "What made the whole model announce a change (count, then the property or function that did it ← its caller; names are Swift-mangled, run them through `swift demangle`):"]
            for (site, count) in publishers.sorted(by: { $0.value > $1.value }).prefix(14) { lines.append("  \(count) ×  \(site)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// Finds who set a property of the model, from a stack trace taken inside its change notification.
enum PublisherSite {
    /// "3   Browser Setu   0x000000010a3c1d4 $s12Browser_Setu12BrowserModelC15chromeCollapsedSbvs + 156" gives just the symbol.
    static func symbol(of frame: String) -> String {
        let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
        guard let at = parts.firstIndex(where: { $0.hasPrefix("0x") }), at + 1 < parts.count else { return frame }
        return String(parts[at + 1])
    }

    /// The first frame that belongs to the model (skipping this recorder and the framework plumbing that carries a notification), and the frame that called it.
    static func describe(_ frames: [String]) -> String? {
        let symbols = frames.map(symbol(of:))
        let plumbing = ["FrameMonitor", "Combine", "ObservableObject", "Published", "SwiftUI"]
        guard let index = symbols.firstIndex(where: { $0.contains("BrowserModelC") && !plumbing.contains(where: $0.contains) }) else { return nil }
        let caller = index + 1 < symbols.count ? symbols[index + 1] : ""
        return caller.isEmpty ? symbols[index] : symbols[index] + " ← " + caller
    }
}

// MARK: The recorder

/// Counts how long every frame the screen asked for really took, and what the person was doing at the time, so "it feels janky" becomes numbers
/// that say where. It runs only while the switch in Settings › Performance is on, keeps everything in memory, and sends nothing anywhere. While it
/// runs the screen is held at its top refresh rate and each model change is traced, so the app itself uses somewhat more power and time.
@MainActor
final class FrameMonitor: ObservableObject {
    static let shared = FrameMonitor()
    /// Read by the one-line hooks around the app, so a hook costs nothing while the recorder is off.
    static var isOn = false

    @Published private(set) var isRecording = false
    @Published private(set) var liveLine = "Not recording"
    private(set) var stats = FrameStats()

    private var label = FrameStats.idleLabel
    private var labelUntil: CFTimeInterval = 0
    private weak var model: BrowserModel?
    private var observer: AnyCancellable?
    private var segmentStart: CFTimeInterval = 0
    private var recordedBefore: Double = 0
    private var stackWindowStart: CFTimeInterval = 0
    private var stacksInWindow = 0
    #if os(iOS)
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var ticker: Timer?
    #endif

    var hasData: Bool { stats.frames > 0 }

    /// Names what the person is doing for the next moments, so the frames in them are filed under it.
    static func mark(_ name: String, for seconds: Double = 1.2) {
        guard isOn else { return }
        shared.label = name
        shared.labelUntil = CACurrentMediaTime() + seconds
    }

    private func currentLabel(_ now: CFTimeInterval) -> String {
        if now < labelUntil { return label }
        if model?.active?.isLoading == true { return "Page loading" }
        return FrameStats.idleLabel
    }

    // MARK: Start, stop

    func start(model: BrowserModel) {
        #if os(iOS)
        guard !isRecording else { return }
        self.model = model
        observer = model.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.modelWillChange() } }
        segmentStart = CACurrentMediaTime()
        lastTimestamp = nil
        let target = FrameLinkTarget(owner: self)
        let created = CADisplayLink(target: target, selector: #selector(FrameLinkTarget.tick(_:)))
        created.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        created.add(to: .main, forMode: .common)
        link = created
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshLine() } }
        Self.isOn = true
        isRecording = true
        refreshLine()
        #endif
    }

    func stop() {
        #if os(iOS)
        guard isRecording else { return }
        recordedBefore += CACurrentMediaTime() - segmentStart
        link?.invalidate(); link = nil
        ticker?.invalidate(); ticker = nil
        observer = nil
        Self.isOn = false
        isRecording = false
        refreshLine()
        #endif
    }

    func reset() {
        stats = FrameStats()
        recordedBefore = 0
        segmentStart = CACurrentMediaTime()
        refreshLine()
    }

    // MARK: Frames and changes

    #if os(iOS)
    fileprivate func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard let last = lastTimestamp else { return }
        let expected = link.targetTimestamp - link.timestamp
        stats.record(interval: now - last, expected: expected, label: currentLabel(CACurrentMediaTime()),
                     at: recordedBefore + (CACurrentMediaTime() - segmentStart))
    }
    #endif

    private func modelWillChange() {
        guard isRecording else { return }
        stats.noteModelChange(label: currentLabel(CACurrentMediaTime()), site: tracedSite())
    }

    /// A stack trace costs real time, so at most 150 are taken a second; a burst past that is still counted, just not traced.
    private func tracedSite() -> String? {
        let now = CACurrentMediaTime()
        if now - stackWindowStart > 1 { stackWindowStart = now; stacksInWindow = 0 }
        guard stacksInWindow < 150 else { return nil }
        stacksInWindow += 1
        return PublisherSite.describe(Thread.callStackSymbols)
    }

    private func refreshLine() {
        guard hasData else { liveLine = isRecording ? "Recording…" : "Not recording"; return }
        liveLine = "\(FrameStats.clock(stats.seconds)) · \(stats.frames) frames · lost \(String(format: "%.1f", stats.lostMsPerSecond)) ms/s (\(FrameStats.rating(lostMsPerSecond: stats.lostMsPerSecond)))"
    }

    // MARK: The report

    func report() -> String {
        guard let model else { return stats.report(header: ["(no browser window was attached)"]) }
        var header: [String] = []
        let info = Bundle.main.infoDictionary
        header.append("Browser Setu \(info?["CFBundleShortVersionString"] as? String ?? "?") (build \(info?["CFBundleVersion"] as? String ?? "?"))")
        #if os(iOS)
        header.append("\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion), screen up to \(UIScreen.main.maximumFramesPerSecond) Hz")
        header.append("Low Power Mode \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off") · thermal state \(Self.thermalName(ProcessInfo.processInfo.thermalState))")
        #endif
        header.append("Tabs \(model.tabs.count) (\(model.tabs.filter(\.isDiscarded).count) asleep) · theme \(model.themeIsActive ? model.activeTheme.name : "none")\(ThemeState.animated ? " (animated)" : "") · animation setting \(model.motionStyle.title)")
        return stats.report(header: header)
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

#if os(iOS)
/// Receives the screen's ticks, so the display link does not hold the recorder itself.
private final class FrameLinkTarget: NSObject {
    weak var owner: FrameMonitor?
    init(owner: FrameMonitor) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { owner?.frame(link) } }
}
#endif

// MARK: The switch in Settings

struct SmoothnessSection: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var monitor = FrameMonitor.shared

    var body: some View {
        #if os(iOS)
        Section {
            Toggle("Record smoothness", isOn: Binding(get: { monitor.isRecording }, set: { on in on ? monitor.start(model: model) : monitor.stop() }))
            if monitor.isRecording || monitor.hasData { LabeledContent("So far", value: monitor.liveLine) }
            Button("Copy the Report") {
                copyToPasteboard(monitor.report())
                model.notice = "Smoothness report copied. It holds no addresses or titles."
            }
            .disabled(!monitor.hasData)
            Button("Start Over", role: .destructive) { monitor.reset() }.disabled(!monitor.hasData)
        } header: { Text("Smoothness recorder") } footer: {
            Text("For finding what makes the browser stutter. Turn it on, use the browser as you normally do for a few minutes (switch tabs, scroll, open the address bar, open the overview), then come back and copy the report. It counts frames that came late and says what you were doing at the time. It keeps nothing after you quit and sends nothing anywhere. While it runs the screen is held at its top refresh rate, so it uses more battery.")
        }
        #else
        EmptyView()
        #endif
    }
}
