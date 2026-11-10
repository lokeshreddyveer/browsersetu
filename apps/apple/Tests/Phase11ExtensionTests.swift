import CryptoKit
import XCTest
@testable import Browser_Setu

// MARK: Helpers

enum ExtFixture {
    static func manifest(_ overrides: [String: Any?] = [:]) -> [String: Any] {
        var m: [String: Any] = [
            "manifestVersion": 1, "apiVersion": 1, "id": "org.example.sample-files", "name": "Sample Files", "version": "1.0.0", "description": "A sample.",
            "author": ["name": "Tester"], "entry": "rules.json", "capabilities": ["resolve", "filename", "category"],
            "hostPermissions": ["https://files.example.org/*"], "proposeHosts": ["https://cdn.example.org/*"], "storage": ["quotaBytes": 4096],
            "settings": [["name": "quality", "title": "Quality", "type": "string", "default": "standard", "options": ["standard", "high"]]],
        ]
        for (k, v) in overrides { if let v { m[k] = v } else { m[k] = nil } }
        return m
    }

    static func rules(_ overrides: [String: Any?] = [:]) -> [String: Any] {
        var rule: [String: Any] = [
            "id": "page", "match": "https://files.example.org/view/*",
            "resolve": ["resources": [["url": "https://cdn.example.org/files/{last}-{setting.quality}.zip", "filename": "{last}-{setting.quality}.zip", "mimeType": "application/zip", "size": 1_048_576, "title": "{last}"],
                                      ["url": "https://cdn.example.org/files/{last}.txt", "filename": "{last}-notes.txt"]]],
            "filename": "{last}.zip", "category": "Archives",
        ]
        for (k, v) in overrides { if let v { rule[k] = v } else { rule[k] = nil } }
        return ["rules": [rule]]
    }

    static func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }

    static func folder(manifest: [String: Any]? = nil, rules: [String: Any]? = nil, extra: [(String, Data)] = [], in dir: URL, name: String = UUID().uuidString) throws -> URL {
        let f = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try json(manifest ?? self.manifest()).write(to: f.appendingPathComponent("manifest.json"))
        try json(rules ?? self.rules()).write(to: f.appendingPathComponent("rules.json"))
        for (n, d) in extra { try d.write(to: f.appendingPathComponent(n)) }
        return f
    }

    static func zip(manifest: [String: Any]? = nil, rules: [String: Any]? = nil, extra: [(path: String, data: Data)] = [], in dir: URL) throws -> URL {
        var entries: [(path: String, data: Data)] = [("manifest.json", json(manifest ?? self.manifest())), ("rules.json", json(rules ?? self.rules()))]
        entries += extra
        let url = dir.appendingPathComponent("\(UUID().uuidString).zip")
        try ZipWriter.zip(entries).write(to: url)
        return url
    }

    static let url = URL(string: "https://files.example.org/view/report-2024")!
}

class ExtTestCase: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("p11-\(UUID().uuidString)"); try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    func parsed(_ m: [String: Any?] = [:]) throws -> ExtensionManifest { try ExtensionManifest.parse(ExtFixture.json(ExtFixture.manifest(m))) }
}

// MARK: Match patterns

final class ExtensionMatchPatternTests: XCTestCase {
    func testParsingAndMatching() throws {
        let p = try XCTUnwrap(ExtensionMatchPattern.parse("https://*.example.com/files/*"))
        XCTAssertTrue(p.matches(URL(string: "https://a.example.com/files/x.zip")!)); XCTAssertTrue(p.matches(URL(string: "https://example.com/files/")!))
        XCTAssertFalse(p.matches(URL(string: "http://a.example.com/files/x")!), "wrong scheme"); XCTAssertFalse(p.matches(URL(string: "https://evilexample.com/files/x")!), "not a subdomain")
        XCTAssertFalse(p.matches(URL(string: "https://example.com.evil.org/files/x")!)); XCTAssertFalse(p.matches(URL(string: "https://a.example.com/other")!))
        XCTAssertTrue(ExtensionMatchPattern.parse("*://example.com/*")!.matches(URL(string: "http://example.com/a?b=1")!), "* covers http and https, and the query")
        XCTAssertFalse(ExtensionMatchPattern.parse("*://example.com/*")!.matches(URL(string: "ftp://example.com/a")!))
        XCTAssertTrue(ExtensionMatchPattern.parse("<all_urls>")!.matches(URL(string: "https://anything.example/x")!))
    }

    func testBadPatternsAreRefused() {
        for bad in ["", "example.com/*", "ftp://example.com/*", "https://example.com", "https://exa mple.com/*", "https://*example.com/*", "https://a*.com/*", "https://.example.com/*", "https://example..com/*", "javascript://x/*", String(repeating: "a", count: 400), "https://ex\u{0}ample.com/*", "https:///*"] {
            XCTAssertNil(ExtensionMatchPattern.parse(bad), bad)
        }
    }

    func testCoverage() throws {
        let broad = ExtensionMatchPattern.parse("https://*.example.com/*")!, narrow = ExtensionMatchPattern.parse("https://files.example.com/view/*")!
        XCTAssertTrue(broad.covers(narrow)); XCTAssertFalse(narrow.covers(broad))
        XCTAssertTrue(ExtensionMatchPattern.parse("<all_urls>")!.covers(narrow)); XCTAssertFalse(broad.covers(ExtensionMatchPattern.parse("<all_urls>")!))
        XCTAssertFalse(ExtensionMatchPattern.parse("https://example.com/*")!.covers(ExtensionMatchPattern.parse("http://example.com/x")!))
        XCTAssertFalse(ExtensionMatchPattern.parse("https://example.com/*")!.covers(ExtensionMatchPattern.parse("https://example.org/x")!))
    }

    func testAPatternCannotTakeLongToMatch() {
        let started = Date()
        XCTAssertFalse(ExtensionMatchPattern.glob("*a*a*a*a*a*a*a*b", String(repeating: "a", count: 3000)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "matching is by code with no backtracking blow-up")
    }
}

// MARK: Manifest

final class ExtensionManifestTests: ExtTestCase {
    func testAValidManifest() throws {
        let m = try parsed()
        XCTAssertEqual(m.id, "org.example.sample-files"); XCTAssertEqual(m.capabilities, [.resolve, .filename, .category]); XCTAssertEqual(m.storageQuota, 4096)
        XCTAssertEqual(m.settings.first?.options, ["standard", "high"]); XCTAssertFalse(m.isBroad); XCTAssertEqual(m.permissionLines.count, 3 + 1 + 1)
    }

    func testRequiredFieldsAndVersions() {
        for key in ["manifestVersion", "apiVersion", "id", "name", "version", "entry", "capabilities"] {
            XCTAssertThrowsError(try parsed([key: nil]), key)
        }
        XCTAssertThrowsError(try parsed(["manifestVersion": 2])) { XCTAssertEqual($0 as? ExtensionManifest.Failure, .unsupportedManifest(2)) }
        XCTAssertThrowsError(try parsed(["apiVersion": 9])) { XCTAssertEqual($0 as? ExtensionManifest.Failure, .unsupportedAPI(9)) }
    }

