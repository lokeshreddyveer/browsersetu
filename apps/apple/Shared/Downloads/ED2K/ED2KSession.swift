import Foundation

/// Peer and server connection counts for eD2k, kept apart from HTTP connections and from BitTorrent peers: a different protocol, a different limit.
enum ED2KBudget {
    static let peers: PeerBudget = { let b = PeerBudget(); b.setLimit(40); return b }()
    static let servers: PeerBudget = { let b = PeerBudget(); b.setLimit(2); return b }()
}

/// Everything one eD2k download does on the network: ask the servers the person configured for sources, connect out to those sources, request the file part by part, check each part, write it.
///
/// Outgoing connections only. A source that is "LowID" (it cannot be reached directly; a server would have to relay a callback to a port this app does not open) is counted and left alone.
/// Not supported: obfuscation, secure identification, compressed parts, Kad, and the queue beyond a bounded wait. The conversation follows the layouts in `ED2KWire`.
final class ED2KSession: @unchecked Sendable {
    enum Event {
        case progress(completedBytes: Int64, totalBytes: Int64)
        case verifiedPart(index: Int, md4: String)
        case hashset([Data])
        case finished
        case failed(String, retryable: Bool)
    }

    struct Settings: Sendable {
        var maxPeers = 8
        var requestDepth = 3
        var requestTimeout: TimeInterval = 40
        var handshakeTimeout: TimeInterval = 15
        var idleTimeout: TimeInterval = 100
        var queueWait: TimeInterval = 60
        var serverTimeout: TimeInterval = 20
        var rediscoverEvery: TimeInterval = 600
        var maxHashFailuresPerPeer = 2
        var allowLocalPeers = false
        var nickname = "BrowserSetu"
    }

    struct Snapshot: Sendable {
        var sources = 0, connected = 0, queued = 0, sending = 0, lowID = 0
        var verifiedParts = 0, totalParts = 0
        var downloaded: Int64 = 0
        var downRate = 0.0
        var servers: [String: String] = [:]
        var availability = 0
        var recoveryNote: String?
    }

    let file: ED2KLink.File
    let userHash: Data
    private let servers: [PeerAddress]
    private let storage: () -> ED2KStorage?
    private let transports: PeerTransportFactory
    private let down: BandwidthController?
    private let taskID: UUID
    private let settings: Settings
    let queue: DispatchQueue
    private let io = DispatchQueue(label: "browsersetu.ed2k.io", qos: .utility)
    var onEvent: ((Event) -> Void)?

    private enum Stage { case connecting, hello, fileInfo, hashset, queued, ready }
    private final class Peer {
        let id: Int; let address: PeerAddress; let transport: PeerTransport
        var stage = Stage.connecting
        var parser = ED2KWire.Parser()
        var startedAt: TimeInterval, lastReceived: TimeInterval, stageAt: TimeInterval
        var outstanding: [ED2KPartPicker.Request] = []
        var gotName = false, gotStatus = false
        var closed = false, hashFailures = 0
        init(id: Int, address: PeerAddress, transport: PeerTransport, now: TimeInterval) { self.id = id; self.address = address; self.transport = transport; startedAt = now; lastReceived = now; stageAt = now }
    }
    private final class ServerLink {
        let address: PeerAddress; let transport: PeerTransport
        var parser = ED2KWire.Parser(); var startedAt: TimeInterval; var sentSources = false; var closed = false
        init(address: PeerAddress, transport: PeerTransport, now: TimeInterval) { self.address = address; self.transport = transport; startedAt = now }
    }

    private var peers: [Int: Peer] = [:]
    private var nextID = 1
    private var candidates: [PeerAddress] = []
    private var known = Set<PeerAddress>()
    private var tried: [PeerAddress: Int] = [:]
    private var banned = Set<PeerAddress>()
    private var lowIDSeen = 0
    private var picker: ED2KPartPicker?
    private var partHashes: [Data]?
    private var running = false, finishing = false
    private var timer: DispatchSourceTimer?
    private var link: ServerLink?
    private var nextServer = 0
    private var lastDiscovery: TimeInterval = -.infinity
    private var serverState: [String: String] = [:]
    private var downloaded: Int64 = 0
    private var rateMark: (at: TimeInterval, bytes: Int64)?
    private var downRate = 0.0
    private var recoveryNote: String?
    private var lastProgress: Int64 = -1

