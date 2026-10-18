import Foundation
import Network
import SwiftUI
import Charts
import Darwin

// MARK: Interfaces

struct InterfaceInfo: Identifiable, Equatable {
    var name: String
    var kind: String
    var ipv4: [String]
    var ipv6: [String]
    var up: Bool
    var id: String { name }
}

enum NetworkInterfaces {
    /// A plain name for a system interface name.
    static func kind(of name: String) -> String {
        if name.hasPrefix("lo") { return "Loopback" }
        if name.hasPrefix("pdp_ip") { return "Cellular" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return "VPN or tunnel" }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return "Apple device link" }
        if name.hasPrefix("bridge") || name.hasPrefix("ap") { return "Bridge" }
        if name.hasPrefix("en") { return "Wi-Fi or Ethernet" }
        return "Other"
    }

    static func list() -> [InterfaceInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var map: [String: InterfaceInfo] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            let name = String(cString: item.ifa_name)
            var info = map[name] ?? InterfaceInfo(name: name, kind: kind(of: name), ipv4: [], ipv6: [], up: (item.ifa_flags & UInt32(IFF_UP)) != 0 && (item.ifa_flags & UInt32(IFF_RUNNING)) != 0)
            if let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) || addr.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: host)
                    if addr.pointee.sa_family == UInt8(AF_INET) { info.ipv4.append(text) } else { info.ipv6.append(text) }
                }
            }
            map[name] = info
        }
        return map.values.filter { !$0.ipv4.isEmpty || !$0.ipv6.isEmpty }.sorted { $0.name < $1.name }
    }

    /// Name servers the system is using, from its resolver file (Mac only; empty where the file is not readable).
    static func resolvers() -> [String] {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            return parts.count == 2 && parts[0] == "nameserver" ? String(parts[1]) : nil
        }
    }
}

// MARK: Probing one site

struct ProbeResult: Equatable {
    var host: String
    var ipv4: [String] = []
    var ipv6: [String] = []
    var dnsMs: Double?
    var tcpMs: Double?
    var tlsMs: Double?
    var tlsVersion: String?
    var httpStatus: Int?
    var firstByteMs: Double?
    var error: String?
}

enum ConnectionProbe {
    /// Looks the site up, connects, negotiates TLS and asks for its headers, timing each step. The probe is the app's own connection, not the
    /// page's: a proxy or a different route can make a page behave differently.
    static func run(host: String) async -> ProbeResult {
        var r = ProbeResult(host: host)
        let t0 = Date()
        let found: [(family: Int32, address: String)] = await Task.detached { lookup(host) }.value
        r.dnsMs = Date().timeIntervalSince(t0) * 1000
        r.ipv4 = found.filter { $0.family == AF_INET }.map(\.address)
        r.ipv6 = found.filter { $0.family == AF_INET6 }.map(\.address)
        guard !found.isEmpty else { r.error = "The name could not be looked up. The site may not exist, or this network cannot resolve it."; return r }
        r.tcpMs = await connect(host: host, tls: false).ms
        let secure = await connect(host: host, tls: true)
        r.tlsMs = secure.ms
        r.tlsVersion = secure.version
        if secure.ms == nil && r.tcpMs == nil { r.error = "Could not connect to port 443 on that site." }
        if let url = URL(string: "https://\(host)/") {
            let started = Date()
            var request = URLRequest(url: url, timeoutInterval: 10); request.httpMethod = "HEAD"
            let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
            if let (_, response) = try? await URLSession(configuration: config).data(for: request), let http = response as? HTTPURLResponse {
                r.httpStatus = http.statusCode
                r.firstByteMs = Date().timeIntervalSince(started) * 1000
            }
        }
        return r
    }

    nonisolated private static func lookup(_ host: String) -> [(family: Int32, address: String)] {
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }
        var out: [(Int32, String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer)
                if !out.contains(where: { $0.1 == text }) { out.append((entry.pointee.ai_family, text)) }
            }
        }
        return out
    }

    private static func connect(host: String, tls: Bool) async -> (ms: Double?, version: String?) {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: tls ? .tls : .tcp)
            let started = Date()
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            func finish(_ ms: Double?, _ version: String?) {
                guard !once.done else { return }
                once.done = true
                connection.cancel()
                continuation.resume(returning: (ms, version))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var version: String?
                    if tls, let meta = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                        switch sec_protocol_metadata_get_negotiated_tls_protocol_version(meta.securityProtocolMetadata) {
                        case .TLSv13: version = "TLS 1.3"
                        case .TLSv12: version = "TLS 1.2"
                        case .TLSv11: version = "TLS 1.1"
                        case .TLSv10: version = "TLS 1.0"
                        default: version = "TLS"
                        }
                    }
                    finish(Date().timeIntervalSince(started) * 1000, version)
                case .failed, .cancelled: finish(nil, nil)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "app.browsersetu.probe"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { finish(nil, nil) }
        }
    }
}