    func testCodeRuntimesAreRefusedClearly() {
        for runtime in ["javascript", "wasm", "native"] {
            XCTAssertThrowsError(try parsed(["runtime": runtime])) { XCTAssertEqual($0 as? ExtensionManifest.Failure, .unsupportedRuntime(runtime)); XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("not supported") == true) }
        }
        XCTAssertNoThrow(try parsed(["runtime": "declarative"]))
    }

    func testBadIdsVersionsAndEntries() {
        for id in ["", "a", "Has.Upper", "has space", "x..y", ".x.y", "a/b.c", String(repeating: "a", count: 70) + ".b"] { XCTAssertThrowsError(try parsed(["id": id]), id) }
        for v in ["1", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "99999.0.0"] { XCTAssertThrowsError(try parsed(["version": v]), v) }
        for e in ["../x.json", "/abs.json", ".hidden.json", "a/../b.json", "a\\b.json", "rules.txt", "c:rules.json", "", "a//b.json"] { XCTAssertThrowsError(try parsed(["entry": e]), e) }
    }

    func testCapabilitiesPermissionsAndProposeHosts() {
        XCTAssertThrowsError(try parsed(["capabilities": ["run-anything"]])); XCTAssertThrowsError(try parsed(["capabilities": [String]()]))
        XCTAssertThrowsError(try parsed(["proposeHosts": nil]), "resolve needs the hosts it may suggest")
        for bad in ["https://*/*", "<all_urls>", "https://127.0.0.1/*", "https://localhost/*", "https://192.168.1.4/*", "https://[::1]/*", "https://nodots/*", "https://10.0.0.1/*", "https://*.local/*"] {
            XCTAssertThrowsError(try parsed(["proposeHosts": [bad]]), bad)
        }
        XCTAssertThrowsError(try parsed(["hostPermissions": ["nonsense"]]))
        XCTAssertThrowsError(try parsed(["hostPermissions": (0..<30).map { "https://h\($0).example.com/*" }]), "too many")
        XCTAssertTrue(try parsed(["hostPermissions": ["<all_urls>"]]).isBroad)
        XCTAssertNoThrow(try parsed(["capabilities": ["filename"], "proposeHosts": nil]), "an extension that only suggests names needs no hosts to suggest")
    }

    func testSettingsStorageUpdateAndIntegrity() {
        XCTAssertThrowsError(try parsed(["settings": [["name": "1bad", "type": "string"]]])); XCTAssertThrowsError(try parsed(["settings": [["name": "a", "type": "color"]]]))
        XCTAssertThrowsError(try parsed(["settings": [["name": "a", "type": "string"], ["name": "a", "type": "string"]]]), "a repeated name")
        XCTAssertThrowsError(try parsed(["settings": [["name": "n", "type": "number", "default": "x"]]]))
        XCTAssertThrowsError(try parsed(["storage": ["quotaBytes": 999_999]]))
        XCTAssertThrowsError(try parsed(["update": ["url": "http://example.org/u"]]), "https only"); XCTAssertNoThrow(try parsed(["update": ["url": "https://example.org/u"]]))
        XCTAssertThrowsError(try parsed(["integrity": ["entrySHA256": "nope"]])); XCTAssertNoThrow(try parsed(["integrity": ["entrySHA256": String(repeating: "ab", count: 32)]]))
    }

    func testSizeAndShape() {
        XCTAssertThrowsError(try ExtensionManifest.parse(Data(repeating: 0x20, count: 70_000))) { XCTAssertEqual($0 as? ExtensionManifest.Failure, .tooLarge) }
        XCTAssertThrowsError(try ExtensionManifest.parse(Data("[]".utf8))) { XCTAssertEqual($0 as? ExtensionManifest.Failure, .notJSON) }
        XCTAssertThrowsError(try ExtensionManifest.parse(Data("{".utf8)))
        XCTAssertThrowsError(try parsed(["name": "bad\u{7}name"]))
    }
}

// MARK: Rules and suggestions

final class ExtensionRuleTests: ExtTestCase {
    private func ruleSet(_ r: [String: Any?] = [:], manifest: [String: Any?] = [:]) throws -> (ExtensionManifest, ExtensionRuleSet) {
        let m = try parsed(manifest)
        return (m, try ExtensionRuleSet.parse(ExtFixture.json(ExtFixture.rules(r)), manifest: m))
    }

    private func run(_ m: ExtensionManifest, _ rs: ExtensionRuleSet, _ url: URL = ExtFixture.url, caps: Set<ExtensionManifest.Capability>? = nil, hosts: [ExtensionMatchPattern]? = nil,
                     settings: [String: String] = ["quality": "standard"]) -> ExtensionRuleEngine.Outcome {
        ExtensionRuleEngine.evaluate(manifest: m, rules: rs, input: url, grantedCapabilities: caps ?? m.capabilities, grantedHosts: hosts ?? m.hostPermissions, settings: settings)
    }

    func testTheSampleRulesProduceTheExpectedSuggestions() throws {
        let (m, rs) = try ruleSet()
        let p = try XCTUnwrap(run(m, rs).proposals.first)
        XCTAssertEqual(p.resources.map(\.url.absoluteString), ["https://cdn.example.org/files/report-2024-standard.zip", "https://cdn.example.org/files/report-2024.txt"])
        XCTAssertEqual(p.resources[0].filename, "report-2024-standard.zip"); XCTAssertEqual(p.resources[0].mimeType, "application/zip"); XCTAssertEqual(p.resources[0].size, 1_048_576); XCTAssertEqual(p.resources[0].title, "report-2024")
        XCTAssertEqual(p.filename, "report-2024.zip"); XCTAssertEqual(p.category, .archives)
        XCTAssertEqual(p.provenance, .init(extensionID: "org.example.sample-files", extensionName: "Sample Files", version: "1.0.0", rule: "page"))
        XCTAssertEqual(p.origin, .browserExtension, "a suggestion is never the person's own request")
        XCTAssertEqual(run(m, rs, settings: ["quality": "high"]).proposals.first?.resources.first?.url.lastPathComponent, "report-2024-high.zip", "settings are used")
    }

