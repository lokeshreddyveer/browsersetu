import Foundation

// What went wrong, decided from the evidence the system gives (the error's domain and code, the HTTP status, whether the device has a network at all), never from the wording of
// its message: the wording changes with the language. One place decides the kind, what the page says, which recovery actions it offers and whether the offline games appear.

/// The twelve things a person can be told.
enum BrowserErrorKind: String, CaseIterable, Identifiable {
    case noInternet, dnsFailure, timedOut, serverUnavailable, pageMissing, certificate
    case protectionBlocked, unsupportedContent, processCrashed, fileFailure, syncFailure, mediaFailure
    var id: String { rawValue }

    var title: String {
        switch self {
        case .noInternet: "You’re not connected to the Internet"
        case .dnsFailure: "This website can’t be found"
        case .timedOut: "The website took too long to respond"
        case .serverUnavailable: "The website isn’t responding properly"
        case .pageMissing: "This page doesn’t exist"
        case .certificate: "This connection isn’t private"
        case .protectionBlocked: "Browser Setu blocked this page"
        case .unsupportedContent: "Browser Setu can’t show this"
        case .processCrashed: "This page stopped unexpectedly"
        case .fileFailure: "This file couldn’t be opened"
        case .syncFailure: "Syncing didn’t finish"
        case .mediaFailure: "This video can’t be played"
        }
    }
}

/// The reasons a page can be stopped by the browser's own protection.
enum BlockReason: String {
    case contentFilter, threatList, policy
}

/// Everything known about one failure. Plain values, so it can be tested and shown without the engine.
struct BrowserErrorInfo: Equatable {
    var kind: BrowserErrorKind
    var url: URL?
    var domain = ""
    var code = 0
    var httpStatus: Int?
    /// The system's own description, shown only under Technical Details.
    var detail = ""
    /// A page that died repeatedly: how many times in the last couple of minutes, and whether reloading is paused.
    var crashCount = 0
    var reloadPaused = false
    var blockReason: BlockReason?
    /// The device had no network when this happened (nil: not known).
    var deviceOnline: Bool?
    var date = Date()
    /// A more specific title than the kind's own (a failed video says which kind of failure it was).
    var headline: String?

    var host: String { url?.host ?? "" }

    /// The offline games appear only where the trouble is the connection itself: no network, a name that does not resolve, a timeout, or a site that refuses the connection
    /// (not one that answered with an error), and never for anything about security, permission or the person's own files.
    var offersGames: Bool {
        switch kind {
        case .noInternet, .dnsFailure, .timedOut: return true
        case .serverUnavailable: return httpStatus == nil
        default: return false
        }
    }
}

enum BrowserErrorClassifier {
    /// The kind for a failed load, or nil when there is nothing to show (a load the person or the page cancelled, one stopped by a policy decision, an authentication prompt
    /// that was dismissed). `deviceOnline` is the network path's state when it is known; with no network at all, a failure to resolve or connect is reported as the device
    /// being offline, and with a network it is reported as the site's problem.
    static func classify(domain: String, code: Int, deviceOnline: Bool? = nil) -> BrowserErrorKind? {
        switch domain {
        case NSURLErrorDomain: return url(code, deviceOnline)
        case "WebKitErrorDomain":
            switch code {
            case 102: return nil                    // the frame load was interrupted by a policy decision (a download, an external app): not a failure
            case 100, 101: return .unsupportedContent   // cannot show the MIME type / the URL
            case 103: return .unsupportedContent    // the address uses a restricted network port, which WebKit refuses (seen on the real app with port 9)
            case 104: return .protectionBlocked     // blocked by a content filter
            default: return deviceOnline == false ? .noInternet : .serverUnavailable
            }
        case "WKErrorDomain":
            // WKError.webContentProcessTerminated is 4; the others are about the web view itself, not the page.
            return code == 4 ? .processCrashed : nil
        case NSCocoaErrorDomain:
            switch code {
            case 256, 257, 258, 260, 261, 262, 263, 264, 265, 266, 267: return .fileFailure
            default: return nil
            }
        default:
            return deviceOnline == false ? .noInternet : .serverUnavailable
        }
    }

