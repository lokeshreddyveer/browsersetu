import Foundation
import WebKit

/// "Find Downloadable Media": runs once, when asked, on the page that is open. It reads the address, declared type and length of each video, audio and source element, and the
/// address of a link that points at a media file or playlist, and nothing else: no form values, no text, no cookies, no storage. It runs in the browser's own script world, so
/// the page cannot see or change it, and it installs nothing in the page (no observer, no timer, no hook on how media is loaded or played).
///
/// WebKit offers no supported way to watch a page's network requests, so this reads what the page's own elements say. Media a page assembles in memory (MediaSource) shows up
/// as a blob: element and is reported as such, not as a file.
@MainActor
enum MediaPageExtractor {
    static let maxElements = 2000
    static let maxResults = 200

    static let script = """
    const out = []; const seen = new Set(); let looked = 0; let cut = false;
    const add = (o) => { if (out.length >= maxResults) { cut = true; return false; } out.push(o); return true; };
    const text = (u) => (typeof u === 'string' && u.length > 0 && u.length <= 8192) ? u : '';
    const finite = (d) => (typeof d === 'number' && isFinite(d) && d > 0) ? d : null;
    for (const el of document.querySelectorAll('video, audio')) {
      if (++looked > maxElements) { cut = true; break; }
      const tag = el.tagName.toLowerCase();
      let dur = null, drm = false;
      try { dur = finite(el.duration); } catch (e) {}
      try { drm = !!el.mediaKeys; } catch (e) {}
      let cur = '';
      try { cur = text(el.currentSrc) || (el.hasAttribute('src') ? text(el.src) : ''); } catch (e) {}
      if (cur.toLowerCase().startsWith('blob:')) { if (!add({ blob: true, element: tag, type: '', duration: dur, drm: drm })) break; }
      else if (cur && !seen.has(cur)) { seen.add(cur); if (!add({ href: cur, element: tag, type: String(el.getAttribute('type') || '').slice(0, 100), duration: dur, drm: drm, blob: false })) break; }
      else if (!cur && drm) { if (!add({ blob: true, element: tag, type: '', duration: dur, drm: drm })) break; }
      for (const s of el.querySelectorAll('source')) {
        if (++looked > maxElements) { cut = true; break; }
        let h = ''; try { h = text(s.src); } catch (e) {}
        if (!h || h.toLowerCase().startsWith('blob:') || seen.has(h)) continue;
        seen.add(h);
        if (!add({ href: h, element: 'source', type: String(s.type || '').slice(0, 100), duration: dur, drm: drm, blob: false })) break;
      }
    }
    const ext = /\\.(m3u8|mpd|mp4|m4v|mov|webm|mkv|mp3|m4a|aac|ogg|oga|opus|wav|flac)(?:$|[?#])/i;
    for (const a of document.querySelectorAll('a[href]')) {
      if (++looked > maxElements) { cut = true; break; }
      let h = ''; try { h = a.href; } catch (e) { continue; }
      if (typeof h !== 'string' || !h || h.length > 8192 || seen.has(h)) continue;
      if (!/^https?:/i.test(h) || !ext.test(h)) continue;
      seen.add(h);
      if (!add({ href: h, element: 'link', type: '', duration: null, drm: false, blob: false })) break;
    }
    return { hits: out, cut: cut };
    """

    static func collect(from webView: WKWebView) async -> MediaPageSnapshot {
        let answer = try? await webView.callAsyncJavaScript(script, arguments: ["maxElements": maxElements, "maxResults": maxResults], contentWorld: .defaultClient) as? [String: Any]
        guard !Task.isCancelled else { return MediaPageSnapshot(hits: [], truncated: false) }
        guard let answer else { return MediaPageSnapshot(hits: [], truncated: false, failed: true) }
        let raw = (answer["hits"] as? [[String: Any]]) ?? []
        let hits = raw.prefix(maxResults).map { d in
            MediaPageHit(href: d["href"] as? String, element: (d["element"] as? String) ?? "link", type: (d["type"] as? String) ?? "", duration: d["duration"] as? Double,
                         drm: (d["drm"] as? Bool) ?? false, blob: (d["blob"] as? Bool) ?? false)
        }
        return MediaPageSnapshot(hits: Array(hits), truncated: (answer["cut"] as? Bool) ?? false)
    }
}
