import SwiftUI

/// Page-wide switches the person has chosen (see Settings › Privacy). Engine-neutral: the engine turns them into whatever it needs.
struct WebPolicy: Equatable {
    var blockWebRTC = false
    var exceptions = Set<String>()
    /// Small changes to what canvas, audio and the processor count report, different for every site and every start, so a site cannot recognise this device by them.
    var randomizeFingerprint = false
    var fingerprintExceptions = Set<String>()
    /// Pages that are Google AMP copies are replaced by the site's own page.
    var deAMP = false
    /// Skips and mutes the video ads on YouTube.
    var blockVideoAds = false
    /// What the ad blocker removes and hides; the built-in set, or a newer one the browser has fetched.
    var youtubeRules = YouTubeAdRules.builtIn
    /// A page may start video or sound only after a tap or a key press, not by itself (a feed that plays as you scroll, a preview, the next video).
    var blockAutoplay = false
    var autoplayExceptions = Set<String>()
    /// Presses "reject" on consent banners, and hides the ones left.
    var cookieBanners = false
    /// Sites where cookie banners are left alone, and whether a banner that cannot be refused may be hidden (it is then reported as hidden, never as refused).
    var consentOffSites = Set<String>()
    var hideUnrefusableBanners = true
    /// Send no referrer to other sites.
    var referrerSameSiteOnly = false
    /// Tells sites, with the standard Global Privacy Control signal, not to sell or share what they learn about the visitor.
    var globalPrivacyControl = false
    /// Links lose their `ping` attribute, which would report every click to a third party.
    var blockLinkPings = false
    /// Websites (name without "www.") that load in WebKit's Lockdown Mode: no JIT, no WebGL, few fonts and media formats. Safer, but some pages break.
    var lockdownHosts = Set<String>()
    /// Pages cannot reach this device or the home network, except the sites named here (name without "www.").
    var blockLocalNetwork = false
    var localNetworkAllowed = Set<String>()
    /// Refuses Google's analytics, advertising and font servers, and the embedded social-network widgets.
    var blockGoogleServices = false
    var blockSocialWidgets = false
    /// The click (with a key held) that opens a link in Glance instead of following it; `.none` leaves it to the link's menu.
    var glanceTrigger: GlanceTrigger = .none
    /// Developer capture of the page's console, WebSocket connections and failed resources (runs in the page's own world).
    var devCapture = false
    /// A remembered playback speed for each website (name without "www.").
    var videoSpeeds: [String: Double] = [:]
    /// Light websites are shown dark (see AdaptiveDark.swift); the sites named are darkened by choice, or never touched (name without "www.").
    var darkPages: DarkPages = .off
    var darkSites = Set<String>()
    var darkSitesOff = Set<String>()
    /// SponsorBlock's settings; nil (no script at all) while it is off or not agreed to.
    var sponsorBlock: SponsorPolicy?
}

// MARK: - AMP links

