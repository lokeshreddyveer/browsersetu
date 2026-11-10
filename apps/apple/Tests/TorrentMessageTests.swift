import XCTest
@testable import Browser_Setu

@MainActor
final class TorrentMessageTests: XCTestCase {
    func testAFailedMagnetLookupSaysWhatWasTriedAndWhatCanHelp() {
        let off = TorrentRunner.noDetailsMessage(dhtOn: false)
        XCTAssertTrue(off.contains("Find peers on the public DHT") && off.contains("turn it on") && off.contains(".torrent file"), off)
        let on = TorrentRunner.noDetailsMessage(dhtOn: true)
        XCTAssertTrue(on.contains("no active peers") && on.contains(".torrent file") && !on.contains("turn it on"), on)
    }
}
