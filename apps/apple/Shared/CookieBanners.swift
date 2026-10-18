import Foundation

/// Consent pop-ups, dealt with in the page: where a banner has a "reject" button the browser presses it, and a banner left over is hidden,
/// with the page's scrolling given back. Nothing is accepted for you. The rules are plain names of page elements; there is no code in them.
enum CookieBanners {
    /// The buttons that refuse everything but what a site needs, for the consent tools sites commonly use.
    static let rejectButtons: [String] = [
        "#onetrust-reject-all-handler", ".ot-pc-refuse-all-handler",
        "#CybotCookiebotDialogBodyButtonDecline", "#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll",
        "#didomi-notice-disagree-button", "button[data-testid='uc-deny-all-button']",
        ".cmplz-deny", ".cky-btn-reject", ".osano-cm-denyAll", ".iubenda-cs-reject-btn",
        ".cn-decline", "button[data-tid='banner-decline']", "#truste-consent-required",
        "button.fc-cta-do-not-consent", ".fc-secondary-button", "#cookie_action_close_header_reject",
        "#cookie-law-info-bar .cli_action_button.wt-cli-reject-btn", ".cc-deny", "#cc-reject", "#rejectAll", ".js-reject-cookies",
    ]

    /// Banner containers to hide when pressing a button did not remove them.
    static let containers: [String] = [
        "#onetrust-banner-sdk", "#onetrust-consent-sdk", "#CybotCookiebotDialog", "#CybotCookiebotDialogBodyUnderlay",
        "#didomi-host", ".didomi-popup-container", ".didomi-popup-backdrop", "#usercentrics-root", "#uc-center-container",
        "#cmplz-cookiebanner-container", ".cmplz-cookiebanner", ".cky-consent-container", ".cky-overlay",
        "#cookie-law-info-bar", "#cookie-notice", ".cookie-notice-container", ".osano-cm-window", ".osano-cm-dialog",
        "#iubenda-cs-banner", ".iubenda-cs-container", ".truste_overlay", ".truste_box_overlay", "#truste-consent-track",
        ".qc-cmp2-container", "[id^='sp_message_container']", ".fc-consent-root", "#cookiebanner", "#cookie-banner",
        ".cookie-banner", ".cookie-consent", "#cookieConsent", "#gdpr-cookie-banner", ".gdpr-banner", ".cc-window", ".cc-banner",
        "#cc-main .cm-wrapper", "#klaro .cookie-notice", ".klaro .cookie-modal",
    ]

    /// Words on a button that mean "refuse", for a banner none of the lists above knows. Only used inside an element whose name says cookie or consent.
    static let rejectWords = ["reject all", "decline all", "deny all", "refuse all", "only necessary", "necessary only", "essential only", "reject non-essential",
                              "reject optional", "continue without accepting", "use necessary cookies only"]

    static var script: String {
        func json(_ value: Any) -> String { (try? String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8)) ?? "[]" }
        return """
        (function () {
          if (window.__bsCookieBanners) { return; }
          window.__bsCookieBanners = true;
          var buttons = \(json(rejectButtons)), boxes = \(json(containers)), words = \(json(rejectWords));
          var started = Date.now(), pressed = new WeakSet();
          var style = document.createElement('style');
          style.textContent = boxes.join(',') + '{display:none!important;visibility:hidden!important}' +
            'html.bs-unlock,html.bs-unlock body{overflow:auto!important;position:static!important}';
          function mount() { (document.head || document.documentElement).appendChild(style); }
          if (document.documentElement) { mount(); } else { document.addEventListener('DOMContentLoaded', mount); }
          function visible(el) { var r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; }
          function press(el) { if (!pressed.has(el)) { pressed.add(el); try { el.click(); } catch (e) {} } }
          function sweep() {
            var found = false;
            buttons.forEach(function (selector) {
              // A known button is pressed even when its banner is already hidden by the rule above: a script can click what the eye cannot see.
              try { document.querySelectorAll(selector).forEach(function (el) { press(el); found = true; }); } catch (e) {}
            });
            if (!found) {
              document.querySelectorAll('[id*="cookie" i],[class*="cookie" i],[id*="consent" i],[class*="consent" i],[id*="gdpr" i],[class*="gdpr" i],[id*="cmp" i]').forEach(function (box) {
                if (!visible(box) || box.tagName === 'BODY' || box.tagName === 'HTML') { return; }
                box.querySelectorAll('button,a[role="button"],[role="button"]').forEach(function (b) {
                  var text = (b.textContent || '').trim().toLowerCase();
                  if (text.length < 40 && words.some(function (w) { return text === w || text.indexOf(w) === 0; }) && visible(b)) { press(b); found = true; }
                });
              });
            }
            if (found || document.querySelector(boxes.join(','))) { document.documentElement.classList.add('bs-unlock'); }
          }
          function run() {
            sweep();
            var watcher = new MutationObserver(function () { if (Date.now() - started < 10000) { sweep(); } else { watcher.disconnect(); } });
            watcher.observe(document.documentElement, { childList: true, subtree: true });
            setTimeout(function () { watcher.disconnect(); }, 10000);
          }
          if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', run); } else { run(); }
        })();
        """
    }
}
