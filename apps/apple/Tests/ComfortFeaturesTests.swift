import XCTest
import WebKit
import SwiftUI
@testable import Browser_Setu

final class FuzzyTextTests: XCTestCase {
    func testSlipsOfTheKeysAreForgivenInProportionToTheWordLength() {
        func hit(_ q: String, _ text: String) -> FuzzyText.Grade? { FuzzyText.match(q, in: text)?.grade }
        XCTAssertEqual(hit("githb", "Open the GitHub repository"), .close, "a missing letter")
        XCTAssertEqual(hit("recieve", "You will receive an email"), .close, "two letters swapped")
        XCTAssertEqual(hit("kuberntes", "Notes on Kubernetes"), .close)
        XCTAssertEqual(hit("cluser", "a cluster of machines"), .close)
        XCTAssertEqual(hit("cafe", "the Café opens"), .phrase, "accents do not matter")
        XCTAssertEqual(hit("dollars", "It cost 40 dollars."), .phrase)
        XCTAssertEqual(hit("tax return", "Your return of the tax"), .words, "both words, apart")
        XCTAssertEqual(hit("tax retrn", "Your return of the tax"), .close)
        XCTAssertEqual(hit("deploy", "Deployment notes"), .phrase, "the start of a longer word")
        XCTAssertEqual(hit("deploy notes", "Notes on how we deploy daily"), .words, "start-of-word and apart")
        XCTAssertNil(hit("cat", "the cut"), "short words must be exact")
        XCTAssertNil(hit("banana", "an apple a day"))
        XCTAssertNil(hit("kuberntes cluser", "only kubernetes here"))
    }

    func testDistanceCountsASwapAsOneSlip() {
        XCTAssertEqual(FuzzyText.distance(Array("form"), Array("from"), limit: 2), 1)
        XCTAssertEqual(FuzzyText.distance(Array("kitten"), Array("sitten"), limit: 2), 1)
        XCTAssertNil(FuzzyText.distance(Array("abcdef"), Array("uvwxyz"), limit: 2))
        XCTAssertEqual(FuzzyText.distance(Array("same"), Array("same"), limit: 0), 0)
    }

    func testTheMatchSaysWhereAndWhatItFound() throws {
        let text = "Intro. We deploy to a kubernetes cluster nightly."
        let match = try XCTUnwrap(FuzzyText.match("kuberntes", in: text))
        XCTAssertEqual(match.found, "kubernetes")
        XCTAssertEqual(String(text[match.range]), "kubernetes")
    }

    func testAVeryLongPageIsHandledQuickly() {
        let page = (0..<60_000).map { "word\($0 % 997)" }.joined(separator: " ") + " finally the needle"
        let start = Date()
        XCTAssertNotNil(FuzzyText.match("needel", in: page))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testTabTitlesAndAddressesAreMatchedLeniently() {
        XCTAssertTrue(TabMatch.matches(title: "GitHub - pull requests", url: "https://github.com/x", words: "githb pull"))
        XCTAssertTrue(TabMatch.matches(title: "Inbox", url: "https://mail.test", words: "inbox"))
        XCTAssertFalse(TabMatch.matches(title: "Inbox", url: "https://mail.test", words: "calendar"))
    }
}

@MainActor
final class FuzzyTabSearchTests: XCTestCase {
    func testAMisspeltSearchFindsTheTabAndRanksExactMatchesFirst() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-fz-\(UUID().uuidString)", profile: "default")
        await m.start()
        let a = m.openTab(url: nil, isPrivate: false), b = m.openTab(url: nil, isPrivate: false)
        a.engine.showHTML("<html><title>Spelled right</title><body>We run a kubernetes cluster every night.</body></html>", baseURL: URL(string: "https://one.fz.test/"))
        b.engine.showHTML("<html><title>Notes</title><body>Our kubernets cluser is small.</body></html>", baseURL: URL(string: "https://two.fz.test/"))
        try await Task.sleep(for: .seconds(2))
        let hits = await m.searchTabText("kubernetes cluster")
        XCTAssertEqual(hits.map(\.tabID), [a.id, b.id], "the exact match is listed before the close one")
        XCTAssertFalse(hits[0].close)
        XCTAssertTrue(hits[1].close)
        let typo = await m.searchTabText("kuberntes cluser")
        XCTAssertEqual(Set(typo.map(\.tabID)), [a.id, b.id], "with slips in the search both are found")
        XCTAssertTrue(typo.allSatisfy { !$0.found.isEmpty }, "each says what the page actually contains, for the find that follows")
    }
}

