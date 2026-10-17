import XCTest
@testable import Browser_Setu

/// Loads real sites and prints how long each took and how much memory the app held afterwards. It uses the network, so it only runs when asked:
/// `BS_REAL_PAGES=1` in the test environment. The numbers describe this build on this machine and connection; they are not a comparison with another browser.
@MainActor
final class RealPagePerformanceTests: XCTestCase {
    func testRealPages() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BS_REAL_PAGES"] == "1" || FileManager.default.fileExists(atPath: "/tmp/bs-real-pages"), "set BS_REAL_PAGES=1 to run")
        let sites = ["https://www.wikipedia.org/", "https://en.wikipedia.org/wiki/Web_browser", "https://news.ycombinator.com/", "https://www.bbc.com/", "https://github.com/", "https://www.apple.com/"]
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-real-\(UUID().uuidString)", profile: "default")
        await model.start()
        let base = currentMemoryFootprint()
        var results: [(String, Double?)] = []
        for site in sites {
            let tab = model.openTab(url: URL(string: site)!, isPrivate: false)
            let start = Date()
            var done = false
            for _ in 0..<120 { try? await Task.sleep(for: .milliseconds(250)); if !tab.isLoading, tab.progress >= 1 || tab.url != nil, Date().timeIntervalSince(start) > 0.5 { done = true; break } }
            results.append((site, done ? Date().timeIntervalSince(start) * 1000 : nil))
            print("PERF page \(site) = \(results.last!.1.map { String(format: "%.0f ms", $0) } ?? "did not finish in 30 s")")
        }
        try? await Task.sleep(for: .seconds(2))
        print("PERF app-memory-after-\(sites.count)-real-tabs-MB = \(Double(Int64(currentMemoryFootprint()) - Int64(base)) / 1_048_576)")
        let slow = results.filter { ($0.1 ?? .infinity) > 15_000 }
        XCTAssertTrue(slow.isEmpty, "pages that took over 15 s or never finished: \(slow.map(\.0))")
    }
}
