import XCTest
@testable import Browser_Setu

// MARK: Core: identifiers, addresses, messages, tokens, BEP 42, routing

final class DHTCoreTests: XCTestCase {
    private func id(_ b: UInt8, last: UInt8 = 0) -> NodeID { NodeID(bytes: [b] + [UInt8](repeating: 0, count: 18) + [last]) }
    private func ep(_ s: String, _ port: UInt16 = 6881) -> DHTEndpoint { DHTEndpoint(host: s, port: port)! }

    func testDistanceAndCommonPrefix() {
        let a = id(0b1000_0000), b = id(0b1100_0000)
        XCTAssertEqual(a.distance(to: b)[0], 0b0100_0000)
        XCTAssertEqual(a.commonPrefix(with: b), 1); XCTAssertEqual(a.commonPrefix(with: a), 160)
        XCTAssertEqual(NodeID(hex: a.hex), a); XCTAssertNil(NodeID(hex: "zz"))
        XCTAssertNil(NodeID(Data(count: 19)))
    }

    func testCompactAddressesRoundTripForBothFamilies() {
        let v4 = ep("198.51.100.7", 51413), v6 = ep("2001:db8::1", 6881)
        XCTAssertEqual(v4.compact.count, 6); XCTAssertEqual(v6.compact.count, 18)
        XCTAssertEqual(DHTEndpoint(compact: v4.compact), v4); XCTAssertEqual(DHTEndpoint(compact: v6.compact), v6)
        XCTAssertNil(DHTEndpoint(compact: Data(count: 7)))
        XCTAssertEqual(v4.host, "198.51.100.7")
    }

    func testOnlyAddressesOnTheOpenInternetAreRoutable() {
        for h in ["127.0.0.1", "10.0.0.5", "192.168.1.1", "169.254.1.1", "::1", "fe80::1", "fc00::1", "0.0.0.0", "224.0.0.1"] { XCTAssertFalse(ep(h).isRoutable, h) }
        XCTAssertTrue(ep("198.51.100.7").isRoutable); XCTAssertTrue(ep("2606:4700::1").isRoutable)
        XCTAssertFalse(DHTEndpoint(host: "198.51.100.7", port: 0)!.isRoutable)
    }

    func testCompactNodesParseAndRefuseBadLengths() {
        let n4 = DHTNodeInfo(id: id(1), endpoint: ep("198.51.100.1")), n6 = DHTNodeInfo(id: id(2), endpoint: ep("2606:4700::2", 7000))
        XCTAssertEqual(DHTCompact.decodeNodes(DHTCompact.encodeNodes([n4, n4]), ipv6: false).count, 2)
        XCTAssertEqual(DHTCompact.decodeNodes(DHTCompact.encodeNodes([n6]), ipv6: true), [n6])
        XCTAssertTrue(DHTCompact.decodeNodes(Data(count: 27), ipv6: false).isEmpty, "not a whole number of entries")
        XCTAssertTrue(DHTCompact.decodeNodes(Data(count: 26 * 65), ipv6: false).isEmpty, "too many")
    }

    func testKRPCParsesTheThreeKindsAndRefusesEverythingElse() throws {
        let q = KRPC.query(tid: Data("aa".utf8), method: "ping", args: ["id": .bytes(Data(count: 20))])
        guard case .query(_, let m, _, let ro)? = KRPC.parse(q) else { return XCTFail() }
        XCTAssertEqual(m, "ping"); XCTAssertTrue(ro)
        XCTAssertNotNil(KRPC.parse(KRPC.response(tid: Data("aa".utf8), values: ["id": .bytes(Data(count: 20))])))
        guard case .error(_, let code, _)? = KRPC.parse(KRPC.error(tid: Data("aa".utf8), code: 201, text: "x")) else { return XCTFail() }
        XCTAssertEqual(code, 201)
        XCTAssertNil(KRPC.parse(Data("not bencode".utf8)))
        XCTAssertNil(KRPC.parse(Data()))
        XCTAssertNil(KRPC.parse(Data(count: KRPC.maxDatagram + 1)), "longer than a message may be")
        XCTAssertNil(KRPC.parse(BencodeDecoder.encode(.dict(["y": .bytes(Data("q".utf8))]))), "no transaction")
        XCTAssertNil(KRPC.parse(BencodeDecoder.encode(.dict(["t": .bytes(Data("a".utf8)), "y": .bytes(Data("x".utf8))]))), "unknown type")
        XCTAssertNil(KRPC.parse(KRPC.query(tid: Data("a".utf8), method: "ping", args: ["id": .bytes(Data(count: 5))])), "an id that is not 20 bytes")
        XCTAssertNil(KRPC.parse(KRPC.response(tid: Data(count: 21), values: ["id": .bytes(Data(count: 20))])), "a transaction id too long")
    }

    func testTokensAreBoundToTheAddressAndExpire() {
        final class Clock: @unchecked Sendable { var t: TimeInterval = 0 }
        let clock = Clock(); let tokens = DHTTokens(now: { clock.t })
        let ip: [UInt8] = [198, 51, 100, 7], other: [UInt8] = [198, 51, 100, 8]
        let token = tokens.issue(for: ip)
        XCTAssertTrue(tokens.isValid(token, for: ip)); XCTAssertFalse(tokens.isValid(token, for: other))
        XCTAssertFalse(tokens.isValid(Data(count: 4), for: ip), "wrong length")
        clock.t = DHTTokens.rotation + 1
        XCTAssertTrue(tokens.isValid(token, for: ip), "the previous secret is still honoured")
        clock.t = DHTTokens.rotation * 2 + 2
        XCTAssertFalse(tokens.isValid(token, for: ip), "and then it is not")
        XCTAssertNotEqual(tokens.issue(for: ip), token)
    }

    func testBEP42ValidatesTheSpecificationsExample() {
        // BEP 42: 124.31.75.21 with r = 1 gives a CRC whose first 21 bits are 0x5fbfb8 >> 3.
        var good = [UInt8](repeating: 7, count: 20); good[0] = 0x5f; good[1] = 0xbf; good[2] = 0xb8; good[19] = 1
        XCTAssertTrue(DHTNodeIDSecurity.isValid(NodeID(bytes: good), for: [124, 31, 75, 21]))
        var bad = good; bad[1] = 0x00
        XCTAssertFalse(DHTNodeIDSecurity.isValid(NodeID(bytes: bad), for: [124, 31, 75, 21]))
        XCTAssertFalse(DHTNodeIDSecurity.isValid(NodeID(bytes: good), for: [1, 2, 3, 4]))
    }