final class CertificateIdentityTests: XCTestCase {
    private let organization = "MIICxjCCAm2gAwIBAgIJANgnxY7dHZtqMAoGCCqGSM49BAMCMFQxCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRUwEwYDVQQKDAxFeGFtcGxlIENvcnAxGTAXBgNVBAMMEHd3dy5leGFtcGxlLnRlc3QwHhcNMjYxMDE3MDYwNjA1WhcNMzYxMDE0MDYwNjA1WjBUMQswCQYDVQQGEwJVUzETMBEGA1UECAwKQ2FsaWZvcm5pYTEVMBMGA1UECgwMRXhhbXBsZSBDb3JwMRkwFwYDVQQDDBB3d3cuZXhhbXBsZS50ZXN0MIIBSzCCAQMGByqGSM49AgEwgfcCAQEwLAYHKoZIzj0BAQIhAP////8AAAABAAAAAAAAAAAAAAAA////////////////MFsEIP////8AAAABAAAAAAAAAAAAAAAA///////////////8BCBaxjXYqjqT57PrvVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMVAMSdNgiG5wSTamZ44ROdJreBn36QBEEEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9QIhAP////8AAAAA//////////+85vqtpxeehPO5ysL8YyVRAgEBA0IABOP2UXRipVWGL/bDQtbv3JeWSyRxoBUwiyKfKNfAh+Iwd/i7sMdrec5lbFQoVbCNC31x88b9QKlGtPMUpUn9L9GjNDAyMBMGA1UdIAQMMAowCAYGZ4EMAQICMBsGA1UdEQQUMBKCEHd3dy5leGFtcGxlLnRlc3QwCgYIKoZIzj0EAwIDRwAwRAIgFUwFxGbYPNqukoWDObnI1GPAfxn5U1mF7JPhN/9c6qUCIE1OmB4DQVV0UG7MOWza8oG5zxPluEqG0Eb30b0zXzuA"
    private let domainOnly = "MIICmTCCAj+gAwIBAgIJAMH33wC5h1qUMAoGCCqGSM49BAMCMD0xCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRkwFwYDVQQDDBB3d3cuZXhhbXBsZS50ZXN0MB4XDTI2MTAxNzA2MDYwNVoXDTM2MTAxNDA2MDYwNVowPTELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWExGTAXBgNVBAMMEHd3dy5leGFtcGxlLnRlc3QwggFLMIIBAwYHKoZIzj0CATCB9wIBATAsBgcqhkjOPQEBAiEA/////wAAAAEAAAAAAAAAAAAAAAD///////////////8wWwQg/////wAAAAEAAAAAAAAAAAAAAAD///////////////wEIFrGNdiqOpPns+u9VXaYhrxlHQawzFOw9jvOPD4n0mBLAxUAxJ02CIbnBJNqZnjhE50mt4GffpAEQQRrF9Hy4SxCR/i85uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1AiEA/////wAAAAD//////////7zm+q2nF56E87nKwvxjJVECAQEDQgAE7JzRd0QCSG3UYGVCtD8NCtBHkg1SotC7hnfLODLMB6tWDJxO67k+DNph82dtOMR+7X++nBn/TjCOEE0LTySCHaM0MDIwEwYDVR0gBAwwCjAIBgZngQwBAgEwGwYDVR0RBBQwEoIQd3d3LmV4YW1wbGUudGVzdDAKBggqhkjOPQQDAgNIADBFAiEAvTY8RKfqMW2A0Vr5RynNtHt+ZS1Mvy4f85pVVmifeogCIHLdYdSSM2ZY1l5IZhn6+4X/OeHYXKwR42UP2N65Tyqe"
    private let extended = "MIICzjCCAnSgAwIBAgIJAI//pFrNneSOMAoGCCqGSM49BAMCMFgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRkwFwYDVQQKDBBDYWbDqSBNw7xsbGVyIEFHMRkwFwYDVQQDDBB3d3cuZXhhbXBsZS50ZXN0MB4XDTI2MTAxNzA2MDYwNVoXDTM2MTAxNDA2MDYwNVowWDELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWExGTAXBgNVBAoMEENhZsOpIE3DvGxsZXIgQUcxGTAXBgNVBAMMEHd3dy5leGFtcGxlLnRlc3QwggFLMIIBAwYHKoZIzj0CATCB9wIBATAsBgcqhkjOPQEBAiEA/////wAAAAEAAAAAAAAAAAAAAAD///////////////8wWwQg/////wAAAAEAAAAAAAAAAAAAAAD///////////////wEIFrGNdiqOpPns+u9VXaYhrxlHQawzFOw9jvOPD4n0mBLAxUAxJ02CIbnBJNqZnjhE50mt4GffpAEQQRrF9Hy4SxCR/i85uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1AiEA/////wAAAAD//////////7zm+q2nF56E87nKwvxjJVECAQEDQgAE65Q2O7uaO7Bj1lOnrEVRlHcE68bTixzmtOcSTGUfsGPWUJUlIrOJUIrM5nxfILzaRSbjDHpdsuT1PNqunk9vY6MzMDEwEgYDVR0gBAswCTAHBgVngQwBATAbBgNVHREEFDASghB3d3cuZXhhbXBsZS50ZXN0MAoGCCqGSM49BAMCA0gAMEUCIQCUI3nyXupUVURmxAmX7QNoJsalVQ5Ggb7vHkT6fn+X+AIgTwN/l/JYvY9jfaay7j9tzrZG4B/GDEMz8gj2X2Xe/Lg="

