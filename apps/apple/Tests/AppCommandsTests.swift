import XCTest
@testable import Browser_Setu

// The menu bar's commands are also inside the app (command palette, More menu, Page Tools › Page). These tests keep that true.

@MainActor
final class AppCommandsTests: XCTestCase {
    private var apple: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    func testEveryNamedMenuBarCommandIsAlsoInTheAppsOwnList() throws {
        let source = try String(contentsOf: apple.appendingPathComponent("macOS/BrowserSetuMacApp.swift"), encoding: .utf8)
        let body = source.components(separatedBy: "var body: some Commands").last ?? ""
        let regex = try NSRegularExpression(pattern: #"Button\("([^"\\]+)"\)"#)
        let found = Set(regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } })
        XCTAssertGreaterThan(found.count, 80, "the scan found too few commands: did the menu move?")
        let inApp = Set(AppCommands.all.map(\.title))
        XCTAssertEqual(found.subtracting(inApp).sorted(), [], "these menu-bar commands are missing from AppCommands (add them there so they are reachable inside the window)")
    }

    func testCommandIdentifiersAreUniqueAndEveryCommandIsComplete() {
        let ids = AppCommands.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
        for command in AppCommands.all {
            XCTAssertFalse(command.title.isEmpty); XCTAssertFalse(command.symbol.isEmpty); XCTAssertFalse(command.section.isEmpty, command.title)
        }
        XCTAssertTrue(AppCommands.sections.contains("File")); XCTAssertTrue(AppCommands.sections.contains("Library")); XCTAssertTrue(AppCommands.sections.contains("Player"))
    }

    func testEveryRowOfPageToolsPageIsARealCommand() {
        for group in PageActionsView.groups {
            let found = PageActionsView.commands(for: group).map(\.title)
            XCTAssertEqual(found, group.titles, "\(group.name): a row would do nothing")
        }
    }

    func testThePaletteOffersEveryCommandOnceAndAnUnavailableOneSaysSo() async {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-ac-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        let items = m.allPaletteItems(full: true)
        let keys = items.map { BrowserModel.paletteKey($0.title) }
        for command in AppCommands.all { XCTAssertTrue(keys.contains(BrowserModel.paletteKey(command.title)), "\(command.title) is not in the palette") }
        let find = items.filter { BrowserModel.paletteKey($0.title) == "find next" }
        XCTAssertEqual(find.count, 1, "listed once")
        find.first?.run()
        XCTAssertNotNil(m.notice, "Find Next with no search open says it is not available instead of doing nothing")
    }
}

@MainActor
final class AppCommandDispatchTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-cd-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        return m
    }

    func testTheMenuBarCallsTheRegistryInsteadOfKeepingItsOwnCopyOfEachAction() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("macOS/BrowserSetuMacApp.swift"), encoding: .utf8)
        let body = source.components(separatedBy: "var body: some Commands").last ?? ""
        XCTAssertGreaterThan(body.components(separatedBy: "AppCommands.perform(").count - 1, 90, "the menu bar's buttons run their command through AppCommands")
        for gone in ["model.newTab()", "model.toggleSidebar()", "model.closeTab(id:", "model.printActive()", "model.showFind()"] {
            XCTAssertFalse(body.contains(gone), "the menu bar still has its own copy of \(gone)")
        }
        XCTAssertTrue(body.contains("openWindow(id: \"browser\")"), "New Window keeps the window-opening action of the menu")
    }

    func testTheMenuPaletteAndPageToolsReachTheSameHandler() async {
        let m = await model()
        let id = "cmd-view-toggle-sidebar"
        let before = m.sidebarVisible
        XCTAssertTrue(AppCommands.perform(id, m)); XCTAssertNotEqual(m.sidebarVisible, before, "the registry's handler toggled the sidebar")
        let paletteItem = m.allPaletteItems(full: true).first { $0.id == id || BrowserModel.paletteKey($0.title) == "toggle sidebar" }
        XCTAssertNotNil(paletteItem)
        paletteItem?.run()
        XCTAssertEqual(m.sidebarVisible, before, "the palette's entry ran the same handler (a second toggle)")
        let tabs = m.tabs.count
        AppCommands.perform("cmd-file-new-tab", m)
        XCTAssertEqual(m.tabs.count, tabs + 1)
    }

    func testACommandThatIsNotAvailableDoesNotRunAndSaysSo() async {
        let m = await model()
        XCTAssertFalse(m.findVisible)
        XCTAssertFalse(AppCommands.isEnabled("cmd-edit-find-next", m))
        XCTAssertFalse(AppCommands.perform("cmd-edit-find-next", m), "disabled: not run")
        XCTAssertFalse(AppCommands.perform("cmd-no-such-command", m), "an unknown id does nothing")
        let before = m.closedTabs.count
        XCTAssertFalse(AppCommands.isEnabled("cmd-file-reopen-closed-tab", m)); AppCommands.perform("cmd-file-reopen-closed-tab", m)
        XCTAssertEqual(m.closedTabs.count, before)
        m.notice = nil
        m.allPaletteItems(full: true).first { BrowserModel.paletteKey($0.title) == "find next" }?.run()
        XCTAssertNotNil(m.notice, "the palette tells the person why nothing happened")
    }
}
