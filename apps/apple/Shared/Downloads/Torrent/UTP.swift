import Foundation

// MARK: µTP (BEP 29): packets, one connection's state machine, delay-based congestion control
//
// A µTP connection is an ordered, reliable byte stream over UDP datagrams. This file is pure: no sockets, no timers of its own. The caller feeds it datagrams and the passage of time, and takes
// what it wants sent through closures. That is what lets loss and reordering be tested exactly, and lets the same state machine run over a connected socket (outgoing) or a listener (incoming).

enum UTP {
    static let version: UInt8 = 1
    static let headerSize = 20
    static let maxDatagram = 1500
    /// Payload bytes in one data packet: small enough to fit a typical path MTU with IP, UDP and µTP headers.
    static let payloadSize = 1000

    enum PacketType: UInt8 { case data = 0, fin = 1, state = 2, reset = 3, syn = 4 }

    struct Packet: Equatable {
        var type: PacketType
        var connectionID: UInt16
        var timestamp: UInt32
        var timestampDifference: UInt32
        var window: UInt32
        var seq: UInt16
        var ack: UInt16
        /// Selective ACK bitmask (extension 1): bit i of byte j says whether packet `ack + 2 + 8j + i` arrived.
        var sack: Data?
        var payload: Data = Data()
    }

    static func encode(_ p: Packet) -> Data {
        var d = Data()
        d.append(p.type.rawValue << 4 | version)
        d.append(p.sack == nil ? 0 : 1)
        d.appendBE(p.connectionID); d.appendBE(p.timestamp); d.appendBE(p.timestampDifference); d.appendBE(p.window); d.appendBE(p.seq); d.appendBE(p.ack)
        if let sack = p.sack { d.append(0); d.append(UInt8(sack.count)); d.append(sack) }
        d.append(p.payload)
        return d
    }

    /// nil for anything that is not a well-formed µTP packet: too short or long, another version, an unknown type, a broken extension chain, a selective ACK whose length is not a multiple of four,
    /// or a payload on a packet that carries none. Unknown extensions are skipped by their length, as the specification says.
    static func parse(_ data: Data) -> Packet? {
        guard data.count >= headerSize, data.count <= maxDatagram else { return nil }
        let b = [UInt8](data)
        guard b[0] & 0x0F == version, let type = PacketType(rawValue: b[0] >> 4) else { return nil }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
        var ext = b[1], offset = headerSize, sack: Data?, seen = 0
        while ext != 0 {
            seen += 1
            guard seen <= 4, offset + 2 <= b.count else { return nil }
            let next = b[offset], length = Int(b[offset + 1])
            offset += 2
            guard offset + length <= b.count else { return nil }
            if ext == 1 {
                guard length >= 4, length % 4 == 0, length <= 64, sack == nil else { return nil }
                sack = Data(b[offset..<(offset + length)])
            }
            ext = next; offset += length
        }
        let payload = Data(b[offset...])
        guard type == .data || payload.isEmpty else { return nil }
        return Packet(type: type, connectionID: u16(2), timestamp: u32(4), timestampDifference: u32(8), window: u32(12), seq: u16(16), ack: u16(18), sack: sack, payload: payload)
    }

    /// Sequence-number order with wrap-around: `a` comes before `b` if `b` is up to half the range ahead.
    static func before(_ a: UInt16, _ b: UInt16) -> Bool { a != b && (b &- a) < 0x8000 }
}

enum UTPFailure: Error, Equatable, LocalizedError {
    case timeout, reset, protocolViolation(String), closed
    var errorDescription: String? {
        switch self {
        case .timeout: "The peer did not answer."
        case .reset: "The peer reset the connection."
        case .protocolViolation(let why): "The peer broke the µTP protocol (\(why))."
        case .closed: "The connection was closed."
        }
    }
}

final class UTPConnection {
    enum State: Equatable { case idle, synSent, connected, finSent, lingering, closed }

