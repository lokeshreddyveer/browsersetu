import CryptoKit
import SwiftUI

// Skipping the sponsor, self-promotion and similar stretches that people have marked inside YouTube videos. Written here, for Browser Setu, around a documented lookup
// that anyone can run (the segment service named in Settings, which you can change to a server of your own). It is OFF until the person turns it on and agrees to what it
// sends. Nothing here touches a private tab, a protected (DRM) video, a live stream or a video that is showing an ad.

enum SponsorAction: String, Codable, CaseIterable, Identifiable {
    case off, button, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Leave it"
        case .button: "Show a Skip button"
        case .auto: "Skip automatically"
        }
    }
}

enum SponsorCategory: String, CaseIterable, Codable, Identifiable {
    case sponsor, selfpromo, interaction, intro, outro, preview, filler, music_offtopic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfpromo: "Unpaid or self-promotion"
        case .interaction: "Reminder to like or subscribe"
        case .intro: "Intro"
        case .outro: "Outro and end cards"
        case .preview: "Preview or recap"
        case .filler: "Tangents and filler"
        case .music_offtopic: "Non-music part of a music video"
        }
    }
    /// What each starts as. Only the three that are plainly marketing are on at all.
    var defaultAction: SponsorAction {
        switch self {
        case .sponsor: .auto
        case .selfpromo, .interaction: .button
        default: .off
        }
    }
}

struct SponsorSpan: Codable, Equatable {
    var start: Double
    var end: Double
    var category: String
    var uuid: String
}

/// What the page script is given: what to do for each kind of segment, and the sites where it does nothing. Nil (no script at all) while the feature is off.
struct SponsorPolicy: Equatable {
    var actions: [String: String]
    var offSites: Set<String>
}

enum SponsorVideoID {
    static func valid(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == "-" || $0 == "_" }
    }

    /// The video's identifier from a YouTube address, and nothing else from the page.
    static func parse(_ url: URL?) -> String? {
        guard let url, url.scheme == "https" || url.scheme == "http", var host = url.host?.lowercased() else { return nil }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        guard host == "youtube.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        var candidate: String?
        if parts.first == "watch" { candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value }
        else if parts.count >= 2, ["shorts", "embed", "live"].contains(parts[0]) { candidate = parts[1] }
        guard let id = candidate, valid(id) else { return nil }
        return id
    }

    /// The first four characters of the video identifier's SHA-256: the only thing about the video that is sent. Many thousands of videos share any one prefix.
    static func hashPrefix(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
    }
}

/// Spans already fetched, kept in memory only (they are gone when the browser quits). A video with segments is kept six hours, one without an hour.
final class SponsorCache {
    private var items: [String: (segments: [SponsorSpan], date: Date)] = [:]
    static let hitLifetime: TimeInterval = 6 * 3600
    static let emptyLifetime: TimeInterval = 3600

    private func key(_ id: String, _ categories: [String]) -> String { id + "|" + categories.sorted().joined(separator: ",") }

    func get(_ id: String, categories: [String], now: Date = Date()) -> [SponsorSpan]? {
        guard let item = items[key(id, categories)] else { return nil }
        let life = item.segments.isEmpty ? Self.emptyLifetime : Self.hitLifetime
        if now.timeIntervalSince(item.date) > life { items[key(id, categories)] = nil; return nil }
        return item.segments
    }

    func set(_ id: String, categories: [String], segments: [SponsorSpan], now: Date = Date()) {
        if items.count >= 100 { items.removeValue(forKey: items.min { $0.value.date < $1.value.date }?.key ?? "") }
        items[key(id, categories)] = (segments, now)
    }

    func clear() { items = [:] }
    var count: Int { items.count }
}

// MARK: - The page script

