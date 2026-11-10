import XCTest
@testable import Browser_Setu

/// The decisions the HTTP engine makes that need no network: where a download may go, what a header or a filename may be, what a response means.
final class HTTPRequestPolicyTests: XCTestCase {
    private let user = HTTPRequestPolicy(origin: .user)
    private let script = HTTPRequestPolicy(origin: .automation)

    func testHostsAreClassifiedByWhatTheyAre() {
        let cases: [(String, HostClass)] = [
            ("example.com", .publicHost), ("93.184.216.34", .publicHost), ("1.1.1.1", .publicHost),
            ("127.0.0.1", .loopback), ("127.8.9.10", .loopback), ("localhost", .loopback), ("foo.localhost", .loopback), ("::1", .loopback), ("[::1]", .loopback),
            ("10.0.0.5", .privateNetwork), ("172.16.0.1", .privateNetwork), ("172.31.255.255", .privateNetwork), ("192.168.1.1", .privateNetwork), ("100.64.0.1", .privateNetwork),
            ("fd12:3456::1", .privateNetwork), ("169.254.169.254", .linkLocal), ("fe80::1", .linkLocal),
            ("0.0.0.0", .unspecified), ("::", .unspecified), ("224.0.0.1", .unspecified),
            ("printer.local", .localName), ("intranet", .localName), ("nas.home.arpa", .localName),
            ("::ffff:127.0.0.1", .loopback), ("::ffff:10.1.2.3", .privateNetwork),
        ]
        for (host, expected) in cases { XCTAssertEqual(HTTPRequestPolicy.classify(host: host), expected, host) }
        XCTAssertEqual(HTTPRequestPolicy.classify(host: "172.32.0.1"), .publicHost, "outside 172.16/12")
    }

    func testOnlyAPersonsOwnRequestsMayReachTheirNetwork() throws {
        XCTAssertNoThrow(try user.check(URL(string: "http://192.168.1.10/file.zip")!))
        XCTAssertNoThrow(try user.check(URL(string: "http://localhost:8080/a")!))
        XCTAssertThrowsError(try script.check(URL(string: "http://192.168.1.10/file.zip")!)) { XCTAssertEqual($0 as? HTTPRequestPolicy.Refusal, .internalAddress("192.168.1.10")) }
        XCTAssertThrowsError(try script.check(URL(string: "http://169.254.169.254/latest/meta-data")!), "the cloud metadata address")
        XCTAssertThrowsError(try HTTPRequestPolicy(origin: .browserExtension).check(URL(string: "https://localhost/x")!))
        XCTAssertNoThrow(try script.check(URL(string: "https://example.com/a.zip")!))
    }

    func testOnlyHttpAndHttpsAreFetched() {
        for bad in ["file:///etc/passwd", "ftp://example.com/a", "data:text/plain,hi", "javascript:alert(1)", "magnet:?xt=urn:btih:abc", "ed2k://%7Cfile%7Cx%7C1%7Ch%7C/"] {
            let url = try? XCTUnwrap(URL(string: bad), bad)
            if let url { XCTAssertThrowsError(try user.check(url), bad) }
        }
        if let nohost = URL(string: "https:///nohost") { XCTAssertThrowsError(try user.check(nohost)) }
    }

    func testRedirectsAreFollowedOnlyToSafePlaces() {
        let a = URL(string: "https://a.example/start")!, b = URL(string: "https://b.example/next")!
        XCTAssertEqual(user.decideRedirect(from: a, to: b, chain: [a]), .follow(dropCredentials: true), "a different origin never gets the credentials")
        XCTAssertEqual(user.decideRedirect(from: a, to: URL(string: "https://a.example/other")!, chain: [a]), .follow(dropCredentials: false))
        XCTAssertEqual(user.decideRedirect(from: a, to: URL(string: "https://a.example:8443/other")!, chain: [a]), .follow(dropCredentials: true), "another port is another origin")
        XCTAssertEqual(user.decideRedirect(from: a, to: URL(string: "http://a.example/plain")!, chain: [a]), .refuse(.insecureRedirect), "https to http is a downgrade")
        XCTAssertEqual(user.decideRedirect(from: URL(string: "http://a.example/")!, to: URL(string: "https://a.example/")!, chain: []), .follow(dropCredentials: true), "http to https is fine (and a different origin)")
        XCTAssertEqual(user.decideRedirect(from: a, to: URL(string: "file:///etc/passwd")!, chain: [a]), .refuse(.unsupportedScheme("file")))
        XCTAssertEqual(user.decideRedirect(from: a, to: URL(string: "ftp://a.example/x")!, chain: [a]), .refuse(.unsupportedScheme("ftp")))
    }

