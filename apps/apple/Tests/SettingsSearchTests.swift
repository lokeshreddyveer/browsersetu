import XCTest
@testable import Browser_Setu

/// Settings search: every result names a real pane and a real section of it, so choosing it can scroll to the setting.
final class SettingsSearchTests: XCTestCase {
    private func windowSource() throws -> String {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent("macOS/Settings/SettingsWindow.swift"), encoding: .utf8)
    }

    func testEveryEntryHasASectionAndNothingIsLeftOver() {
        let titles = Set(SettingsIndex.entries.map(\.title))
        XCTAssertEqual(titles.count, SettingsIndex.entries.count, "titles are the ids, so they must be unique")
        XCTAssertEqual(Set(SettingsIndex.macSections.keys), titles, "an entry with no section, or a section for an entry that is gone")
    }

    func testEveryEntryNamesARealMacPane() {
        let panes = Set(SettingsPanel.allCases.map(\.rawValue))
        for entry in SettingsIndex.entries { XCTAssertTrue(panes.contains(entry.mac), "\(entry.title) names the pane \"\(entry.mac)\"") }
    }

    func testEverySectionIsInThePaneTheEntrySaysHoldsIt() throws {
        let source = try windowSource()
        guard let start = source.range(of: "@ViewBuilder private var content: some View {"),
              let end = source.range(of: "/// Horizontal strip or vertical sidebar", range: start.upperBound..<source.endIndex) else { return XCTFail("the pane content was not found") }
        let content = String(source[start.upperBound..<end.lowerBound])
        // "case .general:" ... up to the next "case ." (or the end).
        var paneBodies: [String: String] = [:]
        let parts = content.components(separatedBy: "        case .").dropFirst()
        for part in parts {
            guard let colon = part.firstIndex(of: ":") else { continue }
            paneBodies[String(part[part.startIndex..<colon])] = part
        }
        for entry in SettingsIndex.entries {
            guard let section = SettingsIndex.macSection(for: entry) else { XCTFail("\(entry.title) has no section"); continue }
            XCTAssertTrue(paneBodies[entry.mac]?.contains("\(section)(") == true, "\(entry.title): \(section) is not in the \(entry.mac) pane")
            XCTAssertTrue(paneBodies[entry.mac]?.contains(".settingsAnchor(\"\(section)\")") == true, "\(section) is not given an anchor, so a result could not scroll to it")
        }
    }

    func testSearchStillRanksTitlesFirstAndNeedsEveryWord() {
        XCTAssertEqual(SettingsIndex.search("proxy").first?.title, "Use a Proxy")
        XCTAssertTrue(SettingsIndex.search("proxy zzzzzz").isEmpty)
        XCTAssertTrue(SettingsIndex.search("   ").isEmpty)
    }

    func testChoosingTheSameSectionTwiceIsANewRequest() {
        XCTAssertNotEqual(SettingsReveal(section: "ProxySection"), SettingsReveal(section: "ProxySection"))
    }
}
