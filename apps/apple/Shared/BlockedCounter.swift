import Foundation

/// An estimate of how many requests the content rules blocked on a page. WebKit does not say, so the page is asked: a picture, script,
/// style sheet or frame that fails to load, and has no entry in the page's own resource timings, was refused before it left the device
/// (a real 404 or a network error leaves an entry). Every refused attempt counts, so an address a page asks for three times counts three
/// times. Nothing is sent anywhere; the numbers stay in the page until the browser reads them.
enum BlockedCounter {
    /// Installed before the page runs. `window.__bsBlockedCount()` returns one web address per refused attempt, repeats included.
    static let script = """
    (function () {
      if (window.__bsBlockedInstalled) { return; }
      window.__bsBlockedInstalled = true;
      var failed = [];
      function absolute(url) { try { return new URL(url, document.baseURI).href; } catch (e) { return null; } }
      window.addEventListener('error', function (event) {
        var el = event.target;
        if (!el || !el.tagName) { return; }
        var tag = el.tagName.toUpperCase();
        if (['IMG', 'SCRIPT', 'LINK', 'IFRAME', 'VIDEO', 'AUDIO', 'SOURCE', 'EMBED'].indexOf(tag) < 0) { return; }
        var url = absolute(el.currentSrc || el.src || el.href);
        if (url && url.indexOf('http') === 0) { failed.push(url); }
      }, true);
      window.__bsBlockedCount = function () {
        var seen = new Set(performance.getEntriesByType('resource').map(function (e) { return e.name; }));
        return failed.filter(function (url) { return !seen.has(url); });
      };
    })();
    """

    /// What to run to read the count.
    static let read = "return typeof window.__bsBlockedCount === 'function' ? window.__bsBlockedCount() : [];"
}
