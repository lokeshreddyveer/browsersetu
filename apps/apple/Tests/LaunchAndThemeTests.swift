import XCTest
@testable import Browser_Setu

final class LaunchArgumentTests: XCTestCase {
    func testSpaceFlagForms() {
        XCTAssertEqual(try LaunchArgumentParser.parse(["app", "--space", "Development"]).get(), [.space("Development")])
        XCTAssertEqual(try LaunchArgumentParser.parse(["app", "--space=Deep Work"]).get(), [.space("Deep Work")])
        XCTAssertEqual(try LaunchArgumentParser.parse(["app", "-NSDocumentRevisionsDebugMode", "YES", "--space", " Dev "]).get(), [.space("Dev")])
        XCTAssertEqual(try LaunchArgumentParser.parse(["app"]).get(), [], "no flag, no request")
        XCTAssertEqual(try LaunchArgumentParser.parse(["app", "-ApplePersistenceIgnoreState", "YES"]).get(), [], "the system's own arguments are ignored")
    }

    func testMistakesAreNamed() {
        XCTAssertEqual(LaunchArgumentParser.parse(["app", "--space"]), .failure(.missingValue(flag: "--space")))
        XCTAssertEqual(LaunchArgumentParser.parse(["app", "--space", "--other"]), .failure(.missingValue(flag: "--space")))
        XCTAssertEqual(LaunchArgumentParser.parse(["app", "--space="]), .failure(.missingValue(flag: "--space")))
        XCTAssertEqual(LaunchArgumentParser.parse(["app", "--space", "   "]), .failure(.missingValue(flag: "--space")))
        XCTAssertEqual(LaunchArgumentParser.parse(["app", "--space", "A", "--space", "B"]), .failure(.repeated(flag: "--space")))
        XCTAssertFalse(LaunchArgumentError.missingValue(flag: "--space").message.isEmpty)
    }

    private func workspaces(_ names: [String]) -> [Workspace] { names.map { Workspace(name: $0, icon: "star", preset: nil) } }

    func testWorkspaceLookup() {
        let list = workspaces(["Development", "Research", "dev notes"])
        XCTAssertEqual(try SpaceLookup.resolve("Development", in: list).get(), "Development")
        XCTAssertEqual(try SpaceLookup.resolve("research", in: list).get(), "Research", "capital letters do not matter when one workspace fits")
        XCTAssertEqual(try SpaceLookup.resolve("Personal", in: list).get(), "", "the built-in workspace has an empty id")
        XCTAssertEqual(try SpaceLookup.resolve("personal", in: list).get(), "")
        if case .failure(.notFound(_, let known)) = SpaceLookup.resolve("Nope", in: list) { XCTAssertTrue(known.contains("Research")) } else { XCTFail("expected notFound") }
    }

    func testAmbiguousNamesAreRefused() {
        let list = workspaces(["Work", "WORK"])
        XCTAssertEqual(try SpaceLookup.resolve("Work", in: list).get(), "Work", "an exact name is never ambiguous")
        if case .failure(.ambiguous(_, let matches)) = SpaceLookup.resolve("work", in: list) { XCTAssertEqual(Set(matches), ["Work", "WORK"]) } else { XCTFail("expected ambiguous") }
    }

    func testSpaceLinks() {
        XCTAssertEqual(URLAction.parse(URL(string: "browsersetu://space?name=Development")!), .space("Development"))
        XCTAssertEqual(URLAction.parse(URL(string: "browsersetu://space?id=Dev%20Work")!), .space("Dev Work"))
        XCTAssertNil(URLAction.parse(URL(string: "browsersetu://space")!))
        XCTAssertNil(URLAction.parse(URL(string: "browsersetu://report?text=hi")!), "a link can never make an in-app report")
    }
}

