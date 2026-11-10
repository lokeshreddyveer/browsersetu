import Foundation

/// Playback speed and picture-in-picture for the video on any page. A speed chosen for a website is remembered and applied to every
/// video that site shows afterwards, including ones that appear while you watch. Nothing leaves the device.
enum VideoControls {
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func label(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
    }

    /// Run at the start of every page: gives each video on a remembered site its speed. `speeds` maps a site name (no "www.") to a rate.
    static func rememberedSpeedScript(_ speeds: [String: Double]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: speeds)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return """
        (function () {
          if (window.__bsVideoSpeed) { return; }
          window.__bsVideoSpeed = true;
          var table = \(json), host = location.hostname.toLowerCase().replace(/^www\\./, '');
          var rate = null;
          Object.keys(table).forEach(function (site) { if (host === site || host.endsWith('.' + site)) { rate = table[site]; } });
          if (!rate || !(rate >= 0.0625 && rate <= 16)) { return; }
          function apply(video) { if (video.playbackRate !== rate) { video.playbackRate = rate; } }
          function sweep() { document.querySelectorAll('video').forEach(apply); }
          // A player resets its own speed when a new clip loads, so the speed is put back as each one starts.
          document.addEventListener('loadedmetadata', function (e) { if (e.target && e.target.tagName === 'VIDEO') { apply(e.target); } }, true);
          document.addEventListener('play', function (e) { if (e.target && e.target.tagName === 'VIDEO') { apply(e.target); } }, true);
          document.addEventListener('DOMContentLoaded', sweep);
          sweep();
        })();
        """
    }

    /// Sets the speed of every video on the page now.
    static func setNow(_ rate: Double) -> String {
        "document.querySelectorAll('video').forEach(function (v) { v.playbackRate = \(rate); }); return document.querySelectorAll('video').length;"
    }

    /// Opens the biggest playing (or else the biggest) video in a floating window.
    static let pictureInPicture = """
    var videos = Array.from(document.querySelectorAll('video')).filter(function (v) { return v.readyState > 0; });
    if (!videos.length) { return false; }
    videos.sort(function (a, b) { return (!b.paused - !a.paused) || (b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight); });
    var v = videos[0];
    try {
      if (document.pictureInPictureElement) { await document.exitPictureInPicture(); return true; }
      if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
        v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture'); return true;
      }
      if (v.requestPictureInPicture) { await v.requestPictureInPicture(); return true; }
    } catch (e) { return false; }
    return false;
    """
}


/// Finding and driving the players on a page without ever naming one by its place in a list. Each player gets a number the first time it is seen, kept in a table that lives in the
/// browser's own script world (a page cannot read, change or fake it), so the number follows the same player through any change to the page around it, and a player that has been
/// removed is simply gone, never replaced in the list by a different one.
enum MediaScripts {
    /// Shared by both scripts below: the table, and a walk over the page that also goes into open shadow trees and into frames of the same site.
    static let registry = """
    const R = window.__bsMedia || (window.__bsMedia = { next: 1, ids: new WeakMap(), byId: new Map() });
    function idOf(el) {
      let id = R.ids.get(el);
      if (!id) { id = R.next++; R.ids.set(el, id); R.byId.set(id, new WeakRef(el)); }
      return id;
    }
    function find(limit) {
      const out = [], seen = new Set();
      let visited = 0;
      (function walk(root, depth) {
        if (!root || depth > 4 || out.length >= limit) return;
        let list = [];
        try { list = root.querySelectorAll('*'); } catch (e) { return; }
        for (const el of list) {
          if (++visited > 6000 || out.length >= limit) return;
          if (el.tagName === 'VIDEO' || el.tagName === 'AUDIO') { if (!seen.has(el)) { seen.add(el); out.push(el); } }
          if (el.shadowRoot) walk(el.shadowRoot, depth + 1);
          if (el.tagName === 'IFRAME') { try { if (el.contentDocument) walk(el.contentDocument, depth + 1); } catch (e) {} }
        }
      })(document, 0);
      return out;
    }
    """