    func testAPublicSiteCannotSendADownloadIntoTheNetwork() {
        let site = URL(string: "https://files.example/a")!
        for target in ["http://127.0.0.1/admin", "https://192.168.0.1/", "http://169.254.169.254/", "http://localhost:9200/", "http://printer.local/"] {
            guard case .refuse = user.decideRedirect(from: site, to: URL(string: target)!, chain: [site]) else { XCTFail("\(target) must be refused even for the person's own request"); continue }
        }
        // For a secure public site the reason is the network, not the downgrade.
        for target in ["https://192.168.0.1/", "https://127.0.0.1/", "https://169.254.169.254/", "https://localhost/"] {
            guard case .refuse(.redirectIntoInternalNetwork) = user.decideRedirect(from: site, to: URL(string: target)!, chain: [site]) else { XCTFail("\(target)"); continue }
        }
        // From one internal address to another, for the person's own request, is their business; for a script it is not.
        let nas = URL(string: "http://192.168.1.2/a")!
        XCTAssertEqual(user.decideRedirect(from: nas, to: URL(string: "http://192.168.1.3/b")!, chain: [nas]), .follow(dropCredentials: true))
        XCTAssertEqual(script.decideRedirect(from: nas, to: URL(string: "http://192.168.1.3/b")!, chain: [nas]), .refuse(.redirectIntoInternalNetwork("192.168.1.3")))
    }

    func testLoopsAndLongChainsAreStopped() {
        let a = URL(string: "https://a.example/1")!, b = URL(string: "https://a.example/2")!
        XCTAssertEqual(user.decideRedirect(from: b, to: a, chain: [a, b]), .refuse(.redirectLoop))
        XCTAssertEqual(user.decideRedirect(from: b, to: URL(string: "https://A.EXAMPLE/1#frag")!, chain: [a, b]), .refuse(.redirectLoop), "case and fragment do not hide a loop")
        let chain = (0..<12).map { URL(string: "https://a.example/\($0)")! }
        XCTAssertEqual(user.decideRedirect(from: chain.last!, to: URL(string: "https://a.example/new")!, chain: chain), .refuse(.tooManyRedirects))
    }

    func testOnlyApprovedHeadersGoOut() {
        let (kept, dropped) = user.sanitize(["Accept": "*/*", "Cookie": "session=1", "Authorization": "Bearer t", "Host": "evil", "Range": "bytes=0-", "X-Anything": "1", "Referer": "https://a/"])
        XCTAssertEqual(Set(kept.keys), ["Accept", "Authorization", "Referer"])
        XCTAssertEqual(Set(dropped), ["Cookie", "Host", "Range", "X-Anything"])
        let (scriptKept, scriptDropped) = script.sanitize(["Authorization": "Bearer t", "Accept": "*/*"])
        XCTAssertEqual(Set(scriptKept.keys), ["Accept"], "a script cannot attach credentials")
        XCTAssertEqual(scriptDropped, ["Authorization"])
        XCTAssertTrue(user.sanitize(["Accept": "a\r\nInjected: 1"]).kept.isEmpty, "a header value cannot carry a line break")
    }

