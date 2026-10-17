import XCTest
@testable import Browser_Setu

final class ImportToolsTests: XCTestCase {
    func testCSVHandlesQuotesCommasAndLineBreaksInsideFields() {
        let rows = CSV.parse("a,b,c\r\n\"x, y\",\"he said \"\"hi\"\"\",\"line1\nline2\"\n\n,,\n")
        XCTAssertEqual(rows[0], ["a", "b", "c"])
        XCTAssertEqual(rows[1], ["x, y", "he said \"hi\"", "line1\nline2"])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(CSV.parse("\u{FEFF}name,url\n")[0], ["name", "url"])
    }

    func testChromeAndAppleAndFirefoxFilesAreAllRead() {
        let chrome = "name,url,username,password,note\nexample.com,https://example.com/login,me@x.test,pw1,\n"
        let apple = "Title,URL,Username,Password,Notes,OTPAuth\nShop,https://shop.test,bob,\"p,w\"\"2\",,\n"
        let firefox = "url,username,password,httpRealm,formActionOrigin\nhttps://mozilla.test,ann,pw3,,\n"
        XCTAssertEqual(PasswordImport.parse(csv: chrome).logins.map(\.user), ["me@x.test"])
        XCTAssertEqual(PasswordImport.parse(csv: chrome).logins.first?.origin, "https://example.com")
        XCTAssertEqual(PasswordImport.parse(csv: apple).logins.first?.password, "p,w\"2")
        XCTAssertEqual(PasswordImport.parse(csv: firefox).logins.first?.origin, "https://mozilla.test")
    }

    func testInsecureIncompleteAndDuplicateRowsAreSkippedAndCounted() {
        let csv = "url,username,password\nhttp://plain.test,a,b\nhttps://ok.test,,pw\nhttps://ok.test,u,pw\nhttps://ok.test,u,pw\njavascript:alert(1),u,pw\nhttps://x.test,u,\n"
        let r = PasswordImport.parse(csv: csv)
        XCTAssertEqual(r.logins.count, 1)
        XCTAssertEqual(r.skippedInsecure, 1)
        XCTAssertEqual(r.skippedDuplicate, 1)
        XCTAssertGreaterThanOrEqual(r.skippedIncomplete, 3)
        let again = PasswordImport.parse(csv: csv, existing: r.logins)
        XCTAssertTrue(again.logins.isEmpty, "importing the same file twice adds nothing")
        XCTAssertTrue(PasswordImport.parse(csv: "nonsense\nvalue").logins.isEmpty)
    }

    func testExportRoundTripsAndNeutralisesSpreadsheetFormulas() {
        let logins = [WebLogin(origin: "https://a.test", user: "me", password: "p,w\"x"), WebLogin(origin: "https://b.test", user: "=cmd|' /C calc'!A0", password: "pw")]
        let csv = PasswordImport.csv(for: logins)
        let back = PasswordImport.parse(csv: csv).logins
        XCTAssertEqual(back.first { $0.origin == "https://a.test" }?.password, "p,w\"x")
        XCTAssertFalse(csv.contains(",=cmd"), "a field starting with = must not reach a spreadsheet as a formula")
    }

    func testGeneratedPasswordsAreLongMixedAndDifferent() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let p = PasswordGenerator.make(length: 20)
            XCTAssertEqual(p.count, 20)
            XCTAssertTrue(p.contains { $0.isLowercase } && p.contains { $0.isUppercase } && p.contains { $0.isNumber } && p.contains { "!@#$%^&*-_=+?".contains($0) })
            XCTAssertFalse(p.contains { "lIO01".contains($0) }, "look-alike characters are left out")
            seen.insert(p)
        }
        XCTAssertEqual(seen.count, 200)
        XCTAssertEqual(PasswordGenerator.make(length: 3).count, 12)
        XCTAssertFalse(PasswordGenerator.make(length: 30, symbols: false).contains { "!@#$%^&*-_=+?".contains($0) })
    }

    func testHistoryFromChromeTakeoutAndSafariAreMergedPerPage() {
        let takeout = "{\"Browser History\":[{\"url\":\"https://a.test\",\"title\":\"A\",\"time_usec\":1700000000000000},{\"url\":\"https://a.test\",\"title\":\"\",\"time_usec\":1700005000000000},{\"url\":\"https://b.test\",\"title\":\"B\",\"time_usec\":1690000000000000}]}"
        let visits = HistoryImport.parse(json: Data(takeout.utf8)).sorted { $0.url < $1.url }
        XCTAssertEqual(visits.count, 2)
        XCTAssertEqual(visits[0].count, 2)
        XCTAssertEqual(visits[0].seconds, 1_700_005_000)
        XCTAssertEqual(visits[0].title, "A")
        let safari = "{\"history\":[{\"url\":\"https://c.test\",\"title\":\"C\",\"time_usec\":1600000000000000}]}"
        XCTAssertEqual(HistoryImport.parse(json: Data(safari.utf8)).first?.seconds, 1_600_000_000)
        XCTAssertTrue(HistoryImport.parse(json: Data("not json".utf8)).isEmpty)
    }
}