    func testRulesMustStayInsideWhatTheManifestDeclares() {
        XCTAssertThrowsError(try ruleSet(["match": "https://other.example.net/*"]), "matches addresses it did not ask to read")
        XCTAssertThrowsError(try ruleSet(["resolve": ["url": "https://{host}/x"]]), "the host of a suggestion must be written out")
        XCTAssertThrowsError(try ruleSet(["resolve": ["url": "{url}"]]))
        XCTAssertThrowsError(try ruleSet(["resolve": ["url": "https://evil.example.net/x"]]), "a host not in proposeHosts")
        XCTAssertThrowsError(try ruleSet(["resolve": ["url": "https://cdn.example.org.evil.net/x"]]))
        XCTAssertThrowsError(try ruleSet(["resolve": ["url": "ftp://cdn.example.org/x"]])); XCTAssertThrowsError(try ruleSet(["resolve": ["url": "https://cdn.example.org"]]), "no path after the host")
        XCTAssertThrowsError(try ruleSet(["filename": "{secret}"]), "unknown token"); XCTAssertThrowsError(try ruleSet(["filename": "{setting.unknown}"]), "a setting that was not declared")
        XCTAssertThrowsError(try ruleSet(["filename": "{path.99}"])); XCTAssertThrowsError(try ruleSet(["filename": "oops {last"])); XCTAssertThrowsError(try ruleSet(["filename": String(repeating: "a", count: 600)]))
        XCTAssertThrowsError(try ruleSet(["category": "Weapons"])); XCTAssertThrowsError(try ruleSet(["resolve": ["url": "https://cdn.example.org/x", "mimeType": "not a mime"]]))
        XCTAssertThrowsError(try ruleSet(["resolve": nil, "filename": nil, "category": nil]), "a rule that suggests nothing")
        XCTAssertThrowsError(try ruleSet(manifest: ["capabilities": ["filename"], "proposeHosts": nil]), "resolve used without the capability")
    }

    func testTooManyRulesAndHugeFiles() throws {
        let m = try parsed()
        let many = ["rules": (0..<150).map { ["id": "r\($0)", "match": "https://files.example.org/*", "filename": "a"] }]
        XCTAssertThrowsError(try ExtensionRuleSet.parse(ExtFixture.json(many), manifest: m)) { XCTAssertEqual($0 as? ExtensionRuleSet.Failure, .tooMany("rules")) }
        XCTAssertThrowsError(try ExtensionRuleSet.parse(Data(repeating: 0x20, count: 70_000), manifest: m)) { XCTAssertEqual($0 as? ExtensionRuleSet.Failure, .tooLarge) }
        let dup = ["rules": [["id": "a", "match": "https://files.example.org/*", "filename": "x"], ["id": "a", "match": "https://files.example.org/*", "filename": "y"]]]
        XCTAssertThrowsError(try ExtensionRuleSet.parse(ExtFixture.json(dup), manifest: m))
    }

    func testValuesCannotChangeTheShapeOfASuggestedAddress() throws {
        let (m, rs) = try ruleSet()
        for hostile in ["a@evil.com", "..%2F..%2Fetc", "x%3Fy%3D1%26z", "evil.com%2Fx", "a%00b", "%E2%80%AEgnp"] {
            let url = URL(string: "https://files.example.org/view/\(hostile)")!
            for p in run(m, rs, url).proposals { for r in p.resources { XCTAssertEqual(r.url.host, "cdn.example.org", hostile); XCTAssertNil(r.url.user); XCTAssertFalse(r.url.absoluteString.dropFirst(8).contains("//")) } }
        }
        let q = try ruleSet(["match": "https://files.example.org/*", "resolve": ["url": "https://cdn.example.org/get?id={query.id}"]])
        let out = run(q.0, q.1, URL(string: "https://files.example.org/x?id=1%26admin%3D1%23frag")!)
        XCTAssertEqual(out.proposals.first?.resources.first?.url.absoluteString, "https://cdn.example.org/get?id=1%26admin%3D1%23frag", "an & or # in a value stays inside the value")
    }

    func testMissingValuesGiveNoSuggestion() throws {
        let q = try ruleSet(["match": "https://files.example.org/*", "resolve": ["url": "https://cdn.example.org/get?id={query.id}"], "filename": nil, "category": nil])
        XCTAssertTrue(run(q.0, q.1, URL(string: "https://files.example.org/x")!).proposals.isEmpty)
        let s = try ruleSet(["match": "https://files.example.org/*", "resolve": ["url": "https://cdn.example.org/{path.3}"], "filename": nil, "category": nil])
        XCTAssertTrue(run(s.0, s.1, URL(string: "https://files.example.org/a/b")!).proposals.isEmpty)
    }

    func testOnlyWhatWasGrantedIsUsed() throws {
        let (m, rs) = try ruleSet()
        XCTAssertTrue(run(m, rs, hosts: []).proposals.isEmpty, "no host access means the extension is never even asked")
        XCTAssertTrue(run(m, rs, ExtFixture.url, hosts: [ExtensionMatchPattern.parse("https://other.example.net/*")!]).proposals.isEmpty)
        let nameOnly = run(m, rs, caps: [.filename]).proposals.first
        XCTAssertEqual(nameOnly?.filename, "report-2024.zip"); XCTAssertTrue(nameOnly?.resources.isEmpty == true); XCTAssertNil(nameOnly?.category)
        XCTAssertTrue(run(m, rs, caps: []).proposals.isEmpty)
        XCTAssertTrue(run(m, rs, URL(string: "https://files.example.org/other/page")!).proposals.isEmpty, "an address the rules do not match")
        XCTAssertTrue(run(m, rs, URL(string: "ftp://files.example.org/view/x")!).proposals.isEmpty)
    }

    func testEveryAddressIsCheckedAgainBeforeItLeaves() {
        let hosts = [ExtensionMatchPattern.parse("https://cdn.example.org/*")!]
        XCTAssertNotNil(ExtensionRuleEngine.validated("https://cdn.example.org/a.zip", proposeHosts: hosts))
        for bad in ["http://127.0.0.1/a", "https://cdn.example.org@evil.com/a", "https://user:pw@cdn.example.org/a", "javascript:alert(1)", "file:///etc/passwd", "ed2k://|file|x|1|31d6cfe0d16ae931b73c59d7e0c089c0|/",
                    "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567", "https://evil.net/a", "https://localhost/a", "https://192.168.0.1/a", "https://[::1]/a", "https://cdn.example.org.evil.net/a",
                    "https://" + String(repeating: "a", count: 3000) + ".example.org/", ""] {
            XCTAssertNil(ExtensionRuleEngine.validated(bad, proposeHosts: hosts), bad)
        }
        XCTAssertNil(ExtensionRuleEngine.validated("https://cdn.example.org/a", proposeHosts: [ExtensionMatchPattern.parse("http://cdn.example.org/*")!]), "the scheme must match too")
    }

    func testFileNamesAreMadeSafe() throws {
        let t = try ruleSet(["match": "https://files.example.org/*", "filename": "{last}", "resolve": nil, "category": nil])
        for hostile in ["..%2F..%2Fetc%2Fpasswd", "%2Fabs", "a%5Cb", "%00x"] {
            let name = run(t.0, t.1, URL(string: "https://files.example.org/v/\(hostile)")!).proposals.first?.filename
            if let name { XCTAssertFalse(name.contains("/") || name.contains("\\") || name == ".." || name.contains("\0"), "\(hostile) -> \(name)") }
        }
    }