    func testSignedAddressesAreRedactedAndRecognised() {
        let url = URL(string: "https://user:pw@files.example/path/file.zip?X-Amz-Signature=abc123&expires=999&name=report#frag")!
        let text = DownloadURLRedactor.redact(url)
        XCTAssertEqual(text, "https://files.example/path/file.zip?X-Amz-Signature=***&expires=***&name=***")
        XCTAssertFalse(text.contains("abc123")); XCTAssertFalse(text.contains("pw")); XCTAssertFalse(text.contains("frag"))
        XCTAssertTrue(DownloadURLRedactor.looksSigned(url))
        XCTAssertFalse(DownloadURLRedactor.looksSigned(URL(string: "https://files.example/a.zip?page=2")))
        XCTAssertEqual(DownloadURLRedactor.redact(nil), "(no address)")
    }
}

final class DownloadFilenameTests: XCTestCase {
    private func name(_ cd: String?, _ url: String? = nil, mime: String? = nil) -> String { DownloadFilename.derive(contentDisposition: cd, url: url.flatMap(URL.init(string:)), mimeType: mime).name }

    func testAHeadersFilenameComesFirstThenTheAddressThenAFallback() {
        XCTAssertEqual(name("attachment; filename=\"report.pdf\"", "https://x.test/other.bin"), "report.pdf")
        XCTAssertEqual(name(nil, "https://x.test/files/data.csv?x=1"), "data.csv")
        XCTAssertEqual(name(nil, "https://x.test/"), "download")
        XCTAssertEqual(name(nil, nil), "download")
        XCTAssertEqual(DownloadFilename.derive(contentDisposition: nil, url: URL(string: "https://x.test/a.zip"), mimeType: nil).source, .url)
        XCTAssertEqual(DownloadFilename.derive(contentDisposition: "attachment; filename=a.txt", url: nil).source, .contentDisposition)
    }

    func testTheExtendedFormWinsAndUnderstandsUtf8() {
        XCTAssertEqual(name("attachment; filename=\"fallback.txt\"; filename*=UTF-8''%E2%82%AC%20rates.txt"), "€ rates.txt")
        XCTAssertEqual(name("attachment; filename*=iso-8859-1'en'%A3%20rates.txt"), "£ rates.txt")
        XCTAssertEqual(name("attachment; filename*=UTF-8''caf%C3%A9.pdf"), "café.pdf")
        XCTAssertEqual(name("attachment; filename=\"x.txt\"; filename*=koi8-r''abc"), "x.txt", "an undefined charset is ignored, and the plain name is used")
        XCTAssertEqual(name("attachment; filename*=UTF-8''%ZZ.txt", "https://x.test/safe.bin"), "safe.bin", "a broken escape falls through")
    }

    func testQuotedStringsEscapesAndOddHeadersAreParsed() {
        XCTAssertEqual(name("attachment; filename=\"a;b.txt\""), "a;b.txt", "a semicolon inside quotes")
        XCTAssertEqual(name("attachment; filename=\"say \\\"hi\\\".txt\""), "say \"hi\".txt")
        XCTAssertEqual(name("attachment; FILENAME=plain.txt"), "plain.txt", "parameter names are case-insensitive")
        XCTAssertEqual(name("inline", "https://x.test/p.png"), "p.png")
        XCTAssertEqual(name("attachment; filename=\"unterminated", "https://x.test/u.bin"), "u.bin")
        XCTAssertEqual(name("attachment; filename=", "https://x.test/e.bin"), "e.bin")
    }

