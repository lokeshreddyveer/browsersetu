import XCTest
import SetuPrivacyCore
@testable import Browser_Setu

/// A rule build that fails must never take working protection away, and the screen must say what is true.
@MainActor
final class ProtectionFailureTests: XCTestCase {
    private func controller() throws -> (PrivacyController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bs-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let core = try BrowserCore.open(root: root.path, profile: "fail-test")
        let privacy = PrivacyController(engine: WebKitEngine(), cacheDirectory: root.appendingPathComponent("lists"))
        privacy.load(from: core)
        return (privacy, root)
    }

    func testAFailedBuildKeepsTheRulesThatAreWorkingAndSaysSo() async throws {
        let (privacy, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        await privacy.apply(includeDownloaded: false)
        let working = try XCTUnwrap(privacy.snapshot, "the built-in rules were built")
        XCTAssertEqual(privacy.report?.installed, true)

        privacy.builder = { _, _ in .failed("The rules could not be put together.") }
        await privacy.apply(includeDownloaded: false)
        XCTAssertEqual(privacy.snapshot?.identifier, working.identifier, "the rules in use are still the old ones")
        XCTAssertEqual(privacy.report?.installed, true, "and they are still installed")
        XCTAssertEqual(privacy.report?.removed, false)
        XCTAssertTrue(privacy.report?.error?.contains("still on") == true, privacy.report?.error ?? "nil")
        XCTAssertFalse(privacy.isApplying)

        privacy.builder = { config, downloaded in PolicyBuilder.outcome(configuration: config, downloaded: downloaded) }
        await privacy.apply(includeDownloaded: false)
        XCTAssertNil(privacy.report?.error, "a good build afterwards clears the problem")
        XCTAssertEqual(privacy.report?.installed, true)
    }

    func testAFailedFirstBuildDoesNotClaimProtectionIsOn() throws {
        let report = PrivacyController.failedBuildReport("The rules are too large for the browser to load.", previous: nil, previousReport: nil)
        XCTAssertFalse(report.installed)
        XCTAssertTrue(report.error?.contains("No protection rules are active") == true)
    }

    func testSwitchingProtectionOffStillRemovesTheRules() async throws {
        let (privacy, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        await privacy.apply(includeDownloaded: false)
        XCTAssertEqual(privacy.report?.installed, true)
        privacy.builder = { _, _ in .disabled }
        await privacy.apply(includeDownloaded: false)
        XCTAssertNil(privacy.snapshot, "off means the rules are gone")
        XCTAssertEqual(privacy.report?.removed, true)
    }

    func testTheKitSaysTheDifferenceBetweenOffEmptyAndBuilt() {
        var config = PrivacyConfiguration()
        config.adBlocking = false; config.antiTracking = false
        if case .disabled = PolicyBuilder.outcome(configuration: config) {} else { XCTFail("off") }
        XCTAssertNil(PolicyBuilder.build(configuration: config))
        config.adBlocking = true
        if case .built = PolicyBuilder.outcome(configuration: config) {} else { XCTFail("the default rules build") }
    }

    func testTheFailureBranchNeverReachesTheEngine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/Privacy/PrivacyController.swift")
        let text = try String(contentsOf: root, encoding: .utf8)
        let apply = try XCTUnwrap(text.range(of: "func apply(includeDownloaded"))
        let body = String(text[apply.lowerBound...].prefix(1600))
        let failed = try XCTUnwrap(body.range(of: "case .failed(let reason) = outcome"))
        let engineCall = try XCTUnwrap(body.range(of: "engine.applyProtection"))
        XCTAssertLessThan(failed.lowerBound, engineCall.lowerBound, "a failed build returns before the engine is touched")
        XCTAssertTrue(body[failed.lowerBound...engineCall.lowerBound].contains("return"))
    }
}