    func testSlowEvaluationIsStopped() throws {
        let m = try parsed()
        let many = ["rules": (0..<100).map { ["id": "r\($0)", "match": "https://files.example.org/*", "filename": "a\($0)"] }]
        let rs = try ExtensionRuleSet.parse(ExtFixture.json(many), manifest: m)
        var t = 0.0
        let out = ExtensionRuleEngine.evaluate(manifest: m, rules: rs, input: ExtFixture.url, grantedCapabilities: m.capabilities, grantedHosts: m.hostPermissions, settings: [:], clock: { t += 0.02; return t }, budget: 0.05)
        XCTAssertTrue(out.timedOut); XCTAssertLessThan(out.proposals.count, 100, "a rule file cannot hold the app up")
        XCTAssertTrue(ExtensionRuleEngine.evaluate(manifest: m, rules: rs, input: URL(string: "https://files.example.org/" + String(repeating: "a", count: 3000))!, grantedCapabilities: m.capabilities, grantedHosts: m.hostPermissions, settings: [:]).proposals.isEmpty, "an oversized address is refused")
    }
}

// MARK: Storage

final class ExtensionStorageTests: ExtTestCase {
    func testValuesPersistAndAreIsolated() throws {
        let a = try ExtensionStorage(folder: root.appendingPathComponent("a"), quota: 200), b = try ExtensionStorage(folder: root.appendingPathComponent("b"), quota: 200)
        try a.set("k", "va"); try b.set("k", "vb")
        XCTAssertEqual(a.get("k"), "va"); XCTAssertEqual(b.get("k"), "vb")
        let again = try ExtensionStorage(folder: root.appendingPathComponent("a"), quota: 200)
        XCTAssertEqual(again.get("k"), "va", "it survives a restart"); XCTAssertEqual(again.used, 3)
        try a.set("k", nil); XCTAssertNil(a.get("k"))
    }

    func testQuotaKeysAndValueLimits() throws {
        let s = try ExtensionStorage(folder: root.appendingPathComponent("q"), quota: 30)
        try s.set("abc", "1234567890")
        XCTAssertThrowsError(try s.set("other", String(repeating: "x", count: 40))) { XCTAssertEqual($0 as? ExtensionStorage.Failure, .quotaExceeded) }
        XCTAssertEqual(s.get("other"), nil, "a refused write changes nothing")
        for bad in ["", "has space", "a/b", "../x", String(repeating: "k", count: 100), "ключ"] { XCTAssertThrowsError(try s.set(bad, "v"), bad) }
        let big = try ExtensionStorage(folder: nil, quota: 60_000)
        XCTAssertThrowsError(try big.set("k", String(repeating: "x", count: 5000))) { XCTAssertEqual($0 as? ExtensionStorage.Failure, .valueTooLarge) }
    }

    func testWritesAreAtomicAndLeaveNothingBehind() throws {
        let f = root.appendingPathComponent("atomic")
        let s = try ExtensionStorage(folder: f, quota: 1000)
        for i in 0..<20 { try s.set("k\(i)", "v") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.path), ["storage.json"], "no temporary file is left")
    }

    func testAPrivateStoreWritesNothing() throws {
        let s = try ExtensionStorage(folder: nil, quota: 1000)
        try s.set("secret", "value"); XCTAssertEqual(s.get("secret"), "value")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
    }

    func testDamagedOrNewerDataIsNotBelieved() throws {
        let f = root.appendingPathComponent("bad"); try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: f.appendingPathComponent("storage.json"))
        XCTAssertThrowsError(try ExtensionStorage(folder: f, quota: 100)) { XCTAssertEqual($0 as? ExtensionStorage.Failure, .unreadable) }
        try ExtFixture.json(["v": 99, "values": ["a": "b"]]).write(to: f.appendingPathComponent("storage.json"))
        XCTAssertThrowsError(try ExtensionStorage(folder: f, quota: 100), "data from a newer version is not read as if it were this one")
    }

    func testDestroyRemovesEverything() throws {
        let f = root.appendingPathComponent("gone")
        let s = try ExtensionStorage(folder: f, quota: 100); try s.set("a", "b"); s.destroy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }
}

// MARK: Manager: install, permissions, lifecycle

@MainActor
final class DownloadExtensionManagerTests: XCTestCase {
    var root: URL!
    var work: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p11m-\(UUID().uuidString)")
        work = root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func manager(_ profile: String = "default", persistent: Bool = true, folder: String = "ext") -> DownloadExtensionManager {
        DownloadExtensionManager(root: root.appendingPathComponent(folder).appendingPathComponent(profile), profile: profile, persistent: persistent)
    }

    @discardableResult
    func install(_ m: DownloadExtensionManager, manifest: [String: Any]? = nil, rules: [String: Any]? = nil, optional: Bool = false) async throws -> InstalledDownloadExtension {
        let zip = try ExtFixture.zip(manifest: manifest, rules: rules, in: work)
        return try m.install(try await m.inspect(zip), grantOptional: optional)
    }

