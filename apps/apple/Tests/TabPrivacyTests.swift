import XCTest
@testable import Browser_Setu

/// What each kind of tab may keep, share or save. A normal tab keeps; private, guest, scratch and Glance tabs do not.
@MainActor
final class TabPrivacyTests: XCTestCase {
    private func model(guest: Bool = false) async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-ctx-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        m.isGuest = guest
        return m
    }

    private func tab(_ m: BrowserModel, _ context: TabContext, url: String = "https://example.com/page") -> TabController {
        let t: TabController
        switch context {
        case .normal, .glance: t = m.openTab(url: nil, isPrivate: false)
        case .privateTab: t = m.openTab(url: nil, isPrivate: true)
        case .scratch: t = m.openTab(url: nil, isPrivate: false, scratch: true)
        case .guest: t = m.openTab(url: nil, isPrivate: true)
        }
        t.url = URL(string: url)
        return t
    }

    func testOnlyANormalTabKeepsAnything() {
        for context in TabContext.allCases {
            let p = TabPrivacy(context: context)
            let all = [p.keepsTraces, p.canSaveLogins, p.canSaveToResearch, p.canRecordClipboard, p.canRecordActivity, p.canShareWithAutomation, p.canSaveSiteSettings, p.canWriteFilesWithoutAsking]
            if context == .normal { XCTAssertTrue(all.allSatisfy { $0 }, "a normal tab keeps") }
            else { XCTAssertTrue(all.allSatisfy { !$0 }, "\(context) keeps nothing"); XCTAssertFalse(p.refusal.isEmpty) }
        }
    }

    func testTheContextIsReadFromHowTheTabWasOpened() async {
        let m = await model()
        XCTAssertEqual(tab(m, .normal).context, .normal)
        XCTAssertEqual(tab(m, .privateTab).context, .privateTab)
        XCTAssertEqual(tab(m, .scratch).context, .scratch)
        let g = await model(guest: true)
        XCTAssertEqual(tab(g, .guest).context, .guest)
    }

    func testResearchSavesNothingFromAnyTabThatLeavesNoTrace() async {
        for context in [TabContext.privateTab, .scratch] {
            let m = await model()
            _ = m.research.create(name: "R")
            _ = tab(m, context)
            let draft = await m.researchDraftForActivePage()
            XCTAssertNil(draft, "\(context)")
            await m.addPageToResearch()
            XCTAssertTrue(m.research.collections.flatMap(\.items).isEmpty, "\(context) was saved")
        }
        let normal = await model()
        _ = normal.research.create(name: "R")
        _ = tab(normal, .normal)
        let draft = await normal.researchDraftForActivePage()
        XCTAssertNotNil(draft, "a normal tab still can")
    }

    func testClipboardHistoryIgnoresCopiesFromTabsThatLeaveNoTrace() async {
        for context in [TabContext.privateTab, .scratch] {
            let m = await model()
            m.keepClipboardHistory = true
            _ = tab(m, context)
            m.recordCopy("a quote from a page")
            XCTAssertTrue(m.clipboardHistory.isEmpty, "\(context)")
        }
        let m = await model()
        m.keepClipboardHistory = true
        _ = tab(m, .normal)
        m.recordCopy("kept")
        XCTAssertEqual(m.clipboardHistory.count, 1)
    }

    func testSiteStylesAreNotSavedFromATabThatLeavesNoTrace() async {
        for context in [TabContext.privateTab, .scratch] {
            let m = await model()
            _ = tab(m, context)
            m.setStyleForActiveSite("body { background: black }")
            XCTAssertTrue(m.siteStyles.isEmpty, "\(context)")
        }
    }

    func testSignInsAreNeverOfferedForSavingFromATabThatLeavesNoTrace() async {
        for context in [TabContext.privateTab, .scratch] {
            let m = await model()
            let t = tab(m, context)
            XCTAssertFalse(t.engineWantsLoginCapture(), "\(context)")
        }
        let m = await model()
        XCTAssertTrue(tab(m, .normal).engineWantsLoginCapture())
    }

    func testScratchTabsAreNotInRestorePointsOrTheOpenTabsThatSync() async throws {
        let m = await model()
        m.syncCategorySet.insert(.openTabs)
        _ = tab(m, .normal, url: "https://kept.example.com/")
        _ = tab(m, .scratch, url: "https://scratch.example.com/")
        _ = tab(m, .privateTab, url: "https://private.example.com/")
        let sent = m.makeSyncSnapshot().tabs?.map(\.url) ?? []
        XCTAssertTrue(sent.contains("https://kept.example.com/"))
        XCTAssertFalse(sent.contains { $0.contains("scratch.") || $0.contains("private.") }, "\(sent)")
    }

    func testNoPictureOrPageIsWrittenToDiskFromATabThatLeavesNoTrace() async throws {
        XCTAssertFalse(Workbench.safeCommands.contains("screenshot-annotate"), "an outside link or workflow cannot make a capture on its own")
        func files() -> Set<String> {
            let root = DownloadCoordinator.directory
            return Set(((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("Screenshots") || $0.hasPrefix("Page Screenshots") || $0.hasSuffix(".png") || $0.hasSuffix(".pdf") })
        }
        for context in [TabContext.privateTab, .scratch] {
            let m = await model()
            _ = tab(m, context)
            let before = files()
            await m.takeScreenshot(fullPage: false)
            await m.takeScreenshot(fullPage: true)
            await m.annotatePageScreenshot()
            await m.savePageAsPDF()
            XCTAssertEqual(files(), before, "\(context) wrote a file")
            XCTAssertNil(m.pdfEditorURL, "\(context) opened a saved PDF")
        }
    }

    func testTheAutomationBridgeUsesThePolicyNotAPrivateFlagAlone() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("macOS/AgentBridge.swift"), encoding: .utf8)
        XCTAssertFalse(bridge.contains(".isPrivate"), "AgentBridge must ask TabPrivacy")
        XCTAssertTrue(bridge.contains("canShareWithAutomation"))
        for file in ["Shared/PasswordManager.swift", "Shared/ToolkitFeatures.swift", "Shared/Research.swift", "Shared/ResearchNotes.swift", "Shared/PageMemory.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("privacy."), "\(file) must ask TabPrivacy")
        }
    }
}
