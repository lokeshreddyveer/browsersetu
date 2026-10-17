import XCTest
import SwiftUI
@testable import Browser_Setu

final class ShortcutTests: XCTestCase {
    func testCombosRoundTripAndDisplay() throws {
        let combo = KeyCombo(key: "T", command: true, shift: true)
        XCTAssertEqual(combo.stored, "shift+cmd+t")
        XCTAssertEqual(KeyCombo(stored: "shift+cmd+t"), combo)
        XCTAssertEqual(combo.display, "⇧⌘T")
        XCTAssertEqual(KeyCombo(key: "up", command: true, option: true).display, "⌥⌘↑")
        XCTAssertNil(KeyCombo(stored: "t"), "a bare letter is not a shortcut")
        XCTAssertNil(KeyCombo(stored: "hyper+t"))
        XCTAssertNil(KeyCombo(stored: ""))
    }

    func testEveryDefaultIsUsableAndNoTwoDefaultsClash() {
        var seen: [KeyCombo: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            let combo = action.defaultCombo
            XCTAssertTrue(combo.isUsable, "\(action) default")
            XCTAssertNotNil(combo.keyEquivalent, "\(action) default key")
            XCTAssertNil(seen[combo], "\(action) clashes with \(String(describing: seen[combo]))")
            seen[combo] = action
            XCTAssertFalse(ShortcutMap.isReserved(combo), "\(action) must not use a reserved shortcut")
        }
    }

    func testOverridesAreSavedLoadedAndCanTurnAShortcutOff() {
        var map = ShortcutMap()
        XCTAssertEqual(map.combo(for: .newTab), ShortcutAction.newTab.defaultCombo)
        map.set(KeyCombo(key: "y", command: true, option: true), for: .newTab)
        map.set(nil, for: .stop)
        let loaded = ShortcutMap(json: map.json)
        XCTAssertEqual(loaded.combo(for: .newTab)?.display, "⌥⌘Y")
        XCTAssertNil(loaded.combo(for: .stop), "turned off")
        XCTAssertTrue(loaded.isCustom(.newTab))
        map.set(ShortcutAction.newTab.defaultCombo, for: .newTab)
        XCTAssertFalse(map.isCustom(.newTab), "choosing the default again removes the override")
        map.resetAll()
        XCTAssertEqual(map, ShortcutMap())
    }

    func testConflictsAreFoundAndBadSavedDataIsIgnored() {
        let map = ShortcutMap()
        XCTAssertEqual(map.conflict(for: ShortcutAction.reload.defaultCombo, excluding: .newTab), .reload)
        XCTAssertNil(map.conflict(for: ShortcutAction.reload.defaultCombo, excluding: .reload))
        let broken = ShortcutMap(json: #"{"newTab":"nonsense","madeUp":"cmd+x","reload":"cmd+e"}"#)
        XCTAssertEqual(broken.combo(for: .newTab), ShortcutAction.newTab.defaultCombo)
        XCTAssertEqual(broken.combo(for: .reload)?.display, "⌘E")
        XCTAssertEqual(ShortcutMap(json: "not json"), ShortcutMap())
    }
}
