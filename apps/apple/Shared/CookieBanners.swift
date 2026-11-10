import Foundation

/// One consent tool that sites commonly use, with what its banner looks like and the clicks that REFUSE.
struct ConsentPlatform: Equatable {
    let id: String
    let name: String
    /// What is on the page while this tool's banner is showing (the banner counts as showing while any of these is visible).
    let present: [String]
    /// Alternative ways to refuse, tried in order; the first whose opening button is visible is used. Each path is a list of steps (a second screen needs a second step);
    /// a step is a list of selectors, and the first visible one is pressed.
    let paths: [[[String]]]
    /// The parts of the banner that may be hidden if refusing was not possible. Hiding is never reported as a refusal.
    let boxes: [String]
    /// Elements whose shadow root holds the banner (the buttons are looked for inside as well).
    var shadowHosts: [String] = []
}

/// Consent pop-ups, dealt with in the page. Where a banner has a button that refuses, the browser presses it and then CHECKS that the banner really went away: only then is it
/// reported as refused. A banner that cannot be refused is, if the person allows, hidden, and reported as hidden: hiding a banner does not tell the site "no", and the site may still
/// believe nothing was answered. Nothing is accepted for you. The catalog holds plain names of page elements; there is no code in it, and nothing from a page is ever run.
enum CookieBanners {
    /// Changes whenever an entry is added or fixed, so a record can say which catalog it was made with.
    static let catalogVersion = 4
    static let catalogDate = "2026-11-04"

    static let platforms: [ConsentPlatform] = [
        ConsentPlatform(id: "onetrust", name: "OneTrust", present: ["#onetrust-banner-sdk", "#onetrust-pc-sdk.otPcCenter"],
                        paths: [[["#onetrust-reject-all-handler"]], [["#onetrust-pc-btn-handler"], [".ot-pc-refuse-all-handler", "#ot-pc-refuse-all-handler"]]],
                        boxes: ["#onetrust-banner-sdk", "#onetrust-consent-sdk", ".onetrust-pc-dark-filter"]),
        ConsentPlatform(id: "cookiebot", name: "Cookiebot", present: ["#CybotCookiebotDialog"],
                        paths: [[["#CybotCookiebotDialogBodyButtonDecline", "#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll"]]],
                        boxes: ["#CybotCookiebotDialog", "#CybotCookiebotDialogBodyUnderlay"]),
        ConsentPlatform(id: "didomi", name: "Didomi", present: ["#didomi-host", ".didomi-popup-container", "#didomi-notice"],
                        paths: [[["#didomi-notice-disagree-button"]]], boxes: ["#didomi-host", ".didomi-popup-container", ".didomi-popup-backdrop"]),
        ConsentPlatform(id: "usercentrics", name: "Usercentrics", present: ["#usercentrics-root", "#uc-center-container"],
                        paths: [[["button[data-testid='uc-deny-all-button']"]]], boxes: ["#usercentrics-root", "#uc-center-container"], shadowHosts: ["#usercentrics-root"]),
        ConsentPlatform(id: "complianz", name: "Complianz", present: ["#cmplz-cookiebanner-container", ".cmplz-cookiebanner"],
                        paths: [[[".cmplz-deny"]]], boxes: ["#cmplz-cookiebanner-container", ".cmplz-cookiebanner"]),
        ConsentPlatform(id: "cookieyes", name: "CookieYes", present: [".cky-consent-container", "#cookie-law-info-bar"],
                        paths: [[[".cky-btn-reject", "#cookie-law-info-bar .cli_action_button.wt-cli-reject-btn", "#cookie_action_close_header_reject"]]],
                        boxes: [".cky-consent-container", ".cky-overlay", "#cookie-law-info-bar"]),
        ConsentPlatform(id: "osano", name: "Osano", present: [".osano-cm-window", ".osano-cm-dialog"],
                        paths: [[[".osano-cm-denyAll"]]], boxes: [".osano-cm-window", ".osano-cm-dialog"]),
        ConsentPlatform(id: "iubenda", name: "iubenda", present: ["#iubenda-cs-banner"],
                        paths: [[[".iubenda-cs-reject-btn"]]], boxes: ["#iubenda-cs-banner", ".iubenda-cs-container"]),
        ConsentPlatform(id: "trustarc", name: "TrustArc", present: ["#truste-consent-track", ".truste_overlay", ".truste_box_overlay"],
                        paths: [[["#truste-consent-required"]]], boxes: ["#truste-consent-track", ".truste_overlay", ".truste_box_overlay"]),
        ConsentPlatform(id: "funding-choices", name: "Google Funding Choices", present: [".fc-consent-root"],
                        paths: [[["button.fc-cta-do-not-consent"]]], boxes: [".fc-consent-root"]),
        ConsentPlatform(id: "klaro", name: "Klaro", present: ["#klaro .cookie-notice", ".klaro .cookie-modal"],
                        paths: [[[".cn-decline"]]], boxes: ["#klaro .cookie-notice", ".klaro .cookie-modal"]),
        ConsentPlatform(id: "cookie-notice", name: "Cookie Notice", present: ["#cookie-notice", ".cookie-notice-container"],
                        paths: [[[".cn-decline", "#cn-refuse-cookie"]]], boxes: ["#cookie-notice", ".cookie-notice-container"]),
        ConsentPlatform(id: "cookieconsent", name: "Cookie Consent", present: [".cc-window", ".cc-banner"],
                        paths: [[[".cc-deny", "#cc-reject"]]], boxes: [".cc-window", ".cc-banner"]),
        ConsentPlatform(id: "microsoft", name: "Microsoft consent banner", present: ["button[data-tid='banner-decline']"],
                        paths: [[["button[data-tid='banner-decline']"]]], boxes: ["#wcpConsentBannerCtrl"]),
        // Sourcepoint and Quantcast keep their buttons in a frame from another website, which a page's own script cannot press: they are recognised, never refused.
        ConsentPlatform(id: "sourcepoint", name: "Sourcepoint", present: ["[id^='sp_message_container']"], paths: [], boxes: ["[id^='sp_message_container']"]),
        ConsentPlatform(id: "quantcast", name: "Quantcast Choice", present: [".qc-cmp2-container"], paths: [], boxes: [".qc-cmp2-container"]),
    ]

