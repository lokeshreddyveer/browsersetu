import XCTest
@testable import Browser_Setu

/// The local tools: one registry, every tool working on its own example, and the two new ones (UUID and JWT) held to what they promise.
@MainActor
final class ToolRegistryTests: XCTestCase {
    func testTheRegistryListsEveryToolTheSpecNamesOnceWithAnExampleThatWorks() {
        let ids = ToolRegistry.all.map(\.id)
        XCTAssertEqual(ids.sorted(), ["base64", "color", "diff", "hash", "json", "jwt", "regex", "time", "url", "uuid"])
        XCTAssertEqual(Set(ids).count, ids.count, "no tool twice")
        for tool in ToolRegistry.all {
            XCTAssertTrue(tool.platforms.contains(.mac) && tool.platforms.contains(.phone), tool.id)
            XCTAssertFalse(tool.inputs.isEmpty, tool.id)
            var values = Dictionary(uniqueKeysWithValues: tool.inputs.map { ($0.id, $0.initial) })
            for (k, v) in tool.example { values[k] = v }
            if tool.id == "jwt" { values["input"] = Self.sample(alg: "HS256", exp: Date().addingTimeInterval(3600)) }
            let out = tool.run(values)
            XCTAssertNil(out.error, "\(tool.id): \(out.error ?? "")")
            if tool.id != "jwt" { XCTAssertFalse(out.primary.isEmpty, tool.id) }
        }
        XCTAssertEqual(ToolRegistry.paletteEntries.count, 10)
        XCTAssertEqual(ToolRegistry.tool("uuid")?.title, "UUID Generator")
    }