enum SponsorBlockScript {
    static func source(_ policy: SponsorPolicy) -> String {
        let config: [String: Any] = ["actions": policy.actions, "offSites": policy.offSites.sorted()]
        guard let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) else { return "" }
        return template.replacingOccurrences(of: "__CONFIG__", with: json)
    }

    static let stats = "return window.__bsSponsor ? window.__bsSponsor.stats() : null;"

    /// Events, not polling: the script listens to the video's own play, pause, seek and speed events, and sets one timer for the moment the next segment starts.
    private static let template = #"""
    (function () {
      var cfg = __CONFIG__;
      var host = location.hostname.toLowerCase().replace(/^(www|m)\./, '');
      if (host !== 'youtube.com') return;
      if (cfg.offSites.some(function (h) { return host === h || host.endsWith('.' + h); })) return;
      var data = { id: null, segments: [] }, video = null, bound = null, timer = null, tries = 0, state = 'idle';
      var stats = { skipped: 0, seconds: 0 }, released = {}, ourSeek = false, lastSkip = null, box = null, hideTimer = null;

      function currentID() {
        var m = location.pathname.match(/^\/(?:shorts|embed|live)\/([A-Za-z0-9_-]{11})/);
        if (m) return m[1];
        return new URLSearchParams(location.search).get('v');
      }
      function findVideo() {
        return document.querySelector('#movie_player video.html5-main-video') || document.querySelector('#movie_player video') ||
               document.querySelector('video.html5-main-video') || document.querySelector('video');
      }
      function adShowing() { var p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player'); return !!(p && p.classList.contains('ad-showing')); }
      function actionFor(seg) { return cfg.actions[seg.category] || 'off'; }
      // Not on a protected video (it has encryption keys), a live stream, an ad, or a video this data was not for.
      function eligible() {
        if (!video || data.id !== currentID()) return false;
        if (video.mediaKeys) { state = 'protected'; return false; }
        if (adShowing()) return false;
        return isFinite(video.duration) && video.duration > 0;
      }
      function inside(t) {
        for (var i = 0; i < data.segments.length; i++) { var s = data.segments[i]; if (t >= s.start - 0.05 && t < s.end - 0.05) return s; }
        return null;
      }
      function nextAfter(t) {
        for (var i = 0; i < data.segments.length; i++) { var s = data.segments[i]; if (s.start > t && actionFor(s) !== 'off') return s; }
        return null;
      }
      function clearTimer() { if (timer) { clearTimeout(timer); timer = null; } }

      function evaluate() {
        clearTimer();
        if (!video || !data.segments.length || !eligible()) { hideButton(); return; }
        state = 'ready';
        var t = video.currentTime, seg = inside(t), a = seg ? actionFor(seg) : 'off';
        if (seg && a !== 'off' && !released[seg.uuid]) { if (a === 'auto') { skip(seg); return; } showButton(seg); } else if (!(box && box.getAttribute('data-for') === 'skipped')) { hideButton(); }
        if (video.paused || video.ended) return;
        var rate = video.playbackRate || 1, target = null;
        if (seg && a === 'button' && !released[seg.uuid]) { target = seg.end; } else { var n = nextAfter(t); if (n) target = n.start; }
        if (target !== null) { timer = setTimeout(evaluate, Math.min(Math.max(0, (target - t) / rate * 1000 - 20), 600000)); }
      }

      function parent() { return document.fullscreenElement || document.body || document.documentElement; }
      function makeBox() {
        if (box && box.isConnected && box.parentNode === parent()) return box;
        if (box && box.parentNode) box.parentNode.removeChild(box);
        box = document.createElement('div');
        box.setAttribute('data-bs-sponsor', '');
        box.style.cssText = 'position:fixed;right:16px;bottom:84px;z-index:2147483647;display:none;gap:8px;align-items:center;padding:8px 12px;border-radius:10px;' +
          'background:rgba(20,20,20,.88);color:#fff;font:600 13px -apple-system,system-ui,sans-serif;box-shadow:0 2px 10px rgba(0,0,0,.4)';
        parent().appendChild(box);
        return box;
      }
      function label(seg) { return { sponsor: 'sponsor', selfpromo: 'promotion', interaction: 'reminder', intro: 'intro', outro: 'outro', preview: 'preview', filler: 'filler', music_offtopic: 'non-music part' }[seg.category] || 'segment'; }
      function addButton(text, fn) {
        var b = document.createElement('button');
        b.textContent = text; b.type = 'button';
        b.style.cssText = 'all:unset;cursor:pointer;padding:4px 10px;border-radius:7px;background:#fff;color:#111;font:600 13px -apple-system,system-ui,sans-serif';
        b.addEventListener('click', function (e) { e.stopPropagation(); fn(); });
        makeBox().appendChild(b);
      }
      function showButton(seg) {
        var b = makeBox();
        if (b.getAttribute('data-for') === seg.uuid && b.style.display === 'flex') return;
        b.textContent = ''; b.setAttribute('data-for', seg.uuid); b.style.display = 'flex';
        addButton('Skip ' + label(seg), function () { skip(seg); });
      }
      function hideButton() { if (box) { box.style.display = 'none'; box.textContent = ''; box.removeAttribute('data-for'); } }
      function notice(seg, from) {
        var b = makeBox();
        b.textContent = ''; b.setAttribute('data-for', 'skipped'); b.style.display = 'flex';
        var t = document.createElement('span'); t.textContent = 'Skipped ' + label(seg); b.appendChild(t);
        addButton('Undo', function () { released[seg.uuid] = true; ourSeek = true; try { video.currentTime = from; } catch (e) {} hideButton(); });
        if (hideTimer) clearTimeout(hideTimer);
        hideTimer = setTimeout(hideButton, 5000);
      }

      function skip(seg) {
        if (!video) return;
        var from = video.currentTime;
        ourSeek = true; lastSkip = { seg: seg, from: from, at: Date.now() };
        try { video.currentTime = Math.min(seg.end, video.duration); } catch (e) { ourSeek = false; return; }
        stats.skipped++; stats.seconds += Math.max(0, seg.end - from);
        if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
        notice(seg, seg.start);
      }

      // The person going back into a segment that was just skipped means they want to see it: it is not skipped again.
      function onSeeked() {
        if (ourSeek) { ourSeek = false; } else if (lastSkip && Date.now() - lastSkip.at < 15000 && video.currentTime < lastSkip.seg.end - 0.5) { released[lastSkip.seg.uuid] = true; }
        evaluate();
      }
      function bind() {
        var v = findVideo();
        if (!v) { if (++tries < 12) setTimeout(bind, 500); else state = 'no-player'; return; }
        if (v === bound) { evaluate(); return; }
        if (bound) { ['playing', 'pause', 'ratechange', 'loadedmetadata', 'durationchange', 'emptied', 'ended'].forEach(function (n) { bound.removeEventListener(n, evaluate); }); bound.removeEventListener('seeked', onSeeked); }
        bound = video = v;
        ['playing', 'pause', 'ratechange', 'loadedmetadata', 'durationchange', 'emptied', 'ended'].forEach(function (n) { v.addEventListener(n, evaluate); });
        v.addEventListener('seeked', onSeeked);
        evaluate();
      }
      document.addEventListener('fullscreenchange', function () { if (box) { var current = box.getAttribute('data-for'); hideButton(); box = null; if (current) evaluate(); } });
      document.addEventListener('yt-navigate-finish', function () { tries = 0; released = {}; evaluate(); bind(); });

      window.__bsSponsor = {
        set: function (id, segments) {
          if (id !== currentID() || !Array.isArray(segments)) return;
          var list = [];
          segments.forEach(function (s) {
            if (s && typeof s.start === 'number' && typeof s.end === 'number' && s.end > s.start && typeof s.category === 'string' && typeof s.uuid === 'string') list.push({ start: s.start, end: s.end, category: s.category, uuid: s.uuid });
          });
          list.sort(function (a, b) { return a.start - b.start; });
          data = { id: id, segments: list.slice(0, 100) }; released = {}; tries = 0; bind();
        },
        stats: function () { return JSON.stringify({ skipped: stats.skipped, seconds: Math.round(stats.seconds), state: state, count: data.segments.length }); }
      };
    })();
    """#
}

// MARK: - The browser's side

extension BrowserModel {
    /// The categories that have an action, with what each does.
    var sponsorActionMap: [String: String] {
        var map: [String: String] = [:]
        for category in SponsorCategory.allCases { map[category.rawValue] = (sponsorActions[category.rawValue].flatMap(SponsorAction.init(rawValue:)) ?? category.defaultAction).rawValue }
        return map
    }

    var sponsorCategoriesWanted: [String] { sponsorActionMap.filter { $0.value != SponsorAction.off.rawValue }.map(\.key).sorted() }

    /// The page script's settings, or nil (no script) unless the feature is on AND the person has agreed to what it sends.
    var sponsorPolicy: SponsorPolicy? {
        guard sponsorBlockEnabled, sponsorConsentDate != nil, !sponsorCategoriesWanted.isEmpty else { return nil }
        return SponsorPolicy(actions: sponsorActionMap, offSites: sponsorOffSites)
    }

    /// Turns the feature on or off. Turning it on says plainly what it will send and asks first.
    func setSponsorBlock(enabled: Bool) async {
        if !enabled { sponsorBlockEnabled = false; sponsorCache.clear(); return }
        let server = URL(string: sponsorServer)?.host ?? sponsorServer
        let message = """
        To find the marked segments, Browser Setu asks \(server) (the SponsorBlock project’s server, unless you changed it) about each YouTube video you watch.

        It sends only the first 4 characters of a fingerprint (hash) of the video’s identifier. Thousands of videos share any one prefix, so the server cannot tell which one you are watching. It does not receive the full identifier, your cookies, your account or the page address. It does see your internet address and when you asked, as any website would.

        Nothing is sent in private tabs, on sites you switch it off for, or while this is off. The results are kept in memory for a few hours and never written to disk. The segment data is made by the SponsorBlock community.
        """
        let choice = await Dialogs.choose(title: "Turn on SponsorBlock?", message: message, buttons: ["Turn On", "Cancel"])
        guard choice == 0 else { return }
        sponsorConsentDate = Date()
        sponsorBlockEnabled = true
    }

    /// Looks up the segments of the video in this tab (if it is one) and hands them to the page. Does nothing unless the feature is on and agreed to, never for a private tab,
    /// a site switched off, or a page that is not a YouTube video.
    func sponsorCheck(_ tab: TabController) {
        guard sponsorBlockEnabled, sponsorConsentDate != nil, !tab.leavesNoTrace, let id = SponsorVideoID.parse(tab.url),
              let host = tab.url?.host, !sponsorOffSites.contains(FaviconStore.key(forHost: host) ?? host) else { return }
        let categories = sponsorCategoriesWanted
        guard !categories.isEmpty else { return }
        tab.sponsorTask?.cancel()
        let server = sponsorServer
        tab.sponsorTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            var segments = self.sponsorCache.get(id, categories: categories)
            if segments == nil {
                guard let fetched = await SponsorBlockService.shared.fetch(videoID: id, categories: categories, server: server) else { return }
                self.sponsorCache.set(id, categories: categories, segments: fetched)
                segments = fetched
            }
            guard !Task.isCancelled, SponsorVideoID.parse(tab.url) == id, let segments, !segments.isEmpty,
                  let data = try? JSONEncoder().encode(segments), let json = String(data: data, encoding: .utf8) else { return }
            await tab.engine.setSponsorSpans(videoID: id, json: json)
        }
    }

    func setSponsor(host: String?, on: Bool) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        if on { sponsorOffSites.remove(key) } else { sponsorOffSites.insert(key) }
        saveSetting("sponsor_off", encodedMap(["list": Array(sponsorOffSites).sorted()]))
        pushWebPolicy()
    }

    func sponsorOn(forHost host: String?) -> Bool {
        guard let key = FaviconStore.key(forHost: host) else { return true }
        return !sponsorOffSites.contains(key)
    }

    func setSponsorAction(_ category: SponsorCategory, _ action: SponsorAction) {
        sponsorActions[category.rawValue] = action.rawValue
        saveSetting("sponsor_actions", encodedMap(sponsorActions))
        sponsorCache.clear()
        pushWebPolicy()
    }
}

// MARK: - Settings and the site card

struct SponsorBlockSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var server = ""

    var body: some View {
        Section {
            Toggle("Skip sponsor segments in YouTube videos", isOn: Binding(get: { model.sponsorBlockEnabled }, set: { on in Task { await model.setSponsorBlock(enabled: on) } }))
            if model.sponsorBlockEnabled {
                ForEach(SponsorCategory.allCases) { category in
                    Picker(category.title, selection: Binding(get: { SponsorAction(rawValue: model.sponsorActionMap[category.rawValue] ?? "") ?? .off },
                                                              set: { model.setSponsorAction(category, $0) })) {
                        ForEach(SponsorAction.allCases) { Text($0.title).tag($0) }
                    }
                }
                TextField("Server for marked parts", text: $server).autocorrectionDisabled()
                    .onSubmit { if SponsorBlockService.validServer(server) { model.sponsorServer = server } else { server = model.sponsorServer; model.notice = "Only an https address of a public server can be used." } }
                Button("Use the Default Server") { model.sponsorServer = SponsorBlockService.defaultServer; server = model.sponsorServer; model.sponsorCache.clear() }
                    .disabled(model.sponsorServer == SponsorBlockService.defaultServer)
                Button("Forget Fetched Marks") { model.sponsorCache.clear() }
            }
        } header: {
            Text("SponsorBlock")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
            Text(model.sponsorBlockEnabled
                 ? "Marked parts come from \(URL(string: model.sponsorServer)?.host ?? model.sponsorServer): the first 4 characters of a fingerprint of each video’s identifier are sent, nothing else. Never in private tabs. Not used on protected videos, live streams or while an ad plays. The marked-part data is made by the SponsorBlock community. In full-screen on iPhone the Skip button cannot be drawn over the system player; use automatic skipping there."
                 : "Off. Turning it on asks first and tells you exactly what is sent. Browser Setu contacts nothing for this while it is off.")
                Text("The skip times come from SponsorBlock, by Ajay Ramachandran and contributors (sponsor.ajay.app), shared under CC BY-NC-SA 4.0.")
            }
        }
        .onAppear { server = model.sponsorServer }
    }
}

struct SiteSponsorRows: View {
    @EnvironmentObject var model: BrowserModel
    let host: String?
    @State private var summary = ""

    var body: some View {
        Group {
            if model.sponsorBlockEnabled, SponsorVideoID.parse(model.active?.url) != nil || (host.map { FaviconStore.key(forHost: $0) == "youtube.com" } ?? false) {
                Toggle("Skip sponsor segments on this site", isOn: Binding(get: { model.sponsorOn(forHost: host) }, set: { model.setSponsor(host: host, on: $0) }))
                if !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        guard let tab = model.active, let raw = await tab.engine.sponsorStats(), let data = raw.data(using: .utf8),
              let found = try? JSONDecoder().decode(SponsorStats.self, from: data) else { return }
        summary = found.count == 0 ? "No marked segments in this video." : "Skipped \(found.skipped) of \(found.count) segment\(found.count == 1 ? "" : "s") on this page (\(found.seconds) s)."
    }

}

struct SponsorStats: Decodable { var skipped: Int; var seconds: Int; var state: String; var count: Int }
