import Foundation

/// Makes light websites dark: the engine behind Settings › Appearance › Dark Pages (the setting, the per-site list and the page-menu button are in
/// BrowserModel and SettingsSections). Pages that already have a dark look (their own, or one chosen by the site on request) are never touched.
///
/// How it works, and why: WebKit gives other browsers no switch for this (Safari 27.3's own Adaptive Dark Mode is private to Safari), so the page is
/// recoloured here. The whole page is inverted in brightness with its hues kept, then images, video, canvas, frames and anything with a picture for a
/// background are put back the way they were, so photographs are never negatives. The filter sits on the document root, where the CSS filter rules
/// do not turn fixed headers into scrolling ones. Nothing is sent anywhere: the work is done by a script inside the page's own web view.
enum AdaptiveDarkScript {
    /// The recolouring: brightness inverted with the hue kept, softened so the page is #121212 and #EDEDED rather than black and white.
    static let filter = "invert(1) hue-rotate(180deg) contrast(.86)"
    /// What puts a picture back: the exact opposite of `filter`, in the opposite order. The darkest and lightest few percent of a picture are
    /// clipped to the page's own dark and light, which is what a dark page wants of its photographs anyway.
    static let undo = "contrast(1.163) hue-rotate(180deg) invert(1)"

    /// The script for one page load. `always` darkens every light page; `on` and `off` are site names without "www." (a site on `off` is never touched,
    /// one on `on` is darkened if it is light, whatever the global choice).
    static func source(always: Bool, off: Set<String>, on: Set<String>) -> String {
        let config: [String: Any] = ["mode": always ? "always" : "chosen", "off": off.sorted(), "on": on.sorted()]
        let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return #"""
        (function () {
          if (window.__bsDark) { return; }
          var cfg = \#(json);
          var host = location.hostname.toLowerCase().replace(/^www\./, '');
          function listed(list) {
            for (var i = 0; i < list.length; i++) { if (host === list[i] || host.slice(-list[i].length - 1) === '.' + list[i]) { return true; } }
            return false;
          }
          if (listed(cfg.off || [])) { return; }
          var type = (document.contentType || 'text/html').toLowerCase();
          if (/^(image|video|audio)\//.test(type) || type === 'application/pdf') { return; }
          window.__bsDark = true;
          var forced = listed(cfg.on || []), excludedNow = false;
          var query = window.matchMedia('(prefers-color-scheme: dark)');
          var root = document.documentElement;
          var STYLE = '__bs_dark__', HIDE = '__bs_dark_hide__';
          var MEDIA = 'img:not([data-bsd-flip]),video,canvas,iframe,embed,object,[data-bsd-keep]';
          var CSS = 'html{filter:\#(filter) !important;background-color:#fff !important}' +
            MEDIA + '{filter:\#(undo) !important}' +
            'img[data-bsd-plate]{background-color:#ececec !important;border-radius:6px;padding:3px;box-sizing:content-box}' +
            '[data-bsd-keep] img,[data-bsd-keep] video,[data-bsd-keep] canvas,[data-bsd-keep] iframe,[data-bsd-keep] embed,[data-bsd-keep] object,[data-bsd-keep] [data-bsd-keep]{filter:none !important}' +
            '@media print{html{filter:none !important;background-color:transparent !important}' + MEDIA + '{filter:none !important}}';

          function wanted() { return !excludedNow && (forced || cfg.mode === 'always'); }

          // ---- what the page says about itself
          function metaTokens() {
            var out = [];
            var metas = document.querySelectorAll('meta[name="color-scheme" i]');
            for (var i = 0; i < metas.length; i++) { out.push((metas[i].getAttribute('content') || '').toLowerCase()); }
            return out.join(' ');
          }
          function declaresDark() {
            if (metaTokens().indexOf('dark') >= 0) { return true; }
            try { if ((getComputedStyle(root).colorScheme || '').indexOf('dark') >= 0) { return true; } } catch (e) {}
            return false;
          }
          function optsOutOfDark() { var t = metaTokens(); return t.indexOf('only') >= 0 && t.indexOf('light') >= 0; }

          // ---- is the page already dark? Looks at the colour behind five places on screen.
          function parse(c) {
            var m = /rgba?\(([^)]+)\)/.exec(c || ''); if (!m) { return null; }
            var p = m[1].split(/[ ,\/]+/).filter(Boolean).map(Number);
            return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
          }
          function lum(c) {
            function f(v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
            return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
          }
          function gradientLum(image) {
            var found = image.match(/rgba?\([^)]+\)/g); if (!found) { return null; }
            var total = 0, n = 0;
            found.forEach(function (s) { var c = parse(s); if (c && c.a >= 0.5) { total += lum(c); n++; } });
            return n ? total / n : null;
          }
          function backgroundAt(x, y) {
            var el = document.elementFromPoint(x, y);
            while (el) {
              var cs = getComputedStyle(el), c = parse(cs.backgroundColor);
              if (c && c.a >= 0.5) { return lum(c); }
              if (cs.backgroundImage && cs.backgroundImage.indexOf('gradient') >= 0) { var g = gradientLum(cs.backgroundImage); if (g !== null) { return g; } }
              el = el.parentElement;
            }
            var rc = parse(getComputedStyle(root).backgroundColor); if (rc && rc.a >= 0.5) { return lum(rc); }
            var b = document.body && parse(getComputedStyle(document.body).backgroundColor); if (b && b.a >= 0.5) { return lum(b); }
            return 1;
          }
          // Judged from the page itself, not from what happens to be on screen: the area of its wide solid-coloured regions (and the page canvas behind them), dark against
          // light. Where the page is scrolled to does not change the answer, a half-dark page (a dark header over a light body) is judged by how much of it is which, and
          // a page that is dark by its own design is told apart from a light one however long it takes the site to put its dark theme on.
          function canvasLum() {
            var rc = parse(getComputedStyle(root).backgroundColor); if (rc && rc.a >= 0.5) { return lum(rc); }
            var b = document.body && parse(getComputedStyle(document.body).backgroundColor); if (b && b.a >= 0.5) { return lum(b); }
            return 1;
          }
          function looksDark(themeChange) {
            var w = window.innerWidth, h = window.innerHeight;
            // The canvas behind everything counts for the length of the page (up to three screens); each wide solid region then takes its own area from the canvas's share.
            var canvasArea = w * Math.min(Math.max(document.documentElement.scrollHeight, h), h * 3);
            var canvasDark = canvasLum() < 0.2;
            var dark = canvasDark ? canvasArea : 0, light = canvasDark ? 0 : canvasArea;
            var all = document.body ? document.body.querySelectorAll('*') : [];
            for (var i = 0; i < all.length && i < 1500; i++) {
              var el = all[i], r = el.getBoundingClientRect();
              if (r.width < w * 0.6 || r.height < 60) { continue; }
              var cs = getComputedStyle(el), c = parse(cs.backgroundColor), l = null;
              if (c && c.a >= 0.5) { l = lum(c); }
              else if (cs.backgroundImage && cs.backgroundImage.indexOf('gradient') >= 0) { l = gradientLum(cs.backgroundImage); }
              if (l === null) { continue; }
              var area = r.width * Math.min(r.height, h * 3), regionDark = l < 0.2;
              if (regionDark && !canvasDark) { var toDark = Math.min(area, light); light -= toDark; dark += toDark; }
              else if (!regionDark && canvasDark) { var toLight = Math.min(area, dark); dark -= toLight; light += toLight; }
            }
            return dark > (dark + light) * 0.55;
          }
          function decide(themeChange) {
            if (!wanted()) { return false; }
            // A site the person chose is darkened even if it asked to stay light. A site that says it supports dark is not skipped for saying so: what
            // counts is how it looks now, so one that supports dark but is showing light is darkened, and one that is showing dark is left alone.
            if (!forced && optsOutOfDark()) { return false; }
            // A filter over the whole page costs the graphics chip more the bigger the page is (Dark Reader's own notes say the same of its filter mode), and scrolling is
            // worth more than a dark page. A very large page is left as its site made it, unless the person chose the site.
            if (!forced && document.getElementsByTagName('*').length > 15000) { return false; }
            return !looksDark(themeChange);
          }

          // ---- pictures that must stay as they are, and dark logos that must not
          function keepIfPicture(el) {
            if (el.nodeType !== 1 || el === root || el === document.body) { return; }
            var tag = el.tagName;
            if (tag === 'svg' || tag === 'SVG') {
              var seen = {}, count = 0, kids = el.querySelectorAll('*');
              for (var i = 0; i < kids.length && count < 4; i++) {
                var f = kids[i].getAttribute('fill') || (kids[i].style && kids[i].style.fill) || '';
                if (/url\(/.test(f) || (f && f !== 'none' && f !== 'currentColor' && !seen[f] && (seen[f] = 1) && ++count >= 4)) { count = 4; }
              }
              if (count >= 4) { el.setAttribute('data-bsd-keep', ''); }
              return;
            }
            var cs0 = getComputedStyle(el);
            // A wide, solid, very dark band (a header, a hero, a footer) is already dark: it is kept as it is, and the rest of the page is turned around it. Flipping the whole
            // page would make exactly those parts light, on a page that is half dark to begin with.
            var own = parse(cs0.backgroundColor);
            if (own && own.a >= 0.95 && lum(own) < 0.06) {
              var band = el.getBoundingClientRect();
              if (band.width >= window.innerWidth * 0.5 && band.height >= 36) { el.setAttribute('data-bsd-keep', ''); return; }
            }
            var bi = cs0.backgroundImage;
            if (bi && bi !== 'none' && bi.indexOf('url(') >= 0) {
              // A picture is kept as it is, and so is everything inside it. A big section with a lot of text in it is not a picture, whatever its background: keeping it would
              // leave a whole header or feed light on a dark page, so it is darkened with the rest.
              var r = el.getBoundingClientRect();
              var big = r.width * r.height > 0.35 * window.innerWidth * window.innerHeight;
              var words = (el.textContent || '').trim().length;
              if (!(big && words > 40) && words <= 200) { el.setAttribute('data-bsd-keep', ''); }
            }
          }
          // Looks at a small copy of a picture. A mostly see-through picture whose ink is dark is a logo or an icon: it is flipped with the page, not kept,
          // or it would be dark on dark. Throws when the picture came from another site without permission to read it.
          function judge(src) {
            var w = src.naturalWidth, h = src.naturalHeight; if (!w || !h || w > 1200 || h > 1200) { return false; }
            var c = document.createElement('canvas'); c.width = 24; c.height = 24;
            var x = c.getContext('2d', { willReadFrequently: true }); x.drawImage(src, 0, 0, 24, 24);
            var d = x.getImageData(0, 0, 24, 24).data, opaque = 0, clear = 0, bright = 0;
            for (var i = 0; i < d.length; i += 4) {
              if (d[i + 3] < 20) { clear++; continue; }
              opaque++; bright += (0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]) / 255;
            }
            return opaque >= 8 && clear / (d.length / 4) >= 0.2 && bright / opaque < 0.38;
          }
          function logoish(img) {
            var r = img.getBoundingClientRect();
            if (r.height < 8 || r.height > 64 || r.width > 320) { return false; }
            var t = (img.currentSrc || img.src || '') + ' ' + (img.alt || '') + ' ' + (typeof img.className === 'string' ? img.className : '') + ' ' + (img.id || '');
            return /logo|brand|wordmark/i.test(t) || !!img.closest('header,nav,[role=banner]');
          }
          var corsBudget = 24;
          function classifyImage(img) {
            if (img.__bsd) { return; } img.__bsd = 1;
            function plate() { img.setAttribute('data-bsd-plate', ''); }
            // A picture from another site cannot be read directly. Asking for it again with permission works when the site allows it (and the page has
            // already shown it, so this is the same address); when it does not, a logo-like picture gets a light plate behind it so it stays legible.
            function again() {
              if (!logoish(img)) { return; }
              if (corsBudget-- <= 0) { plate(); return; }
              var c = new Image(); c.crossOrigin = 'anonymous';
              c.onload = function () { try { if (judge(c)) { img.setAttribute('data-bsd-flip', ''); } } catch (e) { plate(); } };
              c.onerror = plate;
              c.src = img.currentSrc || img.src;
            }
            function look() {
              try { if (judge(img)) { img.setAttribute('data-bsd-flip', ''); } } catch (e) { again(); }
            }
            if (img.complete) { look(); } else { img.addEventListener('load', look, { once: true }); }
          }
          function sweep(node) {
            var all = node.querySelectorAll ? node.querySelectorAll('*') : [];
            for (var i = 0; i < all.length && i < 3000; i++) { keepIfPicture(all[i]); }
            var imgs = node.querySelectorAll ? node.querySelectorAll('img') : [];
            for (var j = 0; j < imgs.length && j < 300; j++) { classifyImage(imgs[j]); }
          }

          // ---- putting it on and taking it off
          function hide() { if (document.getElementById(HIDE)) { return; } var s = document.createElement('style'); s.id = HIDE; s.textContent = 'html{opacity:0 !important}'; root.appendChild(s); }
          function reveal() { var s = document.getElementById(HIDE); if (s) { s.remove(); } }
          function setOn(on) {
            var s = document.getElementById(STYLE);
            if (on && !s) {
              s = document.createElement('style'); s.id = STYLE; s.textContent = CSS; (document.head || root).appendChild(s);
              root.setAttribute('data-bsd-on', '');
              if (document.body) { sweep(root); }
            } else if (!on && s) { s.remove(); root.removeAttribute('data-bsd-on'); }
          }
          // Taking the darkening off needs two agreeing judgements a moment apart, so one passing dark thing on the page (a banner, a loading screen)
          // cannot turn the whole page light.
          // The same in the other direction: a page already judged is changed only when two judgements a moment apart agree, so a page that keeps changing a little
          // (a video feed, a carousel) cannot make the whole page flutter between dark and light.
          var state = null, votes = 0, lastRun = 0;
          function run(themeChange) {
            var on = false; try { on = decide(themeChange); } catch (e) {}
            if (state !== null && on !== state && wanted() && ++votes < 2) { reveal(); setTimeout(function () { run(themeChange); }, 700); return; }
            votes = 0; state = on; lastRun = Date.now(); setOn(on); reveal(); watchMore();
          }

          // Nothing is shown until the page has been judged, so a light page is never seen white and a dark one is never seen inverted. A page that is slow
          // to load is shown (darkened, as most pages are light) after a moment, and judged properly when it is ready.
          if (wanted()) { hide(); setTimeout(function () { if (document.getElementById(HIDE)) { state = true; setOn(true); reveal(); } }, 600); }
          if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', function () { run(false); }); } else { run(false); }
          window.addEventListener('load', function () { setTimeout(function () { run(false); }, 250); });
          // A site often puts its dark theme on a little after the page is ready: the page is looked at again for the first seconds.
          var looked = 0, again = setInterval(function () { if (looked < 0) { return; } if (++looked > 8) { looked = -1; return; } run(false); }, 800);
          try { query.addEventListener('change', function () { run(true); }); } catch (e) {}
          // A page that changes without loading (a single-page site: YouTube, Google, X) or comes back from the back-forward cache is judged again, because its look can change
          // completely while the script that decided is still running.
          var lastHref = location.href;
          function moved() { if (location.href !== lastHref) { lastHref = location.href; later(); } }
          try {
            ['pushState', 'replaceState'].forEach(function (name) { var orig = history[name]; history[name] = function () { var r = orig.apply(this, arguments); setTimeout(moved, 0); return r; }; });
            window.addEventListener('popstate', moved); window.addEventListener('hashchange', moved);
            window.addEventListener('pageshow', function () { later(); });
            document.addEventListener('visibilitychange', function () { if (!document.hidden) { later(); } });
            ['yt-navigate-finish', 'turbo:load', 'pjax:end'].forEach(function (n) { document.addEventListener(n, function () { later(); }); });
          } catch (e) {}

          // A site that switches its own theme later (a class or a data attribute on the page) is judged again; new pictures are looked at as they arrive.
          var timer = null;
          // Sites say which theme they are in many ways (YouTube's `dark` attribute, `data-dark`, a `theme` attribute): all are watched.
          var ATTRS = ['class', 'data-theme', 'data-color-mode', 'data-mode', 'data-bs-theme', 'dark', 'data-dark', 'data-darkmode', 'theme'];
          // Judged again at most every two seconds: a site that touches its page all the time would otherwise be judged all the time.
          function later() { clearTimeout(timer); timer = setTimeout(function () { run(true); }, Math.max(300, 2000 - (Date.now() - lastRun))); }
          // Sites change their theme on the body, or by adding a style sheet, as often as on the root: both are watched too.
          var watching = false;
          function watchMore() {
            if (watching || !document.body) { return; }
            watching = true;
            try {
              new MutationObserver(later).observe(document.body, { attributes: true, attributeFilter: ATTRS });
              if (document.head) { new MutationObserver(later).observe(document.head, { childList: true }); }
            } catch (e) {}
          }
          try {
            new MutationObserver(later).observe(root, { attributes: true, attributeFilter: ATTRS });
            var arrived = [], batch = null;
            new MutationObserver(function (list) {
              if (!document.getElementById(STYLE)) { return; }
              list.forEach(function (m) { m.addedNodes.forEach(function (n) { if (n.nodeType === 1) { arrived.push(n); } }); });
              if (arrived.length > 2000) { arrived.splice(0, arrived.length - 2000); }   // a page that never stops adding things must not make this grow
              if (!batch) { batch = setTimeout(function () { var nodes = arrived.splice(0, 200); batch = null; nodes.forEach(function (n) { keepIfPicture(n); sweep(n); }); }, 120); }
            }).observe(root, { childList: true, subtree: true });
          } catch (e) {}
          // Lets the browser change the choice on a page that is already open (a switch in Settings, or the Darken button), without loading it again.
          window.__bsDarkConfig = function (next) {
            cfg = next || cfg; forced = listed(cfg.on || []); excludedNow = listed(cfg.off || []);
            state = null;   // a choice made by the person applies at once, without waiting for a second judgement
            if (wanted()) { hide(); }
            run(true);
          };
        })();
        """#
    }
}