    private static func url(_ code: Int, _ online: Bool?) -> BrowserErrorKind? {
        let offline = online == false
        switch code {
        case NSURLErrorCancelled, NSURLErrorUserCancelledAuthentication, NSURLErrorUserAuthenticationRequired:
            return nil
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive:
            return .noInternet
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return offline ? .noInternet : .dnsFailure
        case NSURLErrorBadURL:
            return .dnsFailure                      // an address that is not an address: "check the address"
        case NSURLErrorTimedOut:
            return offline ? .noInternet : .timedOut
        case NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorBadServerResponse, NSURLErrorZeroByteResource, NSURLErrorCannotParseResponse,
             NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation, NSURLErrorResourceUnavailable:
            return offline ? .noInternet : .serverUnavailable
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired, NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .certificate
        case NSURLErrorUnsupportedURL, NSURLErrorCannotDecodeRawData, NSURLErrorCannotDecodeContentData, NSURLErrorDataLengthExceedsMaximum:
            return .unsupportedContent
        case NSURLErrorFileDoesNotExist, NSURLErrorFileIsDirectory, NSURLErrorNoPermissionsToReadFile:
            return .fileFailure
        default:
            return offline ? .noInternet : .serverUnavailable
        }
    }

    /// An answer from the website itself. A page the site sent is the site's to show, however bad the status: this is only for an error answer with nothing in it, which
    /// would otherwise leave a blank page. 404 and 410 are a missing page, the 5xx statuses an unavailable server.
    static func classify(httpStatus: Int, bodyIsEmpty: Bool) -> BrowserErrorKind? {
        guard bodyIsEmpty else { return nil }
        switch httpStatus {
        case 404, 410: return .pageMissing
        case 500...599: return .serverUnavailable
        default: return nil
        }
    }

    /// What was wrong with a certificate, in plain words, from the error code alone.
    static func certificateProblem(code: Int) -> String {
        switch code {
        case NSURLErrorServerCertificateHasBadDate: "The site’s certificate has expired."
        case NSURLErrorServerCertificateNotYetValid: "The site’s certificate is not valid yet. Check that this device’s date and time are right."
        case NSURLErrorServerCertificateUntrusted: "The site’s certificate is not trusted: it may be self-signed, or issued by an authority this device does not know."
        case NSURLErrorServerCertificateHasUnknownRoot: "The site’s certificate comes from an authority this device does not know."
        case NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired: "The site asked for a certificate of yours and did not accept it."
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: "This address does not use a secure connection, and this app does not load it."
        default: "A secure connection to the site could not be made."
        }
    }
}

// MARK: - Recovery actions

enum BrowserErrorAction: String, Identifiable {
    case tryAgain, goBack, checkAddress, networkSettings, reload, savedCopy, goHome
    case reviewProtection, chooseAnotherFile, playOffline, openSettings, copyAddress
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tryAgain: "Try Again"
        case .goBack: "Go Back"
        case .checkAddress: "Check the Address"
        case .networkSettings: "Network Settings"
        case .reload: "Reload Page"
        case .savedCopy: "Look for a Saved Copy"
        case .goHome: "Go to the Start Page"
        case .reviewProtection: "Review Site Protection"
        case .chooseAnotherFile: "Choose Another File…"
        case .playOffline: "Play Offline"
        case .openSettings: "Open Settings"
        case .copyAddress: "Copy the Address"
        }
    }

    var symbol: String {
        switch self {
        case .tryAgain, .reload: "arrow.clockwise"
        case .goBack: "chevron.backward"
        case .checkAddress: "pencil"
        case .networkSettings, .openSettings: "gearshape"
        case .savedCopy: "clock.arrow.circlepath"
        case .goHome: "house"
        case .reviewProtection: "shield.lefthalf.filled"
        case .chooseAnotherFile: "folder"
        case .playOffline: "gamecontroller"
        case .copyAddress: "doc.on.doc"
        }
    }
}