// MARK: Captive portal

enum CaptiveState: Equatable { case clear, suspected(String), unknown(String) }

enum CaptivePortal {
    /// Apple's own test page answers a short "Success" page when the connection is open. Anything else, or a redirect, means a sign-in page is in the way.
    static func classify(status: Int?, body: String, redirected: Bool, error: String?) -> CaptiveState {
        if let error { return .unknown(error) }
        if redirected { return .suspected("The network redirected the test page, which usually means a sign-in page.") }
        guard let status else { return .unknown("No answer.") }
        if status == 200, body.contains("Success") { return .clear }
        return .suspected("The test page did not come back as expected (\(status)).")
    }

    /// Asks apple's connectivity test page once. This contacts that host, so it only runs when the person asks.
    static func check() async -> CaptiveState {
        guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html") else { return .unknown("Bad address.") }
        final class Delegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            var redirected = false
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { redirected = true; return nil }
        }
        let delegate = Delegate()
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        do {
            let (data, response) = try await session.data(from: url)
            let http = response as? HTTPURLResponse
            return classify(status: http?.statusCode, body: String(decoding: data.prefix(2000), as: UTF8.self), redirected: delegate.redirected || (http.map { (300..<400).contains($0.statusCode) } ?? false), error: nil)
        } catch let error as URLError where error.code == .notConnectedToInternet { return .unknown("This device is offline.") }
        catch { return delegate.redirected ? classify(status: nil, body: "", redirected: true, error: nil) : .unknown("The test page could not be reached.") }
    }
}

// MARK: Usage

enum NetworkSession {
    /// Bytes on the network interfaces when the app started; the difference is this session's traffic for the whole device, not for this app alone.
    nonisolated(unsafe) static let baseline: (down: UInt64, up: UInt64) = NetworkSpeedMonitor.counters() ?? (0, 0)

    static func used() -> (down: UInt64, up: UInt64) {
        guard let now = NetworkSpeedMonitor.counters() else { return (0, 0) }
        return (now.down &- baseline.down, now.up &- baseline.up)
    }
}

/// How a page's requests split by kind of file, from its resource timings.
enum ResourceBreakdown {
    struct Row: Identifiable, Equatable { var type: String; var count: Int; var bytes: Int; var id: String { type } }

    static func rows(_ entries: [ResourceEntry]) -> [Row] {
        Dictionary(grouping: entries, by: \.type).map { Row(type: $0.key, count: $0.value.count, bytes: Int($0.value.reduce(0) { $0 + $1.transferBytes })) }
            .sorted { $0.bytes == $1.bytes ? $0.count > $1.count : $0.bytes > $1.bytes }
    }
}

// MARK: Screen

struct NetworkToolsView: View {
    @EnvironmentObject var model: BrowserModel
    @StateObject private var speed = NetworkSpeedMonitor()
    @State private var samples: [(at: Date, down: Double, up: Double)] = []
    @State private var interfaces: [InterfaceInfo] = []
    @State private var probe: ProbeResult?
    @State private var probing = false
    @State private var captive: CaptiveState?
    @State private var checkingCaptive = false
    @State private var tick = Date()
    private let pulse = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var host: String? { model.active?.url?.host }

