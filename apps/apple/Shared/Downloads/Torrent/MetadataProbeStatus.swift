import Foundation

/// What a magnet link's details search is doing right now, for the person to see while they wait.
struct MetadataProbeStatus: Equatable, Sendable {
    var trackersTotal = 0, trackersAnswered = 0, trackersFailed = 0
    var peersConnected = 0, peersConnecting = 0
    var dhtOn = false
    var dhtNodes = 0, dhtPeers = 0
    var dhtState = ""
    var metadataProgress: Double?
    var elapsed: TimeInterval = 0

    init(dhtOn: Bool = false) { self.dhtOn = dhtOn }

    init(snapshot s: TorrentSession.Snapshot, elapsed: TimeInterval) {
        trackersTotal = s.trackerRows.count
        trackersAnswered = s.trackerRows.filter { $0.secondsSinceAnnounce != nil && $0.state != .error }.count
        trackersFailed = s.trackerRows.filter { $0.state == .error }.count
        peersConnected = s.peers; peersConnecting = s.connecting
        if let d = s.dht { dhtOn = d.state != .off; dhtNodes = d.nodes4 + d.nodes6; dhtState = d.state.rawValue }
        dhtPeers = s.dhtPeers
        metadataProgress = s.metadataProgress
        self.elapsed = elapsed
    }

    /// "2 of 3 trackers answered, 12 peers (4 connecting), DHT: 38 nodes, 5 peers found"
    var summary: String {
        var parts: [String] = []
        if trackersTotal > 0 { parts.append("\(trackersAnswered) of \(trackersTotal) tracker\(trackersTotal == 1 ? "" : "s") answered") }
        parts.append(peersConnected == 0 && peersConnecting == 0 ? "no peers yet" : "\(peersConnected) peer\(peersConnected == 1 ? "" : "s") connected" + (peersConnecting > 0 ? ", \(peersConnecting) connecting" : ""))
        if dhtOn { parts.append(dhtNodes > 0 ? "DHT: \(dhtNodes) nodes, \(dhtPeers) peer\(dhtPeers == 1 ? "" : "s") found" : "DHT: " + (dhtState.isEmpty ? "starting" : dhtState.lowercased())) }
        if let m = metadataProgress, m > 0 { parts.append("details \(Int(m * 100))%") }
        return parts.joined(separator: " · ")
    }
}
