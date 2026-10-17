import XCTest
@testable import Browser_Setu

final class PhoneToolbarTests: XCTestCase {
    private func everything(_ l: PhoneToolbarLayout) -> [PhoneAction] { l.toolbarActions + l.more + l.hidden }

    func testStandardLayoutHasEveryActionOnceAndTheAddressBetweenTheButtons() {
        let l = PhoneToolbarLayout.standard
        XCTAssertEqual(Set(everything(l)).count, PhoneAction.allCases.count)
        XCTAssertEqual(everything(l).count, PhoneAction.allCases.count, "no action appears twice")
        XCTAssertEqual(l.beforeAddress, [.back, .forward])
        XCTAssertEqual(l.afterAddress, [.tabs])
        XCTAssertTrue(l.more.contains(.settings))
    }

    func testMovingAnActionBetweenPlacesKeepsEverythingConsistent() {
        var l = PhoneToolbarLayout.standard.moving(.share, to: .toolbar)
        XCTAssertEqual(l.location(of: .share), .toolbar)
        XCTAssertTrue(l.toolbarIsFull, "back, forward, tabs and share make four")
        let refused = l.moving(.bookmark, to: .toolbar)
        XCTAssertEqual(refused, l, "a fifth button does not fit")
        l = l.moving(.share, to: .hidden)
        XCTAssertEqual(l.location(of: .share), .hidden)
        XCTAssertEqual(everything(l).count, PhoneAction.allCases.count)
        l = l.moving(.settings, to: .hidden)
        XCTAssertNotEqual(l.location(of: .settings), .hidden, "Settings can always be reached")
    }

    func testAddressPillCanMoveAndTheButtonsSplitAroundIt() {
        let l = PhoneToolbarLayout(slots: [.address, .action(.back), .action(.forward), .action(.tabs)], more: [], hidden: [])
        XCTAssertEqual(l.beforeAddress, [])
        XCTAssertEqual(l.afterAddress, [.back, .forward, .tabs])
        let moved = PhoneToolbarLayout.standard.movingSlots(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(moved.beforeAddress, [])
        XCTAssertEqual(moved.afterAddress, [.back, .forward, .tabs])
    }

    func testDamagedSavedLayoutsAreRepaired() {
        XCTAssertEqual(PhoneToolbarLayout(stored: nil), .standard)
        XCTAssertEqual(PhoneToolbarLayout(stored: "not json"), .standard)
        let json = #"{"toolbar":["back","back","nonsense","tabs","share","find","reload","print"],"more":["share","madeup"],"hidden":["settings","history"]}"#
        let l = PhoneToolbarLayout(stored: json)
        XCTAssertEqual(l.slots.filter { $0 == .address }.count, 1, "the address pill is always there, once")
        XCTAssertLessThanOrEqual(l.toolbarActions.count, PhoneToolbarLayout.maxActions)
        XCTAssertEqual(l.toolbarActions.filter { $0 == .back }.count, 1)
        XCTAssertEqual(everything(l).count, PhoneAction.allCases.count)
        XCTAssertNotEqual(l.location(of: .settings), .hidden)
        XCTAssertEqual(l.location(of: .history), .hidden)
    }

    func testSavingAndLoadingRoundTrips() {
        let l = PhoneToolbarLayout.standard.moving(.reader, to: .toolbar).moving(.print, to: .hidden)
        XCTAssertEqual(PhoneToolbarLayout(stored: l.stored), l)
    }

    func testTheMoreMenuIsGroupedInSectionsAndKeepsTheUsersOrder() {
        let l = PhoneToolbarLayout.standard.movingMore(from: IndexSet(integer: PhoneToolbarLayout.standard.more.count - 1), to: 0)
        let sections = l.moreSections
        XCTAssertEqual(sections.map(\.section), sections.map(\.section).sorted { $0.rawValue < $1.rawValue }, "sections keep their fixed order")
        for group in sections { XCTAssertTrue(group.actions.allSatisfy { $0.section == group.section }) }
        XCTAssertFalse(sections.flatMap(\.actions).contains(.back), "what is in the toolbar is not repeated in the menu")
    }

    @MainActor func testTheChoiceIsSavedWithTheProfile() async throws {
        let root = NSTemporaryDirectory() + "bs-phone-\(UUID().uuidString)"
        let a = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await a.start()
        a.phoneLayout = a.phoneLayout.moving(.reader, to: .toolbar)
        a.addressDisplay = .titleAndDomain
        a.overviewStyle = .list
        a.searchPanelAtBottom = true
        a.darkPages = .chosen
        a.setDarkSite("www.Example.com", true)
        let b = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        XCTAssertEqual(b.phoneLayout.location(of: .reader), .toolbar)
        XCTAssertEqual(b.addressDisplay, .titleAndDomain)
        XCTAssertEqual(b.overviewStyle, .list)
        XCTAssertTrue(b.searchPanelAtBottom)
        XCTAssertTrue(b.shouldDarken(host: "example.com"))
        XCTAssertFalse(b.shouldDarken(host: "other.com"))
    }
}
