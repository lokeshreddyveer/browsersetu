import XCTest
@testable import Browser_Setu

@MainActor
final class MemoryTrimTests: XCTestCase {
    private func store(capacity: Int) -> FaviconStore {
        FaviconStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID().uuidString)"), memoryCapacity: capacity)
    }

    private func icon() -> PlatformImage {
        #if os(macOS)
        NSImage(size: NSSize(width: 4, height: 4))
        #else
        UIImage()
        #endif
    }

    func testFaviconMemoryNeverExceedsItsCapacity() {
        let store = store(capacity: 3)
        for i in 0..<10 { store.remember("site\(i).com", icon()) }
        XCTAssertEqual(store.memoryKeys.count, 3)
    }

    func testTheLeastRecentlyUsedIconIsTheOneDropped() {
        let store = store(capacity: 3)
        for name in ["a.com", "b.com", "c.com"] { store.remember(name, icon()) }
        // Asking for a.com makes it the most recent, so b.com is now the oldest.
        _ = store.image(forURL: "https://a.com/")
        store.remember("d.com", icon())
        XCTAssertEqual(store.memoryKeys, ["a.com", "c.com", "d.com"])
    }

    func testTrimmingKeepsTheMostRecentlyUsed() {
        let store = store(capacity: 5)
        for name in ["a.com", "b.com", "c.com", "d.com", "e.com"] { store.remember(name, icon()) }
        _ = store.image(forURL: "https://b.com/")
        store.trimMemory(limit: 2)
        XCTAssertEqual(store.memoryKeys, ["b.com", "e.com"])
        store.trimMemory(limit: 0)
        XCTAssertTrue(store.memoryKeys.isEmpty)
        store.trimMemory(limit: 0)        // trimming an empty cache is safe
    }

    func testAnIconWithAWwwPrefixSharesTheSitesKey() {
        let store = store(capacity: 3)
        store.remember(FaviconStore.key(forHost: "www.example.com")!, icon())
        XCTAssertNotNil(store.image(forURL: "https://example.com/page"))
    }

    func testPerfMeasureReturnsValue() {
        XCTAssertEqual(Perf.measure("Test") { 42 }, 42)
    }
}