    func testAFilenameCanNeverBeAPath() {
        for hostile in ["../../etc/passwd", "/etc/passwd", "..\\..\\windows\\system32\\evil.dll", "a/b/c.txt", "C:\\temp\\x.exe", "....//....//x"] {
            let clean = DownloadFilename.sanitize(hostile)
            XCTAssertNotNil(clean, hostile)
            XCTAssertFalse(clean!.contains("/") || clean!.contains("\\") || clean!.contains(".."), "\(hostile) -> \(clean!)")
        }
        XCTAssertEqual(DownloadFilename.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(DownloadFilename.sanitize("C:\\temp\\x.exe"), "x.exe")
        XCTAssertNil(DownloadFilename.sanitize(".."))
        XCTAssertNil(DownloadFilename.sanitize("."))
        XCTAssertNil(DownloadFilename.sanitize("/"))
        XCTAssertNil(DownloadFilename.sanitize("   "))
    }

    func testControlCharactersHiddenFilesAndDirectionTricksAreRemoved() {
        XCTAssertEqual(DownloadFilename.sanitize("a\u{0}b\u{7}c.txt"), "abc.txt")
        XCTAssertEqual(DownloadFilename.sanitize(".hidden"), "hidden")
        XCTAssertEqual(DownloadFilename.sanitize("name. "), "name")
        XCTAssertEqual(DownloadFilename.sanitize("report\u{202E}fdp.exe"), "reportfdp.exe", "the override that makes exe look like pdf is dropped")
        XCTAssertEqual(DownloadFilename.sanitize("a\u{200B}b.txt"), "ab.txt")
        XCTAssertEqual(DownloadFilename.sanitize("a:b.txt"), "a-b.txt", "Finder shows a colon as a slash")
        XCTAssertEqual(DownloadFilename.sanitize("CON.txt"), "_CON.txt", "a reserved name on other systems")
        XCTAssertEqual(DownloadFilename.sanitize("e\u{0301}.txt"), "é.txt", "composed form")
    }

    func testLongNamesAreCutOnACharacterBoundaryKeepingTheEnding() {
        let long = String(repeating: "é", count: 300) + ".pdf"
        let cut = DownloadFilename.sanitize(long)!
        XCTAssertLessThanOrEqual(cut.utf8.count, DownloadFilename.maxBytes)
        XCTAssertTrue(cut.hasSuffix(".pdf"))
        XCTAssertNotNil(String(data: Data(cut.utf8), encoding: .utf8), "still valid UTF-8")
        XCTAssertLessThanOrEqual(DownloadFilename.sanitize(String(repeating: "x", count: 500))!.utf8.count, DownloadFilename.maxBytes)
    }

    func testADocumentThatEndsInAProgramIsFlagged() {
        XCTAssertTrue(DownloadFilename.derive(contentDisposition: "attachment; filename=\"invoice.pdf.app\"", url: nil).suspicious)
        XCTAssertTrue(DownloadFilename.derive(contentDisposition: "attachment; filename=\"photo.jpg.command\"", url: nil).suspicious)
        XCTAssertFalse(DownloadFilename.derive(contentDisposition: "attachment; filename=\"installer.dmg\"", url: nil).suspicious)
        XCTAssertFalse(DownloadFilename.derive(contentDisposition: "attachment; filename=\"archive.tar.gz\"", url: nil).suspicious)
    }

    func testAMissingEndingIsAddedFromTheContentTypeButNeverAProgram() {
        XCTAssertEqual(name(nil, "https://x.test/readme", mime: "text/plain; charset=utf-8"), "readme.txt")
        XCTAssertEqual(name(nil, "https://x.test/pic", mime: "image/png"), "pic.png")
        XCTAssertEqual(name(nil, "https://x.test/thing", mime: "application/octet-stream"), "thing")
        XCTAssertEqual(name(nil, "https://x.test/has.ext", mime: "image/png"), "has.ext", "an ending that is there is kept")
    }
}

final class HTTPResponseRulesTests: XCTestCase {
    private func verdict(_ status: Int, range: Int64? = nil, headers: [String: String] = [:], signed: Bool = false) -> HTTPDownloadError? {
        HTTPResponseRules.validate(status: status, headers: { headers[$0] }, rangeStart: range, signed: signed)
    }

    func testSuccessAndTheRangeThatWasAskedFor() {
        XCTAssertNil(verdict(200))
        XCTAssertNil(verdict(206, range: 100, headers: ["Content-Range": "bytes 100-199/1000"]))
        XCTAssertNotNil(verdict(206, range: nil, headers: ["Content-Range": "bytes 0-9/10"]), "a part nobody asked for")
        XCTAssertTrue(verdict(206, range: 100, headers: ["Content-Range": "bytes 0-99/1000"])?.restartFromZero == true, "the wrong part")
        XCTAssertTrue(verdict(206, range: 100, headers: [:])?.restartFromZero == true, "no Content-Range at all")
    }

