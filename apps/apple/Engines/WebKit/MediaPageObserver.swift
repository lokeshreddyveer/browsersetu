import Foundation
import WebKit

/// DX-07: watches the media of a page while it is open. A small script runs in every frame, in the browser's own isolated script world (`.defaultClient`, never the page's), so the page
/// cannot see it, change it or call it. It is event-driven: it reacts to a media element's own events and to the elements a page adds or re-points, coalesces them, and posts a short
/// message per player. It reads addresses, declared types, sizes, track labels and the playing state, and nothing else: no page text, form values, cookies or storage. It does not touch
/// playback, add a hook to how media is loaded, or change the page. WebKit offers no supported view of a page's network requests, so a player that loads its media only through script
/// (fetch into a MediaSource) shows as an in-page stream; the playlists such a player fetched are seen through the page's Resource Timing entries.
///
/// Limits that are WebKit's, not ours: a frame the page's sandbox forbids scripts in may not run this script; elements inside shadow roots (open or closed) are not looked into; cross-origin Resource Timing entries list
/// an address but no sizes. Nothing here works around any of that.
enum MediaPageObserver {
    static let handlerName = "bsMedia"
    /// The setting (default on) that lets the browser watch pages for media. Turning it off removes the script from tabs opened afterwards.
    static let defaultsKey = "bs.media.observe"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    static let script = """
    (function () {
      if (window.__bsMedia) return;
      const bytes = new Uint8Array(12); crypto.getRandomValues(bytes);
      const frame = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
      const post = (m) => { try { m.f = frame; window.webkit.messageHandlers.bsMedia.postMessage(m); } catch (e) {} };
      const MAX_PLAYERS = 100, MAX_PER_FLUSH = 40, MAX_TEXT = 8192;
      const ids = new WeakMap(); const refs = new Map(); const sent = new Map(); const dirty = new Set();
      let next = 1, timer = 0, flushed = 0;
      const text = (u) => (typeof u === 'string' && u.length > 0 && u.length <= MAX_TEXT) ? u : '';
      const num = (n) => (typeof n === 'number' && isFinite(n) && n > 0) ? n : null;
      const idOf = (el) => { let id = ids.get(el); if (id && !refs.has(id)) refs.set(id, new WeakRef(el)); if (!id) { if (refs.size >= MAX_PLAYERS) return 0; id = next++; ids.set(el, id); refs.set(id, new WeakRef(el)); } return id; };
      const read = (el, id) => {
        const m = { t: 'player', p: id, tag: el.tagName.toLowerCase() };
        let cur = ''; try { cur = text(el.currentSrc); } catch (e) {}
        if (cur) m.cur = cur;
        let attr = ''; try { attr = el.hasAttribute('src') ? text(el.src) : ''; } catch (e) {}
        if (attr && attr !== cur) m.src = attr;
        const declared = [];
        for (const s of el.querySelectorAll('source')) { if (declared.length >= 20) break; const u = text(s.src); if (u) declared.push({ u: u, t: String(s.type || '').slice(0, 100) }); }
        if (declared.length) m.srcs = declared;
        const d = num(el.duration); if (d) m.dur = d;
        m.loaded = el.readyState >= 1;
        if (m.loaded && m.tag === 'video') { m.w = el.videoWidth | 0; m.h = el.videoHeight | 0; }
        const poster = m.tag === 'video' ? text(el.poster) : ''; if (poster) m.poster = poster;
        const tracks = [];
        for (const t of el.querySelectorAll('track')) { if (tracks.length >= 20) break; tracks.push({ k: String(t.kind || 'subtitles').slice(0, 24), l: String(t.srclang || '').slice(0, 35) || undefined, n: String(t.label || '').slice(0, 120) || undefined, u: text(t.src) || undefined }); }
        if (tracks.length) m.tracks = tracks;
        if (cur.toLowerCase().startsWith('blob:') || (attr && attr.toLowerCase().startsWith('blob:'))) m.blob = true;
        try { if (el.mediaKeys) m.drm = true; } catch (e) {}
        m.playing = !el.paused && !el.ended;
        const title = String(el.getAttribute('title') || el.getAttribute('aria-label') || '').slice(0, 200); if (title) m.title = title;
        return m;
      };
      const flush = () => {
        timer = 0;
        if (framesDirty) { framesDirty = false; reportFrames(); }
        // A page that is not on screen does no work now; what is waiting is looked at when it is shown (the event), and checked every couple of seconds in case the event never comes.
        if (document.visibilityState === 'hidden') { if (dirty.size || framesDirty) timer = setTimeout(flush, 2000); return; }
        let n = 0;
        for (const el of Array.from(dirty)) {
          dirty.delete(el);
          if (++n > MAX_PER_FLUSH) { dirty.add(el); timer = setTimeout(flush, 400); break; }
          if (!el.isConnected) continue;
          const id = idOf(el); if (!id) continue;
          const m = read(el, id); const sig = JSON.stringify(m);
          if (sent.get(id) === sig) continue;
          sent.set(id, sig); post(m);
        }
        for (const [id, ref] of Array.from(refs)) {
          const el = ref.deref();
          if (!el || !el.isConnected) { refs.delete(id); sent.delete(id); post({ t: 'gone', p: id }); }
        }
      };
      const schedule = () => { if (!timer) timer = setTimeout(flush, 150); };
      const mark = (el) => { if (el && (el.tagName === 'VIDEO' || el.tagName === 'AUDIO')) { dirty.add(el); schedule(); } };
      const markIn = (node) => {
        if (!node || node.nodeType !== 1) return;
        if (node.tagName === 'VIDEO' || node.tagName === 'AUDIO') { mark(node); return; }
        if (node.tagName === 'SOURCE' || node.tagName === 'TRACK') { mark(node.parentElement); return; }
        if (node.querySelectorAll) { let k = 0; for (const el of node.querySelectorAll('video, audio')) { mark(el); if (++k >= 50) break; } }
      };
      let framesDirty = false;
      const events = ['loadstart', 'loadedmetadata', 'durationchange', 'emptied', 'play', 'pause', 'ended', 'resize'];
      for (const name of events) document.addEventListener(name, (e) => mark(e.target), true);
      let rescanSoon = false;
      new MutationObserver((records) => {
        let k = 0;
        for (const r of records) {
          if (++k > 200) { rescanSoon = true; break; }
          if (r.type === 'attributes') { const t = r.target; if (t.tagName === 'SOURCE' || t.tagName === 'TRACK') mark(t.parentElement); else mark(t); }
          else { for (const n of r.addedNodes) { markIn(n); if (n.nodeType === 1 && (n.tagName === 'IFRAME' || n.tagName === 'FRAME' || (n.querySelector && n.querySelector('iframe, frame')))) { framesDirty = true; schedule(); } } if (r.removedNodes.length) schedule(); }
        }
        if (rescanSoon) { rescanSoon = false; scanAll(); schedule(); }
      }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'srcset', 'poster'] });
      let lastFrames = '';
      const reportFrames = () => {
        let n = 0, b = 0;
        for (const f of document.querySelectorAll('iframe, frame')) {
          if (++n > 10000) break;
          const sb = f.getAttribute('sandbox');
          if (sb !== null && !/(^|\\s)allow-scripts(\\s|$)/i.test(sb)) b++;
        }
        const sig = n + ':' + b; if (sig === lastFrames) return; lastFrames = sig;
        post({ t: 'frames', n: n, b: b });
      };
      const scanAll = () => { reportFrames(); let k = 0; for (const el of document.querySelectorAll('video, audio')) { mark(el); if (++k >= MAX_PLAYERS) break; } };
      // Playlists and media a player loaded by script show up in Resource Timing with their address (sizes are withheld across origins).
      const reported = new Set(); let fetchedMedia = 0;
      const resources = (entries) => {
        const out = [];
        for (const e of entries) {
          const u = text(e.name); if (!u || reported.has(u) || reported.size >= 200) continue;
          if (!/^https?:/i.test(u)) continue;
          const manifest = /\\.(m3u8|mpd)(?:$|[?#])/i.test(u);
          // Media an element loads is reported by that element (and goes when it does); only media fetched by script, which no element shows, is taken from here.
          const byScript = e.initiatorType === 'fetch' || e.initiatorType === 'xmlhttprequest' || e.initiatorType === 'other';
          const media = byScript && /\\.(mp4|m4v|webm|mp3|m4a|aac|ogg|opus|flac|wav|mov)(?:$|[?#])/i.test(u);
          if (!manifest && !media) continue;
          if (media && ++fetchedMedia > 5) continue;          // a player that fetches media in pieces by script would otherwise list every piece
          reported.add(u); out.push({ u: u, i: String(e.initiatorType || '').slice(0, 32) });
          if (out.length >= 20) break;
        }
        if (out.length) post({ t: 'res', r: out });
      };
      try { new PerformanceObserver((list) => resources(list.getEntries())).observe({ type: 'resource', buffered: true }); } catch (e) {}
      document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') { scanAll(); schedule(); } });
      window.addEventListener('pageshow', (e) => { if (e.persisted) { post({ t: 'hello' }); sent.clear(); lastFrames = ''; } scanAll(); });
      window.addEventListener('pagehide', () => { post({ t: 'bye' }); });
      window.addEventListener('popstate', () => { scanAll(); });
      window.addEventListener('hashchange', () => { scanAll(); });
      window.__bsMedia = { rescan: () => { scanAll(); schedule(); } };
      post({ t: 'hello' });
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', scanAll, { once: true }); else scanAll();
    })();
    """

    /// Adds the observer to a content controller: the script in every frame (isolated world) and its message handler. Called once per controller.
    @MainActor
    static func install(in controller: WKUserContentController, sink: @escaping @MainActor (WKWebView?, MediaObservation) -> Void) {
        controller.add(MediaMessageHandler(sink: sink), contentWorld: .defaultClient, name: handlerName)
        guard isEnabled else { return }
        UserScriptInstaller.addMediaObserver(source: script, to: controller)
    }
}

final class MediaMessageHandler: NSObject, WKScriptMessageHandler {
    private let sink: @MainActor (WKWebView?, MediaObservation) -> Void
    init(sink: @escaping @MainActor (WKWebView?, MediaObservation) -> Void) { self.sink = sink }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // The frame's origin and whether it is the main frame are WebKit's answer for the frame that sent this, not anything the message says.
        let info = message.frameInfo
        let origin = info.securityOrigin
        let facts = MediaFrameFacts(origin: "\(origin.protocol)://\(origin.host)" + (origin.port > 0 ? ":\(origin.port)" : ""), isMain: info.isMainFrame)
        guard let observation = MediaObservationParser.parse(message.body, frame: facts) else { return }
        let web = message.webView
        MainActor.assumeIsolated { sink(web, observation) }
    }
}