    func testTheSampleExtensionInstallsFromItsFolderAndSuggests() async throws {
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/examples/download-extension-sample")
        let m = manager()
        let inspection = try await m.inspect(sample)
        XCTAssertEqual(inspection.manifest.id, "org.example.sample-files"); XCTAssertFalse(inspection.permissionLines.isEmpty)
        try m.install(inspection)
        let proposals = m.propose(for: ExtFixture.url)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].resources.first?.url.absoluteString, "https://cdn.example.org/files/report-2024-standard.zip")
        XCTAssertEqual(proposals[0].filename, "report-2024.zip")
        try m.setSetting("org.example.sample-files", "quality", "high")
        XCTAssertEqual(m.propose(for: ExtFixture.url).first?.resources.first?.url.lastPathComponent, "report-2024-high.zip", "the setting reaches the rules through the extension's own storage")
        XCTAssertTrue(m.propose(for: URL(string: "https://unrelated.example.net/view/x")!).isEmpty)
    }

    func testInstallingFromAZipAndFromAFolder() async throws {
        let m = manager()
        let ext = try await install(m)
        XCTAssertEqual(m.installed.count, 1); XCTAssertTrue(ext.isActive)
        XCTAssertEqual(ext.grantedHosts, ext.manifest.hostPermissions); XCTAssertEqual(ext.grantedCapabilities, ext.manifest.capabilities)
        let m2 = manager(folder: "ext2")
        let folder = try ExtFixture.folder(in: work)
        let i = try await m2.inspect(folder)
        try m2.install(i, enable: false)
        XCTAssertFalse(m2.installed[0].isActive, "installing and activating are separate steps"); XCTAssertTrue(m2.propose(for: ExtFixture.url).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: i.folder.path), "the temporary copy is cleaned up")
    }

    func testLookingAtAPackageInstallsNothing() async throws {
        let m = manager()
        let i = try await m.inspect(try ExtFixture.zip(in: work))
        XCTAssertTrue(m.installed.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ext/default/packages").path))
        m.discard(i); XCTAssertFalse(FileManager.default.fileExists(atPath: i.folder.path))
    }

    func testBadPackagesAreRefused() async throws {
        let m = manager()
        func fails(_ label: String, _ make: () throws -> URL) async { do { _ = try await m.inspect(try make()); XCTFail(label) } catch {} }
        await fails("traversal in a zip") { try ExtFixture.zip(extra: [("../evil.txt", Data("x".utf8))], in: work) }
        await fails("absolute path in a zip") { try ExtFixture.zip(extra: [("/etc/evil.txt", Data("x".utf8))], in: work) }
        await fails("not a package") { let u = work.appendingPathComponent("junk.zip"); try Data("junk".utf8).write(to: u); return u }
        await fails("no manifest") { let u = work.appendingPathComponent("nomanifest.zip"); try ZipWriter.zip([("rules.json", Data("{}".utf8))]).write(to: u); return u }
        await fails("entry missing") { try ExtFixture.zip(rules: nil, extra: [], in: work).deletingLastPathComponent().appendingPathComponent("absent.zip") }
        await fails("oversized") { try ExtFixture.zip(extra: [("big.bin", Data(count: 3 * 1024 * 1024))], in: work) }
        await fails("too many files") { try ExtFixture.zip(extra: (0..<60).map { ("f\($0).txt", Data("x".utf8)) }, in: work) }
        await fails("a script extension") { try ExtFixture.zip(manifest: ExtFixture.manifest(["runtime": "javascript"]), in: work) }
        await fails("wrong checksum") { try ExtFixture.zip(manifest: ExtFixture.manifest(["integrity": ["entrySHA256": String(repeating: "0", count: 64)]]), in: work) }
        await fails("a link in a folder") {
            let f = try ExtFixture.folder(in: work); try FileManager.default.createSymbolicLink(at: f.appendingPathComponent("link.json"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts")); return f
        }
        await fails("a rule outside the manifest") { try ExtFixture.zip(rules: ExtFixture.rules(["match": "https://elsewhere.example.net/*"]), in: work) }
        XCTAssertTrue(m.installed.isEmpty)
    }

    func testAChecksumThatMatchesIsAccepted() async throws {
        let rulesData = ExtFixture.json(ExtFixture.rules())
        let sha = DownloadIntegrityCheck.normalizedDigest(rulesData.sha256Hex) ?? ""
        let m = manager()
        let zip = work.appendingPathComponent("ok.zip")
        try ZipWriter.zip([("manifest.json", ExtFixture.json(ExtFixture.manifest(["integrity": ["entrySHA256": sha]]))), ("rules.json", rulesData)]).write(to: zip)
        let inspection = try await m.inspect(zip)
        XCTAssertNoThrow(try m.install(inspection))
    }

    func testDuplicatesAndTheLimit() async throws {
        let m = manager()
        try await install(m)
        do { try await install(m); XCTFail() } catch { XCTAssertEqual(error as? DownloadExtensionManager.Failure, .duplicate("org.example.sample-files")) }
        XCTAssertEqual(m.installed.count, 1)
    }

    func testRevokingTakesEffectAtOnce() async throws {
        let m = manager()
        let ext = try await install(m)
        XCTAssertFalse(m.propose(for: ExtFixture.url).isEmpty)
        try m.setCapability(ext.id, .resolve, granted: false)
        XCTAssertTrue(m.propose(for: ExtFixture.url).first?.resources.isEmpty == true, "no addresses once the capability is taken away")
        try m.setCapability(ext.id, .resolve, granted: true)
        try m.revokeHost(ext.id, ext.manifest.hostPermissions[0])
        XCTAssertTrue(m.propose(for: ExtFixture.url).isEmpty, "no host access, so the extension is not asked at all")
        try m.grantHost(ext.id, ext.manifest.hostPermissions[0])
        XCTAssertFalse(m.propose(for: ExtFixture.url).isEmpty)
        XCTAssertThrowsError(try m.grantHost(ext.id, ExtensionMatchPattern.parse("https://never-asked.example.net/*")!), "only what the manifest declared can be granted")
    }

    func testOptionalAccessNeedsAnExplicitGrant() async throws {
        let m = manager()
        let opt = ExtensionMatchPattern.parse("https://more.example.org/*")!
        let ext = try await install(m, manifest: ExtFixture.manifest(["optionalHostPermissions": ["https://more.example.org/*"]]), rules: ExtFixture.rules(["match": "https://more.example.org/view/*"]))
        XCTAssertFalse(ext.grantedHosts.contains(opt)); XCTAssertTrue(m.propose(for: URL(string: "https://more.example.org/view/a")!).isEmpty)
        try m.grantHost(ext.id, opt)
        XCTAssertFalse(m.propose(for: URL(string: "https://more.example.org/view/a")!).isEmpty)
    }

    func testDisableAndUninstall() async throws {
        let m = manager()
        let ext = try await install(m)
        try m.setEnabled(ext.id, false); XCTAssertTrue(m.propose(for: ExtFixture.url).isEmpty)
        try m.setEnabled(ext.id, true); XCTAssertFalse(m.propose(for: ExtFixture.url).isEmpty)
        try m.setSetting(ext.id, "quality", "high")
        let pkg = root.appendingPathComponent("ext/default/packages/\(ext.id)"), store = root.appendingPathComponent("ext/default/storage/\(ext.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        try m.uninstall(ext.id)
        XCTAssertTrue(m.installed.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: pkg.path), "files removed"); XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "stored values removed")
        XCTAssertThrowsError(try m.uninstall(ext.id)) { XCTAssertEqual($0 as? DownloadExtensionManager.Failure, .notInstalled) }
        try await install(m)           // the same id can be installed again, starting clean
        XCTAssertEqual(m.settings("org.example.sample-files")["quality"], "standard")
    }

    func testStateSurvivesARestartAndTamperingIsCaught() async throws {
        let m = manager()
        let ext = try await install(m)
        try m.setSetting(ext.id, "quality", "high"); try m.revokeHost(ext.id, ext.manifest.hostPermissions[0])
        let again = manager()
        XCTAssertEqual(again.installed.count, 1); XCTAssertTrue(again.installed[0].grantedHosts.isEmpty, "the person's revocation is remembered"); XCTAssertEqual(again.settings(ext.id)["quality"], "high")
        try again.grantHost(ext.id, ext.manifest.hostPermissions[0])
        // someone edits the rule file on disk after it was approved
        let rules = root.appendingPathComponent("ext/default/packages/\(ext.id)/\(ext.manifest.version)/rules.json")
        var text = try String(contentsOf: rules, encoding: .utf8); text = text.replacingOccurrences(of: "Archives", with: "Video"); try text.write(to: rules, atomically: true, encoding: .utf8)
        let tampered = manager()
        XCTAssertEqual(tampered.installed.count, 1)
        guard case .damaged = tampered.installed[0].status else { return XCTFail("a changed package must be marked damaged") }
        XCTAssertFalse(tampered.installed[0].enabled); XCTAssertTrue(tampered.propose(for: ExtFixture.url).isEmpty, "a damaged extension is not used")
    }

    func testProfilesDoNotShareExtensionsOrGrants() async throws {
        let a = manager("work"), b = manager("home")
        let ext = try await install(a)
        XCTAssertTrue(b.installed.isEmpty); XCTAssertTrue(b.propose(for: ExtFixture.url).isEmpty)
        try a.setSetting(ext.id, "quality", "high")
        try await install(b)
        XCTAssertEqual(b.settings(ext.id)["quality"], "standard", "another profile's value is not seen")
        try a.revokeHost(ext.id, ext.manifest.hostPermissions[0])
        XCTAssertFalse(b.propose(for: ExtFixture.url).isEmpty, "revoking in one profile does not touch the other")
    }

    func testAPrivateSessionWritesNothing() async throws {
        let m = manager(persistent: false)
        let ext = try await install(m)
        try m.setSetting(ext.id, "quality", "high")
        XCTAssertEqual(m.settings(ext.id)["quality"], "high", "it works in memory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ext").path), "nothing is written for a private session")
    }

    func testSettingsAreCheckedAndStorageIsBounded() async throws {
        let m = manager()
        let ext = try await install(m, manifest: ExtFixture.manifest(["storage": ["quotaBytes": 40], "settings": [["name": "quality", "type": "string", "options": ["a", "b"]], ["name": "n", "type": "number"], ["name": "t", "type": "string"]]]))
        XCTAssertThrowsError(try m.setSetting(ext.id, "quality", "zzz"), "not one of the choices"); XCTAssertThrowsError(try m.setSetting(ext.id, "n", "abc")); XCTAssertThrowsError(try m.setSetting(ext.id, "nope", "x"))
        try m.setSetting(ext.id, "n", "12")
        XCTAssertThrowsError(try m.setSetting(ext.id, "t", String(repeating: "x", count: 100)), "over the extension's quota")
        XCTAssertEqual(m.settings(ext.id)["n"], "12")
    }

    func testDiagnosticsAreBoundedAndHoldNoAddresses() async throws {
        let m = manager()
        let ext = try await install(m)
        for _ in 0..<150 { try m.setEnabled(ext.id, true) }
        XCTAssertLessThanOrEqual(m.diagnostics.count, 100)
        _ = m.propose(for: URL(string: "https://files.example.org/view/secret-token-123?key=abc")!)
        XCTAssertFalse(m.diagnostics.contains { $0.message.contains("secret-token") || $0.message.contains("key=abc") })
    }

    // MARK: Updates

    func testUpdateWithTheSameAccessNeedsNoApprovalAndKeepsTheGrants() async throws {
        let m = manager()
        let ext = try await install(m)
        try m.setSetting(ext.id, "quality", "high")
        let plan = try await m.prepareUpdate(try ExtFixture.zip(manifest: ExtFixture.manifest(["version": "1.1.0"]), in: work))
        XCTAssertFalse(plan.needsApproval); XCTAssertEqual(plan.from, "1.0.0")
        try m.apply(plan, approved: false)
        XCTAssertEqual(m.installed[0].manifest.version, "1.1.0"); XCTAssertEqual(m.settings(ext.id)["quality"], "high")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ext/default/packages/\(ext.id)/1.0.0").path), "the old version's files are removed after a good update")
        XCTAssertFalse(m.propose(for: ExtFixture.url).isEmpty)
    }

    func testAnUpdateThatAsksForMoreNeedsApprovalAndTheOldVersionStaysUntilThen() async throws {
        let m = manager()
        let ext = try await install(m, manifest: ExtFixture.manifest(["capabilities": ["filename"], "proposeHosts": nil]), rules: ["rules": [["id": "page", "match": "https://files.example.org/view/*", "filename": "{last}.zip"]]])
        let plan = try await m.prepareUpdate(try ExtFixture.zip(manifest: ExtFixture.manifest(["version": "2.0.0", "hostPermissions": ["https://files.example.org/*", "https://more.example.org/*"]]), rules: ExtFixture.rules(), in: work))
        XCTAssertTrue(plan.needsApproval); XCTAssertFalse(plan.addedPermissions.isEmpty)
        XCTAssertThrowsError(try m.apply(plan, approved: false)) { XCTAssertEqual($0 as? DownloadExtensionManager.Failure, .needsApproval) }
        XCTAssertEqual(m.installed[0].manifest.version, "1.0.0", "still the old version"); XCTAssertEqual(m.installed[0].grantedCapabilities, [.filename], "no new access was given silently")
        try m.apply(plan, approved: true)
        XCTAssertEqual(m.installed[0].manifest.version, "2.0.0"); XCTAssertTrue(m.installed[0].grantedCapabilities.contains(.resolve)); XCTAssertEqual(ext.id, m.installed[0].id)
    }

    func testAFailedUpdateLeavesTheOldVersionExactlyAsItWas() async throws {
        let m = manager()
        let ext = try await install(m)
        try m.setSetting(ext.id, "quality", "high")
        let plan = try await m.prepareUpdate(try ExtFixture.zip(manifest: ExtFixture.manifest(["version": "1.5.0"]), in: work))
        m.failUpdateAfterCopy = true
        XCTAssertThrowsError(try m.apply(plan, approved: true))
        XCTAssertEqual(m.installed[0].manifest.version, "1.0.0"); XCTAssertEqual(m.settings(ext.id)["quality"], "high")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ext/default/packages/\(ext.id)/1.5.0").path), "the half-installed version is removed")
        XCTAssertFalse(m.propose(for: ExtFixture.url).isEmpty, "the old version still works")
        XCTAssertEqual(manager().installed[0].manifest.version, "1.0.0", "and that is what is saved")
    }

    func testUpdatesMustBeNewerAndForTheSameExtension() async throws {
        let m = manager()
        try await install(m)
        do { _ = try await m.prepareUpdate(try ExtFixture.zip(manifest: ExtFixture.manifest(["version": "0.9.0"]), in: work)); XCTFail() } catch { XCTAssertEqual(error as? DownloadExtensionManager.Failure, .notNewer) }
        do { _ = try await m.prepareUpdate(try ExtFixture.zip(manifest: ExtFixture.manifest(["version": "1.0.0"]), in: work)); XCTFail() } catch { XCTAssertEqual(error as? DownloadExtensionManager.Failure, .notNewer) }
        do { _ = try await m.prepareUpdate(try ExtFixture.zip(manifest: ExtFixture.manifest(["id": "org.example.other"]), in: work)); XCTFail() } catch { XCTAssertEqual(error as? DownloadExtensionManager.Failure, .differentExtension) }
        XCTAssertTrue(DownloadExtensionManager.isNewer("1.10.0", than: "1.9.9")); XCTAssertFalse(DownloadExtensionManager.isNewer("1.2.3", than: "1.2.3"))
    }
}

