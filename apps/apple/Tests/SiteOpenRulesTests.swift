import XCTest
@testable import Browser_Setu

final class SiteOpenRulesTests: XCTestCase {
    private func rule(_ host: String, _ action: SiteOpenRule.Action) -> SiteOpenRule { SiteOpenRule(host: host, action: action) }

    func testRulesCoverTheHostAndItsSubdomainsOnly() {
        let r = rule("bank.test", .privateTab)
        XCTAssertTrue(r.matches(host: "bank.test")); XCTAssertTrue(r.matches(host: "www.bank.test")); XCTAssertTrue(r.matches(host: "A.B.Bank.test"))
        XCTAssertFalse(r.matches(host: "notbank.test")); XCTAssertFalse(r.matches(host: "bank.test.evil.com")); XCTAssertFalse(r.matches(host: nil))
    }

    func testAPageThatBreaksTheRuleIsMovedAndOneThatKeepsItIsLeftAlone() {
        let rules = [rule("bank.test", .privateTab), rule("work.test", .container("Work")), rule("news.test", .group("Reading")), rule("docs.test", .workspace("Research"))]
        func go(_ host: String, priv: Bool = false, container: String? = nil, group: String = "", ws: String = "") -> SiteOpenOutcome? {
            SiteOpenRules.outcome(forHost: host, rules: rules, tabIsPrivate: priv, tabContainer: container, tabGroup: group, tabWorkspace: ws)
        }
        XCTAssertEqual(go("bank.test"), .openElsewhere(isPrivate: true, container: nil))
        XCTAssertNil(go("bank.test", priv: true), "already private: nothing to do (and no loop)")
        XCTAssertEqual(go("www.work.test"), .openElsewhere(isPrivate: false, container: "Work"))
        XCTAssertNil(go("work.test", container: "Work"))
        XCTAssertNil(go("work.test", priv: true), "a private tab is left private, not moved to a container")
        XCTAssertEqual(go("news.test"), .moveToGroup("Reading")); XCTAssertNil(go("news.test", group: "Reading"))
        XCTAssertEqual(go("docs.test"), .moveToWorkspace("Research")); XCTAssertNil(go("docs.test", ws: "Research"))
        XCTAssertNil(go("other.test"))
    }

    func testAMoreSpecificRuleComesBeforeABroaderOne() {
        let rules = [rule("example.test", .group("All")), rule("mail.example.test", .privateTab)]
        XCTAssertEqual(SiteOpenRules.outcome(forHost: "mail.example.test", rules: rules, tabIsPrivate: false, tabContainer: nil, tabGroup: "", tabWorkspace: ""), .openElsewhere(isPrivate: true, container: nil))
        XCTAssertEqual(SiteOpenRules.outcome(forHost: "www.example.test", rules: rules, tabIsPrivate: false, tabContainer: nil, tabGroup: "", tabWorkspace: ""), .moveToGroup("All"))
    }

    func testHostsAreCleanedAndNonsenseIsRefused() {
        XCTAssertEqual(SiteOpenRule.cleanHost("https://www.Example.com/path?x=1"), "example.com")
        XCTAssertEqual(SiteOpenRule.cleanHost(" Example.com:8443 "), "example.com")
        XCTAssertNil(SiteOpenRule.cleanHost("localhost")); XCTAssertNil(SiteOpenRule.cleanHost("a b.com")); XCTAssertNil(SiteOpenRule.cleanHost("")); XCTAssertNil(SiteOpenRule.cleanHost("exa..mple.com"))
    }

    func testARuleNeedsWhatItNamesToExistAndNoDuplicates() {
        let list = [rule("a.test", .privateTab)]
        XCTAssertFalse(SiteOpenRules.canAdd(rule("a.test", .privateTab), to: list, containers: [], groups: [], workspaces: []), "no duplicates")
        XCTAssertFalse(SiteOpenRules.canAdd(rule("b.test", .container("Work")), to: list, containers: ["Home"], groups: [], workspaces: []))
        XCTAssertTrue(SiteOpenRules.canAdd(rule("b.test", .container("Work")), to: list, containers: ["Work"], groups: [], workspaces: []))
        XCTAssertFalse(SiteOpenRules.canAdd(rule("b.test", .workspace("Nope")), to: list, containers: [], groups: [], workspaces: ["Work"]))
        XCTAssertFalse(SiteOpenRules.canAdd(rule("Not A Host", .privateTab), to: list, containers: [], groups: [], workspaces: []))
    }

    func testRulesRoundTripThroughStorage() throws {
        let rules = [rule("a.test", .container("Work")), rule("b.test", .privateTab)]
        XCTAssertEqual(try JSONDecoder().decode([SiteOpenRule].self, from: JSONEncoder().encode(rules)), rules)
    }
}

@MainActor
final class SiteOpenRulesNavigationTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-rules-\(UUID().uuidString)", profile: "default")
        await m.start()
        return m
    }

    private func waitFor(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return condition()
    }

    func testAPageForARuledSiteOpensInAPrivateTabInstead() async throws {
        let m = await model()
        XCTAssertTrue(m.workbench.addSiteRule(host: "127.0.0.1", action: .privateTab))
        let tab = m.openTab(url: nil, isPrivate: false)
        tab.load(URL(string: "http://127.0.0.1:18765/")!)
        let moved = await waitFor { m.tabs.contains { $0.isPrivate && $0.url?.host == "127.0.0.1" } || m.tabs.contains { $0.isPrivate && $0.hasLoadedPage } }
        XCTAssertTrue(moved, "the page went to a private tab")
        XCTAssertFalse(m.tabs.contains { !$0.isPrivate && $0.url?.host == "127.0.0.1" }, "and not into the normal one")
    }

    func testAPageForARuledSiteIsFiledIntoItsGroup() async throws {
        let m = await model()
        XCTAssertTrue(m.workbench.addSiteRule(host: "127.0.0.1", action: .group("Local")))
        let tab = m.openTab(url: nil, isPrivate: false)
        tab.load(URL(string: "http://127.0.0.1:18765/")!)
        let filed = await waitFor { tab.group == "Local" }
        XCTAssertTrue(filed)
    }
}
