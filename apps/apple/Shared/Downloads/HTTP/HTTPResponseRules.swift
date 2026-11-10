import Foundation

/// What an HTTP response (or a transport error) means for a download: success, retry later, restart, or stop for good. Pure, so every status can be tested.
/// Shared with the multipart engine in Phase 3.
struct HTTPDownloadError: Error, Sendable {
    var info: DownloadFailureInfo
    /// The server asked to be left alone for this long (Retry-After), in seconds.
    var retryAfter: TimeInterval?
    /// The partial data cannot be continued (the file changed, or the range was refused): start again from the beginning.
    var restartFromZero = false
    /// The address looks like a signed link and the server refused it: it has probably expired.
    var maybeExpired = false
}

enum HTTPFailureCode {
    static let restartFromZero = "http:restart"
}

enum HTTPResponseRules {
    static let maxRetryAfter: TimeInterval = 3600

    enum Verdict: Equatable {
        case accept                         // 200, or the 206 that was asked for
        case failure(HTTPDownloadErrorSummary)
    }

    /// A comparable summary (HTTPDownloadError itself holds a struct with strings, fine for tests, but Equatable keeps assertions short).
    struct HTTPDownloadErrorSummary: Equatable {
        var code: String, retryable: Bool, restart: Bool
        var retryAfter: TimeInterval?
    }

    /// Whether a response to a download request is one to save. `ranged` is the first byte asked for (nil for a whole-file request).
    static func validate(status: Int, headers: (String) -> String?, rangeStart: Int64?, signed: Bool = false, now: Date = Date()) -> HTTPDownloadError? {
        switch status {
        case 200:
            // A server that ignored the range sends the whole file again: what was kept is no use, and writing this after it would corrupt the file.
            if rangeStart != nil, rangeStart! > 0 { return error("http:200-for-range", "The site sent the whole file again instead of the rest, so the download starts over.", retryable: true, restart: true) }
            return nil
        case 206:
            guard let start = rangeStart else { return error("http:206-unasked", "The site sent only part of the file when the whole file was asked for.", retryable: false) }
            guard let range = parseContentRange(headers("Content-Range")), range.start == start else {
                return error("http:206-wrong-range", "The site sent a different part of the file than was asked for, so the download starts over.", retryable: true, restart: true)
            }
            return nil
        case 304:
            return error("http:304", "The site says the file has not changed, but there is nothing here to keep.", retryable: false)
        case 401:
            return error("http:401", "The website asked you to sign in, and a download started from a link cannot do that.", retryable: false)
        case 403:
            var e = error("http:403", signed ? "The website refused this link. It may have expired: get a new one." : "The website would not let this file be downloaded.", retryable: false)
            e.maybeExpired = signed
            return e
        case 404, 410:
            return error("http:\(status)", "The file is no longer there.", retryable: false)
        case 408:
            return error("http:408", "The website took too long to answer.", retryable: true, retryAfter: retryAfter(headers("Retry-After"), now: now))
        case 416:
            // The kept part does not fit the file now (it changed, or it is shorter): start again.
            return error("http:416", "The file changed on the website, so the download starts over.", retryable: true, restart: true)
        case 429:
            return error("http:429", "The website is limiting how fast files can be downloaded and asked to wait.", retryable: true, retryAfter: retryAfter(headers("Retry-After"), now: now))
        case 500, 502, 504:
            return error("http:\(status)", "The website had a problem.", retryable: true, retryAfter: retryAfter(headers("Retry-After"), now: now))
        case 503:
            return error("http:503", "The website is busy or down for a moment.", retryable: true, retryAfter: retryAfter(headers("Retry-After"), now: now))
        case 300...399:
            return error("http:\(status)", "The website sent the download somewhere that could not be followed.", retryable: false)
        case 400...499:
            return error("http:\(status)", "The website refused the request.", retryable: false)
        case 500...599:
            return error("http:\(status)", "The website had a problem.", retryable: true, retryAfter: retryAfter(headers("Retry-After"), now: now))
        default:
            return error("http:\(status)", "The website answered in a way that could not be used.", retryable: false)
        }
    }

    private static func error(_ code: String, _ reason: String, retryable: Bool, restart: Bool = false, retryAfter: TimeInterval? = nil) -> HTTPDownloadError {
        HTTPDownloadError(info: DownloadFailureInfo(code: code, reason: reason, retryable: retryable), retryAfter: retryAfter, restartFromZero: restart)
    }