    /// The players on the page, each with its number. At most `limit`.
    static func list(limit: Int = 16) -> String {
        registry + """
        return find(\(limit)).map(m => ({
          id: idOf(m),
          tag: m.tagName.toLowerCase(), src: m.currentSrc || m.src || '', blob: (m.currentSrc || m.src || '').startsWith('blob:'),
          currentTime: m.currentTime, duration: isFinite(m.duration) ? m.duration : 0, paused: m.paused, rate: m.playbackRate, readyState: m.readyState, networkState: m.networkState, hasMediaKeys: !!m.mediaKeys,
          errorCode: m.error ? m.error.code : null, errorMessage: m.error ? (m.error.message || '') : null,
          volume: m.volume, muted: m.muted,
          width: m.videoWidth || 0, height: m.videoHeight || 0,
          dropped: (m.getVideoPlaybackQuality ? m.getVideoPlaybackQuality().droppedVideoFrames : 0), frames: (m.getVideoPlaybackQuality ? m.getVideoPlaybackQuality().totalVideoFrames : 0),
          sessionTitle: (navigator.mediaSession && navigator.mediaSession.metadata) ? (navigator.mediaSession.metadata.title || '') : '',
          sessionArtist: (navigator.mediaSession && navigator.mediaSession.metadata) ? (navigator.mediaSession.metadata.artist || '') : '',
          pageTitle: document.title || '',
          tracks: Array.from(m.textTracks || []).filter(t => t.kind === 'subtitles' || t.kind === 'captions').map(t => ({ label: t.label || t.language || 'Track', language: t.language || '', mode: t.mode })),
          canAirPlay: !!m.webkitShowPlaybackTargetPicker,
          live: m.duration === Infinity,
          loop: !!m.loop,
          seekStart: m.seekable && m.seekable.length ? m.seekable.start(0) : null,
          seekEnd: m.seekable && m.seekable.length ? m.seekable.end(m.seekable.length - 1) : null,
          bufferedEnd: (function () { try { for (let i = 0; i < m.buffered.length; i++) { if (m.currentTime >= m.buffered.start(i) - 0.1 && m.currentTime <= m.buffered.end(i) + 0.1) return m.buffered.end(i); } } catch (e) {} return null; })(),
          visible: (function () { const r = m.getBoundingClientRect(), c = getComputedStyle(m); return r.width >= 40 && r.height >= 30 && c.visibility !== 'hidden' && c.display !== 'none' && parseFloat(c.opacity) > 0.01; })(),
          inView: (function () { const r = m.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth; })(),
          area: (function () { const r = m.getBoundingClientRect(); return Math.round(r.width * r.height); })(),
          decorative: !!(m.muted && m.loop && !m.controls),
          audioTracks: m.audioTracks ? Array.from(m.audioTracks).map(t => ({ label: t.label || t.language || 'Track', enabled: !!t.enabled })) : [],
          theater: !!(R.theater && R.theater.ref.deref() === m),
          focus: !!(R.focus && R.focus.ref.deref() === m),
          fit: m.style.objectFit || '',
          picture: (R.adjust && R.adjust.get(idOf(m))) || null,
          chapters: (function () { try { const t = Array.from(m.textTracks || []).find(t => t.kind === 'chapters'); if (!t) { return []; } if (t.mode === 'disabled') { t.mode = 'hidden'; } return Array.from(t.cues || []).slice(0, 200).map(c => ({ title: c.text || '', start: c.startTime })); } catch (e) { return []; } })(),
          ab: (function () { const a = R.ab && R.ab.get(idOf(m)); return a ? { a: a.a, b: a.b === undefined ? null : a.b } : null; })()
        }));
        """
    }

