import Security
import WebKit
import XCTest
@testable import Browser_Setu

/// Sandbox, recovery, lifecycle and policy regression tests. Needs scripts/testserver.py on :18765.
@MainActor
final class HardeningTests: XCTestCase {
    let base = "http://127.0.0.1:18765"
    var root = ""

    override func setUp() async throws {
        root = NSTemporaryDirectory() + "bs-hard-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try await fetch("/_reset")
    }

    override func tearDown() async throws {
        Dialogs.testHandler = nil
        try? FileManager.default.removeItem(atPath: root)
    }

    func fetch(_ path: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + path)!)
        return String(decoding: data, as: UTF8.self)
    }

    func makeModel(profile: String = "default") -> BrowserModel { BrowserModel(engine: WebKitEngine(), root: root, profile: profile) }

    func waitUntil(_ seconds: Double = 15, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    func entitlement(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let v = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        return (v as? Bool) == true
    }

    // MARK: Stage 1 - sandbox, measured on the process that actually runs these tests

    func testRunningProcessIsSandboxedWithExpectedEntitlements() {
        XCTAssertTrue(entitlement("com.apple.security.app-sandbox"), "process is not sandboxed")
        XCTAssertTrue(entitlement("com.apple.security.network.client"))
        XCTAssertTrue(entitlement("com.apple.security.files.downloads.read-write"))
        XCTAssertTrue(entitlement("com.apple.security.device.camera"))
        XCTAssertTrue(entitlement("com.apple.security.device.audio-input"))
        XCTAssertFalse(entitlement("com.apple.security.network.server"), "should not accept inbound connections")
        XCTAssertFalse(entitlement("com.apple.security.files.all"))
        XCTAssertTrue(NSHomeDirectory().contains("/Library/Containers/"), "home is not a sandbox container: \(NSHomeDirectory())")
    }

    // Enforcement (blocked Documents/Desktop, no writes outside the container) is verified against the
    // normally launched app by scripts/sandbox-check.sh; Xcode's test host is granted extra access.

    // MARK: Stage 2 - WebKit behaviour

    func testDownloadCancellationRemovesPartialFileAndRecordsNothing() async throws {
        let model = makeModel()
        _ = model.openTab(url: URL(string: base + "/slow.bin"), isPrivate: false)
        let started = await waitUntil(15) { !model.downloads.active.isEmpty }
        XCTAssertTrue(started, "slow download never started")
        let name = model.downloads.active.values.first?.filename ?? "slow.bin"
        let path = DownloadCoordinator.directory.appendingPathComponent(name).path
        model.downloads.cancelAll()
        let cleared = await waitUntil(10) { model.downloads.active.isEmpty }
        XCTAssertTrue(cleared, "download still active after cancel")
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "partial file left behind: \(path)")
        XCTAssertTrue(model.downloads.completed.isEmpty)
        XCTAssertEqual(try model.core.listDownloads(limit: 5).count, 0, "cancelled download was recorded")
    }

    func testDownloadFilenameCollisionNeverOverwrites() throws {
        let dir = URL(fileURLWithPath: root)
        let a = DownloadCoordinator.uniqueURL(in: dir, name: "report.pdf")
        XCTAssertEqual(a.lastPathComponent, "report.pdf")
        try Data("first".utf8).write(to: a)
        let b = DownloadCoordinator.uniqueURL(in: dir, name: "report.pdf")
        XCTAssertEqual(b.lastPathComponent, "report (1).pdf")
        try Data("second".utf8).write(to: b)
        let c = DownloadCoordinator.uniqueURL(in: dir, name: "report.pdf")
        XCTAssertEqual(c.lastPathComponent, "report (2).pdf")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "first")
        for hostile in ["../../x", "/etc/passwd", "a/b/c.txt", "....", ""] {
            let n = DownloadCoordinator.safeName(hostile)
            XCTAssertFalse(n.contains("/"), hostile)
            XCTAssertFalse(n.isEmpty)
        }
    }

    func testRedirectToFileSchemeIsNeverRendered() async throws {
        let model = makeModel()
        let tab = model.openTab(url: URL(string: base + "/redirect-file"), isPrivate: false)
        let settled = await waitUntil(10) { model.notice != nil || tab.isShowingError }
        XCTAssertTrue(settled, "redirect to file:// neither blocked by policy nor refused by WebKit")
        XCTAssertFalse(tab.engine.currentURL?.isFileURL ?? false, "file:// page was rendered")
        XCTAssertFalse(tab.title.contains("localhost"), "file contents rendered")
        XCTAssertTrue(try model.core.recentHistory(limit: 5).allSatisfy { !$0.url.hasPrefix("file:") })
    }

    func testBenignRedirectRecordsOnlyFinalURL() async throws {
        let model = makeModel()
        let tab = model.openTab(url: URL(string: base + "/redirect-page"), isPrivate: false)
        let ok = await waitUntil { tab.title == "Page Two" && !tab.isLoading }
        XCTAssertTrue(ok)
        let urls = try model.core.recentHistory(limit: 10).map(\.url)
        XCTAssertEqual(urls, [base + "/page2"])
    }

    func testRendererCrashIsolatedAndRecoverable() async throws {
        let model = makeModel()
        let a = model.openTab(url: URL(string: base + "/page"), isPrivate: false)
        let b = model.openTab(url: URL(string: base + "/page2"), isPrivate: false)
        let both = await waitUntil { !a.isLoading && !b.isLoading && a.title == "Page" && b.title == "Page Two" }
        XCTAssertTrue(both)
        try model.core.addBookmark(url: base + "/page", title: "keep", folder: "")
        // A genuine renderer crash cannot be induced from the sandbox (WebKit's process cannot be signalled
        // and the private kill hook does not produce a callback), so this exercises the app's own
        // termination handler. Real-crash behaviour remains NOT TESTED.
        a.engineProcessCrashed()
        let errored = await waitUntil(5) { a.isShowingError }
        XCTAssertTrue(errored, "tab did not show a crash page")
        XCTAssertEqual(b.title, "Page Two", "other tab affected by crash")
        XCTAssertEqual(try model.core.listBookmarks(query: "").count, 1, "browser data damaged")
        let settled = await waitUntil(10) { !a.isLoading }
        XCTAssertTrue(settled, "error page never finished loading")
        a.reload()
        let recovered = await waitUntil(15) { a.title == "Page" && !a.isShowingError && !a.isLoading }
        XCTAssertTrue(recovered, "reload did not recover: title=\(a.title) err=\(a.isShowingError) loading=\(a.isLoading)")
    }

    func testPermissionPromptShowsOriginAndKinds() async throws {
        let model = makeModel()
        var seen: [(String, [String])] = []
        Dialogs.testHandler = { title, _, buttons in
            seen.append((title, buttons))
            return buttons.firstIndex(of: "Always Allow") ?? 0
        }
        let origin = "https://prompt.example"
        let ok = await model.resolvePermission(origin: origin, kinds: [.camera, .microphone], isPrivate: false)
        XCTAssertTrue(ok)
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(seen[0].0.contains(origin), "origin missing from prompt: \(seen[0].0)")
        XCTAssertTrue(seen[0].0.contains("camera and microphone"), seen[0].0)
        XCTAssertEqual(seen[0].1, ["Allow", "Allow for an Hour", "Allow for This Session", "Always Allow", "Don’t Allow"])
        // Remembered: no second prompt.
        let again = await model.resolvePermission(origin: origin, kinds: [.camera], isPrivate: false)
        XCTAssertTrue(again)
        XCTAssertEqual(seen.count, 1, "prompted again despite stored choice")
        // Private: only Allow / Don't Allow, never persisted.
        let priv = await model.resolvePermission(origin: "https://private.example", kinds: [.microphone], isPrivate: true)
        XCTAssertTrue(priv)
        XCTAssertEqual(seen.last?.1, ["Allow", "Don’t Allow"])
        XCTAssertFalse(try model.core.listPermissions().contains { $0.origin == "https://private.example" })
        // Insecure origins are refused without asking.
        let before = seen.count
        let insecure = await model.resolvePermission(origin: "http://insecure.example", kinds: [.camera], isPrivate: false)
        XCTAssertFalse(insecure)
        XCTAssertEqual(seen.count, before)
        // Deny is respected.
        Dialogs.testHandler = { _, _, buttons in buttons.count - 1 }
        let denied = await model.resolvePermission(origin: "https://deny.example", kinds: [.camera], isPrivate: false)
        XCTAssertFalse(denied)
    }

    func testPrivateTabDataIsGoneAfterLastPrivateTabCloses() async throws {
        let model = makeModel()
        let p1 = model.openTab(url: URL(string: base + "/cookie/LIFECYCLE1"), isPrivate: true)
        let ok = await waitUntil { p1.title == "Cookie" && !p1.isLoading }
        XCTAssertTrue(ok)
        let before = await model.engine.cookies(profile: model.profileName, isPrivate: true)
        XCTAssertTrue(before.contains { $0.value == "LIFECYCLE1" })
        model.closeTab(id: p1.id)
        let p2 = model.openTab(url: nil, isPrivate: true)
        let after = await model.engine.cookies(profile: model.profileName, isPrivate: true)
        _ = p2
        XCTAssertFalse(after.contains { $0.value == "LIFECYCLE1" }, "private cookie survived session end")
    }

    func testHTTPSUpgradeIsConfigured() async throws {
        let model = makeModel()
        let engine = try XCTUnwrap(model.engine as? WebKitEngine)
        let config = engine.makeConfiguration(isPrivate: false, profile: model.profileName)
        XCTAssertTrue(config.upgradeKnownHostsToHTTPS)
        XCTAssertTrue(engine.makeConfiguration(isPrivate: true, profile: model.profileName).upgradeKnownHostsToHTTPS)
    }

    // MARK: Stage 2 - corrupt database recovery

    func testCorruptProfileEntersExplicitRecoveryAndPreservesOriginal() async throws {
        let dir = root + "/profiles/broken"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let original = Data("garbage garbage garbage garbage".utf8)
        let dbPath = dir + "/browser.db"
        try original.write(to: URL(fileURLWithPath: dbPath))

        let model = makeModel(profile: "broken")
        XCTAssertNotNil(model.recovery, "recovery state must be explicit, not a silent empty profile")
        XCTAssertEqual(model.recovery?.profile, "broken")

        // Temporary session works but writes nothing to disk and never touches the original.
        let tab = model.openTab(url: URL(string: base + "/page"), isPrivate: false)
        let ok = await waitUntil { tab.title == "Page" && !tab.isLoading }
        XCTAssertTrue(ok)
        try model.core.addBookmark(url: "https://temp.example", title: "temp", folder: "")
        model.saveNow()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dbPath)), original, "original database was modified")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath + "-wal"))

        // Explicit reset moves the data aside (never deletes) and starts clean.
        XCTAssertTrue(model.resetUnreadableProfile())
        XCTAssertNil(model.recovery)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root + "/recovered")
        XCTAssertEqual(backups.count, 1)
        let saved = try Data(contentsOf: URL(fileURLWithPath: root + "/recovered/\(backups[0])/browser.db"))
        XCTAssertEqual(saved, original, "backup does not match the original bytes")
        XCTAssertTrue(try model.core.listBookmarks(query: "").isEmpty, "temporary data leaked into the new profile")
        try model.core.addBookmark(url: "https://real.example", title: "real", folder: "")
        XCTAssertEqual(try BrowserCore.open(root: root, profile: "broken").listBookmarks(query: "").count, 1)
    }

    func testNewerSchemaProfileIsNotModifiedByTheApp() async throws {
        let dir = root + "/profiles/future"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/browser.db"
        // Build a database stamped with a schema version this build does not know.
        let tmp = try BrowserCore.open(root: root, profile: "future")
        drop(tmp)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        // SQLite header: user_version is a big-endian u32 at offset 60.
        bytes.replaceSubrange(60..<64, with: [0, 0, 0, 99])
        try bytes.write(to: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let model = makeModel(profile: "future")
        XCTAssertNotNil(model.recovery)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "newer database was modified")
    }

    func drop(_ x: Any) {}
}