    /// For a banner none of the entries above recognises: only elements whose name says cookie or consent, and only when they are fixed, stuck or placed straight in the page's body.
    static let genericBoxes = ["#cookiebanner", "#cookie-banner", ".cookie-banner", ".cookie-consent", "#cookieConsent", "#gdpr-cookie-banner", ".gdpr-banner"]

    /// Words on a button that mean "refuse", for a banner none of the entries knows. Only used inside an element whose name says cookie or consent.
    static let rejectWords = ["reject all", "decline all", "deny all", "refuse all", "only necessary", "necessary only", "essential only", "reject non-essential",
                              "reject optional", "continue without accepting", "use necessary cookies only"]

    /// How a banner was dealt with. Only `.refused` means a refusal was made.
    enum Outcome: String, Codable {
        case refused        // a refusing button was pressed and the banner then really went away
        case hidden         // it could not be refused; it was hidden and the site was not told "no"
        case failed         // a refusing button was pressed or sought and nothing changed; the banner is as it was
        case recognised     // a banner was seen and left alone (hiding is switched off)
        case pending
        case none

        var title: String {
            switch self {
            case .refused: "Refused"
            case .hidden: "Hidden, not refused"
            case .failed: "Could not be refused"
            case .recognised: "Left as it was"
            case .pending: "Working on it"
            case .none: "No banner"
            }
        }
    }