extension BrowserErrorInfo {
    /// The first is the main action; the rest are secondary. A page that failed to load is never offered "bypass this warning": for a certificate there is no such action.
    func actions(canGoBack: Bool, isPublicWeb: Bool) -> [BrowserErrorAction] {
        var list: [BrowserErrorAction]
        switch kind {
        case .noInternet: list = [.tryAgain, .networkSettings]
        case .dnsFailure: list = [.tryAgain, .checkAddress]
        case .timedOut: list = [.tryAgain, .checkAddress]
        case .serverUnavailable: list = [.tryAgain]
        case .pageMissing: list = [.goBack, .checkAddress, .goHome]
        case .certificate: list = canGoBack ? [.goBack, .goHome] : [.goHome]
        case .protectionBlocked: list = [.goBack, .reviewProtection]
        case .unsupportedContent: list = [.copyAddress, .goBack]
        case .processCrashed: list = reloadPaused ? [.goHome] : [.reload]
        case .fileFailure: list = [.chooseAnotherFile, .tryAgain]
        case .syncFailure: list = [.tryAgain, .openSettings]
        case .mediaFailure: list = [.reload, .copyAddress]
        }
        // Contained panels (a video, a sync) never navigate away; the pages that already lead with going back, or must not offer a way around, are left as they are.
        let containedOrFixed: Set<BrowserErrorKind> = [.pageMissing, .certificate, .protectionBlocked, .unsupportedContent, .processCrashed, .mediaFailure, .syncFailure]
        if canGoBack, !containedOrFixed.contains(kind), !list.contains(.goBack) { list.append(.goBack) }
        // A saved copy is looked up on the Internet Archive, so it is only offered when this device can reach the Internet at all, and only for a public site.
        let siteTrouble = kind == .serverUnavailable || kind == .timedOut || kind == .dnsFailure || kind == .pageMissing
        if isPublicWeb, siteTrouble, deviceOnline != false { list.append(.savedCopy) }
        return list
    }
}

// MARK: - What the page says

extension BrowserErrorInfo {
    /// One or two sentences, specific to the evidence and never claiming more than it knows.
    var message: String {
        let site = host.isEmpty ? "this page" : host
        switch kind {
        case .noInternet:
            return "This device doesn’t seem to have a network connection. Check that Wi-Fi or mobile data is on and that Airplane Mode is off."
        case .dnsFailure:
            if code == NSURLErrorBadURL { return "That doesn’t look like a complete web address. Check it for a typing mistake." }
            return "The name “\(site)” couldn’t be found. Check the address for a typing mistake; if it is right, the site may be gone or your network may not be able to look it up."
        case .timedOut:
            return "\(site) didn’t answer in time, though this device is connected. The site may be busy or slow; other sites may still work."
        case .serverUnavailable:
            if let status = httpStatus { return "\(site) answered with an error (\(status)) and sent nothing to show. Try again in a little while." }
            return "A connection to \(site) couldn’t be made or was cut off. The site may be down, or something between here and there is refusing the connection."
        case .pageMissing:
            return "\(site) says this page isn’t there. The link may be old or the address mistyped."
        case .certificate:
            return BrowserErrorClassifier.certificateProblem(code: code) + " Nothing was loaded, to keep your information safe."
        case .protectionBlocked:
            switch blockReason {
            case .threatList: return "\(site) is on your own list of sites to be warned about, so it wasn’t opened."
            case .policy: return "A rule in this profile doesn’t allow this page to open here."
            default: return "Browser Setu’s content protection stopped \(site) from loading. If you trust the site, you can review its protection settings."
            }
        case .unsupportedContent:
            if domain == "WebKitErrorDomain", code == 103 {
                return "This address uses a network port that web browsers refuse to connect to, because services on it are easy to attack. Nothing was sent. Check the address, or use another port."
            }
            return "This kind of address or content isn’t something Browser Setu can show. The address was left alone; you can copy it and open it in an app that supports it."
        case .processCrashed:
            if reloadPaused { return "This page keeps stopping, so reloading is paused for a minute. Open another page, or come back to this one later." }
            if crashCount > 1 { return "The page’s process ended again (\(crashCount) times in a couple of minutes). Your other tabs are fine. Reload to try once more." }
            return "The process that shows this page ended. Your other tabs are fine, and this tab’s history is kept. Reload to try again."
        case .fileFailure:
            return "The file may have been moved, deleted or damaged, or this app may not be allowed to read it."
        case .syncFailure:
            return detail.isEmpty ? "Your data on this device is unchanged. Sync will try again when you ask." : detail
        case .mediaFailure:
            return detail.isEmpty ? "The video couldn’t be played. The rest of the page still works." : detail
        }
    }