    struct Tuning {
        var targetDelay: UInt32 = 100_000                 // µs: BEP 29's CCONTROL_TARGET
        var maxIncreasePerRTT = 3000.0                    // bytes
        var minWindow = 2 * UTP.payloadSize
        var maxWindow = 1 << 20
        var initialWindow = 4 * UTP.payloadSize
        var receiveLimit = 256 * 1024                     // bytes the peer may have in flight to us
        var maxReorder = 64                               // packets held out of order
        var maxSendQueue = 4 * 1024 * 1024
        var maxOutstanding = 512
        var minRTO: TimeInterval = 0.5, maxRTO: TimeInterval = 30
        var synAttempts = 4, dataAttempts = 6
        var idleTimeout: TimeInterval = 180
        var baseDelayWindow: TimeInterval = 120
    }

    // Outputs.
    var sendDatagram: (Data) -> Void = { _ in }
    var onData: (Data) -> Void = { _ in }
    var onConnected: () -> Void = {}
    var onClosed: (UTPFailure?) -> Void = { _ in }
    /// How many bytes the reader has been handed and not yet consumed: counted against the window we advertise (backpressure).
    var unreadBytes: () -> Int = { 0 }

    private(set) var state: State = .idle
    let tuning: Tuning
    private let clock: () -> UInt64               // microseconds, monotonic
    private var recvID: UInt16 = 0, sendID: UInt16 = 0
    private var seqNr: UInt16 = 1, ackNr: UInt16 = 0

    private struct Out { var seq: UInt16; var type: UTP.PacketType; var payload: Data; var sentAt: UInt64; var transmissions: Int; var sacked = false }
    private var outstanding: [Out] = []
    private var sendQueue: [Data] = []
    private var queuedBytes = 0
    private var wantFin = false
    private var inFlight = 0
    private var maxWindow: Double
    private var peerWindow = UInt32(UTP.payloadSize * 4)
    private var replyMicro: UInt32 = 0
    private var reorder: [UInt16: Data] = [:], reorderBytes = 0
    private var finSeq: UInt16?
    private var gotFin = false
    private var lastReceive: UInt64
    private var srtt: Double?, rttVar = 0.0, rto: TimeInterval = 1
    private var baseDelays: [(at: UInt64, value: UInt32)] = []
    private var lastAck: UInt16 = 0, duplicateAcks = 0
    private var lastLossAt: UInt64 = 0
    private var lastProbeAt: UInt64 = 0, lingerUntil: UInt64 = 0, notified = false
    private var peerFinished = false, finAckedAt: UInt64?
    private(set) var retransmissions = 0, packetsSent = 0
    var congestionWindow: Int { Int(maxWindow) }
    var bytesInFlight: Int { inFlight }
    var smoothedRTT: TimeInterval? { srtt }

    init(tuning: Tuning = Tuning(), clock: @escaping () -> UInt64) {
        self.tuning = tuning; self.clock = clock
        maxWindow = Double(tuning.initialWindow); lastReceive = clock()
    }

    // MARK: Opening

    /// Outgoing: a SYN carrying our receive id; the peer answers with a STATE.
    func connect(id: UInt16 = UInt16.random(in: 1...0xFFFE)) {
        guard state == .idle else { return }
        recvID = id; sendID = id &+ 1; seqNr = 1
        state = .synSent
        transmit(.syn, payload: Data(), id: recvID)
    }

    /// Incoming: a SYN whose connection id is `syn.connectionID`; our receive id is one more, our send id is that id.
    func accept(_ syn: UTP.Packet, seq: UInt16 = UInt16.random(in: 1...0xFFFE)) {
        guard state == .idle, syn.type == .syn else { return }
        recvID = syn.connectionID &+ 1; sendID = syn.connectionID
        seqNr = seq; ackNr = syn.seq
        state = .connected
        peerWindow = syn.window
        replyMicro = UInt32(truncatingIfNeeded: clock()) &- syn.timestamp
        sendState()
        onConnected()
    }

    // MARK: Writing

    /// Queues bytes to send. false if the queue is full (the caller holds the bytes back).
    @discardableResult
    func write(_ data: Data) -> Bool {
        guard state == .connected || state == .synSent, !wantFin, !data.isEmpty else { return false }
        guard queuedBytes + data.count <= tuning.maxSendQueue else { return false }
        sendQueue.append(data); queuedBytes += data.count
        pump()
        return true
    }