enum AMPLinks {
    /// The site's own address for a link that goes through an AMP cache, or nil when the link is not one. Handles the two forms that carry the real address in
    /// the path: `google.com/amp/s/example.com/page` and `example-com.cdn.ampproject.org/c/s/example.com/page`.
    static func canonical(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var rest: ArraySlice<String>?
        var secure = true
        if host == "google.com" || host.hasPrefix("www.google."), parts.first == "amp", parts.count >= 2 {
            if parts[1] == "s" { rest = parts.dropFirst(2) } else { secure = false; rest = parts.dropFirst(1) }
        } else if host.hasSuffix(".cdn.ampproject.org"), parts.count >= 2, ["c", "v", "i", "wp"].contains(parts[0]) {
            if parts[1] == "s" { rest = parts.dropFirst(2) } else { secure = false; rest = parts.dropFirst(1) }
        }
        guard let rest, let first = rest.first, first.contains("."), !first.contains(":") else { return nil }
        var parts2 = URLComponents()
        parts2.scheme = secure ? "https" : "http"
        parts2.host = first
        parts2.percentEncodedPath = "/" + rest.dropFirst().joined(separator: "/")
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, !query.isEmpty {
            let kept = query.split(separator: "&").filter { pair in
                let name = pair.split(separator: "=", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                return !(name.hasPrefix("amp_") || name == "usqp" || name == "amp" || name == "_gsa")
            }
            if !kept.isEmpty { parts2.percentEncodedQuery = kept.joined(separator: "&") }
        }
        guard let result = parts2.url, result.host?.isEmpty == false else { return nil }
        return result
    }
}

// MARK: - The scripts

/// The page scripts behind the switches above. Plain text only; they are installed by `UserScriptInstaller`, the one file that puts scripts into pages.
/// None of them can send anything back to the app.
enum PageScripts {
    /// Sets `host` to the website the person is on: the top page's, also from inside a frame from another site. A frame cannot read the top page's address when the two
    /// are from different sites, but the browser tells it the addresses of the pages around it (`ancestorOrigins`), and the last of them is the top page. A frame that
    /// used its own name here would give every page that embeds it the same answer, which is what lets one tracker tell the sites apart from the others.
    static let topHostJS = """
    var host = location.hostname.toLowerCase();
    try { host = window.top.location.hostname.toLowerCase(); } catch (e) {
      try { var ao = location.ancestorOrigins; if (ao && ao.length) host = new URL(ao[ao.length - 1]).hostname.toLowerCase(); } catch (e2) {}
    }
    """