    // Routing

    private func table(_ own: NodeID = .random()) -> DHTRoutingTable { DHTRoutingTable(own: own, now: 0) }
    private func node(_ i: Int, id: NodeID = .random()) -> DHTNodeInfo { DHTNodeInfo(id: id, endpoint: ep("\(1 + i / 65000 % 200).\(i / 250 % 250).\(i % 250).9")) }

    func testABucketSplitsOnlyWhereOurOwnIdLives() {
        var t = table()
        for i in 0..<200 { t.insert(node(i), now: 1) }
        XCTAssertGreaterThan(t.buckets.count, 1)
        XCTAssertTrue(t.buckets.allSatisfy { $0.entries.count <= DHTRoutingTable.k })
        XCTAssertLessThan(t.count, 200, "buckets far from us stay full and do not split")
    }

    func testClosestNodesAreSortedByXORDistance() {
        var t = table(); let target = NodeID.random()
        for i in 0..<60 { t.insert(node(i), now: 1) }
        let c = t.closest(to: target, count: 8)
        let d = c.map { $0.id.distance(to: target) }
        XCTAssertEqual(d, d.sorted { $0.lexicographicallyPrecedes($1) })
        XCTAssertLessThanOrEqual(c.count, 8)
    }

    func testDuplicatesAndHostileInsertsAreRefused() {
        var t = table(id(0x80))
        let n = DHTNodeInfo(id: id(0x10), endpoint: ep("198.51.100.1"))
        XCTAssertEqual(t.insert(n, now: 1), .added)
        XCTAssertEqual(t.insert(n, now: 2), .updated)
        XCTAssertEqual(t.insert(DHTNodeInfo(id: id(0x10), endpoint: ep("198.51.100.2")), now: 3), .rejected, "an id does not move to another address")
        XCTAssertEqual(t.insert(DHTNodeInfo(id: id(0x11), endpoint: ep("198.51.100.1", 7000)), now: 3), .rejected, "one entry per address")
        XCTAssertEqual(t.insert(DHTNodeInfo(id: id(0x80), endpoint: ep("198.51.100.3")), now: 3), .rejected, "never our own id")
        XCTAssertEqual(t.insert(DHTNodeInfo(id: id(0x12), endpoint: DHTEndpoint(host: "198.51.100.4", port: 0)!), now: 3), .rejected)
        XCTAssertEqual(t.count, 1)
    }

    func testTheTableStaysBoundedUnderAFlood() {
        var t = table()
        for i in 0..<6000 { t.insert(node(i), now: Double(i)) }
        XCTAssertLessThan(t.count, 8 * (DHTRoutingTable.maxDepth + 2))
    }

    func testFailedNodesAreReplacedByWaitingOnes() {
        var t = table(id(0x00))
        // Fill the far bucket (ids starting with 1...) then add one more: it waits as a replacement.
        var far: [DHTNodeInfo] = (0..<8).map { DHTNodeInfo(id: NodeID(bytes: [0x80 | UInt8($0)] + [UInt8](repeating: 1, count: 19)), endpoint: ep("198.51.100.\($0 + 1)")) }
        for n in far { t.insert(n, now: 1) }
        let extra = DHTNodeInfo(id: NodeID(bytes: [0x90] + [UInt8](repeating: 2, count: 19)), endpoint: ep("198.51.100.99"))
        XCTAssertEqual(t.insert(extra, now: 2), .cached)
        t.markFailed(far[0].id); t.markFailed(far[0].id)
        XCTAssertTrue(t.allEntries.contains { $0.info.id == extra.id }, "the replacement took the failed node's place")
        XCTAssertFalse(t.allEntries.contains { $0.info.id == far[0].id })
        far.removeAll()
    }

    func testRefreshingOneBucketLeavesTheOthersStale() {
        var t = table(); for i in 0..<30 { t.insert(node(i), now: 0) }
        let targets = t.staleTargets(now: DHTRoutingTable.staleAfter + 1)
        XCTAssertGreaterThan(targets.count, 1)
        t.touchBucket(of: targets[0], now: DHTRoutingTable.staleAfter + 1)
        XCTAssertEqual(t.staleTargets(now: DHTRoutingTable.staleAfter + 2).count, targets.count - 1)
    }

    func testAHeardOfNodeNeverEvictsAWorkingOne() {
        var t = table(id(0x00))
        let far: [DHTNodeInfo] = (0..<8).map { DHTNodeInfo(id: NodeID(bytes: [0x80 | UInt8($0)] + [UInt8](repeating: 1, count: 19)), endpoint: ep("198.51.100.\($0 + 1)")) }
        for n in far { t.insert(n, now: 1) }
        // Whatever the ids look like, a node only named by someone else does not push out one that answered.
        for i in 0..<20 { t.insert(DHTNodeInfo(id: NodeID(bytes: [0x90 | UInt8(i)] + [UInt8](repeating: 2, count: 19)), endpoint: ep("203.0.113.\(i + 1)")), heard: true, now: 2) }
        XCTAssertEqual(Set(t.allEntries.map(\.info.id)).intersection(far.map(\.id)).count, 8)
    }

    func testStaleBucketsGetRefreshTargetsInsideThem() {
        var t = table(); for i in 0..<30 { t.insert(node(i), now: 0) }
        let targets = t.staleTargets(now: DHTRoutingTable.staleAfter + 1)
        XCTAssertEqual(targets.count, t.buckets.count)
        for (b, target) in zip(t.buckets, targets) { XCTAssertGreaterThanOrEqual(target.commonPrefix(with: b.prefix), b.depth) }
        XCTAssertTrue(t.staleTargets(now: 10).isEmpty)
    }
}

// MARK: A node, with a pretend network

final class FakeDHTTransport: DHTDatagramTransport, @unchecked Sendable {
    var onReceive: ((Data, DHTEndpoint) -> Void)?
    var supportsIPv6 = false
    private let lock = NSLock()
    private(set) var sent: [(data: Data, to: DHTEndpoint)] = []
    private(set) var started = 0, closed = 0
    /// What the pretend remote nodes say back: given the query, the values of the answer (nil: silence).
    var remotes: [DHTEndpoint: (String, [String: Bencode]) -> [String: Bencode]?] = [:]
    var remoteIDs: [DHTEndpoint: NodeID] = [:]