    init(file: ED2KLink.File, servers: [PeerAddress], extraSources: [PeerAddress], storage: @escaping () -> ED2KStorage?, alreadyHave: Set<Int>, transports: PeerTransportFactory,
         download: BandwidthController?, taskID: UUID, settings: Settings = Settings(), queue: DispatchQueue = DispatchQueue(label: "browsersetu.ed2k.session")) {
        self.file = file; self.servers = servers; self.storage = storage; self.transports = transports; down = download; self.taskID = taskID; self.settings = settings; self.queue = queue
        userHash = ED2KWire.newUserHash()
        partHashes = file.partHashes ?? ED2KHash.singlePartHashes(fileHash: file.hash, size: file.size)
        picker = ED2KPartPicker(size: file.size, alreadyHave: alreadyHave)
        // A link can list many sources; only a few are used, so a link cannot make the app contact dozens of addresses.
        for s in file.sources.prefix(8).map({ PeerAddress(host: $0.host, port: $0.port) }) + extraSources { addCandidate(s) }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Lifecycle

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            reportProgress(force: true)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.2, repeating: 1.0, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t; t.resume()
            if picker?.isComplete == true { finalCheck(); return }
            tick()
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            running = false
            timer?.cancel(); timer = nil
            for p in Array(peers.values) { drop(p) }
            closeServer()
            io.async { completion?() }
        }
    }

    var snapshot: Snapshot {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            var s = Snapshot()
            s.sources = known.count; s.connected = peers.values.filter { $0.stage != .connecting && $0.stage != .hello }.count
            s.queued = peers.values.filter { $0.stage == .queued }.count; s.sending = peers.values.filter { !$0.outstanding.isEmpty }.count; s.lowID = lowIDSeen
            s.verifiedParts = picker?.verifiedParts ?? 0; s.totalParts = picker?.partCount ?? 0; s.downloaded = downloaded; s.downRate = downRate; s.servers = serverState
            s.availability = picker?.sourcesWithParts ?? 0; s.recoveryNote = recoveryNote
            return s
        }
    }

    // MARK: Ticking

    private func tick() {
        guard running, !finishing else { return }
        let t = now()
        if let m = rateMark, t - m.at >= 1 { downRate = 0.6 * downRate + 0.4 * Double(downloaded - m.bytes) / (t - m.at); rateMark = (t, downloaded) } else if rateMark == nil { rateMark = (t, downloaded) }
        for p in Array(peers.values) {
            switch p.stage {
            case .connecting, .hello, .fileInfo, .hashset: if t - p.stageAt > settings.handshakeTimeout { drop(p, retry: true); continue }
            case .queued: if t - p.stageAt > settings.queueWait { drop(p); continue }
            case .ready: break
            }
            if t - p.lastReceived > settings.idleTimeout { drop(p, retry: true) }
        }
        picker?.expire(olderThan: settings.requestTimeout, now: t).forEach { if let p = peers[$0] { drop(p, retry: true) } }
        if let l = link, t - l.startedAt > settings.serverTimeout { serverState[l.address.host] = "no answer"; closeServer() }
        discoverIfDue(t)
        connectMore()
    }

    // MARK: Sources

    private func addCandidate(_ a: PeerAddress) {
        guard candidates.count < 300, a.port != 0, !banned.contains(a), !known.contains(a) else { return }
        if !settings.allowLocalPeers {
            let o = a.host.split(separator: ".").compactMap { UInt8($0) }
            guard o.count == 4, !ED2KLink.isInternal(o) else { return }
        }
        known.insert(a); candidates.append(a)
    }

    private func discoverIfDue(_ t: TimeInterval) {
        guard link == nil, !servers.isEmpty, t - lastDiscovery >= (nextServer == 0 ? settings.rediscoverEvery : 1), picker?.isComplete == false else { return }
        guard ED2KBudget.servers.acquire(task: taskID) else { return }
        let address = servers[nextServer % servers.count]
        nextServer = (nextServer + 1) % servers.count
        if nextServer == 0 { lastDiscovery = t }
        let l = ServerLink(address: address, transport: transports.make(address, queue: queue), now: t)
        link = l
        serverState[address.host] = "connecting"
        l.transport.connect { [weak self, weak l] error in
            guard let self, let l else { return }
            self.queue.async {
                guard !l.closed, self.link === l else { return }
                if let error { self.serverState[l.address.host] = "unreachable (\(error.localizedDescription.prefix(40)))"; self.closeServer(); return }
                l.transport.send(ED2KWire.encode(ED2KWire.loginRequest(userHash: self.userHash, nickname: self.settings.nickname)))
                self.serverState[l.address.host] = "logging in"
                self.readServer(l)
            }
        }
    }

    private func readServer(_ l: ServerLink) {
        l.transport.receive { [weak self, weak l] data, error in
            guard let self, let l else { return }
            self.queue.async {
                guard !l.closed, self.running, self.link === l else { return }
                guard let data, error == nil else { if l.sentSources == false { self.serverState[l.address.host] = "closed" }; self.closeServer(); return }
                do {
                    for packet in try l.parser.feed(data) {
                        guard packet.proto == ED2KWire.edonkey || packet.proto == ED2KWire.emule else { continue }
                        switch packet.opcode {
                        case ED2KWire.Op.idChange where !l.sentSources:
                            let id = try ED2KWire.parseIDChange(packet.payload)
                            self.serverState[l.address.host] = id.isLowID ? "logged in (low ID: some sources cannot be reached)" : "logged in"
                            l.sentSources = true
                            l.transport.send(ED2KWire.encode(ED2KWire.getSources(hash: self.file.hash, size: self.file.size)))
                        case ED2KWire.Op.foundSources:
                            let found = try ED2KWire.parseFoundSources(packet.payload)
                            guard found.hash == self.file.hash else { continue }
                            for s in found.sources { if s.isLowID { self.lowIDSeen += 1 } else { self.addCandidate(PeerAddress(host: s.host, port: s.port)) } }
                            self.serverState[l.address.host] = "\(found.sources.count) source\(found.sources.count == 1 ? "" : "s") reported"
                            self.closeServer(); self.connectMore(); return
                        case ED2KWire.Op.reject: self.serverState[l.address.host] = "refused the login"; self.closeServer(); return
                        default: break              // server messages, status and identity are not needed to ask for sources
                        }
                    }
                } catch { self.serverState[l.address.host] = "sent something invalid"; self.closeServer(); return }
                self.readServer(l)
            }
        }
    }

    private func closeServer() {
        guard let l = link else { return }
        l.closed = true; l.transport.close(); link = nil
        ED2KBudget.servers.release(task: taskID, count: 1)
    }

    // MARK: Peers

    private func connectMore() {
        guard running, !finishing, picker?.isComplete == false else { return }
        while peers.count < settings.maxPeers, !candidates.isEmpty, ED2KBudget.peers.acquire(task: taskID) {
            let a = candidates.removeFirst()
            tried[a, default: 0] += 1
            let p = Peer(id: nextID, address: a, transport: transports.make(a, queue: queue), now: now())
            nextID += 1; peers[p.id] = p
            p.transport.connect { [weak self, weak p] error in
                guard let self, let p else { return }
                self.queue.async {
                    guard !p.closed else { return }
                    if error != nil { self.drop(p, retry: true); return }
                    p.stage = .hello; p.stageAt = self.now()
                    p.transport.send(ED2KWire.encode(ED2KWire.hello(userHash: self.userHash, nickname: self.settings.nickname)))
                    self.readPeer(p)
                }
            }
        }
    }

    private func drop(_ p: Peer, retry: Bool = false) {
        guard !p.closed else { return }
        p.closed = true; p.transport.close()
        if peers.removeValue(forKey: p.id) != nil { ED2KBudget.peers.release(task: taskID, count: 1) }
        picker?.peerGone(p.id)
        if retry, !banned.contains(p.address), tried[p.address, default: 0] <= 2 { candidates.append(p.address) }
        if running { connectMore() }
    }

    private func readPeer(_ p: Peer) {
        guard running, !p.closed else { return }
        p.transport.receive { [weak self, weak p] data, error in
            guard let self, let p else { return }
            self.queue.async {
                guard !p.closed, self.running else { return }
                guard let data, error == nil else { self.drop(p, retry: p.stage == .connecting || p.stage == .hello); return }
                p.lastReceived = self.now()
                do { for packet in try p.parser.feed(data) { try self.handle(packet, from: p); if p.closed { return } } }
                catch { self.banned.insert(p.address); self.drop(p); return }
                // The next read waits for the speed limit: the connection backs up and the sender slows.
                let wait = self.down?.reserve(task: self.taskID, bytes: data.count) ?? 0
                if wait > 0.002 { self.queue.asyncAfter(deadline: .now() + wait) { [weak self, weak p] in if let self, let p { self.readPeer(p) } } } else { self.readPeer(p) }
            }
        }
    }

    private func send(_ packet: ED2KWire.Packet, to p: Peer) { guard !p.closed else { return }; p.transport.send(ED2KWire.encode(packet)) }

    private func handle(_ packet: ED2KWire.Packet, from p: Peer) throws {
        guard let picker else { return }
        let edonkey = packet.proto == ED2KWire.edonkey, extended = packet.proto == ED2KWire.emule
        switch (edonkey, extended, packet.opcode) {
        case (true, _, ED2KWire.Op.helloAnswer) where p.stage == .hello:
            _ = try ED2KWire.parseHello(packet.payload, isAnswer: true)
            p.stage = .fileInfo; p.stageAt = now()
            send(ED2KWire.requestFileName(file.hash), to: p); send(ED2KWire.setReqFileID(file.hash), to: p)
        case (true, _, ED2KWire.Op.reqFileNameAnswer) where p.stage == .fileInfo:
            let answer = try ED2KWire.parseFileNameAnswer(packet.payload)
            guard answer.hash == file.hash else { throw ED2KWire.Failure.badMessage("another file") }
            p.gotName = true
            if picker.partCount == 1 && !p.gotStatus { picker.peerHas(p.id, [true]); p.gotStatus = true }
            advanceFromFileInfo(p)
        case (true, _, ED2KWire.Op.fileStatus) where p.stage == .fileInfo:
            let status = try ED2KWire.parseFileStatus(packet.payload, expectedParts: picker.partCount)
            guard status.hash == file.hash else { throw ED2KWire.Failure.badMessage("another file") }
            picker.peerHas(p.id, status.have); p.gotStatus = true
            advanceFromFileInfo(p)
        case (true, _, ED2KWire.Op.fileNotFound):
            drop(p)                                   // this source does not have the file
        case (true, _, ED2KWire.Op.hashsetAnswer) where p.stage == .hashset:
            let answer = try ED2KWire.parseHashsetAnswer(packet.payload)
            guard answer.hash == file.hash, let valid = ED2KHash.validatedPartHashes(answer.parts, fileHash: file.hash, size: file.size) else { throw ED2KWire.Failure.badMessage("the hash list does not match the file") }
            let first = partHashes == nil
            partHashes = valid
            if first { onEvent?(.hashset(valid)) }
            send(ED2KWire.startUploadReq(file.hash), to: p); p.stage = .queued; p.stageAt = now()
        case (true, _, ED2KWire.Op.acceptUploadReq) where p.stage == .queued:
            p.stage = .ready; p.stageAt = now(); fill(p)
        case (true, _, ED2KWire.Op.queueRank), (_, true, ED2KWire.Op.queueRanking):
            break                                     // queued at the source: the wait is bounded by the tick
        case (true, _, ED2KWire.Op.outOfPartReqs), (true, _, ED2KWire.Op.cancelTransfer):
            drop(p, retry: true)
        case (_, true, ED2KWire.Op.compressedPart), (_, true, ED2KWire.Op.compressedPart64):
            throw ED2KWire.Failure.badMessage("compressed parts are not supported")        // never advertised, so a well-behaved peer does not send them
        case (true, _, ED2KWire.Op.sendingPart) where p.stage == .ready, (_, true, ED2KWire.Op.sendingPart64) where p.stage == .ready:
            let part = try ED2KWire.parseSendingPart(packet.payload, wide: extended)
            guard part.hash == file.hash else { throw ED2KWire.Failure.badMessage("another file") }
            p.outstanding.removeAll { $0.start == part.start && $0.end == part.end }
            switch picker.received(from: p.id, start: part.start, end: part.end, data: part.data) {
            case .unexpected: break                       // not counted: nobody asked for it
            case .accepted: downloaded += Int64(part.data.count)
            case .partComplete(let index, let data, let who): downloaded += Int64(part.data.count); verify(part: index, data: data, contributors: who)
            }
            if p.outstanding.isEmpty { fill(p) }
        default: break                                // eMule extension packets and anything not part of a download are ignored
        }
    }

    private func advanceFromFileInfo(_ p: Peer) {
        guard p.gotName, p.gotStatus, p.stage == .fileInfo, let picker else { return }
        if partHashes == nil { send(ED2KWire.hashsetRequest(file.hash), to: p); p.stage = .hashset }
        else { send(ED2KWire.startUploadReq(file.hash), to: p); p.stage = .queued }
        p.stageAt = now()
        _ = picker
    }

    private func fill(_ p: Peer) {
        guard running, !finishing, p.stage == .ready, p.outstanding.isEmpty, let picker, partHashes != nil else { return }
        var requests = picker.nextRequests(for: p.id, limit: settings.requestDepth, now: now())
        if let first = requests.first?.part {                       // one part per request, as eMule does
            let extra = requests.filter { $0.part != first }
            requests.removeAll { $0.part != first }
            picker.release(extra)                                     // asked of nobody after all: free to be asked of someone else
        }
        guard !requests.isEmpty else { return }
        p.outstanding = requests
        send(ED2KWire.requestParts(hash: file.hash, ranges: requests.map { ED2KWire.Range(start: $0.start, end: $0.end) }), to: p)
    }

    // MARK: Parts

    private func verify(part index: Int, data: Data, contributors: Set<Int>) {
        guard let storage = storage(), let hashes = partHashes, index < hashes.count else { picker?.partFailed(index, contributors: []); return }
        let expected = hashes[index]
        io.async { [self] in
            let ok = MD4.hash(data) == expected
            var failure: String?
            if ok { do { try storage.write(part: index, data: data) } catch { failure = (error as? LocalizedError)?.errorDescription ?? "The file could not be written." } }
            queue.async { [self] in
                guard running, let picker else { return }
                if let failure { fail(failure, retryable: false); return }
                if ok {
                    picker.partVerified(index)
                    onEvent?(.verifiedPart(index: index, md4: expected.hexString))
                    reportProgress(force: false)
                    if picker.isComplete { finalCheck() }
                } else {
                    picker.partFailed(index, contributors: contributors)
                    // Blame is only certain when one peer supplied the whole part; otherwise the part is retried from a single peer.
                    if contributors.count == 1, let id = contributors.first, let p = peers[id] { p.hashFailures += 1; if p.hashFailures >= settings.maxHashFailuresPerPeer { banned.insert(p.address); drop(p) } }
                    for p in peers.values { fill(p) }
                }
            }
        }
    }

    private func reportProgress(force: Bool) {
        guard let picker else { return }
        let done = picker.completedBytes
        guard force || done != lastProgress else { return }
        lastProgress = done
        onEvent?(.progress(completedBytes: done, totalBytes: file.size))
    }

    /// Every part is read back from disk and checked, and the file hash is worked out again from what is there. Only then is the download called finished.
    private func finalCheck() {
        guard !finishing, let storage = storage(), let hashes = partHashes else { return }
        finishing = true
        let parts = picker?.partCount ?? 0
        io.async { [self] in
            storage.sync()
            var bad: [Int] = []
            var actual: [Data] = []
            for i in 0..<parts { if let d = storage.read(part: i) { let h = MD4.hash(d); actual.append(h); if h != hashes[i] { bad.append(i) } } else { bad.append(i); actual.append(Data(count: 16)) } }
            let identity = ED2KHash.acceptableFileHashes(partHashes: actual, size: file.size).contains(file.hash)
            queue.async { [self] in
                guard running else { return }
                if bad.isEmpty, identity {
                    running = false; timer?.cancel(); timer = nil
                    for p in Array(peers.values) { drop(p) }
                    closeServer()
                    onEvent?(.finished); return
                }
                finishing = false
                recoveryNote = "\(max(bad.count, 1)) part\(bad.count == 1 ? "" : "s") failed the final check and are being fetched again"
                picker?.invalidate(bad.isEmpty ? Array(0..<parts) : bad)
                for p in peers.values { fill(p) }
                connectMore()
            }
        }
    }

    private func fail(_ message: String, retryable: Bool) {
        guard running || finishing else { return }
        running = false; timer?.cancel(); timer = nil
        for p in Array(peers.values) { drop(p) }
        closeServer()
        onEvent?(.failed(message, retryable: retryable))
    }
}