    /// One action on one player. Returns nothing when it worked, or a short sentence saying why it did not (the player is gone, the page refused, the action is not available).
    static let control = registry + """
    const ref = R.byId.get(id), m = ref && ref.deref();
    if (!m || !m.isConnected) { R.byId.delete(id); return 'That player is no longer on the page.'; }
    try {
      if (action === 'play') { await m.play(); }
      else if (action === 'pause') { m.pause(); }
      else if (action === 'speed') { m.playbackRate = value; }
      else if (action === 'seek') { m.currentTime = value; }
      else if (action === 'seekBy') {
        // Only inside what the player says can be reached: a live stream with no window, or a player that is not ready, cannot be moved.
        if (!m.seekable || !m.seekable.length) { return 'This video cannot be moved to another point.'; }
        const lo = m.seekable.start(0), hi = m.seekable.end(m.seekable.length - 1);
        m.currentTime = Math.max(lo, Math.min(hi, m.currentTime + value));
      }
      else if (action === 'loop') { m.loop = value > 0; }
      else if (action === 'frame') {
        // One picture at a time. WebKit does not say how many pictures a second a video has, so a step is a thirtieth of a second.
        if (!m.seekable || !m.seekable.length) { return 'This video cannot be moved to another point.'; }
        if (!m.paused) { m.pause(); }
        m.currentTime = Math.max(m.seekable.start(0), Math.min(m.seekable.end(m.seekable.length - 1), m.currentTime + value / 30));
      }
      else if (action === 'speedBy') { m.playbackRate = Math.min(16, Math.max(0.0625, Math.round((m.playbackRate + value) * 100) / 100)); }
      else if (action === 'fit') {
        if (value < 0) { m.style.removeProperty('object-fit'); } else { m.style.setProperty('object-fit', ['contain', 'cover', 'fill'][Math.round(value)] || 'contain', 'important'); }
      }
      else if (action === 'focus') {
        const leave = () => {
          const f = R.focus; if (!f) { return; }
          const el = f.ref.deref();
          if (el) { if (f.css) { el.setAttribute('style', f.css); } else { el.removeAttribute('style'); } el.removeEventListener('emptied', f.leave); }
          window.removeEventListener('pagehide', f.leave); window.removeEventListener('popstate', f.leave);
          R.focus = null;
        };
        if (value <= 0) { leave(); }
        else {
          if (R.focus) { leave(); }
          const cs = getComputedStyle(m);
          const f = { ref: new WeakRef(m), css: m.getAttribute('style') || '', leave };
          R.focus = f;
          // The video stays where it is; everything around it is dimmed by a very wide shadow of its own. Nothing else on the page is touched.
          m.style.setProperty('box-shadow', '0 0 0 100vmax rgba(0,0,0,.88)', 'important');
          m.style.setProperty('position', cs.position === 'static' ? 'relative' : cs.position, 'important');
          m.style.setProperty('z-index', '2147483000', 'important');
          window.addEventListener('pagehide', leave); window.addEventListener('popstate', leave); m.addEventListener('emptied', leave);
        }
      }
      else if (action.indexOf('adjust:') === 0) {
        if (m.mediaKeys) { return 'Picture adjustments are not available for protected video.'; }
        R.adjust = R.adjust || new Map();
        const part = action.split(':')[1];
        let a = R.adjust.get(id) || { brightness: 1, contrast: 1, saturation: 1 };
        if (part === 'reset') { a = { brightness: 1, contrast: 1, saturation: 1 }; } else { a[part] = Math.max(0.4, Math.min(1.8, Math.round((a[part] + value) * 100) / 100)); }
        if (a.brightness === 1 && a.contrast === 1 && a.saturation === 1) { R.adjust.delete(id); m.style.removeProperty('filter'); }
        else { R.adjust.set(id, a); m.style.setProperty('filter', 'brightness(' + a.brightness + ') contrast(' + a.contrast + ') saturate(' + a.saturation + ')', 'important'); }
      }
      else if (action === 'subtitleShift') {
        let moved = 0;
        for (const t of Array.from(m.textTracks || [])) {
          if (t.mode !== 'showing' || !t.cues) { continue; }
          for (const c of Array.from(t.cues)) { try { c.startTime = Math.max(0, c.startTime + value); c.endTime = Math.max(0, c.endTime + value); moved++; } catch (e) { return 'This player does not allow its subtitle timing to be changed.'; } }
        }
        if (!moved) { return 'No subtitles are showing.'; }
      }
      else if (action === 'endAction') {
        // What happens when it finishes: nothing special (0), or leave theater and focus mode (1).
        R.endH = R.endH || new Map();
        const old = R.endH.get(id); if (old) { m.removeEventListener('ended', old); R.endH.delete(id); }
        if (value > 0) {
          const h = function () { if (R.theater && R.theater.ref.deref() === m) { R.theater.leave(); } if (R.focus && R.focus.ref.deref() === m) { R.focus.leave(); } };
          R.endH.set(id, h); m.addEventListener('ended', h);
        }
      }
      else if (action.indexOf('setAB:') === 0) {
        const parts = action.split(':'), a = parseFloat(parts[1]), b = parseFloat(parts[2]);
        if (!m.seekable || !m.seekable.length) { return 'This video cannot be repeated between two points.'; }
        if (!(b > a)) { return 'Point B must come after point A.'; }
        R.ab = R.ab || new Map();
        const prev = R.ab.get(id); if (prev && prev.fn) { m.removeEventListener('timeupdate', prev.fn); m.removeEventListener('emptied', prev.stop); m.removeEventListener('loadstart', prev.stop); }
        const o = { a: a, b: b };
        o.fn = function () { if (m.currentTime >= o.b) { m.currentTime = o.a; } };
        o.stop = function () { m.removeEventListener('timeupdate', o.fn); m.removeEventListener('emptied', o.stop); m.removeEventListener('loadstart', o.stop); R.ab.delete(id); };
        R.ab.set(id, o); m.addEventListener('timeupdate', o.fn); m.addEventListener('emptied', o.stop); m.addEventListener('loadstart', o.stop);
        m.currentTime = a;
      }
      else if (action === 'audioTrack') {
        if (!m.audioTracks || m.audioTracks.length < 2) { return 'This player has no other audio to choose.'; }
        Array.from(m.audioTracks).forEach((t, i) => { t.enabled = (i === Math.round(value)); });
      }
      else if (action === 'theater') {
        // Reversible and scoped: only this video's own style and the page's scroll are touched, and both are put back, on request or as soon as the page or the player goes.
        const leave = () => {
          const t = R.theater; if (!t) { return; }
          const el = t.ref.deref();
          if (el) { if (t.css) { el.setAttribute('style', t.css); } else { el.removeAttribute('style'); } }
          document.documentElement.style.overflow = t.overflow;
          window.removeEventListener('pagehide', t.leave); window.removeEventListener('popstate', t.leave);
          if (el) { el.removeEventListener('emptied', t.leave); }
          R.theater = null;
        };
        if (value <= 0) { leave(); }
        else {
          if (m.tagName !== 'VIDEO') { return 'Only video can use theater mode.'; }
          if (R.theater) { leave(); }
          const t = { ref: new WeakRef(m), css: m.getAttribute('style') || '', overflow: document.documentElement.style.overflow, leave };
          R.theater = t;
          m.style.cssText = t.css + ';position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;z-index:2147483646!important;background:#000!important;object-fit:contain!important;transform:none!important';
          document.documentElement.style.overflow = 'hidden';
          window.addEventListener('pagehide', leave); window.addEventListener('popstate', leave); m.addEventListener('emptied', leave);
        }
      }
      else if (action === 'markA' || action === 'markB' || action === 'clearAB') {
        R.ab = R.ab || new Map();
        const clear = () => { const o = R.ab.get(id); if (o && o.fn) { m.removeEventListener('timeupdate', o.fn); m.removeEventListener('emptied', o.stop); m.removeEventListener('loadstart', o.stop); } R.ab.delete(id); };
        if (action === 'clearAB') { clear(); }
        else if (!m.seekable || !m.seekable.length) { return 'This video cannot be repeated between two points.'; }
        else if (action === 'markA') { clear(); R.ab.set(id, { a: m.currentTime }); }
        else {
          const o = R.ab.get(id);
          if (!o) { return 'Set point A first.'; }
          if (m.currentTime <= o.a + 0.5) { return 'Point B must come after point A.'; }
          if (o.fn) { m.removeEventListener('timeupdate', o.fn); }
          o.b = m.currentTime;
          // Back to A each time B is reached; gone as soon as the player is given something else to play.
          o.fn = function () { if (m.currentTime >= o.b) { m.currentTime = o.a; } };
          o.stop = function () { clear(); };
          m.addEventListener('timeupdate', o.fn); m.addEventListener('emptied', o.stop); m.addEventListener('loadstart', o.stop);
        }
      }
      else if (action === 'mute') { m.muted = value > 0; }
      else if (action === 'volume') { m.volume = Math.max(0, Math.min(1, value)); }
      else if (action === 'airplay') { if (!m.webkitShowPlaybackTargetPicker) return 'This player cannot send to another screen.'; m.webkitShowPlaybackTargetPicker(); }
      else if (action === 'subtitle') {
        const list = Array.from(m.textTracks || []).filter(t => t.kind === 'subtitles' || t.kind === 'captions');
        list.forEach((t, i) => { t.mode = (i === Math.round(value)) ? 'showing' : 'disabled'; });
      }
      else if (action === 'pictureInPicture') {
        if (m.webkitSetPresentationMode && m.webkitSupportsPresentationMode && m.webkitSupportsPresentationMode('picture-in-picture')) { m.webkitSetPresentationMode(m.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture'); }
        else if (document.pictureInPictureEnabled && m.requestPictureInPicture) { if (document.pictureInPictureElement) { await document.exitPictureInPicture(); } else { await m.requestPictureInPicture(); } }
        else { return 'This player cannot be popped out.'; }
      }
      else if (action === 'fullscreen') {
        if (m.webkitEnterFullscreen) { m.webkitEnterFullscreen(); }
        else if (m.requestFullscreen) { await m.requestFullscreen(); }
        else { return 'This player cannot go full screen.'; }
      }
      else { return 'Unknown action.'; }
    } catch (e) {
      return (e && e.name === 'NotAllowedError') ? 'The page did not allow that (it needs a tap on the video first, or the site blocks it).' : ((e && e.message) ? e.message : 'The player refused.');
    }
    return null;
    """

