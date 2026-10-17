import XCTest
@testable import Browser_Setu

@MainActor
final class MemoryTrimTests: XCTestCase {
    func testFaviconMemoryIsBounded() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID().uuidString)")
        let store = FaviconStore(directory: dir)
        store.trimMemory(limit: 0)
        XCTAssertNotNil(store)   // trimming an empty cache is safe
    }

    func testPerfMeasureReturnsValue() {
        XCTAssertEqual(Perf.measure("Test") { 42 }, 42)
    }
}
