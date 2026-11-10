import Foundation

/// The GitHub package. Everything the browser knows about GitHub's pages is in the scripts below and nowhere else: if GitHub changes its layout, these are what change, and an
/// enhancement whose page it no longer finds fails and is switched off. Each runs where it is told to and nowhere else on github.com.
enum GitHubEnhancements {
    static let package = EnhancementPackage(
        id: "github", name: "GitHub", domain: "github.com", version: 1,
        summary: "Wider code review, jumping between changed files, copying a link as Markdown, and a small repository summary.",
        items: [wide, jump, copy, overlay])

    private static let wide = EnhancementItem(
        id: "wide-review", name: "Use the full width for code review",
        summary: "On the Files changed tab, the page uses the whole window instead of a narrow column.",
        matches: ["https://github.com/*/*/pull/*/files*", "https://github.com/*/*/pull/*/changes*", "https://github.com/*/*/commit/*"], runAtStart: true,
        source: #"""
        var style = document.createElement('style');
        style.textContent = '.container-xl, .container-lg, .container-md { max-width: none !important; } .repository-content, .application-main main { max-width: none !important; }';
        (document.head || document.documentElement).appendChild(style);
        """#)

    private static let jump = EnhancementItem(
        id: "file-jump", name: "Jump between changed files with [ and ]",
        summary: "On a pull request's Files changed tab, ] goes to the next file and [ to the previous one.",
        matches: ["https://github.com/*/*/pull/*/files*", "https://github.com/*/*/pull/*/changes*"],
        source: #"""
        function files() { return Array.prototype.slice.call(document.querySelectorAll('div.file, [data-tagsearch-path], copilot-diff-entry')); }
        function typing(e) { var t = e.target; return t && (t.isContentEditable || /^(input|textarea|select)$/i.test(t.tagName)); }
        document.addEventListener('keydown', function (e) {
          if (e.metaKey || e.ctrlKey || e.altKey || typing(e) || (e.key !== ']' && e.key !== '[')) return;
          var list = files();
          if (!list.length) { throw new Error('the list of changed files was not found'); }
          var here = list.findIndex(function (f) { return f.getBoundingClientRect().top > 8; });
          var index = e.key === ']' ? (here < 0 ? list.length - 1 : here) : Math.max(0, (here < 0 ? list.length : here) - 2);
          list[Math.min(list.length - 1, Math.max(0, index))].scrollIntoView({ block: 'start' });
          e.preventDefault();
        });
        """#)

    private static let copy = EnhancementItem(
        id: "copy-markdown", name: "Copy an issue or pull request as a Markdown link",
        summary: "Adds a button by the title that copies “[#123 Title](link)”.",
        matches: ["https://github.com/*/*/issues/*", "https://github.com/*/*/pull/*"], excludes: ["https://github.com/*/*/pull/*/files*", "https://github.com/*/*/issues/new*"],
        source: #"""
        var number = (location.pathname.match(/\/(?:issues|pull)\/(\d+)/) || [])[1];
        if (!number) { return; }
        function title() { return document.querySelector('bdi.js-issue-title') || document.querySelector('[data-testid="issue-title"]') || document.querySelector('h1 bdi'); }
        function add() {
          var t = title();
          if (!t) { return false; }
          if (document.getElementById('bs-copy-md')) { return true; }
          var b = document.createElement('button');
          b.id = 'bs-copy-md'; b.type = 'button'; b.textContent = 'Copy as Markdown';
          b.style.cssText = 'margin-left:10px;padding:2px 8px;font-size:12px;border:1px solid #8888;border-radius:6px;background:transparent;color:inherit;cursor:pointer;vertical-align:middle';
          b.addEventListener('click', function () {
            var text = '[#' + number + ' ' + t.textContent.trim() + '](' + location.origin + location.pathname.replace(/\/files.*$/, '') + ')';
            navigator.clipboard.writeText(text).then(function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy as Markdown'; }, 1500); }, function () { b.textContent = 'Could not copy'; });
          });
          t.parentNode.appendChild(b);
          return true;
        }
        // The page may fill in its title a moment later; look for up to four seconds, then say so.
        if (!add()) {
          var started = Date.now();
          var observer = new MutationObserver(function () { if (add()) { observer.disconnect(); } else if (Date.now() - started > 4000) { observer.disconnect(); throw new Error('the page title was not found'); } });
          observer.observe(document.documentElement, { childList: true, subtree: true });
          setTimeout(function () { observer.disconnect(); if (!document.getElementById('bs-copy-md')) { throw new Error('the page title was not found'); } }, 4500);
        }
        """#)

    private static let overlay = EnhancementItem(
        id: "repo-summary", name: "Show a repository summary",
        summary: "A small note on a repository's main page: stars, forks, open issues, licence and when it was last pushed. Asks api.github.com for them.",
        matches: ["/^https:\\/\\/github\\.com\\/[^\\/]+\\/[^\\/]+\\/?(\\?.*)?$/"], grants: ["GM_xmlhttpRequest"], connects: ["api.github.com"],
        source: #"""
        var parts = location.pathname.split('/').filter(Boolean);
        var reserved = ['settings', 'orgs', 'marketplace', 'notifications', 'new', 'login', 'sponsors', 'topics', 'collections', 'explore', 'features', 'pricing', 'about', 'search', 'pulls', 'issues'];
        if (parts.length !== 2 || reserved.indexOf(parts[0]) >= 0) { return; }
        GM_xmlhttpRequest({
          method: 'GET', url: 'https://api.github.com/repos/' + encodeURIComponent(parts[0]) + '/' + encodeURIComponent(parts[1]), headers: { Accept: 'application/vnd.github+json' },
          onload: function (r) {
            if (r.status !== 200) { return; }      // a private or missing repository, or a limit reached: nothing to show, and nothing wrong
            var d = JSON.parse(r.responseText);
            if (typeof d.stargazers_count !== 'number') { throw new Error('the answer was not what was expected'); }
            var note = document.createElement('div');
            var when = d.pushed_at ? new Date(d.pushed_at).toLocaleDateString() : 'unknown';
            note.textContent = '★ ' + d.stargazers_count + '  ·  ⑂ ' + d.forks_count + '  ·  ' + d.open_issues_count + ' open issues  ·  ' + ((d.license && d.license.spdx_id) || 'no licence') + '  ·  pushed ' + when;
            note.style.cssText = 'position:fixed;left:16px;bottom:16px;z-index:2147483647;padding:8px 12px;border-radius:10px;background:rgba(20,20,20,.88);color:#fff;font:600 12px -apple-system,system-ui,sans-serif;cursor:pointer';
            note.title = 'Click to hide'; note.addEventListener('click', function () { note.remove(); });
            document.body.appendChild(note);
          },
          onerror: function () {}
        });
        """#)
}