    var body: some View {
        let path = NetworkConditions.shared.info
        List {
            Section("Connection") {
                LabeledContent("Status", value: path.online ? "Online" : "Offline")
                LabeledContent("Kind", value: path.links.isEmpty ? "None" : path.links.joined(separator: ", "))
                LabeledContent("Quality", value: path.summary)
                LabeledContent("IPv4", value: path.ipv4 ? "Available" : "Not available")
                LabeledContent("IPv6", value: path.ipv6 ? "Available" : "Not available")
                LabeledContent("DNS", value: path.dns ? "Available" : "Not available")
                let resolvers = NetworkInterfaces.resolvers()
                LabeledContent("Resolvers", value: resolvers.isEmpty ? "Not shown on this device" : resolvers.joined(separator: ", "))
                LabeledContent("Proxy", value: model.proxy == nil ? "None" : "In use")
            }
            Section("Interfaces") {
                ForEach(interfaces) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(i.name) · \(i.kind)" + (i.up ? "" : " · down")).fontWeight(.medium)
                        ForEach(i.ipv4, id: \.self) { Text("IPv4  " + $0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        ForEach(i.ipv6.prefix(3), id: \.self) { Text("IPv6  " + $0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                }
            }
            Section {
                Button(probing ? "Testing…" : "Test the Connection to \(host ?? "This Site")") { runProbe() }.disabled(probing || host == nil)
                if let p = probe {
                    if let error = p.error { Text(error).foregroundStyle(.red) }
                    LabeledContent("Name lookup", value: ms(p.dnsMs))
                    LabeledContent("Addresses", value: "\(p.ipv4.count) IPv4, \(p.ipv6.count) IPv6")
                    LabeledContent("Connect (TCP)", value: ms(p.tcpMs))
                    LabeledContent("Secure connection", value: ms(p.tlsMs) + (p.tlsVersion.map { " · " + $0 } ?? ""))
                    LabeledContent("First answer", value: ms(p.firstByteMs) + (p.httpStatus.map { " · HTTP \($0)" } ?? ""))
                }
            } header: { Text("This Site") } footer: {
                Text("A separate test connection from this app, timed step by step. WebKit makes the page's own connections, so a proxy or a different route can give different numbers.")
            }
            Section {
                Button(checkingCaptive ? "Checking…" : "Check for a Sign-in Page (Wi-Fi Portal)") { runCaptive() }.disabled(checkingCaptive)
                switch captive {
                case .clear?: Label("The connection is open.", systemImage: "checkmark.circle").foregroundStyle(.green)
                case .suspected(let why)?:
                    Label(why, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                    Button("Open the Sign-in Page") { model.open(urlString: "http://captive.apple.com", newTab: true) }
                case .unknown(let why)?: Text(why).foregroundStyle(.secondary)
                case nil: EmptyView()
                }
            } header: { Text("Wi-Fi Sign-in") } footer: {
                Text("Hotel and café Wi-Fi often needs a sign-in before pages load. This asks Apple's connectivity test page once, only when you tap.")
            }
            Section {
                if samples.count > 2 {
                    Chart {
                        ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                            LineMark(x: .value("Time", s.at), y: .value("Mbps", s.down * 8 / 1e6), series: .value("Direction", "Down")).foregroundStyle(.blue)
                            LineMark(x: .value("Time", s.at), y: .value("Mbps", s.up * 8 / 1e6), series: .value("Direction", "Up")).foregroundStyle(.orange)
                        }
                    }
                    .chartYAxisLabel("Mbps").frame(height: 120)
                }
                LabeledContent("Now", value: "↓ \(NetworkSpeedMonitor.format(speed.down))  ↑ \(NetworkSpeedMonitor.format(speed.up))")
                let used = NetworkSession.used()
                LabeledContent("Since the app opened", value: "↓ \(ByteCountFormatter.string(fromByteCount: Int64(used.down), countStyle: .binary))  ↑ \(ByteCountFormatter.string(fromByteCount: Int64(used.up), countStyle: .binary))")
            } header: { Text("Throughput and Usage") } footer: {
                Text("Counts all traffic on this device's network interfaces, not only Browser Setu's. The system does not report per-app totals to an app.")
            }
            if let snap = model.workbench.snapshot {
                Section("This Page's Requests by Kind") {
                    ForEach(ResourceBreakdown.rows(snap.resources)) { row in
                        LabeledContent("\(row.type) · \(row.count)", value: ByteCountFormatter.string(fromByteCount: Int64(row.bytes), countStyle: .file))
                    }
                }
            }
        }
        .onAppear { speed.start(); interfaces = NetworkInterfaces.list() }
        .onDisappear { speed.stop() }
        .onReceive(pulse) { _ in
            samples.append((Date(), speed.down, speed.up))
            if samples.count > 120 { samples.removeFirst(samples.count - 120) }
            tick = Date()
        }
    }

    private func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "Failed" }

    private func runProbe() {
        guard let host else { return }
        probing = true; probe = nil
        Task { probe = await ConnectionProbe.run(host: host); probing = false }
    }

    private func runCaptive() {
        checkingCaptive = true; captive = nil
        Task { captive = await CaptivePortal.check(); checkingCaptive = false }
    }
}


@MainActor
extension BrowserModel {
    /// Tells the person when the connection drops, comes back, or changes kind. Pages that failed for lack of a connection retry by themselves.
    func observeNetwork() {
        NetworkConditions.shared.observe(self) { [weak self] old, new in
            guard let self else { return }
            // Only a real loss or return of the connection is worth a message. The kind of link and the metered flag change often and
            // quietly on a phone, so they are never announced; they are shown in the Network tab.
            if old.online && !new.online { self.noteConnection(online: false) }
            else if !old.online && new.online { self.noteConnection(online: true) }
        }
    }

    /// Waits a moment before speaking, so a connection that flickers (a lift, a Wi-Fi handover) says nothing, and says each thing at most once a minute.
    private func noteConnection(online: Bool) {
        connectionNoteTask?.cancel()
        connectionNoteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(online ? 3 : 4))
            guard let self, !Task.isCancelled, NetworkConditions.shared.info.online == online else { return }
            guard Date().timeIntervalSince(self.lastConnectionNote) > 60 else { return }
            self.lastConnectionNote = Date()
            self.notice = online ? "Back online." : "You are offline. Pages load again when the connection is back."
        }
    }
}
