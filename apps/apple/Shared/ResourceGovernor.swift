import Foundation
import Network
import Darwin
#if os(macOS)
import IOKit.ps
#else
import UIKit
#endif

/// What the device is doing about power right now.
struct PowerState: Equatable {
    var onBattery = false
    /// 0...1, or nil when the device has no battery or will not say.
    var level: Double?
    var lowPowerMode = false
    var thermal: ProcessInfo.ThermalState = .nominal

    static func read() -> PowerState {
        var state = PowerState(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
        #if os(macOS)
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType else { continue }
                state.onBattery = d[kIOPSPowerSourceStateKey as String] as? String == kIOPSBatteryPowerValue
                if let now = d[kIOPSCurrentCapacityKey as String] as? Double, let full = d[kIOPSMaxCapacityKey as String] as? Double, full > 0 { state.level = now / full }
            }
        }
        #else
        UIDevice.current.isBatteryMonitoringEnabled = true
        state.onBattery = UIDevice.current.batteryState == .unplugged
        if UIDevice.current.batteryLevel >= 0 { state.level = Double(UIDevice.current.batteryLevel) }
        #endif
        return state
    }
}

/// Decides which profile is really in force. Pure, so the choices can be tested.
enum GovernorRules {
    /// Battery Saver takes over a Balanced profile when the battery is low, Low Power Mode is on, or the device is running hot, if the person allows it.
    static func effective(base: MemoryMode, power: PowerState, batteryAware: Bool, lowPowerSaves: Bool) -> (mode: MemoryMode, reason: String?) {
        guard base == .balanced else { return (base, nil) }
        if lowPowerSaves, power.lowPowerMode { return (.battery, "Low Power Mode is on") }
        guard batteryAware else { return (base, nil) }
        if power.thermal == .serious || power.thermal == .critical { return (.battery, "the device is running hot") }
        if power.onBattery, let level = power.level, level <= 0.2 { return (.battery, "the battery is at \(Int(level * 100))%") }
        return (base, nil)
    }

    /// A rough label from this app's own average CPU use. Web pages run in separate processes the system does not let us measure here.
    static func energyLabel(averageCPU: Double) -> String {
        switch averageCPU {
        case ..<0.05: "Low"
        case ..<0.25: "Moderate"
        default: "High"
        }
    }

    /// Seconds between the window's background checks (sound, scheduled pages): slower when saving power.
    static func watchInterval(for mode: MemoryMode) -> Double { mode == .battery ? 10 : 3 }

    /// Thumbnails of other tabs are not refreshed while saving battery, or under serious heat.
    static func allowsThumbnails(mode: MemoryMode, power: PowerState) -> Bool {
        mode != .battery && power.thermal != .serious && power.thermal != .critical
    }
}

/// What the system says about the connection right now.
struct PathInfo: Equatable {
    var online = true
    var expensive = false
    var constrained = false
    var ipv4 = true
    var ipv6 = false
    var dns = true
    /// "Wi-Fi", "Ethernet", "Cellular", "Other": the kinds of link the connection can use.
    var links: [String] = []
    var interfaces: [String] = []

    var summary: String { !online ? "Offline" : (constrained ? "Low Data Mode" : (expensive ? "Metered connection" : "Normal")) }
}

/// Connection quality from the system: a metered link (cellular, hotspot) or Low Data Mode means background downloads can wait.
@MainActor
final class NetworkConditions {
    static let shared = NetworkConditions()
    private let monitor = NWPathMonitor()
    private(set) var info = PathInfo()
    private var observers: [(owner: () -> AnyObject?, handler: (PathInfo, PathInfo) -> Void)] = []

