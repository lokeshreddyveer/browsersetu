import XCTest
@testable import Browser_Setu

/// Skipping a tracker's redirect page: only known forms, never a sign-in, payment, invitation or signed link, with exceptions and a way back to the original.
@MainActor
final class RedirectSkipTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testAKnownRedirectIsSkippedToItsNormalizedDestination() {
        let d = LinkDebouncer.decision(for: url("https://l.facebook.com/l.php?u=HTTPS%3A%2F%2FExample.com%3A443%2Fpage%3Fa%3D1%23frag&h=abc"), excepted: [])
        XCTAssertEqual(d, .skip(destination: url("https://example.com/page?a=1"), redirector: "l.facebook.com"), "scheme and host lower-cased, the default port and the fragment left out")
        XCTAssertEqual(LinkDebouncer.decision(for: url("https://www.google.com/url?q=https%3A%2F%2Fnews.example.org%2Fa&sa=U"), excepted: []), .skip(destination: url("https://news.example.org/a"), redirector: "www.google.com"))
        XCTAssertEqual(LinkDebouncer.decision(for: url("https://example.com/"), excepted: []), .none)
    }

    func testSignInPaymentInvitationAndSignedLinksAreNeverTouched() {
        let cases = [
            "https://l.facebook.com/l.php?u=https%3A%2F%2Faccounts.google.com%2Fsignin",                                  // a sign-in site
            "https://l.facebook.com/l.php?u=https%3A%2F%2Fshop.example.com%2Fcheckout%2Fpay",                           // a payment page
            "https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2Fjoin%3Finvite%3Dabc123",                        // an invitation
            "https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2Ffile%3Fsignature%3Dabc%26expires%3D1",          // a signed link
            "https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2Fcb%3Fcode%3D1%26state%3D2",                      // an OAuth callback
            "https://l.facebook.com/l.php?u=https%3A%2F%2Flogin.microsoftonline.com%2Fcommon%2Foauth2%2Fauthorize",
            "https://www.google.com/url?q=https%3A%2F%2Fwww.paypal.com%2Fcheckout&sa=U",
            "https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2Fpage&token=abc",                                 // the redirect itself is signed
            "https://l.facebook.com/l.php?u=https%3A%2F%2Fuser%3Apw%40example.com%2Fpage",                               // a name and password in the address
            "https://l.facebook.com/l.php?u=https%3A%2F%2F192.168%2Fx",                                                  // not a public host
        ]
        for text in cases {
            if case .skip = LinkDebouncer.decision(for: url(text), excepted: []) { XCTFail("must not skip: \(text)") }
        }
        if case .keep(let reason) = LinkDebouncer.decision(for: url(cases[0]), excepted: []) { XCTAssertTrue(reason.contains("sign-in")) } else { XCTFail("expected keep") }
    }

    func testASiteTheyExceptedIsNeverSkippedWhetherItIsTheRedirectOrTheDestination() {
        let link = url("https://l.facebook.com/l.php?u=https%3A%2F%2Fnews.example.org%2Fa")
        XCTAssertEqual(LinkDebouncer.decision(for: link, excepted: ["facebook.com"]), .keep(reason: "a site you excepted"))
        XCTAssertEqual(LinkDebouncer.decision(for: link, excepted: ["example.org"]), .keep(reason: "a site you excepted"))
        if case .skip = LinkDebouncer.decision(for: link, excepted: ["other.com"]) {} else { XCTFail("an unrelated exception changes nothing") }
    }

    func testALinkThatOnlyLooksLikeARedirectIsDescribedNeverFollowed() {
        XCTAssertEqual(LinkDebouncer.destination(for: url("https://unknown.example.net/redirect?url=https%3A%2F%2Fnews.example.org%2Fa")), nil, "not a known form, so never skipped")
        XCTAssertEqual(LinkDebouncer.unfamiliarDestination(for: url("https://unknown.example.net/redirect?url=https%3A%2F%2Fnews.example.org%2Fa"))?.absoluteString, "https://news.example.org/a")
        XCTAssertNil(LinkDebouncer.unfamiliarDestination(for: url("https://unknown.example.net/login?url=https%3A%2F%2Fnews.example.org%2Fa")), "a sign-in is not described as a redirect")
        XCTAssertNil(LinkDebouncer.unfamiliarDestination(for: url("https://unknown.example.net/article?url=https%3A%2F%2Fnews.example.org%2Fa")), "an ordinary page with an address in it is not one")
        XCTAssertNil(LinkDebouncer.unfamiliarDestination(for: url("https://unknown.example.net/out?url=https%3A%2F%2Funknown.example.net%2Fa")), "the same site is not a hop")
    }

    func testTheModelSkipsSaysSoOffersTheOriginalAndNeverLoops() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-redir-\(UUID().uuidString)", profile: "default")
        await m.start()
        let tab = m.openTab(url: nil, isPrivate: false)
        let link = url("https://l.facebook.com/l.php?u=https%3A%2F%2Fnews.example.org%2Fa")
        m.debounceLinks = false
        XCTAssertNil(m.skipRedirect(link, in: tab), "off means off")
        m.debounceLinks = true
        XCTAssertEqual(m.skipRedirect(link, in: tab)?.absoluteString, "https://news.example.org/a")
        XCTAssertTrue(m.notice?.contains("Skipped the click tracker at l.facebook.com") ?? false, "the person is told")
        XCTAssertEqual(m.noticeUndo?.title, "Use the Original Link")
        m.noticeUndo?.run()
        XCTAssertEqual(tab.redirectBypass, link)
        XCTAssertNil(m.skipRedirect(link, in: tab), "the original link is followed this once")
        XCTAssertNil(tab.redirectBypass, "and only once")
        m.setRedirectSkipOff("facebook.com")
        XCTAssertNil(m.skipRedirect(link, in: tab), "an excepted site is left alone")
        XCTAssertEqual(m.redirectSkipOff, ["facebook.com"])
        m.setRedirectSkipOff("")
        // A page that keeps sending the visit back through a redirect cannot loop.
        var skipped = 0
        for _ in 0..<10 { if m.skipRedirect(url("https://www.google.com/url?q=https%3A%2F%2Fa.example.org%2F"), in: tab) != nil { skipped += 1 } }
        XCTAssertLessThanOrEqual(skipped, 3)
    }

    func testRemovingTrackingParametersIsAnotherSwitchWithItsOwnRules() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-redir2-\(UUID().uuidString)", profile: "default")
        await m.start()
        m.debounceLinks = false
        m.stripTrackingParameters = true
        XCTAssertNotNil(m.cleanedLink(url("https://example.com/a?utm_source=x&id=1")), "parameters are still removed")
        let tab = m.openTab(url: nil, isPrivate: false)
        XCTAssertNil(m.skipRedirect(url("https://l.facebook.com/l.php?u=https%3A%2F%2Fnews.example.org%2Fa"), in: tab), "while redirects are not skipped")
    }
}