    private static func json(_ value: Any) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)) ?? "null"
    }

    /// The script side of Global Privacy Control, for systems before 27 where WebKit cannot add the request header itself.
    static let globalPrivacyControl = """
    (function () {
      try {
        if (navigator.globalPrivacyControl === true) { return; }
        Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get: function () { return true; }, configurable: true, enumerable: true });
      } catch (e) {}
    })();
    """

    /// Removes the `ping` attribute from links, now and as the page adds them, so a click is not reported to a third party.
    static let noLinkPings = """
    (function () {
      try {
        function clean(root) {
          var list = root.querySelectorAll ? root.querySelectorAll('a[ping],area[ping]') : [];
          for (var i = 0; i < list.length; i++) { list[i].removeAttribute('ping'); }
        }
        function start() {
          clean(document);
          new MutationObserver(function (records) {
            for (var i = 0; i < records.length; i++) {
              var r = records[i];
              if (r.type === 'attributes') { r.target.removeAttribute('ping'); continue; }
              for (var j = 0; j < r.addedNodes.length; j++) {
                var n = r.addedNodes[j];
                if (n.nodeType === 1) { if (n.hasAttribute && n.hasAttribute('ping')) { n.removeAttribute('ping'); } clean(n); }
              }
            }
          }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['ping'] });
        }
        if (document.documentElement) { start(); }
        else { document.addEventListener('DOMContentLoaded', start); }
      } catch (e) {}
    })();
    """

    /// Canvas, WebGL read-back, audio and processor count. The change is a pattern worked out from a number picked at random each time the app starts and the
    /// site's name, so within one site and one run the answers agree with each other, and another site (or the next run) gets different ones.
    static func fingerprint(seed: UInt32, exceptions: Set<String>) -> String {
        """
        (function () {
          var seed = \(seed), skip = \(json(Array(exceptions).sorted()));
          \(topHostJS)
          host = host.replace(/^www\\./, '');
          if (skip.some(function (s) { return host === s || host.endsWith('.' + s); })) return;
          var h = seed >>> 0;
          for (var i = 0; i < host.length; i++) { h = Math.imul(h ^ host.charCodeAt(i), 16777619) >>> 0; }
          function rng(extra) {
            var s = (h ^ (extra | 0)) >>> 0;
            return function () {
              s = (s + 0x6D2B79F5) >>> 0; var t = s;
              t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
              return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
            };
          }
          // About one pixel in fifty has the lowest bit of one colour flipped: not visible, but the picture's hash is different.
          function perturb(data, w, ht) {
            var r = rng(w * 31 + ht);
            for (var i = 0; i < data.length; i += 4) { if (r() < 0.02) { var c = (r() * 3) | 0; data[i + c] = data[i + c] ^ 1; } }
          }
          try {
            var gid = CanvasRenderingContext2D.prototype.getImageData;
            CanvasRenderingContext2D.prototype.getImageData = function () {
              var d = gid.apply(this, arguments);
              try { if (d.width * d.height <= 4000000) perturb(d.data, d.width, d.height); } catch (e) {}
              return d;
            };
            var noisyCopy = function (canvas) {
              try {
                var w = canvas.width, ht = canvas.height;
                if (!w || !ht || w * ht > 4000000) return canvas;
                var copy = document.createElement('canvas'); copy.width = w; copy.height = ht;
                var ctx = copy.getContext('2d'); ctx.drawImage(canvas, 0, 0);
                var img = gid.call(ctx, 0, 0, w, ht); perturb(img.data, w, ht); ctx.putImageData(img, 0, 0);
                return copy;
              } catch (e) { return canvas; }
            };
            var tdu = HTMLCanvasElement.prototype.toDataURL;
            HTMLCanvasElement.prototype.toDataURL = function () { return tdu.apply(noisyCopy(this), arguments); };
            var tb = HTMLCanvasElement.prototype.toBlob;
            HTMLCanvasElement.prototype.toBlob = function () { return tb.apply(noisyCopy(this), arguments); };
          } catch (e) {}
          try {
            ['WebGLRenderingContext', 'WebGL2RenderingContext'].forEach(function (name) {
              var C = window[name]; if (!C) return;
              var rp = C.prototype.readPixels;
              C.prototype.readPixels = function () {
                var r = rp.apply(this, arguments);
                try { var px = arguments[6]; if (px && (px instanceof Uint8Array || px instanceof Uint8ClampedArray) && px.length <= 16000000) perturb(px, arguments[2], arguments[3]); } catch (e) {}
                return r;
              };
            });
          } catch (e) {}
          try {
            if (window.AudioBuffer) {
              var gcd = AudioBuffer.prototype.getChannelData, done = new WeakSet();
              AudioBuffer.prototype.getChannelData = function () {
                var d = gcd.apply(this, arguments);
                if (!done.has(this)) { done.add(this); var r = rng(d.length); for (var i = 0; i < d.length; i += 97) { d[i] += (r() - 0.5) * 1e-6; } }
                return d;
              };
            }
            if (window.AnalyserNode) {
              var gf = AnalyserNode.prototype.getFloatFrequencyData;
              AnalyserNode.prototype.getFloatFrequencyData = function (a) {
                gf.apply(this, arguments);
                var r = rng(a.length); for (var i = 0; i < a.length; i += 5) { a[i] += (r() - 0.5) * 0.01; }
              };
            }
          } catch (e) {}
          try {
            var real = navigator.hardwareConcurrency || 4, shown = Math.min(real, [4, 6, 8][h % 3]);
            Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', { get: function () { return shown; }, configurable: true });
          } catch (e) {}
          // The size of text and of page elements is scaled by a factor within three millionths, different for each site: far below anything a layout shows,
          // but the exact widths a site measures to recognise installed fonts no longer repeat.
          try {
            var scale = 1 + (rng(7)() - 0.5) * 0.000006;
            var mt = CanvasRenderingContext2D.prototype.measureText;
            CanvasRenderingContext2D.prototype.measureText = function () {
              var m = mt.apply(this, arguments);
              try { var w = m.width * scale; return new Proxy(m, { get: function (t, k) { var v = t[k]; return k === 'width' ? w : (typeof v === 'function' ? v.bind(t) : v); } }); } catch (e) { return m; }
            };
            var rectOf = function (original) {
              return function () {
                var r = original.apply(this, arguments);
                try { return new DOMRect(r.x * scale, r.y * scale, r.width * scale, r.height * scale); } catch (e) { return r; }
              };
            };
            Element.prototype.getBoundingClientRect = rectOf(Element.prototype.getBoundingClientRect);
            Range.prototype.getBoundingClientRect = rectOf(Range.prototype.getBoundingClientRect);
          } catch (e) {}
        })();
        """
    }

    /// Runs when the page has loaded: if it says it is an AMP page and names its own full version, go there. Only to the same site or from an AMP cache, once per address.
    static let deAMP = """
    (function () {
      try {
        var d = document.documentElement;
        if (!d || !(d.hasAttribute('amp') || d.hasAttribute('\u{26A1}'))) return;
        var link = document.querySelector('link[rel="canonical"]');
        if (!link || !link.href) return;
        var target = new URL(link.href, location.href);
        if (target.protocol !== 'https:' && target.protocol !== 'http:') return;
        if (target.href === location.href) return;
        var here = location.hostname.toLowerCase(), there = target.hostname.toLowerCase();
        var cache = /(^|\\.)(ampproject\\.org|ampproject\\.net|bing-amp\\.com)$/.test(here);
        function site(h) { return h.split('.').slice(-2).join('.'); }
        if (!cache && site(here) !== site(there)) return;
        var key = '__bsDeAmp';
        if (sessionStorage.getItem(key) === target.href) return;
        sessionStorage.setItem(key, target.href);
        location.replace(target.href);
      } catch (e) {}
    })();
    """

    /// Runs in every page and frame, before the page's own scripts. A page may start media (`play()`, an `autoplay` attribute, a video that begins on its own) only within six
    /// seconds of a real tap, click or key press. Scrolling is neither: on a phone a scroll counts as a touch to WebKit, which is how a feed could start videos while you scrolled.
    /// The six seconds cover the page that opens after a tap and starts its own player. Sites in `exceptions` are left alone.
    static func noAutoplay(exceptions: Set<String>, grant: String = "") -> String {
        """
        (function () {
          var skip = \(json(Array(exceptions).sorted()));
          \(topHostJS)
          host = host.replace(/^www\\./, '');
          if (skip.some(function (s) { return host === s || host.endsWith('.' + s); })) return;
          // The page counts as "touched" from the first real tap, click or key press on it, and stays so: a video started afterwards (the one after an
          // advert, the next in a playlist, a player that builds a new element) is the viewer's doing. Before that, nothing may start by itself.
          var touched = false;
          function touch(e) { if (e.isTrusted) { touched = true; try { sessionStorage.setItem('__bsArm', String(Date.now())); } catch (x) {} } }
          ['click', 'keydown', 'touchend', 'pointerup'].forEach(function (name) { window.addEventListener(name, touch, true); });
          // Following a link to a video on the same website keeps the permission for the first seconds of the next page.
          try { if (Date.now() - Number(sessionStorage.getItem('__bsArm') || 0) < 8000) touched = true; } catch (e) {}
          try { if (navigator.userActivation && navigator.userActivation.hasBeenActive) touched = true; } catch (e) {}
          // The browser's own controls (the player panel's Play button) are the viewer's doing, but reach the page as a script, not as a tap. Just before such a command the browser sends this
          // event, whose name is chosen at random each time the app starts and is known only to the browser and to this script (a page cannot read this script). It lets playback start for
          // the next few seconds. The listener is registered with the original method, so a page that later replaces addEventListener cannot see or reuse it.
          var granted = 0;
          var grantName = \(json(grant));
          if (grantName) { try { EventTarget.prototype.addEventListener.call(window, grantName, function () { granted = Date.now(); }); } catch (e) {} }
          function viewerActive() { return granted > 0 && Date.now() - granted < 8000; }
          var realPlay = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function () {
            if (touched || viewerActive()) return realPlay.apply(this, arguments);
            try { this.pause(); } catch (e) {}
            return Promise.reject(new DOMException('Playback needs a tap first.', 'NotAllowedError'));
          };
          // An element with the autoplay attribute starts without anyone calling play(): take the attribute away, and stop anything that starts by itself.
          function tame(el) { try { if (el.autoplay) { el.autoplay = false; el.removeAttribute('autoplay'); } } catch (e) {} }
          document.addEventListener('DOMContentLoaded', function () { document.querySelectorAll('video[autoplay],audio[autoplay]').forEach(tame); });
          try {
            new MutationObserver(function (list) {
              list.forEach(function (m) { m.addedNodes.forEach(function (n) { if (n.nodeType === 1) { if (n.matches && n.matches('video,audio')) tame(n); if (n.querySelectorAll) n.querySelectorAll('video[autoplay],audio[autoplay]').forEach(tame); } }); });
            }).observe(document, { childList: true, subtree: true });
          } catch (e) {}
          window.addEventListener('play', function (e) {
            var el = e.target;
            if (el && el.pause && !touched && !viewerActive()) { try { el.pause(); } catch (x) {} }
          }, true);
        })();
        """
    }

    /// On YouTube only: hides the ad slots, presses Skip when it shows, and while an ad that cannot be skipped is playing, mutes it and jumps to its end. The sound and
    /// speed are put back the moment the ad is over. Does nothing at all when no ad is playing.
}

