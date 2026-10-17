import SwiftUI
import Darwin

/// The deep black the iPhone's floating pieces are made of: near-black fill, a faint light along the top edge, a soft shadow.
/// Text and symbols on it are white.
enum Obsidian {
    static let fill = Color(white: 0.045)
    static var edge: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.07)], startPoint: .top, endPoint: .bottom)
    }
}

/// Live network throughput of this device, read from the system's own interface counters. It sends nothing and contacts no
/// server; it only watches how many bytes the Wi-Fi, Ethernet and cellular interfaces have moved since a second ago.
@MainActor
final class NetworkSpeedMonitor: ObservableObject {
    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0
    private var last: (down: UInt64, up: UInt64, at: Date)?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        last = Self.counters().map { ($0.down, $0.up, Date()) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil; last = nil; down = 0; up = 0
    }

    private func sample() {
        guard let now = Self.counters() else { return }
        let at = Date()
        if let last, at.timeIntervalSince(last.at) > 0.2 {
            let seconds = at.timeIntervalSince(last.at)
            down = Double(now.down &- last.down) / seconds
            up = Double(now.up &- last.up) / seconds
            if down < 0 || down > 1e11 { down = 0 }
            if up < 0 || up > 1e11 { up = 0 }
        }
        last = (now.down, now.up, at)
    }

    /// Bytes received and sent so far on real network interfaces (not loopback or VPN tunnels, which would count twice).
    nonisolated static func counters() -> (down: UInt64, up: UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var down: UInt64 = 0, up: UInt64 = 0
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let info = entry.pointee
            guard let addr = info.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  (info.ifa_flags & UInt32(IFF_UP)) != 0, (info.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let data = info.ifa_data else { continue }
            let name = String(cString: info.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(stats.ifi_ibytes)
            up += UInt64(stats.ifi_obytes)
        }
        return (down, up)
    }

    static func format(_ bytesPerSecond: Double) -> String {
        let bits = bytesPerSecond * 8
        switch bits {
        case ..<1_000: return "0 Kbps"
        case ..<1_000_000: return String(format: "%.0f Kbps", bits / 1_000)
        case ..<100_000_000: return String(format: "%.1f Mbps", bits / 1_000_000)
        default: return String(format: "%.0f Mbps", bits / 1_000_000)
        }
    }
}

/// A small glass pill with the live download and upload speed. Only runs while it is on screen.
struct SpeedPill: View {
    @StateObject private var monitor = NetworkSpeedMonitor()
    /// The same height as the pills it sits beside, so the row reads as one set.
    var height: CGFloat = 30

    var body: some View {
        HStack(spacing: height <= 22 ? 6 : 8) {
            Label(NetworkSpeedMonitor.format(monitor.down), systemImage: "arrow.down")
            Label(NetworkSpeedMonitor.format(monitor.up), systemImage: "arrow.up")
        }
        .labelStyle(CompactSpeedLabel())
        .font(.system(size: height >= 40 ? 13 : (height <= 22 ? 10 : 12), weight: .medium).monospacedDigit())
        // White on a dark glass pill, so the numbers read over any page, light or dark.
        .foregroundStyle(.white)
        .padding(.horizontal, height >= 40 ? 14 : (height <= 22 ? 7 : 11)).frame(height: height)
        .background(Obsidian.fill.opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(Obsidian.edge, lineWidth: 0.6))
        .shadow(color: .black.opacity(height >= 40 ? 0.3 : 0.38), radius: height >= 40 ? 10 : (height <= 22 ? 4 : 9), y: height <= 22 ? 1 : 3)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        // Never in the way: taps and scrolls go straight through to the page underneath.
        .allowsHitTesting(false)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download \(NetworkSpeedMonitor.format(monitor.down)), upload \(NetworkSpeedMonitor.format(monitor.up))")
        .accessibilityIdentifier("speed-pill")
    }
}

private struct CompactSpeedLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8, weight: .bold))
            configuration.title
        }
    }
}
