import XCTest
@testable import Browser_Setu

/// A place that does not exist yet, inside a folder reached through a link (the sandbox's Downloads folder is one), is judged by where the link really leads.
final class PathPolicyLinkTests: XCTestCase {
    private var base: URL!
    private var real: URL!
    private var link: URL!
    private var elsewhere: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-policy-\(UUID().uuidString)", isDirectory: true)
        real = base.appendingPathComponent("real", isDirectory: true)
        elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func testANewPlaceInsideALinkedRootIsInsideTheRealRoot() {
        XCTAssertTrue(DownloadPathPolicy.isAuthorized(link.appendingPathComponent("new-folder").path, roots: [real]))
        XCTAssertTrue(DownloadPathPolicy.isAuthorized(link.appendingPathComponent("a/b/c.bin").path, roots: [real]), "several missing levels")
        XCTAssertTrue(DownloadPathPolicy.isAuthorized(real.appendingPathComponent("new").path, roots: [link]), "the root may be the link")
    }

    func testAPlaceThatExistsStillWorks() throws {
        try Data("x".utf8).write(to: real.appendingPathComponent("here.bin"))
        XCTAssertTrue(DownloadPathPolicy.isAuthorized(link.appendingPathComponent("here.bin").path, roots: [real]))
    }

    func testAnotherFolderIsNotAuthorizedWhetherOrNotItExists() {
        XCTAssertFalse(DownloadPathPolicy.isAuthorized(elsewhere.appendingPathComponent("x.bin").path, roots: [real]))
        XCTAssertFalse(DownloadPathPolicy.isAuthorized(base.appendingPathComponent("never/x.bin").path, roots: [real]))
    }

    func testALinkInsideTheRootThatLeadsOutIsNotFollowedOut() throws {
        let escape = real.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: elsewhere)
        XCTAssertFalse(DownloadPathPolicy.isAuthorized(escape.appendingPathComponent("x.bin").path, roots: [real]), "a new file behind a link that leaves the folder")
        XCTAssertFalse(DownloadPathPolicy.isAuthorized(escape.path, roots: [real]))
    }

    func testADanglingLinkIsJudgedByWhereItPoints() throws {
        let dangling = real.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: elsewhere.appendingPathComponent("missing"))
        XCTAssertFalse(DownloadPathPolicy.isAuthorized(dangling.path, roots: [real]))
    }

    func testDotDotCannotClimbOut() {
        XCTAssertFalse(DownloadPathPolicy.isAuthorized(real.path + "/../elsewhere/x.bin", roots: [real]))
    }
}