    func testACertificateWithACheckedOrganisationNamesIt() throws {
        let id = try XCTUnwrap(CertificateIdentity.parse(der: Data(base64Encoded: organization)!, host: "www.example.test"))
        XCTAssertEqual(id.organization, "Example Corp")
        XCTAssertEqual(id.country, "US")
        XCTAssertEqual(id.commonName, "www.example.test")
        XCTAssertEqual(id.level, .organization)
        XCTAssertTrue(id.isVerified)
        XCTAssertEqual(id.headline, "Verified: Example Corp (US)")
        XCTAssertEqual(id.shortLabel, "Example Corp")
        XCTAssertTrue(id.detail.contains("controls www.example.test"))
    }

    func testADomainOnlyCertificateDoesNotClaimToKnowTheOwner() throws {
        let id = try XCTUnwrap(CertificateIdentity.parse(der: Data(base64Encoded: domainOnly)!, host: "www.example.test"))
        XCTAssertNil(id.organization)
        XCTAssertEqual(id.level, .domain)
        XCTAssertFalse(id.isVerified)
        XCTAssertEqual(id.headline, "Encrypted, owner not verified")
        XCTAssertNil(id.shortLabel, "nothing is shown in the address bar for these")
        XCTAssertTrue(id.detail.contains("does not say who runs the site"))
    }

    func testAnExtendedCertificateAndNamesWithAccentsAreRead() throws {
        let id = try XCTUnwrap(CertificateIdentity.parse(der: Data(base64Encoded: extended)!, host: "www.example.test"))
        XCTAssertEqual(id.level, .extended)
        XCTAssertEqual(id.organization, "Café Müller AG")
        XCTAssertTrue(id.detail.contains("checked in detail"))
    }

    func testBytesThatAreNotACertificateAreRefused() {
        XCTAssertNil(CertificateIdentity.parse(der: Data(), host: "x"))
        XCTAssertNil(CertificateIdentity.parse(der: Data([0x30, 0x03, 0x01, 0x02, 0x03]), host: "x"))
        XCTAssertNil(CertificateIdentity.parse(der: Data(repeating: 0xFF, count: 200), host: "x"))
        var truncated = Data(base64Encoded: organization)!
        truncated.removeLast(400)
        XCTAssertNil(CertificateIdentity.parse(der: truncated, host: "x"))
    }
}