    func testEachToolGivesTheRightAnswerAndBadInputIsSaidNotGuessed() {
        func run(_ id: String, _ values: [String: String]) -> ToolOutput { ToolRegistry.tool(id)!.run(values) }
        XCTAssertEqual(run("json", ["input": "{\"b\":1,\"a\":[1,2]}"]).rows.first { $0.label == "Minified" }?.value, "{\"a\":[1,2],\"b\":1}")
        XCTAssertNotNil(run("json", ["input": "{\"a\":"]).error)
        XCTAssertEqual(run("url", ["input": "a b&c"]).rows.first?.value, "a%20b%26c")
        XCTAssertEqual(run("base64", ["input": "Browser Setu"]).rows.first?.value, "QnJvd3NlciBTZXR1")
        XCTAssertEqual(run("hash", ["input": "abc", "algorithm": "SHA-256"]).primary, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(run("time", ["input": "0"]).rows.first { $0.label == "UTC" }?.value.contains("1970"), true)
        XCTAssertNotNil(run("regex", ["pattern": "(", "text": "x", "flags": ""]).error, "a broken pattern is reported")
        XCTAssertEqual(run("color", ["input": "#ff0000"]).rows.first { $0.label == "RGB" }?.value.contains("255"), true)
        XCTAssertNotNil(run("color", ["input": "not a colour"]).error)
        XCTAssertTrue(run("diff", ["left": "a\nb", "right": "a\nc"]).rows.first?.value.contains("1 lines the same") ?? false)
    }

    func testUUIDsAreValidDistinctAndInTheStyleAsked() {
        let standard = UUIDTool.generate(count: 5, style: .standard)
        XCTAssertEqual(Set(standard).count, 5)
        for id in standard { XCTAssertNotNil(UUID(uuidString: id)); XCTAssertEqual(id, id.lowercased()); XCTAssertEqual(Array(id)[14], "4", "version 4") }
        let upper = UUIDTool.generate(count: 1, style: .upper)[0]
        XCTAssertEqual(upper, upper.uppercased())
        XCTAssertEqual(UUIDTool.generate(count: 1, style: .compact)[0].count, 32)
        let braces = UUIDTool.generate(count: 1, style: .braces)[0]
        XCTAssertTrue(braces.hasPrefix("{") && braces.hasSuffix("}"))
        XCTAssertEqual(UUIDTool.generate(count: 500, style: .standard).count, UUIDTool.maxCount, "capped")
        XCTAssertEqual(UUIDTool.generate(count: -3, style: .standard).count, 1)
        XCTAssertTrue(ToolRegistry.tool("uuid")!.run(["count": "999", "style": "Lower case"]).warnings.contains("Limited to 50."))
    }

    static func b64(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func sample(alg: String, exp: Date?, signature: String = "c2ln") -> String {
        var claims: [String: Any] = ["sub": "1234", "iss": "https://issuer.example", "iat": Int(Date().timeIntervalSince1970) - 60]
        if let exp { claims["exp"] = Int(exp.timeIntervalSince1970) }
        return b64(["alg": alg, "typ": "JWT"]) + "." + b64(claims) + "." + signature
    }

    func testAJWTIsReadAndNeverClaimedToBeVerified() {
        let report = JWTInspector.inspect(Self.sample(alg: "HS256", exp: Date().addingTimeInterval(3600))).output
        XCTAssertNil(report.error)
        XCTAssertEqual(report.rows.first { $0.label == "Algorithm" }?.value, "HS256")
        XCTAssertEqual(report.rows.first { $0.label == "Issuer" }?.value, "https://issuer.example")
        XCTAssertTrue(report.warnings.contains { $0.contains("NOT checked") && $0.contains("Nothing was sent") }, "it says it did not verify, and sent nothing")
        XCTAssertTrue(report.warnings.contains("It has not expired."))
        let expired = JWTInspector.inspect(Self.sample(alg: "HS256", exp: Date().addingTimeInterval(-3600))).output
        XCTAssertTrue(expired.warnings.contains { $0.hasPrefix("It has expired") })
        let unsigned = JWTInspector.inspect(Self.sample(alg: "none", exp: nil, signature: "")).output
        XCTAssertTrue(unsigned.warnings.contains { $0.contains("not signed at all") })
        XCTAssertTrue(unsigned.warnings.contains("There is no signature part."))
        XCTAssertTrue(unsigned.warnings.contains("It has no expiry."))
        XCTAssertTrue(JWTInspector.inspect("Bearer " + Self.sample(alg: "RS256", exp: nil)).output.error == nil, "a Bearer prefix is allowed")
        for bad in ["", "abc", "a.b.c.d", "not.base64.here", Self.b64(["alg": "HS256"]) + "." + "!!!" + ".x"] { XCTAssertNotNil(JWTInspector.inspect(bad).output.error, bad) }
    }

    func testNothingTypedIntoAToolIsKeptAndNoToolCanReachTheNetwork() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Shared/ToolRegistry.swift", "Shared/ToolsPanel.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["URLSession", "NWConnection", "saveSetting", "UserDefaults", "WebLoginVault", "recordHistory", "@AppStorage", "SceneStorage"] {
                XCTAssertFalse(text.contains(forbidden), "\(file) uses \(forbidden)")
            }
        }
        let panel = try String(contentsOf: root.appendingPathComponent("Shared/ToolsPanel.swift"), encoding: .utf8)
        XCTAssertTrue(panel.contains(".onDisappear { values = [:]; output = ToolOutput() }"), "what was typed, and the result made from it, are cleared when the panel closes")
    }

    func testThePaletteListsEveryToolAndOpensThePanelOnIt() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-tools-\(UUID().uuidString)", profile: "default")
        await m.start()
        let items = m.paletteItems(query: "tool")
        for entry in ToolRegistry.paletteEntries { XCTAssertTrue(items.contains { $0.id == "tool-\(entry.id)" }, entry.id) }
        items.first { $0.id == "tool-jwt" }?.run()
        XCTAssertEqual(m.toolSelection, "jwt")
        XCTAssertEqual(m.sheet, .tools)
    }
}