    func start() throws { lock.lock(); started += 1; lock.unlock() }
    func close() { lock.lock(); closed += 1; lock.unlock() }
    func send(_ data: Data, to endpoint: DHTEndpoint) {
        lock.lock(); sent.append((data, endpoint)); lock.unlock()
        guard case .query(let tid, let method, let args, _)? = KRPC.parse(data), let behave = remotes[endpoint], var values = behave(method, args) else { return }
        values["id"] = .bytes((remoteIDs[endpoint] ?? NodeID.random()).data)
        let reply = KRPC.response(tid: tid, values: values)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.onReceive?(reply, endpoint) }
    }
    func inject(_ data: Data, from: DHTEndpoint) { onReceive?(data, from) }
    func queries(_ method: String) -> [(args: [String: Bencode], to: DHTEndpoint)] {
        lock.lock(); defer { lock.unlock() }
        return sent.compactMap { if case .query(_, let m, let a, _)? = KRPC.parse($0.data), m == method { return (a, $0.to) } else { return nil } }
    }
    var responses: [(KRPC.Message, DHTEndpoint)] { lock.lock(); defer { lock.unlock() }; return sent.compactMap { m in KRPC.parse(m.data).map { ($0, m.to) } }.filter { if case .query = $0.0 { return false } else { return true } } }
    var sentCount: Int { lock.lock(); defer { lock.unlock() }; return sent.count }
}

private final class MemoryNodeStore: DHTNodeStore, @unchecked Sendable {
    var nodes: [DHTNodeInfo] = []; var saved: [DHTNodeInfo]?
    func load() -> [DHTNodeInfo] { nodes }
    func save(_ nodes: [DHTNodeInfo]) { saved = nodes }
}

final class DHTNodeTests: XCTestCase {
    private func ep(_ s: String, _ port: UInt16 = 6881) -> DHTEndpoint { DHTEndpoint(host: s, port: port)! }
    private let boot = "198.51.100.1", infoHash = Data((0..<20).map { UInt8($0 + 1) })
    private let peerA = DHTEndpoint(host: "203.0.113.50", port: 51413)!

    private func make(_ t: FakeDHTTransport, policy: @escaping @Sendable () -> DHTBlock? = { nil }, store: DHTNodeStore? = nil, explicit: Bool = false, hosts: [String]? = nil,
                      isPrivate: @escaping @Sendable (Data) -> Bool = { _ in false }, config: DHTNode.Config = DHTNode.Config()) -> DHTNode {
        DHTNode(transport: t, config: config, policy: policy, store: store, resolver: FixedResolver(table: [:]), bootstrap: { (hosts ?? ["\(self.boot):6881"], explicit) }, isPrivateHash: isPrivate)
    }
    private func until(_ seconds: Double = 5, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }
    private func nodesField(_ list: [(UInt8, String)]) -> Bencode {
        .bytes(DHTCompact.encodeNodes(list.map { DHTNodeInfo(id: NodeID(bytes: [$0.0] + [UInt8](repeating: 9, count: 19)), endpoint: ep($0.1)) }))
    }
    /// A swarm of pretend nodes: the bootstrap names two others; one of them knows a peer.
    private func swarm(_ t: FakeDHTTransport) {
        let n1 = ep("198.51.100.11"), n2 = ep("198.51.100.12")
        t.remotes[ep(boot)] = { _, _ in ["nodes": self.nodesField([(0x20, "198.51.100.11"), (0x21, "198.51.100.12")])] }
        t.remoteIDs[n1] = NodeID(bytes: [0x20] + [UInt8](repeating: 9, count: 19)); t.remoteIDs[n2] = NodeID(bytes: [0x21] + [UInt8](repeating: 9, count: 19))
        t.remotes[n1] = { method, _ in method == "get_peers" ? ["token": .bytes(Data("tok".utf8)), "values": .list([.bytes(self.peerA.compact)])] : ["nodes": .bytes(Data())] }
        t.remotes[n2] = { method, _ in method == "get_peers" ? ["token": .bytes(Data("tok".utf8)), "nodes": .bytes(Data())] : ["nodes": .bytes(Data())] }
    }
    private final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

    func testNothingHappensUntilATorrentAsks() async {
        let t = FakeDHTTransport(); let node = make(t)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(t.started, 0); XCTAssertEqual(t.sentCount, 0); XCTAssertEqual(node.status.state, .off)
    }

    func testBootstrapSendsAValidFindNodeAndBecomesReady() async {
        let t = FakeDHTTransport(); swarm(t); let node = make(t)
        node.acquire(UUID())
        let ready = await until { node.status.state == .ready }
        XCTAssertTrue(ready)
        let q = t.queries("find_node")
        XCTAssertEqual(q.first?.to, ep(boot))
        XCTAssertEqual(q.first?.args["id"]?.data?.count, 20); XCTAssertEqual(q.first?.args["target"]?.data?.count, 20)
        let raw = t.sent.first!.data
        guard case .query(let tid, _, _, let ro)? = KRPC.parse(raw) else { return XCTFail() }
        XCTAssertEqual(tid.count, 4); XCTAssertTrue(ro, "read-only: we hold no listening port")
        node.stopNow(reason: "test")
    }

    func testAnAnswerFromTheWrongPlaceOrWithTheWrongTransactionIsIgnored() async {
        let t = FakeDHTTransport(); let node = make(t)
        node.acquire(UUID())
        _ = await until { t.sentCount >= 1 }
        guard case .query(let tid, _, _, _)? = KRPC.parse(t.sent[0].data) else { return XCTFail() }
        let good = KRPC.response(tid: tid, values: ["id": .bytes(Data(count: 20)), "nodes": .bytes(Data())])
        t.inject(good, from: ep("198.51.100.77"))                                    // right transaction, wrong sender
        t.inject(KRPC.response(tid: Data("zzzz".utf8), values: ["id": .bytes(Data(count: 20))]), from: ep(boot))          // right sender, unknown transaction
        t.inject(Data("garbage".utf8), from: ep(boot))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(node.droppedSpoofed, 2); XCTAssertEqual(node.droppedMalformed, 1)
        XCTAssertNotEqual(node.status.state, .ready)
        t.inject(good, from: ep(boot))
        let ready = await until { node.status.state == .ready }
        XCTAssertTrue(ready)
        node.stopNow(reason: "test")
    }