private extension Data { var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() } }

// MARK: The download safety rule stays in force

@MainActor
final class ExtensionSecurityGateTests: XCTestCase {
    func testAnExtensionOriginIsStillRefusedByTheDownloadRule() throws {
        XCTAssertFalse(HTTPRequestPolicy.untrustedRequestsEnabled)
        XCTAssertThrowsError(try HTTPRequestPolicy(origin: .browserExtension).requireAllowedOrigin()) { XCTAssertEqual($0 as? HTTPRequestPolicy.Refusal, .untrustedRequestsDisabled) }
        XCTAssertNoThrow(try HTTPRequestPolicy(origin: .user).requireAllowedOrigin())
    }

    func testAStartRequestWithAnExtensionOriginCreatesNoTask() async throws {
        let c = DownloadCoordinator()
        c.store = FileManager.default.temporaryDirectory.appendingPathComponent("p11g-\(UUID().uuidString)")
        defer { if let s = c.store { DownloadTaskStore.close(folder: s); try? FileManager.default.removeItem(at: s) } }
        var options = HTTPDownloadRunner.Options(); options.origin = .browserExtension
        do { _ = try await c.http.start(url: URL(string: "https://cdn.example.org/files/a.zip")!, options: options); XCTFail("must be refused") }
        catch { XCTAssertEqual(error as? HTTPRequestPolicy.Refusal, .untrustedRequestsDisabled) }
        XCTAssertTrue(c.ledger.records.isEmpty, "a refused request leaves no task behind")
    }