    /// The script, with the sites that are left alone and whether a banner that cannot be refused may be hidden.
    static func script(excluded: Set<String> = [], hideUnrefusable: Bool = true) -> String {
        func json(_ value: Any) -> String { (try? String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8)) ?? "[]" }
        let catalog: [[String: Any]] = platforms.map {
            ["id": $0.id, "present": $0.present, "paths": $0.paths, "boxes": $0.boxes, "shadow": $0.shadowHosts]
        }
        let config: [String: Any] = ["version": catalogVersion, "platforms": catalog, "generic": genericBoxes, "words": rejectWords,
                                     "excluded": excluded.sorted(), "hide": hideUnrefusable]
        return source.replacingOccurrences(of: "__CONFIG__", with: json(config))
    }

    /// The script with its usual settings.
    static var script: String { script() }

    /// Reads what the script found (nothing from the page itself): which tool, and what became of the banner.
    static let read = "return window.__bsConsent ? JSON.stringify(window.__bsConsent) : null;"
    /// Starts over on this page now (the person asked), whatever happened before.
    static let rerun = "if (window.__bsConsentRun) { window.__bsConsentRun(true); } return window.__bsConsent ? JSON.stringify(window.__bsConsent) : null;"

    private static let source = #"""
    (function () {
      if (window.__bsCookieBanners) { return; }
      window.__bsCookieBanners = true;
      var cfg = __CONFIG__;
      var host = location.hostname.toLowerCase().replace(/^www\./, '');
      var state = { state: 'none', platform: '', why: '', catalog: cfg.version, sweeps: 0 };
      window.__bsConsent = state;
      if (cfg.excluded.some(function (h) { return host === h || host.endsWith('.' + h); })) { state.why = 'site-off'; return; }

      // Bounded: a sweep is only started by a change to the page, at most one every 250 ms, no more than 24 in all and none after 12 seconds. A banner being worked on gets
      // up to 8 more seconds to finish. The page is never scanned in between.
      var MAX_SWEEPS = 24, WINDOW = 12000, started = Date.now(), timer = null, acting = false, observer = null, attemptedGeneric = 0;
      var attempted = {};

      function q(selector, root) { try { return root.querySelector(selector); } catch (e) { return null; } }
      function all(selector, root) { try { return Array.prototype.slice.call(root.querySelectorAll(selector)); } catch (e) { return []; } }
      function visible(el) {
        if (!el || !el.isConnected) { return false; }
        var r = el.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) { return false; }
        var s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && el.getAttribute('data-bs-hidden') === null;
      }
      function roots(p) {
        var out = [document];
        (p.shadow || []).forEach(function (h) { var el = q(h, document); if (el && el.shadowRoot) { out.push(el.shadowRoot); } });
        return out;
      }
      function firstVisible(selectors, rs) {
        for (var i = 0; i < rs.length; i++) { for (var j = 0; j < selectors.length; j++) { var els = all(selectors[j], rs[i]); for (var k = 0; k < els.length; k++) { if (visible(els[k])) { return els[k]; } } } }
        return null;
      }
      function showing(p) { return !!firstVisible(p.present, roots(p)); }

      function hideBoxes(boxes, rs) {
        var hid = 0;
        rs.forEach(function (r) { boxes.forEach(function (sel) { all(sel, r).forEach(function (el) {
          if (el === document.body || el === document.documentElement) { return; }
          el.setAttribute('data-bs-hidden', ''); el.style.setProperty('display', 'none', 'important'); hid++;
        }); }); });
        if (hid) { unlock(); }
        return hid;
      }
      // The page may have been frozen behind the banner (no scrolling). Given back only after a banner was hidden, by setting the style directly (a page's content rules cannot stop that).
      function unlock() {
        [document.documentElement, document.body].forEach(function (el) {
          if (!el) { return; }
          var s = getComputedStyle(el);
          if (s.overflow === 'hidden' || s.overflowY === 'hidden') { el.style.setProperty('overflow', 'auto', 'important'); }
          if (s.position === 'fixed') { el.style.setProperty('position', 'static', 'important'); }
        });
      }

      function finish(result, platform, why) {
        acting = false;
        state.state = result; state.platform = platform || state.platform; state.why = why || '';
        if (observer) { observer.disconnect(); observer = null; }
      }
      // It could not be refused. Hiding it is allowed only if the person said so, and is reported as hiding.
      function cannotRefuse(p, why) {
        if (cfg.hide && hideBoxes(p.boxes, roots(p)) > 0) { finish('hidden', p.id, why); } else { finish(cfg.hide ? 'failed' : 'recognised', p.id, why); }
      }

      // Waits are measured in real time, not in timer ticks: a page that is not on screen runs its timers slowly, and must not be given up on (or waited for) longer for that.
      function runSteps(p, path, i, since) {
        var button = firstVisible(path[i], roots(p));
        if (!button) {
          if (Date.now() - since < 2500) { setTimeout(function () { runSteps(p, path, i, since); }, 250); return; }
          cannotRefuse(p, 'button-missing'); return;
        }
        try { button.click(); } catch (e) { cannotRefuse(p, 'click-failed'); return; }
        if (i + 1 < path.length) { setTimeout(function () { runSteps(p, path, i + 1, Date.now()); }, 400); return; }
        verify(p, Date.now());
      }
      // A refusal counts only when the banner has really gone (closed by the site itself): the button being pressed is not enough.
      function verify(p, since) {
        if (!showing(p)) { finish('refused', p.id, 'banner-closed'); return; }
        if (Date.now() - since < 3000) { setTimeout(function () { verify(p, since); }, 250); return; }
        cannotRefuse(p, 'still-showing');
      }

      function attempt(p) {
        attempted[p.id] = true; acting = true; state.state = 'pending'; state.platform = p.id;
        var rs = roots(p);
        for (var i = 0; i < p.paths.length; i++) {
          if (firstVisible(p.paths[i][0], rs)) { runSteps(p, p.paths[i], 0, Date.now()); return; }
        }
        // No refusing button is showing. A banner that opens on a second screen can show its button a moment later, so one short wait before giving up.
        if (p.paths.length && !attempted[p.id + ':wait']) {
          attempted[p.id + ':wait'] = true; attempted[p.id] = false; acting = false; state.state = 'none'; schedule(400); return;
        }
        cannotRefuse(p, p.paths.length ? 'no-refuse-button' : 'refusal-not-possible');
      }

      // A banner none of the entries knows: elements named for cookies or consent that are stuck to the screen, with a button that plainly says "reject".
      function generic() {
        var boxes = all('[id*="cookie" i],[class*="cookie" i],[id*="consent" i],[class*="consent" i],[id*="gdpr" i],[class*="gdpr" i]', document).filter(function (el) {
          if (el === document.body || el === document.documentElement || !visible(el)) { return false; }
          var pos = getComputedStyle(el).position;
          return pos === 'fixed' || pos === 'sticky' || pos === 'absolute' || el.parentElement === document.body || el.matches(cfg.generic.join(','));
        });
        for (var i = 0; i < boxes.length; i++) {
          var box = boxes[i], buttons = all('button,a[role="button"],[role="button"],input[type="button"],input[type="submit"]', box);
          for (var j = 0; j < buttons.length; j++) {
            var b = buttons[j], text = ((b.textContent || b.value || '') + '').trim().toLowerCase();
            if (text.length < 40 && visible(b) && cfg.words.some(function (w) { return text === w || text.indexOf(w) === 0; })) {
              acting = true; state.state = 'pending'; state.platform = 'generic';
              try { b.click(); } catch (e) {}
              var since = Date.now();
              (function check(boxEl) {
                if (!visible(boxEl)) { finish('refused', 'generic', 'banner-closed'); return; }
                if (Date.now() - since < 3000) { setTimeout(function () { check(boxEl); }, 250); return; }
                if (cfg.hide) { boxEl.setAttribute('data-bs-hidden', ''); boxEl.style.setProperty('display', 'none', 'important'); unlock(); finish('hidden', 'generic', 'still-showing'); } else { finish('recognised', 'generic', 'still-showing'); }
              })(box);
              return true;
            }
          }
        }
        // No refusing button: a known generic container is hidden (and said to be hidden), never an unknown element.
        var known = all(cfg.generic.join(','), document).filter(visible);
        if (known.length) {
          if (cfg.hide) { known.forEach(function (el) { el.setAttribute('data-bs-hidden', ''); el.style.setProperty('display', 'none', 'important'); }); unlock(); finish('hidden', 'generic', 'refusal-not-possible'); }
          else { finish('recognised', 'generic', 'refusal-not-possible'); }
          return true;
        }
        return false;
      }

      function sweep() {
        timer = null;
        if (acting || state.state === 'refused' || state.state === 'hidden' || state.state === 'failed' || state.state === 'recognised') { return; }
        var late = Date.now() - started > WINDOW;
        if (++state.sweeps > MAX_SWEEPS || late) { if (observer) { observer.disconnect(); observer = null; } return; }
        for (var i = 0; i < cfg.platforms.length; i++) {
          var p = cfg.platforms[i];
          if (!attempted[p.id] && showing(p)) { attempt(p); return; }
        }
        // The slower check of the page for unknown banners runs twice at most, once the page has settled a little.
        if (state.sweeps >= 2 && attemptedGeneric < 2) { attemptedGeneric++; if (generic()) { return; } }
      }
      function schedule(delay) { if (!timer) { timer = setTimeout(sweep, delay || 250); } }
      function watch() { try { observer = new MutationObserver(function () { if (!acting) { schedule(250); } }); observer.observe(document.documentElement, { childList: true, subtree: true }); } catch (e) {} }

      function start() {
        sweep();
        watch();
        // Two more looks as the page settles, even if nothing on it changes: a banner that is already there when the page stops loading is not announced by any change.
        setTimeout(function () { schedule(0); }, 700);
        setTimeout(function () { schedule(0); }, 2500);
        setTimeout(function () { if (state.state === 'none' && observer) { observer.disconnect(); observer = null; } }, WINDOW + 1000);
      }
      if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', start); } else { start(); }

      // The person asked for this page to be looked at again (a banner that came back, or a page that was set aside).
      window.__bsConsentRun = function () {
        if (timer) { clearTimeout(timer); timer = null; }
        attempted = {}; attemptedGeneric = 0; acting = false; started = Date.now();
        state.state = 'none'; state.platform = ''; state.why = ''; state.sweeps = 0;
        if (!observer) { watch(); }
        sweep();
      };
    })();
    """#
}
