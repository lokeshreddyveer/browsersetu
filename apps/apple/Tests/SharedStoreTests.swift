import XCTest
@testable import Browser_Setu

final class SharedStoreTests: XCTestCase {
    func testSnapshotAndInboxRoundTripThroughJSON() throws {
        let snap = SharedStore.Snapshot(favorites: [.init(title: "A", url: "https://a.test")], reading: [.init(title: "B", url: "https://b.test")], blockedToday: 7)
        XCTAssertEqual(try JSONDecoder().decode(SharedStore.Snapshot.self, from: JSONEncoder().encode(snap)), snap)
        let item = SharedStore.InboxItem(kind: .readLater, url: "https://c.test/x", title: "C")
        XCTAssertEqual(try JSONDecoder().decode(SharedStore.InboxItem.self, from: JSONEncoder().encode(item)), item)
        XCTAssertEqual(SharedStore.InboxItem.Kind(rawValue: "send"), .send)
    }

    func testOnlyWebAddressesAreAccepted() {
        // Without the App Group folder (as in a plain test run) nothing is written, whatever is offered.
        XCTAssertFalse(SharedStore.append(.init(kind: .open, url: "javascript:alert(1)", title: "x")))
        XCTAssertFalse(SharedStore.append(.init(kind: .open, url: "file:///etc/passwd", title: "x")))
    }
}
