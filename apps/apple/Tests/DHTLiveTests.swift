import XCTest
@testable import Browser_Setu

/// The real socket and node against an independent BEP 5 node (e2e/dhtnode.py, written separately from this code). Skipped unless DX02_LIVE_DHT=1 (TEST_RUNNER_DX02_LIVE_DHT=1) and the fixture is running on 127.0.0.1:18796.
final class DHTLiveTests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipUnless(ProcessInfo.processInfo.environment["DX02_LIVE_DHT"] == "1") }

    func testBootstrapLookupAndPeerFromAnIndependentNode() async throws {
        let hash = Data(NodeID(hex: "86a0237199c6d96409a3b7d3df69f19b86a8c0d9")!.bytes)
        let node = DHTNode(transport: NWDHTTransport(), policy: { nil }, bootstrap: { (["127.0.0.1:18796"], true) })
        let task = UUID(); node.acquire(task)
        defer { node.stopNow(reason: "done") }
        var ready = false
        for _ in 0..<150 { if node.status.state == .ready { ready = true; break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(ready, "bootstrap answered: \(node.status)")
        final class Box: @unchecked Sendable { var peers: [(PeerAddress, Bool)] = []; var done = false }
        let box = Box()
        node.lookupPeers(infoHash: hash, task: task, onPeers: { p, local in box.peers += p.map { ($0, local) } }, onFinish: { box.done = true })
        for _ in 0..<400 { if box.done { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(box.done)
        print("LIVE DHT peers:", box.peers, "status:", node.status)
        XCTAssertEqual(box.peers.first?.0, PeerAddress(host: "127.0.0.1", port: 18792))
        XCTAssertEqual(box.peers.first?.1, true, "from the node the person configured on their own network")
    }
}