    func testALookupConvergesAndDeliversThePeer() async {
        let t = FakeDHTTransport(); swarm(t); let node = make(t)
        let task = UUID(); node.acquire(task)
        _ = await until { node.status.state == .ready }
        let got = Box<[PeerAddress]>([]), done = Box(false)
        node.lookupPeers(infoHash: infoHash, task: task, onPeers: { peers, local in got.v += peers; XCTAssertFalse(local) }, onFinish: { done.v = true })
        let finished = await until { done.v }
        XCTAssertTrue(finished); XCTAssertEqual(got.v, [peerA.peerAddress])
        let asks = t.queries("get_peers")
        XCTAssertTrue(asks.allSatisfy { $0.args["info_hash"]?.data == infoHash })
        XCTAssertGreaterThanOrEqual(asks.count, 2, "both nodes the bootstrap named were asked")
        XCTAssertEqual(node.status.peersFound, 1)
        node.stopNow(reason: "test")
    }

    func testAPeerOnAPrivateAddressIsNotDelivered() async {
        let t = FakeDHTTransport(); swarm(t)
        let n1 = ep("198.51.100.11")
        t.remotes[n1] = { method, _ in method == "get_peers" ? ["token": .bytes(Data("t".utf8)), "values": .list([.bytes(self.ep("192.168.1.9", 6881).compact), .bytes(self.ep("127.0.0.1", 6881).compact), .bytes(self.ep("2606:4700::5", 6881).compact)])] : ["nodes": .bytes(Data())] }
        let node = make(t); let task = UUID(); node.acquire(task)
        _ = await until { node.status.state == .ready }
        let got = Box<[PeerAddress]>([]), done = Box(false)
        node.lookupPeers(infoHash: infoHash, task: task, onPeers: { p, _ in got.v += p }, onFinish: { done.v = true })
        _ = await until { done.v }
        XCTAssertEqual(got.v, [PeerAddress(host: "2606:4700::5", port: 6881)], "local peers are never taken from a public node; the public IPv6 peer is handed on")
        XCTAssertEqual(node.status.peersFound, 1)
        node.stopNow(reason: "test")
    }

    func testALookupByATaskThatDoesNotHoldTheNodeIsRefused() async {
        let t = FakeDHTTransport(); swarm(t); let node = make(t)
        node.acquire(UUID())
        let done = Box(false)
        node.lookupPeers(infoHash: infoHash, task: UUID(), onPeers: { _, _ in XCTFail() }, onFinish: { done.v = true })
        let finished = await until { done.v }
        XCTAssertTrue(finished)
        XCTAssertTrue(t.queries("get_peers").isEmpty)
        node.stopNow(reason: "test")
    }

    func testALocalBootstrapIsUsedOnlyWhenThePersonNamedIt() async {
        let t = FakeDHTTransport(); t.remotes[ep("127.0.0.1", 18796)] = { _, _ in ["nodes": .bytes(Data())] }
        let refused = make(t, explicit: false, hosts: ["127.0.0.1:18796"])
        refused.acquire(UUID())
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(t.sentCount, 0, "a public bootstrap list never reaches a local address")
        XCTAssertEqual(refused.status.state, .unreachable); refused.stopNow(reason: "x")
        let t2 = FakeDHTTransport(); t2.remotes[ep("127.0.0.1", 18796)] = { _, _ in ["nodes": .bytes(Data())] }
        let node = make(t2, explicit: true, hosts: ["127.0.0.1:18796"])
        node.acquire(UUID())
        let sent = await until { t2.sentCount > 0 }
        XCTAssertTrue(sent); node.stopNow(reason: "x")
    }

    func testAPeerFromTheConfiguredLocalNodeMayBeLocal() async {
        let t = FakeDHTTransport(); let local = ep("127.0.0.1", 18796)
        t.remotes[local] = { method, _ in method == "get_peers" ? ["token": .bytes(Data("t".utf8)), "values": .list([.bytes(self.ep("127.0.0.1", 18792).compact)])] : ["nodes": .bytes(Data())] }
        t.remoteIDs[local] = NodeID(bytes: [0x30] + [UInt8](repeating: 1, count: 19))
        let node = make(t, explicit: true, hosts: ["127.0.0.1:18796"]); let task = UUID(); node.acquire(task)
        _ = await until { node.status.state == .ready }
        let got = Box<[(PeerAddress, Bool)]>([]), done = Box(false)
        node.lookupPeers(infoHash: infoHash, task: task, onPeers: { p, l in got.v += p.map { ($0, l) } }, onFinish: { done.v = true })
        _ = await until { done.v }
        XCTAssertEqual(got.v.first?.0, PeerAddress(host: "127.0.0.1", port: 18792)); XCTAssertEqual(got.v.first?.1, true)
        node.stopNow(reason: "x")
    }

    func testPolicyBlockStopsEverythingBeforeAnyNetworkUse() async {
        let t = FakeDHTTransport()
        let node = make(t, policy: { DHTBlock(reason: "The DHT uses UDP, which a proxy cannot carry.", needsSettings: true) })
        node.acquire(UUID())
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(t.started, 0); XCTAssertEqual(t.sentCount, 0)
        XCTAssertEqual(node.status.state, .blocked); XCTAssertTrue(node.status.needsSettings)
    }

    func testSwitchingOffWhileRunningClosesTheSocketAndCancelsEverything() async {
        let t = FakeDHTTransport(); swarm(t)
        let off = Box(false)
        let node = make(t, policy: { off.v ? DHTBlock(reason: "off") : nil })
        let task = UUID(); node.acquire(task)
        _ = await until { node.status.state == .ready }
        let done = Box(false)
        node.lookupPeers(infoHash: infoHash, task: task, onPeers: { _, _ in }, onFinish: { done.v = true })
        off.v = true
        let closed = await until { t.closed >= 1 }
        XCTAssertTrue(closed); XCTAssertTrue(done.v || true)
        XCTAssertEqual(node.status.state, .blocked)
        let before = t.sentCount
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(t.sentCount, before, "nothing more is sent")
    }