    func testSuggestionsCarryTheirOriginAndNeverBecomeTheUsersOwn() throws {
        let m = try ExtensionManifest.parse(ExtFixture.json(ExtFixture.manifest()))
        let rs = try ExtensionRuleSet.parse(ExtFixture.json(ExtFixture.rules()), manifest: m)
        let out = ExtensionRuleEngine.evaluate(manifest: m, rules: rs, input: ExtFixture.url, grantedCapabilities: m.capabilities, grantedHosts: m.hostPermissions, settings: ["quality": "standard"])
        XCTAssertFalse(out.proposals.isEmpty)
        for p in out.proposals { XCTAssertEqual(p.origin, .browserExtension); XCTAssertEqual(p.provenance.extensionID, m.id) }
        XCTAssertFalse(DownloadRequestOrigin.browserExtension == .user)
    }

    func testOnlyHTTPAddressesAreEverSuggestedSoOtherEnginesAreNotInvolved() {
        let hosts = [ExtensionMatchPattern.parse("https://cdn.example.org/*")!]
        for link in ["magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567", "ed2k://|file|a|1|31d6cfe0d16ae931b73c59d7e0c089c0|/", "ftp://cdn.example.org/a"] {
            XCTAssertNil(ExtensionRuleEngine.validated(link, proposeHosts: hosts), link)
        }
    }

    func testTheExtensionCodeCannotReachTheDownloadSystemOrTheNetwork() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Downloads/Extensions")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 5)
        // The settings view is user interface and may name the browser model; the engine and manager files may not touch downloads, sockets, processes or code execution at all.
        for f in files where !f.lastPathComponent.contains("SettingsView") {
            let text = try String(contentsOf: f, encoding: .utf8)
            for forbidden in ["scheduleDownload", "admitTicket", "DownloadCoordinator", "DownloadLedger", "URLSession", "NWConnection", "Process(", "JSContext", "JavaScriptCore", "dlopen", "NSTask", "posix_spawn", "system(", "evaluateScript", "WKWebView"] {
                XCTAssertFalse(text.contains(forbidden), "\(f.lastPathComponent) must not use \(forbidden)")
            }
        }
    }

    func testTheDownloadSystemDoesNotDependOnExtensions() throws {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared")
        for name in ["DownloadCoordinator.swift", "DownloadCoordinator+Network.swift", "Downloads/DownloadScheduler.swift", "Downloads/HTTP/HTTPDownloadRunner.swift", "Downloads/HTTP/HTTPTransferEngine.swift"] {
            let text = try String(contentsOf: shared.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("DownloadExtensionManager") || text.contains("ExtensionProposal"), "\(name) must not depend on extensions: downloads work with none installed")
        }
    }

    func testTheInstalledListProjectsWhatTheSettingsShow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p11s-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        let m = DownloadExtensionManager(root: root, profile: "p")
        let zip = root.appendingPathComponent("a.zip"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ZipWriter.zip([("manifest.json", ExtFixture.json(ExtFixture.manifest(["hostPermissions": ["<all_urls>"]]))), ("rules.json", ExtFixture.json(ExtFixture.rules()))]).write(to: zip)
        let i = try await m.inspect(zip)
        XCTAssertTrue(i.manifest.isBroad, "an extension that asks to read everything is flagged before it is installed")
        XCTAssertTrue(i.permissionLines.contains { $0.contains("<all_urls>") || $0.contains("*://*/*") || $0.contains("*://") })
        let ext = try m.install(i)
        XCTAssertEqual(m.installed.map(\.id), [ext.id]); XCTAssertEqual(m.installed[0].status, .ready)
    }
}

// MARK: Findings from the independent review

@MainActor
final class ExtensionReviewFixTests: XCTestCase {
    var root: URL!
    var work: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("p11r-\(UUID().uuidString)")
        work = root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    func manager(_ profile: String = "default", folder: String = "ext") -> DownloadExtensionManager { DownloadExtensionManager(root: root.appendingPathComponent(folder).appendingPathComponent(profile), profile: profile) }
    @discardableResult func install(_ m: DownloadExtensionManager, manifest: [String: Any]? = nil, rules: [String: Any]? = nil) async throws -> InstalledDownloadExtension {
        try m.install(try await m.inspect(try ExtFixture.zip(manifest: manifest, rules: rules, in: work)))
    }
    func parsed(_ o: [String: Any?]) throws -> ExtensionManifest { try ExtensionManifest.parse(ExtFixture.json(ExtFixture.manifest(o))) }

    func testHostsWrittenAsNumbersInAnySpellingAreRefused() {
        for host in ["0x7f.0.0.1", "0xa9.0xfe.0xa9.0xfe", "127.1", "2130706433", "0177.0.0.1", "10.1", "1.2.3.4", "999", "cdn.0x7f.example.org", "cdn.example.org.123"] {
            XCTAssertThrowsError(try parsed(["proposeHosts": ["https://\(host)/*"]]), host)
            XCTAssertNil(ExtensionRuleEngine.validated("https://\(host)/a", proposeHosts: [ExtensionMatchPattern(scheme: "https", host: host, path: "/*")]), host)
        }
        for helper in ["nip.io", "*.nip.io", "app.sslip.io", "localtest.me", "*.lvh.me"] { XCTAssertThrowsError(try parsed(["proposeHosts": ["https://\(helper)/*"]]), helper) }
        XCTAssertNoThrow(try parsed(["proposeHosts": ["https://cdn.example.org/*"]]))
    }