    func testAWholeFileAnsweringARangeIsARestartNotACorruptFile() {
        let e = verdict(200, range: 5_000)
        XCTAssertTrue(e?.restartFromZero == true)
        XCTAssertNil(verdict(200, range: 0), "a range that starts at zero is the whole file")
        XCTAssertTrue(verdict(416)?.restartFromZero == true)
    }

    func testEachStatusMeansWhatItShould() {
        XCTAssertEqual(verdict(401)?.info.retryable, false)
        XCTAssertEqual(verdict(403)?.info.retryable, false)
        XCTAssertEqual(verdict(404)?.info.retryable, false)
        XCTAssertEqual(verdict(410)?.info.retryable, false)
        XCTAssertEqual(verdict(400)?.info.retryable, false)
        XCTAssertEqual(verdict(408)?.info.retryable, true)
        XCTAssertEqual(verdict(429)?.info.retryable, true)
        for code in [500, 502, 503, 504, 599] { XCTAssertEqual(verdict(code)?.info.retryable, true, "\(code)") }
        XCTAssertEqual(verdict(304)?.info.retryable, false)
        XCTAssertEqual(verdict(301)?.info.retryable, false, "a redirect that could not be followed")
        XCTAssertEqual(verdict(404)?.info.code, "http:404")
    }

    func testAForbiddenSignedLinkIsSaidToHaveProbablyExpired() {
        let signed = verdict(403, signed: true)
        XCTAssertTrue(signed?.maybeExpired == true)
        XCTAssertTrue(signed?.info.reason.contains("expired") == true)
        XCTAssertFalse(verdict(403, signed: false)?.info.reason.contains("expired") == true)
    }

    func testRetryAfterIsReadAsSecondsOrADateAndCapped() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(HTTPResponseRules.retryAfter("120", now: now), 120)
        XCTAssertEqual(HTTPResponseRules.retryAfter(" 0 ", now: now), 0)
        XCTAssertEqual(HTTPResponseRules.retryAfter("999999", now: now), HTTPResponseRules.maxRetryAfter, "a huge value does not park a download for days")
        XCTAssertNil(HTTPResponseRules.retryAfter("soon", now: now))
        XCTAssertNil(HTTPResponseRules.retryAfter("-5", now: now))
        XCTAssertNil(HTTPResponseRules.retryAfter(nil, now: now))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let later = formatter.string(from: now.addingTimeInterval(90))
        XCTAssertEqual(HTTPResponseRules.retryAfter(later, now: now) ?? -1, 90, accuracy: 1)
        XCTAssertEqual(HTTPResponseRules.retryAfter(formatter.string(from: now.addingTimeInterval(-90)), now: now), 0, "a date in the past means now")
        XCTAssertEqual(verdict(429, headers: ["Retry-After": "30"])?.retryAfter, 30)
    }

    func testContentRangeIsParsedStrictly() {
        XCTAssertEqual(HTTPResponseRules.parseContentRange("bytes 0-99/1000")?.total, 1000)
        XCTAssertNil(HTTPResponseRules.parseContentRange("bytes 0-99/1000")?.total == nil ? nil : nil as Int?)
        XCTAssertNil(HTTPResponseRules.parseContentRange("bytes 0-99/*")?.total)
        XCTAssertNotNil(HTTPResponseRules.parseContentRange("bytes 0-99/*"))
        XCTAssertNil(HTTPResponseRules.parseContentRange("bytes 100-50/1000"), "backwards")
        XCTAssertNil(HTTPResponseRules.parseContentRange("bytes 0-1000/1000"), "ends past the end")
        XCTAssertNil(HTTPResponseRules.parseContentRange("items 0-9/10"))
        XCTAssertNil(HTTPResponseRules.parseContentRange("bytes */1000"))
        XCTAssertNil(HTTPResponseRules.parseContentRange(nil))
    }

