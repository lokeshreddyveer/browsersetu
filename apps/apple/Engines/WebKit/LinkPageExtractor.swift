import Foundation
import WebKit

/// "Collect Download Links from This Page": runs once, when asked, on the page that is open. It reads the address of each link (the `href` of an `<a>`) and nothing else: no form
/// values, no text, no passwords, no other part of the page. It runs in the browser's own script world, so the page cannot see or change it, and it is not installed in any page.
@MainActor
enum LinkPageExtractor {
    static let maxElements = 5000
    /// As many as the elements read: the cap used to be 500 ANCHORS of any kind, so on a long page (an encyclopedia article has thousands of links) the download links after the first 500 were never seen.
    /// What is a download is decided afterwards, in Swift, so the page script must hand over every link it read.
    static let maxResults = 5000

    static let script = """
    const found = []; const seen = new Set(); let looked = 0; let cut = false;
    const ok = ['http:', 'https:', 'magnet:', 'ed2k:'];
    for (const a of document.querySelectorAll('a[href]')) {
      if (++looked > maxElements) { cut = true; break; }
      let h = '';
      try { h = a.href || ''; } catch (e) { continue; }
      if (typeof h !== 'string' || !h || h.length > 8192) continue;   // an SVG <a> has an object here, not text
      // The scheme is read from the text itself: an eD2k link has bars where a web address has a host name, and the browser's own URL parser refuses it.
      const colon = h.indexOf(':');
      if (colon < 1) continue;
      const proto = h.slice(0, colon + 1).toLowerCase();
      if (!ok.includes(proto) || seen.has(h)) continue;
      seen.add(h);
      found.push({ href: h, dl: a.hasAttribute('download') });
      if (found.length >= maxResults) { cut = true; break; }
    }
    return { links: found, cut: cut };
    """

    struct Found: Equatable { var href: String; var marked: Bool }
    struct Result: Equatable { var links: [Found]; var truncated: Bool }

    /// The raw addresses on the page. Cancelling the surrounding task stops the wait; the page script itself is bounded and short.
    static func collect(from webView: WKWebView) async -> Result {
        let answer = try? await webView.callAsyncJavaScript(script, arguments: ["maxElements": maxElements, "maxResults": maxResults], contentWorld: .defaultClient) as? [String: Any]
        guard !Task.isCancelled, let answer else { return Result(links: [], truncated: false) }
        let raw = (answer["links"] as? [[String: Any]]) ?? []
        let links = raw.compactMap { d -> Found? in (d["href"] as? String).map { Found(href: $0, marked: (d["dl"] as? Bool) ?? false) } }
        return Result(links: Array(links.prefix(maxResults)), truncated: (answer["cut"] as? Bool) ?? false)
    }

    /// Of everything on a page, only what is likely to be a download: a file, a torrent, a magnet or eD2k link, or a link the page itself marks as a download. Ordinary page links are
    /// left out: not every link on a page is a file.
    static func downloadCandidates(_ result: Result) -> [String] {
        result.links.compactMap { f in
            let kind = LinkClassifier.classify(f.href).kind
            switch kind {
            case .httpResource, .torrentURL, .magnet, .ed2kFile: return f.href
            case .webpage: return f.marked ? f.href : nil
            default: return nil
            }
        }
    }
}