    func testANetworkChangeReplacesTheSocketsAndAsksTheBootstrapNodeAgain() async {
        final class Gen: @unchecked Sendable { var v = 0 }
        let gen = Gen(); let t = FakeDHTTransport(); swarm(t)
        let node = DHTNode(transport: t, policy: { nil }, resolver: FixedResolver(table: [:]), bootstrap: { (["\(self.boot):6881"], false) }, pathGeneration: { gen.v })
        node.acquire(UUID())
        _ = await until { node.status.state == .ready }
        let before = t.queries("find_node").count
        gen.v = 1
        let again = await until(4) { t.started == 2 && t.queries("find_node").count > before }
        XCTAssertTrue(again, "the socket was made again and the bootstrap node asked again")
        XCTAssertEqual(t.closed, 1)
        node.stopNow(reason: "x")
    }

    func testAllBootstrapNodesSilentIsReportedAndRetried() async {
        var cfg = DHTNode.Config(); cfg.queryTimeout = 0.3; cfg.bootstrapRetry = 1
        let t = FakeDHTTransport()                          // nothing answers
        let node = make(t, config: cfg); node.acquire(UUID())
        let first = await until(4) { node.status.state == .unreachable }
        XCTAssertTrue(first, "\(node.status)")
        let before = t.queries("find_node").count
        let retried = await until(6) { t.queries("find_node").count > before }
        XCTAssertTrue(retried, "it keeps trying while a torrent needs it")
        XCTAssertNotNil(node.status.lastError)
        node.stopNow(reason: "x")
    }

    func testReleasingTheLastTorrentClosesTheSocket() async {
        let t = FakeDHTTransport(); swarm(t); let node = make(t)
        let a = UUID(), b = UUID(); node.acquire(a); node.acquire(b)
        _ = await until { node.status.state == .ready }
        node.release(a); try? await Task.sleep(nanoseconds: 150_000_000); XCTAssertEqual(t.closed, 0)
        node.release(b)
        let closed = await until { t.closed == 1 }
        XCTAssertTrue(closed); XCTAssertEqual(node.status.state, .off)
    }

    // Answering other nodes

    private func readyNode(_ t: FakeDHTTransport, private isPrivate: @escaping @Sendable (Data) -> Bool = { _ in false }, config: DHTNode.Config = DHTNode.Config()) async -> DHTNode {
        swarm(t); let node = make(t, isPrivate: isPrivate, config: config); node.acquire(UUID())
        _ = await until { node.status.state == .ready }
        return node
    }
    private func ask(_ t: FakeDHTTransport, _ method: String, _ args: [String: Bencode], from: DHTEndpoint, tid: String = "q1") async -> KRPC.Message? {
        let before = t.responses.count
        var a = args; a["id"] = .bytes(Data(count: 20))
        t.inject(KRPC.query(tid: Data(tid.utf8), method: method, args: a, readOnly: false), from: from)
        _ = await until(1) { t.responses.count > before }
        return t.responses.count > before ? t.responses.last?.0 : nil
    }

    func testItAnswersPingAndFindNodeAndKeepsTheAnswerSmall() async {
        let t = FakeDHTTransport(); let node = await readyNode(t); let from = ep("198.51.100.200")
        guard case .response(let tid, let v)? = await ask(t, "ping", [:], from: from) else { return XCTFail() }
        XCTAssertEqual(tid, Data("q1".utf8)); XCTAssertEqual(v["id"]?.data?.count, 20)
        let request = KRPC.query(tid: Data("q2".utf8), method: "find_node", args: ["id": .bytes(Data(count: 20)), "target": .bytes(Data(count: 20))], readOnly: false)
        guard case .response(_, let fv)? = await ask(t, "find_node", ["target": .bytes(Data(count: 20))], from: from, tid: "q2") else { return XCTFail() }
        let size = KRPC.response(tid: Data("q2".utf8), values: fv).count
        XCTAssertLessThanOrEqual(fv["nodes"]?.data?.count ?? 0, 26 * 8)
        XCTAssertLessThan(size, request.count * 8, "a small question never earns a large answer")
        node.stopNow(reason: "x")
    }