    func testTransportErrorsAreClassified() {
        func f(_ code: URLError.Code) -> HTTPDownloadError { HTTPResponseRules.failure(for: URLError(code)) }
        for code in [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost] {
            XCTAssertTrue(f(code).info.retryable, "\(code)")
        }
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed, .userCancelledAuthentication, .badURL, .unsupportedURL, .cancelled, .cannotWriteToFile] {
            XCTAssertFalse(f(code).info.retryable, "\(code) must never be retried")
        }
        XCTAssertTrue(f(.serverCertificateUntrusted).info.reason.contains("not secure"))
        XCTAssertFalse(HTTPResponseRules.failure(for: POSIXError(.ENOSPC)).info.retryable)
        XCTAssertTrue(HTTPResponseRules.failure(for: POSIXError(.ENOSPC)).info.reason.contains("space"))
        XCTAssertTrue(HTTPResponseRules.failure(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)).info.reason.contains("space"))
        XCTAssertFalse(HTTPResponseRules.failure(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)).info.retryable)
        XCTAssertFalse(HTTPResponseRules.failure(for: HTTPRequestPolicy.Refusal.redirectLoop).info.retryable)
    }

    func testBackoffGrowsHonoursRetryAfterAndSpreadsFailuresApart() {
        let saved = HTTPRetrySchedule.delayScale; HTTPRetrySchedule.delayScale = 1; defer { HTTPRetrySchedule.delayScale = saved }
        XCTAssertEqual(HTTPRetrySchedule.delay(afterAttempt: 1, retryAfter: nil, jitter: 0.5), 5, accuracy: 0.001)
        XCTAssertEqual(HTTPRetrySchedule.delay(afterAttempt: 2, retryAfter: nil, jitter: 0.5), 10, accuracy: 0.001)
        XCTAssertEqual(HTTPRetrySchedule.delay(afterAttempt: 3, retryAfter: nil, jitter: 0.5), 20, accuracy: 0.001)
        XCTAssertLessThanOrEqual(HTTPRetrySchedule.delay(afterAttempt: 20, retryAfter: nil, jitter: 1), 300 * 1.2 + 0.001, "bounded")
        XCTAssertEqual(HTTPRetrySchedule.delay(afterAttempt: 1, retryAfter: 120, jitter: 0), 120, "never sooner than the server asked")
        let spread = Set((0...4).map { HTTPRetrySchedule.delay(afterAttempt: 2, retryAfter: nil, jitter: Double($0) / 4) })
        XCTAssertEqual(spread.count, 5, "different downloads failing together do not all come back at the same moment")
    }

    func testRetriesAreLimitedAndOnlyForRecoverableFailures() {
        let transient = HTTPResponseRules.failure(for: URLError(.timedOut))
        XCTAssertTrue(HTTPRetrySchedule.mayRetry(transient, attempt: 1))
        XCTAssertTrue(HTTPRetrySchedule.mayRetry(transient, attempt: HTTPRetrySchedule.maxAttempts - 1))
        XCTAssertFalse(HTTPRetrySchedule.mayRetry(transient, attempt: HTTPRetrySchedule.maxAttempts))
        XCTAssertFalse(HTTPRetrySchedule.mayRetry(verdict(401)!, attempt: 1), "authentication is never retried")
        XCTAssertFalse(HTTPRetrySchedule.mayRetry(verdict(404)!, attempt: 1))
        XCTAssertFalse(HTTPRetrySchedule.mayRetry(HTTPResponseRules.failure(for: POSIXError(.ENOSPC)), attempt: 1))
    }

    func testAnAuthoritativeSizeIsOnlyTrustedWhenItCanBe() {
        XCTAssertEqual(HTTPSizeCheck.authoritativeSize(contentLength: 100, contentEncoding: nil), 100)
        XCTAssertEqual(HTTPSizeCheck.authoritativeSize(contentLength: 100, contentEncoding: "identity"), 100)
        XCTAssertNil(HTTPSizeCheck.authoritativeSize(contentLength: 100, contentEncoding: "gzip"), "a compressed length says nothing about the file")
        XCTAssertNil(HTTPSizeCheck.authoritativeSize(contentLength: nil, contentEncoding: nil))
        XCTAssertEqual(HTTPSizeCheck.authoritativeSize(contentLength: 10, contentEncoding: "gzip", rangeTotal: 5000), 5000)
    }
}
