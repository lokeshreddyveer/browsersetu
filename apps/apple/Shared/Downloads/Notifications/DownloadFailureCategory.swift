import Foundation

/// Why a download failed, in words a person can act on. The raw code stays in the ledger for diagnostics; this is what is shown, exported and decided on.
enum DownloadFailureCategory: String, Codable, CaseIterable, Sendable {
    case networkUnavailable, secureConnectionFailed, timeout, serverRefused, serverUnavailable, authenticationRequired, resumeUnsupported, fileChanged, destinationUnavailable
    case diskFull, permissionDenied, integrityMismatch, proxyFailure, admissionFailure, policyRefused, sessionUnavailable, unsupportedCapability, unknown

    var title: String {
        switch self {
        case .networkUnavailable: "Network unavailable"
        case .secureConnectionFailed: "The connection was not secure"
        case .timeout: "The website took too long"
        case .serverRefused: "The website refused the request"
        case .serverUnavailable: "The website had a problem"
        case .authenticationRequired: "Sign-in required"
        case .resumeUnsupported: "Cannot continue where it stopped"
        case .fileChanged: "The file changed on the website"
        case .destinationUnavailable: "The save location is not available"
        case .diskFull: "Not enough disk space"
        case .permissionDenied: "Not allowed to save there"
        case .integrityMismatch: "The file does not match"
        case .proxyFailure: "Proxy problem"
        case .admissionFailure: "Could not be started"
        case .policyRefused: "This address is not allowed"
        case .sessionUnavailable: "Its web session is not open"
        case .unsupportedCapability: "Not supported for this kind of download"
        case .unknown: "The download failed"
        }
    }

    /// What the person can do. Never contains an address or a raw system message.
    var advice: String {
        switch self {
        case .networkUnavailable: "Check the connection, then try again."
        case .secureConnectionFailed: "The website's security certificate could not be trusted. Do not try to get around this."
        case .timeout: "Try again in a little while."
        case .serverRefused: "The link may have expired or be wrong. Get a fresh link from the website."
        case .serverUnavailable: "The website is having trouble. Try again later."
        case .authenticationRequired: "Open the page in Browser Setu, sign in, and download it again."
        case .resumeUnsupported: "It will start again from the beginning."
        case .fileChanged: "Download it again; the old partial file cannot be used."
        case .destinationUnavailable: "Choose another folder or reconnect the drive."
        case .diskFull: "Free some space, then try again."
        case .permissionDenied: "Choose a folder Browser Setu may write to."
        case .integrityMismatch: "The file was kept but is not the size or checksum expected. Download it again before trusting it."
        case .proxyFailure: "Check the proxy settings in Downloads settings."
        case .admissionFailure: "Wait for other downloads to finish, or raise the limit in settings."
        case .policyRefused: "Only addresses you open yourself can reach private networks."
        case .sessionUnavailable: "Open a page of the profile it came from, then resume."
        case .unsupportedCapability: "That action is not available for this engine."
        case .unknown: "Try again. If it keeps failing, export diagnostics."
        }
    }

    /// Whether trying again by itself can help. Permanent failures are never retried automatically.
    var retryable: Bool {
        switch self {
        case .networkUnavailable, .timeout, .serverUnavailable, .resumeUnsupported, .fileChanged, .admissionFailure: true
        default: false
        }
    }

    /// Needs the person to change something first.
    var needsUser: Bool {
        switch self {
        case .secureConnectionFailed, .authenticationRequired, .destinationUnavailable, .diskFull, .permissionDenied, .proxyFailure, .sessionUnavailable, .serverRefused, .policyRefused, .integrityMismatch: true
        default: false
        }
    }

    static func classify(code: String?, reason: String? = nil) -> DownloadFailureCategory {
        let c = (code ?? "").lowercased(), r = (reason ?? "").lowercased()
        func has(_ parts: String...) -> Bool { parts.contains { c.contains($0) } }
        func says(_ parts: String...) -> Bool { parts.contains { r.contains($0) } }
        if has("policy:") { return .policyRefused }
        if has("session") { return .sessionUnavailable }
        if has("checksum", "wrong-size", "mismatch") { return .integrityMismatch }
        if has("proxy") || says("proxy") { return .proxyFailure }
        if has("http:401", "http:407", "authentication", "-1013", "-1012") || says("sign in", "signed in") { return .authenticationRequired }
        if has("http:403") { return .serverRefused }
        if has("http:404", "http:410", "http:451") { return .serverRefused }
        if has("http:416", "etag", "validator", "if-range") || c.hasSuffix("changed") { return .fileChanged }
        if has("no-resume", "resume-unsupported") { return .resumeUnsupported }
        if has("http:5", "http:429") { return .serverUnavailable }
        if has("-1001", "timedout", "timeout") { return .timeout }
        if has("-1200", "-1201", "-1202", "-1203", "-1204", "-1205", "-1206") { return .secureConnectionFailed }
        if has("-1100") { return .serverRefused }                      // the file does not exist: asking again will not create it
        if has("-1009", "-1005", "-1004", "-1003", "-1018") { return .networkUnavailable }
        if has("nscocoaerrordomain:640") || says("not enough space", "disk is full") || has("enospc") { return .diskFull }
        if has("nscocoaerrordomain:513", "nscocoaerrordomain:518", "nscocoaerrordomain:257") || says("not allowed to save") { return .permissionDenied }
        if c == "nscocoaerrordomain:4" || c == "nscocoaerrordomain:260" || has("volume") || says("destination") { return .destinationUnavailable }
        if has("retry-not-scheduled", "admission") { return .admissionFailure }
        if has("unsupported") { return .unsupportedCapability }
        if says("connection was lost", "could not be found", "did not accept the connection") { return .networkUnavailable }
        return .unknown
    }
}