    var queuedForSending: Int { queuedBytes }

    /// A graceful close: what is queued is sent, then a FIN.
    func close() {
        guard state == .connected || state == .synSent else { return }
        wantFin = true
        pump()
    }

    /// Ends the connection at once, telling the peer.
    func reset() {
        guard state != .closed else { return }
        send(make(.reset))
        finish(nil)
    }

    private func make(_ type: UTP.PacketType, seq: UInt16? = nil) -> UTP.Packet {
        UTP.Packet(type: type, connectionID: sendID, timestamp: UInt32(truncatingIfNeeded: clock()), timestampDifference: replyMicro, window: advertisedWindow, seq: seq ?? seqNr, ack: ackNr)
    }

    private var advertisedWindow: UInt32 { UInt32(max(0, tuning.receiveLimit - reorderBytes - unreadBytes())) }

    private func send(_ p: UTP.Packet) { packetsSent += 1; sendDatagram(UTP.encode(p)) }

    private func transmit(_ type: UTP.PacketType, payload: Data, id: UInt16? = nil) {
        var p = make(type, seq: seqNr)
        if let id { p.connectionID = id }
        p.payload = payload
        send(p)
        outstanding.append(Out(seq: seqNr, type: type, payload: payload, sentAt: clock(), transmissions: 1))
        inFlight += payload.count
        seqNr &+= 1
    }

    private func sendState() {
        var p = make(.state)
        if !reorder.isEmpty { p.sack = selectiveAck() }
        send(p)
    }

    private func selectiveAck() -> Data {
        var bytes = [UInt8](repeating: 0, count: 4)
        for (seq, _) in reorder {
            let distance = Int(seq &- ackNr) - 2          // packet ack+2 is bit 0
            guard distance >= 0, distance < bytes.count * 8 else { continue }
            bytes[distance / 8] |= 1 << UInt8(distance % 8)
        }
        return Data(bytes)
    }

    // MARK: Sending data under the window

    private func pump() {
        guard state == .connected else { return }
        while !sendQueue.isEmpty, outstanding.count < tuning.maxOutstanding {
            let limit = min(Int(maxWindow), Int(peerWindow))
            let size = min(UTP.payloadSize, sendQueue[0].count)
            if limit < UTP.payloadSize {
                // The peer's window is (nearly) closed: nothing is sent except one small probe a second, so the peer can say when it has room again.
                let now = clock()
                guard inFlight == 0, now &- lastProbeAt >= 1_000_000 else { break }
                lastProbeAt = now
            } else {
                guard inFlight + size <= limit else { break }
            }
            var first = sendQueue[0]
            let chunk = first.prefix(UTP.payloadSize)
            first.removeFirst(chunk.count)
            if first.isEmpty { sendQueue.removeFirst() } else { sendQueue[0] = first }
            queuedBytes -= chunk.count
            transmit(.data, payload: Data(chunk))
        }
        if wantFin, sendQueue.isEmpty, state == .connected {
            transmit(.fin, payload: Data())
            state = .finSent
        }
    }

    // MARK: Receiving

    func receive(_ datagram: Data) {
        guard state != .closed, let p = UTP.parse(datagram) else { return }
        // A SYN again (our STATE was lost): the initiator's SYN carries the id we send with, and is answered again.
        if p.type == .syn, p.connectionID == sendID, state == .connected || state == .lingering { sendState(); return }
        guard p.connectionID == recvID, p.type != .syn else { return }          // not for this connection
        if state == .lingering {
            // Our side is done; the peer may still be finishing. A FIN we have not yet answered is acknowledged, anything else is ignored.
            if p.type == .reset { state = .closed } else if p.type == .fin, p.seq == ackNr &+ 1 { ackNr = p.seq; sendState() } else if p.type == .fin || p.type == .data { sendState() }
            return
        }
        let now = clock()
        lastReceive = now
        peerWindow = p.window
        replyMicro = UInt32(truncatingIfNeeded: now) &- p.timestamp

        switch p.type {
        case .reset: finish(.reset); return
        case .syn: sendState(); return                                  // our STATE was lost: say it again
        case .state:
            if state == .synSent {
                ackNr = p.seq &- 1                                       // a STATE does not use up a sequence number
                outstanding.removeAll { $0.type == .syn }
                state = .connected
                onConnected()
            }
        case .data, .fin:
            if state == .synSent { return }
        }
        processAcks(p, now: now)
        if p.type == .data || p.type == .fin { receivedSequenced(p) }
        if state == .finSent, outstanding.isEmpty { linger(); return }
        pump()
    }

