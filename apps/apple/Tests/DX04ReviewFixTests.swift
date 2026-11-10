import XCTest
@testable import Browser_Setu

// Regression tests for the DX-04 review findings that can be tested without a network, and for NAT-PMP.

final class NATPMPCodecTests: XCTestCase {
    func testMapRequestLayoutIsTheOneRFC6886Describes() {
        let d = NATPMP.mapRequest(.tcp, internalPort: 51413, suggestedExternal: 51413, lifetime: 3600)
        XCTAssertEqual([UInt8](d), [0, 2, 0, 0, 0xC8, 0xD5, 0xC8, 0xD5, 0, 0, 0x0E, 0x10])
        XCTAssertEqual(d.count, 12)
        XCTAssertEqual([UInt8](NATPMP.mapRequest(.udp, internalPort: 1, suggestedExternal: 0, lifetime: 0)).prefix(2), [0, 1])
    }

    func testReplyIsParsedOnlyWhenWellFormedAndOfTheRightKind() {
        var b: [UInt8] = [0, 130, 0, 0, 0, 0, 0, 9, 0xC8, 0xD5, 0xC8, 0xD6, 0, 0, 0x0E, 0x10]
        let r = NATPMP.parseMap(Data(b), proto: .tcp)
        XCTAssertEqual(r, NATPMP.MapReply(result: 0, epoch: 9, internalPort: 51413, externalPort: 51414, lifetime: 3600))
        XCTAssertNil(NATPMP.parseMap(Data(b), proto: .udp), "an answer to the other kind of request")
        XCTAssertNil(NATPMP.parseMap(Data(b.dropLast()), proto: .tcp), "too short")
        b[0] = 1
        XCTAssertNil(NATPMP.parseMap(Data(b), proto: .tcp), "another version")
        XCTAssertEqual(NATPMP.resultText(2).contains("refused"), true)
    }
}

final class FakeRouter: PortMapTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [Data] = []
    var result: UInt16 = 0
    var answers = true
    var externalOffset: UInt16 = 0
    /// Set to make the router look PCP-capable: its address is known, and `speaksPCP` decides whether it answers version 2 requests.
    var localIPv4: String?
    var speaksPCP = false
    private(set) var closed = false
    func exchange(_ request: Data, timeout: TimeInterval) async -> Data? {
        lock.lock(); requests.append(request); let (result, answers, off) = (self.result, self.answers, externalOffset); lock.unlock()
        guard answers else { return nil }
        let b = [UInt8](request)
        if b[0] == 2 {          // PCP
            guard speaksPCP, b.count == 60 else { return nil }
            var out = [UInt8](repeating: 0, count: 60)
            out[0] = 2; out[1] = 0x81; out[3] = UInt8(result)
            out[4...7] = b[4...7]                   // lifetime
            out[24..<36] = b[24..<36]               // nonce
            out[36] = b[36]                         // protocol
            out[40] = b[40]; out[41] = b[41]        // internal port
            let ext = ((UInt16(b[42]) << 8) | UInt16(b[43])) &+ off
            out[42] = UInt8(ext >> 8); out[43] = UInt8(ext & 0xFF)
            return Data(out)
        }
        let lifetime = (UInt32(b[8]) << 24) | (UInt32(b[9]) << 16) | (UInt32(b[10]) << 8) | UInt32(b[11])
        let ext = ((UInt16(b[6]) << 8) | UInt16(b[7])) &+ off
        var out: [UInt8] = [0, 128 + b[1], UInt8(result >> 8), UInt8(result & 0xFF), 0, 0, 0, 1, b[4], b[5], UInt8(ext >> 8), UInt8(ext & 0xFF)]
        out += [UInt8(lifetime >> 24), UInt8((lifetime >> 16) & 0xFF), UInt8((lifetime >> 8) & 0xFF), UInt8(lifetime & 0xFF)]
        return Data(out)
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    var sent: [Data] { lock.lock(); defer { lock.unlock() }; return requests }
}

final class PCPCodecTests: XCTestCase {
    func testMapRequestIs60BytesWithTheLayoutOfRFC6887() {
        let nonce = [UInt8](1...12)
        let d = [UInt8](PCP.mapRequest(client: [192, 168, 1, 20], nonce: nonce, .tcp, internalPort: 51413, suggestedExternal: 51413, lifetime: 3600))
        XCTAssertEqual(d.count, 60)
        XCTAssertEqual(Array(d[0..<4]), [2, 1, 0, 0], "version 2, MAP request")
        XCTAssertEqual(Array(d[4..<8]), [0, 0, 0x0E, 0x10])
        XCTAssertEqual(Array(d[8..<24]), [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 192, 168, 1, 20], "our address, as an IPv4-mapped IPv6 address")
        XCTAssertEqual(Array(d[24..<36]), nonce)
        XCTAssertEqual(d[36], 6)
        XCTAssertEqual(Array(d[40..<44]), [0xC8, 0xD5, 0xC8, 0xD5])
    }