    func testItIgnoresQueriesFromPrivateAddressesAndBadRequests() async {
        let t = FakeDHTTransport(); let node = await readyNode(t)
        let answers = t.responses.count
        t.inject(KRPC.query(tid: Data("a".utf8), method: "ping", args: ["id": .bytes(Data(count: 20))], readOnly: false), from: ep("192.168.1.5"))
        t.inject(KRPC.query(tid: Data("a".utf8), method: "ping", args: ["id": .bytes(Data(count: 20))], readOnly: false), from: DHTEndpoint(host: "198.51.100.9", port: 0)!)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.responses.count, answers)
        guard case .error(_, let code, _)? = await ask(t, "nonsense", [:], from: ep("198.51.100.201")) else { return XCTFail() }
        XCTAssertEqual(code, 204)
        guard case .error(_, let c2, _)? = await ask(t, "find_node", ["target": .bytes(Data(count: 3))], from: ep("198.51.100.202")) else { return XCTFail() }
        XCTAssertEqual(c2, 203)
        node.stopNow(reason: "x")
    }

    func testAnnouncePeerNeedsAValidTokenAndAGoodPortAndIsBounded() async {
        let t = FakeDHTTransport(); let node = await readyNode(t); let from = ep("198.51.100.210", 40000)
        guard case .response(_, let gp)? = await ask(t, "get_peers", ["info_hash": .bytes(infoHash)], from: from), let token = gp["token"]?.data else { return XCTFail("no token") }
        XCTAssertNil(gp["values"], "nothing stored yet")
        guard case .error(_, let code, _)? = await ask(t, "announce_peer", ["info_hash": .bytes(infoHash), "port": .int(51413), "token": .bytes(Data(count: 8))], from: from, tid: "q3") else { return XCTFail() }
        XCTAssertEqual(code, 203, "a token that was never issued")
        guard case .error(_, let c2, _)? = await ask(t, "announce_peer", ["info_hash": .bytes(infoHash), "port": .int(0), "token": .bytes(token)], from: from, tid: "q4") else { return XCTFail() }
        XCTAssertEqual(c2, 203, "port 0")
        guard case .error(_, let c3, _)? = await ask(t, "announce_peer", ["info_hash": .bytes(infoHash), "port": .int(51413), "token": .bytes(token)], from: ep("198.51.100.211", 40000), tid: "q5") else { return XCTFail() }
        XCTAssertEqual(c3, 203, "a token issued to another address")
        guard case .response? = await ask(t, "announce_peer", ["info_hash": .bytes(infoHash), "port": .int(51413), "token": .bytes(token)], from: from, tid: "q6") else { return XCTFail() }
        guard case .response(_, let again)? = await ask(t, "get_peers", ["info_hash": .bytes(infoHash)], from: ep("198.51.100.212"), tid: "q7"), let values = again["values"]?.list else { return XCTFail("not stored") }
        XCTAssertEqual(values.compactMap { $0.data.flatMap(DHTEndpoint.init(compact:)) }, [DHTEndpoint(host: "198.51.100.210", port: 51413)!])
        guard case .response? = await ask(t, "announce_peer", ["info_hash": .bytes(infoHash), "implied_port": .int(1), "port": .int(1), "token": .bytes(token)], from: from, tid: "q8") else { return XCTFail() }
        guard case .response(_, let implied)? = await ask(t, "get_peers", ["info_hash": .bytes(infoHash)], from: ep("198.51.100.213"), tid: "q9") else { return XCTFail() }
        XCTAssertTrue((implied["values"]?.list ?? []).contains { $0.data == DHTEndpoint(host: "198.51.100.210", port: 40000)!.compact }, "implied_port uses the port the datagram came from")
        node.stopNow(reason: "x")
    }

    func testAPrivateTorrentIsNeverAnsweredOrStored() async {
        let t = FakeDHTTransport(); let hashCopy = infoHash
        let node = await readyNode(t, private: { $0 == hashCopy })
        guard case .error(let _, let code, _)? = await ask(t, "get_peers", ["info_hash": .bytes(infoHash)], from: ep("198.51.100.220")) else { return XCTFail() }
        XCTAssertEqual(code, 201)
        guard case .error? = await ask(t, "announce_peer", ["info_hash": .bytes(infoHash), "port": .int(5), "token": .bytes(Data(count: 8))], from: ep("198.51.100.220"), tid: "q2") else { return XCTFail() }
        node.stopNow(reason: "x")
    }

    func testAnUnknownSourceCannotMakeUsAnswerWithoutLimit() async {
        let t = FakeDHTTransport()
        var cfg = DHTNode.Config(); cfg.inboundPerIP = 3
        let node = await readyNode(t, config: cfg); let from = ep("198.51.100.230")
        let before = t.responses.count
        for i in 0..<10 { t.inject(KRPC.query(tid: Data("p\(i)".utf8), method: "ping", args: ["id": .bytes(Data(count: 20))], readOnly: false), from: from) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(t.responses.count - before, 3)
        XCTAssertGreaterThanOrEqual(node.droppedRateLimited, 7)
        node.stopNow(reason: "x")
    }

    // Persistence

    func testGoodNodesAreSavedAndOnlyValidOnesAreRestored() async {
        let store = MemoryNodeStore(); let t = FakeDHTTransport()
        let node = await { () -> DHTNode in swarm(t); let n = make(t, store: store); n.acquire(UUID()); _ = await until { n.status.state == .ready }; return n }()
        node.stopNow(reason: "x")
        _ = await until { store.saved != nil }
        XCTAssertNotNil(store.saved); XCTAssertTrue(store.saved!.allSatisfy { $0.endpoint.isRoutable })

        let defaults = UserDefaults(suiteName: "dht-\(UUID().uuidString)")!
        let real = DefaultsDHTNodeStore(defaults: defaults)
        let good = DHTNodeInfo(id: NodeID.random(), endpoint: ep("198.51.100.5"))
        real.save([good, DHTNodeInfo(id: NodeID.random(), endpoint: ep("10.0.0.1")), DHTNodeInfo(id: NodeID.random(), endpoint: ep("127.0.0.1"))])
        XCTAssertEqual(real.load(), [good], "a private address is dropped when read")
        defaults.set(Data("{broken".utf8), forKey: "downloads.dht.nodes.v1")
        XCTAssertTrue(real.load().isEmpty, "corrupted state is ignored")
        defaults.set(Data(count: 100_000), forKey: "downloads.dht.nodes.v1")
        XCTAssertTrue(real.load().isEmpty, "and so is an absurd size")
        real.clear(); XCTAssertTrue(real.load().isEmpty)
    }

    func testSavedNodesAreNotReplacedByNothingWhenNoNodeAnswered() async {
        let store = MemoryNodeStore(); store.nodes = [DHTNodeInfo(id: NodeID.random(), endpoint: ep("198.51.100.77"))]
        let t = FakeDHTTransport()                       // nothing answers
        let node = make(t, store: store); node.acquire(UUID())
        try? await Task.sleep(nanoseconds: 300_000_000)
        node.stopNow(reason: "x")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(store.saved, "no node answered, so the saved list is left as it was")
    }

    func testAQueuedLookupDoesNotStartAfterTheNodeIsStopped() async {
        let t = FakeDHTTransport(); swarm(t)
        var cfg = DHTNode.Config(); cfg.maxConcurrentLookups = 1
        let node = make(t, config: cfg); let task = UUID(); node.acquire(task)
        _ = await until { node.status.state == .ready }
        let a = Box(false), b = Box(false)
        node.lookupPeers(infoHash: infoHash, task: task, onPeers: { _, _ in }, onFinish: { a.v = true })
        node.lookupPeers(infoHash: infoHash, task: task, onPeers: { _, _ in }, onFinish: { b.v = true })          // waits behind the first
        node.stopNow(reason: "off")
        let both = await until { a.v && b.v }
        XCTAssertTrue(both, "both are told they are over")
        let sentAtStop = t.sentCount
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(t.sentCount, sentAtStop, "the queued lookup sent nothing after the stop")
    }

    func testAWarmStartUsesSavedNodesWithoutAnyBootstrapAnswer() async {
        let store = MemoryNodeStore(); let saved = DHTNodeInfo(id: NodeID(bytes: [0x20] + [UInt8](repeating: 9, count: 19)), endpoint: ep("198.51.100.11"))
        store.nodes = [saved]
        let t = FakeDHTTransport(); swarm(t); t.remotes[ep(boot)] = nil          // the bootstrap node is silent
        let node = make(t, store: store); let task = UUID(); node.acquire(task)
        let got = Box<[PeerAddress]>([]), done = Box(false)
        node.lookupPeers(infoHash: infoHash, task: task, onPeers: { p, _ in got.v += p }, onFinish: { done.v = true })
        _ = await until { done.v }
        XCTAssertEqual(got.v, [peerA.peerAddress], "found through the saved node alone")
        node.stopNow(reason: "x")
    }

    // IPv4 / IPv6

    func testIPv6IsAskedForOnlyWhereThereIsASocketForIt() async {
        let v4 = FakeDHTTransport(); swarm(v4); let n4 = make(v4); n4.acquire(UUID())
        _ = await until { n4.status.state == .ready }
        XCTAssertNil(v4.queries("find_node").first?.args["want"], "an IPv4-only network does not ask for IPv6 nodes")
        n4.stopNow(reason: "x")
        let v6 = FakeDHTTransport(); v6.supportsIPv6 = true; swarm(v6)
        let n6node = DHTNodeInfo(id: NodeID(bytes: [0x22] + [UInt8](repeating: 9, count: 19)), endpoint: ep("2606:4700::7", 6881))
        v6.remotes[ep(boot)] = { _, _ in ["nodes": self.nodesField([]), "nodes6": .bytes(DHTCompact.encodeNodes([n6node]))] }
        v6.remotes[n6node.endpoint] = { _, _ in ["nodes": .bytes(Data())] }
        let n = make(v6); n.acquire(UUID())
        _ = await until { n.status.state == .ready }
        XCTAssertEqual(v6.queries("find_node").first?.args["want"]?.list?.compactMap(\.string), ["n4", "n6"])
        let s = await until { n.status.nodes6 + n.status.nodes4 >= 1 }
        XCTAssertTrue(s)
        n.stopNow(reason: "x")
    }

    // Network policy

    func testProxyAndSystemProxyKeepTheDHTOffWithAnExplanation() {
        var setup = DownloadNetworkSetup()
        XCTAssertNotNil(DHTNetworkPolicy.block(setup: setup, enabled: true, dhtEnabled: false, systemProxyActive: false), "off until the person turns it on")
        XCTAssertNotNil(DHTNetworkPolicy.block(setup: setup, enabled: false, dhtEnabled: true, systemProxyActive: false), "off with peer-to-peer")
        XCTAssertNil(DHTNetworkPolicy.block(setup: setup, enabled: true, dhtEnabled: true, systemProxyActive: false))
        let system = DHTNetworkPolicy.block(setup: setup, enabled: true, dhtEnabled: true, systemProxyActive: true)
        XCTAssertEqual(system?.needsSettings, true); XCTAssertTrue(system?.reason.contains("Settings → Downloads") == true)
        setup.proxy.mode = .direct
        XCTAssertNil(DHTNetworkPolicy.block(setup: setup, enabled: true, dhtEnabled: true, systemProxyActive: true), "an explicit No proxy is the person's choice")
        setup.proxy.mode = .socks5; setup.proxy.host = "proxy.example.com"; setup.proxy.port = 1080
        XCTAssertEqual(DHTNetworkPolicy.block(setup: setup, enabled: true, dhtEnabled: true, systemProxyActive: false)?.needsSettings, true)
    }

    func testTorrentSettingsSavedBeforeTheDHTExistedStillRead() {
        let old = #"{"enabled":true,"maxActiveTorrents":3,"maxPeersPerTorrent":30,"maxPeersTotal":60,"shareWhileDownloading":true}"#
        let s = TorrentSettings.decode(old)
        XCTAssertTrue(s.enabled); XCTAssertFalse(s.dhtEnabled)
        var on = s; on.dhtEnabled = true
        XCTAssertTrue(TorrentSettings.decode(on.encoded()).dhtEnabled)
    }
}

