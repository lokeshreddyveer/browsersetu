import XCTest
@testable import Browser_Setu

/// Opens each site in scripts/compat-sites.txt and checks that a page came up (a title, no error page). It needs the network, so it only
/// runs when asked: `BS_COMPAT=1`. Run it before a release and read the failures by hand: a bank may refuse an automated visit, and a
/// failure here means "look at this site", not always "the browser is broken".
@MainActor
final class CompatibilityTests: XCTestCase {
    func testEverydaySitesOpen() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BS_COMPAT"] == "1", "set BS_COMPAT=1 to visit real sites")
        let listURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/compat-sites.txt")
        let lines = try String(contentsOf: listURL, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-compat-\(UUID().uuidString)", profile: "default")
        await model.start()
        var failures: [String] = []
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let address = parts.first, let url = URL(string: address) else { continue }
            let tab = model.openTab(url: url, isPrivate: false)
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, tab.isLoading || tab.title.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            if tab.title.isEmpty || tab.url == nil { failures.append("\(address): nothing loaded (\(parts.last ?? ""))") }
            model.closeTab(id: tab.id)
        }
        XCTAssertTrue(failures.isEmpty, "Look at these by hand:\n" + failures.joined(separator: "\n"))
    }
}
