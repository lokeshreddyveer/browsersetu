import XCTest
@testable import SetuPrivacyCore
import SetuPrivacyWebKit
import WebKit

final class FilterClassifierTests: XCTestCase {
    private func classify(_ text: String, disabled: Set<String> = []) -> ClassifiedList {
        FilterClassifier.parse(Data(text.utf8), name: "T", disabled: disabled)
    }

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: Cosmetic exceptions

    func testACosmeticExceptionKeepsASelectorHiddenEverywhereExceptOnThatSite() {
        let r = classify("##.banner\nexample.com#@#.banner\n")
        XCTAssertEqual(r.content.hides.count, 1)
        let trigger = object(r.content.hides[0])["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["unless-domain"] as? [String], ["*example.com"])
        XCTAssertEqual(r.diagnostics.exceptions, 1)
    }

    func testAGlobalCosmeticExceptionRemovesTheSelectorAndASiteOneRemovesThatSite() {
        XCTAssertTrue(classify("##.banner\n#@#.banner\n").content.hides.isEmpty)
        let scoped = classify("a.example,b.example##.banner\na.example#@#.banner\n")
        let trigger = object(scoped.content.hides[0])["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["if-domain"] as? [String], ["*b.example"], "only the site that was not excepted is left")
        XCTAssertTrue(classify("a.example##.banner\na.example#@#.banner\n").content.hides.isEmpty)
    }

    func testAnElementHidingExceptionForAWholePageSwitchesCosmeticFilteringOffThere() {
        let r = classify("##.banner\n@@||news.example^$elemhide\n")
        let trigger = object(r.content.hides[0])["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["unless-domain"] as? [String], ["*news.example"])
        let generic = classify("##.banner\nsite.example##.only-here\n@@||site.example^$generichide\n")
        let all = generic.content.hides.map { object($0)["trigger"] as? [String: Any] }
        XCTAssertTrue(all.contains { ($0?["unless-domain"] as? [String]) == ["*site.example"] }, "generic hiding is off there")
        XCTAssertTrue(all.contains { ($0?["if-domain"] as? [String]) == ["*site.example"] }, "the site's own rule is kept")
    }

    // MARK: Options

    func testBadfilterSwitchesOffTheRuleItNamesInTheSameOrAnotherList() {
        let list = "||ads.example/x.js$script\n||ads.example/x.js$script,badfilter\n||other.example/y.js$script\n"
        let r = classify(list, disabled: FilterClassifier.badfilterTargets(in: Data(list.utf8)))
        XCTAssertEqual(r.content.blocks.count, 1)
        XCTAssertEqual(r.diagnostics.disabledByBadfilter, 1)
        let elsewhere = classify("||other.example/y.js$script\n", disabled: FilterClassifier.badfilterTargets(in: Data("||other.example/y.js$script,badfilter\n".utf8)))
        XCTAssertTrue(elsewhere.content.blocks.isEmpty, "a $badfilter in another list counts")
        let domain = classify("||tracker.example^\n||tracker.example^$badfilter\n", disabled: FilterClassifier.badfilterTargets(in: Data("||tracker.example^$badfilter\n".utf8)))
        XCTAssertNotNil(domain.domainText, "the host rule is taken out of what the domain parser reads")
        XCTAssertFalse(String(decoding: domain.domainText ?? Data(), as: UTF8.self).contains("||tracker.example^\n"))
    }

    func testImportantBlocksAreKeptApartSoTheyCanComeAfterTheExceptions() {
        let r = classify("||ads.example/x.js$important\n@@||ads.example/x.js\n")
        XCTAssertEqual(r.important.count, 1)
        XCTAssertEqual(r.content.allows.count, 1)
        XCTAssertTrue(r.content.blocks.isEmpty)
        XCTAssertEqual(r.diagnostics.important, 1)
    }

    func testDocumentAndSubdocumentUseTheLoadingContext() {
        let sub = classify("||frame.example/ad.html$subdocument\n")
        let t1 = object(sub.content.blocks[0])["trigger"] as? [String: Any]
        XCTAssertEqual(t1?["load-context"] as? [String], ["child-frame"])
        XCTAssertEqual(t1?["resource-type"] as? [String], ["document"])
        let doc = classify("||page.example/landing$document\n")
        XCTAssertEqual((object(doc.content.blocks[0])["trigger"] as? [String: Any])?["load-context"] as? [String], ["top-frame"])
        let site = classify("@@||shop.example^$document\n")
        let allow = object(site.content.allows[0])
        XCTAssertEqual((allow["trigger"] as? [String: Any])?["if-domain"] as? [String], ["*shop.example"], "a $document exception is a whole-page exception")
        XCTAssertEqual((allow["action"] as? [String: Any])?["type"] as? String, "ignore-previous-rules")
    }

    func testANegatedResourceTypeMeansEveryOtherType() {
        let r = classify("||cdn.example/lib.js$~script\n||cdn.example/pic$~image,~media\n")
        let types = r.content.blocks.map { (object($0)["trigger"] as? [String: Any])?["resource-type"] as? [String] ?? [] }
        XCTAssertFalse(types[0].contains("script"))
        XCTAssertTrue(types[0].contains("image"))
        XCTAssertFalse(types[1].contains("image") || types[1].contains("media"))
        XCTAssertTrue(types[1].contains("script"))
    }

    func testRulesNeedingRewritesAreCountedWithTheirReasonAndNeverApproximated() {
        let r = classify("||a.example/x.js$redirect=noopjs\n||b.example^$csp=script-src 'none'\n||c.example/p$removeparam=utm_source\n||d.example/x$replace=/a/b/\n")
        XCTAssertEqual(r.diagnostics.unsupported, 4)
        XCTAssertTrue(r.content.blocks.isEmpty && r.important.isEmpty)
        XCTAssertEqual(r.diagnostics.reasons[FilterClassifier.needsStub], 1)
        XCTAssertEqual(r.diagnostics.reasons[FilterClassifier.rewritesLink], 1)
        XCTAssertEqual(r.diagnostics.reasons[FilterClassifier.rewritesResponse], 2)
        XCTAssertFalse(r.diagnostics.samples[FilterClassifier.needsStub]?.isEmpty ?? true)
    }

    // MARK: Regular expressions

    func testASimpleRegexBecomesOneRulePerAlternativeAndAComplexOneIsRefused() {
        let ok = classify("/ads(1|2)\\.js/$script\n/banner[0-9]+\\.png/\n")
        XCTAssertEqual(ok.content.blocks.count, 3)
        let filters = ok.content.blocks.compactMap { (object($0)["trigger"] as? [String: Any])?["url-filter"] as? String }
        XCTAssertTrue(filters.contains("ads1\\.js") && filters.contains("ads2\\.js"))
        XCTAssertTrue(filters.contains("banner[0-9]+\\.png"))
        let bad = classify("/foo{2,3}bar/\n/\\bfoo\\b/\n/(a|b)+xyz/\n/(?=foo)bar/\n/a(b(c|d))efg/\n")
        XCTAssertTrue(bad.content.blocks.isEmpty)
        XCTAssertEqual(bad.diagnostics.reasons[FilterClassifier.regexTooComplex], 5)
    }

    // MARK: Procedural filters and scriptlets

    func testProceduralFiltersBecomeRulesForThePageScript() {
        let r = classify("""
        news.example##.card:has-text(Sponsored)
        news.example##div:has(> .ad-label)
        ~safe.example##.promo:upward(2)
        shop.example#?#.item:-abp-contains(/promoted/i)
        shop.example##.row:has-text(Ad):remove()
        site.example##:xpath(//div[@class='ad'])
        """)
        XCTAssertEqual(r.scripts.procedural.count, 6)
        XCTAssertEqual(r.scripts.procedural[0].ops, [ProceduralOp(kind: "has-text", arg: "Sponsored")])
        XCTAssertEqual(r.scripts.procedural[1].ops, [])
        XCTAssertEqual(r.scripts.procedural[1].selector, "div:has(> .ad-label)")
        XCTAssertEqual(r.scripts.procedural[2].excludeDomains, ["safe.example"])
        XCTAssertEqual(r.scripts.procedural[4].action, "remove")
        XCTAssertEqual(r.scripts.procedural[5].selector, "")
        XCTAssertTrue(r.content.hides.isEmpty, "the content blocker is never given what it could reject")
        XCTAssertEqual(r.diagnostics.procedural, 6)
    }

    func testUnsafeOrUnknownProceduralFiltersAreRefusedWithAReason() {
        let r = classify("a.example##.x:matches-attr(foo)\nb.example##.y:style(background: url(http://x/y))\nc.example##.z:has-text(/(a+)+$/)\nd.example##.w:upward(2).k\n")
        XCTAssertEqual(r.diagnostics.unsupported, 4)
        XCTAssertTrue(r.scripts.procedural.isEmpty)
    }

    func testScriptletsAreKeptOnlyWhenBrowserSetuProvidesThem() {
        let r = classify("""
        example.com##+js(set-constant, adBlocked, false)
        example.com##+js(aopr, ads.config)
        example.com##+js(nostif, popup, 2000)
        example.com##+js(some-unknown-scriptlet, x)
        example.com#%#//scriptlet('abort-on-property-read', 'x')
        """)
        XCTAssertEqual(r.scripts.scriptlets.map(\.name), ["set-constant", "abort-on-property-read", "no-setTimeout-if"])
        XCTAssertEqual(r.scripts.scriptlets[0].args, ["adBlocked", "false"])
        XCTAssertEqual(r.diagnostics.unsupported, 2)
        let exception = classify("example.com##+js(aopr, ads.config)\nexample.com#@#+js(aopr, ads.config)\nother.example##+js(aopr, ads.config)\n")
        XCTAssertEqual(exception.scripts.scriptlets.count, 2)
        XCTAssertTrue(exception.scripts.scriptlets.first { $0.domains == ["example.com"] }?.excludeDomains.contains("example.com") ?? false)
    }

    func testEveryLineIsAccountedFor() {
        let list = """
        ! comment
        ||ads.example^
        ||a.example/x.js$script
        ##.banner
        a.example##.card:has-text(Ad)
        a.example##+js(aopr, x)
        @@||a.example/ok.js
        ||b.example/x$redirect=noopjs
        """
        let d = classify(list).diagnostics
        XCTAssertEqual(d.lines, 7)
        XCTAssertEqual(d.network + d.exceptions + d.cosmetic + d.procedural + d.scriptlets + d.domainRules + d.unsupported + d.important, d.lines)
    }
}

/// What the compiled rules do in the real WebKit rule compiler, and what they cost: compile time, memory, and that ordinary resources still load.
@MainActor
final class FilterMeasurementTests: XCTestCase {
    private func store() -> WKContentRuleListStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: folder) ?? .default()
    }

    private func snapshot(_ list: ClassifiedList, id: String) -> PolicySnapshot {
        let rules = list.content.blocks + list.content.hides + list.content.allows + list.important
        let json = "[" + rules.joined(separator: ",") + "]"
        return PolicySnapshot(rulesJSON: Data(json.utf8), additionalRulesJSON: [], identifier: id, domainBlockRules: 0, urlBlockRules: list.content.blocks.count,
                              elementHidingRules: list.content.hides.count, userRules: 0, siteExceptions: 0, droppedForBudget: 0, unsupportedRules: list.diagnostics.unsupported,
                              importantRules: list.important.count, diagnostics: [list.diagnostics], scriptRules: list.scripts, scriptIdentifier: list.scripts.digest,
                              failedLists: [:], listNames: [], strictExtras: [])
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    func testWebKitAcceptsEverythingTheClassifierProduces() async throws {
        let list = FilterClassifier.parse(Data("""
        ||ads.example/x.js$script
        ||ads.example/y.js$~script
        ||frame.example/ad.html$subdocument
        ||page.example/landing$document
        ||first.example/z$first-party,image
        ||dom.example/p$domain=a.example|b.example
        ||imp.example/q.js$important
        /ads(1|2)\\.js/
        /banner[0-9]+\\.png/$image
        @@||shop.example^$document
        @@||ads.example/ok.js$script
        ##.banner
        a.example,b.example##.card
        ~c.example##.promo
        ##.keep
        a.example#@#.keep
        """.utf8), name: "T")
        XCTAssertEqual(list.diagnostics.unsupported, 0, "\(list.diagnostics.reasons)")
        let report = await ContentRuleInstaller(store: store()).apply(snapshot(list, id: "setu-classifier-all"))
        XCTAssertTrue(report.installed, report.error ?? "")
        XCTAssertNil(report.error)
    }

    func testMeasureParsingCompilingAndMemoryOnALargeList() async throws {
        var lines: [String] = []
        for i in 0..<12_000 { lines.append("||tracker\(i).example/collect\(i % 97).js$script,third-party") }
        for i in 0..<6_000 { lines.append("/pixel\(i % 500)(a|b)\\.gif/$image") }
        for i in 0..<8_000 { lines.append("site\(i % 400).example##.ad-slot-\(i)") }
        for i in 0..<3_000 { lines.append("site\(i % 300).example#@#.ad-slot-\(i)") }
        for i in 0..<2_000 { lines.append("||imp\(i).example/x.js$important") }
        for i in 0..<2_000 { lines.append("news\(i % 200).example##.card:has-text(Sponsored \(i))") }
        for i in 0..<500 { lines.append("||redir\(i).example/x$redirect=noopjs") }
        let data = Data(lines.joined(separator: "\n").utf8)

        let memoryBefore = footprintMB()
        let t0 = Date()
        let list = FilterClassifier.parse(data, name: "Large")
        let parseSeconds = Date().timeIntervalSince(t0)
        let t1 = Date()
        let report = await ContentRuleInstaller(store: store()).apply(snapshot(list, id: "setu-measure-large"))
        let compileSeconds = Date().timeIntervalSince(t1)
        let memoryAfter = footprintMB()
        print("""
        FILTER MEASUREMENT lines=\(lines.count) parse=\(String(format: "%.2f", parseSeconds))s compile=\(String(format: "%.2f", compileSeconds))s \
        rules(network=\(list.content.blocks.count) hide=\(list.content.hides.count) allow=\(list.content.allows.count) important=\(list.important.count)) \
        procedural=\(list.scripts.procedural.count) unsupported=\(list.diagnostics.unsupported) memory=\(String(format: "%.0f", memoryAfter - memoryBefore))MB
        """)
        XCTAssertTrue(report.installed, report.error ?? "")
        XCTAssertLessThan(parseSeconds, 10)
        XCTAssertLessThan(compileSeconds, 60)
        XCTAssertEqual(list.diagnostics.reasons[FilterClassifier.needsStub], 500)
    }

    func testOrdinaryResourcesStillLoadWithTheRulesInstalled() async throws {
        let list = FilterClassifier.parse(Data("""
        ||blocked.test/ad.js$script
        ||blocked.test/imp.js$important
        @@||blocked.test/imp.js
        ##.ad
        """.utf8), name: "T")
        let rules = store()
        let installer = ContentRuleInstaller(store: rules)
        let config = WKWebViewConfiguration()
        installer.register(config.userContentController)
        let report = await installer.apply(snapshot(list, id: "setu-breakage-fixture"))
        XCTAssertTrue(report.installed, report.error ?? "")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), configuration: config)
        let html = "<html><body><div class='ad' style='height:20px'>ad</div><div class='content' style='height:20px'>content</div></body></html>"
        web.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        try await Task.sleep(for: .seconds(1.5))
        let hidden = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.ad')).display") as? String
        let shown = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.content')).display") as? String
        XCTAssertEqual(hidden, "none", "the ad element is hidden")
        XCTAssertEqual(shown, "block", "other content is untouched")
    }
}