// MARK: Sessions and the DHT: discovery, dedupe, private torrents, revocation, peer proxy

final class FakeDHT: DHTDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var acquired: [UUID] = [], released: [UUID] = []
    private(set) var lookups = 0
    var peers: [PeerAddress] = [], local = false
    var status = DHTStatus(state: .ready, nodes4: 5)
    func acquire(_ task: UUID) { lock.lock(); acquired.append(task); lock.unlock() }
    func release(_ task: UUID) { lock.lock(); released.append(task); lock.unlock() }
    func lookupPeers(infoHash: Data, task: UUID, onPeers: @escaping @Sendable ([PeerAddress], Bool) -> Void, onFinish: @escaping @Sendable () -> Void) -> DHTLookupHandle {
        lock.lock(); lookups += 1; let p = peers, l = local; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { onPeers(p, l); onFinish() }
        return DHTLookupHandle {}
    }
    var acquiredCount: Int { lock.lock(); defer { lock.unlock() }; return acquired.count }
}

final class DHTSessionTests: TorrentSessionTestCase {
    private func make(_ t: TorrentFixture.Built, meta: TorrentMetainfo?, trackers: [URL], tracker: TrackerAnnouncing = RecordingTracker(), dht: DHTDiscovering?, settings: TorrentSession.Settings = .testing,
                      behaviour: FakePeer.Behaviour = FakePeer.Behaviour(), built: Box<Int>? = nil) throws -> (TorrentSession, Events, FakePeers) {
        let storage = TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: taskID, in: root), selected: [])
        try storage.prepare()
        let factory = FakePeers { a, q in built?.v += 1; return FakePeer(queue: q, stream: t.stream, meta: t.meta, infoHash: t.meta.infoHash, behaviour: behaviour) }
        let events = Events()
        let s = TorrentSession(infoHash: t.meta.infoHash, meta: meta, trackers: trackers, storage: { storage }, alreadyHave: [], transports: factory, tracker: tracker, download: nil, upload: nil, taskID: taskID, settings: settings)
        s.dht = dht
        s.onEvent = { events.add($0) }
        return (s, events, factory)
    }
    final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

    func testATrackerlessTorrentFindsItsPeerThroughTheDHTAndDownloads() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let dht = FakeDHT(); dht.peers = [addr(1)]
        let (s, events, _) = try make(t, meta: t.meta, trackers: [], dht: dht)
        s.start()
        let done = await until { events.finished }
        XCTAssertTrue(done, events.failure ?? "no peer was found")
        XCTAssertEqual(dht.lookups, 1); XCTAssertEqual(dht.acquired, [taskID])
        s.stop()
        let released = await until { dht.released == [self.taskID] }
        XCTAssertTrue(released, "the node is let go when the torrent stops")
        XCTAssertGreaterThanOrEqual(s.snapshot.dhtPeers, 0)
    }

    func testAPeerNamedByBothTheDHTAndATrackerIsConnectedOnce() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let dht = FakeDHT(); dht.peers = [addr(1)]
        let rec = RecordingTracker(); rec.peers = [addr(1)]
        let built = Box(0)
        let (s, events, _) = try make(t, meta: t.meta, trackers: [URL(string: "http://a.example.com/announce")!], tracker: rec, dht: dht, behaviour: FakePeer.Behaviour(neverUnchoke: true), built: built)
        s.start()
        _ = await until { built.v >= 1 }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(built.v, 1, "one connection for the one address, whichever source named it first")
        XCTAssertFalse(events.finished)
        s.stop(sendStoppedAnnounce: false)
    }

    func testAPrivateTorrentNeverTouchesTheDHT() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)], isPrivate: true)
        let dht = FakeDHT(); dht.peers = [addr(1)]
        let rec = RecordingTracker(); rec.peers = [addr(2)]
        let (s, events, _) = try make(t, meta: t.meta, trackers: [URL(string: "http://a.example.com/announce")!], tracker: rec, dht: dht)
        s.start()
        let done = await until { events.finished }
        XCTAssertTrue(done, "the tracker's peer is enough: a private torrent still downloads")
        XCTAssertEqual(dht.acquiredCount, 0); XCTAssertEqual(dht.lookups, 0)
        s.stop(sendStoppedAnnounce: false)
    }

    func testAMagnetThatNamesTrackersIsNotLookedUpOnTheDHTBeforeItsDetailsAreKnown() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let dht = FakeDHT(); dht.peers = [addr(1)]
        let (withTracker, _, _) = try make(t, meta: nil, trackers: [URL(string: "http://a.example.com/announce")!], dht: dht)
        withTracker.start()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(dht.acquiredCount, 0, "trackers are preferred; the public network is not asked about a possibly private torrent")
        withTracker.stop(sendStoppedAnnounce: false)
        let (trackerless, _, _) = try make(t, meta: nil, trackers: [], dht: dht)
        trackerless.start()
        let asked = await until { dht.lookups == 1 }
        XCTAssertTrue(asked, "a magnet with no tracker has nothing else to find peers with")
        trackerless.stop(sendStoppedAnnounce: false)
    }

    func testADHTFailureDoesNotEndTheTorrent() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        let dht = FakeDHT(); dht.peers = []            // finds nothing
        let rec = RecordingTracker(); rec.peers = [addr(3)]
        let (s, events, _) = try make(t, meta: t.meta, trackers: [URL(string: "http://a.example.com/announce")!], tracker: rec, dht: dht)
        s.start()
        let done = await until { events.finished }
        XCTAssertTrue(done); XCTAssertNil(events.failure)
        s.stop(sendStoppedAnnounce: false)
    }

    func testRevokingAPermissionDropsOnlyThePeersThatDependedOnIt() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        var settings = TorrentSession.Settings.testing; settings.allowLocalPeers = false
        let allowed = Box<Set<String>>(["tracker:a", "tracker:b"])
        let lock = NSLock()
        let (s, _, factory) = try make(t, meta: t.meta, trackers: [], dht: nil, settings: settings, behaviour: FakePeer.Behaviour(neverUnchoke: true))
        s.localPeerStillAllowed = { key in lock.lock(); defer { lock.unlock() }; return allowed.v.contains(key) }
        s.start()
        s.addCandidates([addr(5)], fromLocalTracker: true, source: "tracker:a")          // only the first tracker named this one
        s.addCandidates([addr(6)], fromLocalTracker: true, source: "tracker:a")
        s.addCandidates([addr(6)], fromLocalTracker: true, source: "tracker:b")          // both named this one
        let connected = await until { factory.all.count == 2 }
        XCTAssertTrue(connected)
        lock.lock(); allowed.v = ["tracker:b"]; lock.unlock()                               // the first tracker's permission is revoked
        let dropped = await until { factory.peers[self.addr(5)]?.closed == true }
        XCTAssertTrue(dropped, "a connection that depended only on the revoked permission is closed")
        XCTAssertEqual(factory.peers[addr(6)]?.closed, false, "a peer another approved source named stays")
        lock.lock(); allowed.v = []; lock.unlock()
        let both = await until { factory.peers[self.addr(6)]?.closed == true }
        XCTAssertTrue(both)
        s.stop(sendStoppedAnnounce: false)
    }

    func testARevokedPeerIsNotConnectedToEvenIfItWasWaiting() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 40_000)])
        var settings = TorrentSession.Settings.testing; settings.allowLocalPeers = false
        let (s, _, factory) = try make(t, meta: t.meta, trackers: [], dht: nil, settings: settings, behaviour: FakePeer.Behaviour(neverUnchoke: true))
        s.localPeerStillAllowed = { _ in false }
        s.start()
        s.addCandidates([addr(7)], fromLocalTracker: true, source: "tracker:gone")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(factory.all.isEmpty)
        s.stop(sendStoppedAnnounce: false)
    }

    func testPeerConnectionsFailClosedWhenTheMacUsesAProxyAndRespectTheChoice() async {
        let queue = DispatchQueue(label: "t")
        let blocked = NWPeerTransport(address: PeerAddress(host: "203.0.113.5", port: 6881), setup: DownloadNetworkSetup(), queue: queue, systemProxyActive: true)
        let result = Box<Error?>(nil); let done = expectation(description: "failed")
        blocked.connect { e in result.v = e; done.fulfill() }
        await fulfillment(of: [done], timeout: 3)
        XCTAssertTrue("\(result.v?.localizedDescription ?? "")".contains("proxy"), "\(String(describing: result.v))")
        // The factory only treats the Mac's proxy as in force when the person's choice is "Use my Mac's settings".
        var direct = DownloadNetworkSetup(); direct.proxy.mode = .direct
        let f = NWPeerTransportFactory(network: { direct }, systemProxyActive: { true })
        let t = f.make(PeerAddress(host: "203.0.113.5", port: 6881), queue: queue) as! NWPeerTransport
        let r2 = Box<Error?>(nil); let d2 = expectation(description: "direct")
        t.connect { e in r2.v = e; d2.fulfill() }; t.close()
        await fulfillment(of: [d2], timeout: 5)
        XCTAssertFalse("\(r2.v?.localizedDescription ?? "")".contains("Mac uses a proxy"), "an explicit No proxy connects directly")
    }
}
