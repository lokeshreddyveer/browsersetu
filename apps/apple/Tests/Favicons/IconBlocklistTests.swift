import XCTest
@testable import Browser_Setu

final class IconBlocklistTests: XCTestCase {
    private func rules(_ items: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: items) }
    private func domainRule(_ domain: String, extra: [String: Any] = [:], action: String = "block") -> [String: Any] {
        var trigger: [String: Any] = ["url-filter": "^https?://([^/]+\\.)?" + domain.replacingOccurrences(of: ".", with: "\\.") + "[/:?&=]"]
        for (k, v) in extra { trigger[k] = v }
        return ["trigger": trigger, "action": ["type": action]]
    }

    func testDomainBlockRulesAreReadBackFromTheCompiledLists() {
        let list = IconBlocklist.build(from: [rules([domainRule("ads.example"), domainRule("tracker.example", extra: ["load-type": ["third-party"]])])])
        XCTAssertEqual(list.domains, ["ads.example", "tracker.example"])
    }

    func testRulesThatSayMoreThanADomainAreNotApplied() {
        let list = IconBlocklist.build(from: [rules([
            domainRule("a.example", extra: ["if-domain": ["*b.example"]]),
            domainRule("c.example", extra: ["resource-type": ["script"]]),
            domainRule("d.example", extra: ["load-context": ["child-frame"]]),
            domainRule("e.example", action: "ignore-previous-rules"),
            domainRule("f.example", action: "css-display-none"),
            ["trigger": ["url-filter": ".*/ads/banner.*"], "action": ["type": "block"]],
            domainRule("g.example", extra: ["resource-type": ["image", "script"]]),
            domainRule("nodot", extra: [:]),
        ])])
        XCTAssertEqual(list.domains, ["g.example"], "only what can be applied exactly to an icon")
    }

    func testAThirdPartyIconOnAListedHostOrItsSubdomainIsBlockedButTheSitesOwnIsNot() {
        let list = IconBlocklist(domains: ["tracker.example"])
        XCTAssertTrue(list.blocks(iconHost: "tracker.example", pageHost: "news.example"))
        XCTAssertTrue(list.blocks(iconHost: "cdn.eu.tracker.example", pageHost: "news.example"))
        XCTAssertFalse(list.blocks(iconHost: "tracker.example", pageHost: "tracker.example"), "a listed site's own icon is not a third party to it")
        XCTAssertFalse(list.blocks(iconHost: "www.tracker.example", pageHost: "tracker.example"))
        XCTAssertFalse(list.blocks(iconHost: "nottracker.example", pageHost: "news.example"), "a different name that ends the same way")
        XCTAssertFalse(IconBlocklist.empty.blocks(iconHost: "tracker.example", pageHost: "news.example"))
    }

    func testAnUnreadableListIsIgnored() {
        XCTAssertTrue(IconBlocklist.build(from: [Data("not json".utf8), Data("{}".utf8)]).isEmpty)
    }
}
