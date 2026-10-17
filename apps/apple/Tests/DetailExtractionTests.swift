import XCTest
@testable import Browser_Setu

final class DetailExtractionTests: XCTestCase {
    func testFindsPhoneEmailAndDate() {
        let found = DetailExtractor.find(in: "Call 415-555-0134 or write hello@example.com before December 3, 2031 at 6pm.")
        XCTAssertTrue(found.contains { $0.kind == .phone })
        XCTAssertTrue(found.contains { $0.kind == .email && $0.text == "hello@example.com" })
        XCTAssertTrue(found.contains { $0.kind == .event && $0.date != nil })
    }

    func testNoFalsePositivesInPlainSentence() {
        XCTAssertTrue(DetailExtractor.find(in: "A quiet walk through the park.").isEmpty)
    }

    func testCalendarFileIsWellFormedAndEscaped() {
        let ics = CardFiles.calendarEvent(title: "Lunch, then; walk", start: Date(timeIntervalSince1970: 1_700_000_000), duration: 5400, link: "https://a.test/x", uid: "u1")
        XCTAssertTrue(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(ics.contains("SUMMARY:Lunch\\, then\\; walk"))
        XCTAssertTrue(ics.contains("DTSTART:20231114T221320Z"))
        XCTAssertTrue(ics.contains("DTEND:20231114T234320Z"))
        XCTAssertTrue(ics.hasSuffix("END:VCALENDAR\r\n"))
    }

    func testContactCardCarriesEveryDetail() {
        let vcf = CardFiles.contactCard(name: nil, phones: ["415-555-0134"], emails: ["a@b.test"], address: "1 Main St")
        XCTAssertTrue(vcf.contains("TEL:415-555-0134"))
        XCTAssertTrue(vcf.contains("EMAIL:a@b.test"))
        XCTAssertTrue(vcf.contains("ADR:;;1 Main St;;;;"))
    }
}
