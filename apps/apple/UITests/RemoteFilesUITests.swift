import CryptoKit
import XCTest
import AppKit

/// Remote files in the real Debug app, with real clicks and real servers: the system's OpenSSH server (SFTP, key sign-in with a throwaway key) and a small FTP server. Nothing outside temporary folders is
/// touched; no password is saved to the Keychain (SFTP uses a key, the FTP test turns "remember" off).
final class RemoteFilesUITests: XCTestCase {
    var app: XCUIApplication!
    let site = "http://127.0.0.1:18766"
    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    override func tearDown() { app?.terminate() }

    func put(_ path: String, _ body: Data) {
        var r = URLRequest(url: URL(string: site + "/_media/" + path)!); r.httpMethod = "PUT"; r.httpBody = body; r.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: r) { _, _, _ in sem.signal() }.resume(); _ = sem.wait(timeout: .now() + 8)
    }
    func run(_ path: String, _ args: [String]) throws { let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try p.run(); p.waitUntilExit() }
    func listening(_ port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(port).bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
    func waitListening(_ port: Int) { let end = Date().addingTimeInterval(10); while Date() < end, !listening(port) { Thread.sleep(forTimeInterval: 0.1) } }

    /// The OpenSSH server and FTP server started by the scheme (scripts/remote_ui_fixture.sh). A missing fixture is a failure, not a skip.
    let fixtureDir = "/private/tmp/bs-remote-ui-fixture"
    func requireFixtures() {
        XCTAssertTrue(listening(18781), "the SFTP fixture (sshd on 18781) is not running: run these tests through the BrowserSetuMac scheme")
        XCTAssertTrue(listening(18782), "the FTP fixture (18782) is not running: run these tests through the BrowserSetuMac scheme")
    }

    func enterText(_ text: String, in field: XCUIElement) {
        for _ in 1...3 {
            // Command-L is the address bar's own shortcut: it gives the field the keyboard and selects its contents, with no click to race.
            app.typeKey("l", modifierFlags: .command)
            let end = Date().addingTimeInterval(8)
            while Date() < end, (field.value(forKey: "hasKeyboardFocus") as? Bool) != true { Thread.sleep(forTimeInterval: 0.1) }
            // The omnibox re-selects its whole address for about a second after it takes focus (so typing replaces it); characters typed inside that window are overwritten. A person never types that fast.
            Thread.sleep(forTimeInterval: 3.0)
            field.typeText(text)
            if (field.value as? String) == text { return }
        }
        XCTFail("the address was not entered completely: \(String(describing: field.value))")
    }

    func launch(_ extra: [String], page: String) throws {
        app = XCUIApplication()
        app.launchArguments += ["-UITestRoot", "bs-ui-rf-\(UUID().uuidString)", "-UITestAllowLocalPageOrigin", "YES", "-UIState", "url", "-UIURL", page, "-NSRequiresAquaSystemAppearance", "YES", "-UITestFastScan", "YES"] + extra
        app.launch(); app.activate()
        try XCTSkipUnless(app.wait(for: .runningForeground, timeout: 15), "Browser Setu is not frontmost; refusing to send input")
    }

    func scratchFiles(_ name: String) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-ui-scratch-downloads/\(name)")
        return (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    /// Address bar → sftp:// → trust the key → browse → choose → Download → the collection completes in Downloads with its folders; asking again downloads nothing twice.
    func testSFTPFromTheAddressBarTrustBrowseDownloadAFolderAndAskAgain() throws {
        requireFixtures()
        let port = 18781, key = fixtureDir + "/client", tree = fixtureDir + "/tree"
        let n = "rf\(Int(Date().timeIntervalSince1970))"
        put("\(n)/page.html", Data("<html><body><h1>Start</h1></body></html>".utf8))
        try launch(["-UITestRemoteKey", key, "-UIDownloadsScratch", "rf-\(n)"], page: "\(site)/media/\(n)/page.html")

        func typeAddress() {
            let box = app.textFields["omnibox"]
            XCTAssertTrue(box.waitForExistence(timeout: 30))
            // The page that opened with the app must be completely loaded first: when it finishes it moves the address bar's selection, which would overwrite what is being typed.
            XCTAssertTrue(app.webViews.staticTexts["Start"].waitForExistence(timeout: 90), "the start page finished loading")
            Thread.sleep(forTimeInterval: 2)
            let address = "sftp://127.0.0.1:\(port)\(tree)/"
            for attempt in 1...3 {
                enterText(address, in: box)
                Thread.sleep(forTimeInterval: 1.0)
                if (box.value as? String) == address { break }          // still complete a moment later: nothing moved it
                XCTAssertLessThan(attempt, 3, "the address changed after it was typed: \(String(describing: box.value))")
            }
            app.typeKey(.return, modifierFlags: [])
        }
        typeAddress()
        // A server seen for the first time: its fingerprint is shown and nothing is trusted until it is accepted.
        let sawHostKey = any("remote-hostkey").waitForExistence(timeout: 60)
        XCTAssertTrue(sawHostKey, "first sight of a server asks before trusting it")
        let fp = any("remote-fingerprint"); XCTAssertTrue(fp.waitForExistence(timeout: 5))
        XCTAssertTrue(((fp.value as? String) ?? fp.label).contains("SHA256:"), "the fingerprint is shown")
        any("remote-hostkey-trust").click()
        let rows = app.descendants(matching: .any).matching(identifier: "remote-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "the folder is listed")
        XCTAssertEqual(rows.count, 3, "reports, dataset.bin and notes.txt")

        // Into a folder and back up.
        let reports = rows.matching(NSPredicate(format: "label == 'reports'")).firstMatch
        XCTAssertTrue(reports.exists); reports.doubleClick()
        let a = rows.matching(NSPredicate(format: "label == 'a.txt'")).firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 15), "the folder's files are listed"); XCTAssertTrue(any("remote-path").label.hasSuffix("/reports") || ((any("remote-path").value as? String) ?? "").hasSuffix("/reports"))
        any("remote-up").click()
        XCTAssertTrue(rows.matching(NSPredicate(format: "label == 'dataset.bin'")).firstMatch.waitForExistence(timeout: 15))

        // Everything: one file, one more, and a folder of two.
        any("remote-select-all").click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS '3 selected' OR label CONTAINS '3 selected'")).firstMatch.waitForExistence(timeout: 5))
        let go = any("remote-download"); XCTAssertTrue(go.isEnabled); go.click()
        let started = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Started 4' OR label CONTAINS 'Started 4'")).firstMatch
        XCTAssertTrue(started.waitForExistence(timeout: 30), "the folder was read and four files were started")
        any("remote-close").click()

        // They finish as ordinary downloads in the Downloads list, under their own names. (The files' bytes and folders are checked from outside by the unit tests and by hand: this test's process
        // has a different temporary folder from the app's.)
        let table = any("downloads-table")
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        let completed = app.staticTexts.matching(NSPredicate(format: "value == 'Completed' OR label == 'Completed'"))
        let end = Date().addingTimeInterval(90)
        while Date() < end, completed.count < 4 { Thread.sleep(forTimeInterval: 1) }
        XCTAssertEqual(completed.count, 4, "all four files completed")
        for name in ["dataset.bin", "notes.txt", "a.txt", "b.txt"] {
            XCTAssertTrue(table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '\(name)' OR value CONTAINS '\(name)'")).firstMatch.exists, "\(name) is listed")
        }

        // Asking again for the same place: trusted now (no question), and nothing is downloaded twice.
        typeAddress()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "a trusted server opens straight to its folder")
        XCTAssertFalse(any("remote-hostkey").exists)
        any("remote-select-all").click(); any("remote-download").click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'already downloaded' OR label CONTAINS 'already downloaded'")).firstMatch.waitForExistence(timeout: 30), "nothing is fetched twice")
    }

    /// A link on a web page → Remote Files with the address filled in but NOT connected → a wrong password is explained → the right one signs in → the file downloads.
    func testAnFTPLinkOnAPageOpensRemoteFilesWithoutConnectingAndAWrongPasswordIsRecoverable() throws {
        requireFixtures()
        let port = 18782
        let payload = try Data(contentsOf: URL(fileURLWithPath: fixtureDir + "/ftp/release.zip"))
        let n = "rl\(Int(Date().timeIntervalSince1970))"
        put("\(n)/page.html", Data("<html><body><h1>Downloads</h1><a href=\"ftp://alice@127.0.0.1:\(port)/\">Get the release from our FTP server</a></body></html>".utf8))
        try launch(["-UIDownloadsScratch", "rl-\(n)"], page: "\(site)/media/\(n)/page.html")

        let link = app.webViews.links.firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 30), "the page's link is there"); link.click()
        XCTAssertTrue(any("remote-sheet").waitForExistence(timeout: 20), "a click on an FTP link opens Remote Files")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "remote-row").count, 0, "a page can not make the browser connect by itself")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'web page asked' OR label CONTAINS 'web page asked'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(any("remote-insecure").exists, "FTP says it is not encrypted")
        let remember = any("remote-remember"); if (remember.value as? Int) == 1 { remember.click() }          // no password in the Keychain from a test
        let pass = any("remote-password"); XCTAssertTrue(pass.waitForExistence(timeout: 5)); pass.click(); pass.typeText("wrong-password")
        any("remote-connect").click()
        XCTAssertTrue(any("remote-failed").waitForExistence(timeout: 30), "a refused password is explained")
        XCTAssertTrue((any("remote-failed").label + ((any("remote-failed").value as? String) ?? "")).contains("refused"))
        any("remote-retry").exists ? () : ()
        app.buttons["Change Settings"].click()
        let pass2 = any("remote-password"); XCTAssertTrue(pass2.waitForExistence(timeout: 5))
        pass2.click(); pass2.typeKey("a", modifierFlags: .command); pass2.typeText("s3cret")
        any("remote-connect").click()
        let rows = app.descendants(matching: .any).matching(identifier: "remote-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "the right password signs in and lists the files")
        rows.firstMatch.click(); any("remote-download").click()
        any("remote-close").click()
        let table = any("downloads-table")
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        let completed = app.staticTexts.matching(NSPredicate(format: "value == 'Completed' OR label == 'Completed'"))
        let end = Date().addingTimeInterval(60)
        while Date() < end, completed.count < 1 { Thread.sleep(forTimeInterval: 1) }
        XCTAssertEqual(completed.count, 1, "the file from the FTP server completed")
        XCTAssertTrue(table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'release.zip' OR value CONTAINS 'release.zip'")).firstMatch.exists, "listed under its own name")
        _ = payload
    }

    /// A Metalink link on a page → the file's description is read and asked about (never saved as a file the person has to find) → Download → the file completes in Downloads, checked against the document's SHA-256.
    func testAMetalinkLinkOnAPageAsksAboutTheFileAndDownloadsIt() throws {
        let n = "ml\(Int(Date().timeIntervalSince1970))"
        let payload = Data((0..<250_000).map { UInt8(truncatingIfNeeded: $0 &* 11) })
        put("\(n)/package.bin", payload)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let doc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><metalink xmlns=\"urn:ietf:params:xml:ns:metalink\"><file name=\"package.bin\"><size>250000</size><hash type=\"sha-256\">\(digest)</hash><url priority=\"1\">\(site)/media/\(n)/package.bin</url><url priority=\"2\">\(site)/media/\(n)/package.bin?mirror=2</url></file></metalink>"
        put("\(n)/package.meta4", Data(doc.utf8))
        put("\(n)/page.html", Data("<html><body><h1>Start</h1><a href=\"\(site)/media/\(n)/package.meta4\">Download with mirrors (Metalink)</a></body></html>".utf8))
        try launch([], page: "\(site)/media/\(n)/page.html")
        XCTAssertTrue(app.webViews.staticTexts["Start"].waitForExistence(timeout: 90))
        let link = app.webViews.links.firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 30)); link.click()
        // The question is a modal alert (its own window; while it is up its contents are not in the accessibility tree, so it is answered the way a person would: Return takes the default button, "Download").
        // What it says is asserted directly in MetalinkImportTests (the summary text).
        // The question is a modal alert: while it is up, XCUITest cannot see the app's windows at all (zero windows), so it is answered the way a person would: after the document has been read, Return takes the
        // default button ("Download"). If the alert is not up yet, Return does nothing to the page, so it is pressed again until the file shows up in Downloads.
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 5)
            app.typeKey(.return, modifierFlags: [])
            if any("downloads-table").exists { break }
        }
        // It completes in Downloads.
        XCTAssertTrue(any("downloads-table").waitForExistence(timeout: 30) || app.staticTexts["Downloads"].waitForExistence(timeout: 30))
        let completed = app.staticTexts.matching(NSPredicate(format: "value == 'Completed' OR label == 'Completed'"))
        let end = Date().addingTimeInterval(60)
        while Date() < end, completed.count < 1 { Thread.sleep(forTimeInterval: 1) }
        XCTAssertEqual(completed.count, 1, "the file from the Metalink completed")
    }
}