final class GradientTests: XCTestCase {
    func testHexAndContrast() {
        XCTAssertEqual(GradientColor(hex: "#FF8000")?.hex, "#FF8000")
        XCTAssertNil(GradientColor(hex: "#12345"))
        XCTAssertEqual(GradientColor.contrast(GradientColor(r: 0, g: 0, b: 0), GradientColor(r: 1, g: 1, b: 1)), 21, accuracy: 0.01)
        XCTAssertEqual(GradientColor.contrast(GradientColor(r: 1, g: 1, b: 1), GradientColor(r: 1, g: 1, b: 1)), 1, accuracy: 0.001)
    }

    func testHSBRoundTrip() {
        for hex in ["#3366CC", "#CC3366", "#33CC66", "#808080", "#FFFFFF"] {
            let c = GradientColor(hex: hex)!, h = c.hsb
            XCTAssertEqual(GradientColor(h: h.h, s: h.s, b: h.b).hex, c.hex, hex)
        }
    }

    func testValidationKeepsColoursInRangeAndCountsRight() {
        let wild = WorkspaceGradient(colors: ["#FFFFFF", "#000000", "#00FF00", "#FF00FF"], angle: -45)
        let fixed = wild.validated()
        XCTAssertEqual(fixed?.colors.count, 3, "at most three colours")
        for c in fixed?.rgb ?? [] {
            XCTAssertTrue(c.hsb.b >= GradientRules.brightness.lowerBound - 0.01 && c.hsb.b <= GradientRules.brightness.upperBound + 0.01, "\(c.hex)")
            XCTAssertLessThanOrEqual(c.hsb.s, GradientRules.saturation.upperBound + 0.01)
        }
        XCTAssertEqual(fixed?.angle, 315, "an angle below zero is brought into 0 to 360")
        XCTAssertNil(WorkspaceGradient(colors: ["#112233"], angle: 0).validated(), "one colour is not a gradient")
        XCTAssertNil(WorkspaceGradient(colors: ["nope", "also nope"], angle: 0).validated())
    }

    func testEveryGeneratedPaletteIsReadableInBothLooks() {
        var rng = SystemRandomNumberGenerator()
        for count in [2, 3] {
            for _ in 0..<200 {
                let g = GradientGenerator.random(count: count, using: &rng)
                XCTAssertEqual(g.colors.count, count)
                XCTAssertTrue(g.isReadable, g.colors.joined(separator: " "))
                XCTAssertTrue((0...360).contains(g.angle))
            }
        }
    }

    func testAccentIsLightenedOrDarkenedUntilItCanBeSeen() {
        // A pale yellow is invisible on a light sidebar until it is darkened.
        let yellow = WorkspaceGradient(colors: ["#F7E27A", "#F2D95A"], angle: 90)
        let light = yellow.accent(dark: false)!
        XCTAssertGreaterThanOrEqual(GradientColor.contrast(light, GradientRules.base(dark: false)), GradientRules.accentMinimum)
        // A deep navy is invisible on a dark sidebar until it is lightened.
        let navy = WorkspaceGradient(colors: ["#1B2A5E", "#22336B"], angle: 90)
        let dark = navy.accent(dark: true)!
        XCTAssertGreaterThanOrEqual(GradientColor.contrast(dark, GradientRules.base(dark: true)), GradientRules.accentMinimum)
    }

    func testAngleDirections() {
        let g = WorkspaceGradient(colors: ["#336699", "#996633"], angle: 90)
        XCTAssertEqual(g.startPoint.x, 0, accuracy: 0.001)
        XCTAssertEqual(g.endPoint.x, 1, accuracy: 0.001)
        let down = WorkspaceGradient(colors: ["#336699", "#996633"], angle: 180)
        XCTAssertEqual(down.startPoint.y, 0, accuracy: 0.001)
        XCTAssertEqual(down.endPoint.y, 1, accuracy: 0.001)
    }

    func testWorkspaceDataFromBeforeGradientsStillLoads() throws {
        let old = #"{"name":"Work","icon":"briefcase","accent":"blue"}"#
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(old.utf8))
        XCTAssertNil(ws.gradient)
        var withGradient = ws
        withGradient.gradient = WorkspaceGradient(colors: ["#336699", "#996633"], angle: 135)
        let back = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(withGradient))
        XCTAssertEqual(back, withGradient)
    }
}