    func testTheListedPathsOfProposeHostsAreEnforced() {
        let hosts = [ExtensionMatchPattern.parse("https://cdn.example.org/downloads/*")!]
        XCTAssertNotNil(ExtensionRuleEngine.validated("https://cdn.example.org/downloads/a.zip", proposeHosts: hosts))
        XCTAssertNil(ExtensionRuleEngine.validated("https://cdn.example.org/other/a.zip", proposeHosts: hosts), "outside the listed path")
    }

    func testAnUpdateGrantsOnlyWhatIsNewAndNeverSwitchesBackOnWhatWasOff() async throws {
        let m = manager()
        let ext = try await install(m)
        try m.setCapability(ext.id, .category, granted: false)
        let plan = try await m.prepareUpdate(try ExtFixture.zip(manifest: ExtFixture.manifest(["version": "1.1.0"]), in: work))
        XCTAssertFalse(plan.needsApproval)
        try m.apply(plan, approved: false)
        XCTAssertFalse(m.installed[0].grantedCapabilities.contains(.category), "what the person turned off stays off after an update")
        // and even when an update IS approved, only the newly requested access is added
        let plan2 = try await m.prepareUpdate(try ExtFixture.zip(manifest: ExtFixture.manifest(["version": "1.2.0", "hostPermissions": ["https://files.example.org/*", "https://extra.example.org/*"]]), in: work))
        try m.apply(plan2, approved: true)
        XCTAssertFalse(m.installed[0].grantedCapabilities.contains(.category)); XCTAssertTrue(m.installed[0].grantedHosts.contains(ExtensionMatchPattern.parse("https://extra.example.org/*")!))
    }

    func testAStaleOrSameVersionPlanCannotDowngradeOrDeleteTheLivePackage() async throws {
        let m = manager()
        let ext = try await install(m)
        let plan = try await m.prepareUpdate(try ExtFixture.zip(manifest: ExtFixture.manifest(["version": "1.1.0"]), in: work))
        try m.apply(plan, approved: false)
        XCTAssertThrowsError(try m.apply(plan, approved: false), "the same plan twice") { XCTAssertEqual($0 as? DownloadExtensionManager.Failure, .notNewer) }
        let live = root.appendingPathComponent("ext/default/packages/\(ext.id)/1.1.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "the live package is untouched")
        XCTAssertFalse(m.propose(for: ExtFixture.url).isEmpty)
    }

    func testSuggestionsAreComputedWithoutPublishingAnything() async throws {
        let m = manager()
        try await install(m, rules: ["rules": [["id": "p", "match": "https://files.example.org/view/*", "resolve": ["url": "https://cdn.example.org/{path.9}"], "filename": "{last}"]]])
        let before = m.diagnostics.count
        for _ in 0..<50 { _ = m.propose(for: ExtFixture.url) }
        XCTAssertEqual(m.diagnostics.count, before, "drawing a view cannot add log entries or change published state")
    }

    func testUninstallClearsDamagedStorageAndReinstallIsClean() async throws {
        let m = manager()
        let ext = try await install(m)
        try m.setSetting(ext.id, "quality", "high")
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("ext/default/storage/\(ext.id)/storage.json"))
        let again = manager()
        try again.uninstall(ext.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ext/default/storage/\(ext.id)").path), "nothing of it is left")
        try await install(again)
        XCTAssertEqual(again.settings(ext.id)["quality"], "standard")
    }

    func testDotValuesAndCredentialsNeverTravelOnward() throws {
        let m = try parsed([:])
        let rs = try ExtensionRuleSet.parse(ExtFixture.json(["rules": [["id": "a", "match": "https://files.example.org/*", "resolve": ["url": "https://cdn.example.org/f/{last}"], "filename": "{last}"],
                                                                        ["id": "b", "match": "https://files.example.org/*", "resolve": ["url": "https://cdn.example.org/g?u={url}"]]]]), manifest: m)
        func run(_ u: String) -> [ExtensionProposal] { ExtensionRuleEngine.evaluate(manifest: m, rules: rs, input: URL(string: u)!, grantedCapabilities: m.capabilities, grantedHosts: m.hostPermissions, settings: [:]).proposals }
        XCTAssertTrue(run("https://files.example.org/x/%2e%2e").allSatisfy { $0.resources.isEmpty || !$0.resources.contains { $0.url.path.hasSuffix("/..") } }, "a dot segment is never produced")
        let withCreds = run("https://user:secret@files.example.org/x?token=abc#frag")
        for p in withCreds { for r in p.resources { XCTAssertFalse(r.url.absoluteString.contains("secret")); XCTAssertFalse(r.url.absoluteString.contains("frag")) } }
        let unicode = run("https://files.example.org/x/\u{00E9}\u{4E2D}")
        for p in unicode { for r in p.resources { XCTAssertTrue(r.url.absoluteString.allSatisfy(\.isASCII), "non-ASCII values are percent-encoded") } }
    }

    func testHiddenCharactersAreRefusedInNamesAndCleanedInTitles() throws {
        XCTAssertThrowsError(try parsed(["name": "Files\u{202E}exe.pdf"])); XCTAssertThrowsError(try parsed(["description": "x\u{0085}y"]))
        XCTAssertEqual(ExtensionText.clean("a\u{202E}b\u{0085}c"), "abc")
        XCTAssertThrowsError(try parsed(["id": "org.example.files\n"]), "a trailing newline does not satisfy the id pattern")
        XCTAssertThrowsError(try parsed(["version": "1.0.0\n"]))
        XCTAssertThrowsError(try parsed(["settings": [["name": "abc\n", "type": "string"]]]))
    }

    func testAPackageOpenedForOneProfileCannotBeInstalledInAnother() async throws {
        let a = manager("work"), b = manager("home")
        let inspection = try await a.inspect(try ExtFixture.zip(in: work))
        XCTAssertThrowsError(try b.install(inspection)) ; XCTAssertTrue(b.installed.isEmpty)
        XCTAssertNoThrow(try a.install(inspection))
    }

    func testRepeatedIdsInTheSavedListAreIgnoredAndTemporaryFoldersAreCleanedUp() async throws {
        let m = manager()
        let i = try await m.inspect(try ExtFixture.zip(in: work))
        let temp = i.folder
        try m.install(i)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "the temporary copy is removed after install")
        // two entries with one id in the saved list: only one is loaded
        let index = root.appendingPathComponent("ext/default/index.json")
        let data = try Data(contentsOf: index)
        let list = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        try JSONSerialization.data(withJSONObject: list + list).write(to: index)
        XCTAssertEqual(manager().installed.count, 1)
    }
}