@MainActor
final class ThreePanelSplitTests: XCTestCase {
    func testPanelsShareTheWindowTheWayTheirCountSuggests() {
        XCTAssertEqual(SplitLayout<EmptyView>.groups(count: 2), [[0], [1]])
        XCTAssertEqual(SplitLayout<EmptyView>.groups(count: 3), [[0], [1, 2]], "one tall page with two beside it")
        XCTAssertEqual(SplitLayout<EmptyView>.groups(count: 4), [[0, 2], [1, 3]], "two by two")
    }

    func testPanelsJoinUpToFourSwapInAndCloseUpTheGap() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-3p-\(UUID().uuidString)", profile: "default")
        await m.start()
        let a = m.active!, b = m.newTab(), c = m.newTab(), d = m.newTab(), e = m.newTab()
        m.select(a.id)
        m.addThirdPanel(with: c)
        XCTAssertEqual(m.splitTabID, c.id, "with no split open, the first one added makes the pair")
        m.addThirdPanel(with: b)
        XCTAssertEqual(m.splitPanels.map(\.id), [a.id, c.id, b.id])
        let views = (a.hostView, b.hostView, c.hostView)
        m.addThirdPanel(with: d)
        XCTAssertEqual(m.splitPanels.map(\.id), [a.id, c.id, b.id, d.id], "a fourth makes a grid")
        m.addThirdPanel(with: e)
        XCTAssertEqual(m.fourthSplitTabID, e.id, "a fifth replaces the fourth; four is the most")
        m.swapSplit(with: b.id)
        XCTAssertEqual(m.activeID, b.id)
        XCTAssertEqual(m.splitPanels.map(\.id), [b.id, c.id, a.id, e.id], "the tab swapped out takes the panel's place")
        XCTAssertTrue(a.hostView === views.0 && b.hostView === views.1 && c.hostView === views.2, "no page is reloaded or recreated")
        m.closeTab(id: c.id)
        XCTAssertEqual(m.splitPanels.map(\.id), [b.id, a.id, e.id], "closing the second panel moves the others up")
        m.removeThirdPanel()
        XCTAssertEqual(m.splitPanels.map(\.id), [b.id, a.id], "the last panel goes first")
        let priv = m.openTab(url: nil, isPrivate: true, select: false)
        m.addThirdPanel(with: priv)
        XCTAssertNil(m.thirdSplitTabID, "private tabs cannot join a normal split")
        m.addThirdPanel(with: d); m.addThirdPanel(with: e)
        m.closeSplit()
        XCTAssertTrue(m.thirdSplitTabID == nil && m.fourthSplitTabID == nil, "closing the split closes every panel")
    }

    func testTabsInPanelsAreNotPutToSleep() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-3s-\(UUID().uuidString)", profile: "default")
        await m.start()
        let a = m.active!, b = m.newTab(), c = m.newTab(), d = m.newTab()
        m.select(a.id); m.openSplit(with: b); m.addThirdPanel(with: c)
        for tab in [b, c, d] { tab.engine.showHTML("<html><body>x</body></html>", baseURL: URL(string: "https://p.test/")) }
        try await Task.sleep(for: .seconds(1.5))
        _ = await m.suspendAll()
        XCTAssertFalse(b.isDiscarded); XCTAssertFalse(c.isDiscarded)
        XCTAssertTrue(d.isDiscarded, "a tab that is in no panel is")
    }
}

#if os(macOS)
@MainActor
final class RestingColorTests: XCTestCase {
    func testAMacPageHasTheWindowsColourBehindItBeforeItPaints() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-rc-\(UUID().uuidString)", profile: "default")
        await m.start()
        let web = try XCTUnwrap(m.openTab(url: nil, isPrivate: false).hostView as? WKWebView)
        web.appearance = NSAppearance(named: .darkAqua)
        (web as? ScrollReportingWebView)?.applyRestingColor()
        let dark = try XCTUnwrap(web.underPageBackgroundColor?.usingColorSpace(.sRGB))
        XCTAssertLessThan(dark.brightnessComponent, 0.4, "a dark window is not white behind a loading page")
        web.appearance = NSAppearance(named: .aqua)
        (web as? ScrollReportingWebView)?.applyRestingColor()
        let light = try XCTUnwrap(web.underPageBackgroundColor?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(light.brightnessComponent, 0.8)
    }
}
#endif