    /// Lines for the Technical Details disclosure: only facts that are known.
    var technicalLines: [String] {
        var lines: [String] = []
        if let url { lines.append("Address: \(url.absoluteString)") }
        if !domain.isEmpty { lines.append("Error: \(domain) \(code)") }
        if let httpStatus { lines.append("HTTP status: \(httpStatus)") }
        if let deviceOnline { lines.append("This device’s network: \(deviceOnline ? "connected" : "not connected")") }
        if !detail.isEmpty { lines.append("Details: \(detail)") }
        lines.append("Time: \(date.formatted(date: .abbreviated, time: .standard))")
        return lines
    }
}

/// How often a failed page is tried again without being asked. Only a missing network earns one try, made when the network returns; a timeout, a refused connection,
/// a certificate or anything else waits for the person. This replaces a loop that retried with growing delays.
enum ErrorRetryPolicy {
    static func triesWhenNetworkReturns(_ kind: BrowserErrorKind) -> Bool { kind == .noInternet }
    /// Automatic tries for one failed address, ever, until the person acts or the page loads.
    static let automaticTries = 1
}

// MARK: - Sync

/// The ways a sync can fail that the app can say something specific about. The messages are the app's own (not the system's), kept in one place so the status row can tell
/// them apart without reading wording.
enum SyncProblem: Equatable {
    case prepare, tooLarge, passphrase, other(String)

    var message: String {
        switch self {
        case .prepare: "Could not prepare the data to sync."
        case .tooLarge: "Too much to sync for iCloud’s 1 MB space. Turn off history or open tabs, or remove some bookmarks."
        case .passphrase: "Another device uses a different sync passphrase."
        case .other(let text): text
        }
    }

    init(message: String) {
        switch message {
        case SyncProblem.prepare.message: self = .prepare
        case SyncProblem.tooLarge.message: self = .tooLarge
        case SyncProblem.passphrase.message: self = .passphrase
        default: self = .other(message)
        }
    }

    var headline: String {
        switch self {
        case .prepare: "Your data couldn’t be prepared to sync"
        case .tooLarge: "There’s too much to sync"
        case .passphrase: "A device uses a different passphrase"
        case .other: "Syncing didn’t finish"
        }
    }

    /// What is true and what to do. It always says that the data on this device is unchanged.
    var explanation: String {
        switch self {
        case .prepare: "Nothing was sent, and your data on this device is unchanged. You can try again."
        case .tooLarge: "iCloud’s sync space is small. Turn off history or open tabs, or remove some bookmarks. Your data on this device is unchanged, and nothing was sent."
        case .passphrase: "Another device is using a different sync passphrase, so its data was not read. Choose the same passphrase on every device. Nothing on this device was changed or sent."
        case .other(let text): "\(text) Your data on this device is unchanged."
        }
    }

    /// Trying again is offered only where it can help: a different passphrase or a full sync space is not fixed by retrying, and a sensitive transfer is never sent again
    /// without the person asking.
    var canRetry: Bool {
        switch self { case .prepare, .other: true; case .tooLarge, .passphrase: false }
    }

    var info: BrowserErrorInfo {
        var info = BrowserErrorInfo(kind: .syncFailure, detail: explanation)
        info.headline = headline
        return info
    }
}