    func testAnAnswerIsAcceptedOnlyWithOurNonceAndProtocol() {
        let nonce = [UInt8](1...12)
        var b = [UInt8](repeating: 0, count: 60)
        b[0] = 2; b[1] = 0x81; b[7] = 60; b[36] = 17; b[40] = 0x1A; b[41] = 0x0B; b[42] = 0x1A; b[43] = 0x0C
        b.replaceSubrange(24..<36, with: nonce)
        XCTAssertEqual(PCP.parseMap(Data(b), nonce: nonce, .udp), PCP.MapReply(result: 0, lifetime: 60, internalPort: 0x1A0B, externalPort: 0x1A0C))
        XCTAssertNil(PCP.parseMap(Data(b), nonce: nonce, .tcp), "another protocol")
        XCTAssertNil(PCP.parseMap(Data(b), nonce: [UInt8](repeating: 9, count: 12), .udp), "someone else's nonce")
        b[0] = 1
        XCTAssertNil(PCP.parseMap(Data(b), nonce: nonce, .udp), "NAT-PMP-shaped answer")
    }
}

final class PortMapperTests: XCTestCase {
    func testPCPIsUsedWhenTheRouterSpeaksItAndTheMappingIsReleased() async {
        let router = FakeRouter(); router.localIPv4 = "192.168.1.20"; router.speaksPCP = true; router.externalOffset = 2
        let m = PortMapper(gateway: { "192.168.1.1" }, open: { _ in router }, timeouts: [0.05], sleep: never)
        m.start(port: 51413)
        let mapped = await wait(m, .mapped)
        XCTAssertTrue(mapped)
        XCTAssertEqual(m.status.via, "PCP")
        XCTAssertEqual(m.status.externalPort, 51415)
        XCTAssertTrue(router.sent.allSatisfy { $0.first == 2 }, "no NAT-PMP request was needed")
        m.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let releases = router.sent.dropFirst(2).map { [UInt8]($0) }
        XCTAssertEqual(releases.count, 2)
        XCTAssertTrue(releases.allSatisfy { Array($0[4..<8]) == [0, 0, 0, 0] }, "lifetime 0 removes the mapping")
    }

    func testARouterThatOnlySpeaksNATPMPIsAskedAgainWithThatProtocol() async {
        let router = FakeRouter(); router.localIPv4 = "192.168.1.20"; router.speaksPCP = false
        let m = PortMapper(gateway: { "192.168.1.1" }, open: { _ in router }, timeouts: [0.02], sleep: never)
        m.start(port: 6881)
        let mapped = await wait(m, .mapped)
        XCTAssertTrue(mapped)
        XCTAssertEqual(m.status.via, "NAT-PMP")
        m.stop()
    }

