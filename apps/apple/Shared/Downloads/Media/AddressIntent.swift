import Foundation

/// What an address typed into "Add a download" really is, decided from what is known rather than from the ending of its name alone:
///   1. site support: a video provider's watch page, reel or short (also after redirects) is a video page, whatever the server answers;
///   2. what the server says it is (its content type);
///   3. only then, the shape of the address.
/// A web page that is not a known video site is never decided silently: the person chooses between looking for a video and saving the page itself.
enum AddressIntent: Equatable {
    /// A video provider's page: goes to the video options (where a missing tool is offered, with consent).
    case videoPage
    /// A web page (HTML) of an unfamiliar site: the person chooses.
    case webPage
    /// Anything else: a file, saved as before.
    case file
}

enum AddressClassifier {
    /// "text/html; charset=utf-8" becomes "text/html"; nil for nothing usable.
    static func mediaType(_ header: String?) -> String? {
        guard let first = header?.split(separator: ";").first else { return nil }
        let t = first.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty || !t.contains("/") ? nil : t
    }

    static func isHTML(_ type: String?) -> Bool { type == "text/html" || type == "application/xhtml+xml" }

    /// Endings of addresses that usually ARE pages (or have no ending). Only used to decide whether asking the server is worthwhile, never to decide what the address is.
    private static let pageLikeEndings: Set<String> = ["", "html", "htm", "xhtml", "php", "asp", "aspx", "jsp", "cgi", "shtml"]

    /// Whether the server should be asked what this address is (it is not already known to be a video page, and it does not look like a file).
    static func worthProbing(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https", !ProviderRecognizer.isVideoPage(url) else { return false }
        return pageLikeEndings.contains(url.pathExtension.lowercased())
    }

    /// `contentType` and `finalURL` are what the server answered (nil when it was not asked or did not answer).
    static func classify(_ url: URL, contentType: String? = nil, finalURL: URL? = nil) -> AddressIntent {
        if ProviderRecognizer.isVideoPage(url) { return .videoPage }
        if let finalURL, ProviderRecognizer.isVideoPage(finalURL) { return .videoPage }          // a short link that ends on a video page
        if let type = mediaType(contentType) { return isHTML(type) ? .webPage : .file }          // what the server says beats what the name looks like
        return .file                                                                              // unknown: the way it has always behaved
    }
}
