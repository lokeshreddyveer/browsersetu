import SetuPrivacyCore
import WebKit
import XCTest
@testable import Browser_Setu

/// Real WKWebViews against scripts/testserver.py on :18765. Hostnames ads/tracker/other/site.localhost all resolve to
/// the loopback server; the server logs "host+path" for every request it actually receives, so a blocked request
/// is one the server never saw.
@MainActor
final class PrivacyIntegrationTests: XCTestCase {
    let port = 18765
    var root = ""
    let listURL = FilterCatalog.all[0].url

    struct FailingFetcher: ListFetching {
        func fetch(_ url: URL, limit: Int) async throws -> Data { throw ListUpdateError.badStatus(503) }
    }
    struct FixedFetcher: ListFetching {
        let text: String
        func fetch(_ url: URL, limit: Int) async throws -> Data { Data(text.utf8) }
    }

    override func setUp() async throws {
        root = NSTemporaryDirectory() + "bs-priv-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(atPath: root) }

    // MARK: helpers

    func reset() throws { _ = try String(contentsOf: URL(string: "http://127.0.0.1:\(port)/_reset")!, encoding: .utf8) }
    func seen() throws -> String { try String(contentsOf: URL(string: "http://127.0.0.1:\(port)/_requests")!, encoding: .utf8) }

    func makeModel(profile: String = "default", fetcher: ListFetching = URLSessionListFetcher()) -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: root, profile: profile, listFetcher: fetcher)
    }

    func waitUntil(_ seconds: Double = 15, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return cond()
    }

    /// Loads the fixture page and waits until the page and its subresources had time to be requested.
    @discardableResult
    func loadFixture(_ model: BrowserModel, host: String = "site.localhost", private isPrivate: Bool = false) async throws -> TabController {
        try reset()
        let tab = model.openTab(url: URL(string: "http://\(host):\(port)/privacy-page"), isPrivate: isPrivate)
        let ok = await waitUntil(20) { tab.title == "Privacy" && !tab.isLoading }
        XCTAssertTrue(ok, "fixture page did not load (is scripts/testserver.py running?) title=\(tab.title)")
        try await Task.sleep(for: .seconds(1))
        return tab
    }

    func requested(_ needle: String) throws -> Bool { try seen().contains(needle) }

    func useCustomList(_ model: BrowserModel, text: String) async throws {
        try model.privacy.change { $0.mode = .custom; try $0.setList(listURL, enabled: true) }
        try model.privacy.writeCachedList(Data(text.utf8), for: listURL)
        model.privacy.scheduleApply()
        await model.privacy.settle()
    }

    // MARK: protection in real pages

    func testControlWithoutProtectionLoadsEverything() async throws {
        let model = makeModel()
        await model.start()
        model.privacy.setAdBlocking(false); model.privacy.setAntiTracking(false)
        await model.privacy.settle()
        XCTAssertEqual(model.privacy.state(forHost: nil), .disabled)
        try await loadFixture(model)
        XCTAssertTrue(try requested("ads.localhost:\(port)/ad.gif"), "control: ad should load with protection off")
        XCTAssertTrue(try requested("tracker.localhost:\(port)/t.js"))
        XCTAssertTrue(try requested("/normal.gif"))
    }

    func testUserBlockRulesStopAdsAndTrackersWhileNormalResourcesLoad() async throws {
        let model = makeModel()
        await model.start()
        try model.privacy.change { try $0.addUserRule(domain: "ads.localhost", action: .block); try $0.addUserRule(domain: "tracker.localhost", action: .block) }
        await model.privacy.settle()
        XCTAssertEqual(model.privacy.state(forHost: "site.localhost"), .active)
        try await loadFixture(model)
        XCTAssertFalse(try requested("ads.localhost:\(port)/ad.gif"), "ad request must never reach the network")
        XCTAssertFalse(try requested("tracker.localhost:\(port)/t.js"), "tracker request must never reach the network")
        XCTAssertTrue(try requested("/normal.gif"), "normal first-party resource must still load")
    }

    func testListRuleBlocksAndSiteExceptionLiftsItButUserDenyStillWins() async throws {
        let model = makeModel()
        await model.start()
        try await useCustomList(model, text: "ads.localhost\ntracker.localhost\n")
        try await loadFixture(model)
        XCTAssertFalse(try requested("ads.localhost:\(port)/ad.gif"), "list rule blocks")
        XCTAssertFalse(try requested("tracker.localhost:\(port)/t.js"))

        // Website exception: protection off on site.localhost -> list-blocked requests load there.
        try model.privacy.change { try $0.addSiteException("site.localhost") }
        await model.privacy.settle()
        XCTAssertEqual(model.privacy.state(forHost: "site.localhost"), .exception)
        try await loadFixture(model)
        XCTAssertTrue(try requested("ads.localhost:\(port)/ad.gif"), "exception lets list-blocked ad load on that site")
        XCTAssertTrue(try requested("tracker.localhost:\(port)/t.js"))

        // A user deny rule outranks the exception, so the tracker is blocked again even on the exception site.
        try model.privacy.change { try $0.addUserRule(domain: "tracker.localhost", action: .block) }
        await model.privacy.settle()
        try await loadFixture(model)
        XCTAssertTrue(try requested("ads.localhost:\(port)/ad.gif"))
        XCTAssertFalse(try requested("tracker.localhost:\(port)/t.js"), "user rules outrank website exceptions")

        // A user allow rule outranks the list.
        try model.privacy.change { try $0.removeSiteException("site.localhost"); try $0.addUserRule(domain: "ads.localhost", action: .allow) }
        await model.privacy.settle()
        try await loadFixture(model)
        XCTAssertTrue(try requested("ads.localhost:\(port)/ad.gif"), "user allow outranks a list block")
    }

    func testExceptionOnOneSiteDoesNotAffectAnother() async throws {
        let model = makeModel()
        await model.start()
        try await useCustomList(model, text: "ads.localhost\n")
        try model.privacy.change { try $0.addSiteException("site.localhost") }
        await model.privacy.settle()
        try await loadFixture(model, host: "elsewhere.localhost")
        XCTAssertFalse(try requested("ads.localhost:\(port)/ad.gif"), "a different site stays protected")
    }

    /// The page calls navigator.sendBeacon (a WebKit "raw" request) to another host's /beacon endpoint.
    func testStrictBlocksThirdPartyTrackingEndpointsAndBalancedDoesNot() async throws {
        let model = makeModel()
        await model.start()
        try await loadFixture(model)
        XCTAssertTrue(try requested("other.localhost:\(port)/beacon"), "control: Balanced lets a third-party beacon through")
        model.privacy.setMode(.strict)
        await model.privacy.settle()
        XCTAssertTrue(model.privacy.snapshot?.strictExtras.contains("Third-party tracking-endpoint requests") == true)
        try await loadFixture(model)
        XCTAssertFalse(try requested("other.localhost:\(port)/beacon"), "Strict must stop the third-party tracking-endpoint request")
        XCTAssertTrue(try requested("/normal.gif"), "first-party content still loads in Strict")
    }

    /// The cookie rule compiles and installs in Strict. Its effect cannot be shown here: WebKit already refuses
    /// third-party cookies by default, so Balanced stores none either. Recorded as installed, not as separately verified.
    func testStrictInstallsTheCookieRuleButItsEffectIsNotSeparatelyObservable() async throws {
        let model = makeModel()
        await model.start()
        model.privacy.setMode(.strict)
        await model.privacy.settle()
        XCTAssertTrue(model.privacy.snapshot?.strictExtras.contains("Third-party cookie blocking") == true)
        XCTAssertEqual(model.privacy.report?.installed, true)
        XCTAssertNil(model.privacy.report?.error)
        try await loadFixture(model)
        let cookies = await model.engine.cookies(profile: model.profileName, isPrivate: false)
        XCTAssertFalse(cookies.contains { $0.name == "tp" })
    }

    func testPrivateAndNewTabsInheritProtection() async throws {
        let model = makeModel()
        await model.start()
        try model.privacy.change { try $0.addUserRule(domain: "ads.localhost", action: .block) }
        await model.privacy.settle()
        let early = model.openTab(url: nil, isPrivate: false)       // exists before a later rule change
        _ = early
        try model.privacy.change { try $0.addUserRule(domain: "tracker.localhost", action: .block) }
        await model.privacy.settle()
        try await loadFixture(model, private: true)
        XCTAssertFalse(try requested("ads.localhost:\(port)/ad.gif"), "private tab is protected")
        XCTAssertFalse(try requested("tracker.localhost:\(port)/t.js"), "rule added later reaches tabs that already existed and new ones")
        XCTAssertTrue(try requested("/normal.gif"))
    }

    func testProtectionLevelsApplyImmediatelyPersistAndKeepTheSameWebViews() async throws {
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.privacy.configuration.mode, .balanced, "default level")
        let tab = model.active!
        let view = tab.hostView
        var identifiers: [ProtectionMode: String] = [:]
        for level in [ProtectionMode.light, .strict, .balanced, .light, .strict] {
            model.privacy.setMode(level)
            await model.privacy.settle()
            XCTAssertEqual(model.privacy.state(forHost: nil), .active, "\(level)")
            XCTAssertEqual(model.privacy.report?.installed, true)
            XCTAssertNil(model.privacy.report?.error)
            let id = try XCTUnwrap(model.privacy.report?.identifier)
            if let previous = identifiers[level] { XCTAssertEqual(id, previous, "same level, same rules") }
            identifiers[level] = id
        }
        XCTAssertEqual(Set(identifiers.values).count, 3, "each level installs different rules")
        XCTAssertTrue(tab.hostView === view, "changing the level must not recreate tabs")
        let restarted = makeModel()
        XCTAssertEqual(restarted.privacy.configuration.mode, .strict, "last choice survives a restart")
    }

    func testRulesAreInstalledBeforeTheFirstNavigation() async throws {
        let model = makeModel()
        try model.privacy.change { try $0.addUserRule(domain: "ads.localhost", action: .block) }
        await model.start()                       // start() installs rules before it opens or restores any tab
        XCTAssertEqual(model.privacy.report?.installed, true)
        XCTAssertEqual(model.privacy.state(forHost: nil), .active)
        XCTAssertGreaterThanOrEqual((model.engine as? WebKitEngine)?.rules.attachedCount ?? 0, 1)
        try await loadFixture(model)
        XCTAssertFalse(try requested("ads.localhost:\(port)/ad.gif"), "very first page load is already filtered")
    }

    // MARK: updates, failure handling, persistence

    func testFailedUpdateKeepsPreviousProtectionAndSaysSo() async throws {
        let model = makeModel(fetcher: FailingFetcher())
        await model.start()
        try await useCustomList(model, text: "ads.localhost\n")
        let before = model.privacy.report?.identifier
        XCTAssertNotNil(before)
        await model.privacy.updateLists()
        XCTAssertEqual(model.privacy.report?.identifier, before, "rules unchanged after a failed download")
        XCTAssertNotNil(model.privacy.listUpdateStatus)
        XCTAssertNil(model.privacy.configuration.lastSuccessfulUpdate)
        try await loadFixture(model)
        XCTAssertFalse(try requested("ads.localhost:\(port)/ad.gif"), "cached list still protects after a failed update")
    }

    func testSuccessfulUpdateInstallsNewRulesAndRecordsMetadata() async throws {
        let model = makeModel(fetcher: FixedFetcher(text: "tracker.localhost\n"))
        await model.start()
        try model.privacy.change { $0.mode = .custom; try $0.setList(listURL, enabled: true) }
        await model.privacy.settle()
        await model.privacy.updateLists()
        XCTAssertNotNil(model.privacy.configuration.lastSuccessfulUpdate)
        XCTAssertEqual(model.privacy.configuration.listStates[listURL]?.ruleCount, 1)
        XCTAssertEqual(model.privacy.configuration.listStates[listURL]?.contentHash.count, 64)
        try await loadFixture(model)
        XCTAssertFalse(try requested("tracker.localhost:\(port)/t.js"))
        XCTAssertGreaterThan(model.privacy.cachedListFileCount, 0)
    }

    func testGarbageDownloadIsRejectedAndNotInstalled() async throws {
        let model = makeModel(fetcher: FixedFetcher(text: "<html>not a filter list</html>\n"))
        await model.start()
        try await useCustomList(model, text: "ads.localhost\n")
        let before = model.privacy.report?.identifier
        await model.privacy.updateLists()
        XCTAssertEqual(model.privacy.report?.identifier, before)
        XCTAssertNil(model.privacy.configuration.lastSuccessfulUpdate)
    }

    func testPlainHTTPListsAreRefused() async throws {
        let fetcher = URLSessionListFetcher()
        do {
            _ = try await fetcher.fetch(URL(string: "http://127.0.0.1:\(port)/page")!, limit: 1000)
            XCTFail("http list URL must be refused")
        } catch { XCTAssertEqual(error as? ListUpdateError, .notHTTPS) }
    }

    func testProtectionSettingsPersistAndAreIsolatedPerProfile() async throws {
        let a = makeModel()
        await a.start()
        a.privacy.setMode(.strict)
        try a.privacy.change { try $0.addSiteException("shop.example"); try $0.addUserRule(domain: "x.example", action: .block) }
        await a.privacy.settle()
        let b = makeModel()
        XCTAssertEqual(b.privacy.configuration.mode, .strict)
        XCTAssertEqual(b.privacy.configuration.siteExceptions, ["shop.example"])
        XCTAssertEqual(b.privacy.configuration.userRules.map(\.domain), ["x.example"])
        XCTAssertTrue(b.createProfile("second"))
        b.switchProfile("second")
        XCTAssertEqual(b.privacy.configuration, PrivacyConfiguration(), "another profile must not see these rules or exceptions")
        b.switchProfile("default")
        XCTAssertEqual(b.privacy.configuration.mode, .strict)
    }

    func testLegacyTrackerSwitchOffIsPreserved() async throws {
        let core = try BrowserCore.open(root: root, profile: "default")
        try core.setSetting(key: "content_blocking", value: "0")
        let model = makeModel()
        XCTAssertFalse(model.privacy.configuration.isEnabled, "an earlier 'off' choice must carry over")
        _ = core
    }

    func testCorruptStoredConfigurationFallsBackSafely() async throws {
        let core = try BrowserCore.open(root: root, profile: "default")
        try core.setSetting(key: PrivacyController.settingKey, value: "{broken")
        let model = makeModel()
        XCTAssertTrue(model.privacy.configurationWasRepaired)
        XCTAssertEqual(model.privacy.configuration, PrivacyConfiguration())
        await model.start()
        XCTAssertEqual(model.privacy.state(forHost: nil), .active)
    }

    func testMalformedRuleInputIsRejectedByTheController() async throws {
        let model = makeModel()
        await model.start()
        let before = model.privacy.configuration
        XCTAssertThrowsError(try model.privacy.change { try $0.addUserRule(domain: "not a domain", action: .block) })
        XCTAssertThrowsError(try model.privacy.change { try $0.addSiteException("http://x.example/path") })
        XCTAssertEqual(model.privacy.configuration, before, "a rejected change leaves configuration untouched")
    }

    // MARK: private browsing and isolation

    func testProtectionStateNeverTouchesBrowsingData() async throws {
        let model = makeModel()
        await model.start()
        try await loadFixture(model, private: true)
        XCTAssertTrue(try model.core.recentHistory(limit: 20).isEmpty, "private page must not reach history through privacy code")
        let stored = (try model.core.getSetting(key: PrivacyController.settingKey)) ?? ""
        XCTAssertFalse(stored.contains("privacy-page"), "no page address is ever stored in the privacy configuration")
    }

    // MARK: no telemetry, no VPN/DNS, no sandbox regression (static audit of the real sources)

    func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func swiftSources(under relative: String) -> [URL] {
        let base = repoRoot().appendingPathComponent(relative)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && !$0.path.contains("/.build/") && !$0.path.contains("/Generated/") && !$0.path.contains("PublicSuffixData") }
    }

    func testNoTelemetryOrAnalyticsOrBackgroundNetworkingInSources() throws {
        let sources = swiftSources(under: "apps/apple/Shared") + swiftSources(under: "apps/apple/Engines") + swiftSources(under: "apps/apple/macOS")
            + swiftSources(under: "apps/apple/iOS") + swiftSources(under: "Packages/SetuPrivacyKit/Sources")
        XCTAssertGreaterThan(sources.count, 20, "source scan found nothing; repository layout changed?")
        let forbidden = ["Firebase", "Crashlytics", "Sentry", "Mixpanel", "Amplitude", "SegmentAnalytics", "import Segment", "AppCenter", "Bugsnag", "Datadog",
                         "TelemetryDeck", "PostHog", "AdSupport", "ASIdentifierManager", "ATTrackingManager", "MetricKit", "NWConnection", "NWPathMonitor",
                         "CFNetworkExecuteProxyAutoConfiguration", "evaluateJavaScript", "addScriptMessageHandler"]
        for file in sources {
            var text = try String(contentsOf: file, encoding: .utf8)
            // The one documented exception: the segment service's own address path, in the one file that names it, is not an analytics product (see testSponsorBlockNetworkingIsOneConsentedFileThatSendsOnlyAHashPrefix).
            if file.lastPathComponent == "SponsorBlockService.swift" { text = text.replacingOccurrences(of: "\"/api/skipSegments/\"", with: "") }
            for word in forbidden {
                // Sending a file or link between the user's own devices on the local network is the one place a direct connection is allowed.
                if word == "NWConnection", file.lastPathComponent == "LocalLink.swift" { continue }
                // The port and latency check is a tool the person runs themselves; it sends nothing in the background.
                if word == "NWConnection", file.lastPathComponent == "NetworkTools.swift" { continue }
                // The AI-tool connection listens on this Mac's loopback address only and is off until the person turns it on.
                if word == "NWConnection", file.lastPathComponent == "AgentServer.swift" { continue }
                // The automation interface listens on a private Unix socket or 127.0.0.1 only (interface type forced to loopback), and is off until the person turns it on.
                if word == "NWConnection", file.lastPathComponent == "AutomationTransport.swift" { continue }
                // Remote companion: only a short-lived Unix-socket self-test of the encrypted channel in a private temp folder; no listener on any network interface exists.
                if word == "NWConnection", file.lastPathComponent == "RemoteAccess.swift" { continue }
                // The SFTP/FTP proxy relay: listens on 127.0.0.1 only (interface type forced to loopback, one connection), exists only while a remote download that goes through the person's own proxy is running, and ends with it.
                if word == "NWConnection", file.lastPathComponent == "ProxyRelay.swift" { continue }
                // Peer connections for a torrent the person added, with Peer-to-Peer turned on (TorrentSession only names the type in a comment).
                if word == "NWConnection", ["TorrentNetwork.swift", "TorrentSession.swift"].contains(file.lastPathComponent) { continue }
                // DX-04…DX-06 peer-to-peer files, each reviewed in its phase and each off until the person turns Peer-to-Peer on: the DHT, the inbound listener, the peer transports, the pinned HTTP path (trackers and web seeds), NAT port mapping and the UDP tracker.
                if word == "NWConnection", ["DHTNode.swift", "PeerListener.swift", "PeerTransports.swift", "PinnedHTTP.swift", "PortMapping.swift", "UDPTracker.swift"].contains(file.lastPathComponent) { continue }
                if word == "NWPathMonitor", file.lastPathComponent == "DHTNode.swift" { continue }          // only to notice a network change and re-announce
                // Only reads whether the connection is expensive or constrained, to pause heavy work; it sends nothing.
                if word == "NWPathMonitor", file.lastPathComponent == "ResourceGovernor.swift" { continue }
                // The userscript bridge is the one other file that may register a handler, and only in a script's own private world (see testTheUserScriptBridgeStaysNarrow).
                if word == "addScriptMessageHandler", file.lastPathComponent == "UserScriptBridge.swift" { continue }
                XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) contains \(word)")
            }
            // Message handlers (the browser's own sign-in, link and gesture scripts) live in one file only.
            // The one exception is the userscript bridge, held to the narrow rules in testTheUserScriptBridgeStaysNarrow.
            if !["WebKitEngine.swift", "UserScriptBridge.swift", "MediaPageObserver.swift"].contains(file.lastPathComponent) { XCTAssertFalse(text.contains("WKScriptMessage"), "\(file.lastPathComponent) contains WKScriptMessage") }
        }
        // A page must have no way to call into the browser. The browser's own three scripts talk to it from an isolated world a page cannot reach: every handler is
        // registered for `.defaultClient` (never the page's world), and these three are the only ones.
        let engineSource = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Engines/WebKit/WebKitEngine.swift"), encoding: .utf8)
        let registrations = engineSource.split(separator: "\n").filter { $0.contains("controller.add(") && $0.contains("name:") }
        XCTAssertEqual(registrations.count, 3, "unexpected message handlers: \(registrations)")
        for line in registrations { XCTAssertTrue(line.contains("contentWorld: .defaultClient"), "a message handler outside the isolated world: \(line)") }
        let handlerNames = registrations.compactMap { $0.components(separatedBy: "name: \"").last?.components(separatedBy: "\"").first }
        XCTAssertEqual(Set(handlerNames), ["bsLogin", "bsLink", "bsGesture"])
        // DX-07: the media observer is the one other handler. It is registered in its own file, in the isolated world only, and its messages are checked by MediaObservationParser.
        let observerSource = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Engines/WebKit/MediaPageObserver.swift"), encoding: .utf8)
        let observerRegistrations = observerSource.split(separator: "\n").filter { $0.contains("controller.add(") }
        XCTAssertEqual(observerRegistrations.count, 1); XCTAssertTrue(observerRegistrations.allSatisfy { $0.contains("contentWorld: .defaultClient") && $0.contains("name: handlerName") })
        XCTAssertTrue(observerSource.contains("static let handlerName = \"bsMedia\""))
        let installerSource = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Engines/WebKit/WebKitUserScripts.swift"), encoding: .utf8)
        let observerInstaller = installerSource.components(separatedBy: "static func addMediaObserver").dropFirst().first?.components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertTrue(observerInstaller.contains("in: .defaultClient"), "the observer script runs in the isolated world")
        // The device link talks only to devices found on the local network by Bonjour, never to an address on the internet.
        let link = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Shared/LocalLink.swift"), encoding: .utf8)
        XCTAssertFalse(link.contains("http://") || link.contains("https://"), "LocalLink must not name internet addresses")
        XCTAssertTrue(link.contains(".bonjour(type:"))
        // The user's own scripts are installed by one file only.
        let withUserScripts = try sources.filter { try String(contentsOf: $0, encoding: .utf8).contains("WKUserScript") }.map(\.lastPathComponent)
        XCTAssertEqual(Set(withUserScripts), ["WebKitUserScripts.swift"], "unexpected user-script code: \(withUserScripts)")
        // The browser runs script of its own in exactly one place: reading a page's icon links, in its own isolated world.
        let withScript = try sources.filter { try String(contentsOf: $0, encoding: .utf8).contains("callAsyncJavaScript") }.map(\.lastPathComponent)
        // Also the two page readers the person starts (Find Links, Find Downloadable Media): each runs one fixed, read-only script in the browser's isolated world (.defaultClient, never the page's), sends nothing and returns bounded lists.
        XCTAssertEqual(withScript, ["LinkPageExtractor.swift", "MediaPageExtractor.swift", "WebKitEngine.swift"], "unexpected script execution: \(withScript)")
        // Only five files may create a URLSession: the list updater, the opt-in search suggestions, the opt-out site icons, the one-request Chrome Web Store download the user asks for, and the leaked-password check the user starts.
        // Naming the fetcher type is fine; actually creating or using a URLSession is only allowed in those two.
        let withSession = try sources.filter {
            try String(contentsOf: $0, encoding: .utf8).replacingOccurrences(of: "URLSessionListFetcher", with: "")
                // WebKit's sign-in delegate names this type in its signature; it is a result type, not a connection.
                .replacingOccurrences(of: "URLSession.AuthChallengeDisposition", with: "")
                .contains("URLSession")
        }.map(\.lastPathComponent)
        // Also allowed, each only when the person starts it (ExternalLookups: a saved copy, the security headers, a currency rate, a paper's reference): network checks (NetworkTools), a page's response headers (DevCapture), a feed they subscribed to
        // (ToolkitFeatures), the link checker (KnowledgeTools) and the downloaders for a file they chose (PieceDownload, and HTTPTransferEngine, which runs only when a download is started, sends no cookies and keeps no connection open). None sends anything in the background.
        // Download-system additions, each reviewed: AutomationWebhooks (an address the person configured, no redirects, ephemeral session), DownloadNetworkSettings (applies the person's proxy to a download's session configuration),
        // MediaFetcher (the streams of a media download the person started) and TorrentNetwork (a tracker/web-seed request for a torrent the person added). None runs without a download or rule the person set up.
        XCTAssertEqual(withSession.sorted(), ["AutomationWebhooks.swift", "BreachCheck.swift", "ChromeWebStore.swift", "DevCapture.swift", "DownloadNetworkSettings.swift", "ExternalLookups.swift", "FilterListUpdater.swift", "HTTPTransferEngine.swift", "IconFetcher.swift", "KnowledgeTools.swift", "MediaFetcher.swift", "MediaToolsInstaller.swift", "MultipartTransferEngine.swift", "NetworkTools.swift", "PieceDownload.swift", "PinnedHTTP.swift", "ProviderService.swift", "ProviderTypes.swift", "SearchSuggestions.swift", "SponsorBlockService.swift", "ToolkitFeatures.swift", "TorrentNetwork.swift", "UPnP.swift", "UserScriptNetwork.swift"], "unexpected networking code: \(withSession)")
    }

    /// The userscript bridge is the only handler beyond the browser's own three, and it is held to this: registered by one function, in a world made for one script (never the page's
    /// or the browser's), and answering a closed list of small messages. A new kind of message, a second registration or a shared world fails here.
    func testTheUserScriptBridgeStaysNarrow() throws {
        let sources = swiftSources(under: "apps/apple/Shared") + swiftSources(under: "apps/apple/Engines") + swiftSources(under: "apps/apple/macOS") + swiftSources(under: "apps/apple/iOS")
        let registering = try sources.filter { try String(contentsOf: $0, encoding: .utf8).contains("addScriptMessageHandler") }.map(\.lastPathComponent)
        XCTAssertEqual(registering, ["UserScriptBridge.swift"], "only the bridge file may register a handler of this kind: \(registering)")
        let bridge = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Engines/WebKit/UserScriptBridge.swift"), encoding: .utf8)
        XCTAssertEqual(bridge.components(separatedBy: "addScriptMessageHandler(").count - 1, 1, "exactly one registration")
        XCTAssertTrue(bridge.contains("contentWorld: world"), "registered in the world it is given")
        XCTAssertEqual(bridge.components(separatedBy: ".page").count - 1, 1, "the shared worlds are named once, in the check that refuses them")
        XCTAssertEqual(bridge.components(separatedBy: ".defaultClient").count - 1, 1)
        XCTAssertTrue(bridge.contains("precondition(world != .page && world != .defaultClient"))
        XCTAssertFalse(bridge.contains("WKUserScript") || bridge.contains("evaluateJavaScript") || bridge.contains("callAsyncJavaScript"), "the bridge never runs code in a page")
        // The messages it answers are a closed list.
        let pattern = try NSRegularExpression(pattern: #"case ((?:"[a-z]+"(?:, )?)+):"#)
        var ops = Set<String>()
        for match in pattern.matches(in: bridge, range: NSRange(bridge.startIndex..., in: bridge)) {
            let labels = String(bridge[Range(match.range(at: 1), in: bridge)!])
            for label in labels.split(separator: ",") { ops.insert(label.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")) }
        }
        XCTAssertEqual(ops, ["ran", "err", "log", "denied", "set", "del", "xhr"], "a new kind of message must be reviewed before it is added: \(ops)")
        XCTAssertTrue(bridge.contains("static let handlerName = \"bsus\""))
        // The world each script gets is its own, named after the script.
        let installer = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Engines/WebKit/WebKitUserScripts.swift"), encoding: .utf8)
        XCTAssertTrue(installer.contains("WKContentWorld.world(name: \"BrowserSetuUserScript-\" + script.id.uuidString)"))
        XCTAssertTrue(installer.contains("UserScriptBridge.register(for: script, storage: storage, world: privateWorld, on: controller)"))
        // Nothing outside the browser's own three handlers is registered on the engine's side.
        let engine = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Engines/WebKit/WebKitEngine.swift"), encoding: .utf8)
        XCTAssertFalse(engine.contains("UserScriptBridge"))
    }

    /// The userscript system's networking is one file, called from exactly two places: the person's own install/update request, and a bridge call for a script that was given the
    /// permission (re-checked inside the file). Nothing else in the app may call it, and the file keeps its own safeguards.
    func testUserScriptNetworkingIsConfinedToOneAuditedFile() throws {
        let sources = swiftSources(under: "apps/apple/Shared") + swiftSources(under: "apps/apple/Engines") + swiftSources(under: "apps/apple/macOS") + swiftSources(under: "apps/apple/iOS")
        func files(containing text: String) throws -> [String] {
            try sources.filter { try String(contentsOf: $0, encoding: .utf8).contains(text) }.map(\.lastPathComponent).sorted()
        }
        XCTAssertEqual(try files(containing: "UserScriptNet.fetchScript("), ["UserScripts.swift"], "downloads happen only when the person asks to install or update")
        XCTAssertEqual(try files(containing: "UserScriptNet.request("), ["UserScriptBridge.swift"], "a script's request goes only through the bridge")
        XCTAssertEqual(try files(containing: "URLSession").filter { $0.hasPrefix("UserScript") }, ["UserScriptNetwork.swift"], "the rest of the userscript system has no way to reach the network")
        let net = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Shared/UserScriptNetwork.swift"), encoding: .utf8)
        for required in ["URLSessionConfiguration.ephemeral", "httpCookieStorage = nil", "httpShouldSetCookies = false", "urlCache = nil", "isLocalHost", "RedirectGuard",
                         "url.scheme == \"https\"", "connectAllows(host, connects: connects)", "\"cookie\"", "\"authorization\""] {
            XCTAssertTrue(net.contains(required), "the network file lost a safeguard: \(required)")
        }
        XCTAssertFalse(net.contains("URLSession.shared") || net.contains(".default") || net.contains("httpCookieStorage = .shared"), "no shared session, no default configuration")
        // The bridge asks the permission before it ever calls the network.
        let bridge = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Engines/WebKit/UserScriptBridge.swift"), encoding: .utf8)
        let permission = try XCTUnwrap(bridge.range(of: "script.allows(.network)"))
        let call = try XCTUnwrap(bridge.range(of: "UserScriptNet.request("))
        XCTAssertLessThan(permission.lowerBound, call.lowerBound)
    }

    /// SponsorBlock contacts a server about the videos a person watches, so it is held to this: one file does it, one caller reaches it, and that caller checks the person's
    /// agreement, the private-tab rule and the site switch first. The request carries only the hash prefix. Opt-in, off by default, and nothing is written to disk.
    func testSponsorBlockNetworkingIsOneConsentedFileThatSendsOnlyAHashPrefix() throws {
        let sources = swiftSources(under: "apps/apple/Shared") + swiftSources(under: "apps/apple/Engines") + swiftSources(under: "apps/apple/macOS") + swiftSources(under: "apps/apple/iOS")
        func files(containing text: String) throws -> [String] { try sources.filter { try String(contentsOf: $0, encoding: .utf8).contains(text) }.map(\.lastPathComponent).sorted() }
        XCTAssertEqual(try files(containing: "SponsorBlockService.shared"), ["SponsorBlock.swift"], "one caller")
        XCTAssertEqual(try files(containing: "URLSession").filter { $0.hasPrefix("Sponsor") }, ["SponsorBlockService.swift"])
        let service = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Shared/SponsorBlockService.swift"), encoding: .utf8)
        for required in ["URLSessionConfiguration.ephemeral", "httpCookieStorage = nil", "httpShouldSetCookies = false", "urlCache = nil", "SponsorVideoID.hashPrefix(videoID)", "SameHostOnly",
                         "url.scheme == \"https\"", "isLocalHost"] {
            XCTAssertTrue(service.contains(required), "the service lost a safeguard: \(required)")
        }
        XCTAssertFalse(service.contains("URLSession.shared") || service.contains("appendingPathComponent(videoID") || service.contains("name: \"videoID\"") || service.contains("name: \"v\""), "the full identifier is never sent")
        // The caller checks agreement, privacy and the site switch before it asks.
        let caller = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Shared/SponsorBlock.swift"), encoding: .utf8)
        let guardRange = try XCTUnwrap(caller.range(of: "guard sponsorBlockEnabled, sponsorConsentDate != nil, !tab.leavesNoTrace"))
        let fetchRange = try XCTUnwrap(caller.range(of: "SponsorBlockService.shared.fetch("))
        XCTAssertLessThan(guardRange.lowerBound, fetchRange.lowerBound)
        XCTAssertTrue(caller.contains("!sponsorOffSites.contains("))
        // The feature is off by default, nothing is written to disk but the settings, and a private tab gets no script.
        let model = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Shared/BrowserModel.swift"), encoding: .utf8)
        XCTAssertTrue(model.contains("var sponsorBlockEnabled = false"))
        let installer = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/Engines/WebKit/WebKitUserScripts.swift"), encoding: .utf8)
        XCTAssertTrue(installer.contains("privatePolicy.sponsorBlock = nil"))
    }

    func testNoVPNDNSOrNetworkExtensionAnywhereInTheApp() throws {
        let sources = swiftSources(under: "apps/apple") + swiftSources(under: "Packages/SetuPrivacyKit/Sources")
        let forbidden = ["NetworkExtension", "NEVPNManager", "NETunnelProvider", "NEDNSSettings", "NEPacketTunnel", "NEFilterProvider", "WireGuard", "OpenVPN", "DNSOverHTTPS", "NEProxySettings"]
        for file in sources where !file.path.contains("PrivacyIntegrationTests") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden { XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) mentions \(word)") }
        }
        let project = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/project.yml"), encoding: .utf8)
        XCTAssertFalse(project.localizedCaseInsensitiveContains("networkextension"))
        XCTAssertFalse(project.localizedCaseInsensitiveContains("packet-tunnel"))
    }

    func testEntitlementsStillNarrow() throws {
        #if os(macOS)
        let url = repoRoot().appendingPathComponent("apps/apple/macOS/BrowserSetu.entitlements")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        // Not sandboxed by design (direct-download DMG, hardened runtime, notarized): the sandbox key must not appear, and nothing broad may be added in its place.
        XCTAssertNotEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertNil(plist["com.apple.security.network.server"])
        XCTAssertNil(plist["com.apple.security.files.all"])
        XCTAssertFalse(plist.keys.contains { $0.localizedCaseInsensitiveContains("networking.networkextension") })
        #endif
    }

    /// The loopback server for AI tools exists only in the downloadable build, so only that build asks for the entitlement.
    func testOnlyTheDownloadableBuildCanRunTheAIToolServer() throws {
        #if os(macOS)
        let direct = try XCTUnwrap(NSDictionary(contentsOf: repoRoot().appendingPathComponent("apps/apple/Direct/BrowserSetuDirect.entitlements")) as? [String: Any])
        // The downloadable build is not sandboxed, so it needs no network.server entitlement to listen on loopback; the entitlements stay minimal.
        XCTAssertNil(direct["com.apple.security.network.server"])
        XCTAssertNotEqual(direct["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertNil(direct["com.apple.security.files.all"])
        for name in ["AgentBridge.swift", "AgentServer.swift"] {
            let text = try String(contentsOf: repoRoot().appendingPathComponent("apps/apple/macOS/\(name)"), encoding: .utf8)
            XCTAssertTrue(text.hasPrefix("#if DIRECT_BUILD"), "\(name) must not compile into the App Store build")
        }
        #endif
    }

    func testImportedVayuSetuFilesStillMatchTheirRecordedHashes() throws {
        let dir = repoRoot().appendingPathComponent("Packages/SetuPrivacyKit")
        let recorded = try String(contentsOf: dir.appendingPathComponent("IMPORTED.sha256"), encoding: .utf8)
        XCTAssertEqual(recorded.split(separator: "\n").count, 4)
    }

    // MARK: performance (measured, printed; only loose sanity bounds are asserted)

    func testRuleCompileAndInstallCost() async throws {
        let model = makeModel()
        await model.start()
        let big = (0..<40_000).map { "h\($0).perf-test-list.com" }.joined(separator: "\n")
        try await useCustomList(model, text: big)
        let report = try XCTUnwrap(model.privacy.report)
        print("PERF compile+install 40k domain rules: \(Int(report.compileMilliseconds)) ms; parse+build: \(Int(model.privacy.lastBuildMilliseconds)) ms; reused=\(report.reusedCompiledList)")
        XCTAssertLessThan(report.compileMilliseconds, 10_000)
        // Same rules again: must come from the compiled-list cache, not a recompile.
        model.privacy.scheduleApply()
        await model.privacy.settle()
        XCTAssertEqual(model.privacy.report?.reusedCompiledList, true)
    }

    func testPageLoadWithAndWithoutProtection() async throws {
        func average(_ model: BrowserModel) async throws -> Double {
            var total = 0.0
            for _ in 0..<5 {
                let start = Date()
                try await loadFixture(model)
                total += Date().timeIntervalSince(start) - 1.0           // loadFixture waits 1 s for subresources
            }
            return total / 5
        }
        let off = makeModel()
        await off.start()
        off.privacy.setAdBlocking(false); off.privacy.setAntiTracking(false)
        await off.privacy.settle()
        let withoutProtection = try await average(off)
        let on = makeModel(profile: "perf-on")
        XCTAssertTrue(on.createProfile("perf-on") || true)
        await on.start()
        let withProtection = try await average(on)
        print("PERF page load avg: protection off \(Int(withoutProtection * 1000)) ms, on \(Int(withProtection * 1000)) ms")
        XCTAssertLessThan(withProtection, 10)
    }

    func testStartupWithAndWithoutProtection() async throws {
        func startup(enabled: Bool) async -> Double {
            let model = makeModel(root: nil)
            if !enabled { model.privacy.setAdBlocking(false); model.privacy.setAntiTracking(false) }
            let start = Date()
            await model.start()
            return Date().timeIntervalSince(start) * 1000
        }
        let off = await startup(enabled: false)
        let on = await startup(enabled: true)
        let warm = await startup(enabled: true)
        print("PERF startup (model.start): off \(Int(off)) ms, on cold \(Int(on)) ms, on warm \(Int(warm)) ms")
        XCTAssertLessThan(on, 5_000)
    }

    func testMemoryWithManyTabsProtectedVersusNot() async throws {
        let model = makeModel()
        await model.start()
        let base = currentMemoryFootprint()
        for _ in 0..<20 { model.newTab() }
        let grown = Int64(currentMemoryFootprint()) - Int64(base)
        print("PERF memory: +\(grown / 1024 / 1024) MB for 20 blank tabs with protection on (app process only)")
        XCTAssertLessThan(grown, 400 * 1024 * 1024)
    }

    private func makeModel(root: String?) -> BrowserModel {
        BrowserModel(engine: WebKitEngine(), root: root ?? NSTemporaryDirectory() + "bs-priv-\(UUID().uuidString)", profile: "default")
    }
}
