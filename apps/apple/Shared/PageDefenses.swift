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
    /// Send no referrer to other sites.
    var referrerSameSiteOnly = false
    /// Developer capture of the page's console, WebSocket connections and failed resources (runs in the page's own world).
    var devCapture = false
    /// A remembered playback speed for each website (name without "www.").
    var videoSpeeds: [String: Double] = [:]
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
    private static func json(_ value: Any) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)) ?? "null"
    }

    /// Canvas, WebGL read-back, audio and processor count. The change is a pattern worked out from a number picked at random each time the app starts and the
    /// site's name, so within one site and one run the answers agree with each other, and another site (or the next run) gets different ones.
    static func fingerprint(seed: UInt32, exceptions: Set<String>) -> String {
        """
        (function () {
          var seed = \(seed), skip = \(json(Array(exceptions).sorted()));
          var host = location.hostname.toLowerCase();
          try { host = window.top.location.hostname.toLowerCase(); } catch (e) {}
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
    static func noAutoplay(exceptions: Set<String>) -> String {
        """
        (function () {
          var skip = \(json(Array(exceptions).sorted()));
          var host = location.hostname.toLowerCase();
          try { host = window.top.location.hostname.toLowerCase(); } catch (e) {}
          host = host.replace(/^www\\./, '');
          if (skip.some(function (s) { return host === s || host.endsWith('.' + s); })) return;
          var armedUntil = 0;
          function arm(e) { if (e.isTrusted) armedUntil = Date.now() + 6000; }
          ['click', 'keydown', 'pointerup', 'touchend'].forEach(function (name) { if (name === 'click' || name === 'keydown') window.addEventListener(name, arm, true); });
          try { var stored = Number(sessionStorage.getItem('__bsArm') || 0); if (Date.now() - stored < 8000) armedUntil = Date.now() + 6000; } catch (e) {}
          window.addEventListener('click', function (e) { if (e.isTrusted) { try { sessionStorage.setItem('__bsArm', String(Date.now())); } catch (x) {} } }, true);
          var realPlay = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function () {
            if (Date.now() <= armedUntil || this.controls) return realPlay.apply(this, arguments);
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
            if (el && el.pause && !el.controls && Date.now() > armedUntil) { try { el.pause(); } catch (x) {} }
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
            Toggle("Randomize canvas, audio and processor details", isOn: $model.randomizeFingerprint)
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