    // MARK: Retry-After (RFC 9110 §10.2.3: delay-seconds or an HTTP-date)

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds >= 0, seconds.isFinite { return min(seconds, maxRetryAfter) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return min(max(0, date.timeIntervalSince(now)), maxRetryAfter) }
        }
        return nil
    }

    // MARK: Content-Range

    /// "bytes 100-199/1000" (the total may be "*").
    static func parseContentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes ") else { return nil }
        let body = header.dropFirst(6)
        let halves = body.split(separator: "/", maxSplits: 1).map(String.init)
        guard halves.count == 2 else { return nil }
        let span = halves[0].split(separator: "-").map(String.init)
        guard span.count == 2, let start = Int64(span[0]), let end = Int64(span[1]), start <= end else { return nil }
        let total = halves[1] == "*" ? nil : Int64(halves[1])
        if let total, end >= total { return nil }
        return (start, end, total)
    }

    // MARK: Transport errors

    /// A transport error as a failure: what a person is told, and whether trying again can help.
    static func failure(for error: Error) -> HTTPDownloadError {
        if let known = error as? HTTPDownloadError { return known }
        if let refusal = error as? HTTPRequestPolicy.Refusal { return HTTPDownloadError(info: DownloadFailureInfo(code: "policy:\(refusal)", reason: refusal.reason, retryable: false)) }
        let ns = error as NSError
        let code = "\(ns.domain):\(ns.code)"
        func make(_ reason: String, _ retryable: Bool, restart: Bool = false) -> HTTPDownloadError {
            HTTPDownloadError(info: DownloadFailureInfo(code: code, reason: reason, retryable: retryable), restartFromZero: restart)
        }
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return make("The website took too long to answer.", true)
            case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff: return make("The connection was lost.", true)
            case NSURLErrorCannotConnectToHost: return make("The website did not accept the connection.", true)
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return make("The website could not be found.", true)
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
                return make("The connection to the website was not secure, so the download was stopped.", false)
            case NSURLErrorUserCancelledAuthentication, NSURLErrorUserAuthenticationRequired: return make("The website asked you to sign in.", false)
            case NSURLErrorCancelled: return make("It was cancelled.", false)
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return make("The address is not one that can be downloaded.", false)
            case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation: return make("The address redirected too many times.", false)
            case NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile, NSURLErrorCannotMoveFile: return make("Browser Setu could not save the file there.", false)
            case NSURLErrorDownloadDecodingFailedMidStream, NSURLErrorDownloadDecodingFailedToComplete, NSURLErrorZeroByteResource, NSURLErrorBadServerResponse:
                return make("The website sent something that could not be read.", true)
            default: return make("The download could not be completed.", false)
            }
        }
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteOutOfSpaceError].contains(ns.code) { return make("There is not enough space on the disk.", false) }
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(ns.code) { return make("Browser Setu is not allowed to save there.", false) }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return make("There is not enough space on the disk.", false) }
        return make("The download could not be completed.", false)
    }
}

/// How long to wait before the next try: exponential, never below what the server asked for, spread so that many downloads failing together do not all come back together.
enum HTTPRetrySchedule {
    /// One try plus the automatic retries the person allows (3 by default).
    nonisolated(unsafe) static var maxAttempts = 4
    /// Scales the waits; 1 in the app. Tests make it small so a retry does not take seconds.
    nonisolated(unsafe) static var delayScale = 1.0

    /// `jitter` is a number in 0...1 (a parameter so tests are exact).
    static func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?, jitter: Double = Double.random(in: 0...1)) -> TimeInterval {
        DownloadRetry.delay(afterAttempt: attempt, retryAfter: retryAfter, jitter: jitter, scale: delayScale)
    }

    static func mayRetry(_ error: HTTPDownloadError, attempt: Int, max limit: Int? = nil) -> Bool { error.info.retryable && attempt < (limit ?? maxAttempts) }
}

/// What the file should be, checked against what was written.
enum HTTPSizeCheck {
    /// The size a response promises, when that can be trusted: a plain (identity-encoded) body with a Content-Length. A compressed body's length says nothing about the file.
    static func authoritativeSize(contentLength: Int64?, contentEncoding: String?, rangeTotal: Int64? = nil) -> Int64? {
        if let rangeTotal, rangeTotal > 0 { return rangeTotal }
        let encoding = (contentEncoding ?? "identity").lowercased().trimmingCharacters(in: .whitespaces)
        guard encoding.isEmpty || encoding == "identity", let contentLength, contentLength >= 0 else { return nil }
        return contentLength
    }
}
