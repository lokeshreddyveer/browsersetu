import XCTest
@testable import Browser_Setu

final class QuickAnswerTests: XCTestCase {
    private func text(_ q: String) -> String? { QuickAnswer.answer(for: q)?.text }

    func testSumsFollowTheUsualOrderAndBrackets() {
        XCTAssertEqual(text("2+3*4"), "14")
        XCTAssertEqual(text("(2+3)*4"), "20")
        XCTAssertEqual(text("2^3^2"), "512")
        XCTAssertEqual(text("-3 + 5"), "2")
        XCTAssertEqual(text("10 / 4"), "2.5")
        XCTAssertEqual(text("12 × 3"), "36")
        XCTAssertEqual(text("1,000 * 2"), "2000")
        XCTAssertEqual(text("sqrt(16) + abs(-2)"), "6")
        XCTAssertEqual(text("200 * 15%"), "30")
        XCTAssertEqual(text("0.1 + 0.2"), "0.3")
    }

    func testPercentOf() {
        XCTAssertEqual(text("15% of 80"), "12")
        XCTAssertEqual(text("7.5% of 200"), "15")
    }

    func testThingsThatAreNotQuestionsAreLeftAlone() {
        for q in ["2024", "pi", "e", "apple", "2024-10-17", "1.1.1.1", "5 / 0", "(2+", "sqrt(-1)", "hello world", "3 +", "", "x"] {
            XCTAssertNil(QuickAnswer.answer(for: q), q)
        }
    }

    func testUnitsConvertBothWaysAndOnlyWithinAKind() {
        XCTAssertEqual(text("5 km to mi"), "3.10686 mi")
        XCTAssertEqual(text("1 mile in km"), "1.60934 km")
        XCTAssertEqual(text("100 c to f"), "212 °F")
        XCTAssertEqual(text("72 f in c"), "22.2222 °C")
        XCTAssertEqual(text("0 c to k"), "273.15 K")
        XCTAssertEqual(text("2 kg to lb"), "4.40925 lb")
        XCTAssertEqual(text("1 gb to mb"), "1000 MB")
        XCTAssertEqual(text("90 min to h"), "1.5 h")
        XCTAssertNil(QuickAnswer.answer(for: "5 km to kg"), "length is not mass")
        XCTAssertNil(QuickAnswer.answer(for: "5 parsec to km"))
    }
}

final class BreachCheckTests: XCTestCase {
    func testTheHashIsSplitTheWayTheServiceExpects() {
        let parts = BreachCheck.split("password")
        XCTAssertEqual(parts.prefix, "5BAA6")
        XCTAssertEqual(parts.suffix, "1E4C9B93F3F0682250B6CF8331B7EE68FD8")
    }

    func testCountsAreReadFromTheRangeAndPaddingMeansNotFound() {
        let body = "0018A45C4D1DEF81644B54AB7F969B88D65:3\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:9545824\r\n011053FD0102E94D6AE2F8B83D76FAF94F6:0"
        XCTAssertEqual(BreachCheck.count(of: "1E4C9B93F3F0682250B6CF8331B7EE68FD8", in: body), 9_545_824)
        XCTAssertEqual(BreachCheck.count(of: "011053FD0102E94D6AE2F8B83D76FAF94F6", in: body), 0)
        XCTAssertEqual(BreachCheck.count(of: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", in: body), 0)
    }

    func testScanFindsLeaksAndReuseAndSendsOnlyPrefixes() async throws {
        let logins = [
            WebLogin(origin: "https://a.test", user: "me", password: "password"),
            WebLogin(origin: "https://b.test", user: "me", password: "password"),
            WebLogin(origin: "https://c.test", user: "me", password: "Zq!8-unique-horse-battery"),
        ]
        var asked: [String] = []
        let result = try await BreachCheck.scan(logins) { prefix in
            asked.append(prefix)
            return prefix == "5BAA6" ? "1E4C9B93F3F0682250B6CF8331B7EE68FD8:12" : ""
        }
        XCTAssertEqual(asked.count, 2, "two passwords share one prefix, so that is one request")
        XCTAssertTrue(asked.allSatisfy { $0.count == 5 })
        XCTAssertEqual(result[logins[0].id]?.leaks, 12)
        XCTAssertEqual(result[logins[0].id]?.reusedOn, ["b.test"])
        XCTAssertEqual(result[logins[2].id]?.isProblem, false)
        XCTAssertTrue(BreachCheck.summary(result, checked: 3).contains("2 found in known leaks"))
    }

    func testAnUnreachableServiceStopsTheScanInsteadOfCallingEverythingSafe() async {
        let logins = [WebLogin(origin: "https://a.test", user: "me", password: "x1")]
        do { _ = try await BreachCheck.scan(logins) { _ in throw BreachCheck.Failure.unreachable }; XCTFail("should throw") } catch {}
    }
}