    private let never: PortMapper.Sleep = { _ in try? await Task.sleep(nanoseconds: 120_000_000_000) }
    private func wait(_ m: PortMapper, _ state: PortMappingStatus.State) async -> Bool {
        for _ in 0..<200 { if m.status.state == state { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
        return false
    }

    func testRouterThatAnswersOpensThePortAndStoppingReleasesIt() async {
        let router = FakeRouter(); router.externalOffset = 1
        let m = PortMapper(gateway: { "192.168.1.1" }, open: { _ in router }, timeouts: [0.05], sleep: never)
        m.start(port: 51413)
        let mapped = await wait(m, .mapped)
        XCTAssertTrue(mapped)
        XCTAssertEqual(m.status.externalPort, 51414, "the port the router chose is the one reported")
        XCTAssertEqual(router.sent.count, 2, "TCP and UDP")
        m.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let releases = router.sent.dropFirst(2).map { [UInt8]($0) }
        XCTAssertEqual(releases.count, 2)
        XCTAssertTrue(releases.allSatisfy { Array($0[8...11]) == [0, 0, 0, 0] && $0[6] == 0 && $0[7] == 0 }, "lifetime 0 and external port 0 remove the mapping")
        XCTAssertEqual(m.status.state, .off)
    }

    func testARefusalIsReportedAsWhatTheRouterSaid() async {
        let router = FakeRouter(); router.result = 2
        let m = PortMapper(gateway: { "192.168.1.1" }, open: { _ in router }, timeouts: [0.05], sleep: never)
        m.start(port: 6881)
        let failed = await wait(m, .failed)
        XCTAssertTrue(failed)
        XCTAssertTrue(m.status.message?.contains("refused") == true)
        XCTAssertNil(m.status.externalPort, "nothing is claimed")
        m.stop()
    }

    func testARouterThatDoesNotAnswerIsNotClaimedToHaveOpenedAnything() async {
        let router = FakeRouter(); router.answers = false
        let m = PortMapper(gateway: { "192.168.1.1" }, open: { _ in router }, timeouts: [0.02, 0.02], sleep: never)
        m.start(port: 6881)
        let failed = await wait(m, .failed)
        XCTAssertTrue(failed)
        XCTAssertEqual(router.sent.count, 2, "bounded attempts, then it waits before trying again")
        m.stop()
    }

    func testNoRouterOnTheNetworkIsAFailureNotACrash() async {
        let m = PortMapper(gateway: { nil }, open: { _ in nil }, timeouts: [0.01], sleep: never)
        m.start(port: 6881)
        let failed = await wait(m, .failed)
        XCTAssertTrue(failed)
        m.stop()
    }
}

final class UTPReviewFixTests: XCTestCase {
    private func syn(id: UInt16) -> UTP.Packet { UTP.Packet(type: .syn, connectionID: id, timestamp: 5, timestampDifference: 0, window: 100_000, seq: 1, ack: 0) }

    func testARepeatedSYNIsAnsweredAgainBecauseOurFirstAnswerMayHaveBeenLost() {
        var sent: [UTP.Packet] = []
        let c = UTPConnection(clock: { 2_000_000 })
        c.sendDatagram = { if let p = UTP.parse($0) { sent.append(p) } }
        c.accept(syn(id: 77))
        XCTAssertEqual(sent.map(\.type), [.state])
        c.receive(UTP.encode(syn(id: 77)))
        XCTAssertEqual(sent.map(\.type), [.state, .state], "answered again")
        XCTAssertEqual(c.state, .connected)
    }

    func testAFullSendQueueIsReportedSoTheCallerCanEndTheConnection() {
        var tuning = UTPConnection.Tuning(); tuning.maxSendQueue = 1000
        let c = UTPConnection(tuning: tuning, clock: { 2_000_000 })
        c.sendDatagram = { _ in }
        c.accept(syn(id: 5))
        XCTAssertTrue(c.write(Data(repeating: 1, count: 600)))
        // The first bytes go out on the wire at once, so fill past the limit in one write.
        XCTAssertFalse(c.write(Data(repeating: 2, count: 5000)), "refused, not silently dropped")
    }
}

final class InboundPerHostTests: TorrentSessionTestCase {
    func testOneHostCannotFillTheTorrentWithIncomingConnections() async throws {
        let t = try TorrentFixture.build(files: [(["a.bin"], 32768 * 4)], isPrivate: false)
        let storage = TorrentStorage(meta: t.meta, workingFolder: TorrentStorage.workingFolder(for: taskID, in: root), selected: [])
        try storage.prepare()
        let s = TorrentSession(infoHash: t.meta.infoHash, meta: t.meta, trackers: [], storage: { storage }, alreadyHave: [], transports: ScriptedPeers(), tracker: RecordingTracker(), download: nil, upload: nil, taskID: taskID, settings: .testing)
        s.start()
        let q = DispatchQueue(label: "inbound.test")
        var results: [Bool] = []
        for port in 40001...40005 {
            let a = PeerAddress(host: "198.51.100.77", port: UInt16(port))
            results.append(s.adoptInbound(ScriptedPeer(a, queue: q), address: a, initial: Data()))
        }
        XCTAssertEqual(results, [true, true, true, false, false], "three per host, then refused")
        let other = PeerAddress(host: "198.51.100.78", port: 40001)
        XCTAssertTrue(s.adoptInbound(ScriptedPeer(other, queue: q), address: other, initial: Data()), "another host is not affected")
        s.stop(sendStoppedAnnounce: false)
    }
}

// MARK: UPnP

final class FakeUPnP: UPnPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var posts: [(url: URL, action: String, body: String)] = []
    var searchReply: Data? = Data("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLOCATION: http://192.168.1.1:5000/desc.xml\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n".utf8)
    var description = Data("""
        <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceList><device><deviceList><device><serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ctl/IPConn</controlURL></service>
        </serviceList></device></deviceList></device></deviceList></device></root>
        """.utf8)
    /// Refuses timed leases with 725, as some routers do.
    var onlyPermanent = false
    func search(gateway: String, timeout: TimeInterval) async -> Data? { searchReply }
    func fetch(_ url: URL, timeout: TimeInterval) async -> Data? { description }
    func post(_ url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async -> (status: Int, body: Data)? {
        let text = String(data: body, encoding: .utf8) ?? ""
        let action = headers["SOAPAction"] ?? ""
        lock.lock(); posts.append((url, action, text)); lock.unlock()
        if onlyPermanent, action.contains("AddPortMapping"), !text.contains("<NewLeaseDuration>0</NewLeaseDuration>") {
            return (500, Data("<s:Envelope><s:Body><s:Fault><detail><UPnPError><errorCode>725</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>".utf8))
        }
        return (200, Data())
    }
    var sent: [(url: URL, action: String, body: String)] { lock.lock(); defer { lock.unlock() }; return posts }
}

final class UPnPParsingTests: XCTestCase {
    func testOnlyTheRoutersOwnAddressIsAcceptedAsALocation() {
        func reply(_ loc: String) -> Data { Data("HTTP/1.1 200 OK\r\nLocation: \(loc)\r\n\r\n".utf8) }
        XCTAssertEqual(UPnP.location(fromSearchReply: reply("http://192.168.1.1:5000/d.xml"), gateway: "192.168.1.1")?.host, "192.168.1.1")
        XCTAssertNil(UPnP.location(fromSearchReply: reply("http://192.168.1.77:5000/d.xml"), gateway: "192.168.1.1"), "another computer on the network")
        XCTAssertNil(UPnP.location(fromSearchReply: reply("http://evil.example/d.xml"), gateway: "192.168.1.1"), "a name")
        XCTAssertNil(UPnP.location(fromSearchReply: reply("https://192.168.1.1/d.xml"), gateway: "192.168.1.1"), "another scheme")
        XCTAssertNil(UPnP.location(fromSearchReply: reply("http://user:pw@192.168.1.1/d.xml"), gateway: "192.168.1.1"), "credentials in the address")
        XCTAssertNil(UPnP.location(fromSearchReply: Data("HTTP/1.1 500 Error\r\nLOCATION: http://192.168.1.1/d.xml\r\n\r\n".utf8), gateway: "192.168.1.1"))
    }

    func testTheControlAddressIsResolvedAndMustStayOnTheRouter() {
        let loc = URL(string: "http://192.168.1.1:5000/desc.xml")!
        let xml = FakeUPnP().description
        let service = UPnP.service(fromDescription: xml, location: loc, gateway: "192.168.1.1")
        XCTAssertEqual(service?.controlURL.absoluteString, "http://192.168.1.1:5000/ctl/IPConn")
        let elsewhere = Data("<root><URLBase>http://10.9.9.9:80/</URLBase><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/c</controlURL></service></serviceList></device></root>".utf8)
        XCTAssertNil(UPnP.service(fromDescription: elsewhere, location: loc, gateway: "192.168.1.1"), "a description that points the control address at another host")
        let absolute = Data("<root><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>http://203.0.113.5/c</controlURL></service></serviceList></device></root>".utf8)
        XCTAssertNil(UPnP.service(fromDescription: absolute, location: loc, gateway: "192.168.1.1"))
        XCTAssertNil(UPnP.service(fromDescription: Data("not xml".utf8), location: loc, gateway: "192.168.1.1"))
    }

    func testTheActionsAndTheErrorCodeAreWhatTheRouterExpects() {
        let s = UPnPService(controlURL: URL(string: "http://192.168.1.1/c")!, serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1")
        let add = UPnP.addPortMapping(s, externalPort: 51413, internalPort: 51413, client: "192.168.1.20", tcp: true, lease: 3600)
        XCTAssertEqual(add.headers["SOAPAction"], "\"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"")
        let body = String(data: add.body, encoding: .utf8)!
        XCTAssertTrue(body.contains("<NewExternalPort>51413</NewExternalPort>") && body.contains("<NewProtocol>TCP</NewProtocol>") && body.contains("<NewInternalClient>192.168.1.20</NewInternalClient>"))
        XCTAssertEqual(UPnP.errorCode(in: Data("<errorCode> 725 </errorCode>".utf8)), 725)
        XCTAssertNil(UPnP.errorCode(in: Data("nothing".utf8)))
    }
}

final class UPnPMapperTests: XCTestCase {
    private let never: PortMapper.Sleep = { _ in try? await Task.sleep(nanoseconds: 120_000_000_000) }
    private func waitFor(_ m: PortMapper, _ state: PortMappingStatus.State) async -> Bool {
        for _ in 0..<300 { if m.status.state == state { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
        return false
    }
    private func silentRouter() -> FakeRouter { let r = FakeRouter(); r.answers = false; r.localIPv4 = "192.168.1.20"; return r }

    func testUPnPIsUsedWhenNeitherPCPNorNATPMPAnswersAndTheForwardIsRemovedOnStop() async {
        let router = silentRouter(), upnp = FakeUPnP()
        let m = PortMapper(gateway: { "192.168.1.1" }, open: { _ in router }, timeouts: [0.01], upnp: { upnp }, sleep: never)
        m.start(port: 51413)
        let mapped = await waitFor(m, .mapped)
        XCTAssertTrue(mapped)
        XCTAssertEqual(m.status.via, "UPnP")
        XCTAssertEqual(upnp.sent.filter { $0.action.contains("AddPortMapping") }.count, 2, "TCP and UDP")
        XCTAssertTrue(upnp.sent.allSatisfy { $0.url.host == "192.168.1.1" })
        m.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(upnp.sent.filter { $0.action.contains("DeletePortMapping") }.count, 2)
    }

    func testARouterThatOnlyTakesPermanentForwardsIsAskedAgainWithLeaseZero() async {
        let router = silentRouter(), upnp = FakeUPnP(); upnp.onlyPermanent = true
        let m = PortMapper(gateway: { "192.168.1.1" }, open: { _ in router }, timeouts: [0.01], upnp: { upnp }, sleep: never)
        m.start(port: 6881)
        let mapped = await waitFor(m, .mapped)
        XCTAssertTrue(mapped)
        XCTAssertTrue(upnp.sent.contains { $0.body.contains("<NewLeaseDuration>0</NewLeaseDuration>") })
        m.stop()
    }

    func testARouterWhoseDescriptionPointsElsewhereIsNotUsed() async {
        let router = silentRouter(), upnp = FakeUPnP()
        upnp.searchReply = Data("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.99:5000/desc.xml\r\n\r\n".utf8)
        let m = PortMapper(gateway: { "192.168.1.1" }, open: { _ in router }, timeouts: [0.01], upnp: { upnp }, sleep: never)
        m.start(port: 6881)
        let failed = await waitFor(m, .failed)
        XCTAssertTrue(failed)
        XCTAssertTrue(upnp.sent.isEmpty, "nothing was posted to a host that is not the router")
        m.stop()
    }
}

final class SleepOnce: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    /// The first wait (until a renewal is due) ends at once; every later one lasts.
    func sleep(_ t: TimeInterval) async {
        lock.lock(); n += 1; let c = n; lock.unlock()
        if c > 1 { try? await Task.sleep(nanoseconds: 120_000_000_000) }
    }
}

final class PCPRenewalTests: XCTestCase {
    func testARenewalCarriesTheSameNonceAsTheFirstRequest() async {
        let router = FakeRouter(); router.localIPv4 = "192.168.1.20"; router.speaksPCP = true
        let once = SleepOnce()
        let m = PortMapper(gateway: { "192.168.1.1" }, open: { _ in router }, timeouts: [0.05], sleep: { await once.sleep($0) })
        m.start(port: 51413)
        for _ in 0..<300 { if router.sent.count >= 4 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        let nonces = router.sent.prefix(4).map { Array([UInt8]($0)[24..<36]) }
        XCTAssertEqual(nonces.count, 4)
        XCTAssertEqual(nonces[0], nonces[2], "TCP: same mapping, same nonce")
        XCTAssertEqual(nonces[1], nonces[3], "UDP: same mapping, same nonce")
        XCTAssertNotEqual(nonces[0], nonces[1])
        m.stop()
    }

    func testARouterThatGivesPortZeroIsNotTreatedAsHavingOpenedAnything() async {
        let router = FakeRouter(); router.localIPv4 = nil
        // The fake adds the suggested port; ask for port 0 through an offset that cancels it.
        router.externalOffset = 0
        let m = PortMapper(gateway: { "192.168.1.1" }, open: { _ in router }, timeouts: [0.02], sleep: { _ in try? await Task.sleep(nanoseconds: 120_000_000_000) })
        m.start(port: 0)
        for _ in 0..<300 { if m.status.state == .failed { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(m.status.state, .failed)
        m.stop()
    }
}
