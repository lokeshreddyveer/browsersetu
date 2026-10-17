import XCTest
@testable import Browser_Setu

/// iOS-specific lifecycle behaviour: backgrounding must checkpoint the session, private tabs must not be kept,
/// and the phone layout must keep normal and private tab sets apart.
@MainActor
final class IOSLifecycleTests: XCTestCase {
    private func makeModel(root: String, profile: String = "default") -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: root, profile: profile)
    }

    func testBackgroundingCheckpointsSessionWithoutPrivateTabs() async throws {
        let root = NSTemporaryDirectory() + "bs-ios-\(UUID().uuidString)"
        let a = makeModel(root: root)
        await a.start()
        let normal = a.active!
        normal.engineURLChanged(URL(string: "https://open.example/")!)
        try a.core.commitNavigation(tabId: normal.id, url: "https://open.example/", title: "Open")
        let priv = a.openTab(url: nil, isPrivate: true)
        priv.engineURLChanged(URL(string: "https://secret.example/")!)
        a.saveNow()                                   // what the app does when scenePhase leaves .active
        let b = makeModel(root: root)
        await b.start()
        XCTAssertEqual(b.tabs.compactMap { $0.url?.absoluteString }, ["https://open.example/"])
        XCTAssertFalse(b.tabs.contains { $0.isPrivate })
    }

    func testPhoneKeepsNormalAndPrivateTabSetsSeparate() async throws {
        let model = makeModel(root: NSTemporaryDirectory() + "bs-ios-\(UUID().uuidString)")
        await model.start()
        XCTAssertTrue(model.separatesPrivate)
        let normal = model.active!
        let priv = model.openTab(url: nil, isPrivate: true)
        XCTAssertTrue(model.privateMode)
        XCTAssertEqual(model.visibleTabs.map(\.id), [priv.id])
        model.select(normal.id)
        XCTAssertFalse(model.privateMode)
        XCTAssertEqual(model.visibleTabs.map(\.id), [normal.id])
    }

    func testIOSDownloadsLiveInsideTheAppContainer() {
        let dir = DownloadCoordinator.directory
        XCTAssertTrue(dir.path.hasSuffix("Documents/Downloads"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testBackgroundCaptureOfSnapshotsStaysBounded() async throws {
        let model = makeModel(root: NSTemporaryDirectory() + "bs-ios-\(UUID().uuidString)")
        await model.start()
        for _ in 0..<10 { model.newTab() }
        for tab in model.tabs { XCTAssertNil(tab.snapshot, "no snapshots are captured until a tab is left or the overview opens") }
    }
}