// MARK: - Settings held by the model

extension BrowserModel {
    func scriptsAllowed(forHost host: String?) -> Bool {
        guard let key = FaviconStore.key(forHost: host) else { return true }
        return !jsOffSites.contains(key)
    }

    func setScripts(host: String?, allowed: Bool) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        if allowed { jsOffSites.remove(key) } else { jsOffSites.insert(key) }
        saveSetting("site_js_off", encodedMap(["list": Array(jsOffSites).sorted()]))
        for tab in tabs where FaviconStore.key(forHost: tab.url?.host) == key && !tab.isBlank { tab.reload() }
    }

    func neverSleeps(host: String?) -> Bool {
        FaviconStore.key(forHost: host).map { neverSleepSites.contains($0) } ?? false
    }

    func setNeverSleeps(host: String?, _ on: Bool) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        if on { neverSleepSites.insert(key) } else { neverSleepSites.remove(key) }
        saveSetting("never_sleep_sites", encodedMap(["list": Array(neverSleepSites).sorted()]))
    }

    func setFingerprintException(host: String?, allowed: Bool) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        if allowed { fingerprintExceptions.insert(key) } else { fingerprintExceptions.remove(key) }
        saveSetting("fingerprint_exceptions", encodedMap(["list": Array(fingerprintExceptions).sorted()]))
        pushWebPolicy()
    }

    func loadPageDefenseSettings(_ get: (String) -> String?) {
        func list(_ key: String) -> Set<String> { Set(Self.decodeMap(get(key), as: [String].self)["list"] ?? []) }
        jsOffSites = list("site_js_off")
        neverSleepSites = list("never_sleep_sites")
        fingerprintExceptions = list("fingerprint_exceptions")
        randomizeFingerprint = get("fingerprint_noise") == "1"
        deAMP = get("de_amp") != "0"
        blockVideoAds = get("video_ads") != "0"
        loadYouTubeRules(get)
        blockAutoplay = get("block_autoplay") != "0"
        hideCookieBanners = get("cookie_banners") != "0"
        hideUnrefusableBanners = get("cookie_banners_hide") != "0"
        consentOffSites = list("consent_off")
        sponsorActions = Self.decodeMap(get("sponsor_actions"), as: String.self)
        sponsorOffSites = list("sponsor_off")
        if let raw = get("sponsor_consent"), let seconds = Double(raw) { sponsorConsentDate = Date(timeIntervalSince1970: seconds) } else { sponsorConsentDate = nil }
        if let server = get("sponsor_server"), SponsorBlockService.validServer(server) { sponsorServer = server }
        sponsorBlockEnabled = get("sponsor_on") == "1" && sponsorConsentDate != nil
        consentLog = (get("consent_log")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([ConsentRecord].self, from: $0) } ?? []
        videoSpeeds = Self.decodeMap(get("video_speeds"), as: Double.self)
        autoplayExceptions = list("autoplay_exceptions")
    }

    func setAutoplayException(host: String?, allowed: Bool) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        if allowed { autoplayExceptions.insert(key) } else { autoplayExceptions.remove(key) }
        saveSetting("autoplay_exceptions", encodedMap(["list": Array(autoplayExceptions).sorted()]))
        pushWebPolicy()
    }

    /// An AMP cache link, or nil. Cannot loop: the result is never an AMP cache address.
    func deAMPedLink(_ url: URL) -> URL? { deAMP ? AMPLinks.canonical(url) : nil }
}