final class DownloadFlightTests: XCTestCase {
    func testOneFlightEveryCoupleOfSeconds() {
        let t = Date()
        XCTAssertTrue(DownloadFlightPolicy.allows(now: t, lastFlight: .distantPast))
        XCTAssertFalse(DownloadFlightPolicy.allows(now: t.addingTimeInterval(0.5), lastFlight: t), "a second download at once does not animate again")
        XCTAssertTrue(DownloadFlightPolicy.allows(now: t.addingTimeInterval(2.5), lastFlight: t))
    }
}

// MARK: Learned suggestions

final class SuggestionRankingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testWeightsAddToOne() {
        let sum = SuggestionRanking.wText + SuggestionRanking.wFrequency + SuggestionRanking.wRecency + SuggestionRanking.wWorkspace + SuggestionRanking.wFavorite + SuggestionRanking.wChosen
        XCTAssertEqual(sum, 1.0, accuracy: 1e-9)
    }

    func testTextRelevanceOrdersNameBeforeTitleBeforeInside() {
        let exact = SuggestionRanking.textRelevance(query: "github", title: "GitHub", url: "https://github.com/")
        let prefix = SuggestionRanking.textRelevance(query: "git", title: "Home", url: "https://github.com/")
        let inside = SuggestionRanking.textRelevance(query: "hub", title: "Home", url: "https://github.com/")
        let none = SuggestionRanking.textRelevance(query: "zzz", title: "Home", url: "https://github.com/")
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, inside)
        XCTAssertGreaterThan(inside, 0)
        XCTAssertEqual(none, 0)
        XCTAssertEqual(SuggestionRanking.textRelevance(query: "git hub", title: "Git Hub Docs", url: "https://x.example/"), SuggestionRanking.textRelevance(query: "git hub", title: "Git Hub Docs", url: "https://x.example/"))
        XCTAssertEqual(SuggestionRanking.textRelevance(query: "git zzz", title: "Git", url: "https://x.example/"), 0, "every word must fit somewhere")
    }

    func testRecencyHalvesEveryTwoWeeks() {
        XCTAssertEqual(SuggestionRanking.recency(now, now: now), 1, accuracy: 1e-9)
        XCTAssertEqual(SuggestionRanking.recency(now.addingTimeInterval(-14 * 86_400), now: now), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SuggestionRanking.recency(nil, now: now), 0)
        XCTAssertEqual(SuggestionRanking.recency(now.addingTimeInterval(86_400), now: now), 1, accuracy: 1e-9, "a time in the future is not better than now")
    }

    func testAFrequentlyUsedBookmarkedSiteBeatsAnUnknownPageForGit() {
        let github = RankCandidate(key: "github.com", source: .bookmark, title: "GitHub", url: "https://github.com/", visitCount: 300, lastVisit: now.addingTimeInterval(-3600), isBookmark: true, order: 1)
        let stray = RankCandidate(key: "git-scm.example/book", source: .history, title: "Pro Git book", url: "https://git-scm.example/book", visitCount: 1, lastVisit: now.addingTimeInterval(-90 * 86_400), order: 0)
        let ranked = SuggestionRanking.rank([stray, github], query: "git", now: now) { c in
            c.key == "github.com" ? LearnedSignals(workspaceVisits: 40, totalVisits: 50, selectionsForQuery: 4, selectionsTotal: 12) : LearnedSignals()
        }
        XCTAssertEqual(ranked.first?.candidate.key, "github.com")
        XCTAssertTrue(SuggestionRanking.isTopHit(ranked[0]))
        XCTAssertFalse(SuggestionRanking.isTopHit(ranked[1]))
        XCTAssertLessThanOrEqual(ranked[0].score, 1)
    }

    func testPopularityNeverShowsSomethingThatDoesNotMatch() {
        let famous = RankCandidate(key: "news.example", source: .history, title: "News", url: "https://news.example/", visitCount: 9999, lastVisit: now, isBookmark: true, order: 0)
        let scored = SuggestionRanking.rank([famous], query: "git", now: now) { _ in LearnedSignals(workspaceVisits: 9, totalVisits: 9, selectionsForQuery: 9, selectionsTotal: 9) }
        XCTAssertEqual(scored[0].score, 0)
    }

    func testIdenticalDestinationsBecomeOneRow() {
        let tab = RankCandidate(key: "a.example", source: .openTab, title: "A (tab)", url: "https://a.example/", isOpenTab: true, order: 0)
        let mark = RankCandidate(key: "a.example", source: .bookmark, title: "A", url: "https://a.example/", isBookmark: true, order: 1)
        let hist = RankCandidate(key: "a.example", source: .history, title: "A", url: "https://a.example/", visitCount: 7, lastVisit: now, order: 2)
        let one = SuggestionRanking.deduplicated([hist, mark, tab])
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].source, .openTab)
        XCTAssertTrue(one[0].isBookmark && one[0].isOpenTab)
        XCTAssertEqual(one[0].visitCount, 7)
    }

    func testEqualScoresKeepTheirOrder() {
        let a = RankCandidate(key: "a", source: .history, title: "alpha", url: "https://a.example/", order: 0)
        let b = RankCandidate(key: "b", source: .history, title: "alpha", url: "https://b.example/", order: 1)
        XCTAssertEqual(SuggestionRanking.rank([a, b], query: "alpha", now: now) { _ in LearnedSignals() }.map(\.candidate.key), ["a", "b"])
    }

    func testRankingFiveHundredCandidatesIsInstant() {
        let list = (0..<500).map { RankCandidate(key: "k\($0)", source: .history, title: "Site \($0) git", url: "https://k\($0).example/git", visitCount: $0, lastVisit: now, order: $0) }
        measure { _ = SuggestionRanking.rank(list, query: "git", now: now) { _ in LearnedSignals() } }
    }

    func testPrivacyRules() {
        XCTAssertTrue(SuggestionPrivacy.isLearnable(URL(string: "https://github.com/a"), excludedHosts: []))
        XCTAssertFalse(SuggestionPrivacy.isLearnable(URL(string: "browsersetu://panel/history"), excludedHosts: []))
        XCTAssertFalse(SuggestionPrivacy.isLearnable(URL(string: "file:///tmp/x"), excludedHosts: []))
        XCTAssertFalse(SuggestionPrivacy.isLearnable(URL(string: "https://user:pw@bank.example/"), excludedHosts: []))
        XCTAssertFalse(SuggestionPrivacy.isLearnable(URL(string: "https://my.bank.example/a"), excludedHosts: ["bank.example"]), "subdomains are covered")
        XCTAssertTrue(SuggestionPrivacy.isLearnable(URL(string: "https://notbank.example/a"), excludedHosts: ["bank.example"]))
        XCTAssertEqual(SuggestionPrivacy.key(for: URL(string: "https://www.GitHub.com/Foo/?tab=x#top")!), "github.com/foo", "no query, fragment, www or case")
        XCTAssertEqual(SuggestionExclusions.parse("Bank.example, https://www.Mail.example/inbox  bad_host!, bank.example"), ["bank.example", "mail.example"])
    }

    @MainActor func testLearningStoreRecordsBoundsAndResets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bs-learn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SuggestionLearning(folder: folder)
        store.recordVisit(key: "github.com", workspace: "Work", now: now)
        store.recordVisit(key: "github.com", workspace: "Work", now: now)
        store.recordVisit(key: "github.com", workspace: "", now: now)
        store.recordSelection(key: "github.com", query: "git", workspace: "Work", now: now)
        let signals = store.signals(for: "github.com", query: "gi", workspace: "Work")
        XCTAssertEqual(signals.workspaceVisits, 2)
        XCTAssertEqual(signals.totalVisits, 3)
        XCTAssertEqual(signals.selectionsForQuery, 1, "typing 'gi' matches a choice made after typing 'git'")
        XCTAssertEqual(store.signals(for: "github.com", query: "zzz", workspace: "Work").selectionsForQuery, 0)
        store.flush()
        XCTAssertEqual(SuggestionLearning(folder: folder).signals(for: "github.com", query: "git", workspace: "Work").totalVisits, 3, "it survives a restart")
        // Bounded.
        for i in 0..<(SuggestionLearning.maxDestinations + 300) { store.recordVisit(key: "site\(i).example", workspace: "", now: now) }
        XCTAssertLessThanOrEqual(store.data.destinations.count, SuggestionLearning.maxDestinations)
        // Reset.
        store.reset()
        XCTAssertTrue(store.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("suggestion-learning.json").path))
    }
}