final class ToolbarTintTests: XCTestCase {
    func testAColourThatWouldClashOnlyWashesTheBar() {
        let white = PageTint(red: 1, green: 1, blue: 1), navy = PageTint(red: 0.1, green: 0.15, blue: 0.4), cream = PageTint(red: 0.95, green: 0.92, blue: 0.8)
        XCTAssertLessThanOrEqual(ToolbarTint.strength(for: white, dark: true, themed: false), 0.14, "a white page in a dark window")
        XCTAssertLessThanOrEqual(ToolbarTint.strength(for: navy, dark: false, themed: false), 0.14, "a dark page in a light window")
        XCTAssertEqual(ToolbarTint.strength(for: navy, dark: true, themed: false), 0.5, "a colour that suits the window shows clearly")
        XCTAssertEqual(ToolbarTint.strength(for: cream, dark: false, themed: false), 0.5)
        XCTAssertEqual(ToolbarTint.strength(for: navy, dark: true, themed: true), 0.30, "with a theme the page adds a lighter touch")
        XCTAssertLessThan(ToolbarTint.strength(for: navy, dark: true, themed: true), ToolbarTint.strength(for: navy, dark: true, themed: false))
    }
}

#if os(macOS)
@MainActor
final class ToolbarAndWindowDropTests: XCTestCase {
    private func model(root: String? = nil) async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: root ?? NSTemporaryDirectory() + "bs-tb-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    func testTheWorkspaceAndSplitButtonsAreOnByDefaultAndEarlierToolbarsGetThemOnce() async throws {
        let fresh = await model()
        XCTAssertTrue(fresh.shows(.workspaces) && fresh.shows(.splitView))
        XCTAssertEqual(fresh.toolbarExtrasCount, 2)
        let root = NSTemporaryDirectory() + "bs-tbm-\(UUID().uuidString)"
        let seed = await model(root: root)
        // A toolbar saved before these buttons existed has no version marker.
        try seed.core.setSetting(key: "toolbar_items", value: "sidebar,backForward,reload")
        let old = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await old.start()
        XCTAssertTrue(old.shows(.workspaces) && old.shows(.splitView), "added once")
        XCTAssertTrue(old.shows(.reload) && !old.shows(.bookmark), "and the rest of the choice is kept")
        old.toolbarItems = old.toolbarItems.filter { $0 != .splitView }
        let again = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await again.start()
        XCTAssertFalse(again.shows(.splitView), "switched off stays off")
    }

    func testATabDroppedFromAnotherWindowComesInWithItsPageAndTheEmptyWindowCloses() async throws {
        let a = await model()
        let b = BrowserModel(sharing: a)
        b.hasStarted = true
        let moving = b.openTab(url: nil, isPrivate: false)
        var closed = false
        b.onWindowShouldClose = { closed = true }
        let first = a.active!
        let view = moving.hostView
        XCTAssertTrue(a.acceptDroppedTab(moving.id, before: first.id), "a tab from another window is accepted")
        XCTAssertTrue(a.tabs.contains { $0.id == moving.id })
        XCTAssertEqual(a.tabs.firstIndex { $0.id == moving.id }, a.tabs.firstIndex { $0.id == first.id }.map { $0 - 1 }, "and lands where it was dropped")
        XCTAssertTrue(moving.hostView === view, "the same live page, not a reload")
        XCTAssertFalse(b.tabs.contains { $0.id == moving.id })
        XCTAssertTrue(closed, "the window it left has no tabs and closes")
        XCTAssertFalse(a.acceptDroppedTab(999_999, before: nil), "an unknown tab is refused")
    }

    func testTabsDroppedWithinAWindowAreReorderedAndGuestWindowsRefuseNormalTabs() async throws {
        let a = await model()
        let t1 = a.active!, t2 = a.newTab(), t3 = a.newTab()
        XCTAssertTrue(a.acceptDroppedTab(t3.id, before: t1.id))
        XCTAssertEqual(a.tabs.map(\.id).prefix(3), [t3.id, t1.id, t2.id])
        let guest = BrowserModel(sharing: a)
        guest.hasStarted = true
        guest.isGuest = true
        _ = guest.openTab(url: nil, isPrivate: true)
        XCTAssertFalse(guest.acceptDroppedTab(t1.id, before: nil), "a normal tab cannot be dropped into a guest window")
    }
}
#endif