    private func receivedSequenced(_ p: UTP.Packet) {
        let expected = ackNr &+ 1
        if p.seq == expected {
            deliver(p)
            while let next = reorder.removeValue(forKey: ackNr &+ 1) { reorderBytes -= next.count; deliverBuffered(next) }
        } else if UTP.before(expected, p.seq), Int(p.seq &- expected) < tuning.maxReorder, reorder[p.seq] == nil {
            if p.type == .data, reorderBytes + p.payload.count <= tuning.receiveLimit { reorder[p.seq] = p.payload; reorderBytes += p.payload.count }
            else if p.type == .fin { finSeq = p.seq }
        }
        // Anything else is old (already delivered) or too far ahead: not stored, but answered so the sender learns what we have.
        if let fin = finSeq, ackNr &+ 1 == fin { ackNr = fin; gotFin = true; finSeq = nil }
        sendState()
        if gotFin { gotFin = false; finishAfterFin() }
    }

    private func deliver(_ p: UTP.Packet) {
        ackNr = p.seq
        if p.type == .data { onData(p.payload) } else { gotFin = true }
    }
    private func deliverBuffered(_ payload: Data) { ackNr &+= 1; onData(payload) }

    private func finishAfterFin() {
        // The peer has no more to send. Ours is sent and acknowledged before the connection is called closed.
        if state == .connected { wantFin = true; pump() }
        if state != .finSent || outstanding.isEmpty { linger() }
    }

    // MARK: Acknowledgements and congestion

    private func processAcks(_ p: UTP.Packet, now: UInt64) {
        var bytesAcked = 0
        var sackedAfter = 0
        func release(_ o: Out, rttSample: Bool) {
            inFlight -= o.payload.count; bytesAcked += o.payload.count
            if rttSample, o.transmissions == 1 { updateRTT(Double(now &- o.sentAt) / 1_000_000) }
        }
        outstanding.removeAll { o in
            if o.type == .syn { return false }
            if p.ack == o.seq || UTP.before(o.seq, p.ack) { release(o, rttSample: true); return true }
            return false
        }
        if let sack = p.sack {
            let bytes = [UInt8](sack)
            for i in outstanding.indices {
                let d = Int(outstanding[i].seq &- p.ack) - 2
                if d >= 0, d < bytes.count * 8, bytes[d / 8] & (1 << UInt8(d % 8)) != 0, !outstanding[i].sacked { outstanding[i].sacked = true; release(outstanding[i], rttSample: false); outstanding[i].payload = Data() }
            }
            sackedAfter = outstanding.filter(\.sacked).count
        }
        // Delay-based window control.
        if p.timestampDifference != 0 { sampleDelay(p.timestampDifference, now: now) }
        if bytesAcked > 0, let base = baseDelay, p.timestampDifference != 0 {
            let queueDelay = Double(p.timestampDifference &- base)
            let offTarget = (Double(tuning.targetDelay) - queueDelay) / Double(tuning.targetDelay)
            let windowFactor = Double(bytesAcked) / max(maxWindow, Double(inFlight + bytesAcked))
            maxWindow += tuning.maxIncreasePerRTT * offTarget * windowFactor
            maxWindow = min(max(maxWindow, Double(tuning.minWindow)), Double(tuning.maxWindow))
        }
        // Loss: three packets known to be later than the oldest unacknowledged one, or three repeats of the same acknowledgement.
        if p.ack == lastAck, bytesAcked == 0, p.type == .state, !outstanding.isEmpty { duplicateAcks += 1 } else { duplicateAcks = 0; lastAck = p.ack }
        if (sackedAfter >= 3 || duplicateAcks >= 3), let oldest = outstanding.firstIndex(where: { !$0.sacked }) {
            duplicateAcks = 0
            // Once per round trip for a packet: the repeated acknowledgements that follow the resend are not new evidence of loss.
            let o = outstanding[oldest]
            if o.transmissions == 1 || Double(now &- o.sentAt) / 1_000_000 >= 2 * (srtt ?? rto) {
                retransmit(oldest, now: now)
                reduceWindow(now: now)
            }
        }
    }

