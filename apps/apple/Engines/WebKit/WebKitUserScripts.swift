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
            controller.addUserScript(WKUserScript(source: PageScripts.noAutoplay(exceptions: policy.autoplayExceptions), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if policy.devCapture {
            controller.addUserScript(WKUserScript(source: DevCaptureScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        if policy.referrerSameSiteOnly {
            controller.addUserScript(WKUserScript(source: ReferrerMode.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }
        if policy.cookieBanners {
            controller.addUserScript(WKUserScript(source: CookieBanners.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
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
          var host = location.hostname.toLowerCase(), skip = \(list);
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

    static func install(_ scripts: [UserScript], policy: WebPolicy = WebPolicy(), into controller: WKUserContentController) {
        controller.removeAllUserScripts()
        addScrollbarHider(to: controller)
        addPolicyScripts(policy, to: controller)
        addBrowserScripts(to: controller, signInWatcher: true)
        for script in scripts where script.enabled && !script.sites.isEmpty {
            let world: WKContentWorld = script.inPageWorld ? .page : .world(name: "BrowserSetuUserScripts")
            controller.addUserScript(WKUserScript(source: wrapped(script), injectionTime: script.runAtStart ? .atDocumentStart : .atDocumentEnd,
                                                  forMainFrameOnly: true, in: world))
        }
    }

    /// The script inside a check for the website. The list of websites and the name are passed as JSON text, never joined into code.
    static func wrapped(_ script: UserScript) -> String {
        func json(_ value: Any) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)) ?? "null"
        }
        return """
        (function () {
          var sites = \(json(script.sites)), name = \(json(script.name)), host = location.hostname.toLowerCase();
          var ok = sites.some(function (s) { return s === '*' || host === s || host.endsWith('.' + s); });
          if (!ok) return;
          try {
        \(script.source)
          } catch (error) { console.error('Browser Setu user script ' + name + ':', error); }
        })();
        """
    }
}