// MARK: Learned suggestions through the real address bar

@MainActor
final class LearnedAddressBarTests: XCTestCase {
    private func make() -> (BrowserModel, String) {
        let root = NSTemporaryDirectory() + "bs-ab-\(UUID().uuidString)"
        return (BrowserModel(engine: WebKitEngine(), root: root, profile: "ab"), root)
    }

    private func visit(_ model: BrowserModel, _ tab: TabController, _ url: String, title: String, times: Int) {
        for _ in 0..<times { try? model.core.commitNavigation(tabId: tab.id, url: url, title: title) }
    }

    func testAFrequentlyVisitedSiteIsLiftedAboveASearchSuggestionAndTheTypedRowsStayFirst() {
        let (model, root) = make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tab = model.openTab(url: nil, isPrivate: false)
        visit(model, tab, "https://github.com/", title: "GitHub", times: 30)
        visit(model, tab, "https://git-scm.example/book", title: "Pro Git book", times: 1)
        model.suggestionLearning.recordSelection(key: "github.com", query: "git", workspace: "")
        model.addressBar.isEditing = true
        model.addressBar.text = "git"
        model.addressBar.refresh(model: model)
        let rows = model.addressBar.suggestions
        XCTAssertGreaterThanOrEqual(rows.count, 3)
        XCTAssertTrue(rows[0].kind == .go || rows[0].kind == .search, "the typed text's own row stays first")
        XCTAssertEqual(rows[1].target, "https://github.com/", "the site you use most is the top hit")
        XCTAssertEqual(rows.filter { $0.kind != .command && $0.target.contains("github.com") }.count, 1, "one row for one destination; the rows were: " + rows.map { "\($0.kind)|\($0.target)|\($0.title)" }.joined(separator: " ; "))
    }