// MARK: - Settings screens

/// The Privacy switches that change what pages can do or see, and the lists of sites they were changed for.
struct PageDefensesSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Toggle("Stop videos and sound starting by themselves", isOn: $model.blockAutoplay)
            ShowMoreRows(model.autoplayExceptions.sorted(), id: \.self) { site in
                HStack {
                    Label("\(site) may start media by itself", systemImage: "play.circle").font(.callout)
                    Spacer()
                    Button("Stop It") { model.setAutoplayException(host: site, allowed: false) }.buttonStyle(.borderless)
                }
            }
            Toggle("Open a site's own page instead of its AMP copy", isOn: $model.deAMP)
            Toggle("Block ads on YouTube", isOn: $model.blockVideoAds)
            if model.blockVideoAds {
                Toggle("Keep the YouTube ad rules up to date", isOn: $model.keepYouTubeRulesFresh)
                YouTubeRulesRow()
            }
            Toggle("Randomize canvas, audio and processor details (experimental)", isOn: $model.randomizeFingerprint)
                .settingsNoted("Off unless you turn it on. It works by changing what a page's own scripts read, so a site that looks for that can tell; it does not cover fonts, screen size or graphics-card names, and it can upset pages that need exact pixels. Use “Not randomized on” for a site it breaks.")
            if model.randomizeFingerprint, !model.fingerprintExceptions.isEmpty {
                ShowMoreRows(model.fingerprintExceptions.sorted(), id: \.self) { site in
                    HStack {
                        Text("Not randomized on \(site)").font(.callout)
                        Spacer()
                        Button("Randomize Again") { model.setFingerprintException(host: site, allowed: false) }.buttonStyle(.borderless)
                    }
                }
            }
            ShowMoreRows(model.jsOffSites.sorted(), id: \.self) { site in
                HStack {
                    Label("JavaScript is off on \(site)", systemImage: "curlybraces").font(.callout)
                    Spacer()
                    Button("Turn On") { model.setScripts(host: site, allowed: true) }.buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Pages")
        } footer: {
            Text("A video or sound starts only after you tap or press a key, not while you scroll, and not by itself: a page that opens after your tap has six seconds to start its player. Playlists and “Autoplay next” wait for a tap; a site that needs to play by itself (a voice-chat page, say) can be allowed in Site Privacy. AMP copies are replaced when a page names its own full version. YouTube ads are stopped before they load, by removing the ad schedule from the video's own data, and any that still start are skipped or muted. YouTube changes this often, so the rules (names of data fields and page elements, never code) can be fetched from the project's public repository, at most once a day, while this is on: the request carries no cookies or identifiers. Turn off the update to use only the rules built into the app. Randomizing makes a site's canvas, audio and processor-count readings differ from other sites' and from run to run, so they cannot recognise this device; a few sites that draw pictures or sound can look slightly different, so each site has its own off switch in Site Privacy. Both of these apply to pages opened after the change.")
        }
    }
}

/// Never-sleep sites, in the Performance settings.
struct NeverSleepSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            if model.neverSleepSites.isEmpty {
                Label("No site is kept awake", systemImage: "moon.zzz").foregroundStyle(.secondary)
            }
            ShowMoreRows(model.neverSleepSites.sorted(), id: \.self) { site in
                HStack {
                    Text(site)
                    Spacer()
                    Button("Allow Sleep") { model.setNeverSleeps(host: site, false) }.buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Never Put to Sleep")
        } footer: {
            Text("Tabs on these sites stay loaded when memory is short, and when you put all other tabs to sleep. Add a site from Site Privacy, or with “Never Put This Site to Sleep” in the command palette.")
        }
    }
}

/// The ad rules in use, and a button to look for newer ones.
struct YouTubeRulesRow: View {
    @EnvironmentObject var model: BrowserModel
    @State private var status = ""
    @State private var checking = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ad rules version \(model.youtubeRules.version)")
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                else if let checked = model.youtubeRulesChecked { Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button(checking ? "Checking…" : "Check Now") {
                checking = true
                Task { @MainActor in status = await model.refreshYouTubeRules(force: true); checking = false }
            }
            .disabled(checking).buttonStyle(.borderless)
        }
    }
}
