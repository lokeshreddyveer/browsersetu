import XCTest
import WebKit
@testable import Browser_Setu

/// The test fixtures that used to write outside the test process's isolated environment: named preference suites (always kept by `cfprefsd` in the person's real
/// `~/Library/Preferences`) and web views on WebKit's default store (whose temporary files live in the per-user temporary folder under the app's bundle id).
/// The person's files are only looked at here (existence, size, date, contents, folder listing); nothing outside the test process is written, moved or deleted.
@MainActor
final class LegacyTestIsolationTests: XCTestCase {
    private var realPreferences: String { TestIsolation.realHome + "/Library/Preferences" }
    private var sharedWebKitTemporary: String { NSTemporaryDirectory() + "com.browsersetu.mac/WebKit" }

    private struct FileState: Equatable { let exists: Bool; let size: Int; let modified: Date?; let bytes: Data? }
    private func state(_ path: String) -> FileState {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return FileState(exists: attributes != nil, size: (attributes?[.size] as? Int) ?? 0, modified: attributes?[.modificationDate] as? Date, bytes: FileManager.default.contents(atPath: path))
    }
    private func listing(_ folder: String) -> [String: Date] {
        var out: [String: Date] = [:]
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return out }
        while let name = walker.nextObject() as? String {
            out[name] = (try? FileManager.default.attributesOfItem(atPath: folder + "/" + name))?[.modificationDate] as? Date ?? .distantPast
        }
        return out
    }
    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }   // cfprefsd writes after the call returns

    // MARK: Preferences

    /// Every kind of write a test makes through an isolated suite leaves no file with that suite's name in the person's Preferences folder (the old suites each left one).
    func testIsolatedSuitesNeverReachThePersonsPreferencesFolder() {
        final class Counting: IsolatedTestDefaults { var writes = 0; override func set(_ value: Any?, forKey key: String) { writes += 1; super.set(value, forKey: key) } }
        let name = "bs.legacy-isolation.\(UUID().uuidString)", subName = "bs.legacy-isolation.sub.\(UUID().uuidString)"
        let path = realPreferences + "/\(name).plist", subPath = realPreferences + "/\(subName).plist"
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let d = IsolatedTestDefaults(suiteName: name)!
        d.set("v", forKey: "s"); d.set(true, forKey: "b"); d.set(3, forKey: "i"); d.set(1.5, forKey: "d"); d.set(["x"], forKey: "l"); d.set(["k": 1], forKey: "m")
        d.set(URL(string: "https://example.org/")!, forKey: "u"); d.setPersistentDomain(["p": "q"], forName: name)
        XCTAssertEqual(d.string(forKey: "s"), "v"); XCTAssertTrue(d.bool(forKey: "b")); XCTAssertEqual(d.integer(forKey: "i"), 3); XCTAssertEqual(d.double(forKey: "d"), 1.5)
        XCTAssertEqual(d.stringArray(forKey: "l"), ["x"]); XCTAssertEqual(d.dictionary(forKey: "m") as? [String: Int], ["k": 1]); XCTAssertEqual(d.url(forKey: "u")?.host, "example.org")
        d.removeObject(forKey: "s"); d.removeObject(forKey: "never-there"); _ = d.synchronize(); d.removePersistentDomain(forName: name)
        let sub = Counting(suiteName: subName)!
        sub.set("w", forKey: "k"); XCTAssertEqual(sub.writes, 1); XCTAssertEqual(sub.string(forKey: "k"), "w")
        settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "an isolated suite wrote the person's Preferences folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: subPath), "a subclass of an isolated suite wrote the person's Preferences folder")
    }

    /// A suite made again with the same name sees what the first one wrote (as a real suite would within a process); removing the domain clears it for both; another name shares nothing.
    func testASuiteMadeAgainWithTheSameNameKeepsItsValues() {
        let name = "bs.legacy-isolation.again.\(UUID().uuidString)"
        let first = IsolatedTestDefaults(suiteName: name)!
        first.set("kept", forKey: "k")
        let again = IsolatedTestDefaults(suiteName: name)!
        XCTAssertEqual(again.string(forKey: "k"), "kept")
        XCTAssertNil(IsolatedTestDefaults(suiteName: name + ".other")!.string(forKey: "k"))
        again.removePersistentDomain(forName: name)
        XCTAssertNil(first.string(forKey: "k"))
        first.register(defaults: ["r": "registered"]); first.set("w", forKey: "r"); first.removeObject(forKey: "r")
        XCTAssertEqual(first.string(forKey: "r"), "registered", "a removed value shows the registered one again")
    }

    // MARK: WebKit

    /// Pages in both isolated stores, media element included, leave the shared WebKit temporary folder as it was (absent stays absent; present stays unchanged). A web view on the
    /// default store is what made it (checked when this was found; not repeated here, because doing so would write the person's folder).
    func testIsolatedWebKitStoresLeaveTheSharedTemporaryFolderAlone() async throws {
        let before = listing(sharedWebKitTemporary), existed = FileManager.default.fileExists(atPath: sharedWebKitTemporary)
        for configuration in [IsolatedWebKit.ephemeralConfiguration(), IsolatedWebKit.persistentConfiguration()] {
            // Never compared with `WKWebsiteDataStore.default()`: asking for the default store is enough to make WebKit create the shared folder.
            let store = configuration.websiteDataStore
            XCTAssertTrue(!store.isPersistent || store.identifier != nil, "not an isolated store")
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
            web.loadHTMLString("<html><body><video preload=auto></video><script>localStorage.setItem('k','v'); document.title='ok'</script></body></html>", baseURL: URL(string: "https://isolation.stage3.invalid/"))
            let end = Date().addingTimeInterval(8)
            while web.title != "ok", Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertEqual(web.title, "ok")
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(FileManager.default.fileExists(atPath: sharedWebKitTemporary), existed, "an isolated store made the shared WebKit temporary folder")
        XCTAssertEqual(listing(sharedWebKitTemporary), before, "an isolated store changed the shared WebKit temporary folder")
        XCTAssertTrue(IsolatedWebKit.ephemeralConfiguration().websiteDataStore.isPersistent == false)
        XCTAssertTrue(IsolatedWebKit.persistentConfiguration().websiteDataStore.isPersistent)
    }

    // MARK: Keeping it that way

    /// No test file makes a preferences suite directly or a web view configuration that keeps WebKit's default store. A test that means to test the default store itself must be
    /// named in `defaultStoreTests` with the reason.
    func testNoTestFileGoesBackToTheSharedPreferencesOrTheDefaultWebKitStore() throws {
        let testsFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let defaultStoreTests: [String: String] = [:]
        var offences: [String] = []
        let files = FileManager.default.enumerator(at: testsFolder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 100, "the test sources were not found next to this file")
        for file in files where file.deletingLastPathComponent().lastPathComponent != "TestSupport" && file.lastPathComponent != "LegacyTestIsolationTests.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if code.contains("UserDefaults(suiteName:") { offences.append("\(file.lastPathComponent):\(i + 1): UserDefaults(suiteName:) (use IsolatedTestDefaults)") }
                if code.contains("WKWebsiteDataStore.default()"), defaultStoreTests[file.lastPathComponent] == nil { offences.append("\(file.lastPathComponent):\(i + 1): WKWebsiteDataStore.default()") }
                // A web view made without a configuration gets the default one, and with it the default store.
                if code.range(of: #"WKWebView\((frame: [^\n]*)?\)"#, options: .regularExpression) != nil, !code.contains("configuration:"), defaultStoreTests[file.lastPathComponent] == nil {
                    offences.append("\(file.lastPathComponent):\(i + 1): WKWebView without a configuration (use IsolatedWebKit)")
                }
                if code.contains("WKWebViewConfiguration()") {
                    let next = lines[i..<min(lines.count, i + 3)].joined(separator: "\n")
                    if !next.contains("websiteDataStore"), defaultStoreTests[file.lastPathComponent] == nil {
                        offences.append("\(file.lastPathComponent):\(i + 1): WKWebViewConfiguration() without a website data store (use IsolatedWebKit)")
                    }
                }
            }
        }
        XCTAssertEqual(offences, [], offences.joined(separator: "\n"))
    }
}