    private func reduceWindow(now: UInt64) {
        guard now &- lastLossAt > UInt64((srtt ?? 0.5) * 1_000_000) else { return }          // once per round trip
        lastLossAt = now
        maxWindow = max(maxWindow / 2, Double(tuning.minWindow))
    }

    private func updateRTT(_ sample: Double) {
        if let s = srtt { rttVar += (abs(s - sample) - rttVar) / 4; srtt = s + (sample - s) / 8 } else { srtt = sample; rttVar = sample / 2 }
        rto = min(max((srtt ?? sample) + rttVar * 4, tuning.minRTO), tuning.maxRTO)
    }

    private var baseDelay: UInt32? { baseDelays.map(\.value).min() }
    private func sampleDelay(_ delay: UInt32, now: UInt64) {
        let window = UInt64(tuning.baseDelayWindow * 1_000_000)
        baseDelays.removeAll { now &- $0.at > window }
        baseDelays.append((now, delay))
        if baseDelays.count > 64 { baseDelays.removeFirst(baseDelays.count - 64) }
    }

    private func retransmit(_ index: Int, now: UInt64) {
        guard outstanding.indices.contains(index) else { return }
        let o = outstanding[index]
        var p = make(o.type, seq: o.seq)
        if o.type == .syn { p.connectionID = recvID }
        p.payload = o.payload
        send(p)
        outstanding[index].sentAt = now; outstanding[index].transmissions += 1
        retransmissions += 1
    }

    // MARK: Time

    /// Called now and then (every few tens of milliseconds): resends what has waited too long, gives up on a peer that has said nothing for good, and sends more if the window allows.
    func tick() {
        guard state != .closed else { return }
        let now = clock()
        if state == .lingering { if now >= lingerUntil { state = .closed }; return }
        if let i = outstanding.firstIndex(where: { !$0.sacked }) {
            let o = outstanding[i]
            let limit = o.type == .syn ? tuning.synAttempts : tuning.dataAttempts
            let wait = o.type == .syn ? min(pow(2, Double(o.transmissions - 1)), 8) : rto * pow(2, Double(min(o.transmissions - 1, 4)))
            if Double(now &- o.sentAt) / 1_000_000 >= wait {
                if o.transmissions >= limit { finish(.timeout); return }
                retransmit(i, now: now)
                if o.type != .syn { maxWindow = Double(tuning.minWindow); rto = min(rto * 2, tuning.maxRTO) }          // a timeout: back right off
            }
        }
        if Double(now &- lastReceive) / 1_000_000 > tuning.idleTimeout, state != .synSent { finish(.timeout); return }
        pump()
    }

    /// Both directions are finished and acknowledged: the reader is told the stream has ended, and the connection stays able to acknowledge a retransmitted FIN for a few seconds before it is gone.
    private func linger() {
        guard state != .closed, state != .lingering else { return }
        state = .lingering; lingerUntil = clock() + 3_000_000
        outstanding = []; sendQueue = []; reorder = [:]; queuedBytes = 0; inFlight = 0; reorderBytes = 0
        if !notified { notified = true; onClosed(nil) }
    }

    private func finish(_ failure: UTPFailure?) {
        guard state != .closed else { return }
        state = .closed
        outstanding = []; sendQueue = []; reorder = [:]; queuedBytes = 0; inFlight = 0; reorderBytes = 0
        if !notified { notified = true; onClosed(failure) }
    }
}