    /// Calls `handler` with the old and new state whenever the connection changes: offline or back, a different kind of link, metered or not.
    func observe(_ owner: AnyObject, _ handler: @escaping (PathInfo, PathInfo) -> Void) {
        observers.removeAll { $0.owner() == nil }
        observers.append(({ [weak owner] in owner }, handler))
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            var links: [String] = []
            for (type, name) in [(NWInterface.InterfaceType.wifi, "Wi-Fi"), (.wiredEthernet, "Ethernet"), (.cellular, "Cellular"), (.other, "Other")] where path.usesInterfaceType(type) { links.append(name) }
            let new = PathInfo(online: path.status == .satisfied, expensive: path.isExpensive, constrained: path.isConstrained, ipv4: path.supportsIPv4, ipv6: path.supportsIPv6,
                               dns: path.supportsDNS, links: links, interfaces: path.availableInterfaces.map(\.name))
            Task { @MainActor in
                guard let self else { return }
                let old = self.info
                self.info = new
                if old != new { for o in self.observers where o.owner() != nil { o.handler(old, new) } }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.browsersetu.network-conditions"))
    }

    var expensive: Bool { info.expensive }
    var constrained: Bool { info.constrained }
    var offline: Bool { !info.online }

    /// Automatic list updates and other optional downloads wait on a metered or Low Data connection.
    var shouldDeferBackground: Bool { info.expensive || info.constrained }
    var summary: String { info.summary }
}

/// This app's own CPU use, sampled from the system's resource counters. It does not include the web pages' processes.
@MainActor
final class ProcessSampler: ObservableObject {
    @Published private(set) var cpu = 0.0
    @Published private(set) var average = 0.0
    private var last: (cpuSeconds: Double, at: Date)?
    private var recent: [Double] = []

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    /// Call every few seconds. The first call only sets the starting point.
    func sample(now: Date = Date()) {
        let used = Self.cpuSeconds()
        defer { last = (used, now) }
        guard let last, now.timeIntervalSince(last.at) > 0.5 else { return }
        cpu = max(0, (used - last.cpuSeconds) / now.timeIntervalSince(last.at))
        recent.append(cpu)
        if recent.count > 20 { recent.removeFirst() }
        average = recent.reduce(0, +) / Double(recent.count)
    }
}

/// Memory the whole device has free, from the kernel's page counts.
func availableSystemMemory() -> UInt64 {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(vm_kernel_page_size)
}

/// Timings of the moments that decide how fast the browser feels, kept on this device so a slower launch than usual shows up.
struct PerfRecord: Codable, Equatable {
    var name: String
    var millis: Double
    var date = Date()
}

enum PerfLog {
    static let keep = 20

    /// Adds a timing, keeping the last `keep` of each name.
    static func add(_ record: PerfRecord, to list: [PerfRecord]) -> [PerfRecord] {
        var all = list + [record]
        let same = all.filter { $0.name == record.name }
        if same.count > keep { all.removeAll { $0.name == record.name && $0.date < same[same.count - keep].date } }
        return all
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The newest timing against the middle of the earlier ones. A regression is 50% slower or more, with at least four earlier runs.
    static func compare(_ name: String, in list: [PerfRecord]) -> (latest: Double, typical: Double, regression: Bool)? {
        let same = list.filter { $0.name == name }
        guard let latest = same.last, let typical = median(same.dropLast().map(\.millis)) else { return nil }
        return (latest.millis, typical, same.count > 4 && latest.millis >= typical * 1.5)
    }
}

/// The browser-wide view of resources: the profile in force and why, power, network, CPU, and the timing history.
@MainActor
final class ResourceGovernor: ObservableObject {
    @Published private(set) var power = PowerState.read()
    @Published private(set) var reason: String?
    let process = ProcessSampler()
    private weak var model: BrowserModel?

    init(model: BrowserModel) { self.model = model }

    /// Reads power and CPU. Cheap; called when the dashboard is open and by the lifecycle timer.
    func refresh() {
        power = PowerState.read()
        process.sample()
        reason = effective.reason
    }

    var effective: (mode: MemoryMode, reason: String?) {
        guard let model else { return (.balanced, nil) }
        return GovernorRules.effective(base: model.memoryMode, power: power, batteryAware: model.batteryAware, lowPowerSaves: model.lowPowerSavesMemory)
    }

    var allowsThumbnails: Bool { GovernorRules.allowsThumbnails(mode: effective.mode, power: power) }
    var watchInterval: Double { GovernorRules.watchInterval(for: effective.mode) }
}
