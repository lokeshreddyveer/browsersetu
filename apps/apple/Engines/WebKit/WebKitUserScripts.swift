import WebKit

/// Puts the user's scripts into a web view, and is the only file that does. Each script is wrapped so it only runs on the websites
/// the user named (WebKit has no address filter of its own for these), and an error in one script cannot stop the page.
enum UserScriptInstaller {
    /// A number picked at random each time the app starts; the fingerprint changes are worked out from it.
    private static let fingerprintSeed = UInt32.random(in: 1...UInt32.max)

    /// Every switch from `WebPolicy` that is a script. Used for normal and private tabs alike.
    static func addPolicyScripts(_ policy: WebPolicy, to controller: WKUserContentController) {
        if policy.blockWebRTC { addWebRTCBlocker(to: controller, exceptions: policy.exceptions) }
        if policy.randomizeFingerprint {
            controller.addUserScript(WKUserScript(source: PageScripts.fingerprint(seed: fingerprintSeed, exceptions: policy.fingerprintExceptions),
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if policy.blockAutoplay {
            controller.addUserScript(WKUserScript(source: PageScripts.noAutoplay(exceptions: policy.autoplayExceptions, grant: WebKitTab.playbackGrantName), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if policy.darkPages != .off {
            controller.addUserScript(WKUserScript(source: AdaptiveDarkScript.source(always: policy.darkPages == .always, off: policy.darkSitesOff, on: policy.darkSites),
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        if policy.devCapture {
            controller.addUserScript(WKUserScript(source: DevCaptureScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        if policy.referrerSameSiteOnly {
            controller.addUserScript(WKUserScript(source: ReferrerMode.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
        if policy.globalPrivacyControl {
            // Before 27 the header cannot be added, but pages that ask the script property still see the signal.
            controller.addUserScript(WKUserScript(source: PageScripts.globalPrivacyControl, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        if policy.blockLinkPings {
            controller.addUserScript(WKUserScript(source: PageScripts.noLinkPings, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
        if let sponsor = policy.sponsorBlock {
            controller.addUserScript(WKUserScript(source: SponsorBlockScript.source(sponsor), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        }
        if policy.cookieBanners {
            controller.addUserScript(WKUserScript(source: CookieBanners.script(excluded: policy.consentOffSites, hideUnrefusable: policy.hideUnrefusableBanners), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
        if !policy.videoSpeeds.isEmpty {
            controller.addUserScript(WKUserScript(source: VideoControls.rememberedSpeedScript(policy.videoSpeeds), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
        if policy.deAMP {
            controller.addUserScript(WKUserScript(source: PageScripts.deAMP, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        if policy.blockVideoAds {
            controller.addUserScript(WKUserScript(source: policy.youtubeRules.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
    }

    /// The page-media observer: its script runs in every frame, in the isolated client world. Added here so that this file stays the only one that adds scripts.
    static func addMediaObserver(source: String, to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
    }

    /// Pages are drawn without scroll bars, on both the Mac and the iPhone. Scrolling works as before; only the bar is not painted.
    static func addScrollbarHider(to controller: WKUserContentController) {
        let source = """
        (function () {
          var css = '::-webkit-scrollbar{display:none!important;width:0!important;height:0!important}html,body{scrollbar-width:none!important}';
          function add() { var s = document.createElement('style'); s.textContent = css; (document.head || document.documentElement).appendChild(s); }
          if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add);
        })();
        """
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    /// The switch for WebRTC: when on, pages cannot create peer connections, which is how a page learns the address of this device on the network. Sites the person
    /// named are left alone (video calls need it).
    static func addWebRTCBlocker(to controller: WKUserContentController, exceptions: Set<String>) {
        let list = (try? String(data: JSONSerialization.data(withJSONObject: Array(exceptions).sorted()), encoding: .utf8)) ?? "[]"
        let source = """
        (function () {
          \(PageScripts.topHostJS)
          var skip = \(list);
          if (skip.some(function (s) { return host === s || host.endsWith('.' + s); })) return;
          ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel'].forEach(function (name) {
            try { Object.defineProperty(window, name, { value: undefined, configurable: false, writable: false }); } catch (e) {}
          });
        })();
        """
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    /// Keeps the last page errors where the page cannot read them (an isolated world), for the developer tools. Page console output is not
    /// visible from here: WebKit gives a separate console to each world, so only uncaught errors and rejected promises are collected.
    static func addErrorCollector(to controller: WKUserContentController) {
        let source = """
        (function () {
          var log = window.__bsErrors = [];
          function add(kind, text) { log.push({ kind: kind, text: String(text).slice(0, 400), at: Date.now() }); if (log.length > 100) log.shift(); }
          window.addEventListener('error', function (e) { add('error', (e.message || 'Error') + (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : '')); });
          window.addEventListener('unhandledrejection', function (e) { add('promise', e.reason && e.reason.message ? e.reason.message : e.reason); });
        })();
        """
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
    }

    /// The browser's own page scripts (they are not the user's, and not switches): when the person really clicked or typed, which link the pointer is over, and, in normal
    /// tabs, the sign-in watcher. They must be added after the old scripts are cleared, or they never reach a page.
    static func addBrowserScripts(to controller: WKUserContentController, signInWatcher: Bool) {
        controller.addUserScript(WKUserScript(source: GestureScript.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: BlockedCounter.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: LinkHover.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        if signInWatcher {
            controller.addUserScript(WKUserScript(source: LoginScripts.watcher, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
    }

    /// The scripts' message handlers, by web view, so a reinstall can take away exactly the ones it added (and never the browser's own).
    private static let bridges = NSMapTable<WKUserContentController, NSMutableArray>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    @MainActor
    static func install(_ scripts: [UserScript], policy: WebPolicy = WebPolicy(), storage: UserScriptStorage? = nil, filter: FilterScripts = FilterScripts(), into controller: WKUserContentController) {
        controller.removeAllUserScripts()
        for case let world as WKContentWorld in bridges.object(forKey: controller) ?? [] { UserScriptBridge.unregister(world: world, from: controller) }
        bridges.setObject(NSMutableArray(), forKey: controller)
        addScrollbarHider(to: controller)
        addPolicyScripts(policy, to: controller)
        addBrowserScripts(to: controller, signInWatcher: true)
        // Added here, after the old scripts are cleared, so a reinstall can never leave a normal tab without it (it used to be added once, then wiped by the first reinstall).
        addErrorCollector(to: controller)
        addFilterScripts(filter, to: controller)
        // A script whose excludes cannot all be read is not installed at all: it could run where it was meant to be kept out.
        for script in scripts where script.enabled && !script.patterns.isEmpty && UserScriptMatcher.allReadable(script.excludes) {
            // Each script has a world of its own, so one cannot reach another's variables or its bridge. A script that asked for the page's own world is the exception, and
            // gets no abilities beyond changing the page (the page can see everything it holds, so it must not hold anything worth taking).
            let privateWorld = WKContentWorld.world(name: "BrowserSetuUserScript-" + script.id.uuidString)
            let nonce = UUID().uuidString
            let values = script.allows(.storage) && !script.inPageWorld ? (storage?.values(script.id) ?? [:]) : [:]
            UserScriptBridge.register(for: script, storage: storage, world: privateWorld, on: controller)
            bridges.object(forKey: controller)?.add(privateWorld)
            let timing: WKUserScriptInjectionTime = script.runAtStart ? .atDocumentStart : .atDocumentEnd
            if script.inPageWorld {
                // What it reports (that it ran, its errors) is carried by an event to a small relay in the private world: the page world has no bridge of its own.
                controller.addUserScript(WKUserScript(source: relay(nonce: nonce), injectionTime: .atDocumentStart, forMainFrameOnly: !script.allFrames, in: privateWorld))
                controller.addUserScript(WKUserScript(source: wrapped(script, nonce: nonce), injectionTime: timing, forMainFrameOnly: !script.allFrames, in: .page))
            } else {
                controller.addUserScript(WKUserScript(source: wrapped(script, values: values, nonce: nonce), injectionTime: timing, forMainFrameOnly: !script.allFrames, in: privateWorld))
            }
        }
    }

    /// The scriptlets (page world) and procedural cosmetic rules (private world) that the filter lists asked for and this browser provides.
    static func addFilterScripts(_ filter: FilterScripts, to controller: WKUserContentController) {
        if !filter.page.isEmpty { controller.addUserScript(WKUserScript(source: filter.page, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)) }
        if !filter.cosmetic.isEmpty { controller.addUserScript(WKUserScript(source: filter.cosmetic, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)) }
    }

    /// A private tab's scripts: the browser's own, never the person's, and no developer capture.
    static func installPrivate(_ policy: WebPolicy, filter: FilterScripts, into controller: WKUserContentController) {
        controller.removeAllUserScripts()
        addScrollbarHider(to: controller)
        var privatePolicy = policy
        privatePolicy.devCapture = false
        privatePolicy.sponsorBlock = nil       // a private tab never takes part in SponsorBlock
        addPolicyScripts(privatePolicy, to: controller)
        addBrowserScripts(to: controller, signInWatcher: false)
        addFilterScripts(filter, to: controller)
    }

    private static func json(_ value: Any) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)) ?? "null"
    }

    /// Passes the page-world script's reports on to the bridge. Only the four harmless kinds are passed on; the bridge refuses the rest for a page-world script anyway.
    static func relay(nonce: String) -> String {
        """
        (function () {
          var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bsus;
          if (!bridge) return;
          document.addEventListener('bsus-' + \(json(nonce)), function (e) {
            try { var m = JSON.parse(e.detail); if (m && ['ran', 'err', 'log', 'denied'].indexOf(m.op) >= 0) bridge.postMessage({ op: m.op, text: String(m.text || '').slice(0, 300) }); } catch (x) {}
          }, true);
        })();
        """
    }

    /// The script inside a check for the page. Which pages it matches, and which it never runs on, are regular expressions passed as JSON text and tried against the
    /// address of the page or frame it is running in (so a redirect, or a frame with its own address, is judged by where it really is); nothing is joined into code.
    /// The abilities a script was given (`values`, the permissions) are baked in as data; what it was not given is simply not there.
    static func wrapped(_ script: UserScript, values: [String: String] = [:], nonce: String = "") -> String {
        let config: [String: Any] = [
            "id": script.id.uuidString, "name": script.name, "version": script.version, "description": script.scriptDescription,
            "match": UserScriptMatcher.sources(for: script.patterns), "exclude": UserScriptMatcher.sources(for: script.excludes),
            "page": script.inPageWorld, "nonce": nonce, "values": values, "again": script.rerunOnNavigation,
            "storage": script.allows(.storage) && !script.inPageWorld, "network": script.allows(.network) && !script.inPageWorld,
        ]
        let api = script.inPageWorld ? "" : """
          var store = cfg.values, GM_info = { script: { name: cfg.name, version: cfg.version, description: cfg.description }, scriptHandler: 'Browser Setu' };
          function parsed(text, fallback) { try { return text === undefined ? fallback : JSON.parse(text); } catch (e) { return fallback; } }
          function GM_log() { post({ op: 'log', text: Array.prototype.slice.call(arguments).join(' ') }); }
          function GM_addStyle(css) { var s = document.createElement('style'); s.textContent = String(css); (document.head || document.documentElement).appendChild(s); return s; }
          function refused(name) { return function () { post({ op: 'denied', text: name }); }; }
          var GM_getValue = function (key, fallback) { post({ op: 'denied', text: 'GM_getValue' }); return fallback; }, GM_setValue = refused('GM_setValue'), GM_deleteValue = refused('GM_deleteValue'), GM_listValues = function () { post({ op: 'denied', text: 'GM_listValues' }); return []; };
          if (cfg.storage) {
            GM_getValue = function (key, fallback) { return parsed(store[key], fallback); };
            GM_setValue = function (key, value) { var text = JSON.stringify(value); if (text === undefined) return; store[key] = text; post({ op: 'set', key: String(key), value: text }); };
            GM_deleteValue = function (key) { delete store[key]; post({ op: 'del', key: String(key) }); };
            GM_listValues = function () { return Object.keys(store); };
          }
          var GM_xmlhttpRequest = function (d) {
            d = d || {};
            if (!cfg.network) { post({ op: 'denied', text: 'GM_xmlhttpRequest' }); if (d.onerror) d.onerror({ error: 'This script was not given permission to contact websites.' }); return { abort: function () {} }; }
            post({ op: 'xhr', method: d.method || 'GET', url: String(d.url), headers: d.headers || {}, data: d.data == null ? null : String(d.data), timeout: d.timeout || 15000 }).then(function (r) {
              if (!r || r.error) { if (d.onerror) d.onerror({ error: (r && r.error) || 'The request failed.' }); return; }
              if (d.onload) d.onload({ status: r.status, statusText: r.statusText, responseText: r.responseText, response: r.responseText, finalUrl: r.finalUrl, readyState: 4 });
            }, function () { if (d.onerror) d.onerror({ error: 'The request failed.' }); });
            return { abort: function () {} };
          };
          var GM = {
            info: GM_info, log: GM_log, addStyle: GM_addStyle,
            getValue: function (k, d) { return Promise.resolve(GM_getValue(k, d)); }, setValue: function (k, v) { return Promise.resolve(GM_setValue(k, v)); },
            deleteValue: function (k) { return Promise.resolve(GM_deleteValue(k)); }, listValues: function () { return Promise.resolve(GM_listValues()); },
            xmlHttpRequest: GM_xmlhttpRequest, xmlhttpRequest: GM_xmlhttpRequest
          };
          var unsafeWindow = window;
        """
        let params = script.inPageWorld ? "" : "GM_info, GM_log, GM_addStyle, GM_getValue, GM_setValue, GM_deleteValue, GM_listValues, GM_xmlhttpRequest, GM, unsafeWindow"
        return """
        (function () {
          var cfg = \(json(config));
          function hit(list) { var href = location.href; return list.some(function (source) { try { return new RegExp(source, 'i').test(href); } catch (e) { return false; } }); }
          var listening = false;
          function start() {
          var bridge = !cfg.page && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bsus;
          function post(message) {
            if (cfg.page) { try { document.dispatchEvent(new CustomEvent('bsus-' + cfg.nonce, { detail: JSON.stringify(message) })); } catch (e) {} return Promise.resolve(null); }
            try { return bridge ? bridge.postMessage(message) : Promise.resolve(null); } catch (e) { return Promise.resolve(null); }
          }
        \(api)
          if (!cfg.page && !listening) {
            listening = true;
            window.addEventListener('error', function (e) { post({ op: 'err', text: (e.message || 'Error') + (e.lineno ? ' (line ' + e.lineno + ')' : '') }); });
            window.addEventListener('unhandledrejection', function (e) { post({ op: 'err', text: String(e.reason && e.reason.message ? e.reason.message : e.reason) }); });
          }
          post({ op: 'ran' });
          try {
            (function (\(params)) {
        \(script.source)
            }).call(window\(script.inPageWorld ? "" : ", GM_info, GM_log, GM_addStyle, GM_getValue, GM_setValue, GM_deleteValue, GM_listValues, GM_xmlhttpRequest, GM, unsafeWindow"));
          } catch (error) { post({ op: 'err', text: String(error && error.message ? error.message : error) }); console.error('Browser Setu user script ' + cfg.name + ':', error); }
          }
          if (!cfg.again) { if (hit(cfg.match) && !hit(cfg.exclude)) start(); return; }
          // A site that changes its address without loading a new document: judged again whenever the address changes. The address is looked at on the events that go with
          // such a change, when the page changes, and twice a second; each time it is a comparison of two strings, nothing more.
          var last = null;
          function check() {
            var now = location.href;
            if (now === last) return;
            last = now;
            if (hit(cfg.match) && !hit(cfg.exclude)) start();
          }
          check();
          ['popstate', 'hashchange', 'pageshow'].forEach(function (name) { window.addEventListener(name, check); });
          ['turbo:load', 'turbo:render', 'pjax:end', 'yt-navigate-finish'].forEach(function (name) { document.addEventListener(name, check); });
          var pending = null;
          try { new MutationObserver(function () { if (pending) return; pending = setTimeout(function () { pending = null; check(); }, 250); }).observe(document.documentElement, { childList: true, subtree: true }); } catch (e) {}
          // A change of address that makes no event and changes nothing on the page (history.pushState alone) is caught here, twice a second. (A page in the background is
          // slowed down by the browser itself, and is looked at again as soon as it is shown.)
          document.addEventListener('visibilitychange', check);
          setInterval(check, 500);
        })();
        """
    }
}
