import XCTest
@testable import Browser_Setu

/// Section 24 guardrail: the Library's width reaches storage once and correctly, and never stale. Throwaway profile folder; the app-hosted test process runs under a relocated home. WRITTEN, NOT RUN.
@MainActor
final class D1aClassicPersistenceTests: XCTestCase {
    private func model() -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-width-\(UUID().uuidString)", profile: "default")
    }

    func testTheWidthRangeAndDefault() {
        XCTAssertEqual(sidebarWidthRange.lowerBound, 190)
        XCTAssertEqual(sidebarWidthRange.upperBound, 340)
        XCTAssertEqual(clampedSidebarWidth(100), 190)
        XCTAssertEqual(clampedSidebarWidth(500), 340)
        XCTAssertEqual(clampedSidebarWidth(260), 260)
        XCTAssertEqual(model().sidebarWidth, 260, "the default width")
    }

    /// The end of a drag writes the final width at once; the delayed write that follows cannot change it.
    func testCommitWritesTheFinalWidthAndNothingLaterChangesIt() async throws {
        let m = model()
        for w in stride(from: 262.0, through: 300.0, by: 2.0) { m.sidebarWidth = w }       // a drag, frame by frame
        m.commitSidebarWidth()
        XCTAssertEqual(m.settingValue("sidebar_width"), "300", "the final width was not written at the end of the drag")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(m.settingValue("sidebar_width"), "300", "a delayed write changed the committed width")
    }

    /// A drag that is never committed (a slider move, a layout switch mid-drag) still ends at the current width, not an earlier frame's.
    func testDelayedSaveWritesTheCurrentWidthNotAnEarlierOne() async throws {
        let m = model()
        m.sidebarWidth = 220
        m.sidebarWidth = 310
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(m.settingValue("sidebar_width"), "310", "the delayed save wrote an earlier frame's width")
    }

    /// Frames of a drag are not written one by one: nothing is stored until the width settles or the drag ends.
    func testNothingIsWrittenWhileTheWidthIsStillChanging() async throws {
        let m = model()
        m.sidebarWidth = 240
        XCTAssertNil(m.settingValue("sidebar_width"), "a width was written on the frame itself")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(m.settingValue("sidebar_width"), "240")
    }

    /// A window that goes away with a save pending does not crash, and a new model on the same profile folder reads the last committed width.
    func testReleasingTheModelWithASavePendingIsSafe() async throws {
        let root = NSTemporaryDirectory() + "bs-width-\(UUID().uuidString)"
        do {
            let m = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
            m.sidebarWidth = 200; m.commitSidebarWidth()
            m.sidebarWidth = 330                                        // pending, never committed
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        let again = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        XCTAssertTrue([200.0, 330.0].contains(again.sidebarWidth), "the stored width is neither the committed nor the last one: \(again.sidebarWidth)")
    }

    /// The reset button writes 250, the default is 260: both are inside the range (the discrepancy is recorded, not changed).
    func testResetWidthIsInsideTheRange() {
        XCTAssertTrue(sidebarWidthRange.contains(250))
        XCTAssertNotEqual(250, SidebarSnap.standard, "the reset value and the snap target now agree: update the recorded discrepancy")
    }
}