    /// How many players sit in frames from other sites. The page cannot reach into those, so they cannot be controlled from here; this only counts them, so the panel can say so.
    static let blockedFrames = """
    let n = 0;
    const look = (doc, depth) => {
      for (const f of doc.querySelectorAll('iframe')) {
        let inner = null;
        try { inner = f.contentDocument; } catch (e) {}
        if (inner) { if (depth < 3) { look(inner, depth + 1); } }
        else if (/video|player|embed|youtube|vimeo|autoplay|twitch|dailymotion|stream/.test(((f.src || '') + ' ' + (f.allow || '') + ' ' + (f.title || '')).toLowerCase())) { n++; }
      }
    };
    look(document, 0);
    return n;
    """

    /// One frame of a video as a PNG, when the page and the video allow it. A protected video, or one from another site, refuses, and that is said.
    static let capture = registry + """
    const ref = R.byId.get(id), m = ref && ref.deref();
    if (!m || !m.isConnected) { return { error: 'That player is no longer on the page.' }; }
    if (m.tagName !== 'VIDEO') { return { error: 'Only video has pictures to copy.' }; }
    if (m.mediaKeys) { return { error: 'A picture cannot be copied from protected video.' }; }
    if (!m.videoWidth) { return { error: 'The video has not shown a picture yet.' }; }
    try {
      const c = document.createElement('canvas'); c.width = m.videoWidth; c.height = m.videoHeight;
      c.getContext('2d').drawImage(m, 0, 0);
      return { data: c.toDataURL('image/png') };
    } catch (e) { return { error: 'This video comes from another site, which does not let its pictures be copied.' }; }
    """

    /// The subtitles or captions a player exposes, as lines with their times. Nothing is fetched or guessed: only what the player already has.
    static let transcript = registry + """
    const ref = R.byId.get(id), m = ref && ref.deref();
    if (!m || !m.isConnected) { return { error: 'That player is no longer on the page.' }; }
    const tracks = Array.from(m.textTracks || []).filter(t => t.kind === 'subtitles' || t.kind === 'captions');
    const t = tracks.find(t => t.mode === 'showing') || tracks[0];
    if (!t) { return { error: 'This player has no subtitles or captions to read.' }; }
    if (t.mode === 'disabled') { t.mode = 'hidden'; }
    const cues = Array.from(t.cues || []).slice(0, 4000).map(c => ({ start: c.startTime, text: (c.text || '').replace(/<[^>]*>/g, '') }));
    if (!cues.length) { return { error: 'The subtitles have not loaded yet. Play the video for a moment and try again.' }; }
    return { label: t.label || t.language || 'Subtitles', cues: cues };
    """
}