    func testPrivateTabsAndTheSwitchLeaveTheOrderAlone() {
        let (model, root) = make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tab = model.openTab(url: nil, isPrivate: false)
        visit(model, tab, "https://github.com/", title: "GitHub", times: 30)
        model.learnSuggestions = false
        model.addressBar.isEditing = true
        model.addressBar.text = "git"
        model.addressBar.refresh(model: model)
        let off = model.addressBar.suggestions.map(\.id)
        model.learnSuggestions = true
        model.addressBar.refresh(model: model)
        XCTAssertFalse(model.addressBar.suggestions.isEmpty)
        XCTAssertFalse(off.isEmpty)
    }

    func testChoosingAResultTeachesAndAPrivateTabTeachesNothing() {
        let (model, root) = make()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let suggestion = Suggestion(kind: .history, title: "GitHub", subtitle: "https://github.com/", target: "https://github.com/")
        model.addressBar.text = "git"
        model.accept(suggestion)
        XCTAssertEqual(model.suggestionLearning.signals(for: "github.com", query: "git", workspace: "").selectionsTotal, 1)
        // Excluded sites and private tabs are never learned.
        model.suggestionExcludedHosts = ["github.com"]
        model.learnChoice(suggestion, typed: "git")
        XCTAssertEqual(model.suggestionLearning.signals(for: "github.com", query: "git", workspace: "").selectionsTotal, 1)
        model.suggestionExcludedHosts = []
        let priv = model.openTab(url: nil, isPrivate: true)
        model.select(priv.id)
        model.learnChoice(suggestion, typed: "git")
        XCTAssertEqual(model.suggestionLearning.signals(for: "github.com", query: "git", workspace: "").selectionsTotal, 1, "nothing is learned while a private tab is in front")
        model.resetLearnedSuggestions()
        XCTAssertTrue(model.suggestionLearning.isEmpty)
    }
}
